import XCTest
@testable import BackupCore

final class BackupMessageHandlerTests: XCTestCase {
    private var root: URL!
    private var transport: FakeTransport!
    private let udid = "00008030-AAAA"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = try makeTempDir()
        transport = FakeTransport()
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private func makeHandler(
        chunk: Int = 32 * 1024, cancelled: @escaping () -> Bool = { false }
    ) -> BackupMessageHandler {
        var config = BackupMessageHandler.Config()
        config.chunkSize = chunk
        config.stallTimeout = 0 // an empty raw read is a failure in tests, never a wait
        return BackupMessageHandler(root: root, transport: transport, config: config, isCancelled: cancelled)
    }

    private func message(_ items: [Any]) -> DLMessage { DLMessage(items)! }

    private func write(_ relative: String, _ content: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    // MARK: - Simple messages

    func testDisconnectAndProcessMessage() throws {
        let handler = makeHandler()
        XCTAssertEqual(try handler.handle(message(["DLMessageDisconnect", "bye"])), .disconnect)
        let ok = message(["DLMessageProcessMessage", ["ErrorCode": 0]])
        XCTAssertEqual(try handler.handle(ok), .finished(errorCode: 0, description: nil))
        let bad = message(["DLMessageProcessMessage", ["ErrorCode": 211, "ErrorDescription": "Passcode required"]])
        XCTAssertEqual(try handler.handle(bad), .finished(errorCode: 211, description: "Passcode required"))
    }

    func testUnknownMessageIsIgnored() throws {
        XCTAssertEqual(try makeHandler().handle(message(["DLMessageSomethingNew"])), .continue)
        XCTAssertTrue(transport.statuses.isEmpty)
    }

    func testProgressIsTakenFromTheMessages() throws {
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageRemoveFiles", [Any](), 0, 12.5]))
        XCTAssertEqual(handler.progressPercent, 12.5)
        _ = try handler.handle(message(["DLMessageMoveFiles", [String: Any](), 0, 40.0]))
        XCTAssertEqual(handler.progressPercent, 40)
    }

    func testGetFreeDiskSpace() throws {
        _ = try makeHandler().handle(message(["DLMessageGetFreeDiskSpace"]))
        XCTAssertEqual(transport.statuses.count, 1)
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertGreaterThan((transport.statuses[0].payload as? UInt64) ?? 0, 0)
    }

    func testGetFreeDiskSpaceUsesCapacityForImportantUsage() throws {
        var config = BackupMessageHandler.Config()
        config.importantUsageSpace = { _ in 123_456_789 }
        config.systemFreeSpace = { _ in 1_000 }
        let handler = BackupMessageHandler(root: root, transport: transport, config: config)
        _ = try handler.handle(message(["DLMessageGetFreeDiskSpace"]))
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertEqual(transport.statuses[0].payload as? UInt64, 123_456_789)
    }

    func testGetFreeDiskSpaceFallsBackToSystemFree() throws {
        var config = BackupMessageHandler.Config()
        config.importantUsageSpace = { _ in nil }
        config.systemFreeSpace = { _ in 4_242 }
        let handler = BackupMessageHandler(root: root, transport: transport, config: config)
        _ = try handler.handle(message(["DLMessageGetFreeDiskSpace"]))
        XCTAssertEqual(transport.statuses[0].payload as? UInt64, 4_242)
    }

    func testPurgeDiskSpaceIsRefused() throws {
        _ = try makeHandler().handle(message(["DLMessagePurgeDiskSpace"]))
        XCTAssertEqual(transport.statuses[0].code, -1)
    }

    func testContentsOfDirectory() throws {
        try write("\(udid)/Status.plist", "12345")
        try fm.createDirectory(at: root.appendingPathComponent("\(udid)/ab"), withIntermediateDirectories: true)
        _ = try makeHandler().handle(message(["DLContentsOfDirectory", udid, 0, 0.0]))

        let listing = try XCTUnwrap(transport.statuses[0].payload as? [String: Any])
        XCTAssertEqual(Set(listing.keys), ["Status.plist", "ab"])
        let file = try XCTUnwrap(listing["Status.plist"] as? [String: Any])
        XCTAssertEqual(file["DLFileType"] as? String, "DLFileTypeRegular")
        XCTAssertEqual(file["DLFileSize"] as? UInt64, 5)
        XCTAssertNotNil(file["DLFileModificationDate"] as? Date)
        XCTAssertEqual((listing["ab"] as? [String: Any])?["DLFileType"] as? String, "DLFileTypeDirectory")
    }

    func testContentsOfMissingDirectoryIsEmpty() throws {
        _ = try makeHandler().handle(message(["DLContentsOfDirectory", "nope"]))
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertEqual((transport.statuses[0].payload as? [String: Any])?.count, 0)
    }

    func testCreateDirectory() throws {
        _ = try makeHandler().handle(message(["DLMessageCreateDirectory", "\(udid)/Snapshot/ab"]))
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertTrue(exists("\(udid)/Snapshot/ab"))
    }

    func testCreateDirectoryOverExistingFileFails() throws {
        try write("\(udid)/file", "x")
        _ = try makeHandler().handle(message(["DLMessageCreateDirectory", "\(udid)/file"]))
        XCTAssertNotEqual(transport.statuses[0].code, 0)
    }

    func testPathsCannotEscapeTheBackupFolder() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("ibh-escape-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: outside) }
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageCreateDirectory", "../\(outside.lastPathComponent)"]))
        XCTAssertEqual(transport.statuses[0].code, -1)
        XCTAssertFalse(fm.fileExists(atPath: outside.path))

        try write("keep.txt", "keep")
        _ = try handler.handle(message(["DLMessageRemoveFiles", ["a/../../x", ".."], 0, 0.0]))
        XCTAssertEqual(transport.statuses[1].code, -1)
        XCTAssertTrue(exists("keep.txt"))

        _ = try handler.handle(message(["DLMessageMoveFiles", ["keep.txt": "../moved.txt"], 0, 0.0]))
        XCTAssertEqual(transport.statuses[2].code, -1)
        XCTAssertTrue(exists("keep.txt"))
    }

    func testMoveFilesReplacesTargets() throws {
        try write("\(udid)/Manifest.db.tmp", "new")
        try write("\(udid)/Manifest.db", "old")
        try write("\(udid)/Snapshot/a", "a")
        _ = try makeHandler().handle(message([
            "DLMessageMoveFiles",
            ["\(udid)/Manifest.db.tmp": "\(udid)/Manifest.db", "\(udid)/Snapshot/a": "\(udid)/Final/a"],
            0, 50.0,
        ]))
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertEqual(read("\(udid)/Manifest.db"), "new")
        XCTAssertFalse(exists("\(udid)/Manifest.db.tmp"))
        XCTAssertEqual(read("\(udid)/Final/a"), "a")
    }

    func testMoveItemsMissingSourceReportsNoSuchFile() throws {
        _ = try makeHandler().handle(message(["DLMessageMoveItems", ["\(udid)/gone": "\(udid)/there"], 0, 0.0]))
        XCTAssertEqual(transport.statuses[0].code, -6)
        XCTAssertNotNil(transport.statuses[0].description)
    }

    func testRemoveFilesAndItems() throws {
        try write("\(udid)/a", "a")
        try write("\(udid)/dir/b", "b")
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageRemoveFiles", ["\(udid)/a", "\(udid)/missing"], 0, 0.0]))
        XCTAssertEqual(transport.statuses[0].code, 0, "removing something that is already gone is fine")
        XCTAssertFalse(exists("\(udid)/a"))
        _ = try handler.handle(message(["DLMessageRemoveItems", ["\(udid)/dir"], 0, 0.0]))
        XCTAssertEqual(transport.statuses[1].code, 0)
        XCTAssertFalse(exists("\(udid)/dir"))
    }

    func testCopyItemFileAndDirectory() throws {
        try write("\(udid)/Manifest.plist", "m")
        try write("\(udid)/Snap/x", "x")
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageCopyItem", "\(udid)/Manifest.plist", "\(udid)/Manifest.plist.bak"]))
        XCTAssertEqual(read("\(udid)/Manifest.plist.bak"), "m")
        _ = try handler.handle(message(["DLMessageCopyItem", "\(udid)/Snap", "\(udid)/Snap2"]))
        XCTAssertEqual(read("\(udid)/Snap2/x"), "x")
        XCTAssertEqual(transport.statuses.map(\.code), [0, 0])
    }

    // MARK: - DLMessageDownloadFiles (computer → device)

    func testDownloadFilesFramesDataAndReportsMissingFiles() throws {
        try write("\(udid)/Manifest.plist", "0123456789")
        try write("\(udid)/empty", "")
        _ = try makeHandler(chunk: 4).handle(message([
            "DLMessageDownloadFiles", ["\(udid)/Manifest.plist", "\(udid)/empty", "\(udid)/missing"], 0, 10.0,
        ]))

        var expected = Data()
        func path(_ p: String) { expected += be32(p.utf8.count) + Data(p.utf8) }
        path("\(udid)/Manifest.plist")
        for part in ["0123", "4567", "89"] { expected += be32(part.utf8.count + 1) + Data([0x0c]) + Data(part.utf8) }
        expected += be32(1) + Data([0x00])
        path("\(udid)/empty")
        expected += be32(1) + Data([0x00])
        path("\(udid)/missing")
        let text = String(cString: strerror(ENOENT))
        expected += be32(text.utf8.count + 1) + Data([0x06]) + Data(text.utf8)
        expected += be32(0)
        XCTAssertEqual(transport.sentRaw, expected)

        XCTAssertEqual(transport.statuses.count, 1)
        XCTAssertEqual(transport.statuses[0].code, -13)
        XCTAssertEqual(transport.statuses[0].description, "Multi status")
        let errors = try XCTUnwrap(transport.statuses[0].payload as? [String: Any])
        XCTAssertEqual(Array(errors.keys), ["\(udid)/missing"])
        let entry = try XCTUnwrap(errors["\(udid)/missing"] as? [String: Any])
        XCTAssertEqual(entry["DLFileErrorCode"] as? Int, -6)
        XCTAssertEqual(entry["DLFileErrorString"] as? String, text)
    }

    func testDownloadFilesAllOKSendsEmptySuccessStatus() throws {
        try write("\(udid)/a", "x")
        _ = try makeHandler().handle(message(["DLMessageDownloadFiles", ["\(udid)/a"], 0, 0.0]))
        XCTAssertEqual(transport.statuses[0].code, 0)
        XCTAssertEqual((transport.statuses[0].payload as? [String: Any])?.count, 0)
        XCTAssertTrue(transport.sentRaw.suffix(4) == be32(0))
    }

    func testDownloadFilesCanBeCancelled() throws {
        try write("\(udid)/a", String(repeating: "x", count: 100))
        let handler = makeHandler(chunk: 10, cancelled: { true })
        XCTAssertThrowsError(try handler.handle(message(["DLMessageDownloadFiles", ["\(udid)/a"], 0, 0.0]))) {
            XCTAssertEqual($0 as? BackupError, .cancelled)
        }
    }

    // MARK: - DLMessageUploadFiles (device → computer)

    func testUploadFilesWritesFilesAtomically() throws {
        try write("\(udid)/Manifest.db", "old contents")
        transport.rawInput =
            Stream.file(path: "\(udid)/Status.plist", chunks: [Data("sta".utf8), Data("tus".utf8)])
            + Stream.file(path: "\(udid)/ab/abcdef", chunks: [Data("payload".utf8)])
            + Stream.file(path: "\(udid)/Manifest.db", chunks: [Data("new".utf8)])
            + Stream.file(path: "\(udid)/zero", chunks: [])
            + Stream.terminator
        let handler = makeHandler(chunk: 3)
        XCTAssertEqual(try handler.handle(message(["DLMessageUploadFiles", 0, 7.5, 1000])), .continue)

        XCTAssertEqual(read("\(udid)/Status.plist"), "status")
        XCTAssertEqual(read("\(udid)/ab/abcdef"), "payload")
        XCTAssertEqual(read("\(udid)/Manifest.db"), "new")
        XCTAssertEqual(read("\(udid)/zero"), "")
        XCTAssertEqual(handler.bytesReceived, 6 + 7 + 3)
        XCTAssertEqual(handler.filesReceived, 4)
        XCTAssertEqual(handler.progressPercent, 7.5)
        XCTAssertEqual(transport.statuses.map(\.code), [0])
        XCTAssertTrue(transport.rawInput.isEmpty)

        let leftovers = try fm.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(BackupMessageHandler.partSuffix) }
        XCTAssertEqual(leftovers, [])
    }

