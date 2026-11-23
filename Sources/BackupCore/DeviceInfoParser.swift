import Foundation

/// Turns the plist dictionaries returned by lockdownd into `DeviceDetails`.
/// Pure, so it is unit-tested without a device.
public enum DeviceInfoParser {
    /// - Parameters:
    ///   - global: lockdownd global domain (DeviceName, ProductType, ProductVersion, ...)
    ///   - battery: domain `com.apple.mobile.battery`
    ///   - backup: domain `com.apple.mobile.backup`
    ///   - wireless: domain `com.apple.mobile.wireless_lockdown`
    public static func details(
        global: [String: Any],
        battery: [String: Any]?,
        backup: [String: Any]?,
        wireless: [String: Any]?
    ) -> DeviceDetails {
        let productType = global["ProductType"] as? String
        let name = (global["DeviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? productType.map(ProductCatalog.marketingName(for:))
            ?? "Unknown device"
        return DeviceDetails(
            name: name,
            productType: productType,
            productVersion: global["ProductVersion"] as? String,
            battery: batteryStatus(battery),
            encryption: encryption(backup),
            wifiSyncEnabled: wireless?["EnableWifiConnections"] as? Bool
        )
    }

    public static func batteryStatus(_ domain: [String: Any]?) -> BatteryStatus? {
        guard let domain, let level = domain["BatteryCurrentCapacity"] as? Int else { return nil }
        return BatteryStatus(level: level, isCharging: domain["BatteryIsCharging"] as? Bool ?? false)
    }

    public static func encryption(_ domain: [String: Any]?) -> EncryptionStatus {
        guard let value = domain?["WillEncrypt"] as? Bool else { return .unknown }
        return value ? .encrypted : .unencrypted
    }
}
