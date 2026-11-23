import XCTest
@testable import BackupCore

final class BackupFolderTests: XCTestCase {
    private func plist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private let newer = Date(timeIntervalSince1970: 1_700_100_000)

    func testInfoPlistDate() throws {
        let info = try plist(["Last Backup Date": older, "Device Name": "x"])
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: nil), older)
    }

    func testStatusPlistOnlyCountsWhenFinished() throws {
        let finished = try plist(["Date": newer, "SnapshotState": "finished"])
        let running = try plist(["Date": newer, "SnapshotState": "uploading"])
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: nil, statusPlist: finished), newer)
        XCTAssertNil(BackupMetadata.lastBackupDate(infoPlist: nil, statusPlist: running))
    }

    func testStatusWinsOverNewerInfoPlist() throws {
        // Finder/idevicebackup2 write Info.plist at the start of the *next* backup.
        let info = try plist(["Last Backup Date": newer])
        let status = try plist(["Date": older, "SnapshotState": "finished"])
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: status), older)
    }

    func testUnfinishedStatusIsNotASuccessEvenWithInfoPlist() throws {
        let info = try plist(["Last Backup Date": newer])
        let status = try plist(["Date": newer, "SnapshotState": "uploading"])
        XCTAssertNil(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: status))
        let fresh = try plist(["SnapshotState": "new"])
        XCTAssertNil(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: fresh))
    }

    func testInfoPlistFallbackWhenStatusMissingOrUnreadable() throws {
        let info = try plist(["Last Backup Date": older])
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: nil), older)
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: Data("junk".utf8)), older)
    }

    func testFinishedStatusWithoutDateFallsBackToInfoPlist() throws {
        let info = try plist(["Last Backup Date": older])
        let status = try plist(["SnapshotState": "finished"])
        XCTAssertEqual(BackupMetadata.lastBackupDate(infoPlist: info, statusPlist: status), older)
    }

    func testIsFinished() throws {
        XCTAssertTrue(BackupMetadata.isFinished(statusPlist: try plist(["SnapshotState": "finished"])))
        XCTAssertFalse(BackupMetadata.isFinished(statusPlist: try plist(["SnapshotState": "new"])))
        XCTAssertFalse(BackupMetadata.isFinished(statusPlist: nil))
    }

    func testGarbageAndMissing() {
        XCTAssertNil(BackupMetadata.lastBackupDate(infoPlist: nil, statusPlist: nil))
        XCTAssertNil(BackupMetadata.lastBackupDate(infoPlist: Data("nope".utf8), statusPlist: Data()))
    }

    func testReadsFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let udid = "00008030-001A2B3C4D5E802E"
        let dir = root.appendingPathComponent(udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plist(["Last Backup Date": older]).write(to: dir.appendingPathComponent("Info.plist"))

        let folder = BackupFolder(root: root)
        XCTAssertEqual(folder.lastBackupDate(udid: udid), older)
        XCTAssertNil(folder.lastBackupDate(udid: "unknown"))
        XCTAssertEqual(folder.accessStatus(), .granted)
    }
}

final class FullDiskAccessTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/backup")
    private let fallback = URL(fileURLWithPath: "/safari")

    private func status(_ outcomes: [String: FullDiskAccess.ProbeOutcome]) -> FullDiskAccess.Status {
        FullDiskAccess.status(backupRoot: root, probe: { outcomes[$0.path] ?? .other }, fallbackProbeURL: fallback)
    }

    func testReadableRootMeansGranted() {
        XCTAssertEqual(status(["/backup": .readable]), .granted)
    }

    func testDeniedRoot() {
        XCTAssertEqual(status(["/backup": .denied]), .denied)
    }

    func testMissingRootFallsBackToProtectedFolder() {
        XCTAssertEqual(status(["/backup": .missing, "/safari": .denied]), .denied)
        XCTAssertEqual(status(["/backup": .missing, "/safari": .readable]), .granted)
        XCTAssertEqual(status(["/backup": .missing, "/safari": .missing]), .unknown)
    }

    func testClassifyErrors() {
        XCTAssertEqual(FullDiskAccess.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)), .denied)
        XCTAssertEqual(FullDiskAccess.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)), .missing)
        XCTAssertEqual(FullDiskAccess.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))), .denied)
        let wrapped = NSError(
            domain: NSCocoaErrorDomain, code: 999,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertEqual(FullDiskAccess.classify(wrapped), .denied)
        XCTAssertEqual(FullDiskAccess.classify(NSError(domain: "x", code: 1)), .other)
    }
}
