import XCTest
@testable import CodexUsageWidget

final class LegacySettingsMigrationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "usagerings.migration.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let legacy: [String: Any] = [
        "tabOriginX": 120.0, "tabOriginY": 40.0, "panelZoom": 1.25,
        "NSWindow Frame x": "junk", "SUEnableAutomaticChecks": true
    ]

    func testCopiesLegacyKeysOnceWithoutOverwriting() {
        defaults.set(2.0, forKey: "panelZoom")
        let copied = LegacySettingsMigration.runIfNeeded(
            bundleIdentifier: "com.akigarage.usagerings", defaults: defaults, legacyDomain: { _ in self.legacy })
        XCTAssertEqual(copied, ["tabOriginX", "tabOriginY"])
        XCTAssertEqual(defaults.double(forKey: "panelZoom"), 2.0)
        XCTAssertEqual(defaults.double(forKey: "tabOriginX"), 120.0)
        XCTAssertNil(defaults.object(forKey: "SUEnableAutomaticChecks"))
        XCTAssertTrue(defaults.bool(forKey: LegacySettingsMigration.doneKey))

        defaults.removeObject(forKey: "tabOriginX")
        let second = LegacySettingsMigration.runIfNeeded(
            bundleIdentifier: "com.akigarage.usagerings", defaults: defaults, legacyDomain: { _ in self.legacy })
        XCTAssertEqual(second, [])
        XCTAssertNil(defaults.object(forKey: "tabOriginX"))
    }

    func testSkipsForOtherBundleIds() {
        let copied = LegacySettingsMigration.runIfNeeded(
            bundleIdentifier: "local.codex.CodexUsageWidgetMulti", defaults: defaults, legacyDomain: { _ in self.legacy })
        XCTAssertEqual(copied, [])
        XCTAssertFalse(defaults.bool(forKey: LegacySettingsMigration.doneKey))
    }

    func testNoLegacyDomainStillMarksDone() {
        let copied = LegacySettingsMigration.runIfNeeded(
            bundleIdentifier: "com.akigarage.usagerings", defaults: defaults, legacyDomain: { _ in nil })
        XCTAssertEqual(copied, [])
        XCTAssertTrue(defaults.bool(forKey: LegacySettingsMigration.doneKey))
    }
}
