import Foundation

public struct ReleaseAssetSummary: Codable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let size: Int64
    public let digest: String

    public init(id: Int64, name: String, size: Int64, digest: String) {
        self.id = id
        self.name = name
        self.size = size
        self.digest = digest
    }
}

public struct CodexBarReleaseSummary: Codable, Equatable, Sendable {
    public let releaseID: Int64
    public let version: StableSemanticVersion
    public let publishedAt: String
    public let assets: [ReleaseAssetSummary]

    public var tag: String { version.tag }

    public init(
        releaseID: Int64,
        version: StableSemanticVersion,
        publishedAt: String,
        assets: [ReleaseAssetSummary]
    ) {
        self.releaseID = releaseID
        self.version = version
        self.publishedAt = publishedAt
        self.assets = assets
    }
}

public struct CodexBarReleaseCatalog: Sendable {
    private static let firstPage = URL(
        string: "https://api.github.com/repos/steipete/CodexBar/releases?per_page=100"
    )!
    private static let apiReleasePrefix =
        "https://api.github.com/repos/steipete/CodexBar/releases/"
    private static let apiRepositoryIDReleasePath = "/repositories/1097695258/releases"
    private static let webReleasePrefix =
        "https://github.com/steipete/CodexBar/releases/tag/"

    private let client: GitHubAPIClient

    public init(client: GitHubAPIClient) {
        self.client = client
    }

    public func fetchStableReleases(
        minimum: StableSemanticVersion
    ) async throws -> [CodexBarReleaseSummary] {
        var nextURL: URL? = Self.firstPage
        var visited = Set<URL>()
        var releasesByTag: [String: CodexBarReleaseSummary] = [:]
        var tagsByID: [Int64: String] = [:]

        while let pageURL = nextURL {
            guard visited.insert(pageURL).inserted, visited.count <= 100 else {
                throw ReleaseDetectionError.paginationLoop
            }

            let response = try await client.get(pageURL)
            let page: [GitHubRelease]
            do {
                page = try JSONDecoder().decode([GitHubRelease].self, from: response.body)
            } catch {
                throw ReleaseDetectionError.malformedResponse
            }

            for raw in page {
                guard !raw.draft,
                      !raw.prerelease,
                      raw.publishedAt != nil,
                      let version = StableSemanticVersion(tag: raw.tagName),
                      version >= minimum
                else { continue }

                let summary = try Self.validate(raw, version: version)
                if let existingTag = tagsByID[summary.releaseID], existingTag != summary.tag {
                    throw ReleaseDetectionError.ambiguousRelease(summary.tag)
                }
                if let existing = releasesByTag[summary.tag], existing != summary {
                    throw ReleaseDetectionError.ambiguousRelease(summary.tag)
                }
                tagsByID[summary.releaseID] = summary.tag
                releasesByTag[summary.tag] = summary
            }

            nextURL = try Self.nextPageURL(from: response.header(named: "Link"))
        }

        return releasesByTag.values.sorted { $0.version < $1.version }
    }

    private static func validate(
        _ release: GitHubRelease,
        version: StableSemanticVersion
    ) throws -> CodexBarReleaseSummary {
        guard release.id > 0,
              release.url == apiReleasePrefix + String(release.id),
              release.htmlURL == webReleasePrefix + version.tag,
              let publishedAt = release.publishedAt,
              ISO8601DateFormatter().date(from: publishedAt) != nil,
              !release.assets.isEmpty
        else {
            throw ReleaseDetectionError.invalidProvenance
        }

        var assetIDs = Set<Int64>()
        var assetNames = Set<String>()
        let assets = try release.assets.map { asset -> ReleaseAssetSummary in
            guard asset.id > 0,
                  asset.size > 0,
                  IdentityValidation.isSafeAssetName(asset.name),
                  IdentityValidation.isSHA256Digest(asset.digest),
                  assetIDs.insert(asset.id).inserted,
                  assetNames.insert(asset.name).inserted
            else {
                throw ReleaseDetectionError.invalidProvenance
            }
            return ReleaseAssetSummary(
                id: asset.id,
                name: asset.name,
                size: asset.size,
                digest: asset.digest
            )
        }

        return CodexBarReleaseSummary(
            releaseID: release.id,
            version: version,
            publishedAt: publishedAt,
            assets: assets.sorted { $0.name < $1.name }
        )
    }

    private static func nextPageURL(from linkHeader: String?) throws -> URL? {
        guard let linkHeader else { return nil }
        for component in linkHeader.split(separator: ",") {
            let sections = component.split(separator: ";", omittingEmptySubsequences: true)
            guard sections.count >= 2,
                  sections.dropFirst().contains(where: {
                      $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
                  })
            else { continue }

            let rawURL = sections[0].trimmingCharacters(in: .whitespaces)
            guard rawURL.first == "<", rawURL.last == ">",
                  let url = URL(string: String(rawURL.dropFirst().dropLast())),
                  isAllowedPageURL(url)
            else {
                throw ReleaseDetectionError.invalidProvenance
            }
            return url
        }
        return nil
    }

    private static func isAllowedPageURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "api.github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              (url.path == "/repos/steipete/CodexBar/releases" ||
                  url.path == Self.apiRepositoryIDReleasePath),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }

        let items = components.queryItems ?? []
        guard !items.isEmpty,
              items.allSatisfy({ $0.name == "page" || $0.name == "per_page" }),
              items.first(where: { $0.name == "per_page" })?.value == "100"
        else { return false }
        if let page = items.first(where: { $0.name == "page" })?.value {
            return Int(page).map { $0 > 0 } == true
        }
        return true
    }
}

private struct GitHubRelease: Decodable {
    let id: Int64
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let url: String
    let htmlURL: String
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case url
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let id: Int64
    let name: String
    let size: Int64
    let digest: String
}
