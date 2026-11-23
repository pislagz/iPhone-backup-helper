import XCTest
@testable import BackupCore

final class DeviceRegistryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let udid = "00008030-AAAA"

    private func details(battery: Int = 80) -> DeviceDetails {
        DeviceDetails(
            name: "Anna's iPhone", productType: "iPhone15,2", productVersion: "17.5",
            battery: BatteryStatus(level: battery, isCharging: false), encryption: .encrypted)
    }

    func testAttachSchedulesImmediateProbeThenRefresh() {
        var registry = DeviceRegistry()
        registry.applyConnections([ConnectedDevice(udid: udid, connection: .usb)], now: t0)
        XCTAssertEqual(registry.udidsDueForProbe(now: t0), [udid])

        registry.markProbing(udid)
        XCTAssertTrue(registry.udidsDueForProbe(now: t0).isEmpty)

        let known = registry.applyRead(udid: udid, result: .success(details()), now: t0)
        XCTAssertEqual(known?.name, "Anna's iPhone")
        XCTAssertTrue(registry.udidsDueForProbe(now: t0.addingTimeInterval(119)).isEmpty)
        XCTAssertEqual(registry.udidsDueForProbe(now: t0.addingTimeInterval(120)), [udid])
    }

    func testUSBAndWiFiMerge() {
        var registry = DeviceRegistry()
        registry.applyConnections([
            ConnectedDevice(udid: udid, connection: .wifi), ConnectedDevice(udid: udid, connection: .usb),
        ], now: t0)
        let state = registry.states().first
        XCTAssertEqual(state?.connections, [.usb, .wifi])
        XCTAssertEqual(state?.preferredConnection, .usb)
    }

    func testDetachKeepsKnownDeviceAsUnreachable() {
        var registry = DeviceRegistry()
        registry.applyConnections([ConnectedDevice(udid: udid, connection: .usb)], now: t0)
        registry.applyRead(udid: udid, result: .success(details()), now: t0)
        let detached = registry.applyConnections([], now: t0.addingTimeInterval(10))
        XCTAssertTrue(detached)

        let state = registry.states().first
        XCTAssertEqual(state?.isReachable, false)
        XCTAssertEqual(state?.name, "Anna's iPhone")
        XCTAssertNil(state?.battery, "stale battery must not be shown for an absent device")
        XCTAssertEqual(state?.encryption, .encrypted)
        XCTAssertEqual(registry.knownDevices().first?.lastSeen, t0, "lastSeen is the last tick the device was present")
    }

    func testStaleProbeResultAfterDetachIsIgnored() {
        var registry = DeviceRegistry()
        registry.applyConnections([ConnectedDevice(udid: udid, connection: .wifi)], now: t0)
        registry.markProbing(udid)
        registry.applyConnections([], now: t0)
        XCTAssertNil(registry.applyRead(udid: udid, result: .success(details()), now: t0))
        XCTAssertNil(registry.states().first?.battery)
    }

    func testStaleProbeFromBeforeQuickReattachIsDropped() {
        var registry = DeviceRegistry()
        let usb = [ConnectedDevice(udid: udid, connection: .usb)]
        registry.applyConnections(usb, now: t0)
        let stale = registry.markProbing(udid)

        // Detach and re-attach before the first probe returns.
        registry.applyConnections([], now: t0.addingTimeInterval(1))
        registry.applyConnections(usb, now: t0.addingTimeInterval(2))
        XCTAssertEqual(registry.udidsDueForProbe(now: t0.addingTimeInterval(2)), [udid], "reattach probes again")
        let fresh = registry.markProbing(udid)
        XCTAssertNotEqual(stale, fresh)

        // The stale result arrives first: ignored, and it must not clear the newer probe's in-flight flag.
        XCTAssertNil(registry.applyRead(
            udid: udid, result: .success(details(battery: 11)), now: t0.addingTimeInterval(3), generation: stale))
        XCTAssertNil(registry.states().first?.battery)
        XCTAssertTrue(registry.udidsDueForProbe(now: t0.addingTimeInterval(3)).isEmpty, "second probe still in flight")

        // The current probe's result is applied.
        XCTAssertNotNil(registry.applyRead(
            udid: udid, result: .success(details(battery: 77)), now: t0.addingTimeInterval(4), generation: fresh))
        XCTAssertEqual(registry.states().first?.battery?.level, 77)
    }

    func testNeedsTrustBacksOffAndRecovers() {
        var registry = DeviceRegistry()
        registry.applyConnections([ConnectedDevice(udid: udid, connection: .usb)], now: t0)
        registry.applyRead(udid: udid, result: .failure(.needsTrust), now: t0)
        XCTAssertEqual(registry.states().first?.issue, .needsTrust)
        XCTAssertTrue(registry.udidsDueForProbe(now: t0.addingTimeInterval(29)).isEmpty)
        XCTAssertEqual(registry.udidsDueForProbe(now: t0.addingTimeInterval(30)), [udid])

        registry.applyRead(udid: udid, result: .success(details()), now: t0.addingTimeInterval(30))
        XCTAssertNil(registry.states().first?.issue)
    }

    func testKnownDevicesLoadedAsUnreachable() {
        let known = KnownDevice(udid: udid, name: "Old phone", productType: "iPhone12,1", lastSeen: t0)
        let registry = DeviceRegistry(known: [known])
        let state = registry.states().first
        XCTAssertEqual(state?.name, "Old phone")
        XCTAssertEqual(state?.modelName, "iPhone 11")
        XCTAssertEqual(state?.isReachable, false)
        XCTAssertEqual(state?.lastSeen, t0)
    }

    func testReachableSortedFirst() {
        var registry = DeviceRegistry(known: [KnownDevice(udid: "A", name: "Aardvark", lastSeen: t0)])
        registry.applyConnections([ConnectedDevice(udid: "Z", connection: .usb)], now: t0)
        registry.applyRead(udid: "Z", result: .success(DeviceDetails(name: "Zed")), now: t0)
        XCTAssertEqual(registry.states().map(\.name), ["Zed", "Aardvark"])
    }

    func testLastBackupAttached() {
        var registry = DeviceRegistry()
        registry.applyConnections([ConnectedDevice(udid: udid, connection: .usb)], now: t0)
        registry.applyLastBackup(udid: udid, date: t0)
        XCTAssertEqual(registry.states().first?.lastBackup, t0)
    }
}
