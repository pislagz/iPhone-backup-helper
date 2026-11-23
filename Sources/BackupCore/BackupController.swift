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
        /// The Mac ran out of disk space.
        case diskFull
        /// The iPhone went away mid-backup (cable, Wi-Fi, ...).
        case disconnected
        /// Stopped on purpose by the app itself (Mac going to sleep, app quitting). Not a failure.
        case interrupted(String)
    }

    public var kind: Kind
    public var finishedAt: Date
    public var duration: TimeInterval

    public var isProblem: Bool {
        switch kind {
        case .success, .cancelled, .interrupted: return false
        case .failed, .deviceBusy, .passcodeTimeout, .diskFull, .disconnected: return true
        }
    }

    /// Whether the scheduler should wait for its retry interval before trying again.
    public var gatesRetry: Bool {
        switch kind {
        case .success, .interrupted: return false
        case .failed, .cancelled, .deviceBusy, .passcodeTimeout, .diskFull, .disconnected: return true
        }
    }

    public var text: String {
        switch kind {
        case .success: return "Backup finished"
        case .failed(let reason): return "Backup failed: \(reason)"
        case .cancelled: return "Backup cancelled"
        case .deviceBusy: return "Device busy (Finder or another app is syncing). Will try again later."
        case .passcodeTimeout: return "Backup stopped: the iPhone was not unlocked in time."
        case .diskFull: return "Backup stopped: the Mac's disk is full. Free up space; the next try is automatic."
        case .disconnected: return "The iPhone was disconnected during the backup. Will try again when it is back."
        case .interrupted(let why): return "Backup interrupted: \(why)"
        }
    }
}

/// Why the app itself stopped a running backup (the engine only reports "cancelled").
enum AbortReason: Equatable {
    case user
    case deviceGone
    case macSleep
    case appQuit
}

/// Runs backups: at most `maxConcurrent` (default 1) at a time, the rest wait in a FIFO queue. Manual
/// "Back up now" and the scheduler use the same `start` entry point. Keeps the Mac awake while anything
/// runs, reports progress/results, sends notifications and remembers our own successes/failures.
@MainActor
public final class BackupController: ObservableObject {
    @Published public private(set) var jobs: [String: BackupJob] = [:]
    @Published public private(set) var results: [String: BackupResult] = [:]
    /// UDIDs waiting for their turn, first in line first.
    @Published public private(set) var queue: [String] = []

    public var onFinished: (() -> Void)?
    /// Current state of a device (the monitor's list); lets the controller notice a device that left
    /// and re-check a queued device when its turn comes.
    public var deviceLookup: ((String) -> DeviceState?)?

    private let engine: BackupEngine
    private let notifier: BackupNotifying?
    private let sleepBlocker: SleepBlocking?
    private let history: BackupHistoryStore
    private let destinationRoot: URL
    private let passcodeWaitSeconds: TimeInterval
    private let passcodeWaitProvider: ((String) -> TimeInterval)?
    private let maxConcurrent: Int
    private let disconnectGrace: TimeInterval
    private let clock: @Sendable () -> Date
    private var tasks: [String: Task<Void, Never>] = [:]
    private var queuedDevices: [String: DeviceState] = [:]
    private var abortReasons: [String: AbortReason] = [:]
    /// Running jobs whose device is currently missing from the device list (value = check token).
    private var missingSince: [String: UUID] = [:]
    private var sleepBlocked = false
    private var shuttingDown = false
    /// Devices whose "unlock your iPhone" notification was already posted in the current run.
    private var passcodeNotified: Set<String> = []

    private static let log = AppLog.shared.logger(category: "controller")

    public init(
        engine: BackupEngine = LibimobiledeviceBackupEngine(),
        notifier: BackupNotifying? = nil,
        sleepBlocker: SleepBlocking? = IOKitSleepBlocker(),
        history: BackupHistoryStore? = nil,
        destinationRoot: URL = BackupFolder.defaultRoot,
        passcodeWaitSeconds: TimeInterval = 300,
        passcodeWaitProvider: ((String) -> TimeInterval)? = nil,
        maxConcurrent: Int = 1,
        disconnectGrace: TimeInterval = 15,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.notifier = notifier
        self.sleepBlocker = sleepBlocker
        self.history = history ?? BackupHistoryStore(fileURL: nil)
        self.destinationRoot = destinationRoot
        self.passcodeWaitSeconds = passcodeWaitSeconds
        self.passcodeWaitProvider = passcodeWaitProvider
        self.maxConcurrent = max(1, maxConcurrent)
        self.disconnectGrace = disconnectGrace
        self.clock = clock
    }

