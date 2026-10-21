import Foundation
import XCTest
@testable import CodexBarReleaseDetection

final class ReleaseCatalogTests: XCTestCase {
    func testFetchesEveryPageFiltersStableReleasesAndSortsAscending() async throws {
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [
                    .success(
                        response(
                            body: releasesJSON([
                                releaseJSON(id: 440, tag: "v0.44.0"),
                                releaseJSON(id: 441, tag: "v0.44.1-rc.1", prerelease: true),
                                releaseJSON(id: 442, tag: "v0.44.2", draft: true)
                            ]),
                            headers: ["Link": "<\(Self.secondPageURL)>; rel=\"next\""]
                        )
                    )
                ],
                Self.secondPageURL: [
                    .success(
                        response(
                            body: releasesJSON([
                                releaseJSON(id: 430, tag: "v0.43.0"),
                                releaseJSON(id: 431, tag: "v0.43"),
                                releaseJSON(id: 319, tag: "v0.31.9")
                            ])
                        )
                    )
                ]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        let releases = try await CodexBarReleaseCatalog(client: client)
            .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)

        XCTAssertEqual(releases.map(\.tag), ["v0.43.0", "v0.44.0"])
        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(requestedURLs, [Self.firstPageURL, Self.secondPageURL])
        let requests = await transport.requests()
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testAcceptsGitHubsRepositoryIDPaginationURL() async throws {
        let repositoryIDPageURL =
            "https://api.github.com/repositories/1097695258/releases?per_page=100&page=2"
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [
                    .success(
                        response(
                            body: releasesJSON([releaseJSON(id: 440, tag: "v0.44.0")]),
                            headers: ["Link": "<\(repositoryIDPageURL)>; rel=\"next\""]
                        )
                    )
                ],
                repositoryIDPageURL: [
                    .success(response(body: releasesJSON([releaseJSON(id: 430, tag: "v0.43.0")])))
                ]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        let releases = try await CodexBarReleaseCatalog(client: client)
            .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)

        XCTAssertEqual(releases.map(\.tag), ["v0.43.0", "v0.44.0"])
        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(requestedURLs, [Self.firstPageURL, repositoryIDPageURL])
    }

    func testRejectsUnexpectedRepositoryIDPaginationURL() async {
        let unexpectedRepositoryPageURL =
            "https://api.github.com/repositories/1097695259/releases?per_page=100&page=2"
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [
                    .success(
                        response(
                            body: releasesJSON([releaseJSON(id: 440, tag: "v0.44.0")]),
                            headers: ["Link": "<\(unexpectedRepositoryPageURL)>; rel=\"next\""]
                        )
                    )
                ]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        do {
            _ = try await CodexBarReleaseCatalog(client: client)
                .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)
            XCTFail("Expected an unexpected repository ID to fail closed")
        } catch let error as ReleaseDetectionError {
            XCTAssertEqual(error, .invalidProvenance)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }

        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(requestedURLs, [Self.firstPageURL])
    }

    func testRejectsPaginationURLWithNonstandardPort() async {
        let nonstandardPortURL =
            "https://api.github.com:8443/repositories/1097695258/releases?per_page=100&page=2"
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [
                    .success(
                        response(
                            body: releasesJSON([releaseJSON(id: 440, tag: "v0.44.0")]),
                            headers: ["Link": "<\(nonstandardPortURL)>; rel=\"next\""]
                        )
                    )
                ],
                nonstandardPortURL: [
                    .success(response(body: releasesJSON([releaseJSON(id: 430, tag: "v0.43.0")])))
                ]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        do {
            _ = try await CodexBarReleaseCatalog(client: client)
                .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)
            XCTFail("Expected a nonstandard pagination port to fail closed")
        } catch let error as ReleaseDetectionError {
            XCTAssertEqual(error, .invalidProvenance)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }

        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(requestedURLs, [Self.firstPageURL])
    }

    func testRetriesTransientNetworkFailureThenReturnsSanitizedError() async {
        let sensitiveMarker = "synthetic-private-network-marker"
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [
                    .failure(MarkerError(message: sensitiveMarker)),
                    .failure(MarkerError(message: sensitiveMarker)),
                    .failure(MarkerError(message: sensitiveMarker))
                ]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        do {
            _ = try await CodexBarReleaseCatalog(client: client)
                .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)
            XCTFail("Expected a sanitized network failure")
        } catch let error as ReleaseDetectionError {
            XCTAssertEqual(error, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains(sensitiveMarker))
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 3)
    }

    func testIgnoresUntrustedBodyAndAuthorData() async throws {
        let sensitiveMarker = "synthetic-release-body-marker"
        var item = releaseJSON(id: 430, tag: "v0.43.0")
        item["body"] = sensitiveMarker
        item["author"] = ["login": "synthetic-author-marker"]
        let transport = StubTransport(
            responses: [
                Self.firstPageURL: [.success(response(body: releasesJSON([item])))]
            ]
        )
        let client = GitHubAPIClient(
            transport: { request in try await transport.send(request) },
            sleeper: { _ in }
        )

        let releases = try await CodexBarReleaseCatalog(client: client)
            .fetchStableReleases(minimum: StableSemanticVersion(tag: "v0.32.4")!)
        let encoded = try JSONEncoder().encode(releases)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains(sensitiveMarker))
        XCTAssertFalse(text.contains("synthetic-author-marker"))
    }

    private static let firstPageURL =
        "https://api.github.com/repos/steipete/CodexBar/releases?per_page=100"
    private static let secondPageURL =
        "https://api.github.com/repos/steipete/CodexBar/releases?per_page=100&page=2"
}

private actor StubTransport {
    private var queued: [String: [Result<GitHubHTTPResponse, Error>]]
    private var captured: [URLRequest] = []

    init(responses: [String: [Result<GitHubHTTPResponse, Error>]]) {
        queued = responses
    }

    func send(_ request: URLRequest) throws -> GitHubHTTPResponse {
        captured.append(request)
        let key = try XCTUnwrap(request.url?.absoluteString)
        guard var values = queued[key], !values.isEmpty else {
            throw MarkerError(message: "unstubbed request")
        }
        let next = values.removeFirst()
        queued[key] = values
        return try next.get()
    }

    func requestedURLs() -> [String] {
        captured.compactMap { $0.url?.absoluteString }
    }

    func requests() -> [URLRequest] {
        captured
    }

    func requestCount() -> Int {
        captured.count
    }
}

private struct MarkerError: Error {
    let message: String
}

private func response(body: Data, headers: [String: String] = [:]) -> GitHubHTTPResponse {
    GitHubHTTPResponse(statusCode: 200, headers: headers, body: body)
}

private func releasesJSON(_ releases: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: releases, options: [.sortedKeys])
}

private func releaseJSON(
    id: Int,
    tag: String,
    draft: Bool = false,
    prerelease: Bool = false
) -> [String: Any] {
    [
        "id": id,
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "published_at": "2026-07-17T00:00:00Z",
        "url": "https://api.github.com/repos/steipete/CodexBar/releases/\(id)",
        "html_url": "https://github.com/steipete/CodexBar/releases/tag/\(tag)",
        "assets": [[
            "id": id * 10,
            "name": "CodexBarCLI-\(tag)-macos-arm64.tar.gz",
            "size": 1234,
            "digest": "sha256:" + String(repeating: "a", count: 64)
        ]]
    ]
}
