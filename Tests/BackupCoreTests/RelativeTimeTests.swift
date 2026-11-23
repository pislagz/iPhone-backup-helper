import XCTest
@testable import BackupCore

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(_ secondsAgo: TimeInterval) -> String {
        RelativeTime.string(for: now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testNever() {
        XCTAssertEqual(RelativeTime.string(for: nil, now: now), "never")
    }

    func testBuckets() {
        XCTAssertEqual(text(5), "just now")
        XCTAssertEqual(text(59), "just now")
        XCTAssertEqual(text(60), "1 min ago")
        XCTAssertEqual(text(59 * 60), "59 min ago")
        XCTAssertEqual(text(3_600), "1 h ago")
        XCTAssertEqual(text(2 * 3_600 + 100), "2 h ago")
        XCTAssertEqual(text(86_400), "yesterday")
        XCTAssertEqual(text(2 * 86_400), "2 days ago")
        XCTAssertEqual(text(13 * 86_400), "13 days ago")
        XCTAssertEqual(text(14 * 86_400), "2 weeks ago")
        XCTAssertEqual(text(60 * 86_400), "2 months ago")
    }

    func testFutureDatesClampToJustNow() {
        XCTAssertEqual(text(-500), "just now")
    }
}
