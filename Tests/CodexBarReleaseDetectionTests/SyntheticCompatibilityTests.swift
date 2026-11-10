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

    func testRejectedFixtureFailsWhenTheValidatorAcceptsEverything() throws {
        let fixture = try XCTUnwrap(
            CodexBarSyntheticFixtures.all.first { $0.expectation == .rejected }
        )
        let acceptingEverything: (CodexBarSyntheticFixture) throws -> CompatibilityValidationResult = { candidate in
            CompatibilityValidationResult(
                outcome: .success,
                exitCode: candidate.exitCode,
                hasPrimary: true,
                hasSecondary: true,
                errorKind: nil,
                errorCode: nil
            )
        }

        XCTAssertThrowsError(try CodexBarSyntheticFixtures.check(fixture, with: acceptingEverything))
    }

    func testExpectationCheckRejectsAThrowingValidatorForNonRejectedFixtures() throws {
        let success = try XCTUnwrap(
            CodexBarSyntheticFixtures.all.first { $0.expectation == .success }
        )
        let structuredFailure = try XCTUnwrap(
            CodexBarSyntheticFixtures.all.first { $0.expectation == .structuredFailure }
        )
        let alwaysThrows: (CodexBarSyntheticFixture) throws -> CompatibilityValidationResult = { _ in
            throw ReleaseDetectionError.incompatibleContract
        }
        let alwaysSucceeds: (CodexBarSyntheticFixture) throws -> CompatibilityValidationResult = { candidate in
            CompatibilityValidationResult(
                outcome: .success,
                exitCode: candidate.exitCode,
                hasPrimary: true,
                hasSecondary: false,
                errorKind: nil,
                errorCode: nil
            )
        }

        XCTAssertThrowsError(try CodexBarSyntheticFixtures.check(success, with: alwaysThrows))
        XCTAssertThrowsError(try CodexBarSyntheticFixtures.check(structuredFailure, with: alwaysThrows))
        XCTAssertThrowsError(try CodexBarSyntheticFixtures.check(structuredFailure, with: alwaysSucceeds))
        XCTAssertNoThrow(try CodexBarSyntheticFixtures.check(success, with: alwaysSucceeds))
    }

    func testVerifyPassesTheCommittedFixtureMatrix() throws {
        XCTAssertNoThrow(try CodexBarSyntheticFixtures.verify())
    }

    func testOutOfRangeErrorCodeIsRejectedNotTrapped() {
        let validator = CodexBarSyntheticContractValidator()
        for code in ["9223372036854775808", "1e300", "1.5"] {
            let payload = Data(#"[{"provider":"codex","error":{"code":\#(code)}}]"#.utf8)
            XCTAssertThrowsError(try validator.validate(payload, exitCode: 1), code)
        }
        let maxSafe = Data(#"[{"provider":"codex","error":{"code":9007199254740992}}]"#.utf8)
        XCTAssertEqual(try? validator.validate(maxSafe, exitCode: 1).errorCode, 9_007_199_254_740_992)
    }
}
