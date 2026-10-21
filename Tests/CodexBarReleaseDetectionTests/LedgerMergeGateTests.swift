import CryptoKit
import Foundation
import XCTest
@testable import CodexBarReleaseDetection

final class LedgerMergeGateTests: XCTestCase {
    func testAuthorizesExactlyOneVerifiedEntryAtTheCurrentHead() throws {
        let fixture = try GateFixture()

        let decision = try LedgerMergeGate().evaluate(
            snapshot: fixture.validSnapshot,
            policy: fixture.enabledPolicy
        )

        XCTAssertEqual(
            decision,
            .authorized(
                .init(
                    pullRequestNumber: 55,
                    baseOID: fixture.baseOID,
                    headOID: fixture.headOID,
                    canonicalIdentity: fixture.newEntry.canonicalIdentity,
                    mutationAppID: fixture.mutationApp.appID,
                    gateAppID: fixture.gateApp.id
                )
            )
        )
    }

    func testExecuteReevaluatesFreshSuspensionBeforePerformingMerge() async throws {
        let fixture = try GateFixture()
        var performed = false
        var policyLoadCount = 0

        do {
            _ = try await LedgerMergeGate().execute(
                loadFreshPolicy: {
                    policyLoadCount += 1
                    return policyLoadCount == 1 ? fixture.enabledPolicy : fixture.policy(
                        suspended: true,
                        suspensionID: "late-suspension"
                    )
                },
                loadFreshSnapshot: { fixture.validSnapshot },
                performAtomicMergeIfCurrent: { _ in
                    performed = true
                    return true
                }
            )
            XCTFail("Expected the fresh suspension state to block merge")
        } catch {
            XCTAssertEqual(error as? LedgerMergeGateError, .laneSuspended)
        }
        XCTAssertFalse(performed)
    }

    func testExecutePerformsMergeOnlyInsideFreshlyValidatedCall() async throws {
        let fixture = try GateFixture()
        var performed = false
        var receivedAuthorization: LedgerMergeExecutionAuthorization?
        var policyLoadCount = 0
        var snapshotLoadCount = 0

        let result = try await LedgerMergeGate().execute(
            loadFreshPolicy: {
                policyLoadCount += 1
                return fixture.enabledPolicy
            },
            loadFreshSnapshot: {
                snapshotLoadCount += 1
                return fixture.validSnapshot
            },
            performAtomicMergeIfCurrent: {
                receivedAuthorization = $0
                performed = true
                return true
            }
        )

        XCTAssertEqual(result, .performed)
        XCTAssertTrue(performed)
        XCTAssertEqual(policyLoadCount, 2)
        XCTAssertEqual(snapshotLoadCount, 2)
        XCTAssertEqual(
            receivedAuthorization?.expectedRepository,
            "AkiGarage/codex-usage-widget"
        )
        XCTAssertEqual(receivedAuthorization?.expectedBaseBranch, "main")
        XCTAssertEqual(receivedAuthorization?.pullRequestNumber, 55)
        XCTAssertEqual(receivedAuthorization?.expectedBaseOID, fixture.baseOID)
        XCTAssertEqual(receivedAuthorization?.expectedHeadOID, fixture.headOID)
        XCTAssertEqual(receivedAuthorization?.expectedHeadParentOIDs, [fixture.baseOID])
        XCTAssertEqual(
            receivedAuthorization?.expectedPolicySHA256,
            fixture.enabledPolicy.authorizationSHA256
        )
        XCTAssertEqual(
            receivedAuthorization?.expectedSnapshotSHA256,
            try fixture.validSnapshot.authorizationSHA256()
        )
        XCTAssertEqual(receivedAuthorization?.canonicalIdentity, fixture.newEntry.canonicalIdentity)
    }

