import XCTest
@testable import BackupCore

private final class FakeBackend: DeviceBackend, @unchecked Sendable {
    var present: [ConnectedDevice] = []
    var result: DeviceReadResult = .failure(.unreachable("none"))
    var listError: Error?

    func listDevices() async throws -> [ConnectedDevice] {
        if let listError { throw listError }
        return present
    }

    func readDetails(udid: String) async -> DeviceReadResult { result }
}

@MainActor
final class DeviceMonitorTests: XCTestCase {
    func testTickPublishesDeviceWithBatteryAndBackupDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("UDID1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backupDate = Date(timeIntervalSince1970: 1_700_000_000)
        try PropertyListSerialization.data(fromPropertyList: ["Last Backup Date": backupDate], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Info.plist"))

        let backend = FakeBackend()
        backend.present = [ConnectedDevice(udid: "UDID1", connection: .wifi)]
        backend.result = .success(DeviceDetails(
            name: "Phone", battery: BatteryStatus(level: 55, isCharging: true), encryption: .unencrypted))

        let monitor = DeviceMonitor(
            backend: backend, store: nil, backupFolder: BackupFolder(root: root),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) })

        await monitor.tick()
        // The probe runs in a child task; give it a moment.
        for _ in 0..<50 where monitor.devices.first?.battery == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        await monitor.tick()

        let device = try XCTUnwrap(monitor.devices.first)
        XCTAssertEqual(device.name, "Phone")
        XCTAssertEqual(device.connections, [.wifi])
        XCTAssertEqual(device.battery, BatteryStatus(level: 55, isCharging: true))
        XCTAssertEqual(device.encryption, .unencrypted)
        XCTAssertEqual(device.lastBackup, backupDate)
        XCTAssertTrue(monitor.usbmuxAvailable)
    }

    func testUsbmuxFailureIsReported() async {
        let backend = FakeBackend()
        backend.listError = DeviceBackendError.usbmuxUnavailable(-3)
        let monitor = DeviceMonitor(backend: backend, store: nil, backupFolder: BackupFolder(root: URL(fileURLWithPath: "/nonexistent")))
        await monitor.tick()
        XCTAssertFalse(monitor.usbmuxAvailable)
    }
}
