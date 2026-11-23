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
    /// Date of the last *successful* backup.
    ///
    /// `Status.plist` is the source of truth: the device writes `SnapshotState` = "finished" and
    /// "Date" only when a backup completed. `Info.plist` ("Last Backup Date") is written by
    /// Finder/idevicebackup2 at the *start* of a backup, so it must not count as success.
    /// - Status.plist readable and finished (with a date) → that date.
    /// - Status.plist readable but not finished (failed/in-progress backup) → nil.
    /// - Status.plist missing/unreadable (or finished without a date) → Info.plist's date, if any.
    public static func lastBackupDate(infoPlist: Data?, statusPlist: Data?) -> Date? {
        if let status = dictionary(statusPlist) {
            if status["SnapshotState"] as? String == "finished" {
                if let date = status["Date"] as? Date { return date }
            } else {
                return nil
            }
        }
        return dictionary(infoPlist)?["Last Backup Date"] as? Date
    }

    /// True when Status.plist says the snapshot is complete.
    public static func isFinished(statusPlist: Data?) -> Bool {
        dictionary(statusPlist)?["SnapshotState"] as? String == "finished"
    }

    static func dictionary(_ data: Data?) -> [String: Any]? {
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
