import XCTest
@testable import BackupCore

final class BackupRunnerTests: XCTestCase {
    private var root: URL!
    private var clock: FakeClock!
    private var session: FakeSession!
    private let udid = "00008030-AAAA"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = try makeTempDir()
        clock = FakeClock()
        session = FakeSession(clock: clock)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private var udidDir: URL { root.appendingPathComponent(udid) }

    private func target(passcodeWait: TimeInterval = 300) -> BackupTarget {
        BackupTarget(udid: udid, connection: .usb, destinationRoot: root, passcodeWaitSeconds: passcodeWait)
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [BackupProgress] = []
        func add(_ p: BackupProgress) { lock.lock(); items.append(p); lock.unlock() }
        var all: [BackupProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func run(
        passcodeWait: TimeInterval = 300, cancel: CancellationFlag = CancellationFlag(), reports: Reports = Reports()
    ) throws -> BackupSummary {
        var config = BackupRunnerConfig()
        config.handler.stallTimeout = 0
        let runner = BackupRunner(
            session: session, target: target(passcodeWait: passcodeWait), config: config, cancel: cancel,
            now: { [clock] in clock!.now }, log: { _, _ in }, progress: { reports.add($0) })
        return try runner.run()
    }

    private func upload(_ files: [(String, Data)], progress: Double = 50) -> FakeSession.Step {
        var raw = Data()
        for (path, data) in files { raw += Stream.file(path: path, chunks: [data]) }
        raw += Stream.terminator
        return .message(DLMessage(["DLMessageUploadFiles", 0, progress, 100])!, raw: raw)
    }

    private func finish(code: Int = 0) -> FakeSession.Step {
        .message(DLMessage(["DLMessageProcessMessage", ["ErrorCode": code, "ErrorDescription": code == 0 ? "" : "boom"]])!, raw: Data())
    }

    private func readInfo() throws -> [String: Any] {
        try XCTUnwrap(InfoPlistBuilder.parse(try Data(contentsOf: udidDir.appendingPathComponent("Info.plist"))))
    }

    private func successScript(statusState: String = "finished") throws -> [FakeSession.Step] {
        [
            .message(DLMessage(["DLMessageGetFreeDiskSpace"])!, raw: Data()),
            upload([
                ("\(udid)/Status.plist", try statusPlist(state: statusState, date: clock.now)),
                ("\(udid)/Manifest.db", Data("db".utf8)),
            ]),
            .message(DLMessage(["DLMessageRemoveFiles", ["\(udid)/old"], 0, 90.0])!, raw: Data()),
            finish(),
        ]
    }

    func testSuccessfulBackupWritesFinderStyleFolder() throws {
        for encrypted in [false, true] {
            try? fm.removeItem(at: root)
            session = FakeSession(clock: clock)
            session.willEncrypt = encrypted
            session.script = try successScript()
            session.deviceFiles["/iTunes_Control/iTunes/iTunesPrefs"] = Data([1, 2, 3])
            let reports = Reports()

            let summary = try run(reports: reports)

            XCTAssertEqual(session.calls, ["lock", "request:\(udid)", "unlock"], "encrypted=\(encrypted)")
            XCTAssertGreaterThan(summary.bytesWritten, 2)
            XCTAssertTrue(fm.fileExists(atPath: udidDir.appendingPathComponent("Manifest.db").path))
            XCTAssertTrue(BackupMetadata.isFinished(statusPlist: try Data(contentsOf: udidDir.appendingPathComponent("Status.plist"))))

            let info = try readInfo()
            XCTAssertEqual(info["Device Name"] as? String, "Anna's iPhone")
            XCTAssertEqual(info["Unique Identifier"] as? String, udid.uppercased())
            XCTAssertEqual(info["Target Identifier"] as? String, udid)
            XCTAssertEqual((info["iTunes Files"] as? [String: Data])?["iTunesPrefs"], Data([1, 2, 3]))
            XCTAssertEqual(info["Last Backup Date"] as? Date, clock.now)
            XCTAssertEqual(BackupFolder(root: root).lastBackupDate(udid: udid), clock.now)

            let phases = reports.all.map(\.phase)
            XCTAssertEqual(phases.first, .connecting)
            XCTAssertEqual(phases.last, .finishing)
            XCTAssertTrue(phases.contains(.transferring))
            XCTAssertEqual(reports.all.last?.fraction, 1)
        }
    }

    func testIncrementalRunKeepsGUIDAndApplicationsAndWritesInfoBeforeTheBackup() throws {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.createDirectory(at: udidDir, withIntermediateDirectories: true)
        try plistData([
            "GUID": "KEEPME", "Last Backup Date": previous, "Applications": ["com.x": ["a": 1]],
            "Installed Applications": ["com.x"],
        ] as [String: Any]).write(to: udidDir.appendingPathComponent("Info.plist"))
        try statusPlist(state: "finished", date: previous).write(to: udidDir.appendingPathComponent("Status.plist"))

        var infoAtRequest: [String: Any]?
        session.onRequestBackup = { [self] in infoAtRequest = try? readInfo() }
        session.script = try successScript()
        _ = try run()

        let before = try XCTUnwrap(infoAtRequest)
        XCTAssertEqual(before["Last Backup Date"] as? Date, previous, "a running backup must not look like a finished one")
        XCTAssertEqual(before["Device Name"] as? String, "Anna's iPhone")
        let after = try readInfo()
        XCTAssertEqual(after["GUID"] as? String, "KEEPME")
        XCTAssertEqual(after["Installed Applications"] as? [String], ["com.x"])
        XCTAssertEqual(after["Last Backup Date"] as? Date, clock.now)
    }

    func testFailedBackupKeepsPreviousLastBackupDateAndExistingFiles() throws {
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.createDirectory(at: udidDir, withIntermediateDirectories: true)
        try plistData(["Last Backup Date": previous] as [String: Any]).write(to: udidDir.appendingPathComponent("Info.plist"))
        let oldManifest = Data("old manifest".utf8)
        try oldManifest.write(to: udidDir.appendingPathComponent("Manifest.db"))

        session.script = [.message(DLMessage(["DLMessageGetFreeDiskSpace"])!, raw: Data()), finish(code: 211)]
        XCTAssertThrowsError(try run()) {
            guard case .failed(let text)? = $0 as? BackupError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("211") && text.contains("boom"), text)
        }
        XCTAssertEqual(try readInfo()["Last Backup Date"] as? Date, previous)
        XCTAssertEqual(try Data(contentsOf: udidDir.appendingPathComponent("Manifest.db")), oldManifest)
        XCTAssertEqual(session.calls.last, "unlock")
    }

    func testFirstFailedBackupHasNoLastBackupDate() throws {
        session.script = [finish(code: 1)]
        XCTAssertThrowsError(try run())
        XCTAssertNil(try readInfo()["Last Backup Date"])
        XCTAssertNil(BackupFolder(root: root).lastBackupDate(udid: udid))
    }

    func testSuccessCodeWithoutFinishedStatusIsAFailure() throws {
        session.script = try successScript(statusState: "uploading")
        XCTAssertThrowsError(try run()) {
            guard case .failed? = $0 as? BackupError else { return XCTFail("\($0)") }
        }
        XCTAssertNil(try readInfo()["Last Backup Date"])
    }

    func testDeviceBusyStopsBeforeTouchingTheBackupFolder() throws {
        session.busy = true
        XCTAssertThrowsError(try run()) { XCTAssertEqual($0 as? BackupError, .deviceBusy) }
        XCTAssertFalse(fm.fileExists(atPath: udidDir.path))
        XCTAssertFalse(session.calls.contains { $0.hasPrefix("request") })
    }

    func testConnectionLossIsReportedAndLockReleased() throws {
        session.script = [.message(DLMessage(["DLMessageGetFreeDiskSpace"])!, raw: Data())] // then the script runs out
        XCTAssertThrowsError(try run()) {
            guard case .failed(let text)? = $0 as? BackupError else { return XCTFail("\($0)") }
            XCTAssertTrue(text.contains("connection"), text)
        }
        XCTAssertEqual(session.calls.last, "unlock")
    }

    func testCancelDuringTransferCleansUpAndReleasesLock() throws {
        let flag = CancellationFlag()
        session.script = [
            .run { flag.cancel() },
            .timeout(advance: 1),
        ]
        XCTAssertThrowsError(try run(cancel: flag)) { XCTAssertEqual($0 as? BackupError, .cancelled) }
        XCTAssertEqual(session.calls.last, "unlock")
        XCTAssertTrue(session.statuses.isEmpty)
    }

    func testCancelRequestedOnTheDevice() throws {
        session.script = [.event(.cancelRequestedOnDevice), .timeout(advance: 1)]
        XCTAssertThrowsError(try run()) { XCTAssertEqual($0 as? BackupError, .cancelled) }
    }

    func testCancelBeforeStartDoesNothing() throws {
        let flag = CancellationFlag()
        flag.cancel()
        XCTAssertThrowsError(try run(cancel: flag)) { XCTAssertEqual($0 as? BackupError, .cancelled) }
        XCTAssertTrue(session.calls.isEmpty)
    }

    // MARK: - Passcode

    func testPasscodePromptThenUnlockContinues() throws {
        session.onRequestBackup = { [session] in session!.script.insert(.event(.passcodePromptShown), at: 0) }
        session.script = [.timeout(advance: 30), .timeout(advance: 30), .event(.passcodePromptDismissed)]
        session.script += try successScript()
        let reports = Reports()
        _ = try run(passcodeWait: 300, reports: reports)
        let phases = reports.all.map(\.phase)
        let waiting = try XCTUnwrap(phases.firstIndex(of: .waitingForPasscode))
        XCTAssertTrue(phases[waiting...].contains(.transferring))
        XCTAssertEqual(reports.all.first { $0.phase == .waitingForPasscode }?.message, "Unlock your iPhone and enter its passcode")
    }

    func testPasscodeTimeoutCancelsCleanly() throws {
        session.onRequestBackup = { [session] in session!.script.insert(.event(.passcodePromptShown), at: 0) }
        session.script = Array(repeating: .timeout(advance: 60), count: 20)
        let reports = Reports()
        XCTAssertThrowsError(try run(passcodeWait: 300, reports: reports)) {
            XCTAssertEqual($0 as? BackupError, .passcodeTimeout)
        }
        XCTAssertTrue(reports.all.contains { $0.phase == .waitingForPasscode })
        XCTAssertEqual(session.calls.last, "unlock")
        XCTAssertNil(try readInfo()["Last Backup Date"], "a timed-out run is not a success")
        // 300 s of waiting: not much more than 5 minutes of fake time passed.
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(Date(timeIntervalSince1970: 1_800_000_000)), 400)
    }

