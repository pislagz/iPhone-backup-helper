import Foundation

/// Per-device backup settings (persisted by `SettingsStore`). Decoding is tolerant: every field is
/// optional in the JSON and unknown/invalid values fall back to the defaults, so files written by
/// older (or newer) versions still load.
public struct DeviceSettings: Codable, Equatable, Sendable {
    public enum ConnectionPolicy: String, Codable, CaseIterable, Sendable {
        case usbOnly
        case usbOrWiFi
    }

    public enum FrequencyKind: String, Codable, CaseIterable, Sendable {
        case daily
        case everyHours
        case weekly
    }

    /// Automatic (scheduled) backups for this device.
    public var enabled: Bool
    public var frequency: FrequencyKind
    /// For `.everyHours`: 1...168.
    public var everyHours: Int
    /// For `.weekly`: `Calendar` weekday numbers (1 = Sunday ... 7 = Saturday).
    public var weeklyDays: Set<Int>

    /// Only start inside the time window.
    public var windowEnabled: Bool
    /// Minutes since local midnight (0...1439). The window may cross midnight (end <= start).
    /// start == end means "all day".
    public var windowStartMinute: Int
    public var windowEndMinute: Int

    /// 0 = no battery requirement.
    public var minBatteryPercent: Int
    public var ignoreBatteryIfCharging: Bool
    public var connectionPolicy: ConnectionPolicy
    public var requireACPower: Bool
    /// Decimal gigabytes; 0 = no requirement.
    public var minFreeDiskGB: Int
    /// Minimum time since the last successful backup (Finder backups count); 0 = none.
    public var minIntervalHours: Int
    /// How long to wait for the user to unlock the iPhone (passcode is needed on every backup).
    public var passcodeWaitSeconds: TimeInterval
    /// After a failed attempt, try again after this many minutes while still inside the window.
    public var retryIntervalMinutes: Int

    public static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    public init(
        enabled: Bool = false,
        frequency: FrequencyKind = .daily,
        everyHours: Int = 24,
        weeklyDays: Set<Int> = [2, 3, 4, 5, 6],
        windowEnabled: Bool = true,
        windowStartMinute: Int = 20 * 60,
        windowEndMinute: Int = 23 * 60,
        minBatteryPercent: Int = 20,
        ignoreBatteryIfCharging: Bool = true,
        connectionPolicy: ConnectionPolicy = .usbOrWiFi,
        requireACPower: Bool = false,
        minFreeDiskGB: Int = 10,
        minIntervalHours: Int = 12,
        passcodeWaitSeconds: TimeInterval = 300,
        retryIntervalMinutes: Int = 30
    ) {
        self.enabled = enabled
        self.frequency = frequency
        self.everyHours = everyHours
        self.weeklyDays = weeklyDays
        self.windowEnabled = windowEnabled
        self.windowStartMinute = windowStartMinute
        self.windowEndMinute = windowEndMinute
        self.minBatteryPercent = minBatteryPercent
        self.ignoreBatteryIfCharging = ignoreBatteryIfCharging
        self.connectionPolicy = connectionPolicy
        self.requireACPower = requireACPower
        self.minFreeDiskGB = minFreeDiskGB
        self.minIntervalHours = minIntervalHours
        self.passcodeWaitSeconds = passcodeWaitSeconds
        self.retryIntervalMinutes = retryIntervalMinutes
        normalize()
    }

    /// Clamps every value into its valid range.
    public mutating func normalize() {
        everyHours = min(168, max(1, everyHours))
        weeklyDays = weeklyDays.filter { (1...7).contains($0) }
        windowStartMinute = min(1439, max(0, windowStartMinute))
        windowEndMinute = min(1439, max(0, windowEndMinute))
        minBatteryPercent = min(100, max(0, minBatteryPercent))
        minFreeDiskGB = min(10_000, max(0, minFreeDiskGB))
        minIntervalHours = min(24 * 30, max(0, minIntervalHours))
        passcodeWaitSeconds = min(3_600, max(30, passcodeWaitSeconds))
        retryIntervalMinutes = min(24 * 60, max(1, retryIntervalMinutes))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, frequency, everyHours, weeklyDays, windowEnabled, windowStartMinute, windowEndMinute
        case minBatteryPercent, ignoreBatteryIfCharging, connectionPolicy, requireACPower
        case minFreeDiskGB, minIntervalHours, passcodeWaitSeconds, retryIntervalMinutes
        // Names used by the M1 stub; read for compatibility.
        case automaticBackupsEnabled
    }

