import XCTest
@testable import BackupCore

final class AppLogTests: XCTestCase {
    func testWritesLinesAndRotates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AppLog(directory: dir, maxBytes: 300, keepFiles: 3, mirrorToOSLog: false)

        log.log(.info, "backup", "first line")
        log.flush()
        let text = try String(contentsOf: log.logFileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("INFO [backup] first line"), text)

        for i in 0..<60 { log.log(.error, "backup", "line number \(i) with some padding to fill the file") }
        log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["iPhoneBackupHelper.1.log", "iPhoneBackupHelper.2.log", "iPhoneBackupHelper.log"])
        for name in names {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, 300, name)
        }
        let newest = try String(contentsOf: log.logFileURL, encoding: .utf8)
        XCTAssertTrue(newest.contains("line number 59"))
    }

    func testMultilineMessagesStayOnOneLine() {
        let line = AppLog.format(date: Date(timeIntervalSince1970: 0), level: .debug, category: "c", message: "a\nb")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(line.hasSuffix("a ⏎ b\n"))
    }
}
