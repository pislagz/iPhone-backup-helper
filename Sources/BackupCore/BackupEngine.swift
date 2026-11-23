import Foundation

/// Identifies the device a backup runs against.
public struct BackupTarget: Equatable, Sendable {
    public var udid: String
    public var connection: ConnectionType
    public var destinationRoot: URL
    /// How long to wait for the user to unlock the device (passcode is needed on every backup).
    public var passcodeWaitSeconds: TimeInterval

    public init(
        udid: String,
        connection: ConnectionType,
        destinationRoot: URL = BackupFolder.defaultRoot,
        passcodeWaitSeconds: TimeInterval = 300
    ) {
        self.udid = udid
        self.connection = connection
        self.destinationRoot = destinationRoot
        self.passcodeWaitSeconds = passcodeWaitSeconds
    }
}

public enum BackupPhase: String, Equatable, Sendable {
    case connecting
    case waitingForPasscode
    case transferring
    case finishing
}

public struct BackupProgress: Equatable, Sendable {
    /// 0...1, nil while unknown (e.g. waiting for the passcode).
    public var fraction: Double?
    public var message: String
    public var phase: BackupPhase

    public init(fraction: Double?, message: String, phase: BackupPhase = .transferring) {
        self.fraction = fraction
        self.message = message
        self.phase = phase
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
    /// Finder or another sync holds the device's sync lock.
    case deviceBusy
    /// The user did not unlock the device in time.
    case passcodeTimeout
    case cancelled
    /// The connection to the device dropped (cable pulled, Wi-Fi lost, device locked/asleep for good).
    case deviceDisconnected
    /// The Mac ran out of disk space (or has too little to start).
    case diskFull
    case failed(String)
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "Not implemented"
        case .deviceBusy: return "Device busy: Finder or another app is syncing this iPhone."
        case .passcodeTimeout: return "Waiting for the passcode timed out."
        case .cancelled: return "Backup cancelled."
        case .deviceDisconnected: return "The iPhone was disconnected during the backup."
        case .diskFull: return "The Mac's disk is full."
        case .failed(let reason): return reason
        }
    }
}

/// A way to produce a Finder-compatible MobileSync backup. `LibimobiledeviceBackupEngine`
/// is the shipping implementation; an `AppleMobileBackup` wrapper could be a second one.
public protocol BackupEngine: Sendable {
    /// Runs one backup. Task cancellation cancels the backup cleanly (`BackupError.cancelled`).
    func backup(
        _ target: BackupTarget,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupSummary
}

/// Placeholder engine (used where no real engine is wanted).
public struct UnimplementedBackupEngine: BackupEngine {
    public init() {}

    public func backup(
        _ target: BackupTarget,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        throw BackupError.notImplemented
    }
}

/// Thread-safe cancel flag shared between the async caller and the blocking backup thread.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock(); value = true; lock.unlock()
    }
}
