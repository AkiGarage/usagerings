import CryptoKit
import Foundation

public enum PendingReleaseReason: String, Codable, Equatable, Sendable {
    case lightweightTag
    case unverifiedTag
    case incompatibleContract
}

public struct PendingRelease: Codable, Equatable, Sendable {
    public let releaseID: Int64
    public let tag: String
    public let reason: PendingReleaseReason

    public init(releaseID: Int64, tag: String, reason: PendingReleaseReason) {
        self.releaseID = releaseID
        self.tag = tag
        self.reason = reason
    }
}

public enum ReleaseProvenanceResolution: Equatable, Sendable {
    case verified(VerifiedReleaseEntry)
    case pending(PendingRelease)
}

public struct CodexBarProvenanceResolver: Sendable {
    private static let apiRoot = "https://api.github.com/repos/steipete/CodexBar"

    private let client: GitHubAPIClient
    private let sourceChecker: CodexBarSourceContractChecker

    public init(
        client: GitHubAPIClient,
        sourceChecker: CodexBarSourceContractChecker = .init()
    ) {
        self.client = client
        self.sourceChecker = sourceChecker
    }

    public func resolve(_ release: CodexBarReleaseSummary) async throws -> ReleaseProvenanceResolution {
        let refURL = URL(string: "\(Self.apiRoot)/git/ref/tags/\(release.tag)")!
        let refResponse = try await client.get(refURL)
        guard refResponse.body.count <= 262_144,
              let ref = try? JSONDecoder().decode(GitReference.self, from: refResponse.body),
              ref.ref == "refs/tags/\(release.tag)",
              ref.url == "\(Self.apiRoot)/git/refs/tags/\(release.tag)",
              VerifiedReleaseLedger.isGitSHA(ref.object.sha)
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        if ref.object.type == "commit" {
            guard ref.object.url == "\(Self.apiRoot)/git/commits/\(ref.object.sha)" else {
                throw ReleaseDetectionError.invalidProvenance
            }
            return .pending(.init(
                releaseID: release.releaseID,
                tag: release.tag,
                reason: .lightweightTag
            ))
        }

        guard ref.object.type == "tag",
              ref.object.url == "\(Self.apiRoot)/git/tags/\(ref.object.sha)"
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        let tagResponse = try await client.get(URL(string: ref.object.url)!)
        guard tagResponse.body.count <= 524_288,
              let tag = try? JSONDecoder().decode(GitAnnotatedTag.self, from: tagResponse.body),
              tag.tag == release.tag,
              tag.sha == ref.object.sha,
              tag.url == ref.object.url,
              tag.object.type == "commit",
              VerifiedReleaseLedger.isGitSHA(tag.object.sha),
              tag.object.url == "\(Self.apiRoot)/git/commits/\(tag.object.sha)"
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        guard tag.verification.verified, tag.verification.reason == "valid" else {
            return .pending(.init(
                releaseID: release.releaseID,
                tag: release.tag,
                reason: .unverifiedTag
            ))
        }

        let pinned = try await fetchPinnedContract(commitSHA: tag.object.sha)
        do {
            try sourceChecker.validate(pinned.sources)
        } catch let error as ReleaseDetectionError where error == .incompatibleContract {
            return .pending(.init(
                releaseID: release.releaseID,
                tag: release.tag,
                reason: .incompatibleContract
            ))
        }

        return .verified(
            VerifiedReleaseEntry(
                releaseID: release.releaseID,
                tag: release.tag,
                publishedAt: release.publishedAt,
                tagObjectSHA: tag.sha,
                peeledCommitSHA: tag.object.sha,
                signature: .init(verified: true, reason: "valid"),
                assets: release.assets.sorted { $0.name < $1.name },
                contractBlobs: pinned.identities.sorted { $0.path < $1.path }
            )
        )
    }

