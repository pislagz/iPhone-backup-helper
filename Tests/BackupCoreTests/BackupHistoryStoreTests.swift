import XCTest
@testable import BackupCore

@MainActor
final class BackupHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("state.json") }
    private let t1 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t2 = Date(timeIntervalSince1970: 1_800_003_600)

    override func setUpWithError() throws { dir = try makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRoundTrip() {
        let store = BackupHistoryStore(fileURL: file)
        store.recordFailure("A", at: t1)
        store.recordSuccess("B", at: t2)
        let reloaded = BackupHistoryStore(fileURL: file)
        XCTAssertEqual(reloaded.history(for: "A"), DeviceBackupHistory(lastSuccess: nil, lastFailedAttempt: t1))
        XCTAssertEqual(reloaded.history(for: "B"), DeviceBackupHistory(lastSuccess: t2, lastFailedAttempt: nil))
        XCTAssertEqual(reloaded.history(for: "unknown"), DeviceBackupHistory())
    }

    func testSuccessClearsTheFailedAttemptAndNeverMovesBackwards() {
        let store = BackupHistoryStore(fileURL: nil)
        store.recordFailure("A", at: t1)
        store.recordSuccess("A", at: t2)
        XCTAssertEqual(store.history(for: "A"), DeviceBackupHistory(lastSuccess: t2, lastFailedAttempt: nil))
        store.recordSuccess("A", at: t1)
        XCTAssertEqual(store.history(for: "A").lastSuccess, t2)
    }

    func testForgetRemovesTheDevice() {
        let store = BackupHistoryStore(fileURL: file)
        store.recordSuccess("A", at: t1)
        store.forget("A")
        XCTAssertEqual(BackupHistoryStore(fileURL: file).history(for: "A"), DeviceBackupHistory())
    }

    func testCorruptFileIsKeptAsideAndIgnored() throws {
        try Data("not json".utf8).write(to: file)
        let store = BackupHistoryStore(fileURL: file)
        XCTAssertEqual(store.history(for: "A"), DeviceBackupHistory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.corrupt.json").path))
        store.recordSuccess("A", at: t1) // and it keeps working
        XCTAssertEqual(BackupHistoryStore(fileURL: file).history(for: "A").lastSuccess, t1)
    }

    func testMissingFileStartsEmpty() {
        XCTAssertEqual(BackupHistoryStore(fileURL: file).history(for: "A"), DeviceBackupHistory())
    }
}
