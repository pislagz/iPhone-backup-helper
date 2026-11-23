import Foundation

/// Reads Finder/iTunes-style backups from `~/Library/Application Support/MobileSync/Backup`.
public struct BackupFolder: Sendable {
    public let root: URL

    public init(root: URL = BackupFolder.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    public func directory(for udid: String) -> URL {
        root.appendingPathComponent(udid, isDirectory: true)
    }

    /// Last successful backup of `udid`, whoever made it (so Finder backups count).
    public func lastBackupDate(udid: String) -> Date? {
        let dir = directory(for: udid)
        let info = try? Data(contentsOf: dir.appendingPathComponent("Info.plist"))
        let status = try? Data(contentsOf: dir.appendingPathComponent("Status.plist"))
        return BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: status)
    }

    public func accessStatus() -> FullDiskAccess.Status {
        FullDiskAccess.status(backupRoot: root)
    }
}

public enum BackupMetadata {
    /// `Info.plist` → "Last Backup Date"; `Status.plist` → "Date" when `SnapshotState` is "finished".
    /// The newest of the two wins.
    public static func lastBackupDate(infoPlist: Data?, statusPlist: Data?) -> Date? {
        var candidates: [Date] = []
        if let info = dictionary(infoPlist), let date = info["Last Backup Date"] as? Date {
            candidates.append(date)
        }
        if let status = dictionary(statusPlist),
           status["SnapshotState"] as? String == "finished",
           let date = status["Date"] as? Date {
            candidates.append(date)
        }
        return candidates.max()
    }

    private static func dictionary(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

/// Detects whether the app may read the TCC-protected MobileSync folder.
public enum FullDiskAccess {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        /// Cannot tell (no backup folder yet and no other protected folder to probe).
        case unknown
    }

    public enum ProbeOutcome: Equatable, Sendable {
        case readable
        case denied
        case missing
        case other
    }

    /// Lists a directory and classifies the result.
    public typealias DirectoryProbe = @Sendable (URL) -> ProbeOutcome

    public static func status(
        backupRoot: URL,
        probe: DirectoryProbe = liveProbe,
        fallbackProbeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari", isDirectory: true)
    ) -> Status {
        switch probe(backupRoot) {
        case .readable: return .granted
        case .denied: return .denied
        case .missing, .other:
            // No backups yet: use another TCC-protected folder that always exists as an indicator.
            switch probe(fallbackProbeURL) {
            case .readable: return .granted
            case .denied: return .denied
            case .missing, .other: return .unknown
            }
        }
    }

    public static let liveProbe: DirectoryProbe = { url in
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return .readable
        } catch {
            return classify(error as NSError)
        }
    }

    public static func classify(_ error: NSError) -> ProbeOutcome {
        let posix: Int32? = {
            if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return Int32(underlying.code)
            }
            return nil
        }()
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError: return .denied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .missing
            default: break
            }
        }
        guard let code = posix else { return .other }
        if code == EPERM || code == EACCES { return .denied }
        if code == ENOENT { return .missing }
        return .other
    }
}