    func testSnapshotAuthorizationDigestBindsTargetAndLatestEvidence() throws {
        let fixture = try GateFixture()
        let baseline = try fixture.validSnapshot.authorizationSHA256()
        let retargeted = try fixture.snapshot(baseBranch: "release").authorizationSHA256()
        let reparented = try fixture.snapshot(
            headParentOIDs: [String(repeating: "d", count: 40)]
        ).authorizationSHA256()
        let supersededEvidence = try fixture.snapshot(checks: [
            fixture.check(
                name: "swiftpm",
                app: fixture.ciApp,
                runID: 10,
                conclusion: .success
            ),
            fixture.check(
                name: "codex-autoreview",
                app: fixture.gateApp,
                runID: 20,
                evidenceSHA256: String(repeating: "c", count: 64),
                conclusion: .success
            ),
            fixture.check(
                name: "swiftpm",
                app: fixture.ciApp,
                runID: 11,
                conclusion: .pending
            )
        ]).authorizationSHA256()

        XCTAssertNotEqual(baseline, retargeted)
        XCTAssertNotEqual(baseline, reparented)
        XCTAssertNotEqual(baseline, supersededEvidence)
    }

    func testExecuteFailsClosedWhenAtomicMutationSeesPolicyDrift() async throws {
        let fixture = try GateFixture()

        do {
            _ = try await LedgerMergeGate().execute(
                loadFreshPolicy: { fixture.enabledPolicy },
                loadFreshSnapshot: { fixture.validSnapshot },
                performAtomicMergeIfCurrent: { authorization in
                    XCTAssertEqual(
                        authorization.expectedPolicySHA256,
                        fixture.enabledPolicy.authorizationSHA256
                    )
                    return false
                }
            )
            XCTFail("Expected an atomic policy mismatch to block merge")
        } catch {
            XCTAssertEqual(error as? LedgerMergeGateError, .stalePolicy)
        }
    }

    func testExactLedgerRepeatIsANoOpAndCreatesNoAuthorization() throws {
        let fixture = try GateFixture()

        let decision = try LedgerMergeGate().evaluate(
            snapshot: fixture.snapshot(
                changedFiles: [],
                headLedger: fixture.baseLedger,
                includeProvenance: false
            ),
            policy: fixture.enabledPolicy
        )

        XCTAssertEqual(decision, .noOp)
    }

