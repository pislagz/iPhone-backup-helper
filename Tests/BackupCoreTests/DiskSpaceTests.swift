import XCTest
@testable import BackupCore

final class DiskSpaceTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp")

    func testPrefersCapacityForImportantUsage() {
        let value = DiskSpace.availableBytes(at: url, importantUsage: { _ in 9_000 }, systemFree: { _ in 1_000 })
        XCTAssertEqual(value, 9_000)
    }

    func testFallsBackToSystemFreeSize() {
        XCTAssertEqual(DiskSpace.availableBytes(at: url, importantUsage: { _ in nil }, systemFree: { _ in 1_000 }), 1_000)
        XCTAssertEqual(DiskSpace.availableBytes(at: url, importantUsage: { _ in 0 }, systemFree: { _ in 1_000 }), 1_000)
        XCTAssertNil(DiskSpace.availableBytes(at: url, importantUsage: { _ in nil }, systemFree: { _ in nil }))
    }

    func testMissingFolderUsesNearestExistingParent() {
        var probed: URL?
        _ = DiskSpace.availableBytes(
            at: url.appendingPathComponent("does-not-exist-\(UUID().uuidString)/nested"),
            importantUsage: { probed = $0; return 1 }, systemFree: { _ in nil })
        XCTAssertEqual(probed?.path, "/tmp")
    }

    func testLiveValueIsPositive() {
        XCTAssertGreaterThan(DiskSpace.availableBytes(at: FileManager.default.temporaryDirectory) ?? 0, 0)
    }
}