    public func isRunning(_ udid: String) -> Bool { jobs[udid] != nil }
    public func isQueued(_ udid: String) -> Bool { queuedDevices[udid] != nil }
    /// 1 = next in line.
    public func queuePosition(_ udid: String) -> Int? { queue.firstIndex(of: udid).map { $0 + 1 } }
    /// True while a backup runs or waits (used to warn before quitting).
    public var isBusy: Bool { !jobs.isEmpty || !queue.isEmpty }

    /// A backup can start (or queue) when the device is reachable and healthy and nothing runs or waits for it.
    public func canStart(_ device: DeviceState) -> Bool {
        refusal(for: device) == nil
    }

    /// Why `start` would refuse this device, in words for the menu; nil when it would accept.
    public func refusal(for device: DeviceState) -> String? {
        if shuttingDown { return "Waiting: the app is quitting" }
        if jobs[device.udid] != nil { return "Backup in progress" }
        if queuedDevices[device.udid] != nil { return "Queued" }
        if !device.isReachable { return "Waiting: iPhone not connected" }
        if let issue = device.issue {
            switch issue {
            case .needsTrust: return "Waiting: trust this Mac on the iPhone"
            case .locked: return "Waiting: unlock the iPhone"
            case .unreachable: return "Waiting: iPhone not responding"
            }
        }
        if device.preferredConnection == nil { return "Waiting: no usable connection to the iPhone" }
        return nil
    }

    /// Starts the backup now, or queues it when another device is being backed up. Returns false when
    /// the device cannot be backed up right now (see `refusal(for:)`).
    @discardableResult
    public func start(_ device: DeviceState) -> Bool {
        guard canStart(device) else { return false }
        if jobs.count < maxConcurrent {
            launch(device)
        } else {
            queue.append(device.udid)
            queuedDevices[device.udid] = device
            results[device.udid] = nil
            Self.log(.info, "backup of \(device.udid.prefix(8)) queued (position \(queue.count))")
        }
        return true
    }

    /// Cancels a running backup, or takes a queued one out of the queue.
    public func cancel(udid: String) {
        if queuedDevices[udid] != nil {
            dequeue(udid)
            return
        }
        abort(udid, reason: .user)
    }

    public func cancelAll() {
        queue.removeAll()
        queuedDevices.removeAll()
        for udid in Array(jobs.keys) { abort(udid, reason: .user) }
    }

