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
        XCTAssertTrue(controller.start(device("B")))
        XCTAssertEqual(blocker.begins, 1)
        await gate.release()
        await waitUntil { controller.jobs.isEmpty }
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

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimeInterval] = []
    func append(_ value: TimeInterval) { lock.lock(); items.append(value); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return items }
}
