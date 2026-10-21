import XCTest
@testable import CodexBarReleaseDetection

final class ReleaseDetectorTests: XCTestCase {
    func testProcessesRelevantVersionsAscendingAndReturnsPinnedCandidates() async throws {
        let baseline = Self.entry("v0.42.1", id: 42)
        let ledger = try Self.ledger(baseline)
        let order = ResolutionOrder()
        let detector = CodexBarReleaseDetector(
            fetchCatalog: { _ in [
                Self.summary("v0.44.0", id: 44),
                Self.summary("v0.41.0", id: 41),
                Self.summary("v0.43.0", id: 43),
                Self.summary("v0.42.1", id: 42)
            ] },
            resolveProvenance: { release in
                await order.append(release.tag)
                return .verified(Self.entry(release.tag, id: release.releaseID))
            }
        )

        let report = try await detector.detect(ledger: ledger)

        let resolvedOrder = await order.values()
        XCTAssertEqual(resolvedOrder, ["v0.42.1", "v0.43.0", "v0.44.0"])
        XCTAssertEqual(report.compatibleReleases.map(\.tag), ["v0.43.0", "v0.44.0"])
        XCTAssertEqual(report.scannedStableTags, ["v0.41.0", "v0.42.1", "v0.43.0", "v0.44.0"])
        XCTAssertTrue(report.pendingReleases.isEmpty)
        XCTAssertTrue(report.syntheticFixtureMatrixPassed)
    }

    func testExactRepeatIsNoOpAndNewUnverifiedTagRemainsPending() async throws {
        let baseline = Self.entry("v0.42.1", id: 42)
        let ledger = try Self.ledger(baseline)
        let detector = CodexBarReleaseDetector(
            fetchCatalog: { _ in [Self.summary("v0.42.1", id: 42), Self.summary("v0.43.0", id: 43)] },
            resolveProvenance: { release in
                if release.tag == "v0.43.0" {
                    return .pending(.init(releaseID: 43, tag: "v0.43.0", reason: .unverifiedTag))
                }
                return .verified(baseline)
            }
        )

        let report = try await detector.detect(ledger: ledger)
        XCTAssertTrue(report.compatibleReleases.isEmpty)
        XCTAssertEqual(
            report.pendingReleases,
            [.init(releaseID: 43, tag: "v0.43.0", reason: .unverifiedTag)]
        )
        XCTAssertFalse(report.isNoOp)

        let noOp = CodexBarReleaseDetector(
            fetchCatalog: { _ in [Self.summary("v0.42.1", id: 42)] },
            resolveProvenance: { _ in .verified(baseline) }
        )
        let noOpReport = try await noOp.detect(ledger: ledger)
        XCTAssertTrue(noOpReport.isNoOp)
    }

    func testRecordedReleaseCanNeverFallBackToPending() async throws {
        let baseline = Self.entry("v0.42.1", id: 42)
        let ledger = try Self.ledger(baseline)
        let detector = CodexBarReleaseDetector(
            fetchCatalog: { _ in [Self.summary("v0.42.1", id: 42)] },
            resolveProvenance: { _ in
                .pending(.init(releaseID: 42, tag: "v0.42.1", reason: .unverifiedTag))
            }
        )

        do {
            _ = try await detector.detect(ledger: ledger)
            XCTFail("Expected recorded identity to fail closed")
        } catch {
            XCTAssertEqual(error as? ReleaseDetectionError, .identityMutation("v0.42.1"))
        }
    }

    func testReportContainsNoUntrustedTextFields() async throws {
        let baseline = Self.entry("v0.42.1", id: 42)
        let report = try await CodexBarReleaseDetector(
            fetchCatalog: { _ in [Self.summary("v0.42.1", id: 42)] },
            resolveProvenance: { _ in .verified(baseline) }
        ).detect(ledger: Self.ledger(baseline))
        let encoded = try JSONEncoder().encode(report)
        let text = String(decoding: encoded, as: UTF8.self)
        for marker in ["author", "body", "message", "account", "email", "token"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(marker), marker)
        }
    }

    fileprivate static func summary(_ tag: String, id: Int64) -> CodexBarReleaseSummary {
        CodexBarReleaseSummary(
            releaseID: id,
            version: StableSemanticVersion(tag: tag)!,
            publishedAt: "2026-07-17T00:00:00Z",
            assets: [asset(tag, id: id)]
        )
    }

    fileprivate static func entry(_ tag: String, id: Int64) -> VerifiedReleaseEntry {
        VerifiedReleaseEntry(
            releaseID: id,
            tag: tag,
            publishedAt: "2026-07-17T00:00:00Z",
            tagObjectSHA: String(repeating: "1", count: 40),
            peeledCommitSHA: String(repeating: "2", count: 40),
            signature: .init(verified: true, reason: "valid"),
            assets: [asset(tag, id: id)],
            contractBlobs: CodexBarContractPaths.all.map {
                .init(
                    path: $0,
                    blobSHA: String(repeating: "3", count: 40),
                    sha256: String(repeating: "a", count: 64)
                )
            }
        )
    }

    fileprivate static func asset(_ tag: String, id: Int64) -> ReleaseAssetSummary {
        .init(
            id: id * 10,
            name: "CodexBarCLI-\(tag)-macos-arm64.tar.gz",
            size: 100,
            digest: "sha256:" + String(repeating: "a", count: 64)
        )
    }

    fileprivate static func ledger(_ entry: VerifiedReleaseEntry) throws -> VerifiedReleaseLedger {
        let raw = VerifiedReleaseLedger(
            schemaVersion: 1,
            repository: "steipete/CodexBar",
            minimumTag: "v0.32.4",
            verifiedThroughTag: entry.tag,
            entries: [entry]
        )
        return try VerifiedReleaseLedger.decode(JSONEncoder().encode(raw))
    }
}

private actor ResolutionOrder {
    private var tags: [String] = []

    func append(_ tag: String) { tags.append(tag) }
    func values() -> [String] { tags }
}
