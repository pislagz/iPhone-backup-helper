import Foundation

/// Per-device backup settings. Stub for M1; M3 adds frequency, window, battery, disk rules.
public struct DeviceSettings: Codable, Equatable, Sendable {
    public enum ConnectionPolicy: String, Codable, Sendable {
        case usbOnly
        case usbOrWiFi
    }

    public var automaticBackupsEnabled: Bool
    public var connectionPolicy: ConnectionPolicy
    public var minimumBatteryPercent: Int
    /// How long to wait for the user to unlock the iPhone (passcode is needed on every backup).
    public var passcodeWaitSeconds: TimeInterval

    public init(
        automaticBackupsEnabled: Bool = false,
        connectionPolicy: ConnectionPolicy = .usbOrWiFi,
        minimumBatteryPercent: Int = 20,
        passcodeWaitSeconds: TimeInterval = 300
    ) {
        self.automaticBackupsEnabled = automaticBackupsEnabled
        self.connectionPolicy = connectionPolicy
        self.minimumBatteryPercent = minimumBatteryPercent
        self.passcodeWaitSeconds = passcodeWaitSeconds
    }
}
