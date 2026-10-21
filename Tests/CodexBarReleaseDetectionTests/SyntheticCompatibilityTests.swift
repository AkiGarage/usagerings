import XCTest
@testable import CodexBarReleaseDetection

final class SyntheticCompatibilityTests: XCTestCase {
    func testCompleteSyntheticMatrixHasExpectedOutcomes() throws {
        let validator = CodexBarSyntheticContractValidator()

        for fixture in CodexBarSyntheticFixtures.all {
            switch fixture.expectation {
            case .success:
                let result = try validator.validate(fixture.payload, exitCode: fixture.exitCode)
                XCTAssertEqual(result.outcome, .success, fixture.name)
            case .structuredFailure:
                let result = try validator.validate(fixture.payload, exitCode: fixture.exitCode)
                XCTAssertEqual(result.outcome, .structuredFailure, fixture.name)
                XCTAssertNotNil(result.errorCode, fixture.name)
            case .rejected:
                XCTAssertThrowsError(
                    try validator.validate(fixture.payload, exitCode: fixture.exitCode),
                    fixture.name
                )
            }
        }
    }

    func testFixturesAndResultsRemainPrivacySafe() throws {
        let forbidden = [
            "account", "email", "organization", "dashboard", "cookie", "token",
            "localPath", "resetAt", "synthetic-sensitive-message"
        ]
        let validator = CodexBarSyntheticContractValidator()

        for fixture in CodexBarSyntheticFixtures.all {
            let payloadText = String(decoding: fixture.payload, as: UTF8.self)
            for marker in forbidden.dropLast() {
                XCTAssertFalse(payloadText.localizedCaseInsensitiveContains(marker), "\(fixture.name): \(marker)")
            }
            if fixture.expectation != .rejected,
               let result = try? validator.validate(fixture.payload, exitCode: fixture.exitCode),
               let encoded = try? JSONEncoder().encode(result)
            {
                let resultText = String(decoding: encoded, as: UTF8.self)
                for marker in forbidden {
                    XCTAssertFalse(resultText.localizedCaseInsensitiveContains(marker), "\(fixture.name): \(marker)")
                }
            }
        }
    }

    func testMatrixDefinitionCoversRequiredBoundaryCases() {
        XCTAssertEqual(
            Set(CodexBarSyntheticFixtures.all.map(\.name)),
            [
                "both-lanes", "primary-only", "secondary-only", "additive-fields",
                "structured-error", "missing-used-percent", "no-usable-lane",
                "missing-codex-entry", "wrong-envelope", "renamed-required-field",
                "wrong-required-type"
            ]
        )
    }
}
