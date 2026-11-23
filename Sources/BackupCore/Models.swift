import Foundation

/// How a device is currently reachable through usbmuxd.
public enum ConnectionType: String, Codable, CaseIterable, Hashable, Sendable {
    case usb
    case wifi
}

public enum EncryptionStatus: String, Codable, Equatable, Sendable {
    case encrypted
    case unencrypted
    case unknown
}

public struct BatteryStatus: Codable, Equatable, Sendable {
    /// 0...100
    public var level: Int
    public var isCharging: Bool

    public init(level: Int, isCharging: Bool) {
        self.level = max(0, min(100, level))
        self.isCharging = isCharging
    }
}

/// Why we could not read details from a (present) device.
public enum DeviceIssue: Equatable, Sendable {
    /// Not paired / the user has not tapped "Trust" yet.
    case needsTrust
    /// Locked with a passcode and not yet trusted for this connection.
    case locked
    /// Present in usbmuxd but lockdownd did not answer (typical for a sleeping Wi-Fi device).
    case unreachable(String)
}

/// Everything we read from the device via lockdownd in one go.
public struct DeviceDetails: Equatable, Sendable {
    public var name: String
    public var productType: String?
    public var productVersion: String?
    public var battery: BatteryStatus?
    public var encryption: EncryptionStatus
    /// "Show this iPhone when on Wi-Fi" (EnableWifiConnections); nil when unknown.
    public var wifiSyncEnabled: Bool?

    public init(
        name: String,
        productType: String? = nil,
        productVersion: String? = nil,
        battery: BatteryStatus? = nil,
        encryption: EncryptionStatus = .unknown,
        wifiSyncEnabled: Bool? = nil
    ) {
        self.name = name
        self.productType = productType
        self.productVersion = productVersion
        self.battery = battery
        self.encryption = encryption
        self.wifiSyncEnabled = wifiSyncEnabled
    }
}

public enum DeviceReadResult: Equatable, Sendable {
    case success(DeviceDetails)
    case failure(DeviceIssue)
}

/// One usbmuxd entry (a device reachable over USB and Wi-Fi shows up twice).
public struct ConnectedDevice: Hashable, Sendable {
    public var udid: String
    public var connection: ConnectionType

    public init(udid: String, connection: ConnectionType) {
        self.udid = udid
        self.connection = connection
    }
}

/// A device we have seen before; persisted so it can be shown as "not reachable".
public struct KnownDevice: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    public var productType: String?
    public var productVersion: String?
    public var encryption: EncryptionStatus
    public var lastSeen: Date

    public init(
        udid: String, name: String, productType: String? = nil, productVersion: String? = nil,
        encryption: EncryptionStatus = .unknown, lastSeen: Date
    ) {
        self.udid = udid
        self.name = name
        self.productType = productType
        self.productVersion = productVersion
        self.encryption = encryption
        self.lastSeen = lastSeen
    }
}

/// What the UI shows for one device.
public struct DeviceState: Identifiable, Equatable, Sendable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var productType: String?
    public var productVersion: String?
    public var connections: Set<ConnectionType>
    public var battery: BatteryStatus?
    public var encryption: EncryptionStatus
    public var wifiSyncEnabled: Bool?
    public var lastBackup: Date?
    public var issue: DeviceIssue?
    public var lastSeen: Date?

    public var isReachable: Bool { !connections.isEmpty }

    /// USB wins when both are available (it is also what libimobiledevice prefers).
    public var preferredConnection: ConnectionType? {
        if connections.contains(.usb) { return .usb }
        if connections.contains(.wifi) { return .wifi }
        return nil
    }

    public var modelName: String? {
        productType.map(ProductCatalog.marketingName(for:))
    }

    public var isTablet: Bool { productType?.hasPrefix("iPad") ?? false }
}
