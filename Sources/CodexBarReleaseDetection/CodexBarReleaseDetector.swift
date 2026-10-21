import Foundation

public struct ReleaseDetectionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let repository: String
    public let verifiedThroughTag: String
    public let scannedStableTags: [String]
    public let compatibleReleases: [VerifiedReleaseEntry]
    public let pendingReleases: [PendingRelease]
    public let syntheticFixtureMatrixPassed: Bool

    public var isNoOp: Bool {
        compatibleReleases.isEmpty && pendingReleases.isEmpty
    }
}

public struct CodexBarReleaseDetector: Sendable {
    public typealias CatalogFetcher = @Sendable (StableSemanticVersion) async throws -> [CodexBarReleaseSummary]
    public typealias ProvenanceResolver = @Sendable (CodexBarReleaseSummary) async throws -> ReleaseProvenanceResolution

    private let fetchCatalog: CatalogFetcher
    private let resolveProvenance: ProvenanceResolver

    public init(catalog: CodexBarReleaseCatalog, resolver: CodexBarProvenanceResolver) {
        self.fetchCatalog = { minimum in
            try await catalog.fetchStableReleases(minimum: minimum)
        }
        self.resolveProvenance = { release in
            try await resolver.resolve(release)
        }
    }

    init(
        fetchCatalog: @escaping CatalogFetcher,
        resolveProvenance: @escaping ProvenanceResolver
    ) {
        self.fetchCatalog = fetchCatalog
        self.resolveProvenance = resolveProvenance
    }

    public func detect(ledger: VerifiedReleaseLedger) async throws -> ReleaseDetectionReport {
        try CodexBarSyntheticFixtures.verify()

        let catalog = try await fetchCatalog(ledger.minimumVersion).sorted { $0.version < $1.version }
        let recordedTags = Set(ledger.entries.map(\.tag))
        let relevant = catalog.filter {
            recordedTags.contains($0.tag) || $0.version > ledger.verifiedThroughVersion
        }

        var verified: [VerifiedReleaseEntry] = []
        var pending: [PendingRelease] = []
        for release in relevant {
            switch try await resolveProvenance(release) {
            case let .verified(entry):
                guard entry.releaseID == release.releaseID,
                      entry.tag == release.tag,
                      entry.publishedAt == release.publishedAt,
                      entry.assets == release.assets
                else {
                    throw ReleaseDetectionError.invalidProvenance
                }
                verified.append(entry)
            case let .pending(result):
                guard result.releaseID == release.releaseID, result.tag == release.tag else {
                    throw ReleaseDetectionError.invalidProvenance
                }
                if recordedTags.contains(result.tag) {
                    throw ReleaseDetectionError.identityMutation(result.tag)
                }
                pending.append(result)
            }
        }

        let unseen = try ReleaseLedgerReconciler().unseenVerifiedReleases(
            ledger: ledger,
            discovered: verified
        )
        return ReleaseDetectionReport(
            schemaVersion: 1,
            repository: ledger.repository,
            verifiedThroughTag: ledger.verifiedThroughTag,
            scannedStableTags: catalog.map(\.tag),
            compatibleReleases: unseen,
            pendingReleases: pending.sorted {
                StableSemanticVersion(tag: $0.tag)! < StableSemanticVersion(tag: $1.tag)!
            },
            syntheticFixtureMatrixPassed: true
        )
    }
}
