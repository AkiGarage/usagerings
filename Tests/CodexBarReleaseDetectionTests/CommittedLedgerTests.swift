import Foundation
import XCTest
@testable import CodexBarReleaseDetection

final class CommittedLedgerTests: XCTestCase {
    func testCommittedBaselineLedgerPinsTheVerifiedV0421Identity() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(
            contentsOf: packageRoot.appendingPathComponent("Tests/CodexBarReleaseDetectionTests/Fixtures/codexbar-verified-releases.json")
        )

        let ledger = try VerifiedReleaseLedger.decode(data)

        XCTAssertEqual(ledger.repository, "steipete/CodexBar")
        XCTAssertEqual(ledger.minimumTag, "v0.32.4")
        XCTAssertEqual(ledger.verifiedThroughTag, "v0.42.1")
        let entry = try XCTUnwrap(ledger.entries.first)
        XCTAssertEqual(entry.releaseID, 352_670_413)
        XCTAssertEqual(entry.tagObjectSHA, "71e9b33fe9d551e09fbd2b9ec610346d91b96649")
        XCTAssertEqual(entry.peeledCommitSHA, "3e05988f5c5fc1dff70c7a58bd659208cf34c840")
        XCTAssertEqual(entry.assets.count, 14)
        XCTAssertEqual(entry.contractBlobs.map(\.path), CodexBarContractPaths.all)
    }
}
