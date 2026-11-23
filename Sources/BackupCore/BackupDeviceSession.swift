import Foundation

/// Asynchronous things that happen on the device while a backup runs.
public enum SessionEvent: Equatable, Sendable {
    /// The device shows its passcode prompt (`com.apple.LocalAuthentication.ui.presented`).
    case passcodePromptShown
    case passcodePromptDismissed
    /// The user cancelled the sync on the iPhone (`com.apple.itunes-client.syncCancelRequest`).
    case cancelRequestedOnDevice
}

/// Everything the backup runner needs from a connected device. The real one is `NativeBackupSession`
/// (libimobiledevice); tests provide a fake that also acts as the mobilebackup2 transport.
public protocol BackupDeviceSession: MobileBackup2Transport {
    /// iOS version string (e.g. "17.5.1") for feature checks.
    var productVersion: String? { get }
    var willEncrypt: Bool { get }
    var lockdownInfo: LockdownBackupInfo { get }

    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void)
    /// Reads a small file over AFC (nil if missing).
    func readDeviceFile(_ path: String, maxBytes: Int) -> Data?
    /// Posts syncWillStart, takes the AFC lock `/com.apple.itunes.lock_sync` exclusively and posts
    /// syncDidStart. Throws `BackupError.deviceBusy` when somebody else holds the lock.
    func acquireSyncLock(attempts: Int, retryDelay: TimeInterval) throws
    /// Unlocks and posts syncDidFinish. Safe to call more than once.
    func releaseSyncLock()
    /// mobilebackup2 "Backup" request for this device.
    func requestBackup(udid: String) throws
    /// Disconnects and frees everything. Safe to call more than once.
    func close()
}

public protocol BackupSessionFactory: Sendable {
    /// Connects to the device (blocking).
    func openSession(for target: BackupTarget) throws -> BackupDeviceSession
}
