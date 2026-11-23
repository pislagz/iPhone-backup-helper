import XCTest
@testable import BackupCore

final class DeviceInfoParserTests: XCTestCase {
    func testFullDetails() {
        let details = DeviceInfoParser.details(
            global: ["DeviceName": "Anna's iPhone", "ProductType": "iPhone15,2", "ProductVersion": "17.5.1"],
            battery: ["BatteryCurrentCapacity": 83, "BatteryIsCharging": true],
            backup: ["WillEncrypt": true],
            wireless: ["EnableWifiConnections": false])
        XCTAssertEqual(details.name, "Anna's iPhone")
        XCTAssertEqual(details.productType, "iPhone15,2")
        XCTAssertEqual(details.productVersion, "17.5.1")
        XCTAssertEqual(details.battery, BatteryStatus(level: 83, isCharging: true))
        XCTAssertEqual(details.encryption, .encrypted)
        XCTAssertEqual(details.wifiSyncEnabled, false)
    }

    func testMissingDomains() {
        let details = DeviceInfoParser.details(
            global: ["ProductType": "iPhone15,2"], battery: nil, backup: [:], wireless: nil)
        XCTAssertEqual(details.name, "iPhone 14 Pro")
        XCTAssertNil(details.battery)
        XCTAssertEqual(details.encryption, .unknown)
        XCTAssertNil(details.wifiSyncEnabled)
    }

    func testUnencrypted() {
        XCTAssertEqual(DeviceInfoParser.encryption(["WillEncrypt": false]), .unencrypted)
    }

    func testBatteryIsClamped() {
        XCTAssertEqual(DeviceInfoParser.batteryStatus(["BatteryCurrentCapacity": 140])?.level, 100)
    }

    func testParsesRealXMLPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>BatteryCurrentCapacity</key><integer>42</integer>
          <key>BatteryIsCharging</key><false/>
        </dict></plist>
        """
        let dict = try PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil) as? [String: Any]
        XCTAssertEqual(DeviceInfoParser.batteryStatus(dict), BatteryStatus(level: 42, isCharging: false))
    }
}
