import XCTest
@testable import BackupCore

private final class FakeNotifier: BackupNotifying {
    var events: [String] = []
    func backupStarted(deviceName: String) { events.append("started:\(deviceName)") }
    func backupNeedsPasscode(deviceName: String) { events.append("passcode:\(deviceName)") }
    func backupFinished(deviceName: String, duration: TimeInterval, bytes: Int64) { events.append("finished:\(deviceName):\(bytes)") }
    func backupFailed(deviceName: String, reason: String) { events.append("failed:\(deviceName):\(reason)") }
}

private final class FakeBlocker: SleepBlocking {
    var begins = 0
    var ends = 0
    func begin(reason: String) { begins += 1 }
    func end() { ends += 1 }
}

private struct ClosureEngine: BackupEngine {
    var body: @Sendable (BackupTarget, @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupSummary
    func backup(_ target: BackupTarget, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupSummary {
        try await body(target, progress)
    }
}

/// Lets a test hold a fake backup open until it says go.
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

@MainActor
final class BackupControllerTests: XCTestCase {
    private func device(_ udid: String = "U1", reachable: Bool = true, issue: DeviceIssue? = nil) -> DeviceState {
        DeviceState(
            udid: udid, name: "Phone \(udid)", connections: reachable ? [.wifi] : [], encryption: .unknown,
            issue: issue)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    func testSuccessfulBackup() async {
        let notifier = FakeNotifier()
        let blocker = FakeBlocker()
        var finishedCalls = 0
        let controller = BackupController(
            engine: ClosureEngine { target, progress in
                XCTAssertEqual(target.connection, .wifi)
                progress(BackupProgress(fraction: 0.5, message: "Backing up…"))
                return BackupSummary(duration: 12, bytesWritten: 1_000)
            },
            notifier: notifier, sleepBlocker: blocker)
        controller.onFinished = { finishedCalls += 1 }

        XCTAssertTrue(controller.start(device()))
        XCTAssertNotNil(controller.jobs["U1"])
        await waitUntil { controller.jobs.isEmpty }

        XCTAssertEqual(notifier.events, ["started:Phone U1", "finished:Phone U1:1000"])
        XCTAssertEqual(controller.results["U1"]?.kind, .success(bytes: 1_000))
        XCTAssertEqual(blocker.begins, 1)
        XCTAssertEqual(blocker.ends, 1)
        XCTAssertEqual(finishedCalls, 1)
    }

    func testOnlyOneBackupPerDeviceAndSleepBlockedUntilAllDone() async {
        let gate = Gate()
        let blocker = FakeBlocker()
        let controller = BackupController(
            engine: ClosureEngine { _, _ in
                await gate.wait()
                return BackupSummary(duration: 1, bytesWritten: 0)
            },
            notifier: nil, sleepBlocker: blocker)

        XCTAssertTrue(controller.start(device("A")))
        XCTAssertFalse(controller.start(device("A")), "a second backup of the same device is refused")
        XCTAssertTrue(controller.start(device("B")), "another device is queued")
        XCTAssertEqual(controller.jobs.keys.sorted(), ["A"])
        XCTAssertEqual(controller.queue, ["B"])
        XCTAssertFalse(controller.start(device("B")), "already queued")
        XCTAssertEqual(blocker.begins, 1)
        await gate.release()
        await waitUntil { controller.jobs.isEmpty && controller.queue.isEmpty }
        XCTAssertEqual(controller.results["B"]?.kind, .success(bytes: 0))
        XCTAssertEqual(blocker.begins, 1, "the Mac stays awake across the queue")
        XCTAssertEqual(blocker.ends, 1)
    }

    func testCannotStartUnreachableOrUntrustedDevices() {
        let controller = BackupController(engine: UnimplementedBackupEngine(), notifier: nil, sleepBlocker: nil)
        XCTAssertFalse(controller.start(device(reachable: false)))
        XCTAssertFalse(controller.start(device(issue: .needsTrust)))
        XCTAssertTrue(controller.jobs.isEmpty)
    }

    func testCancel() async {
        let notifier = FakeNotifier()
        let gate = Gate()
        let controller = BackupController(
            engine: ClosureEngine { _, _ in
                await gate.wait()
                if Task.isCancelled { throw BackupError.cancelled }
                return BackupSummary(duration: 1, bytesWritten: 0)
            },
            notifier: notifier, sleepBlocker: nil)
        controller.start(device())
        controller.cancel(udid: "U1")
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["U1"]?.kind, .cancelled)
        XCTAssertEqual(notifier.events, ["started:Phone U1"], "cancelling is not a failure")
    }

    func testBusyAndFailureNotifications() async {
        let notifier = FakeNotifier()
        let controller = BackupController(
            engine: ClosureEngine { _, _ in throw BackupError.deviceBusy }, notifier: notifier, sleepBlocker: nil)
        controller.start(device())
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["U1"]?.kind, .deviceBusy)
        XCTAssertTrue(notifier.events.last?.hasPrefix("failed:Phone U1:Device busy") ?? false, "\(notifier.events)")

        let failing = BackupController(
            engine: ClosureEngine { _, _ in throw BackupError.failed("disk full") }, notifier: notifier, sleepBlocker: nil)
        failing.start(device("U2"))
        await waitUntil { failing.jobs.isEmpty }
        XCTAssertEqual(failing.results["U2"]?.kind, .failed("disk full"))
        XCTAssertEqual(notifier.events.last, "failed:Phone U2:disk full")
    }

    func testPasscodeNotificationOnce() async {
        let notifier = FakeNotifier()
        let controller = BackupController(
            engine: ClosureEngine { _, progress in
                progress(BackupProgress(fraction: nil, message: "Unlock", phase: .waitingForPasscode))
                progress(BackupProgress(fraction: nil, message: "Unlock", phase: .waitingForPasscode))
                try? await Task.sleep(nanoseconds: 30_000_000)
                return BackupSummary(duration: 1, bytesWritten: 0)
            },
            notifier: notifier, sleepBlocker: nil)
        controller.start(device())
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(notifier.events.filter { $0.hasPrefix("passcode") }, ["passcode:Phone U1"])
    }

    func testPasscodeNotificationOncePerRunEvenWhenTheDeviceAsksAgain() async {
        let notifier = FakeNotifier()
        let controller = BackupController(
            engine: ClosureEngine { _, progress in
                progress(BackupProgress(fraction: nil, message: "Unlock", phase: .waitingForPasscode))
                try? await Task.sleep(nanoseconds: 30_000_000)
                progress(BackupProgress(fraction: 0.1, message: "Backing up", phase: .transferring))
                try? await Task.sleep(nanoseconds: 30_000_000)
                progress(BackupProgress(fraction: nil, message: "Unlock", phase: .waitingForPasscode))
                try? await Task.sleep(nanoseconds: 30_000_000)
                return BackupSummary(duration: 1, bytesWritten: 0)
            },
            notifier: notifier, sleepBlocker: nil)
        controller.start(device())
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(notifier.events.filter { $0.hasPrefix("passcode") }.count, 1)

        // A new run may notify again.
        controller.start(device())
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(notifier.events.filter { $0.hasPrefix("passcode") }.count, 2)
    }

    func testPerDevicePasscodeWaitReachesTheEngine() async {
        let seen = Seen()
        let controller = BackupController(
            engine: ClosureEngine { target, _ in
                seen.append(target.passcodeWaitSeconds)
                return BackupSummary(duration: 1, bytesWritten: 0)
            },
            notifier: nil, sleepBlocker: nil, passcodeWaitSeconds: 300,
            passcodeWaitProvider: { $0 == "U1" ? 90 : 600 })
        controller.start(device("U1"))
        await waitUntil { controller.jobs.isEmpty }
        controller.start(device("U2"))
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(seen.values, [90, 600])
    }
}

// MARK: - M4: queue, disconnect, sleep, quit

/// Counts how many fake backups overlap and keeps the start order.
private final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var order: [String] = []
    func enter(_ udid: String) { lock.lock(); running += 1; maxRunning = max(maxRunning, running); order.append(udid); lock.unlock() }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
}

