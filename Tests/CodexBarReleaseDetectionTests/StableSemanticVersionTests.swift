import XCTest
@testable import CodexBarReleaseDetection

final class StableSemanticVersionTests: XCTestCase {
    func testAcceptsOnlyStrictStableVPrefixedSemanticVersions() {
        XCTAssertEqual(StableSemanticVersion(tag: "v0.32.4")?.tag, "v0.32.4")
        XCTAssertEqual(StableSemanticVersion(tag: "v12.3.456")?.tag, "v12.3.456")

        let rejected = [
            "0.32.4",
            "v0.32",
            "v0.32.4-rc.1",
            "v0.32.4+build",
            "v00.32.4",
            "v0.032.4",
            "v0.32.04",
            "v0.32.4\n"
        ]

        for tag in rejected {
            XCTAssertNil(StableSemanticVersion(tag: tag), tag)
        }
    }

    func testSortsNumericallyInsteadOfLexicographically() {
        let versions = ["v1.10.0", "v2.0.0", "v1.9.9"]
            .compactMap(StableSemanticVersion.init(tag:))
            .sorted()

        XCTAssertEqual(versions.map(\.tag), ["v1.9.9", "v1.10.0", "v2.0.0"])
    }
}
