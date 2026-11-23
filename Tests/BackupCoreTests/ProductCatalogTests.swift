import XCTest
@testable import BackupCore

final class ProductCatalogTests: XCTestCase {
    func testKnownIPhones() {
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPhone15,2"), "iPhone 14 Pro")
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPhone14,6"), "iPhone SE (3rd generation)")
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPhone17,3"), "iPhone 16")
    }

    func testUnknownFallsBackToFamily() {
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPhone99,1"), "iPhone")
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPad13,4"), "iPad")
        XCTAssertEqual(ProductCatalog.marketingName(for: "iPod7,1"), "iPod touch")
        XCTAssertEqual(ProductCatalog.marketingName(for: "Watch1,1"), "Watch1,1")
    }
}
