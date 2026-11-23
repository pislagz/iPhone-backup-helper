import XCTest
@testable import BackupCore

final class NativeMappingTests: XCTestCase {
    func testLockdownErrorMapping() {
        XCTAssertEqual(NativeDeviceBackend.issue(forLockdownError: -17), .locked)
        XCTAssertEqual(NativeDeviceBackend.issue(forLockdownError: -19), .needsTrust)
        XCTAssertEqual(NativeDeviceBackend.issue(forLockdownError: -21), .needsTrust)
        XCTAssertEqual(NativeDeviceBackend.issue(forLockdownError: -7), .unreachable("lockdown error -7"))
    }
}
