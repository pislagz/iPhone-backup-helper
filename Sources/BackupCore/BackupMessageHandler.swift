import Foundation

/// Implements the computer side of the DeviceLink messages the device sends during a backup
/// (DLMessageDownloadFiles/UploadFiles/GetFreeDiskSpace/ContentsOfDirectory/CreateDirectory/
/// MoveFiles/MoveItems/RemoveFiles/RemoveItems/CopyItem/ProcessMessage/Disconnect), writing
/// into the MobileSync backup folder (`root`). All paths from the device are relative to `root`
/// and are rejected when they try to leave it.
///
/// Pure Swift on top of `MobileBackup2Transport`, so it runs against a fake transport in tests.
public final class BackupMessageHandler {
    public struct Config: Sendable {
        /// Give up when the device sends nothing for this long in the middle of a transfer.
        public var stallTimeout: TimeInterval = 300
        public var chunkSize = 32 * 1024
        /// Free-space sources (overridable in tests); see `DiskSpace.availableBytes`.
        public var importantUsageSpace: @Sendable (URL) -> Int64? = DiskSpace.liveImportantUsage
        public var systemFreeSpace: @Sendable (URL) -> UInt64? = DiskSpace.liveSystemFree
        public init() {}
    }

    public enum Outcome: Equatable {
        case `continue`
        /// DLMessageDisconnect
        case disconnect
        /// DLMessageProcessMessage carrying the operation result (ErrorCode 0 = success).
        case finished(errorCode: Int, description: String?)
    }

    /// Suffix of files being received; renamed into place once complete.
    public static let partSuffix = ".ibh-part"

    private struct PartialFile {
        let handle: FileHandle
        let partURL: URL
        let finalURL: URL
    }

    public let root: URL
    private let transport: MobileBackup2Transport
    private let config: Config
    private let isCancelled: () -> Bool
    private let now: () -> Date
    private let log: BackupLogger
    private let fm = FileManager.default

    /// Bytes received from the device (file contents).
    public private(set) var bytesReceived: Int64 = 0
    public private(set) var filesReceived = 0
    /// True once a write failed because the Mac's disk (or quota) is full.
    public private(set) var diskFull = false
    /// Latest overall progress reported by the device, 0...100.
    public private(set) var progressPercent: Double?
    private var currentPartial: PartialFile?

    public init(
        root: URL,
        transport: MobileBackup2Transport,
        config: Config = Config(),
        isCancelled: @escaping () -> Bool = { false },
        now: @escaping () -> Date = { Date() },
        log: @escaping BackupLogger = { _, _ in }
    ) {
        self.root = root
        self.transport = transport
        self.config = config
        self.isCancelled = isCancelled
        self.now = now
        self.log = log
    }

    // MARK: - Dispatch

    public func handle(_ message: DLMessage) throws -> Outcome {
        switch message.name {
        case "DLMessageDownloadFiles":
            updateProgress(message, index: 3)
            try sendFiles(message)
        case "DLMessageUploadFiles":
            updateProgress(message, index: 2)
            try receiveFiles(message)
        case "DLMessageGetFreeDiskSpace":
            try sendFreeDiskSpace()
        case "DLMessagePurgeDiskSpace":
            try transport.sendStatusResponse(code: -1, description: "Operation not supported", payload: [String: Any]())
        case "DLContentsOfDirectory":
            try listDirectory(message)
        case "DLMessageCreateDirectory":
            try createDirectory(message)
        case "DLMessageMoveFiles", "DLMessageMoveItems":
            updateProgress(message, index: 3)
            try moveItems(message)
        case "DLMessageRemoveFiles", "DLMessageRemoveItems":
            updateProgress(message, index: 3)
            try removeItems(message)
        case "DLMessageCopyItem":
            try copyItem(message)
        case "DLMessageDisconnect":
            return .disconnect
        case "DLMessageProcessMessage":
            return processMessage(message)
        default:
            log(.error, "Ignoring unknown device message \(message.name)")
        }
        return .continue
    }

    /// Removes the file currently being received (cancel / connection loss).
    public func abort() {
        if let partial = currentPartial {
            try? partial.handle.close()
            try? fm.removeItem(at: partial.partURL)
            currentPartial = nil
        }
    }

