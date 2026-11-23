import Foundation

/// Identifies the device a backup runs against.
public struct BackupTarget: Equatable, Sendable {
    public var udid: String
    public var connection: ConnectionType
    public var destinationRoot: URL

    public init(udid: String, connection: ConnectionType, destinationRoot: URL = BackupFolder.defaultRoot) {
        self.udid = udid
        self.connection = connection
        self.destinationRoot = destinationRoot
    }
}

public struct BackupProgress: Equatable, Sendable {
    /// 0...1, nil while unknown (e.g. waiting for the passcode).
    public var fraction: Double?
    public var message: String

    public init(fraction: Double?, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public struct BackupSummary: Equatable, Sendable {
    public var duration: TimeInterval
    public var bytesWritten: Int64

    public init(duration: TimeInterval, bytesWritten: Int64) {
        self.duration = duration
        self.bytesWritten = bytesWritten
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case notImplemented
    case deviceBusy
    case passcodeTimeout
    case cancelled
    case failed(String)
}

/// A way to produce a Finder-compatible MobileSync backup. M2 adds the libimobiledevice
/// mobilebackup2 implementation; an `AppleMobileBackup` wrapper could be a second one.
public protocol BackupEngine: Sendable {
    func backup(
        _ target: BackupTarget,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupSummary
}

/// Placeholder until M2.
public struct UnimplementedBackupEngine: BackupEngine {
    public init() {}

    public func backup(
        _ target: BackupTarget,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        throw BackupError.notImplemented
    }
}
