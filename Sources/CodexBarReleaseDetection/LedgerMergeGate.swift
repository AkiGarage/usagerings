import CryptoKit
import Foundation

public struct LedgerGateAppIdentity: Codable, Equatable, Sendable {
    public let id: Int64
    public let login: String

    public init(id: Int64, login: String) {
        self.id = id
        self.login = login
    }
}

public struct LedgerGateActorIdentity: Codable, Equatable, Sendable {
    public let id: Int64
    public let login: String

    public init(id: Int64, login: String) {
        self.id = id
        self.login = login
    }
}

public struct LedgerGateMutationIdentity: Codable, Equatable, Sendable {
    public let actorID: Int64
    public let actorLogin: String
    public let appID: Int64
    public let appLogin: String

    public init(actorID: Int64, actorLogin: String, appID: Int64, appLogin: String) {
        self.actorID = actorID
        self.actorLogin = actorLogin
        self.appID = appID
        self.appLogin = appLogin
    }

    public var actor: LedgerGateActorIdentity {
        .init(id: actorID, login: actorLogin)
    }

    public var app: LedgerGateAppIdentity {
        .init(id: appID, login: appLogin)
    }
}

public struct LedgerGateCheckRequirement: Codable, Equatable, Sendable {
    public let name: String
    public let app: LedgerGateAppIdentity

    public init(name: String, app: LedgerGateAppIdentity) {
        self.name = name
        self.app = app
    }
}

