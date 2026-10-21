import XCTest
import CodexBarReleaseDetection
@testable import CodexUsageWidget

final class CodexBarSyntheticMatrixConsumerTests: XCTestCase {
    func testWidgetConsumerMatchesTheSharedSyntheticContract() throws {
        for fixture in CodexBarSyntheticFixtures.all {
            switch fixture.expectation {
            case .success:
                XCTAssertNoThrow(
                    try CodexUsageTextParser.parseJSON(fixture.payload),
                    fixture.name
                )
            case .structuredFailure:
                let error = CodexUsageError.commandFailure(
                    exitCode: fixture.exitCode,
                    stdout: fixture.payload,
                    stderr: Data("synthetic-sensitive-message".utf8)
                )
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-message"), fixture.name)
            case .rejected:
                XCTAssertThrowsError(
                    try CodexUsageTextParser.parseJSON(fixture.payload),
                    fixture.name
                )
            }
        }
    }
}
