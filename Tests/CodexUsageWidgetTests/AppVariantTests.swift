import XCTest
@testable import CodexUsageWidget

final class AppVariantTests: XCTestCase {
    func testMultiBundleIdentifierSelectsMultiVariant() {
        XCTAssertEqual(AppVariant.current(bundleIdentifier: "local.codex.CodexUsageWidgetMulti"), .multi)
    }

    func testClassicBundleIdentifierSelectsMultiVariant() {
        XCTAssertEqual(AppVariant.current(bundleIdentifier: "local.codex.CodexUsageWidget"), .multi)
    }

    func testUsageRingsBundleIdentifierSelectsMultiVariant() {
        XCTAssertEqual(AppVariant.current(bundleIdentifier: "com.akigarage.usagerings"), .multi)
    }

    func testUnknownBundlesStaySingleVariant() {
        XCTAssertEqual(AppVariant.current(bundleIdentifier: "local.codex.CodexUsageNano"), .single)
        XCTAssertEqual(AppVariant.current(bundleIdentifier: nil), .single)
    }
}
