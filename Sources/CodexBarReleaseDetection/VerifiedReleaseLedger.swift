import Foundation

public struct GitHubSignatureEvidence: Codable, Equatable, Sendable {
    public let verified: Bool
    public let reason: String

    public init(verified: Bool, reason: String) {
        self.verified = verified
        self.reason = reason
    }
}

public struct ContractBlobIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let blobSHA: String
    public let sha256: String

    public init(path: String, blobSHA: String, sha256: String) {
        self.path = path
        self.blobSHA = blobSHA
        self.sha256 = sha256
    }
}

public struct VerifiedReleaseEntry: Codable, Equatable, Sendable {
    public let releaseID: Int64
    public let tag: String
    public let publishedAt: String
    public let tagObjectSHA: String
    public let peeledCommitSHA: String
    public let signature: GitHubSignatureEvidence
    public let assets: [ReleaseAssetSummary]
    public let contractBlobs: [ContractBlobIdentity]

    public var canonicalIdentity: String {
        "steipete/CodexBar:\(releaseID):\(tag):\(peeledCommitSHA)"
    }

    public init(
        releaseID: Int64,
        tag: String,
        publishedAt: String,
        tagObjectSHA: String,
        peeledCommitSHA: String,
        signature: GitHubSignatureEvidence,
        assets: [ReleaseAssetSummary],
        contractBlobs: [ContractBlobIdentity]
    ) {
        self.releaseID = releaseID
        self.tag = tag
        self.publishedAt = publishedAt
        self.tagObjectSHA = tagObjectSHA
        self.peeledCommitSHA = peeledCommitSHA
        self.signature = signature
        self.assets = assets
        self.contractBlobs = contractBlobs
    }
}

public struct VerifiedReleaseLedger: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let repository: String
    public let minimumTag: String
    public let verifiedThroughTag: String
    public let entries: [VerifiedReleaseEntry]

    public init(
        schemaVersion: Int,
        repository: String,
        minimumTag: String,
        verifiedThroughTag: String,
        entries: [VerifiedReleaseEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.minimumTag = minimumTag
        self.verifiedThroughTag = verifiedThroughTag
        self.entries = entries
    }

    public static func decode(_ data: Data) throws -> VerifiedReleaseLedger {
        guard !data.isEmpty, data.count <= 1_048_576,
              let ledger = try? JSONDecoder().decode(VerifiedReleaseLedger.self, from: data)
        else {
            throw ReleaseDetectionError.invalidLedger
        }
        try ledger.validate()
        return ledger
    }

    public var minimumVersion: StableSemanticVersion {
        StableSemanticVersion(tag: minimumTag)!
    }

    public var verifiedThroughVersion: StableSemanticVersion {
        StableSemanticVersion(tag: verifiedThroughTag)!
    }

    private func validate() throws {
        guard schemaVersion == 1,
              repository == "steipete/CodexBar",
              let minimum = StableSemanticVersion(tag: minimumTag),
              let verifiedThrough = StableSemanticVersion(tag: verifiedThroughTag),
              minimum <= verifiedThrough,
              !entries.isEmpty
        else {
            throw ReleaseDetectionError.invalidLedger
        }

        var tags = Set<String>()
        var releaseIDs = Set<Int64>()
        var previousVersion: StableSemanticVersion?
        for entry in entries {
            guard let version = StableSemanticVersion(tag: entry.tag),
                  version >= minimum,
                  previousVersion.map({ $0 < version }) ?? true,
                  tags.insert(entry.tag).inserted,
                  releaseIDs.insert(entry.releaseID).inserted
            else {
                throw ReleaseDetectionError.invalidLedger
            }
            try Self.validate(entry)
            previousVersion = version
        }

        guard entries.last?.tag == verifiedThroughTag else {
            throw ReleaseDetectionError.invalidLedger
        }
    }

    private static func validate(_ entry: VerifiedReleaseEntry) throws {
        guard entry.releaseID > 0,
              ISO8601DateFormatter().date(from: entry.publishedAt) != nil,
              isGitSHA(entry.tagObjectSHA),
              isGitSHA(entry.peeledCommitSHA),
              entry.signature.verified,
              entry.signature.reason == "valid",
              !entry.assets.isEmpty,
              !entry.contractBlobs.isEmpty,
              entry.assets == entry.assets.sorted(by: { $0.name < $1.name }),
              entry.contractBlobs == entry.contractBlobs.sorted(by: { $0.path < $1.path })
        else {
            throw ReleaseDetectionError.invalidLedger
        }

        var assetIDs = Set<Int64>()
        var assetNames = Set<String>()
        for asset in entry.assets {
            guard asset.id > 0,
                  asset.size > 0,
                  IdentityValidation.isSafeAssetName(asset.name),
                  IdentityValidation.isSHA256Digest(asset.digest),
                  assetIDs.insert(asset.id).inserted,
                  assetNames.insert(asset.name).inserted
            else {
                throw ReleaseDetectionError.invalidLedger
            }
        }

        var paths = Set<String>()
        for blob in entry.contractBlobs {
            guard CodexBarContractPaths.all.contains(blob.path),
                  isGitSHA(blob.blobSHA),
                  IdentityValidation.isBareSHA256(blob.sha256),
                  paths.insert(blob.path).inserted
            else {
                throw ReleaseDetectionError.invalidLedger
            }
        }

        guard paths == Set(CodexBarContractPaths.all) else {
            throw ReleaseDetectionError.invalidLedger
        }
    }

    static func isGitSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }
}

enum IdentityValidation {
    static func isSafeAssetName(_ name: String) -> Bool {
        !name.isEmpty &&
            name.utf8.count <= 255 &&
            !name.contains("/") &&
            !name.contains("\\") &&
            name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isSHA256Digest(_ digest: String) -> Bool {
        digest.hasPrefix("sha256:") && isBareSHA256(String(digest.dropFirst("sha256:".count)))
    }

    static func isBareSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }
}