    /// Deletes leftovers of a crashed run: `*.ibh-part` in `dir` and one level below.
    public static func sweepStaleParts(in dir: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for child in children {
            if child.lastPathComponent.hasSuffix(partSuffix) {
                try? fm.removeItem(at: child)
            } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let inner = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil) {
                for file in inner where file.lastPathComponent.hasSuffix(partSuffix) {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Helpers

    private func number(_ value: Any?) -> NSNumber? { value as? NSNumber }

    private func updateProgress(_ message: DLMessage, index: Int) {
        guard message.items.count > index, let value = number(message.items[index]) else { return }
        progressPercent = max(0, min(100, value.doubleValue))
    }

    /// Maps a device-relative path into `root`; nil when it would escape.
    func resolve(_ relative: String, allowRoot: Bool = false) -> URL? {
        guard !relative.contains("\0") else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        if parts.contains("..") { return nil }
        if parts.isEmpty { return allowRoot ? root : nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func checkCancelled() throws {
        if isCancelled() { throw BackupError.cancelled }
    }

    private func be32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: - Raw reads

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        var idleSince: Date?
        while result.count < count {
            try checkCancelled()
            let part = try transport.receiveRaw(count - result.count)
            if part.isEmpty {
                let current = now()
                let start = idleSince ?? current
                idleSince = start
                if current.timeIntervalSince(start) >= config.stallTimeout {
                    throw BackupError.failed("The device stopped sending data.")
                }
                continue
            }
            idleSince = nil
            result.append(part)
        }
        return result
    }

    private func readUInt32() throws -> UInt32 {
        let data = try readExactly(4)
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func readByte() throws -> UInt8 {
        try readExactly(1)[0]
    }

    /// A length-prefixed name; nil for the zero-length terminator.
    private func readName() throws -> String? {
        let length = Int(try readUInt32())
        if length == 0 { return nil }
        if length > 4096 { throw BackupError.failed("Protocol error: file name too long (\(length)).") }
        return String(decoding: try readExactly(length), as: UTF8.self)
    }

    // MARK: - DLMessageDownloadFiles (device wants files from the computer)

    private func sendFiles(_ message: DLMessage) throws {
        let files = (message.items.count > 1 ? message.items[1] as? [Any] : nil) ?? []
        var failures: [String: Any] = [:]

        for case let path as String in files {
            try checkCancelled()
            if let failure = try sendFile(path) {
                failures[path] = failure
            }
        }

        try transport.sendRaw(be32(0)) // end of file list
        if failures.isEmpty {
            try transport.sendStatusResponse(code: 0, description: nil, payload: [String: Any]())
        } else {
            try transport.sendStatusResponse(code: DeviceErrorCode.multiStatus, description: "Multi status", payload: failures)
        }
    }

    /// Streams one file; returns the per-file error entry when the file could not be sent.
    private func sendFile(_ path: String) throws -> [String: Any]? {
        let pathBytes = Data(path.utf8)
        try transport.sendRaw(be32(UInt32(pathBytes.count)) + pathBytes)

        var errorCode: Int32 = 0
        if let url = resolve(path) {
            do {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    errorCode = EISDIR
                } else if let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 {
                    errorCode = try streamContents(of: url)
                }
            } catch let error as BackupError {
                throw error
            } catch let error as TransportError {
                throw error
            } catch {
                errorCode = errnoValue(of: error)
            }
        } else {
            errorCode = EINVAL
        }

        if errorCode == 0 {
            try transport.sendRaw(be32(1) + Data([FileFrameCode.success]))
            return nil
        }
        let text = describe(errno: errorCode)
        let textBytes = Data(text.utf8)
        try transport.sendRaw(be32(UInt32(textBytes.count + 1)) + Data([FileFrameCode.errorLocal]) + textBytes)
        return [
            "DLFileErrorString": text,
            "DLFileErrorCode": DeviceErrorCode.from(errno: errorCode),
        ]
    }

    /// Returns an errno (0 = fully sent). Transport/cancel errors are thrown.
    private func streamContents(of url: URL) throws -> Int32 {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { return errnoValue(of: error) }
        defer { try? handle.close() }
        while true {
            try checkCancelled()
            let chunk: Data?
            do { chunk = try handle.read(upToCount: config.chunkSize) } catch { return errnoValue(of: error) }
            guard let chunk, !chunk.isEmpty else { return 0 }
            try transport.sendRaw(be32(UInt32(chunk.count + 1)) + Data([FileFrameCode.fileData]) + chunk)
        }
    }

    // MARK: - DLMessageUploadFiles (device sends files to the computer)

    private func receiveFiles(_ message: DLMessage) throws {
        var errorCode = 0
        var errorText: String?

        transfer: while true {
            try checkCancelled()
            guard try readName() != nil else { break }              // name on the device (informational)
            guard let relative = try readName() else { break }       // path inside the backup folder
            let destination = resolve(relative)

            var length = Int(try readUInt32())
            var code = try readByte()
            var lastCode: UInt8 = 0
            var failed = false
            var wroteAnyData = false

            if destination == nil {
                failed = true
                errorCode = DeviceErrorCode.generic
                errorText = "Invalid path"
                log(.error, "Device sent a file with an invalid path: \(relative)")
            }

            while code == FileFrameCode.fileData {
                var remaining = max(0, length - 1)
                while remaining > 0 {
                    let chunk = try readExactly(min(remaining, config.chunkSize))
                    remaining -= chunk.count
                    guard !failed, let destination else { continue }
                    do {
                        if currentPartial == nil { currentPartial = try openPartial(for: destination) }
                        try currentPartial?.handle.write(contentsOf: chunk)
                        bytesReceived += Int64(chunk.count)
                        wroteAnyData = true
                    } catch {
                        failed = true
                        let value = errnoValue(of: error)
                        noteWriteFailure(errno: value)
                        errorCode = DeviceErrorCode.from(errno: value)
                        errorText = describe(errno: value)
                        log(.error, "Could not write \(relative): \(describe(errno: value))")
                        abort()
                    }
                }
                try checkCancelled()
                length = Int(try readUInt32())
                if length > 0 {
                    lastCode = code
                    code = try readByte()
                } else {
                    break
                }
            }

            // Trailing payload of the end frame (an error text for 0x0b).
            var remoteText: String?
            if length > 0, code != FileFrameCode.fileData {
                let extra = length - 1
                if extra > 0 {
                    let payload = try readExactly(extra)
                    if code == FileFrameCode.errorRemote { remoteText = String(decoding: payload, as: UTF8.self) }
                }
            }

            if !failed, let destination {
                let endedCleanly = code == FileFrameCode.success || (code == FileFrameCode.errorRemote && lastCode == FileFrameCode.fileData) || length == 0
                if currentPartial != nil, endedCleanly {
                    do {
                        try commitPartial(to: destination)
                        filesReceived += 1
                    } catch {
                        failed = true
                        let value = errnoValue(of: error)
                        noteWriteFailure(errno: value)
                        errorCode = DeviceErrorCode.from(errno: value)
                        errorText = describe(errno: value)
                        log(.error, "Could not finalize \(relative): \(describe(errno: value))")
                        abort()
                    }
                } else if currentPartial != nil {
                    abort() // data followed by an unexpected end frame: don't keep a truncated file
                    log(.error, "Discarded incomplete \(relative)")
                } else if code == FileFrameCode.success && !wroteAnyData {
                    do {
                        try writeEmptyFile(at: destination)
                        filesReceived += 1
                    } catch {
                        failed = true
                        let value = errnoValue(of: error)
                        noteWriteFailure(errno: value)
                        errorCode = DeviceErrorCode.from(errno: value)
                        errorText = describe(errno: value)
                    }
                } else if code == FileFrameCode.errorRemote {
                    // The device could not read the file: drop the stale copy (like the reference client).
                    try? fm.removeItem(at: destination)
                    log(.info, "Device reported an error for \(relative): \(remoteText ?? "unknown")")
                } else {
                    log(.error, "Unexpected frame code \(code) for \(relative)")
                }
            }

            if failed { break transfer }
            if length == 0 { break transfer }
        }

        abort()
        try transport.sendStatusResponse(code: errorCode, description: errorText, payload: [String: Any]())
    }

    private func noteWriteFailure(errno value: Int32) {
        if value == ENOSPC || value == EDQUOT { diskFull = true }
    }

    private func openPartial(for destination: URL) throws -> PartialFile {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partURL = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + Self.partSuffix)
        try? fm.removeItem(at: partURL)
        guard fm.createFile(atPath: partURL.path, contents: nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
        }
        return PartialFile(handle: try FileHandle(forWritingTo: partURL), partURL: partURL, finalURL: destination)
    }

    private func commitPartial(to destination: URL) throws {
        guard let partial = currentPartial else { return }
        currentPartial = nil
        try partial.handle.close()
        if isDirectory(destination) { try fm.removeItem(at: destination) }
        if rename(partial.partURL.path, destination.path) != 0 {
            let value = errno
            try? fm.removeItem(at: partial.partURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(value))
        }
    }

    private func writeEmptyFile(at destination: URL) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists(destination) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: Data()) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }

    // MARK: - Small request/response messages

    private func sendFreeDiskSpace() throws {
        // Same measure as Finder: includes purgeable APFS space (see `DiskSpace`).
        if let free = DiskSpace.availableBytes(at: root, importantUsage: config.importantUsageSpace, systemFree: config.systemFreeSpace) {
            try transport.sendStatusResponse(code: 0, description: nil, payload: free)
        } else {
            try transport.sendStatusResponse(code: -1, description: nil, payload: UInt64(0))
        }
    }

    private func listDirectory(_ message: DLMessage) throws {
        guard message.items.count > 1, let path = message.items[1] as? String else {
            log(.error, "Malformed DLContentsOfDirectory")
            try transport.sendStatusResponse(code: DeviceErrorCode.generic, description: "Malformed message", payload: [String: Any]())
            return
        }
        var listing: [String: Any] = [:]
        if let url = resolve(path, allowRoot: true),
           let names = try? fm.contentsOfDirectory(atPath: url.path) {
            for name in names {
                let child = url.appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: child.path) else { continue }
                let kind = attributes[.type] as? FileAttributeType
                let type = kind == .typeDirectory ? "DLFileTypeDirectory"
                    : kind == .typeRegular ? "DLFileTypeRegular" : "DLFileTypeUnknown"
                listing[name] = [
                    "DLFileType": type,
                    "DLFileSize": (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                    "DLFileModificationDate": (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0),
                ] as [String: Any]
            }
        }
        try transport.sendStatusResponse(code: 0, description: nil, payload: listing)
    }

    private func createDirectory(_ message: DLMessage) throws {
        var code = 0
        var text: String?
        if message.items.count > 1, let path = message.items[1] as? String, let url = resolve(path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                let value = errnoValue(of: error)
                code = DeviceErrorCode.from(errno: value)
                text = describe(errno: value)
            }
        } else {
            code = DeviceErrorCode.generic
            text = "Invalid path"
        }
        try transport.sendStatusResponse(code: code, description: text, payload: nil)
    }