    /// Call when the device list changed. A running backup whose device stays gone for
    /// `disconnectGrace` seconds is aborted (a hung Wi-Fi connection would otherwise wait for timeouts).
    public func deviceListChanged() {
        guard let lookup = deviceLookup else { return }
        for udid in Array(jobs.keys) {
            guard let device = lookup(udid) else { continue }
            if device.isReachable {
                missingSince[udid] = nil
            } else if missingSince[udid] == nil {
                let token = UUID()
                missingSince[udid] = token
                let grace = disconnectGrace
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                    self?.graceExpired(udid: udid, token: token)
                }
            }
        }
    }

    /// The Mac is about to sleep: stop everything (the connections will not survive) and forget the
    /// queue. The scheduler starts again after wake once the device list is fresh.
    public func suspendForSleep() {
        guard isBusy else { return }
        Self.log(.info, "Mac is going to sleep: stopping backups")
        queue.removeAll()
        queuedDevices.removeAll()
        for udid in Array(jobs.keys) { abort(udid, reason: .macSleep) }
    }

    /// The app is quitting: drop the queue, cancel what runs and wait (up to `timeout` seconds) until the
    /// engines have cleaned up and released the device sync locks. Returns true when everything stopped.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 20) async -> Bool {
        shuttingDown = true
        queue.removeAll()
        queuedDevices.removeAll()
        for udid in Array(jobs.keys) { abort(udid, reason: .appQuit) }
        let deadline = Date().addingTimeInterval(timeout)
        while !jobs.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return jobs.isEmpty
    }

    // Persisted knowledge about our own attempts (the scheduler merges it with the Status.plist date).

    /// When a backup made by this app last finished successfully (survives app restarts).
    public func lastSuccess(for udid: String) -> Date? { history.history(for: udid).lastSuccess }

    /// When the last attempt that should delay the next automatic try ended (survives app restarts).
    public func lastFailedAttempt(for udid: String) -> Date? { history.history(for: udid).lastFailedAttempt }

    public func forgetHistory(udid: String) {
        history.forget(udid)
        results[udid] = nil
    }

    // MARK: - Internals

    private func launch(_ device: DeviceState) {
        guard let connection = device.preferredConnection else { return }
        let udid = device.udid
        let name = device.name
        let startedAt = clock()
        if !sleepBlocked {
            sleepBlocker?.begin(reason: "Backing up an iPhone")
            sleepBlocked = true
        }
        results[udid] = nil
        passcodeNotified.remove(udid)
        abortReasons[udid] = nil
        missingSince[udid] = nil
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
    }

    private func dequeue(_ udid: String) {
        queue.removeAll { $0 == udid }
        queuedDevices[udid] = nil
    }

    private func abort(_ udid: String, reason: AbortReason) {
        guard var job = jobs[udid] else { return }
        if abortReasons[udid] == nil { abortReasons[udid] = reason }
        tasks[udid]?.cancel()
        job.message = reason == .deviceGone ? "iPhone disconnected, stopping…" : "Cancelling…"
        jobs[udid] = job
    }

    private func graceExpired(udid: String, token: UUID) {
        guard missingSince[udid] == token, jobs[udid] != nil else { return }
        missingSince[udid] = nil
        if let device = deviceLookup?(udid), !device.isReachable {
            Self.log(.info, "device \(udid.prefix(8)) left during the backup: aborting")
            abort(udid, reason: .deviceGone)
        }
    }

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
        let reason = abortReasons.removeValue(forKey: udid)
        let kind: BackupResult.Kind
        var notifyFailure = true
        switch outcome {
        case .success(let summary):
            kind = .success(bytes: summary.bytesWritten)
            notifier?.backupFinished(deviceName: name, duration: summary.duration, bytes: summary.bytesWritten)
            notifyFailure = false
        case .failure(let error):
            let backupError = error as? BackupError
            switch (reason, backupError) {
            case (.macSleep?, _):
                kind = .interrupted("the Mac went to sleep. It will start again after wake-up if it is still due.")
                notifyFailure = false
            case (.appQuit?, _):
                kind = .interrupted("the app was quit.")
                notifyFailure = false
            case (.deviceGone?, _), (_, .deviceDisconnected?):
                kind = .disconnected
            case (_, .cancelled?):
                kind = .cancelled
                notifyFailure = false
            case (_, .deviceBusy?): kind = .deviceBusy
            case (_, .passcodeTimeout?): kind = .passcodeTimeout
            case (_, .diskFull?): kind = .diskFull
            default:
                kind = .failed(backupError?.errorDescription ?? error.localizedDescription)
            }
        }
        let result = BackupResult(kind: kind, finishedAt: finished, duration: duration)
        if notifyFailure {
            let reasonText: String
            if case .failed(let text) = kind { reasonText = text } else { reasonText = result.text }
            notifier?.backupFailed(deviceName: name, reason: reasonText)
        }
        if case .success = kind {
            history.recordSuccess(udid, at: finished)
        } else if result.gatesRetry {
            history.recordFailure(udid, at: finished)
        }
        Self.log(.info, "backup of \(udid.prefix(8)) ended: \(result.text)")

        results[udid] = result
        jobs[udid] = nil
        tasks[udid] = nil
        missingSince[udid] = nil
        passcodeNotified.remove(udid)
        startNext()
        if jobs.isEmpty, sleepBlocked {
            sleepBlocker?.end()
            sleepBlocked = false
        }
        onFinished?()
    }

    /// Starts queued backups while there is room. A device that left while it waited is dropped.
    private func startNext() {
        while jobs.count < maxConcurrent, !queue.isEmpty, !shuttingDown {
            let udid = queue.removeFirst()
            guard let queued = queuedDevices.removeValue(forKey: udid) else { continue }
            let current = deviceLookup?(udid) ?? queued
            if canStartAfterQueue(current) {
                launch(current)
            } else {
                Self.log(.info, "queued backup of \(udid.prefix(8)) dropped: device not ready")
                results[udid] = BackupResult(
                    kind: .failed("the iPhone was not ready when its turn came"), finishedAt: clock(), duration: 0)
            }
        }
    }

    private func canStartAfterQueue(_ device: DeviceState) -> Bool {
        device.isReachable && device.issue == nil && device.preferredConnection != nil && jobs[device.udid] == nil
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