    private func fetchPinnedContract(
        commitSHA: String
    ) async throws -> (sources: [String: Data], identities: [ContractBlobIdentity]) {
        guard VerifiedReleaseLedger.isGitSHA(commitSHA) else {
            throw ReleaseDetectionError.invalidProvenance
        }

        let expectedBlobs = try await fetchExpectedContractBlobs(commitSHA: commitSHA)

        var sources: [String: Data] = [:]
        var identities: [ContractBlobIdentity] = []

        for path in CodexBarContractPaths.all {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "raw.githubusercontent.com"
            components.path = "/steipete/CodexBar/\(commitSHA)/\(path)"
            guard let url = components.url else {
                throw ReleaseDetectionError.invalidProvenance
            }

            let response = try await client.get(url)
            let data = response.body
            guard !data.isEmpty, data.count <= 2_097_152 else {
                throw ReleaseDetectionError.invalidProvenance
            }

            var gitBlob = Data("blob \(data.count)\0".utf8)
            gitBlob.append(data)
            let blobSHA = Insecure.SHA1.hash(data: gitBlob)
                .map { String(format: "%02x", $0) }
                .joined()
            guard let expected = expectedBlobs[path],
                  let expectedSize = expected.size,
                  expected.sha == blobSHA,
                  expectedSize == data.count
            else {
                throw ReleaseDetectionError.invalidProvenance
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            sources[path] = data
            identities.append(.init(path: path, blobSHA: blobSHA, sha256: digest))
        }

        return (sources, identities)
    }

    private func fetchExpectedContractBlobs(
        commitSHA: String
    ) async throws -> [String: GitTreeEntry] {
        let commitURL = URL(string: "\(Self.apiRoot)/git/commits/\(commitSHA)")!
        let commitResponse = try await client.get(commitURL)
        guard commitResponse.body.count <= 1_048_576,
              let commit = try? JSONDecoder().decode(GitCommit.self, from: commitResponse.body),
              commit.sha == commitSHA,
              commit.url == commitURL.absoluteString,
              VerifiedReleaseLedger.isGitSHA(commit.tree.sha),
              commit.tree.url == "\(Self.apiRoot)/git/trees/\(commit.tree.sha)",
              var treeComponents = URLComponents(string: commit.tree.url)
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        treeComponents.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let treeURL = treeComponents.url else {
            throw ReleaseDetectionError.invalidProvenance
        }
        let treeResponse = try await client.get(treeURL)
        guard treeResponse.body.count <= 10_485_760,
              let tree = try? JSONDecoder().decode(GitTree.self, from: treeResponse.body),
              tree.sha == commit.tree.sha,
              tree.url == commit.tree.url,
              !tree.truncated
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        let requiredPaths = Set(CodexBarContractPaths.all)
        var expected: [String: GitTreeEntry] = [:]
        for entry in tree.tree where requiredPaths.contains(entry.path) {
            guard expected[entry.path] == nil,
                  entry.type == "blob",
                  entry.mode == "100644" || entry.mode == "100755",
                  let size = entry.size,
                  size > 0,
                  size <= 2_097_152,
                  VerifiedReleaseLedger.isGitSHA(entry.sha),
                  entry.url == "\(Self.apiRoot)/git/blobs/\(entry.sha)"
            else {
                throw ReleaseDetectionError.invalidProvenance
            }
            expected[entry.path] = entry
        }
        guard Set(expected.keys) == requiredPaths else {
            throw ReleaseDetectionError.invalidProvenance
        }
        return expected
    }
}

private struct GitObject: Decodable {
    let type: String
    let sha: String
    let url: String
}

private struct GitReference: Decodable {
    let ref: String
    let url: String
    let object: GitObject
}

private struct GitAnnotatedTag: Decodable {
    let tag: String
    let sha: String
    let url: String
    let object: GitObject
    let verification: GitHubSignatureEvidence
}

private struct GitCommit: Decodable {
    let sha: String
    let url: String
    let tree: GitTreeReference
}

private struct GitTreeReference: Decodable {
    let sha: String
    let url: String
}

private struct GitTree: Decodable {
    let sha: String
    let url: String
    let truncated: Bool
    let tree: [GitTreeEntry]
}

private struct GitTreeEntry: Decodable {
    let path: String
    let mode: String
    let type: String
    let sha: String
    let size: Int?
    let url: String
}
