import CLibimobiledevice
import Foundation
import os

/// `DeviceBackend` on top of libimobiledevice. All C calls live in this file.
/// Calls block (up to ~10 s for a sleeping Wi-Fi device), so they run on a global queue.
public final class NativeDeviceBackend: DeviceBackend {
    private static let log = Logger(subsystem: "io.github.pislagz.iphonebackuphelper", category: "native")
    private static let clientLabel = "iPhoneBackupHelper"

    // lockdownd_error_t values we map (see lockdown.h).
    private enum Lockdown {
        static let passwordProtected: Int32 = -17
        static let userDeniedPairing: Int32 = -18
        static let pairingDialogPending: Int32 = -19
        static let missingHostID: Int32 = -20
        static let invalidHostID: Int32 = -21
        static let missingPairRecord: Int32 = -29
        static let invalidPairRecord: Int32 = -31
        static let pairingProhibitedOverThisConnection: Int32 = -36
    }

    public init() {}

    public func listDevices() async throws -> [ConnectedDevice] {
        try await Self.blocking { try Self.listDevicesBlocking() }
    }

    public func readDetails(udid: String) async -> DeviceReadResult {
        await Self.blockingValue { Self.readDetailsBlocking(udid: udid) }
    }

    // MARK: - Threading

    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func blockingValue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Device list

    private static func listDevicesBlocking() throws -> [ConnectedDevice] {
        var list: UnsafeMutablePointer<idevice_info_t?>? = nil
        var count: Int32 = 0
        let err = idevice_get_device_list_extended(&list, &count)
        guard err.rawValue == 0 else { throw DeviceBackendError.usbmuxUnavailable(Int(err.rawValue)) }
        guard let list else { return [] }
        defer { idevice_device_list_extended_free(list) }

        var result: [ConnectedDevice] = []
        for index in 0..<Int(count) {
            guard let info = list[index], let cUDID = info.pointee.udid else { continue }
            let isNetwork = info.pointee.conn_type.rawValue == CONNECTION_NETWORK.rawValue
            if isNetwork, !networkAddressIsLocal(info) {
                log.error("ignoring a Wi-Fi device with a non-local address")
                continue
            }
            result.append(ConnectedDevice(udid: String(cString: cUDID), connection: isNetwork ? .wifi : .usb))
        }
        return result
    }

    // MARK: - Local-network guard

    /// Whether the address libimobiledevice would open a TCP connection to is loopback, link-local,
    /// RFC 1918 or IPv6 unique-local (`LocalAddressPolicy`). Unknown address family or no address: no.
    private static func networkAddressIsLocal(_ info: idevice_info_t) -> Bool {
        guard let data = info.pointee.conn_data else { return false }
        let family = Int32(data.assumingMemoryBound(to: sockaddr.self).pointee.sa_family)
        switch family {
        case AF_INET:
            var address = data.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            return LocalAddressPolicy.isAllowedIPv4(withUnsafeBytes(of: &address) { Array($0) })
        case AF_INET6:
            var address = data.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            return LocalAddressPolicy.isAllowedIPv6(withUnsafeBytes(of: &address) { Array($0) })
        default:
            return false
        }
    }

    /// Call right before opening a device with `idevice_new_with_options`: true when the connection
    /// would go over USB (via usbmuxd) or to a local address only. `connection == nil` means "whatever
    /// libimobiledevice picks" (USB wins when present). Refuses when the device is not listed.
    static func connectionIsLocal(udid: String, connection: ConnectionType?) -> Bool {
        var list: UnsafeMutablePointer<idevice_info_t?>? = nil
        var count: Int32 = 0
        guard idevice_get_device_list_extended(&list, &count).rawValue == 0, let list else { return false }
        defer { idevice_device_list_extended_free(list) }

        var hasUSB = false
        var hasNetwork = false
        var allNetworkLocal = true
        for index in 0..<Int(count) {
            guard let info = list[index], let cUDID = info.pointee.udid, String(cString: cUDID) == udid else { continue }
            if info.pointee.conn_type.rawValue == CONNECTION_NETWORK.rawValue {
                hasNetwork = true
                if !networkAddressIsLocal(info) { allNetworkLocal = false }
            } else {
                hasUSB = true
            }
        }
        let networkOK = hasNetwork && allNetworkLocal
        switch connection {
        case .usb?: return hasUSB
        case .wifi?: return networkOK
        case nil: return hasUSB || networkOK
        }
    }

    // MARK: - Lockdown

    private static func readDetailsBlocking(udid: String) -> DeviceReadResult {
        guard connectionIsLocal(udid: udid, connection: nil) else {
            return .failure(.unreachable("device not found"))
        }
        var device: idevice_t? = nil
        // USB and network; libimobiledevice prefers USB when both exist.
        let options = idevice_options(rawValue: IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue)
        let deviceError = idevice_new_with_options(&device, udid, options)
        guard deviceError.rawValue == 0, let device else {
            return .failure(.unreachable("device not found (\(deviceError.rawValue))"))
        }
        defer { idevice_free(device) }

        var client: lockdownd_client_t? = nil
        let handshake = lockdownd_client_new_with_handshake(device, &client, clientLabel)
        guard handshake.rawValue == 0, let client else {
            let code = handshake.rawValue
            log.info("lockdown handshake failed for \(udid, privacy: .private): \(code)")
            return .failure(issue(forLockdownError: code))
        }
        defer { lockdownd_client_free(client) }

        guard let global = dictionary(client: client, domain: nil) else {
            return .failure(.unreachable("could not read device info"))
        }
        let details = DeviceInfoParser.details(
            global: global,
            battery: dictionary(client: client, domain: "com.apple.mobile.battery"),
            backup: dictionary(client: client, domain: "com.apple.mobile.backup"),
            wireless: dictionary(client: client, domain: "com.apple.mobile.wireless_lockdown"))
        return .success(details)
    }

    static func issue(forLockdownError code: Int32) -> DeviceIssue {
        switch code {
        case Lockdown.passwordProtected:
            return .locked
        case Lockdown.userDeniedPairing, Lockdown.pairingDialogPending, Lockdown.missingHostID,
             Lockdown.invalidHostID, Lockdown.missingPairRecord, Lockdown.invalidPairRecord:
            return .needsTrust
        case Lockdown.pairingProhibitedOverThisConnection:
            return .unreachable("pair over USB first")
        default:
            return .unreachable("lockdown error \(code)")
        }
    }

    /// Reads a lockdown domain (nil = global) as a Foundation dictionary, via the XML plist form.
    static func dictionary(client: lockdownd_client_t, domain: String?) -> [String: Any]? {
        var node: plist_t? = nil
        guard lockdownd_get_value(client, domain, nil, &node).rawValue == 0, let node else { return nil }
        defer { plist_free(node) }

        var xml: UnsafeMutablePointer<CChar>? = nil
        var length: UInt32 = 0
        guard plist_to_xml(node, &xml, &length).rawValue == 0, let xml else { return nil }
        defer { plist_mem_free(xml) }

        let data = Data(bytes: xml, count: Int(length))
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
