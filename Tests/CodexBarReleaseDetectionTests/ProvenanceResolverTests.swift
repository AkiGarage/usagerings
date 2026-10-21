import CryptoKit
import XCTest
@testable import CodexBarReleaseDetection

final class ProvenanceResolverTests: XCTestCase {
    func testResolvesVerifiedAnnotatedTagAndHashesPinnedContractBlobs() async throws {
        let transport = ProvenanceTransport(mode: .verified)
        let resolver = CodexBarProvenanceResolver(client: makeClient(transport))

        let resolution = try await resolver.resolve(Self.release)
        guard case let .verified(entry) = resolution else {
            return XCTFail("Expected verified provenance")
        }

        XCTAssertEqual(
            entry.canonicalIdentity,
            "steipete/CodexBar:43:v0.43.0:\(String(repeating: "2", count: 40))"
        )
        XCTAssertEqual(entry.contractBlobs.map(\.path), CodexBarContractPaths.all)
        let docs = try XCTUnwrap(entry.contractBlobs.first { $0.path == "docs/cli.md" })
        let expectedHash = SHA256.hash(data: Self.sources["docs/cli.md"]!)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(docs.sha256, expectedHash)
        var gitBlob = Data("blob \(Self.sources["docs/cli.md"]!.count)\0".utf8)
        gitBlob.append(Self.sources["docs/cli.md"]!)
        let expectedBlobSHA = Insecure.SHA1.hash(data: gitBlob)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(docs.blobSHA, expectedBlobSHA)

        let requests = await transport.requests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(requests.filter { $0.url?.host == "api.github.com" }.count, 4)
        XCTAssertEqual(requests.filter { $0.url?.host == "raw.githubusercontent.com" }.count, 6)
    }

    func testRawContractBlobMustMatchSignedCommitTree() async {
        let transport = ProvenanceTransport(mode: .rawBlobMismatch)

        do {
            _ = try await CodexBarProvenanceResolver(client: makeClient(transport))
                .resolve(Self.release)
            XCTFail("Expected a raw blob mismatch to fail closed")
        } catch {
            XCTAssertEqual(error as? ReleaseDetectionError, .invalidProvenance)
        }
    }

    func testLightweightAndUnverifiedTagsRemainPending() async throws {
        for (mode, reason) in [
            (ProvenanceTransport.Mode.lightweight, PendingReleaseReason.lightweightTag),
            (.unverified, .unverifiedTag)
        ] {
            let transport = ProvenanceTransport(mode: mode)
            let resolution = try await CodexBarProvenanceResolver(
                client: makeClient(transport)
            ).resolve(Self.release)
            XCTAssertEqual(
                resolution,
                .pending(.init(releaseID: 43, tag: "v0.43.0", reason: reason))
            )
        }
    }

    func testMalformedTagProvenanceFailsClosed() async {
        let transport = ProvenanceTransport(mode: .malformed)
        do {
            _ = try await CodexBarProvenanceResolver(client: makeClient(transport)).resolve(Self.release)
            XCTFail("Expected malformed provenance to fail")
        } catch {
            XCTAssertEqual(error as? ReleaseDetectionError, .invalidProvenance)
        }
    }

    private func makeClient(_ transport: ProvenanceTransport) -> GitHubAPIClient {
        GitHubAPIClient(
            transport: { request in try await transport.response(for: request) },
            sleeper: { _ in }
        )
    }

    private static let release = CodexBarReleaseSummary(
        releaseID: 43,
        version: StableSemanticVersion(tag: "v0.43.0")!,
        publishedAt: "2026-07-17T00:00:00Z",
        assets: [
            .init(
                id: 430,
                name: "CodexBarCLI-v0.43.0-macos-arm64.tar.gz",
                size: 100,
                digest: "sha256:" + String(repeating: "a", count: 64)
            )
        ]
    )

    fileprivate static let sources = SourceContractCheckerTests.validSources
}

