import Foundation

public struct GitHubHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GitHubAPIClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> GitHubHTTPResponse
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let transport: Transport
    private let sleeper: Sleeper
    private let maximumAttempts: Int

    public init(
        maximumAttempts: Int = 3,
        transport: @escaping Transport,
        sleeper: @escaping Sleeper
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.transport = transport
        self.sleeper = sleeper
    }

    func get(_ url: URL) async throws -> GitHubHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("codex-usage-widget-release-detector/1", forHTTPHeaderField: "User-Agent")

        for attempt in 1...maximumAttempts {
            do {
                let response = try await transport(request)
                switch response.statusCode {
                case 200:
                    return response
                case 403, 429:
                    guard attempt < maximumAttempts else {
                        throw ReleaseDetectionError.rateLimited
                    }
                    try await sleeper(Self.retryDelayNanoseconds(attempt: attempt, response: response))
                case 500...599:
                    guard attempt < maximumAttempts else {
                        throw ReleaseDetectionError.networkUnavailable
                    }
                    try await sleeper(Self.retryDelayNanoseconds(attempt: attempt, response: response))
                case 404:
                    throw ReleaseDetectionError.notFound
                default:
                    throw ReleaseDetectionError.unexpectedHTTPStatus(response.statusCode)
                }
            } catch let error as ReleaseDetectionError {
                throw error
            } catch {
                guard attempt < maximumAttempts else {
                    throw ReleaseDetectionError.networkUnavailable
                }
                try await sleeper(Self.retryDelayNanoseconds(attempt: attempt, response: nil))
            }
        }

        throw ReleaseDetectionError.networkUnavailable
    }

    private static func retryDelayNanoseconds(
        attempt: Int,
        response: GitHubHTTPResponse?
    ) -> UInt64 {
        if let retryAfter = response?.header(named: "Retry-After"),
           let seconds = UInt64(retryAfter)
        {
            return min(seconds, 60) * 1_000_000_000
        }
        let seconds = min(UInt64(1 << max(0, attempt - 1)), 8)
        return seconds * 1_000_000_000
    }
}
