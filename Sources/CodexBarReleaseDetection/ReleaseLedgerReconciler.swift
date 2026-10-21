import Foundation

public struct ReleaseLedgerReconciler: Sendable {
    public init() {}

    public func unseenVerifiedReleases(
        ledger: VerifiedReleaseLedger,
        discovered: [VerifiedReleaseEntry]
    ) throws -> [VerifiedReleaseEntry] {
        var byTag: [String: VerifiedReleaseEntry] = [:]
        var tagByReleaseID: [Int64: String] = [:]

        for entry in discovered {
            guard StableSemanticVersion(tag: entry.tag) != nil else {
                throw ReleaseDetectionError.invalidProvenance
            }
            if let existing = byTag[entry.tag], existing != entry {
                throw ReleaseDetectionError.ambiguousRelease(entry.tag)
            }
            if let existingTag = tagByReleaseID[entry.releaseID], existingTag != entry.tag {
                throw ReleaseDetectionError.ambiguousRelease(entry.tag)
            }
            byTag[entry.tag] = entry
            tagByReleaseID[entry.releaseID] = entry.tag
        }

        for recorded in ledger.entries {
            guard let current = byTag[recorded.tag], current == recorded else {
                throw ReleaseDetectionError.identityMutation(recorded.tag)
            }
        }

        return byTag.values
            .filter {
                guard let version = StableSemanticVersion(tag: $0.tag) else { return false }
                return version > ledger.verifiedThroughVersion
            }
            .sorted {
                StableSemanticVersion(tag: $0.tag)! < StableSemanticVersion(tag: $1.tag)!
            }
    }
}