    func testRejectsAnyExtraFile() throws {
        let fixture = try GateFixture()
        let extra = LedgerGateChangedFile(
            path: "Sources/Injected.swift",
            change: .added,
            oldMode: "000000",
            newMode: "100644",
            isBinary: false,
            isGenerated: false
        )

        assertGateError(.invalidDiff) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(
                    changedFiles: fixture.canonicalChange + [extra]
                ),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsDeletedExecutableSymlinkBinaryOrGeneratedLedgerDiffs() throws {
        let fixture = try GateFixture()
        let forbidden: [LedgerGateChangedFile] = [
            .init(path: fixture.ledgerPath, change: .deleted, oldMode: "100644", newMode: "000000", isBinary: false, isGenerated: false),
            .init(path: fixture.ledgerPath, change: .modified, oldMode: "100644", newMode: "100755", isBinary: false, isGenerated: false),
            .init(path: fixture.ledgerPath, change: .modified, oldMode: "100644", newMode: "120000", isBinary: false, isGenerated: false),
            .init(path: fixture.ledgerPath, change: .modified, oldMode: "100644", newMode: "100644", isBinary: true, isGenerated: false),
            .init(path: fixture.ledgerPath, change: .modified, oldMode: "100644", newMode: "100644", isBinary: false, isGenerated: true)
        ]

        for changedFile in forbidden {
            assertGateError(.invalidDiff) {
                try LedgerMergeGate().evaluate(
                    snapshot: fixture.snapshot(changedFiles: [changedFile]),
                    policy: fixture.enabledPolicy
                )
            }
        }
    }

    func testRejectsMultipleNewEntries() throws {
        let fixture = try GateFixture()
        let extraEntry = GateFixture.entry(tag: "v0.44.0", releaseID: 44)

        assertGateError(.invalidLedger) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(
                    headLedger: try fixture.ledger(entries: [
                        fixture.baseEntry,
                        fixture.newEntry,
                        extraEntry
                    ])
                ),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsUnverifiedOrMismatchedProvenance() throws {
        let fixture = try GateFixture()

        assertGateError(.invalidProvenance) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(provenanceVerified: false),
                policy: fixture.enabledPolicy
            )
        }
        assertGateError(.invalidProvenance) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(provenanceEntry: fixture.baseEntry),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsSkippingAnEarlierUnprocessedStableRelease() throws {
        let fixture = try GateFixture()
        let skippedEntry = GateFixture.entry(tag: "v0.44.0", releaseID: 44)
        let report = fixture.detectionReport(
            compatibleReleases: [fixture.newEntry, skippedEntry]
        )

        assertGateError(.invalidProvenance) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(
                    headLedger: try fixture.ledger(entries: [fixture.baseEntry, skippedEntry]),
                    provenanceEntry: skippedEntry,
                    detectionReport: report
                ),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsSchemaDriftAndSecretOrPIIStrings() throws {
        let fixture = try GateFixture()
        let unknownKey = try fixture.mutatingHeadLedger { root in
            root["unexpected"] = true
        }
        let duplicateKeys = try ["entries", #"\u0065ntries"#].map {
            try fixture.prependingDuplicateRootKey(encodedKey: $0, rawValue: "[]")
        }
        let deeplyNested = try fixture.prependingDuplicateRootKey(
            encodedKey: "entries",
            rawValue: String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
        )
        let unsafeSignals = [
            "github_pat_AAAAAAAAAAAAAAAAAAAA",
            "sk-proj-AAAAAAAAAAAAAAAAAAAA",
            "glpat-AAAAAAAAAAAAAAAAAAAA",
            "npm_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "ASIAABCDEFGHIJKLMNOP",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "release-owner@example.com"
        ]
        let unsafeLedgers = try unsafeSignals.map { signal in
            try fixture.mutatingHeadLedger { root in
                var entries = root["entries"] as! [[String: Any]]
                var newest = entries[entries.count - 1]
                var assets = newest["assets"] as! [[String: Any]]
                assets[0]["name"] = signal
                newest["assets"] = assets
                entries[entries.count - 1] = newest
                root["entries"] = entries
            }
        }

        for invalidLedger in [unknownKey, deeplyNested] + duplicateKeys {
            assertGateError(.invalidLedger) {
                try LedgerMergeGate().evaluate(
                    snapshot: fixture.snapshot(headLedger: invalidLedger),
                    policy: fixture.enabledPolicy
                )
            }
        }
        for unsafeLedger in unsafeLedgers {
            assertGateError(.unsafeContent) {
                try LedgerMergeGate().evaluate(
                    snapshot: fixture.snapshot(headLedger: unsafeLedger),
                    policy: fixture.enabledPolicy
                )
            }
        }
    }

    func testRejectsWrongAppStaleHeadAndDuplicateRun() throws {
        let fixture = try GateFixture()

        assertGateError(.wrongApp) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(author: fixture.gateActor),
                policy: fixture.enabledPolicy
            )
        }
        assertGateError(.staleHead) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(currentHeadOID: String(repeating: "d", count: 40)),
                policy: fixture.enabledPolicy
            )
        }
        assertGateError(.staleBase) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(currentBaseOID: String(repeating: "d", count: 40)),
                policy: fixture.enabledPolicy
            )
        }
        assertGateError(.duplicateRun) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(completedHeadOIDs: [fixture.headOID]),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsSameAppIDEvenWhenLoginsDiffer() throws {
        let fixture = try GateFixture()
        let aliasedGateApp = LedgerGateAppIdentity(
            id: fixture.mutationApp.appID,
            login: fixture.gateApp.login
        )
        let policy = fixture.policy(gateApp: aliasedGateApp)

        assertGateError(.wrongApp) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.validSnapshot,
                policy: policy
            )
        }
    }

    func testRejectsHiddenIntermediateOrMergeCommitHistory() throws {
        let fixture = try GateFixture()
        let hiddenIntermediate = String(repeating: "d", count: 40)

        for parentOIDs in [
            [hiddenIntermediate],
            [fixture.baseOID, hiddenIntermediate]
        ] {
            assertGateError(.invalidCommitHistory) {
                try LedgerMergeGate().evaluate(
                    snapshot: fixture.snapshot(headParentOIDs: parentOIDs),
                    policy: fixture.enabledPolicy
                )
            }
        }
    }

    func testRejectsRequiredCheckAuthoredByMutationApp() throws {
        let fixture = try GateFixture()
        let policy = fixture.policy(
            requiredChecks: [.init(name: "swiftpm", app: fixture.mutationApp.app)]
        )

        assertGateError(.wrongApp) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.validSnapshot,
                policy: policy
            )
        }
    }

    func testRejectsUnavailableOrWrongAppReview() throws {
        let fixture = try GateFixture()
        let unavailable = LedgerGateReviewEvidence(
            available: false,
            app: fixture.gateApp,
            headOID: fixture.headOID,
            runID: 20,
            attempt: 1,
            actionableFindings: 0,
            evidenceSHA256: String(repeating: "c", count: 64)
        )
        let wrongApp = LedgerGateReviewEvidence(
            available: true,
            app: fixture.mutationApp.app,
            headOID: fixture.headOID,
            runID: 20,
            attempt: 1,
            actionableFindings: 0,
            evidenceSHA256: String(repeating: "c", count: 64)
        )

        for review in [unavailable, wrongApp] {
            assertGateError(.reviewUnavailable) {
                try LedgerMergeGate().evaluate(
                    snapshot: fixture.snapshot(review: review),
                    policy: fixture.enabledPolicy
                )
            }
        }
    }

    func testRejectsMissingChecksAndActionableReview() throws {
        let fixture = try GateFixture()
        let actionable = LedgerGateReviewEvidence(
            available: true,
            app: fixture.gateApp,
            headOID: fixture.headOID,
            runID: 20,
            attempt: 1,
            actionableFindings: 1,
            evidenceSHA256: String(repeating: "c", count: 64)
        )

        assertGateError(.checkUnavailable) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: []),
                policy: fixture.enabledPolicy
            )
        }
        assertGateError(.actionableReview) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(review: actionable),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsOlderSuccessfulCheckWhenLatestRunIsNotSuccessful() throws {
        let fixture = try GateFixture()
        let checks = [
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, conclusion: .success),
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 11, conclusion: .pending),
            fixture.check(
                name: "codex-autoreview",
                app: fixture.gateApp,
                runID: 20,
                evidenceSHA256: String(repeating: "c", count: 64),
                conclusion: .success
            )
        ]

        assertGateError(.checkUnavailable) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: checks),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsOlderSuccessfulReviewCheckWhenLatestRunFails() throws {
        let fixture = try GateFixture()
        let checks = [
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, conclusion: .success),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 20, evidenceSHA256: String(repeating: "c", count: 64), conclusion: .success),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 21, evidenceSHA256: String(repeating: "d", count: 64), conclusion: .failure)
        ]

        assertGateError(.reviewUnavailable) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: checks),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testRejectsConflictingEvidenceForTheSameCheckRun() throws {
        let fixture = try GateFixture()
        let checks = [
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, conclusion: .success),
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, conclusion: .failure),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 20, evidenceSHA256: String(repeating: "c", count: 64), conclusion: .success)
        ]

        assertGateError(.checkUnavailable) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: checks),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testAcceptsSuccessfulLatestAttemptForTheSameWorkflowRun() throws {
        let fixture = try GateFixture()
        let checks = [
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, attempt: 1, conclusion: .failure),
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, attempt: 2, conclusion: .success),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 20, evidenceSHA256: String(repeating: "c", count: 64), conclusion: .success)
        ]

        XCTAssertNoThrow(
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: checks),
                policy: fixture.enabledPolicy
            )
        )
    }

    func testRejectsReviewDetailsFromAnOlderSuccessfulRun() throws {
        let fixture = try GateFixture()
        let oldDigest = String(repeating: "c", count: 64)
        let latestDigest = String(repeating: "d", count: 64)
        let checks = [
            fixture.check(name: "swiftpm", app: fixture.ciApp, runID: 10, conclusion: .success),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 20, evidenceSHA256: oldDigest, conclusion: .success),
            fixture.check(name: "codex-autoreview", app: fixture.gateApp, runID: 21, evidenceSHA256: latestDigest, conclusion: .success)
        ]
        let staleReview = LedgerGateReviewEvidence(
            available: true,
            app: fixture.gateApp,
            headOID: fixture.headOID,
            runID: 20,
            attempt: 1,
            actionableFindings: 0,
            evidenceSHA256: oldDigest
        )

        assertGateError(.reviewUnavailable) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.snapshot(checks: checks, review: staleReview),
                policy: fixture.enabledPolicy
            )
        }
    }

    func testCommittedPolicyKeepsTheLaneDisabledUntilAppsAreProvisioned() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(
            contentsOf: packageRoot.appendingPathComponent("Tests/CodexBarReleaseDetectionTests/Fixtures/codexbar-ledger-gate-policy.json")
        )
        let policy = try JSONDecoder().decode(LedgerMergeGatePolicy.self, from: data)
        let fixture = try GateFixture()

        XCTAssertFalse(policy.enabled)
        XCTAssertNotEqual(policy.mutationApp.appID, policy.gateApp.id)
        assertGateError(.laneDisabled) {
            try LedgerMergeGate().evaluate(snapshot: fixture.validSnapshot, policy: policy)
        }
    }

    func testSuspensionRequiresExplicitHumanRecoveryBeforeRestart() throws {
        let fixture = try GateFixture()
        let suspensionID = "unexpected-merge-20260718"
        let suspended = fixture.policy(suspended: true, suspensionID: suspensionID)

        assertGateError(.laneSuspended) {
            try LedgerMergeGate().evaluate(
                snapshot: fixture.validSnapshot,
                policy: suspended
            )
        }
        XCTAssertThrowsError(
            try LedgerMergeLaneRecovery().resume(
                policy: suspended,
                approval: try fixture.recoveryApproval(
                    suspensionID: "wrong-incident"
                )
            )
        ) { error in
            XCTAssertEqual(error as? LedgerMergeGateError, .recoveryApprovalRequired)
        }

        for invalidApproval in [
            try fixture.recoveryApproval(
                suspensionID: suspensionID,
                reviewerID: 405,
                reviewerLogin: "other-maintainer"
            ),
            try fixture.recoveryApproval(
                suspensionID: suspensionID,
                evidenceSHA256: String(repeating: "f", count: 64)
            ),
            LedgerGateRecoveryApproval(
                suspensionID: suspensionID,
                reviewerID: 404,
                reviewerLogin: "reviewer-one",
                evidenceSHA256: String(repeating: "e", count: 64),
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        ] {
            XCTAssertThrowsError(
                try LedgerMergeLaneRecovery().resume(
                    policy: suspended,
                    approval: invalidApproval
                )
            ) { error in
                XCTAssertEqual(error as? LedgerMergeGateError, .recoveryApprovalRequired)
            }
        }

        let restarted = try LedgerMergeLaneRecovery().resume(
            policy: suspended,
            approval: try fixture.recoveryApproval(suspensionID: suspensionID)
        )
        XCTAssertFalse(restarted.suspended)
        XCTAssertNil(restarted.suspensionID)
        XCTAssertEqual(
            try LedgerMergeGate().evaluate(snapshot: fixture.validSnapshot, policy: restarted),
            try LedgerMergeGate().evaluate(snapshot: fixture.validSnapshot, policy: fixture.enabledPolicy)
        )
    }

    private func assertGateError(
        _ expected: LedgerMergeGateError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> LedgerMergeGateDecision
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? LedgerMergeGateError, expected, file: file, line: line)
        }
    }
}

