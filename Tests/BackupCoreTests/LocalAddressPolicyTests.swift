import XCTest
@testable import BackupCore

final class LocalAddressPolicyTests: XCTestCase {
    private func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
        LocalAddressPolicy.isAllowedIPv4([a, b, c, d])
    }

    func testAllowedIPv4Ranges() {
        XCTAssertTrue(v4(127, 0, 0, 1))
        XCTAssertTrue(v4(10, 1, 2, 3))
        XCTAssertTrue(v4(172, 16, 0, 1))
        XCTAssertTrue(v4(172, 31, 255, 254))
        XCTAssertTrue(v4(192, 168, 178, 20))
        XCTAssertTrue(v4(169, 254, 10, 10))
    }

    func testPublicAndNearMissIPv4AreRefused() {
        XCTAssertFalse(v4(8, 8, 8, 8))
        XCTAssertFalse(v4(172, 15, 0, 1))
        XCTAssertFalse(v4(172, 32, 0, 1))
        XCTAssertFalse(v4(192, 169, 0, 1))
        XCTAssertFalse(v4(169, 253, 0, 1))
        XCTAssertFalse(v4(100, 64, 0, 1)) // carrier-grade NAT is not "local"
        XCTAssertFalse(v4(0, 0, 0, 0))
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv4([10, 0, 0]))
    }

    private func v6(_ prefix: [UInt8], tail: [UInt8] = []) -> [UInt8] {
        var bytes = prefix
        bytes += [UInt8](repeating: 0, count: 16 - prefix.count - tail.count)
        return bytes + tail
    }

    func testAllowedIPv6() {
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(v6([], tail: [1])))          // ::1
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(v6([0xfe, 0x80], tail: [1, 2]))) // fe80::
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(v6([0xfe, 0xbf], tail: [1])))    // fe80::/10 upper edge
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(v6([0xfd, 0x12, 0x34], tail: [5]))) // fd00::/8 (ULA)
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(v6([0xfc, 0x00], tail: [5])))
    }

    func testPublicIPv6IsRefused() {
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv6(v6([0x20, 0x01, 0x0d, 0xb8], tail: [1]))) // 2001:db8::
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv6(v6([0xfe, 0xc0], tail: [1])))              // fec0:: (site-local, deprecated)
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv6(v6([])))                                  // ::
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv6([1, 2, 3]))
    }

    func testIPv4MappedIsJudgedByItsIPv4Part() {
        let local = [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 1, 5]
        let publicAddress = [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 8, 8, 8, 8]
        XCTAssertTrue(LocalAddressPolicy.isAllowedIPv6(local))
        XCTAssertFalse(LocalAddressPolicy.isAllowedIPv6(publicAddress))
    }

    func testSanitizeRemovesTheUsbmuxdRedirect() {
        setenv("USBMUXD_SOCKET_ADDRESS", "203.0.113.5:27015", 1)
        OfflineGuard.sanitizeEnvironment()
        XCTAssertNil(getenv("USBMUXD_SOCKET_ADDRESS"))
    }
}