    private func moveItems(_ message: DLMessage) throws {
        var code = 0
        var text: String?
        if message.items.count > 1, let moves = message.items[1] as? [String: Any] {
            for key in moves.keys.sorted() {
                guard let target = moves[key] as? String else { continue }
                guard let source = resolve(key), let destination = resolve(target) else {
                    code = DeviceErrorCode.generic
                    text = "Invalid path"
                    break
                }
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if exists(destination) { try fm.removeItem(at: destination) }
                    if rename(source.path, destination.path) != 0 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                } catch {
                    let value = errnoValue(of: error)
                    log(.error, "Move \(key) -> \(target) failed: \(describe(errno: value))")
                    code = DeviceErrorCode.from(errno: value)
                    text = describe(errno: value)
                    break
                }
            }
        } else {
            code = DeviceErrorCode.generic
            text = "Malformed message"
        }
        try transport.sendStatusResponse(code: code, description: text, payload: [String: Any]())
    }

    private func removeItems(_ message: DLMessage) throws {
        var code = 0
        var text: String?
        for case let path as String in (message.items.count > 1 ? message.items[1] as? [Any] : nil) ?? [] {
            guard let url = resolve(path) else {
                code = DeviceErrorCode.generic
                text = "Invalid path"
                continue
            }
            guard exists(url) else { continue } // already gone is fine
            do {
                try fm.removeItem(at: url)
            } catch {
                let value = errnoValue(of: error)
                if value == ENOENT { continue }
                log(.error, "Could not remove \(path): \(describe(errno: value))")
                code = DeviceErrorCode.from(errno: value)
                text = describe(errno: value)
            }
        }
        try transport.sendStatusResponse(code: code, description: text, payload: [String: Any]())
    }

    private func copyItem(_ message: DLMessage) throws {
        var code = 0
        var text: String?
        if message.items.count > 2, let from = message.items[1] as? String, let to = message.items[2] as? String {
            if let source = resolve(from), let destination = resolve(to) {
                if exists(source) {
                    do {
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if exists(destination) { try fm.removeItem(at: destination) }
                        try fm.copyItem(at: source, to: destination)
                    } catch {
                        let value = errnoValue(of: error)
                        code = DeviceErrorCode.from(errno: value)
                        text = describe(errno: value)
                    }
                }
            } else {
                code = DeviceErrorCode.generic
                text = "Invalid path"
            }
        }
        try transport.sendStatusResponse(code: code, description: text, payload: [String: Any]())
    }

    private func processMessage(_ message: DLMessage) -> Outcome {
        guard message.items.count > 1, let dict = message.items[1] as? [String: Any] else {
            return .finished(errorCode: -1, description: "Malformed final message from the device")
        }
        let code = (dict["ErrorCode"] as? NSNumber)?.intValue ?? -1
        return .finished(errorCode: code, description: dict["ErrorDescription"] as? String)
    }
}
