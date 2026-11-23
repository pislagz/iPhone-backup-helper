import Foundation

public struct BackupRunnerConfig: Sendable {
    /// The AFC sync lock is retried this many times, `lockRetryDelay` apart, before reporting "Device busy".
    public var lockAttempts = 25
    public var lockRetryDelay: TimeInterval = 0.2
    /// iOS 16.1+ asks for the passcode at the start of every backup. When the prompt notification never
    /// arrives, the device is treated as "waiting for the passcode" after this long without any message.
    public var passcodeFallbackAfter: TimeInterval = 10
    public var handler = BackupMessageHandler.Config()

    public init() {}
}

/// One backup run over an already connected `BackupDeviceSession`: sync lock, Info.plist, the
/// "Backup" request, the DeviceLink message loop, passcode wait and cancellation.
public final class BackupRunner {
    private let session: BackupDeviceSession
    private let target: BackupTarget
    private let config: BackupRunnerConfig
    private let cancel: CancellationFlag
    private let now: () -> Date
    private let log: BackupLogger
    private let progress: @Sendable (BackupProgress) -> Void
    private let events = EventState()

    private var lastReport: BackupProgress?

    public init(
        session: BackupDeviceSession,
        target: BackupTarget,
        config: BackupRunnerConfig = BackupRunnerConfig(),
        cancel: CancellationFlag = CancellationFlag(),
        now: @escaping () -> Date = { Date() },
        log: @escaping BackupLogger = { _, _ in },
        progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }
    ) {
        self.session = session
        self.target = target
        self.config = config
        self.cancel = cancel
        self.now = now
        self.log = log
        self.progress = progress
    }

    public func run() throws -> BackupSummary {
        let started = now()
        let udid = target.udid
        let fm = FileManager.default
        report(nil, "Connecting…", .connecting)
        try checkCancelled()

        session.setEventHandler { [events] event in events.apply(event) }

        try session.acquireSyncLock(attempts: config.lockAttempts, retryDelay: config.lockRetryDelay)
        defer { session.releaseSyncLock() }
        try checkCancelled()

        // Backup folder + Info.plist.
        let udidDir = target.destinationRoot.appendingPathComponent(udid, isDirectory: true)
        do {
            try fm.createDirectory(at: udidDir, withIntermediateDirectories: true)
        } catch {
            throw BackupError.failed("Cannot write to the backup folder (\(error.localizedDescription)). Is Full Disk Access granted?")
        }
        BackupMessageHandler.sweepStaleParts(in: udidDir)
        let infoURL = udidDir.appendingPathComponent("Info.plist")
        let existing = InfoPlistBuilder.parse(try? Data(contentsOf: infoURL))
        let previousDate = existing?["Last Backup Date"] as? Date
        var iTunesFiles: [String: Data] = [:]
        for name in InfoPlistBuilder.iTunesFileNames {
            if let data = session.readDeviceFile("/iTunes_Control/iTunes/" + name, maxBytes: 4_000_000) {
                iTunesFiles[name] = data
            }
        }
        let iBooks = session.readDeviceFile("/Books/iBooksData2.plist", maxBytes: 4_000_000)
        func writeInfo(date: Date?) throws {
            let info = InfoPlistBuilder.build(
                udid: udid,
                existing: InfoPlistBuilder.parse(try? Data(contentsOf: infoURL)) ?? existing,
                lockdown: session.lockdownInfo,
                iTunesFiles: iTunesFiles,
                iBooksData: iBooks,
                lastBackupDate: date)
            do { try InfoPlistBuilder.write(info, to: infoURL) } catch {
                throw BackupError.failed("Cannot write Info.plist: \(error.localizedDescription)")
            }
        }
        // Like Finder, write Info.plist before the backup starts, but keep the previous
        // "Last Backup Date" until this run succeeded (a failed run must not look like a success).
        try writeInfo(date: previousDate)
        try checkCancelled()

        log(.info, "Requesting \(session.willEncrypt ? "encrypted" : "unencrypted") backup")
        try session.requestBackup(udid: udid)
        let requestSent = now()

        let handler = BackupMessageHandler(
            root: target.destinationRoot,
            transport: session,
            config: config.handler,
            isCancelled: { [cancel, events] in cancel.isCancelled || events.deviceCancelled },
            now: now,
            log: log)

        let expectsPasscode = Self.versionAtLeast(session.productVersion, major: 16, minor: 1)
        var firstMessageSeen = false
        var waitingSince: Date?
        var result: (code: Int, description: String?)?

        func updatePasscodeState() throws {
            let current = now()
            let active = events.passcodeVisible
                || (!firstMessageSeen && expectsPasscode && current.timeIntervalSince(requestSent) >= config.passcodeFallbackAfter)
            if active {
                if waitingSince == nil {
                    waitingSince = current
                    log(.info, "Waiting for the passcode on the device")
                    report(nil, "Unlock your iPhone and enter its passcode", .waitingForPasscode)
                } else if let since = waitingSince, current.timeIntervalSince(since) >= target.passcodeWaitSeconds {
                    log(.error, "Passcode wait timed out after \(Int(target.passcodeWaitSeconds)) s")
                    throw BackupError.passcodeTimeout
                }
            } else if waitingSince != nil {
                waitingSince = nil
                log(.info, "Passcode entered")
                report(handler.progressPercent.map { $0 / 100 }, "Backing up…", .transferring)
            }
        }

        do {
            loop: while true {
                try checkCancelled()
                try updatePasscodeState()
                switch try session.receiveMessage() {
                case .timeout:
                    continue
                case .message(let message):
                    if !firstMessageSeen {
                        firstMessageSeen = true
                        events.clearPasscode() // the device is talking: whatever it showed is done
                    }
                    let outcome = try handler.handle(message)
                    try updatePasscodeState()
                    if waitingSince == nil {
                        report(handler.progressPercent.map { $0 / 100 }, "Backing up…", .transferring)
                    }
                    switch outcome {
                    case .continue: break
                    case .disconnect: break loop
                    case .finished(let code, let text):
                        result = (code, text)
                        break loop
                    }
                }
            }
        } catch {
            handler.abort()
            if case TransportError.connectionLost(let detail) = error {
                log(.error, "Connection lost: \(detail)")
                throw BackupError.failed("Lost the connection to the iPhone.")
            }
            throw error
        }
        handler.abort()

        guard let result else {
            throw BackupError.failed("The iPhone closed the connection before the backup finished.")
        }
        guard result.code == 0 else {
            let detail = result.description.map { ": \($0)" } ?? ""
            throw BackupError.failed("The iPhone reported error \(result.code)\(detail)")
        }
        let status = try? Data(contentsOf: udidDir.appendingPathComponent("Status.plist"))
        guard BackupMetadata.isFinished(statusPlist: status) else {
            throw BackupError.failed("The iPhone finished, but the backup is not marked complete (Status.plist).")
        }

        report(1, "Finishing…", .finishing)
        let finished = now()
        try writeInfo(date: finished)
        let summary = BackupSummary(duration: finished.timeIntervalSince(started), bytesWritten: handler.bytesReceived)
        log(.info, "Backup finished: \(handler.filesReceived) files, \(summary.bytesWritten) bytes, \(Int(summary.duration)) s")
        return summary
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        if events.deviceCancelled {
            log(.info, "Cancelled on the iPhone")
            throw BackupError.cancelled
        }
        if cancel.isCancelled { throw BackupError.cancelled }
    }

    private func report(_ fraction: Double?, _ message: String, _ phase: BackupPhase) {
        let value = BackupProgress(fraction: fraction.map { max(0, min(1, $0)) }, message: message, phase: phase)
        if let last = lastReport, last.phase == value.phase, last.message == value.message {
            if last.fraction == value.fraction { return }
            if let a = last.fraction, let b = value.fraction, abs(a - b) < 0.001 { return }
        }
        lastReport = value
        progress(value)
    }

    static func versionAtLeast(_ version: String?, major: Int, minor: Int) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        guard let first = parts.first else { return false }
        let second = parts.count > 1 ? parts[1] : 0
        return first > major || (first == major && second >= minor)
    }

    private final class EventState: @unchecked Sendable {
        private let lock = NSLock()
        private var passcode = false
        private var cancelled = false

        var passcodeVisible: Bool { lock.lock(); defer { lock.unlock() }; return passcode }
        var deviceCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func clearPasscode() { lock.lock(); passcode = false; lock.unlock() }

        func apply(_ event: SessionEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .passcodePromptShown: passcode = true
            case .passcodePromptDismissed: passcode = false
            case .cancelRequestedOnDevice: cancelled = true
            }
        }
    }
}