public struct LedgerMergeGatePolicy: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let suspended: Bool
    public let suspensionID: String?
    public let repository: String
    public let baseBranch: String
    public let ledgerPath: String
    public let mutationApp: LedgerGateMutationIdentity
    public let gateApp: LedgerGateAppIdentity
    public let requiredChecks: [LedgerGateCheckRequirement]
    public let recoveryReviewerIDs: Set<Int64>
    public let recoverySigningPublicKeyBase64: String?
    public let suspensionEvidenceSHA256: String?

    public init(
        enabled: Bool,
        suspended: Bool,
        suspensionID: String? = nil,
        repository: String,
        baseBranch: String,
        ledgerPath: String,
        mutationApp: LedgerGateMutationIdentity,
        gateApp: LedgerGateAppIdentity,
        requiredChecks: [LedgerGateCheckRequirement],
        recoveryReviewerIDs: Set<Int64>,
        recoverySigningPublicKeyBase64: String? = nil,
        suspensionEvidenceSHA256: String? = nil
    ) {
        self.enabled = enabled
        self.suspended = suspended
        self.suspensionID = suspensionID
        self.repository = repository
        self.baseBranch = baseBranch
        self.ledgerPath = ledgerPath
        self.mutationApp = mutationApp
        self.gateApp = gateApp
        self.requiredChecks = requiredChecks
        self.recoveryReviewerIDs = recoveryReviewerIDs
        self.recoverySigningPublicKeyBase64 = recoverySigningPublicKeyBase64
        self.suspensionEvidenceSHA256 = suspensionEvidenceSHA256
    }

    public var authorizationSHA256: String {
        let optional: (String?) -> String = { value in
            value.map { "some:\($0)" } ?? "none"
        }
        var fields = [
            "ledger-merge-policy-v1",
            String(enabled),
            String(suspended),
            optional(suspensionID),
            repository,
            baseBranch,
            ledgerPath,
            String(mutationApp.actorID),
            mutationApp.actorLogin,
            String(mutationApp.appID),
            mutationApp.appLogin,
            String(gateApp.id),
            gateApp.login,
            "requiredChecks",
            String(requiredChecks.count)
        ]
        for requirement in requiredChecks {
            fields.append(requirement.name)
            fields.append(String(requirement.app.id))
            fields.append(requirement.app.login)
        }
        fields.append("recoveryReviewerIDs")
        fields.append(String(recoveryReviewerIDs.count))
        fields.append(contentsOf: recoveryReviewerIDs.sorted().map(String.init))
        fields.append("recoverySigningPublicKeyBase64")
        fields.append(optional(recoverySigningPublicKeyBase64))
        fields.append("suspensionEvidenceSHA256")
        fields.append(optional(suspensionEvidenceSHA256))

        var material = Data()
        for field in fields {
            material.append(contentsOf: "\(field.utf8.count):".utf8)
            material.append(contentsOf: field.utf8)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LedgerGateFileChange: String, Codable, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
}

public struct LedgerGateChangedFile: Codable, Equatable, Sendable {
    public let path: String
    public let change: LedgerGateFileChange
    public let oldMode: String
    public let newMode: String
    public let isBinary: Bool
    public let isGenerated: Bool

    public init(
        path: String,
        change: LedgerGateFileChange,
        oldMode: String,
        newMode: String,
        isBinary: Bool,
        isGenerated: Bool
    ) {
        self.path = path
        self.change = change
        self.oldMode = oldMode
        self.newMode = newMode
        self.isBinary = isBinary
        self.isGenerated = isGenerated
    }
}

public enum LedgerGateCheckConclusion: String, Codable, Equatable, Sendable {
    case success
    case failure
    case pending
    case skipped
}

public struct LedgerGateCheckEvidence: Codable, Equatable, Sendable {
    public let name: String
    public let app: LedgerGateAppIdentity
    public let headOID: String
    public let runID: Int64
    public let attempt: Int
    public let completedAt: Date?
    public let evidenceSHA256: String?
    public let conclusion: LedgerGateCheckConclusion

    public init(
        name: String,
        app: LedgerGateAppIdentity,
        headOID: String,
        runID: Int64,
        attempt: Int,
        completedAt: Date?,
        evidenceSHA256: String? = nil,
        conclusion: LedgerGateCheckConclusion
    ) {
        self.name = name
        self.app = app
        self.headOID = headOID
        self.runID = runID
        self.attempt = attempt
        self.completedAt = completedAt
        self.evidenceSHA256 = evidenceSHA256
        self.conclusion = conclusion
    }
}

public struct LedgerGateReviewEvidence: Codable, Equatable, Sendable {
    public let available: Bool
    public let app: LedgerGateAppIdentity
    public let headOID: String
    public let runID: Int64
    public let attempt: Int
    public let actionableFindings: Int
    public let evidenceSHA256: String

    public init(
        available: Bool,
        app: LedgerGateAppIdentity,
        headOID: String,
        runID: Int64,
        attempt: Int,
        actionableFindings: Int,
        evidenceSHA256: String
    ) {
        self.available = available
        self.app = app
        self.headOID = headOID
        self.runID = runID
        self.attempt = attempt
        self.actionableFindings = actionableFindings
        self.evidenceSHA256 = evidenceSHA256
    }
}

public struct LedgerGateProvenanceEvidence: Codable, Equatable, Sendable {
    public let entry: VerifiedReleaseEntry
    public let baseOID: String
    public let headOID: String
    public let verified: Bool
    public let detectionReport: ReleaseDetectionReport

    public init(
        entry: VerifiedReleaseEntry,
        baseOID: String,
        headOID: String,
        verified: Bool,
        detectionReport: ReleaseDetectionReport
    ) {
        self.entry = entry
        self.baseOID = baseOID
        self.headOID = headOID
        self.verified = verified
        self.detectionReport = detectionReport
    }
}

public struct LedgerMergeGateSnapshot: Equatable, Sendable {
    public let repository: String
    public let isPrivateRepository: Bool
    public let pullRequestNumber: Int
    public let author: LedgerGateActorIdentity
    public let headRepository: String
    public let baseBranch: String
    public let proposedBaseOID: String
    public let currentBaseOID: String
    public let proposedHeadOID: String
    public let currentHeadOID: String
    public let headParentOIDs: [String]
    public let changedFiles: [LedgerGateChangedFile]
    public let baseLedger: Data
    public let headLedger: Data
    public let provenance: LedgerGateProvenanceEvidence?
    public let checks: [LedgerGateCheckEvidence]
    public let review: LedgerGateReviewEvidence
    public let completedHeadOIDs: Set<String>

    public init(
        repository: String,
        isPrivateRepository: Bool,
        pullRequestNumber: Int,
        author: LedgerGateActorIdentity,
        headRepository: String,
        baseBranch: String,
        proposedBaseOID: String,
        currentBaseOID: String,
        proposedHeadOID: String,
        currentHeadOID: String,
        headParentOIDs: [String],
        changedFiles: [LedgerGateChangedFile],
        baseLedger: Data,
        headLedger: Data,
        provenance: LedgerGateProvenanceEvidence?,
        checks: [LedgerGateCheckEvidence],
        review: LedgerGateReviewEvidence,
        completedHeadOIDs: Set<String>
    ) {
        self.repository = repository
        self.isPrivateRepository = isPrivateRepository
        self.pullRequestNumber = pullRequestNumber
        self.author = author
        self.headRepository = headRepository
        self.baseBranch = baseBranch
        self.proposedBaseOID = proposedBaseOID
        self.currentBaseOID = currentBaseOID
        self.proposedHeadOID = proposedHeadOID
        self.currentHeadOID = currentHeadOID
        self.headParentOIDs = headParentOIDs
        self.changedFiles = changedFiles
        self.baseLedger = baseLedger
        self.headLedger = headLedger
        self.provenance = provenance
        self.checks = checks
        self.review = review
        self.completedHeadOIDs = completedHeadOIDs
    }

    public func authorizationSHA256() throws -> String {
        var fields = [
            "ledger-merge-snapshot-v2",
            repository,
            String(isPrivateRepository),
            String(pullRequestNumber),
            String(author.id),
            author.login,
            headRepository,
            baseBranch,
            proposedBaseOID,
            currentBaseOID,
            proposedHeadOID,
            currentHeadOID,
            "headParentOIDs",
            String(headParentOIDs.count)
        ]
        fields.append(contentsOf: headParentOIDs)
        fields.append(contentsOf: [
            "changedFiles",
            String(changedFiles.count)
        ])
        for file in changedFiles.sorted(by: { $0.path < $1.path }) {
            fields.append(contentsOf: [
                file.path,
                file.change.rawValue,
                file.oldMode,
                file.newMode,
                String(file.isBinary),
                String(file.isGenerated)
            ])
        }
        fields.append("baseLedgerSHA256")
        fields.append(Self.sha256(baseLedger))
        fields.append("headLedgerSHA256")
        fields.append(Self.sha256(headLedger))
        fields.append("provenance")
        if let provenance {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            fields.append((try encoder.encode(provenance)).base64EncodedString())
        } else {
            fields.append("none")
        }

        let sortedChecks = checks.sorted { lhs, rhs in
            Self.checkSortKey(lhs).lexicographicallyPrecedes(Self.checkSortKey(rhs))
        }
        fields.append("checks")
        fields.append(String(sortedChecks.count))
        for check in sortedChecks {
            fields.append(contentsOf: Self.checkSortKey(check))
        }
        fields.append(contentsOf: [
            "review",
            String(review.available),
            String(review.app.id),
            review.app.login,
            review.headOID,
            String(review.runID),
            String(review.attempt),
            String(review.actionableFindings),
            review.evidenceSHA256,
            "completedHeadOIDs",
            String(completedHeadOIDs.count)
        ])
        fields.append(contentsOf: completedHeadOIDs.sorted())

        var material = Data()
        for field in fields {
            material.append(contentsOf: "\(field.utf8.count):".utf8)
            material.append(contentsOf: field.utf8)
        }
        return Self.sha256(material)
    }

    private static func checkSortKey(_ check: LedgerGateCheckEvidence) -> [String] {
        [
            check.name,
            String(check.app.id),
            check.app.login,
            check.headOID,
            String(check.runID),
            String(check.attempt),
            optionalDate(check.completedAt),
            check.evidenceSHA256.map { "some:\($0)" } ?? "none",
            check.conclusion.rawValue
        ]
    }

    private static func optionalDate(_ date: Date?) -> String {
        date.map { "some:\($0.timeIntervalSince1970.bitPattern)" } ?? "none"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LedgerMergeAuthorization: Equatable, Sendable {
    let pullRequestNumber: Int
    let baseOID: String
    let headOID: String
    let canonicalIdentity: String
    let mutationAppID: Int64
    let gateAppID: Int64

    init(
        pullRequestNumber: Int,
        baseOID: String,
        headOID: String,
        canonicalIdentity: String,
        mutationAppID: Int64,
        gateAppID: Int64
    ) {
        self.pullRequestNumber = pullRequestNumber
        self.baseOID = baseOID
        self.headOID = headOID
        self.canonicalIdentity = canonicalIdentity
        self.mutationAppID = mutationAppID
        self.gateAppID = gateAppID
    }
}

enum LedgerMergeGateDecision: Equatable, Sendable {
    case noOp
    case authorized(LedgerMergeAuthorization)
}

public enum LedgerMergeGateError: Error, Equatable, Sendable {
    case laneDisabled
    case laneSuspended
    case wrongRepository
    case wrongApp
    case staleBase
    case staleHead
    case stalePolicy
    case duplicateRun
    case invalidCommitHistory
    case invalidDiff
    case invalidLedger
    case invalidProvenance
    case checkUnavailable
    case reviewUnavailable
    case actionableReview
    case unsafeContent
    case recoveryApprovalRequired
}

public struct LedgerGateRecoveryApproval: Codable, Equatable, Sendable {
    public let suspensionID: String
    public let reviewerID: Int64
    public let reviewerLogin: String
    public let evidenceSHA256: String
    public let signatureBase64: String

    public init(
        suspensionID: String,
        reviewerID: Int64,
        reviewerLogin: String,
        evidenceSHA256: String,
        signatureBase64: String
    ) {
        self.suspensionID = suspensionID
        self.reviewerID = reviewerID
        self.reviewerLogin = reviewerLogin
        self.evidenceSHA256 = evidenceSHA256
        self.signatureBase64 = signatureBase64
    }

    public static func signingPayload(
        repository: String,
        suspensionID: String,
        reviewerID: Int64,
        reviewerLogin: String,
        evidenceSHA256: String
    ) -> Data {
        Data(
            [
                "ledger-merge-recovery-v1",
                repository,
                suspensionID,
                String(reviewerID),
                reviewerLogin,
                evidenceSHA256
            ].joined(separator: "\n").utf8
        )
    }
}

public struct LedgerMergeLaneRecovery: Sendable {
    public init() {}

    public func resume(
        policy: LedgerMergeGatePolicy,
        approval: LedgerGateRecoveryApproval
    ) throws -> LedgerMergeGatePolicy {
        guard policy.suspended,
              let suspensionID = policy.suspensionID,
              let suspensionEvidenceSHA256 = policy.suspensionEvidenceSHA256,
              let publicKeyBase64 = policy.recoverySigningPublicKeyBase64,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: approval.signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              !suspensionID.isEmpty,
              suspensionID.count <= 128,
              !suspensionID.contains("\n"),
              approval.suspensionID == suspensionID,
              approval.reviewerID > 0,
              policy.recoveryReviewerIDs.contains(approval.reviewerID),
              Self.isHumanGitHubLogin(approval.reviewerLogin),
              IdentityValidation.isBareSHA256(suspensionEvidenceSHA256),
              approval.evidenceSHA256 == suspensionEvidenceSHA256,
              publicKey.isValidSignature(
                  signature,
                  for: LedgerGateRecoveryApproval.signingPayload(
                      repository: policy.repository,
                      suspensionID: suspensionID,
                      reviewerID: approval.reviewerID,
                      reviewerLogin: approval.reviewerLogin,
                      evidenceSHA256: approval.evidenceSHA256
                  )
              )
        else { throw LedgerMergeGateError.recoveryApprovalRequired }

        return LedgerMergeGatePolicy(
            enabled: policy.enabled,
            suspended: false,
            suspensionID: nil,
            repository: policy.repository,
            baseBranch: policy.baseBranch,
            ledgerPath: policy.ledgerPath,
            mutationApp: policy.mutationApp,
            gateApp: policy.gateApp,
            requiredChecks: policy.requiredChecks,
            recoveryReviewerIDs: policy.recoveryReviewerIDs,
            recoverySigningPublicKeyBase64: policy.recoverySigningPublicKeyBase64
        )
    }

    private static func isHumanGitHubLogin(_ value: String) -> Bool {
        !value.isEmpty &&
            value.count <= 39 &&
            value.first != "-" &&
            value.last != "-" &&
            value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

public enum LedgerMergeExecutionResult: Equatable, Sendable {
    case noOp
    case performed
}

public struct LedgerMergeExecutionAuthorization: Equatable, Sendable {
    public let expectedRepository: String
    public let expectedBaseBranch: String
    public let pullRequestNumber: Int
    public let expectedBaseOID: String
    public let expectedHeadOID: String
    public let expectedHeadParentOIDs: [String]
    public let expectedPolicySHA256: String
    public let expectedSnapshotSHA256: String
    public let canonicalIdentity: String
    public let mutationAppID: Int64
    public let gateAppID: Int64

    fileprivate init(
        _ authorization: LedgerMergeAuthorization,
        policy: LedgerMergeGatePolicy,
        snapshot: LedgerMergeGateSnapshot,
        expectedSnapshotSHA256: String
    ) {
        expectedRepository = snapshot.repository
        expectedBaseBranch = snapshot.baseBranch
        pullRequestNumber = authorization.pullRequestNumber
        expectedBaseOID = authorization.baseOID
        expectedHeadOID = authorization.headOID
        expectedHeadParentOIDs = snapshot.headParentOIDs
        expectedPolicySHA256 = policy.authorizationSHA256
        self.expectedSnapshotSHA256 = expectedSnapshotSHA256
        canonicalIdentity = authorization.canonicalIdentity
        mutationAppID = authorization.mutationAppID
        gateAppID = authorization.gateAppID
    }
}

public struct LedgerMergeGate: Sendable {
    public init() {}

    /// The mutation callback must atomically compare every expected value in the
    /// authorization with live state and return `false` without merging on drift.
    public func execute(
        loadFreshPolicy: () async throws -> LedgerMergeGatePolicy,
        loadFreshSnapshot: () async throws -> LedgerMergeGateSnapshot,
        performAtomicMergeIfCurrent: (LedgerMergeExecutionAuthorization) async throws -> Bool
    ) async throws -> LedgerMergeExecutionResult {
        let policy = try await loadFreshPolicy()
        let snapshot = try await loadFreshSnapshot()
        switch try evaluate(snapshot: snapshot, policy: policy) {
        case .noOp:
            return .noOp
        case .authorized:
            let boundaryPolicy = try await loadFreshPolicy()
            let boundarySnapshot = try await loadFreshSnapshot()
            switch try evaluate(snapshot: boundarySnapshot, policy: boundaryPolicy) {
            case .noOp:
                return .noOp
            case let .authorized(authorization):
                let executionAuthorization = LedgerMergeExecutionAuthorization(
                    authorization,
                    policy: boundaryPolicy,
                    snapshot: boundarySnapshot,
                    expectedSnapshotSHA256: try boundarySnapshot.authorizationSHA256()
                )
                // The mutation implementation must atomically compare live target ref, PR,
                // evidence snapshot, and policy digest with these expected values.
                guard try await performAtomicMergeIfCurrent(executionAuthorization) else {
                    throw LedgerMergeGateError.stalePolicy
                }
                return .performed
            }
        }
    }

    func evaluate(
        snapshot: LedgerMergeGateSnapshot,
        policy: LedgerMergeGatePolicy
    ) throws -> LedgerMergeGateDecision {
        guard policy.enabled else { throw LedgerMergeGateError.laneDisabled }
        guard !policy.suspended else { throw LedgerMergeGateError.laneSuspended }
        guard policy.mutationApp.actorID > 0,
              policy.mutationApp.appID > 0,
              policy.gateApp.id > 0,
              policy.mutationApp.appID != policy.gateApp.id,
              !policy.mutationApp.actorLogin.isEmpty,
              !policy.mutationApp.appLogin.isEmpty,
              !policy.gateApp.login.isEmpty,
              !policy.requiredChecks.isEmpty,
              policy.requiredChecks.allSatisfy({
                  !$0.name.isEmpty &&
                      $0.app.id > 0 &&
                      $0.app.id != policy.mutationApp.appID &&
                      !$0.app.login.isEmpty
              })
        else { throw LedgerMergeGateError.wrongApp }
        guard snapshot.repository == policy.repository,
              snapshot.headRepository == policy.repository,
              snapshot.isPrivateRepository,
              snapshot.baseBranch == policy.baseBranch,
              snapshot.pullRequestNumber > 0
        else { throw LedgerMergeGateError.wrongRepository }
        guard snapshot.author == policy.mutationApp.actor else {
            throw LedgerMergeGateError.wrongApp
        }
        guard Self.isGitOID(snapshot.proposedBaseOID),
              snapshot.proposedBaseOID == snapshot.currentBaseOID
        else { throw LedgerMergeGateError.staleBase }
        guard Self.isGitOID(snapshot.proposedHeadOID),
              snapshot.proposedHeadOID == snapshot.currentHeadOID
        else { throw LedgerMergeGateError.staleHead }
        guard snapshot.headParentOIDs == [snapshot.currentBaseOID] else {
            throw LedgerMergeGateError.invalidCommitHistory
        }
        guard !snapshot.completedHeadOIDs.contains(snapshot.currentHeadOID) else {
            throw LedgerMergeGateError.duplicateRun
        }
        let base: VerifiedReleaseLedger
        let head: VerifiedReleaseLedger
        do {
            base = try Self.decodeStrictLedger(snapshot.baseLedger)
            head = try Self.decodeStrictLedger(snapshot.headLedger)
        } catch let error as LedgerMergeGateError {
            throw error
        } catch {
            throw LedgerMergeGateError.invalidLedger
        }
        if snapshot.changedFiles.isEmpty, base == head {
            return .noOp
        }
        guard snapshot.changedFiles == [
            LedgerGateChangedFile(
                path: policy.ledgerPath,
                change: .modified,
                oldMode: "100644",
                newMode: "100644",
                isBinary: false,
                isGenerated: false
            )
        ] else { throw LedgerMergeGateError.invalidDiff }
        guard base.schemaVersion == head.schemaVersion,
              base.repository == head.repository,
              base.minimumTag == head.minimumTag,
              head.entries.count == base.entries.count + 1,
              Array(head.entries.dropLast()) == base.entries,
              let entry = head.entries.last,
              let entryVersion = StableSemanticVersion(tag: entry.tag),
              head.verifiedThroughTag == entry.tag,
              entryVersion > base.verifiedThroughVersion
        else { throw LedgerMergeGateError.invalidLedger }

        guard let provenance = snapshot.provenance,
              provenance.verified,
              provenance.entry == entry,
              provenance.baseOID == snapshot.currentBaseOID,
              provenance.headOID == snapshot.currentHeadOID,
              Self.isNextDetectedRelease(
                  report: provenance.detectionReport,
                  base: base,
                  entry: entry
              )
        else { throw LedgerMergeGateError.invalidProvenance }

        for requirement in policy.requiredChecks {
            guard let latest = try Self.latestCheck(
                named: requirement.name,
                app: requirement.app,
                headOID: snapshot.currentHeadOID,
                checks: snapshot.checks,
                unavailableError: .checkUnavailable
            ), latest.conclusion == .success else {
                throw LedgerMergeGateError.checkUnavailable
            }
        }

        guard snapshot.review.available,
              snapshot.review.app == policy.gateApp,
              snapshot.review.headOID == snapshot.currentHeadOID,
              IdentityValidation.isBareSHA256(snapshot.review.evidenceSHA256),
              let latestReviewCheck = try Self.latestCheck(
                  named: "codex-autoreview",
                  app: policy.gateApp,
                  headOID: snapshot.currentHeadOID,
                  checks: snapshot.checks,
                  unavailableError: .reviewUnavailable
              ),
              latestReviewCheck.conclusion == .success,
              snapshot.review.runID == latestReviewCheck.runID,
              snapshot.review.attempt == latestReviewCheck.attempt,
              snapshot.review.evidenceSHA256 == latestReviewCheck.evidenceSHA256
        else { throw LedgerMergeGateError.reviewUnavailable }
        guard snapshot.review.actionableFindings == 0 else {
            throw LedgerMergeGateError.actionableReview
        }

        return .authorized(
            LedgerMergeAuthorization(
                pullRequestNumber: snapshot.pullRequestNumber,
                baseOID: snapshot.currentBaseOID,
                headOID: snapshot.currentHeadOID,
                canonicalIdentity: entry.canonicalIdentity,
                mutationAppID: policy.mutationApp.appID,
                gateAppID: policy.gateApp.id
            )
        )
    }

    private static func isGitOID(_ value: String) -> Bool {
        VerifiedReleaseLedger.isGitSHA(value)
    }

    private static func latestCheck(
        named name: String,
        app: LedgerGateAppIdentity,
        headOID: String,
        checks: [LedgerGateCheckEvidence],
        unavailableError: LedgerMergeGateError
    ) throws -> LedgerGateCheckEvidence? {
        let candidates = checks.filter {
            $0.name == name && $0.app == app && $0.headOID == headOID
        }
        guard candidates.allSatisfy(Self.isValidCheckEvidence) else {
            throw unavailableError
        }

        var uniqueByRun: [CheckRunKey: LedgerGateCheckEvidence] = [:]
        for evidence in candidates {
            let key = CheckRunKey(runID: evidence.runID, attempt: evidence.attempt)
            if let existing = uniqueByRun[key], existing != evidence {
                throw unavailableError
            }
            uniqueByRun[key] = evidence
        }
        return uniqueByRun.values.max {
            ($0.runID, $0.attempt) < ($1.runID, $1.attempt)
        }
    }

    private static func isValidCheckEvidence(_ evidence: LedgerGateCheckEvidence) -> Bool {
        guard evidence.runID > 0,
              evidence.attempt > 0,
              evidence.evidenceSHA256.map(IdentityValidation.isBareSHA256) ?? true
        else { return false }
        switch evidence.conclusion {
        case .pending:
            return evidence.completedAt == nil
        case .success, .failure, .skipped:
            return evidence.completedAt != nil
        }
    }

    private struct CheckRunKey: Hashable {
        let runID: Int64
        let attempt: Int
    }

    private static func isNextDetectedRelease(
        report: ReleaseDetectionReport,
        base: VerifiedReleaseLedger,
        entry: VerifiedReleaseEntry
    ) -> Bool {
        guard report.schemaVersion == 1,
              report.repository == base.repository,
              report.verifiedThroughTag == base.verifiedThroughTag,
              report.syntheticFixtureMatrixPassed,
              isStrictlyAscending(report.scannedStableTags),
              isStrictlyAscending(report.compatibleReleases.map(\.tag)),
              isStrictlyAscending(report.pendingReleases.map(\.tag)),
              report.compatibleReleases.first == entry
        else { return false }

        let scanned = Set(report.scannedStableTags)
        let recorded = Set(base.entries.map(\.tag))
        guard recorded.isSubset(of: scanned) else { return false }

        let unseenScanned = report.scannedStableTags.filter {
            guard let version = StableSemanticVersion(tag: $0) else { return false }
            return version > base.verifiedThroughVersion
        }
        let compatibleTags = report.compatibleReleases.map(\.tag)
        let pendingTags = report.pendingReleases.map(\.tag)
        guard unseenScanned.first == entry.tag,
              Set(compatibleTags).isDisjoint(with: Set(pendingTags)),
              Set(compatibleTags + pendingTags) == Set(unseenScanned)
        else { return false }

        return true
    }

    private static func isStrictlyAscending(_ tags: [String]) -> Bool {
        let versions = tags.compactMap(StableSemanticVersion.init(tag:))
        guard versions.count == tags.count else { return false }
        return zip(versions, versions.dropFirst()).allSatisfy(<)
    }

    private static func decodeStrictLedger(_ data: Data) throws -> VerifiedReleaseLedger {
        guard !data.isEmpty, data.count <= 1_000_000 else {
            throw LedgerMergeGateError.invalidLedger
        }
        do {
            try StrictJSONScanner.validate(data)
        } catch {
            throw LedgerMergeGateError.invalidLedger
        }
        guard
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LedgerMergeGateError.invalidLedger }

        try requireExactKeys(
            root,
            ["schemaVersion", "repository", "minimumTag", "verifiedThroughTag", "entries"]
        )
        guard let entries = root["entries"] as? [[String: Any]] else {
            throw LedgerMergeGateError.invalidLedger
        }
        for entry in entries {
            try requireExactKeys(
                entry,
                [
                    "releaseID", "tag", "publishedAt", "tagObjectSHA", "peeledCommitSHA",
                    "signature", "assets", "contractBlobs"
                ]
            )
            guard let signature = entry["signature"] as? [String: Any],
                  let assets = entry["assets"] as? [[String: Any]],
                  let contractBlobs = entry["contractBlobs"] as? [[String: Any]]
            else { throw LedgerMergeGateError.invalidLedger }
            try requireExactKeys(signature, ["verified", "reason"])
            for asset in assets {
                try requireExactKeys(asset, ["id", "name", "size", "digest"])
            }
            for blob in contractBlobs {
                try requireExactKeys(blob, ["path", "blobSHA", "sha256"])
            }
        }

        if containsUnsafeString(root) {
            throw LedgerMergeGateError.unsafeContent
        }
        do {
            return try VerifiedReleaseLedger.decode(data)
        } catch {
            throw LedgerMergeGateError.invalidLedger
        }
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        _ allowed: Set<String>
    ) throws {
        guard Set(object.keys) == allowed else {
            throw LedgerMergeGateError.invalidLedger
        }
    }

    private static func containsUnsafeString(_ value: Any) -> Bool {
        if let string = value as? String {
            let lower = string.lowercased()
            let unsafeFragments = [
                "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
                "glpat-", "npm_", "sk-proj-", "sk-svcacct-", "sk_live_",
                "sk_test_", "rk_live_", "whsec_", "xoxa-", "xoxb-", "xoxp-",
                "xoxr-", "sq0atp-", "sq0csp-", "-----begin private key-----",
                "-----begin openssh private key-----", "-----begin rsa private key-----",
                "-----begin dsa private key-----", "-----begin ec private key-----",
                "-----begin pgp private key block-----", "/users/", "/home/", "/.ssh/",
                "ssh-rsa ", "../", "..\\"
            ]
            if unsafeFragments.contains(where: lower.contains) {
                return true
            }
            let unsafePatterns = [
                #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
                #"\bAIza[0-9A-Za-z_-]{35}\b"#
            ]
            return unsafePatterns.contains {
                string.range(
                    of: $0,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsUnsafeString)
        }
        if let object = value as? [String: Any] {
            return object.values.contains(where: containsUnsafeString)
        }
        return false
    }
}

private struct StrictJSONScanner {
    private static let maximumDepth = 16

    private enum ParseError: Error {
        case invalidJSON
        case duplicateKey
    }

    private let bytes: [UInt8]
    private var index = 0

    private init(data: Data) {
        bytes = Array(data)
    }

    static func validate(_ data: Data) throws {
        var scanner = StrictJSONScanner(data: data)
        scanner.skipWhitespace()
        try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == scanner.bytes.count else {
            throw ParseError.invalidJSON
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw ParseError.invalidJSON }
        skipWhitespace()
        guard let byte = currentByte else { throw ParseError.invalidJSON }
        switch byte {
        case 0x7B:
            try parseObject(depth: depth)
        case 0x5B:
            try parseArray(depth: depth)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try parseLiteral("true")
        case 0x66:
            try parseLiteral("false")
        case 0x6E:
            try parseLiteral("null")
        default:
            try parseNumber()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) { return }

        var keys = Set<String>()
        while true {
            skipWhitespace()
            let key = try parseString()
            guard keys.insert(key).inserted else { throw ParseError.duplicateKey }
            skipWhitespace()
            try consume(0x3A)
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x7D) { return }
            try consume(0x2C)
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) { return }

        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x5D) { return }
            try consume(0x2C)
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(0x22)
        while let byte = currentByte {
            index += 1
            switch byte {
            case 0x22:
                let token = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                    throw ParseError.invalidJSON
                }
                return value
            case 0x5C:
                guard let escape = currentByte else { throw ParseError.invalidJSON }
                index += 1
                if escape == 0x75 {
                    for _ in 0..<4 {
                        guard let hex = currentByte, Self.isHex(hex) else {
                            throw ParseError.invalidJSON
                        }
                        index += 1
                    }
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                    throw ParseError.invalidJSON
                }
            case 0x00...0x1F:
                throw ParseError.invalidJSON
            default:
                continue
            }
        }
        throw ParseError.invalidJSON
    }

    private mutating func parseLiteral(_ literal: StaticString) throws {
        for byte in literal.withUTF8Buffer({ Array($0) }) {
            try consume(byte)
        }
    }

    private mutating func parseNumber() throws {
        _ = consumeIfPresent(0x2D)
        guard let first = currentByte else { throw ParseError.invalidJSON }
        if first == 0x30 {
            index += 1
            if let next = currentByte, Self.isDigit(next) {
                throw ParseError.invalidJSON
            }
        } else {
            guard (0x31...0x39).contains(first) else { throw ParseError.invalidJSON }
            index += 1
            consumeDigits()
        }

        if consumeIfPresent(0x2E) {
            guard currentByte.map(Self.isDigit) == true else {
                throw ParseError.invalidJSON
            }
            consumeDigits()
        }
        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D { index += 1 }
            guard currentByte.map(Self.isDigit) == true else {
                throw ParseError.invalidJSON
            }
            consumeDigits()
        }
    }

    private mutating func consumeDigits() {
        while let byte = currentByte, Self.isDigit(byte) { index += 1 }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else { throw ParseError.invalidJSON }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
