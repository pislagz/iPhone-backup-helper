import Foundation
@testable import BackupCore

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ibh-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

func be32(_ value: Int) -> Data {
    var big = UInt32(value).bigEndian
    return Data(bytes: &big, count: 4)
}

/// Raw stream builders for DLMessageUploadFiles (device → computer).
enum Stream {
    static func name(_ text: String) -> Data { be32(text.utf8.count) + Data(text.utf8) }

    /// One file: device name, backup path, data frames, success end frame.
    static func file(deviceName: String = "dev", path: String, chunks: [Data], end: UInt8 = 0x00, endText: String? = nil) -> Data {
        var out = name(deviceName) + name(path)
        for chunk in chunks { out += be32(chunk.count + 1) + Data([0x0c]) + chunk }
        let text = Data((endText ?? "").utf8)
        out += be32(text.count + 1) + Data([end]) + text
        return out
    }

    /// A file the device could not read: error frame right away.
    static func unreadable(path: String, text: String) -> Data {
        name("dev") + name(path) + be32(text.utf8.count + 1) + Data([0x0b]) + Data(text.utf8)
    }

    static let terminator = be32(0)
}

struct SentStatus {
    var code: Int
    var description: String?
    var payload: Any?
}

class FakeTransport: MobileBackup2Transport {
    var rawInput = Data()
    var sentRaw = Data()
    var statuses: [SentStatus] = []
    var messages: [TransportReceive] = []
    /// When set, reading raw data after the scripted bytes ran out is a lost connection (cable pulled).
    var disconnectWhenRawRunsOut = false

    func receiveMessage() throws -> TransportReceive {
        if messages.isEmpty { throw TransportError.connectionLost("script exhausted") }
        return messages.removeFirst()
    }

    func sendStatusResponse(code: Int, description: String?, payload: Any?) throws {
        statuses.append(SentStatus(code: code, description: description, payload: payload))
    }

    func sendRaw(_ data: Data) throws { sentRaw.append(data) }

    func receiveRaw(_ count: Int) throws -> Data {
        if rawInput.isEmpty, disconnectWhenRawRunsOut { throw TransportError.connectionLost("cable pulled") }
        let n = min(count, rawInput.count)
        let out = rawInput.prefix(n)
        rawInput.removeFirst(n)
        return Data(out)
    }
}

/// Scripted device for `BackupRunner` tests.
final class FakeSession: FakeTransport, BackupDeviceSession {
    enum Step {
        /// Deliver `message`; `raw` is appended to the raw stream first (UploadFiles payload).
        case message(DLMessage, raw: Data)
        case timeout(advance: TimeInterval)
        case event(SessionEvent)
        case run(() -> Void)
    }

    var script: [Step] = []
    var productVersion: String? = "17.5"
    var willEncrypt = false
    var lockdownInfo = LockdownBackupInfo(
        global: ["DeviceName": "Anna's iPhone", "ProductVersion": "17.5", "ProductType": "iPhone15,2",
                 "SerialNumber": "SER123", "BuildVersion": "21F79"],
        iTunesSettings: ["k": "v"], minITunesVersion: "12.0")
    var busy = false
    var onRequestBackup: (() -> Void)?
    var deviceFiles: [String: Data] = [:]
    let clock: FakeClock

    private(set) var calls: [String] = []
    private var handler: (@Sendable (SessionEvent) -> Void)?

    init(clock: FakeClock) { self.clock = clock }

    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) { self.handler = handler }
    func readDeviceFile(_ path: String, maxBytes: Int) -> Data? { deviceFiles[path] }

    func acquireSyncLock(attempts: Int, retryDelay: TimeInterval) throws {
        calls.append("lock")
        if busy { throw BackupError.deviceBusy }
    }

    func releaseSyncLock() { calls.append("unlock") }

    func requestBackup(udid: String) throws {
        calls.append("request:\(udid)")
        onRequestBackup?()
    }

    func close() { calls.append("close") }

    override func receiveMessage() throws -> TransportReceive {
        while !script.isEmpty {
            switch script.removeFirst() {
            case .message(let message, let raw):
                rawInput.append(raw)
                return .message(message)
            case .timeout(let seconds):
                clock.advance(seconds)
                return .timeout
            case .event(let event):
                handler?(event)
            case .run(let block):
                block()
            }
        }
        throw TransportError.connectionLost("script exhausted")
    }
}

func plistData(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
}

func statusPlist(state: String, date: Date = Date()) throws -> Data {
    try plistData(["SnapshotState": state, "Date": date, "Version": "3.3", "UUID": "X"] as [String: Any])
}