/// The shipping engine: libimobiledevice session + our own mobilebackup2 client loop.
public struct LibimobiledeviceBackupEngine: BackupEngine {
    private let factory: BackupSessionFactory
    private let config: BackupRunnerConfig
    private let log: BackupLogger

    public init(
        factory: BackupSessionFactory = NativeBackupSessionFactory(),
        config: BackupRunnerConfig = BackupRunnerConfig(),
        log: @escaping BackupLogger = AppLog.shared.logger(category: "backup")
    ) {
        self.factory = factory
        self.config = config
        self.log = log
    }

    public func backup(
        _ target: BackupTarget,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) async throws -> BackupSummary {
        let flag = CancellationFlag()
        let factory = self.factory, config = self.config, log = self.log
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.runBlocking(factory: factory, config: config, log: log, target: target, flag: flag, progress: progress)
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private static func runBlocking(
        factory: BackupSessionFactory,
        config: BackupRunnerConfig,
        log: @escaping BackupLogger,
        target: BackupTarget,
        flag: CancellationFlag,
        progress: @escaping @Sendable (BackupProgress) -> Void
    ) throws -> BackupSummary {
        let tag = String(target.udid.prefix(8))
        log(.info, "Backup of \(tag) starting (\(target.connection.rawValue))")
        do {
            if flag.isCancelled { throw BackupError.cancelled }
            let session = try factory.openSession(for: target)
            defer { session.close() }
            let runner = BackupRunner(
                session: session, target: target, config: config, cancel: flag, log: log, progress: progress)
            return try runner.run()
        } catch let error as BackupError {
            log(error == .cancelled ? .info : .error, "Backup of \(tag) ended: \(error.errorDescription ?? "\(error)")")
            throw error
        } catch {
            log(.error, "Backup of \(tag) failed: \(error)")
            throw BackupError.failed(error.localizedDescription)
        }
    }
}
