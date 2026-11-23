import XCTest
@testable import BackupCore

final class KnownDeviceStoreTests: XCTestCase {
    func testRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnownDeviceStore(fileURL: dir.appendingPathComponent("sub/devices.json"))
        XCTAssertEqual(store.load(), [])

        let device = KnownDevice(
            udid: "U1", name: "Phone", productType: "iPhone15,2", productVersion: "17.5",
            encryption: .encrypted, lastSeen: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save([device])
        XCTAssertEqual(store.load(), [device])
    }
}
