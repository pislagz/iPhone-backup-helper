import XCTest
@testable import BackupCore

final class InfoPlistBuilderTests: XCTestCase {
    private let udid = "00008030-001A2B3C4D5E802E"
    private let lockdown = LockdownBackupInfo(
        global: [
            "BuildVersion": "21F79", "DeviceName": "Anna's iPhone", "ProductType": "iPhone15,2",
            "ProductVersion": "17.5.1", "SerialNumber": "SER1", "PhoneNumber": "+49 1",
            "InternationalMobileEquipmentIdentity": "35", "IntegratedCircuitCardIdentity": "89",
        ],
        iTunesSettings: ["Foo": true], minITunesVersion: "12.12")

    func testFinderStyleKeys() {
        let info = InfoPlistBuilder.build(
            udid: udid, existing: nil, lockdown: lockdown, iTunesFiles: ["iTunesPrefs": Data([9])],
            iBooksData: Data([7]), lastBackupDate: Date(timeIntervalSince1970: 5), newGUID: { "GUID1" })
        XCTAssertEqual(info["Build Version"] as? String, "21F79")
        XCTAssertEqual(info["Device Name"] as? String, "Anna's iPhone")
        XCTAssertEqual(info["Display Name"] as? String, "Anna's iPhone")
        XCTAssertEqual(info["GUID"] as? String, "GUID1")
        XCTAssertEqual(info["IMEI"] as? String, "35")
        XCTAssertEqual(info["ICCID"] as? String, "89")
        XCTAssertEqual(info["Phone Number"] as? String, "+49 1")
        XCTAssertEqual(info["Product Type"] as? String, "iPhone15,2")
        XCTAssertEqual(info["Product Version"] as? String, "17.5.1")
        XCTAssertEqual(info["Serial Number"] as? String, "SER1")
        XCTAssertEqual(info["Target Identifier"] as? String, udid)
        XCTAssertEqual(info["Target Type"] as? String, "Device")
        XCTAssertEqual(info["Unique Identifier"] as? String, udid.uppercased())
        XCTAssertEqual(info["iTunes Version"] as? String, "12.12")
        XCTAssertEqual(info["iBooks Data 2"] as? Data, Data([7]))
        XCTAssertEqual((info["iTunes Files"] as? [String: Data])?["iTunesPrefs"], Data([9]))
        XCTAssertEqual((info["iTunes Settings"] as? [String: Bool])?["Foo"], true)
        XCTAssertNotNil(info["Applications"] as? [String: Any])
        XCTAssertNotNil(info["Installed Applications"] as? [Any])
        XCTAssertEqual(info["Last Backup Date"] as? Date, Date(timeIntervalSince1970: 5))
        XCTAssertNil(info["MEID"])
    }

    func testExistingValuesAreKeptAndDateCanBeCleared() {
        let existing: [String: Any] = [
            "GUID": "OLD", "Applications": ["a": 1], "Installed Applications": ["a"], "Last Backup Date": Date(),
            "Something Finder Wrote": 1,
        ]
        let info = InfoPlistBuilder.build(
            udid: udid, existing: existing, lockdown: lockdown, lastBackupDate: nil, newGUID: { "NEW" })
        XCTAssertEqual(info["GUID"] as? String, "OLD")
        XCTAssertEqual(info["Installed Applications"] as? [String], ["a"])
        XCTAssertEqual(info["Something Finder Wrote"] as? Int, 1)
        XCTAssertNil(info["Last Backup Date"])
        XCTAssertEqual(info["iTunes Version"] as? String, "12.12")
    }

    func testDefaultITunesVersionAndRoundTrip() throws {
        let info = InfoPlistBuilder.build(
            udid: udid, existing: nil, lockdown: LockdownBackupInfo(global: [:]), lastBackupDate: nil)
        XCTAssertEqual(info["iTunes Version"] as? String, "10.0.1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try InfoPlistBuilder.write(info, to: url)
        let parsed = try XCTUnwrap(InfoPlistBuilder.parse(try Data(contentsOf: url)))
        XCTAssertEqual(parsed["Target Type"] as? String, "Device")
    }
}