    func testPasscodeIsAssumedWhenNoPromptNotificationArrivesOnModernIOS() throws {
        session.productVersion = "17.5"
        session.script = Array(repeating: .timeout(advance: 5), count: 100)
        let reports = Reports()
        XCTAssertThrowsError(try run(passcodeWait: 60, reports: reports)) {
            XCTAssertEqual($0 as? BackupError, .passcodeTimeout)
        }
        XCTAssertTrue(reports.all.contains { $0.phase == .waitingForPasscode })
    }

    func testOldIOSNeverAssumesAPasscodeWait() throws {
        session.productVersion = "15.0"
        session.script = Array(repeating: .timeout(advance: 5), count: 10) + [finish(code: 1)]
        let reports = Reports()
        XCTAssertThrowsError(try run(passcodeWait: 1, reports: reports)) {
            guard case .failed? = $0 as? BackupError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(reports.all.contains { $0.phase == .waitingForPasscode })
    }

    func testVersionCheck() {
        XCTAssertTrue(BackupRunner.versionAtLeast("16.1", major: 16, minor: 1))
        XCTAssertTrue(BackupRunner.versionAtLeast("17.0.2", major: 16, minor: 1))
        XCTAssertTrue(BackupRunner.versionAtLeast("26.1", major: 16, minor: 1))
        XCTAssertFalse(BackupRunner.versionAtLeast("16.0.3", major: 16, minor: 1))
        XCTAssertFalse(BackupRunner.versionAtLeast("15.7.1", major: 16, minor: 1))
        XCTAssertFalse(BackupRunner.versionAtLeast(nil, major: 16, minor: 1))
    }
}