/// An engine that behaves like the real one on cancel: it takes a moment to clean up (remove partial
/// files, release the sync lock) before it reports `cancelled`.
private final class CleanupEngine: BackupEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _cleanedUp: [String] = []
    private var _started: [String] = []
    var cleanedUp: [String] { lock.lock(); defer { lock.unlock() }; return _cleanedUp }
    var started: [String] { lock.lock(); defer { lock.unlock() }; return _started }

    func backup(_ target: BackupTarget, progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupSummary {
        lock.lock(); _started.append(target.udid); lock.unlock()
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 60_000_000) // cleanup takes a while
        lock.lock(); _cleanedUp.append(target.udid); lock.unlock()
        throw BackupError.cancelled
    }
}

@MainActor
final class BackupQueueAndAbortTests: XCTestCase {
    private func device(_ udid: String, reachable: Bool = true) -> DeviceState {
        DeviceState(udid: udid, name: "Phone \(udid)", connections: reachable ? [.usb] : [], encryption: .unknown)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    func testThreeDevicesRunOneAtATimeInTheOrderTheyWereQueued() async {
        let seen = Concurrency()
        let controller = BackupController(
            engine: ClosureEngine { target, _ in
                seen.enter(target.udid)
                try? await Task.sleep(nanoseconds: 20_000_000)
                seen.leave()
                return BackupSummary(duration: 1, bytesWritten: 1)
            }, notifier: nil, sleepBlocker: nil)
        for id in ["A", "B", "C"] { XCTAssertTrue(controller.start(device(id))) }
        XCTAssertEqual(controller.queuePosition("B"), 1)
        XCTAssertEqual(controller.queuePosition("C"), 2)
        XCTAssertNil(controller.queuePosition("A"))
        XCTAssertTrue(controller.isQueued("C"))
        XCTAssertFalse(controller.canStart(device("C")), "already queued")
        await waitUntil { controller.jobs.isEmpty && controller.queue.isEmpty }
        XCTAssertEqual(seen.order, ["A", "B", "C"])
        XCTAssertEqual(seen.maxRunning, 1)
        XCTAssertEqual(Set(controller.results.keys), ["A", "B", "C"])
    }

    func testCancellingAQueuedDeviceJustRemovesIt() async {
        let engine = CleanupEngine()
        let controller = BackupController(engine: engine, notifier: nil, sleepBlocker: nil)
        controller.start(device("A"))
        controller.start(device("B"))
        controller.cancel(udid: "B")
        XCTAssertTrue(controller.queue.isEmpty)
        XCTAssertNil(controller.results["B"])
        controller.cancel(udid: "A")
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(engine.started, ["A"], "the cancelled queue entry never started")
    }

    func testQueuedDeviceThatLeftIsSkippedWhenItsTurnComes() async {
        var present: Set<String> = ["A", "B", "C"]
        let seen = Concurrency()
        let gate = Gate()
        let controller = BackupController(
            engine: ClosureEngine { target, _ in
                seen.enter(target.udid)
                await gate.wait()
                seen.leave()
                return BackupSummary(duration: 1, bytesWritten: 1)
            }, notifier: nil, sleepBlocker: nil)
        controller.deviceLookup = { [unowned self] udid in self.device(udid, reachable: present.contains(udid)) }
        controller.start(device("A")); controller.start(device("B")); controller.start(device("C"))
        present.remove("B")
        await gate.release()
        await waitUntil { controller.jobs.isEmpty && controller.queue.isEmpty }
        XCTAssertEqual(seen.order, ["A", "C"])
        XCTAssertNotNil(controller.results["B"])
        XCTAssertNil(controller.lastFailedAttempt(for: "B"), "a skipped turn is not a failed attempt")
    }

    func testDeviceLeavingMidBackupAbortsAfterTheGraceAndStartsTheNextOne() async {
        let engine = CleanupEngine()
        let notifier = FakeNotifier()
        var present: Set<String> = ["A", "B"]
        let controller = BackupController(
            engine: engine, notifier: notifier, sleepBlocker: nil, disconnectGrace: 0.03,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        controller.deviceLookup = { [unowned self] udid in self.device(udid, reachable: present.contains(udid)) }
        controller.start(device("A")); controller.start(device("B"))
        await waitUntil { engine.started == ["A"] }

        present.remove("A")
        controller.deviceListChanged()
        XCTAssertTrue(controller.isRunning("A"), "a short glitch must not abort")
        await waitUntil { controller.results["A"] != nil }
        XCTAssertEqual(controller.results["A"]?.kind, .disconnected)
        XCTAssertTrue(controller.results["A"]?.isProblem ?? false)
        XCTAssertEqual(engine.cleanedUp, ["A"], "the engine cleaned up before the result was reported")
        XCTAssertNotNil(controller.lastFailedAttempt(for: "A"), "the scheduler retries later")
        XCTAssertTrue(notifier.events.contains { $0.hasPrefix("failed:Phone A") })
        await waitUntil { engine.started.contains("B") }
        controller.cancel(udid: "B")
        await waitUntil { controller.jobs.isEmpty }
    }

    func testDeviceBackWithinTheGraceKeepsTheBackup() async {
        let engine = CleanupEngine()
        var present = true
        let controller = BackupController(engine: engine, notifier: nil, sleepBlocker: nil, disconnectGrace: 0.05)
        controller.deviceLookup = { [unowned self] udid in self.device(udid, reachable: present) }
        controller.start(device("A"))
        present = false
        controller.deviceListChanged()
        present = true
        controller.deviceListChanged()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(controller.isRunning("A"))
        controller.cancel(udid: "A")
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .cancelled)
    }

    func testEngineReportedDisconnectIsRecordedAndRetried() async {
        let notifier = FakeNotifier()
        let controller = BackupController(
            engine: ClosureEngine { _, _ in throw BackupError.deviceDisconnected }, notifier: notifier, sleepBlocker: nil)
        controller.start(device("A"))
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .disconnected)
        XCTAssertTrue(controller.results["A"]?.gatesRetry ?? false)
        XCTAssertNotNil(controller.lastFailedAttempt(for: "A"))
        XCTAssertNil(controller.lastSuccess(for: "A"))
    }

