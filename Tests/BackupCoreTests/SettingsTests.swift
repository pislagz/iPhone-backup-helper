import XCTest
@testable import BackupCore

final class DeviceSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> DeviceSettings {
        try JSONDecoder().decode(DeviceSettings.self, from: Data(json.utf8))
    }

    func testRoundTrip() throws {
        let settings = DeviceSettings(
            enabled: true, frequency: .weekly, everyHours: 6, weeklyDays: [1, 7],
            windowEnabled: true, windowStartMinute: 22 * 60, windowEndMinute: 90,
            minBatteryPercent: 35, ignoreBatteryIfCharging: false, connectionPolicy: .usbOnly,
            requireACPower: true, minFreeDiskGB: 50, minIntervalHours: 20,
            passcodeWaitSeconds: 600, retryIntervalMinutes: 15)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(DeviceSettings.self, from: data), settings)
    }

    func testEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try decode("{}"), DeviceSettings())
        XCTAssertFalse(DeviceSettings().enabled, "automatic backups are opt-in")
    }

    func testOlderStubFormatIsRead() throws {
        let settings = try decode(#"{"automaticBackupsEnabled": true, "connectionPolicy": "usbOnly", "minimumBatteryPercent": 50, "passcodeWaitSeconds": 120}"#)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.connectionPolicy, .usbOnly)
        XCTAssertEqual(settings.passcodeWaitSeconds, 120)
        XCTAssertEqual(settings.minBatteryPercent, DeviceSettings().minBatteryPercent)
    }

    func testWrongTypesAndUnknownValuesFallBackFieldByField() throws {
        let settings = try decode(#"{"enabled": true, "frequency": "fortnightly", "everyHours": "soon", "connectionPolicy": 3, "futureField": [1], "minFreeDiskGB": 40}"#)
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.frequency, DeviceSettings().frequency)
        XCTAssertEqual(settings.everyHours, DeviceSettings().everyHours)
        XCTAssertEqual(settings.connectionPolicy, DeviceSettings().connectionPolicy)
        XCTAssertEqual(settings.minFreeDiskGB, 40)
    }

    func testValuesAreClamped() throws {
        let settings = try decode(#"{"everyHours": 0, "weeklyDays": [0, 3, 9], "windowStartMinute": 5000, "windowEndMinute": -4, "minBatteryPercent": 400, "minFreeDiskGB": -1, "minIntervalHours": -5, "passcodeWaitSeconds": 1, "retryIntervalMinutes": 0}"#)
        XCTAssertEqual(settings.everyHours, 1)
        XCTAssertEqual(settings.weeklyDays, [3])
        XCTAssertEqual(settings.windowStartMinute, 1439)
        XCTAssertEqual(settings.windowEndMinute, 0)
        XCTAssertEqual(settings.minBatteryPercent, 100)
        XCTAssertEqual(settings.minFreeDiskGB, 0)
        XCTAssertEqual(settings.minIntervalHours, 0)
        XCTAssertEqual(settings.passcodeWaitSeconds, 30)
        XCTAssertEqual(settings.retryIntervalMinutes, 1)
    }

    func testNotADictionaryGivesDefaults() throws {
        XCTAssertEqual(try decode("[1,2]"), DeviceSettings())
    }

    func testGeneralSettingsAreTolerant() throws {
        let general = try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"notifyFailed": false, "notifyStarted": "x"}"#.utf8))
        XCTAssertFalse(general.notifyFailed)
        XCTAssertEqual(general.notifyStarted, GeneralSettings().notifyStarted)
        XCTAssertTrue(general.notifyFinished)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private lazy var dir: URL = {
        let url = try! makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()
    private var file: URL { dir.appendingPathComponent("sub/settings.json") }

    func testUnknownDeviceGetsDefaults() {
        let store = SettingsStore(fileURL: file)
        XCTAssertEqual(store.settings(for: "X"), DeviceSettings())
    }

    func testPersistsAcrossInstances() {
        let store = SettingsStore(fileURL: file)
        var settings = DeviceSettings(enabled: true)
        settings.minBatteryPercent = 55
        store.update("A", settings)
        store.general.notifyStarted = true

        let reloaded = SettingsStore(fileURL: file)
        XCTAssertEqual(reloaded.settings(for: "A").minBatteryPercent, 55)
        XCTAssertTrue(reloaded.settings(for: "A").enabled)
        XCTAssertTrue(reloaded.general.notifyStarted)
        XCTAssertTrue(reloaded.notificationPreferences.value.notifyStarted)
    }

    func testForgetRemovesSettings() {
        let store = SettingsStore(fileURL: file)
        store.update("A", DeviceSettings(enabled: true))
        store.update("B", DeviceSettings(enabled: true))
        store.forget("A")
        let reloaded = SettingsStore(fileURL: file)
        XCTAssertEqual(reloaded.devices.keys.sorted(), ["B"])
    }

    func testUpdateClampsValues() {
        let store = SettingsStore(fileURL: file)
        var settings = DeviceSettings()
        settings.minBatteryPercent = 999
        store.update("A", settings)
        XCTAssertEqual(store.settings(for: "A").minBatteryPercent, 100)
    }

    func testCorruptFileIsKeptAsideAndDefaultsUsed() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = SettingsStore(fileURL: file)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("settings.corrupt.json").path))
    }

    func testOneBrokenDeviceEntryDoesNotLoseTheOthers() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 1, "devices": {"A": {"enabled": true, "minBatteryPercent": "x"}, "B": 5}, "general": {}}"#.utf8).write(to: file)
        let store = SettingsStore(fileURL: file)
        XCTAssertTrue(store.settings(for: "A").enabled)
        XCTAssertEqual(store.settings(for: "A").minBatteryPercent, DeviceSettings().minBatteryPercent)
        XCTAssertEqual(store.settings(for: "B"), DeviceSettings(), "an entry that is not an object becomes defaults")
        XCTAssertEqual(store.general, GeneralSettings())
    }

    func testInMemoryStore() {
        let store = SettingsStore(fileURL: nil)
        store.update("A", DeviceSettings(enabled: true))
        XCTAssertTrue(store.settings(for: "A").enabled)
    }
}