private struct GateFixture {
    let ledgerPath = "release/codexbar-verified-releases.json"
    let baseOID = String(repeating: "a", count: 40)
    let headOID = String(repeating: "b", count: 40)
    let mutationApp = LedgerGateMutationIdentity(
        actorID: 101,
        actorLogin: "codexbar-ledger-mutation[bot]",
        appID: 102,
        appLogin: "codexbar-ledger-mutation"
    )
    let gateApp = LedgerGateAppIdentity(id: 202, login: "codexbar-ledger-gate[bot]")
    let ciApp = LedgerGateAppIdentity(id: 303, login: "github-actions[bot]")
    let recoveryPrivateKey = Curve25519.Signing.PrivateKey()
    let baseEntry: VerifiedReleaseEntry
    let newEntry: VerifiedReleaseEntry
    let baseLedger: Data
    let headLedger: Data

    init() throws {
        baseEntry = Self.entry(tag: "v0.42.1", releaseID: 42)
        newEntry = Self.entry(tag: "v0.43.0", releaseID: 43)
        baseLedger = try Self.ledger(entries: [baseEntry])
        headLedger = try Self.ledger(entries: [baseEntry, newEntry])
    }

    var enabledPolicy: LedgerMergeGatePolicy {
        policy()
    }

    var gateActor: LedgerGateActorIdentity {
        .init(id: gateApp.id, login: gateApp.login)
    }