private actor ProvenanceTransport {
    enum Mode {
        case verified
        case lightweight
        case unverified
        case malformed
        case rawBlobMismatch
    }

    private let mode: Mode
    private var captured: [URLRequest] = []
    private let tagSHA = String(repeating: "1", count: 40)
    private let commitSHA = String(repeating: "2", count: 40)
    private let treeSHA = String(repeating: "3", count: 40)

    init(mode: Mode) {
        self.mode = mode
    }

    func response(for request: URLRequest) throws -> GitHubHTTPResponse {
        captured.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        let root = "https://api.github.com/repos/steipete/CodexBar"

        if url.path.hasSuffix("/git/ref/tags/v0.43.0") {
            let type = mode == .lightweight ? "commit" : "tag"
            let sha = type == "commit" ? commitSHA : tagSHA
            let objectURL = mode == .malformed
                ? "https://example.invalid/object"
                : "\(root)/git/\(type == "tag" ? "tags" : "commits")/\(sha)"
            return json([
                "ref": "refs/tags/v0.43.0",
                "url": "\(root)/git/refs/tags/v0.43.0",
                "object": ["type": type, "sha": sha, "url": objectURL]
            ])
        }

        if url.path.hasSuffix("/git/tags/\(tagSHA)") {
            let isVerified = mode == .verified || mode == .rawBlobMismatch
            return json([
                "tag": "v0.43.0",
                "sha": tagSHA,
                "url": "\(root)/git/tags/\(tagSHA)",
                "object": [
                    "type": "commit",
                    "sha": commitSHA,
                    "url": "\(root)/git/commits/\(commitSHA)"
                ],
                "verification": [
                    "verified": isVerified,
                    "reason": isVerified ? "valid" : "unsigned"
                ]
            ])
        }

        if url.path.hasSuffix("/git/commits/\(commitSHA)") {
            return json([
                "sha": commitSHA,
                "url": "\(root)/git/commits/\(commitSHA)",
                "tree": [
                    "sha": treeSHA,
                    "url": "\(root)/git/trees/\(treeSHA)"
                ]
            ])
        }

        if url.path.hasSuffix("/git/trees/\(treeSHA)"), url.query == "recursive=1" {
            var entries: [[String: Any]] = CodexBarContractPaths.all.map { path in
                let data = ProvenanceResolverTests.sources[path]!
                let sha = Self.gitBlobSHA(data)
                return [
                    "path": path,
                    "mode": "100644",
                    "type": "blob",
                    "sha": sha,
                    "size": data.count,
                    "url": "\(root)/git/blobs/\(sha)"
                ]
            }
            entries.append([
                "path": "Sources",
                "mode": "040000",
                "type": "tree",
                "sha": treeSHA,
                "url": "\(root)/git/trees/\(treeSHA)"
            ])
            return json([
                "sha": treeSHA,
                "url": "\(root)/git/trees/\(treeSHA)",
                "truncated": false,
                "tree": entries
            ])
        }

        let rawPrefix = "/steipete/CodexBar/\(commitSHA)/"
        if url.host == "raw.githubusercontent.com", url.path.hasPrefix(rawPrefix) {
            let path = String(url.path.dropFirst(rawPrefix.count)).removingPercentEncoding!
            guard let data = ProvenanceResolverTests.sources[path] else {
                throw URLError(.fileDoesNotExist)
            }
            if mode == .rawBlobMismatch, path == CodexBarContractPaths.all[0] {
                return GitHubHTTPResponse(statusCode: 200, body: data + Data("tampered".utf8))
            }
            return GitHubHTTPResponse(statusCode: 200, body: data)
        }

        throw URLError(.badServerResponse)
    }

    func requests() -> [URLRequest] { captured }

    private func json(_ object: Any) -> GitHubHTTPResponse {
        GitHubHTTPResponse(
            statusCode: 200,
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private static func gitBlobSHA(_ data: Data) -> String {
        var gitBlob = Data("blob \(data.count)\0".utf8)
        gitBlob.append(data)
        return Insecure.SHA1.hash(data: gitBlob)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
