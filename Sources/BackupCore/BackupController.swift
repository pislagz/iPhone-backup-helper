import Combine
import Foundation

/// User-facing notifications about backups (UNUserNotificationCenter in the app; fakes in tests).
public protocol BackupNotifying: AnyObject {
    func backupStarted(deviceName: String)
    func backupNeedsPasscode(deviceName: String)
    func backupFinished(deviceName: String, duration: TimeInterval, bytes: Int64)
    func backupFailed(deviceName: String, reason: String)
}

/// A backup that is running right now.
public struct BackupJob: Equatable, Sendable {
    public var udid: String
    public var deviceName: String
    public var phase: BackupPhase
    /// 0...1; nil while unknown.
    public var fraction: Double?
    public var message: String
    public var startedAt: Date
}

/// How the last backup attempt of a device ended (shown in the menu until the next attempt).
public struct BackupResult: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case success(bytes: Int64)
        case failed(String)
        case cancelled
        case deviceBusy
        case passcodeTimeout
    }

    public var kind: Kind
    public var finishedAt: Date
    public var duration: TimeInterval

    public var isProblem: Bool {
        switch kind {
        case .success, .cancelled: return false
        case .failed, .deviceBusy, .passcodeTimeout: return true
        }
    }

    public var text: String {
        switch kind {
        case .success: return "Backup finished"
        case .failed(let reason): return "Backup failed: \(reason)"
        case .cancelled: return "Backup cancelled"
        case .deviceBusy: return "Device busy (Finder or another app is syncing). Try again later."
        case .passcodeTimeout: return "Backup stopped: the iPhone was not unlocked in time."
        }
    }
}

/// Runs manual backups: one per device at a time, keeps the Mac awake, reports progress/results and
/// sends notifications. Manual "Back up now" and the scheduler use the same `start` entry point.
@MainActor
public final class BackupController: ObservableObject {
    @Published public private(set) var jobs: [String: BackupJob] = [:]
    @Published public private(set) var results: [String: BackupResult] = [:]

    public var onFinished: (() -> Void)?

    private let engine: BackupEngine
    private let notifier: BackupNotifying?
    private let sleepBlocker: SleepBlocking?
    private let destinationRoot: URL
    private let passcodeWaitSeconds: TimeInterval
    private let passcodeWaitProvider: ((String) -> TimeInterval)?
    private let clock: @Sendable () -> Date
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Devices whose "unlock your iPhone" notification was already posted in the current run.
    private var passcodeNotified: Set<String> = []

    public init(
        engine: BackupEngine = LibimobiledeviceBackupEngine(),
        notifier: BackupNotifying? = nil,
        sleepBlocker: SleepBlocking? = IOKitSleepBlocker(),
        destinationRoot: URL = BackupFolder.defaultRoot,
        passcodeWaitSeconds: TimeInterval = 300,
        passcodeWaitProvider: ((String) -> TimeInterval)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.notifier = notifier
        self.sleepBlocker = sleepBlocker
        self.destinationRoot = destinationRoot
        self.passcodeWaitSeconds = passcodeWaitSeconds
        self.passcodeWaitProvider = passcodeWaitProvider
        self.clock = clock
    }

    public func isRunning(_ udid: String) -> Bool { jobs[udid] != nil }

    /// A backup can start when the device is reachable and healthy and none runs for it already.
    public func canStart(_ device: DeviceState) -> Bool {
        device.isReachable && device.issue == nil && jobs[device.udid] == nil
    }

    @discardableResult
    public func start(_ device: DeviceState) -> Bool {
        guard canStart(device), let connection = device.preferredConnection else { return false }
        let udid = device.udid
        let name = device.name
        let startedAt = clock()
        if jobs.isEmpty { sleepBlocker?.begin(reason: "Backing up an iPhone") }
        results[udid] = nil
        passcodeNotified.remove(udid)
        jobs[udid] = BackupJob(
            udid: udid, deviceName: name, phase: .connecting, fraction: nil,
            message: "Connecting…", startedAt: startedAt)
        notifier?.backupStarted(deviceName: name)

        let target = BackupTarget(
            udid: udid, connection: connection, destinationRoot: destinationRoot,
            passcodeWaitSeconds: passcodeWaitProvider?(udid) ?? passcodeWaitSeconds)
        let relay = ProgressRelay()
        let engine = self.engine
        tasks[udid] = Task { [weak self] in
            do {
                let summary = try await engine.backup(target) { progress in
                    relay.push(progress)
                    Task { @MainActor [weak self] in self?.drain(relay, udid: udid) }
                }
                self?.drain(relay, udid: udid)
                self?.finish(udid: udid, name: name, outcome: .success(summary))
            } catch {
                self?.drain(relay, udid: udid)
                self?.finish(udid: udid, name: name, outcome: .failure(error))
            }
        }
        return true
    }

    public func cancel(udid: String) {
        guard jobs[udid] != nil else { return }
        tasks[udid]?.cancel()
        if var job = jobs[udid] {
            job.message = "Cancelling…"
            jobs[udid] = job
        }
    }

    public func cancelAll() {
        for udid in jobs.keys { cancel(udid: udid) }
    }

    // MARK: - Internals

    private func drain(_ relay: ProgressRelay, udid: String) {
        for progress in relay.take() { apply(progress, udid: udid) }
    }

    private func apply(_ progress: BackupProgress, udid: String) {
        guard var job = jobs[udid] else { return }
        job.phase = progress.phase
        job.fraction = progress.fraction
        job.message = progress.message
        jobs[udid] = job
        // At most one passcode notification per run, even when the device asks again.
        if progress.phase == .waitingForPasscode, passcodeNotified.insert(udid).inserted {
            notifier?.backupNeedsPasscode(deviceName: job.deviceName)
        }
    }

    private func finish(udid: String, name: String, outcome: Result<BackupSummary, Error>) {
        let started = jobs[udid]?.startedAt ?? clock()
        let finished = clock()
        let duration = finished.timeIntervalSince(started)
        let kind: BackupResult.Kind
        switch outcome {
        case .success(let summary):
            kind = .success(bytes: summary.bytesWritten)
            notifier?.backupFinished(deviceName: name, duration: summary.duration, bytes: summary.bytesWritten)
        case .failure(let error):
            switch error as? BackupError {
            case .cancelled?: kind = .cancelled
            case .deviceBusy?:
                kind = .deviceBusy
                notifier?.backupFailed(deviceName: name, reason: BackupResult(kind: kind, finishedAt: finished, duration: duration).text)
            case .passcodeTimeout?:
                kind = .passcodeTimeout
                notifier?.backupFailed(deviceName: name, reason: BackupResult(kind: kind, finishedAt: finished, duration: duration).text)
            default:
                let reason = (error as? BackupError)?.errorDescription ?? error.localizedDescription
                kind = .failed(reason)
                notifier?.backupFailed(deviceName: name, reason: reason)
            }
        }
        results[udid] = BackupResult(kind: kind, finishedAt: finished, duration: duration)
        jobs[udid] = nil
        tasks[udid] = nil
        passcodeNotified.remove(udid)
        if jobs.isEmpty { sleepBlocker?.end() }
        onFinished?()
    }
}

/// Hands progress from the backup thread to the main actor in order.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [BackupProgress] = []

    func push(_ progress: BackupProgress) {
        lock.lock(); pending.append(progress); lock.unlock()
    }

    func take() -> [BackupProgress] {
        lock.lock(); defer { lock.unlock() }
        let result = pending
        pending = []
        return result
    }
}