    func testDiskFullIsAClearProblemAndIsRetriedLater() async {
        let notifier = FakeNotifier()
        let controller = BackupController(
            engine: ClosureEngine { _, _ in throw BackupError.diskFull }, notifier: notifier, sleepBlocker: nil)
        controller.start(device("A"))
        await waitUntil { controller.jobs.isEmpty }
        XCTAssertEqual(controller.results["A"]?.kind, .diskFull)
        XCTAssertTrue(controller.results["A"]?.text.contains("disk is full") ?? false)
        XCTAssertNotNil(controller.lastFailedAttempt(for: "A"))
        XCTAssertTrue(notifier.events.last?.contains("disk is full") ?? false, "\(notifier.events)")
    }

    func testSleepStopsTheRunningBackupAndDropsTheQueueWithoutCountingAsAFailure() async {
        let engine = CleanupEngine()
        let notifier = FakeNotifier()
        let blocker = FakeBlocker()
        let controller = BackupController(engine: engine, notifier: notifier, sleepBlocker: blocker)
        controller.start(device("A")); controller.start(device("B"))
        await waitUntil { engine.started == ["A"] }

        controller.suspendForSleep()
        XCTAssertTrue(controller.queue.isEmpty)
        await waitUntil { controller.jobs.isEmpty }
        guard case .interrupted? = controller.results["A"]?.kind else { return XCTFail("\(String(describing: controller.results["A"]))") }
        XCTAssertFalse(controller.results["A"]?.isProblem ?? true)
        XCTAssertNil(controller.lastFailedAttempt(for: "A"), "after wake the backup may start again right away")
        XCTAssertEqual(engine.started, ["A"], "the queued device did not start after A stopped")
        XCTAssertEqual(notifier.events, ["started:Phone A"], "no failure notification for a sleep")
        XCTAssertEqual(blocker.ends, 1)
    }

