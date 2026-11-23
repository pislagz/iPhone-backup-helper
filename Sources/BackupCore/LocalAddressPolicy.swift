import Foundation

/// The only addresses this app may ever connect to directly (Wi-Fi backups: libimobiledevice opens a
/// TCP connection to the address usbmuxd reports for the phone): loopback, link-local, RFC 1918 private
/// IPv4 and IPv6 unique-local. Everything else is refused in code. Pure, no I/O.
public enum LocalAddressPolicy {
    /// `bytes` is the 4-byte address in network order.
    public static func isAllowedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let a = bytes[0], b = bytes[1]
        switch a {
        case 127: return true                       // loopback 127.0.0.0/8
        case 10: return true                        // 10.0.0.0/8
        case 172: return (16...31).contains(b)      // 172.16.0.0/12
        case 192: return b == 168                   // 192.168.0.0/16
        case 169: return b == 254                   // link-local 169.254.0.0/16
        default: return false
        }
    }

    /// `bytes` is the 16-byte address in network order.
    public static func isAllowedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // ::1 loopback
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // fe80::/10 link-local
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        // fc00::/7 unique local
        if (bytes[0] & 0xfe) == 0xfc { return true }
        // ::ffff:a.b.c.d IPv4-mapped: judged by the IPv4 part
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isAllowedIPv4(Array(bytes[12..<16]))
        }
        return false
    }
}

/// Process-wide settings that keep the app offline.
public enum OfflineGuard {
    /// Environment variables that could redirect the device service to another host. libusbmuxd reads
    /// `USBMUXD_SOCKET_ADDRESS` (`host:port` or a socket path) on every connection. Call once at launch,
    /// before any library call.
    public static let redirectingVariables = ["USBMUXD_SOCKET_ADDRESS"]

    public static func sanitizeEnvironment() {
        for name in redirectingVariables { unsetenv(name) }
    }
}