    func policy(
        suspended: Bool = false,
        suspensionID: String? = nil,
        mutationApp: LedgerGateMutationIdentity? = nil,
        gateApp: LedgerGateAppIdentity? = nil,
        requiredChecks: [LedgerGateCheckRequirement]? = nil
    ) -> LedgerMergeGatePolicy {
        .init(
            enabled: true,
            suspended: suspended,
            suspensionID: suspensionID,
            repository: "AkiGarage/codex-usage-widget",
            baseBranch: "main",
            ledgerPath: ledgerPath,
            mutationApp: mutationApp ?? self.mutationApp,
            gateApp: gateApp ?? self.gateApp,
            requiredChecks: requiredChecks ?? [.init(name: "swiftpm", app: ciApp)],
            recoveryReviewerIDs: [404],
            recoverySigningPublicKeyBase64: recoveryPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            suspensionEvidenceSHA256: suspended ? String(repeating: "e", count: 64) : nil
        )
    }

    var canonicalChange: [LedgerGateChangedFile] {
        [
            .init(
                path: ledgerPath,
                change: .modified,
                oldMode: "100644",
                newMode: "100644",
                isBinary: false,
                isGenerated: false
            )
        ]
    }

    var validSnapshot: LedgerMergeGateSnapshot {
        snapshot()
    }

