import CLibimobiledevice
import XCTest
@testable import BackupCore

/// Exercises the real libplist (the bundled dylib) through the bridge used for mobilebackup2 messages.
final class PlistBridgeTests: XCTestCase {
    private func roundTrip(_ value: Any) throws -> Any {
        let node = try XCTUnwrap(PlistBridge.fromFoundation(value))
        defer { plist_free(node) }
        return try XCTUnwrap(PlistBridge.toFoundation(node))
    }

    func testDeviceLinkMessageShape() throws {
        let message: [Any] = [
            "DLMessageUploadFiles", ["a", "b"], 12.5, UInt64(1) << 40, true,
            ["ErrorCode": 0, "Name": "x"] as [String: Any],
        ]
        let back = try XCTUnwrap(try roundTrip(message) as? [Any])
        XCTAssertEqual(back[0] as? String, "DLMessageUploadFiles")
        XCTAssertEqual(back[1] as? [String], ["a", "b"])
        XCTAssertEqual((back[2] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertEqual((back[3] as? NSNumber)?.uint64Value, UInt64(1) << 40)
        XCTAssertEqual((back[4] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((back[5] as? [String: Any])?["Name"] as? String, "x")
    }

    func testScalarsAndDates() throws {
        XCTAssertEqual((try roundTrip(UInt64(123_456_789_012)) as? NSNumber)?.uint64Value, 123_456_789_012)
        XCTAssertEqual(try roundTrip("text") as? String, "text")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try roundTrip(["d": date] as [String: Any]) as? [String: Date], ["d": date])
        XCTAssertEqual(try roundTrip(Data([1, 2, 3])) as? Data, Data([1, 2, 3]))
    }
}