final class FilteringNotifierTests: XCTestCase {
    private final class Recorder: BackupNotifying {
        var events: [String] = []
        func backupStarted(deviceName: String) { events.append("started") }
        func backupNeedsPasscode(deviceName: String) { events.append("passcode") }
        func backupFinished(deviceName: String, duration: TimeInterval, bytes: Int64) { events.append("finished") }
        func backupFailed(deviceName: String, reason: String) { events.append("failed") }
    }

    private func fire(_ notifier: BackupNotifying) {
        notifier.backupStarted(deviceName: "d")
        notifier.backupNeedsPasscode(deviceName: "d")
        notifier.backupFinished(deviceName: "d", duration: 1, bytes: 1)
        notifier.backupFailed(deviceName: "d", reason: "r")
    }

    func testDefaultsSkipOnlyTheStartedNotification() {
        let recorder = Recorder()
        fire(FilteringNotifier(base: recorder, preferences: NotificationPreferences()))
        XCTAssertEqual(recorder.events, ["passcode", "finished", "failed"])
    }

    func testEveryToggleIsRespectedAndLive() {
        let recorder = Recorder()
        let preferences = NotificationPreferences(GeneralSettings(
            notifyStarted: true, notifyNeedsPasscode: false, notifyFinished: false, notifyFailed: false))
        let notifier = FilteringNotifier(base: recorder, preferences: preferences)
        fire(notifier)
        XCTAssertEqual(recorder.events, ["started"])

        recorder.events = []
        preferences.value = GeneralSettings(notifyStarted: false, notifyNeedsPasscode: true, notifyFinished: true, notifyFailed: true)
        fire(notifier)
        XCTAssertEqual(recorder.events, ["passcode", "finished", "failed"])
    }
}
