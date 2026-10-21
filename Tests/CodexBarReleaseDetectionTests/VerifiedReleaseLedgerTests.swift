import XCTest
@testable import CodexBarReleaseDetection

final class VerifiedReleaseLedgerTests: XCTestCase {
    func testExactRecordedIdentityIsANoOpAndNewVersionsAreAscending() throws {
        let baseline = makeEntry(tag: "v0.42.1", releaseID: 42)
        let ledger = try makeLedger(entry: baseline)
        let later = makeEntry(tag: "v0.44.0", releaseID: 44)
        let earlier = makeEntry(tag: "v0.43.0", releaseID: 43)

        let unseen = try ReleaseLedgerReconciler().unseenVerifiedReleases(
            ledger: ledger,
            discovered: [later, baseline, earlier, earlier]
        )

        XCTAssertEqual(unseen.map(\.tag), ["v0.43.0", "v0.44.0"])
        XCTAssertEqual(
            try ReleaseLedgerReconciler().unseenVerifiedReleases(
                ledger: ledger,
                discovered: [baseline]
            ),
            []
        )
    }

    func testRecordedAssetOrContractMutationFailsClosed() throws {
        let baseline = makeEntry(tag: "v0.42.1", releaseID: 42)
        let ledger = try makeLedger(entry: baseline)
        let changedAsset = makeEntry(
            tag: "v0.42.1",
            releaseID: 42,
            assetDigest: "sha256:" + String(repeating: "b", count: 64)
        )
        let changedContract = makeEntry(
            tag: "v0.42.1",
            releaseID: 42,
            contractHash: String(repeating: "c", count: 64)
        )

        for changed in [changedAsset, changedContract] {
            XCTAssertThrowsError(
                try ReleaseLedgerReconciler().unseenVerifiedReleases(
                    ledger: ledger,
                    discovered: [changed]
                )
            ) { error in
                XCTAssertEqual(error as? ReleaseDetectionError, .identityMutation("v0.42.1"))
            }
        }
    }

    func testMissingVerifiedThroughIdentityFailsClosed() throws {
        let ledger = try makeLedger(entry: makeEntry(tag: "v0.42.1", releaseID: 42))

        XCTAssertThrowsError(
            try ReleaseLedgerReconciler().unseenVerifiedReleases(
                ledger: ledger,
                discovered: [makeEntry(tag: "v0.43.0", releaseID: 43)]
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseDetectionError, .identityMutation("v0.42.1"))
        }
    }

    func testLedgerRejectsWrongRepositoryAndNonCanonicalEntries() throws {
        let entry = makeEntry(tag: "v0.42.1", releaseID: 42)
        let valid = try JSONEncoder.sorted.encode(
            VerifiedReleaseLedger(
                schemaVersion: 1,
                repository: "steipete/CodexBar",
                minimumTag: "v0.32.4",
                verifiedThroughTag: "v0.42.1",
                entries: [entry]
            )
        )
        XCTAssertNoThrow(try VerifiedReleaseLedger.decode(valid))

        for repository in ["other/CodexBar", "steipete/codexbar"] {
            let data = try JSONEncoder.sorted.encode(
                VerifiedReleaseLedger(
                    schemaVersion: 1,
                    repository: repository,
                    minimumTag: "v0.32.4",
                    verifiedThroughTag: "v0.42.1",
                    entries: [entry]
                )
            )
            XCTAssertThrowsError(try VerifiedReleaseLedger.decode(data))
        }
    }

    func testLedgerRejectsAnIncompleteContractIdentitySet() throws {
        let entry = makeEntry(tag: "v0.42.1", releaseID: 42)
        let incomplete = VerifiedReleaseEntry(
            releaseID: entry.releaseID,
            tag: entry.tag,
            publishedAt: entry.publishedAt,
            tagObjectSHA: entry.tagObjectSHA,
            peeledCommitSHA: entry.peeledCommitSHA,
            signature: entry.signature,
            assets: entry.assets,
            contractBlobs: Array(entry.contractBlobs.dropLast())
        )
        let data = try JSONEncoder.sorted.encode(
            VerifiedReleaseLedger(
                schemaVersion: 1,
                repository: "steipete/CodexBar",
                minimumTag: "v0.32.4",
                verifiedThroughTag: incomplete.tag,
                entries: [incomplete]
            )
        )

        XCTAssertThrowsError(try VerifiedReleaseLedger.decode(data))
    }

    private func makeLedger(entry: VerifiedReleaseEntry) throws -> VerifiedReleaseLedger {
        let data = try JSONEncoder.sorted.encode(
            VerifiedReleaseLedger(
                schemaVersion: 1,
                repository: "steipete/CodexBar",
                minimumTag: "v0.32.4",
                verifiedThroughTag: entry.tag,
                entries: [entry]
            )
        )
        return try VerifiedReleaseLedger.decode(data)
    }

    private func makeEntry(
        tag: String,
        releaseID: Int64,
        assetDigest: String = "sha256:" + String(repeating: "a", count: 64),
        contractHash: String = String(repeating: "b", count: 64)
    ) -> VerifiedReleaseEntry {
        VerifiedReleaseEntry(
            releaseID: releaseID,
            tag: tag,
            publishedAt: "2026-07-17T00:00:00Z",
            tagObjectSHA: String(repeating: "1", count: 40),
            peeledCommitSHA: String(repeating: "2", count: 40),
            signature: .init(verified: true, reason: "valid"),
            assets: [
                .init(id: releaseID * 10, name: "CodexBarCLI-\(tag)-macos-arm64.tar.gz", size: 100, digest: assetDigest)
            ],
            contractBlobs: CodexBarContractPaths.all.map {
                .init(
                    path: $0,
                    blobSHA: String(repeating: "3", count: 40),
                    sha256: contractHash
                )
            }
        )
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
