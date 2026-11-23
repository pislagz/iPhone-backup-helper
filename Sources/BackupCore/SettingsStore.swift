import Combine
import Foundation

/// The on-disk shape of `settings.json`.
struct SettingsFile: Codable, Equatable {
    var version = 1
    var devices: [String: DeviceSettings] = [:]
    var general = GeneralSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        devices = (try? c.decodeIfPresent([String: DeviceSettings].self, forKey: .devices)) ?? [:]
        general = (try? c.decodeIfPresent(GeneralSettings.self, forKey: .general)) ?? GeneralSettings()
    }
}

/// Thread-safe copy of the notification toggles, so notifiers (not bound to the main actor) can read them.
public final class NotificationPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var current: GeneralSettings

    public init(_ initial: GeneralSettings = GeneralSettings()) { current = initial }

    public var value: GeneralSettings {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Persists per-device and general settings as JSON in Application Support.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public private(set) var devices: [String: DeviceSettings]
    @Published public var general: GeneralSettings {
        didSet {
            guard general != oldValue else { return }
            notificationPreferences.value = general
            save()
        }
    }

    public let notificationPreferences: NotificationPreferences
    public let fileURL: URL?

    nonisolated public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iPhoneBackupHelper/settings.json")
    }

    /// `fileURL == nil` keeps everything in memory (tests, previews).
    public init(fileURL: URL? = SettingsStore.defaultFileURL) {
        self.fileURL = fileURL
        let file = fileURL.map(SettingsStore.load) ?? SettingsFile()
        devices = file.devices
        general = file.general
        notificationPreferences = NotificationPreferences(file.general)
    }

    /// Settings of a device; defaults (automatic backups off) for devices never configured.
    public func settings(for udid: String) -> DeviceSettings {
        devices[udid] ?? DeviceSettings()
    }

    public func update(_ udid: String, _ settings: DeviceSettings) {
        var settings = settings
        settings.normalize()
        guard devices[udid] != settings else { return }
        devices[udid] = settings
        save()
    }

    /// Drops the settings of a device (its backups on disk are not touched).
    public func forget(_ udid: String) {
        guard devices.removeValue(forKey: udid) != nil else { return }
        save()
    }

    // MARK: - Persistence

    static func load(_ url: URL) -> SettingsFile {
        guard let data = try? Data(contentsOf: url) else { return SettingsFile() }
        if let file = try? JSONDecoder().decode(SettingsFile.self, from: data) { return file }
        // Unreadable file: keep it for inspection instead of silently overwriting it.
        let aside = url.deletingLastPathComponent().appendingPathComponent("settings.corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return SettingsFile()
    }

    private func save() {
        guard let fileURL else { return }
        var file = SettingsFile()
        file.devices = devices
        file.general = general
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.log(.error, "settings", "could not save settings: \(error)")
        }
    }
}

/// Notifier decorator that honours the notification toggles.
public final class FilteringNotifier: BackupNotifying {
    private let base: BackupNotifying
    private let preferences: NotificationPreferences

    public init(base: BackupNotifying, preferences: NotificationPreferences) {
        self.base = base
        self.preferences = preferences
    }

    public func backupStarted(deviceName: String) {
        if preferences.value.notifyStarted { base.backupStarted(deviceName: deviceName) }
    }

    public func backupNeedsPasscode(deviceName: String) {
        if preferences.value.notifyNeedsPasscode { base.backupNeedsPasscode(deviceName: deviceName) }
    }

    public func backupFinished(deviceName: String, duration: TimeInterval, bytes: Int64) {
        if preferences.value.notifyFinished { base.backupFinished(deviceName: deviceName, duration: duration, bytes: bytes) }
    }

    public func backupFailed(deviceName: String, reason: String) {
        if preferences.value.notifyFailed { base.backupFailed(deviceName: deviceName, reason: reason) }
    }
}