    func testSleepWithNothingRunningIsHarmless() {
        let controller = BackupController(engine: UnimplementedBackupEngine(), notifier: nil, sleepBlocker: nil)
        controller.suspendForSleep()
        XCTAssertFalse(controller.isBusy)
    }

    func testQuitCancelsWaitsForTheCleanupAndRefusesNewBackups() async {
        let engine = CleanupEngine()
        let blocker = FakeBlocker()
        let controller = BackupController(engine: engine, notifier: nil, sleepBlocker: blocker)
        controller.start(device("A")); controller.start(device("B"))
        await waitUntil { engine.started == ["A"] }
        XCTAssertTrue(controller.isBusy)

        let clean = await controller.shutdown(timeout: 5)
        XCTAssertTrue(clean)
        XCTAssertEqual(engine.cleanedUp, ["A"], "shutdown returned only after the engine finished cleaning up")
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(engine.started, ["A"])
        guard case .interrupted? = controller.results["A"]?.kind else { return XCTFail("quit is not a failure") }
        XCTAssertNil(controller.lastFailedAttempt(for: "A"))
        XCTAssertEqual(blocker.ends, 1)
        XCTAssertFalse(controller.start(device("C")), "no new backups while quitting")
    }

    func testQuitGivesUpAfterTheTimeoutWhenTheEngineDoesNotStop() async {
        let controller = BackupController(
            engine: ClosureEngine { _, _ in
                // Ignores cancellation for a while (a blocked device read).
                let end = Date().addingTimeInterval(0.6)
                while Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
                throw BackupError.cancelled
            }, notifier: nil, sleepBlocker: nil)
        controller.start(device("A"))
        let clean = await controller.shutdown(timeout: 0.1)
        XCTAssertFalse(clean)
        await waitUntil { controller.jobs.isEmpty }
    }