    func snapshot(
        author: LedgerGateActorIdentity? = nil,
        baseBranch: String? = nil,
        currentBaseOID: String? = nil,
        currentHeadOID: String? = nil,
        headParentOIDs: [String]? = nil,
        changedFiles: [LedgerGateChangedFile]? = nil,
        headLedger: Data? = nil,
        provenanceEntry: VerifiedReleaseEntry? = nil,
        provenanceVerified: Bool = true,
        includeProvenance: Bool = true,
        detectionReport: ReleaseDetectionReport? = nil,
        checks: [LedgerGateCheckEvidence]? = nil,
        review: LedgerGateReviewEvidence? = nil,
        completedHeadOIDs: Set<String> = []
    ) -> LedgerMergeGateSnapshot {
        .init(
            repository: "AkiGarage/codex-usage-widget",
            isPrivateRepository: true,
            pullRequestNumber: 55,
            author: author ?? mutationApp.actor,
            headRepository: "AkiGarage/codex-usage-widget",
            baseBranch: baseBranch ?? "main",
            proposedBaseOID: baseOID,
            currentBaseOID: currentBaseOID ?? baseOID,
            proposedHeadOID: headOID,
            currentHeadOID: currentHeadOID ?? headOID,
            headParentOIDs: headParentOIDs ?? [baseOID],
            changedFiles: changedFiles ?? canonicalChange,
            baseLedger: baseLedger,
            headLedger: headLedger ?? self.headLedger,
            provenance: includeProvenance ? .init(
                entry: provenanceEntry ?? newEntry,
                baseOID: baseOID,
                headOID: headOID,
                verified: provenanceVerified,
                detectionReport: detectionReport ?? self.detectionReport()
            ) : nil,
            checks: checks ?? [
                check(name: "swiftpm", app: ciApp, runID: 10, conclusion: .success),
                check(
                    name: "codex-autoreview",
                    app: gateApp,
                    runID: 20,
                    evidenceSHA256: String(repeating: "c", count: 64),
                    conclusion: .success
                )
            ],
            review: review ?? .init(
                available: true,
                app: gateApp,
                headOID: headOID,
                runID: 20,
                attempt: 1,
                actionableFindings: 0,
                evidenceSHA256: String(repeating: "c", count: 64)
            ),
            completedHeadOIDs: completedHeadOIDs
        )
    }

