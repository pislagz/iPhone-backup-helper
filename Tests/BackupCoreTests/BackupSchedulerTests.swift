import XCTest
@testable import BackupCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

private actor Gate {
    private var open = false
    func wait() async {
        while !open {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func release() { open = true }
}

/// Fake engine: records every target and either holds the backup open, fails, or succeeds.
private final class RecordingEngine: BackupEngine, @unchecked Sendable {
    enum Behavior { case succeed, fail, hold }
    private let lock = NSLock()
    private var _targets: [BackupTarget] = []
    private var _behavior: Behavior = .succeed
    let gate = Gate()

    var targets: [BackupTarget] { lock.lock(); defer { lock.unlock() }; return _targets }
    var behavior: Behavior {
        get { lock.lock(); defer { lock.unlock() }; return _behavior }
        set { lock.lock(); _behavior = newValue; lock.unlock() }
    }

    func backup(_ target: BackupTarget, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupSummary {
        lock.lock(); _targets.append(target); let behavior = _behavior; lock.unlock()
        switch behavior {
        case .succeed: return BackupSummary(duration: 1, bytesWritten: 10)
        case .fail: throw BackupError.failed("boom")
        case .hold:
            await gate.wait()
            if Task.isCancelled { throw BackupError.cancelled }
            return BackupSummary(duration: 1, bytesWritten: 10)
        }
    }
}

/// Reports "device busy" until `busy` is switched off, then succeeds.
private final class BusyEngine: BackupEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _busy = true
    var busy: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _busy }
        set { lock.lock(); _busy = newValue; lock.unlock() }
    }
    func backup(_ target: BackupTarget, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupSummary {
        if busy { throw BackupError.deviceBusy }
        return BackupSummary(duration: 1, bytesWritten: 1)
    }
}

@MainActor
final class BackupSchedulerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    private var clock: TestClock!
    private var engine: RecordingEngine!
    private var controller: BackupController!
    private var scheduler: BackupScheduler!
    private var devices: [DeviceState] = []
    private var settings: [String: DeviceSettings] = [:]
    private var lastBackups: [String: Date] = [:]
    private var mac = MacState(onACPower: true, freeDiskBytes: 500_000_000_000)

    private func local(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func device(_ udid: String, battery: Int = 80, reachable: Bool = true) -> DeviceState {
        DeviceState(
            udid: udid, name: "Phone \(udid)", connections: reachable ? [.usb] : [],
            battery: BatteryStatus(level: battery, isCharging: false), encryption: .unencrypted)
    }

    private func enabledSettings(_ change: (inout DeviceSettings) -> Void = { _ in }) -> DeviceSettings {
        var s = DeviceSettings(
            enabled: true, windowEnabled: true, windowStartMinute: 20 * 60, windowEndMinute: 23 * 60,
            minFreeDiskGB: 0, minIntervalHours: 0, passcodeWaitSeconds: 123, retryIntervalMinutes: 30)
        change(&s)
        return s
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    func testStartsABackupInsideTheWindowWithThePerDevicePasscodeTimeout() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        XCTAssertTrue(controller.isRunning("A"))
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(engine.targets.map(\.udid), ["A"])
        XCTAssertEqual(engine.targets.first?.passcodeWaitSeconds, 123)
        XCTAssertEqual(engine.targets.first?.connection, .usb)
    }

    func testNeverStartsASecondBackupForARunningDevice() async {
        build()
        engine.behavior = .hold
        devices = [device("A")]
        settings["A"] = enabledSettings()
        for _ in 0..<5 { scheduler.evaluate() }
        await waitUntil { !self.engine.targets.isEmpty }
        XCTAssertEqual(engine.targets.count, 1)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Backup in progress")
        // Even a manual start is refused while it runs.
        XCTAssertFalse(controller.start(devices[0]))
        await engine.gate.release()
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testOutsideTheWindowNothingStartsAndTheMenuTextSaysWhen() {
        build(at: "2026-03-27 12:00")
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertTrue(engine.targets.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Next: today 20:00–23:00")
    }

    func testDisabledDevicesAreLeftAlone() {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings { $0.enabled = false }
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertNil(scheduler.statusText(for: "A"))
        devices = [device("B")] // never configured: defaults are off
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
    }

    func testBlockedByBatteryThenStartsWhenItRecovers() async {
        build()
        devices = [device("A", battery: 14)]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: battery 14% < 20%")

        devices = [device("A", battery: 25)] // battery change event
        scheduler.evaluate()
        XCTAssertTrue(controller.isRunning("A"))
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testDeviceAttachStartsTheBackup() async {
        build()
        devices = []
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        XCTAssertTrue(engine.targets.isEmpty)
        devices = [device("A", reachable: false)]
        scheduler.evaluate()
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: iPhone not connected")
        devices = [device("A")]
        scheduler.evaluate()
        await waitUntil { !self.engine.targets.isEmpty }
        XCTAssertEqual(engine.targets.count, 1)
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testMinFreeDiskUsesTheMacState() {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings { $0.minFreeDiskGB = 50 }
        mac = MacState(onACPower: true, freeDiskBytes: 10_000_000_000)
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: free disk space 10.0 GB < 50 GB")
    }

    func testFinderBackupsCountViaTheLastBackupProvider() {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings { $0.minIntervalHours = 12 }
        lastBackups["A"] = clock.now.addingTimeInterval(-3_600) // made in Finder an hour ago
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Next: tomorrow 20:00–23:00")
    }

    func testSuccessfulRunIsNotRepeatedEvenWhenTheBackupFolderCannotBeRead() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .success(bytes: 10))

        clock.advance(120)
        scheduler.evaluate() // lastBackups["A"] is still nil (no Full Disk Access)
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertEqual(engine.targets.count, 1)
    }

    func testFailedAttemptIsRetriedAfterTheRetryIntervalInsideTheWindow() async {
        build()
        engine.behavior = .fail
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(engine.targets.count, 1)

        clock.advance(10 * 60)
        scheduler.evaluate()
        XCTAssertEqual(engine.targets.count, 1, "too early")
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: retry in 20 min")

        clock.advance(21 * 60) // 21:31 - still inside the window
        engine.behavior = .succeed
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(engine.targets.count, 2)
        XCTAssertEqual(controller.results["A"]?.kind, .success(bytes: 10))
    }

    func testNoRetryOnceTheWindowHasClosed() async {
        build(at: "2026-03-27 22:40")
        engine.behavior = .fail
        devices = [device("A")]
        settings["A"] = enabledSettings { $0.retryIntervalMinutes = 30 }
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        clock.advance(40 * 60) // 23:20, window over
        scheduler.evaluate()
        XCTAssertEqual(engine.targets.count, 1)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Next: tomorrow 20:00–23:00")
    }

    func testTwoDevicesAreHandledIndependently() async {
        build()
        engine.behavior = .hold
        devices = [device("A"), device("B", battery: 5), device("C", reachable: false)]
        for id in ["A", "B", "C"] { settings[id] = enabledSettings() }
        scheduler.evaluate()
        await waitUntil { !self.engine.targets.isEmpty }
        XCTAssertEqual(Set(engine.targets.map(\.udid)), ["A"])
        await engine.gate.release()
        await waitUntil { self.controller.jobs.isEmpty }
    }

    // MARK: - M4

    func testSecondDeviceIsQueuedShowsQueuedAndRunsAfterTheFirst() async {
        build()
        engine.behavior = .hold
        devices = [device("A"), device("B")]
        settings["A"] = enabledSettings()
        settings["B"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { !self.engine.targets.isEmpty }
        XCTAssertTrue(controller.isQueued("B"))
        XCTAssertEqual(scheduler.statusText(for: "A"), "Backup in progress")
        XCTAssertEqual(scheduler.statusText(for: "B"), "Queued: waiting for the running backup to finish")
        scheduler.evaluate()
        XCTAssertEqual(engine.targets.count, 1, "evaluating again does not queue or start it twice")
        XCTAssertEqual(controller.queue, ["B"])

        await engine.gate.release()
        await waitUntil { self.controller.jobs.isEmpty && self.controller.queue.isEmpty }
        XCTAssertEqual(engine.targets.map(\.udid), ["A", "B"])
    }

    func testManualBackupAndSchedulerShareTheQueue() async {
        build()
        engine.behavior = .hold
        devices = [device("A"), device("B")]
        settings["B"] = enabledSettings()
        XCTAssertTrue(controller.start(devices[0])) // manual, device A has automatic backups off
        scheduler.evaluate()
        XCTAssertTrue(controller.isQueued("B"))
        await engine.gate.release()
        await waitUntil { self.controller.jobs.isEmpty && self.controller.queue.isEmpty }
        XCTAssertEqual(engine.targets.map(\.udid), ["A", "B"])
    }

    func testStartsAreHeldUntilTheDeviceListIsFreshAfterWake() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.holdStarts(for: 60)
        scheduler.evaluate()
        XCTAssertTrue(controller.jobs.isEmpty)
        XCTAssertTrue(engine.targets.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: checking devices after wake-up")

        scheduler.releaseStarts()
        XCTAssertTrue(controller.isRunning("A"))
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testADeviceThatLeftDuringSleepNeverGetsAFailedAttempt() async {
        build()
        devices = [device("A")] // stale pre-sleep list
        settings["A"] = enabledSettings()
        scheduler.holdStarts(for: 60)
        scheduler.evaluate()
        devices = [device("A", reachable: false)] // the refreshed list: it was unplugged during sleep
        scheduler.releaseStarts()
        XCTAssertTrue(engine.targets.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: iPhone not connected")
        XCTAssertNil(controller.lastFailedAttempt(for: "A"), "so no retry interval delays the real backup")

        devices = [device("A")] // plugged back in
        scheduler.evaluate()
        XCTAssertTrue(controller.isRunning("A"))
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testTheHoldExpiresByItself() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.holdStarts(for: 60)
        XCTAssertTrue(scheduler.startsAreHeld)
        clock.advance(61)
        XCTAssertFalse(scheduler.startsAreHeld)
        scheduler.evaluate()
        XCTAssertTrue(controller.isRunning("A"))
        await waitUntil { self.controller.jobs.isEmpty }
    }

    func testARefusedStartShowsAReasonInsteadOfStartingForever() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        await controller.shutdown(timeout: 1) // the app is quitting: the controller refuses everything
        scheduler.evaluate()
        XCTAssertTrue(engine.targets.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: the app is quitting")
    }

    func testBusyDeviceIsRetriedAfterTheRetryInterval() async {
        build()
        let busy = BusyEngine()
        let clock = self.clock!
        controller = BackupController(
            engine: busy, notifier: nil, sleepBlocker: nil, history: BackupHistoryStore(fileURL: nil),
            clock: { clock.now })
        scheduler = BackupScheduler(
            controller: controller, devices: { [unowned self] in self.devices },
            settings: { [unowned self] in self.settings[$0] ?? DeviceSettings() },
            lastBackup: { _ in nil }, macState: { MacState() },
            clock: { clock.now }, calendar: { [unowned self] in self.calendar })
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .deviceBusy)
        scheduler.evaluate()
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: retry in 30 min")
        clock.advance(31 * 60) // 21:31, still in the window
        busy.busy = false
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .success(bytes: 1))
    }

    func testASuccessIsStillKnownAfterARestartWithoutFullDiskAccess() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        build(historyFile: file)
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }
        XCTAssertEqual(engine.targets.count, 1)

        // The app restarts a few minutes later: new controller and scheduler, same state file, and
        // Status.plist is unreadable (lastBackup provider returns nil).
        build(at: "2026-03-27 21:05", historyFile: file)
        scheduler.evaluate()
        XCTAssertTrue(engine.targets.isEmpty, "the daily backup made minutes ago is not repeated")
        XCTAssertEqual(scheduler.statusText(for: "A"), "Next: tomorrow 20:00–23:00")
    }

    func testAFailedAttemptStillGatesTheRetryAfterARestart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        build(historyFile: file)
        engine.behavior = .fail
        devices = [device("A")]
        settings["A"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { self.controller.jobs.isEmpty }

        build(at: "2026-03-27 21:10", historyFile: file) // restart 10 min later
        scheduler.evaluate()
        XCTAssertTrue(engine.targets.isEmpty)
        XCTAssertEqual(scheduler.statusText(for: "A"), "Waiting: retry in 20 min")
    }

    func testCancellingAQueuedAutomaticBackupIsNotUndoneByTheScheduler() async {
        build()
        engine.behavior = .hold
        devices = [device("A"), device("B")]
        settings["A"] = enabledSettings()
        settings["B"] = enabledSettings()
        scheduler.evaluate()
        await waitUntil { !self.engine.targets.isEmpty }
        XCTAssertTrue(controller.isQueued("B"))

        controller.cancel(udid: "B") // the user cancels the queued one
        XCTAssertEqual(controller.results["B"]?.kind, .cancelled)
        scheduler.evaluate()
        XCTAssertFalse(controller.isQueued("B"), "not queued again right away")
        XCTAssertEqual(scheduler.statusText(for: "B"), "Waiting: retry in 30 min")

        clock.advance(31 * 60) // retry interval over, still inside the window
        scheduler.evaluate()
        XCTAssertTrue(controller.isQueued("B"), "automatic backups resume after the retry interval")
        await engine.gate.release()
        await waitUntil { self.controller.jobs.isEmpty && self.controller.queue.isEmpty }
    }

    func testTimerLoopEvaluates() async {
        build()
        devices = [device("A")]
        settings["A"] = enabledSettings()
        let clock = self.clock!
        let calendar = self.calendar
        let ticking = BackupScheduler(
            controller: controller, devices: { [unowned self] in self.devices },
            settings: { [unowned self] in self.settings[$0] ?? DeviceSettings() },
            lastBackup: { _ in nil }, macState: { MacState() },
            clock: { clock.now }, calendar: { calendar }, tickInterval: 0.01)
        ticking.start()
        await waitUntil { !self.engine.targets.isEmpty }
        ticking.stop()
        XCTAssertEqual(engine.targets.count, 1)
        await waitUntil { self.controller.jobs.isEmpty }
    }

    /// Creates the engine, controller and scheduler around a fake clock (called first in every test).
    private func build(at start: String = "2026-03-27 21:00", historyFile: URL? = nil) {
        let newClock = TestClock(local(start))
        clock = newClock
        engine = RecordingEngine()
        controller = BackupController(
            engine: engine, notifier: nil, sleepBlocker: nil, history: BackupHistoryStore(fileURL: historyFile),
            passcodeWaitProvider: { [unowned self] udid in self.settings[udid]?.passcodeWaitSeconds ?? 300 },
            clock: { newClock.now })
        scheduler = BackupScheduler(
            controller: controller,
            devices: { [unowned self] in self.devices },
            settings: { [unowned self] in self.settings[$0] ?? DeviceSettings() },
            lastBackup: { [unowned self] in self.lastBackups[$0] },
            macState: { [unowned self] in self.mac },
            clock: { newClock.now },
            calendar: { [unowned self] in self.calendar })
    }
}