    func testUploadFilesRemoteErrorEndFrameAfterDataCountsAsComplete() throws {
        // The device sometimes ends a file with 0x0b; after data frames that is not an error.
        transport.rawInput =
            Stream.file(path: "\(udid)/f", chunks: [Data("abc".utf8)], end: 0x0b, endText: "")
            + Stream.terminator
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageUploadFiles", 0, 0.0, 3]))
        XCTAssertEqual(read("\(udid)/f"), "abc")
        XCTAssertEqual(transport.statuses[0].code, 0)
    }

    func testUploadFilesUnreadableOnDeviceRemovesStaleCopy() throws {
        try write("\(udid)/stale", "old")
        transport.rawInput =
            Stream.unreadable(path: "\(udid)/stale", text: "file vanished")
            + Stream.file(path: "\(udid)/next", chunks: [Data("n".utf8)])
            + Stream.terminator
        _ = try makeHandler().handle(message(["DLMessageUploadFiles", 0, 0.0, 1]))
        XCTAssertFalse(exists("\(udid)/stale"))
        XCTAssertEqual(read("\(udid)/next"), "n")
        XCTAssertEqual(transport.statuses[0].code, 0)
    }

    func testUploadFilesRejectsEscapingPathButStaysInSync() throws {
        let outside = "../ibh-escape-\(UUID().uuidString)"
        transport.rawInput =
            Stream.file(path: outside, chunks: [Data("evil".utf8)])
            + Stream.terminator
        let handler = makeHandler()
        _ = try handler.handle(message(["DLMessageUploadFiles", 0, 0.0, 4]))
        XCTAssertFalse(fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent(String(outside.dropFirst(3))).path))
        XCTAssertEqual(transport.statuses[0].code, -1)
        XCTAssertEqual(transport.rawInput, Stream.terminator, "the file's data frames were consumed, nothing else")
        XCTAssertEqual(handler.bytesReceived, 0)
    }

    func testUploadFilesCancelLeavesNoPartialFile() throws {
        transport.rawInput =
            Stream.file(path: "\(udid)/big", chunks: [Data("aaaa".utf8), Data("bbbb".utf8)])
            + Stream.terminator
        var calls = 0
        let handler = makeHandler(chunk: 4, cancelled: { calls += 1; return calls > 8 })
        XCTAssertThrowsError(try handler.handle(message(["DLMessageUploadFiles", 0, 0.0, 8]))) {
            XCTAssertEqual($0 as? BackupError, .cancelled)
        }
        handler.abort()
        XCTAssertFalse(exists("\(udid)/big"))
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(udid).path)) ?? [], [])
    }

    func testUploadFilesStalledConnectionFailsInsteadOfHanging() throws {
        // Header announces data that never arrives.
        transport.rawInput = Stream.name("dev") + Stream.name("\(udid)/f") + be32(11) + Data([0x0c]) + Data("abc".utf8)
        let handler = makeHandler()
        XCTAssertThrowsError(try handler.handle(message(["DLMessageUploadFiles", 0, 0.0, 10]))) {
            guard case .failed? = ($0 as? BackupError) else { return XCTFail("unexpected \($0)") }
        }
        handler.abort()
        XCTAssertFalse(exists("\(udid)/f"))
        XCTAssertFalse(exists("\(udid)/f\(BackupMessageHandler.partSuffix)"))
    }

    func testSweepStalePartsRemovesLeftovers() throws {
        try write("\(udid)/x.ibh-part", "1")
        try write("\(udid)/ab/y.ibh-part", "2")
        try write("\(udid)/ab/keep", "3")
        BackupMessageHandler.sweepStaleParts(in: root.appendingPathComponent(udid))
        XCTAssertFalse(exists("\(udid)/x.ibh-part"))
        XCTAssertFalse(exists("\(udid)/ab/y.ibh-part"))
        XCTAssertTrue(exists("\(udid)/ab/keep"))
    }
}