    func check(
        name: String,
        app: LedgerGateAppIdentity,
        runID: Int64,
        attempt: Int = 1,
        evidenceSHA256: String? = nil,
        conclusion: LedgerGateCheckConclusion
    ) -> LedgerGateCheckEvidence {
        .init(
            name: name,
            app: app,
            headOID: headOID,
            runID: runID,
            attempt: attempt,
            completedAt: conclusion == .pending ? nil : Date(timeIntervalSince1970: 1_750_000_000 + Double(runID)),
            evidenceSHA256: evidenceSHA256,
            conclusion: conclusion
        )
    }

    func detectionReport(
        compatibleReleases: [VerifiedReleaseEntry]? = nil,
        pendingReleases: [PendingRelease] = []
    ) -> ReleaseDetectionReport {
        let compatible = compatibleReleases ?? [newEntry]
        let unseenTags = (compatible.map(\.tag) + pendingReleases.map(\.tag)).sorted {
            StableSemanticVersion(tag: $0)! < StableSemanticVersion(tag: $1)!
        }
        return .init(
            schemaVersion: 1,
            repository: "steipete/CodexBar",
            verifiedThroughTag: baseEntry.tag,
            scannedStableTags: [baseEntry.tag] + unseenTags,
            compatibleReleases: compatible,
            pendingReleases: pendingReleases,
            syntheticFixtureMatrixPassed: true
        )
    }

    func recoveryApproval(
        suspensionID: String,
        reviewerID: Int64 = 404,
        reviewerLogin: String = "reviewer-one",
        evidenceSHA256: String = String(repeating: "e", count: 64)
    ) throws -> LedgerGateRecoveryApproval {
        let payload = LedgerGateRecoveryApproval.signingPayload(
            repository: "AkiGarage/codex-usage-widget",
            suspensionID: suspensionID,
            reviewerID: reviewerID,
            reviewerLogin: reviewerLogin,
            evidenceSHA256: evidenceSHA256
        )
        let signature = try recoveryPrivateKey.signature(for: payload)
        return .init(
            suspensionID: suspensionID,
            reviewerID: reviewerID,
            reviewerLogin: reviewerLogin,
            evidenceSHA256: evidenceSHA256,
            signatureBase64: signature.base64EncodedString()
        )
    }

    func ledger(entries: [VerifiedReleaseEntry]) throws -> Data {
        try Self.ledger(entries: entries)
    }

    func mutatingHeadLedger(_ mutation: (inout [String: Any]) -> Void) throws -> Data {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: headLedger) as? [String: Any]
        )
        mutation(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func prependingDuplicateRootKey(encodedKey: String, rawValue: String) throws -> Data {
        let source = try XCTUnwrap(String(data: headLedger, encoding: .utf8))
        guard source.first == "{" else { throw LedgerMergeGateError.invalidLedger }
        return Data("{\"\(encodedKey)\":\(rawValue),\(source.dropFirst())".utf8)
    }

    private static func ledger(entries: [VerifiedReleaseEntry]) throws -> Data {
        let ledger = VerifiedReleaseLedger(
            schemaVersion: 1,
            repository: "steipete/CodexBar",
            minimumTag: "v0.32.4",
            verifiedThroughTag: entries.last!.tag,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    static func entry(tag: String, releaseID: Int64) -> VerifiedReleaseEntry {
        VerifiedReleaseEntry(
            releaseID: releaseID,
            tag: tag,
            publishedAt: "2026-07-17T00:00:00Z",
            tagObjectSHA: String(repeating: "1", count: 40),
            peeledCommitSHA: String(repeating: "2", count: 40),
            signature: .init(verified: true, reason: "valid"),
            assets: [
                .init(
                    id: releaseID * 10,
                    name: "CodexBarCLI-\(tag)-macos-arm64.tar.gz",
                    size: 100,
                    digest: "sha256:" + String(repeating: "a", count: 64)
                )
            ],
            contractBlobs: CodexBarContractPaths.all.map {
                .init(
                    path: $0,
                    blobSHA: String(repeating: "3", count: 40),
                    sha256: String(repeating: "d", count: 64)
                )
            }
        )
    }
}