    public init(from decoder: Decoder) throws {
        let defaults = DeviceSettings.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = defaults
            return
        }
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, value(.automaticBackupsEnabled, defaults.enabled))
        frequency = value(.frequency, defaults.frequency)
        everyHours = value(.everyHours, defaults.everyHours)
        weeklyDays = Set(value(.weeklyDays, Array(defaults.weeklyDays)))
        windowEnabled = value(.windowEnabled, defaults.windowEnabled)
        windowStartMinute = value(.windowStartMinute, defaults.windowStartMinute)
        windowEndMinute = value(.windowEndMinute, defaults.windowEndMinute)
        minBatteryPercent = value(.minBatteryPercent, defaults.minBatteryPercent)
        ignoreBatteryIfCharging = value(.ignoreBatteryIfCharging, defaults.ignoreBatteryIfCharging)
        connectionPolicy = value(.connectionPolicy, defaults.connectionPolicy)
        requireACPower = value(.requireACPower, defaults.requireACPower)
        minFreeDiskGB = value(.minFreeDiskGB, defaults.minFreeDiskGB)
        minIntervalHours = value(.minIntervalHours, defaults.minIntervalHours)
        passcodeWaitSeconds = value(.passcodeWaitSeconds, defaults.passcodeWaitSeconds)
        retryIntervalMinutes = value(.retryIntervalMinutes, defaults.retryIntervalMinutes)
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(everyHours, forKey: .everyHours)
        try c.encode(weeklyDays.sorted(), forKey: .weeklyDays)
        try c.encode(windowEnabled, forKey: .windowEnabled)
        try c.encode(windowStartMinute, forKey: .windowStartMinute)
        try c.encode(windowEndMinute, forKey: .windowEndMinute)
        try c.encode(minBatteryPercent, forKey: .minBatteryPercent)
        try c.encode(ignoreBatteryIfCharging, forKey: .ignoreBatteryIfCharging)
        try c.encode(connectionPolicy, forKey: .connectionPolicy)
        try c.encode(requireACPower, forKey: .requireACPower)
        try c.encode(minFreeDiskGB, forKey: .minFreeDiskGB)
        try c.encode(minIntervalHours, forKey: .minIntervalHours)
        try c.encode(passcodeWaitSeconds, forKey: .passcodeWaitSeconds)
        try c.encode(retryIntervalMinutes, forKey: .retryIntervalMinutes)
    }
}

/// App-wide settings (General tab). Launch at login is not stored here: SMAppService owns that state.
public struct GeneralSettings: Codable, Equatable, Sendable {
    public var notifyStarted: Bool
    public var notifyNeedsPasscode: Bool
    public var notifyFinished: Bool
    public var notifyFailed: Bool

    public init(
        notifyStarted: Bool = false, notifyNeedsPasscode: Bool = true,
        notifyFinished: Bool = true, notifyFailed: Bool = true
    ) {
        self.notifyStarted = notifyStarted
        self.notifyNeedsPasscode = notifyNeedsPasscode
        self.notifyFinished = notifyFinished
        self.notifyFailed = notifyFailed
    }

    private enum CodingKeys: String, CodingKey {
        case notifyStarted, notifyNeedsPasscode, notifyFinished, notifyFailed
    }

    public init(from decoder: Decoder) throws {
        let d = GeneralSettings()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        notifyStarted = (try? c.decodeIfPresent(Bool.self, forKey: .notifyStarted)) ?? d.notifyStarted
        notifyNeedsPasscode = (try? c.decodeIfPresent(Bool.self, forKey: .notifyNeedsPasscode)) ?? d.notifyNeedsPasscode
        notifyFinished = (try? c.decodeIfPresent(Bool.self, forKey: .notifyFinished)) ?? d.notifyFinished
        notifyFailed = (try? c.decodeIfPresent(Bool.self, forKey: .notifyFailed)) ?? d.notifyFailed
    }
}