    func testHistorySurvivesARestart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = BackupController(
            engine: ClosureEngine { target, _ in
                if target.udid == "BAD" { throw BackupError.failed("boom") }
                return BackupSummary(duration: 1, bytesWritten: 1)
            }, notifier: nil, sleepBlocker: nil, history: BackupHistoryStore(fileURL: file), clock: { now })
        first.start(device("GOOD"))
        await waitUntil { first.jobs.isEmpty }
        first.start(device("BAD"))
        await waitUntil { first.jobs.isEmpty }

        // "Restart": a new controller reading the same file.
        let second = BackupController(
            engine: UnimplementedBackupEngine(), notifier: nil, sleepBlocker: nil, history: BackupHistoryStore(fileURL: file))
        XCTAssertEqual(second.lastSuccess(for: "GOOD"), now)
        XCTAssertNil(second.lastFailedAttempt(for: "GOOD"))
        XCTAssertEqual(second.lastFailedAttempt(for: "BAD"), now)
        XCTAssertNil(second.lastSuccess(for: "BAD"))
        second.forgetHistory(udid: "GOOD")
        XCTAssertNil(BackupHistoryStore(fileURL: file).history(for: "GOOD").lastSuccess)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimeInterval] = []
    func append(_ value: TimeInterval) { lock.lock(); items.append(value); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return items }
}
