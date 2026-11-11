import Foundation

/// OpenDesign Go Design Plan windows (5-hour and 7-day pools) read from the
/// official OpenDesign control API with the control key the official app's AMR
/// login already stores in `~/.amr/config.json`.
///
/// No browser cookie, web session or Keychain item is used. The key never
/// leaves `OpenDesignUsageClient.fetch()`: it is not stored in the model, not
/// written to disk and never placed in a failure message.
enum OpenDesignUsage: Equatable, Sendable {
    enum WindowKind: Hashable, Sendable {
        case fiveHour
        case weekly

        /// Titles the existing row/ring code already understands.
        var title: String {
            switch self {
            case .fiveHour: "5h"
            case .weekly: "Weekly"
            }
        }

        var durationSeconds: Int {
            switch self {
            case .fiveHour: 18_000
            case .weekly: 604_800
            }
        }
    }

    struct Window: Equatable, Sendable {
        let kind: WindowKind
        /// Share of the pool still available (0–100).
        let leftPercent: Double
        /// nil when the API sent `resetsAt: null` (reset time unknown).
        let resetsAt: Date?
    }

    /// Only the ids the API needs to scope the next request; names and
    /// account details are not retained.
    struct Workspace: Equatable, Sendable {
        let id: String
        let memberID: String
    }

    case loaded(workspace: Workspace, windows: [Window])
    /// No readable `~/.amr/config.json` profile or a login still pending.
    case notLoggedIn
    /// The API rejected the control key.
    case unauthorized
    /// Any other non-200 response, including Cloudflare's 403.
    case httpFailure(Int)
    case transportFailure
    /// The response did not match the contract (never treated as full quota).
    case malformed
    /// The plan is not eligible or reports no windows.
    case noPlan
    case noPersonalWorkspace
}

/// Strict, fail-closed readers for the two responses. Unknown extra fields are
/// ignored by `Decodable`, but every field the quota is derived from is required
/// to have the documented type and range.
enum OpenDesignUsageParser {
    enum Failure: Error, Equatable {
        case malformed
        case noPlan
        case noPersonalWorkspace
    }

    private static let decimal = Locale(identifier: "en_US_POSIX")
    private static let creditPattern = #"^(0|[1-9]\d*)$"#
    private static let balancePattern = #"^-?\d+(\.\d+)?$"#
    private static let tiers: Set<String> = ["go", "plus", "pro", "max"]
    private static let fundingSources: Set<String> = ["coding_plan", "wallet", "gateway"]
    private static let fundingChecks: Set<String> = ["available", "insufficient", "unknown"]
    private static let resetModes: Set<String> = ["activity_triggered", "anchored_recurring"]

    // MARK: Workspace directory

    private struct Directory: Decodable {
        let items: [DirectoryItem]?
    }

    private struct DirectoryItem: Decodable {
        let workspaceId: String?
        let workspaceMemberId: String?
        let workspaceType: String?
        let memberStatus: String?
        let lifecycleState: String?
        let isDefault: Bool?
    }

    /// The personal, active workspace the control key's owner can read quota
    /// for. `isDefault` breaks ties; otherwise the directory order wins.
    static func personalWorkspace(_ data: Data) throws -> OpenDesignUsage.Workspace {
        let directory: Directory
        do { directory = try JSONDecoder().decode(Directory.self, from: data) }
        catch { throw Failure.malformed }
        guard let items = directory.items else { throw Failure.malformed }
        let candidates = items.compactMap { item -> (OpenDesignUsage.Workspace, Bool)? in
            guard item.workspaceType == "personal",
                  item.memberStatus == "active",
                  item.lifecycleState == "active",
                  let id = item.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let member = item.workspaceMemberId?.trimmingCharacters(in: .whitespacesAndNewlines), !member.isEmpty
            else { return nil }
            return (OpenDesignUsage.Workspace(id: id, memberID: member), item.isDefault == true)
        }
        guard !candidates.isEmpty else { throw Failure.noPersonalWorkspace }
        return (candidates.first { $0.1 } ?? candidates[0]).0
    }

    // MARK: Funding check

    private struct FundingEnvelope: Decodable {
        let schemaVersion: Int?
        let workspaceId: String?
        let workspaceMemberId: String?
        let generatedAt: String?
        let balanceUsd: String?
        let modelCovered: Bool?
        let funding: String?
        let fundingCheck: String?
        let codingPlan: CodingPlan?
    }

    private struct CodingPlan: Decodable {
        let workspaceId: String?
        let generatedAt: String?
        let eligible: Bool?
        let tier: String?
        let windows: [FundingWindow]?
    }

    private struct FundingWindow: Decodable {
        let policyId: String?
        let durationSeconds: Int?
        let resetMode: String?
        let usedCredits: String?
        let limitCredits: String?
        let remainingCredits: String?
        let windowStart: String?
        let resetsAt: String?
    }

    /// Validated windows, shortest period first. Throws `.noPlan` when the plan
    /// is not eligible or reports no windows, so callers can never render it as
    /// 100% left.
    static func funding(_ data: Data, workspace: OpenDesignUsage.Workspace) throws -> [OpenDesignUsage.Window] {
        let envelope: FundingEnvelope
        do { envelope = try JSONDecoder().decode(FundingEnvelope.self, from: data) }
        catch { throw Failure.malformed }

        guard envelope.schemaVersion == 1,
              envelope.workspaceId == workspace.id,
              envelope.workspaceMemberId == workspace.memberID,
              let generatedAt = envelope.generatedAt, timestamp(generatedAt) != nil,
              let balance = envelope.balanceUsd, balance.range(of: balancePattern, options: .regularExpression) != nil,
              let funding = envelope.funding, fundingSources.contains(funding),
              envelope.fundingCheck.map(fundingChecks.contains) ?? true,
              let plan = envelope.codingPlan,
              plan.workspaceId == workspace.id,
              let planGeneratedAt = plan.generatedAt, timestamp(planGeneratedAt) != nil,
              plan.tier.map(tiers.contains) ?? true,
              let eligible = plan.eligible
        else { throw Failure.malformed }

        guard eligible, let rawWindows = plan.windows, !rawWindows.isEmpty else { throw Failure.noPlan }

        var windows: [OpenDesignUsage.Window] = []
        var seenKinds: Set<OpenDesignUsage.WindowKind> = []
        for raw in rawWindows {
            guard let policyId = raw.policyId, !policyId.isEmpty,
                  let duration = raw.durationSeconds, duration > 0,
                  let resetMode = raw.resetMode, resetModes.contains(resetMode),
                  let used = raw.usedCredits, credits(used) != nil,
                  let limit = raw.limitCredits, let limitValue = credits(limit), limitValue > 0,
                  let remaining = raw.remainingCredits, let remainingValue = credits(remaining),
                  remainingValue <= limitValue,
                  raw.windowStart.map({ timestamp($0) != nil }) ?? true
            else { throw Failure.malformed }
            let resetsAt: Date?
            if let rawReset = raw.resetsAt {
                guard let parsed = timestamp(rawReset) else { throw Failure.malformed }
                resetsAt = parsed
            } else {
                resetsAt = nil
            }
            let kind: OpenDesignUsage.WindowKind
            switch duration {
            case OpenDesignUsage.WindowKind.fiveHour.durationSeconds: kind = .fiveHour
            case OpenDesignUsage.WindowKind.weekly.durationSeconds: kind = .weekly
            default: throw Failure.malformed
            }
            guard seenKinds.insert(kind).inserted else { throw Failure.malformed }
            windows.append(OpenDesignUsage.Window(
                kind: kind,
                leftPercent: percentLeft(remaining: remainingValue, limit: limitValue),
                resetsAt: resetsAt
            ))
        }
        return windows.sorted { $0.kind.durationSeconds < $1.kind.durationSeconds }
    }

    /// Whole, non-negative credit count as the API writes it (a decimal string).
    private static func credits(_ raw: String) -> Decimal? {
        guard raw.range(of: creditPattern, options: .regularExpression) != nil else { return nil }
        return Decimal(string: raw, locale: decimal)
    }

    private static func percentLeft(remaining: Decimal, limit: Decimal) -> Double {
        let ratio = remaining * 100 / limit
        return min(max(NSDecimalNumber(decimal: ratio).doubleValue, 0), 100)
    }

    /// `YYYY-MM-DDTHH:MM[:SS[.fraction]]` with `Z` or a numeric offset, as the
    /// control API writes it.
    private static func timestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// The control key the official OpenDesign app (AMR login) stores in
/// `~/.amr/config.json`, profile `prod`.
enum OpenDesignCredential {
    enum LoadError: Error, Equatable {
        case missing
        case pendingLogin
        case malformed
    }

    static let profile = "prod"

    /// `AMR_HOME` is honored only in its documented shapes (`~`, `~/…`, an
    /// absolute path); anything else falls back to `~/.amr`.
    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let raw = (environment["AMR_HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let directory: URL
        if raw == "~" {
            directory = home
        } else if raw.hasPrefix("~/") {
            directory = home.appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
        } else if raw.hasPrefix("/") {
            directory = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            directory = home.appendingPathComponent(".amr", isDirectory: true)
        }
        return directory.appendingPathComponent("config.json")
    }

    /// Throws without ever echoing the key or the file contents.
    static func controlKey(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = object["profiles"] as? [String: Any],
              let profile = profiles[profile] as? [String: Any]
        else { throw LoadError.malformed }
        // The app records a login in progress as a non-false `pendingLogin`.
        if let pending = profile["pendingLogin"], !(pending is NSNull), (pending as? Bool) != false {
            throw LoadError.pendingLogin
        }
        guard let key = profile["controlKey"] as? String else { throw LoadError.malformed }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw LoadError.malformed }
        return trimmed
    }

    static func live() throws -> String {
        try controlKey(at: configURL())
    }
}

/// HTTP client for the two read-only control API calls.
///
/// The credential is loaded per fetch, used for the `Authorization` header only,
/// and dropped when `fetch()` returns. The production API host is fixed: a
/// rewritten config cannot redirect the key to another server.
struct OpenDesignUsageClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    static let productionAPI = URL(string: "https://amr-api.open-design.ai")!
    static let timeout: TimeInterval = 15

    let loadControlKey: @Sendable () throws -> String
    let transport: Transport
    let userAgent: String
    let apiBaseURL: URL

    init(loadControlKey: @escaping @Sendable () throws -> String,
         transport: @escaping Transport,
         userAgent: String = OpenDesignUsageClient.defaultUserAgent(),
         apiBaseURL: URL = OpenDesignUsageClient.productionAPI) {
        self.loadControlKey = loadControlKey
        self.transport = transport
        self.userAgent = userAgent
        self.apiBaseURL = apiBaseURL
    }

    /// Cloudflare rejects some scripting default user agents with 403, so both
    /// requests identify the app explicitly.
    static func defaultUserAgent() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "UsageRings/" + (version?.isEmpty == false ? version! : "dev")
    }

    func fetch() async -> OpenDesignUsage {
        let key: String
        do {
            key = try loadControlKey().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .notLoggedIn
        }
        guard !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .notLoggedIn
        }
        do {
            let (directoryData, directoryStatus) = try await transport(request(path: "/api/v1/workspaces", key: key))
            guard directoryStatus == 200 else { return Self.outcome(status: directoryStatus) }
            let workspace: OpenDesignUsage.Workspace
            do {
                workspace = try OpenDesignUsageParser.personalWorkspace(directoryData)
            } catch OpenDesignUsageParser.Failure.noPersonalWorkspace {
                return .noPersonalWorkspace
            } catch {
                return .malformed
            }
            let id = workspace.id.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? workspace.id
            let path = "/api/v1/workspaces/\(id)/billing/funding-check"
            let (fundingData, fundingStatus) = try await transport(request(path: path, key: key))
            guard fundingStatus == 200 else { return Self.outcome(status: fundingStatus) }
            do {
                let windows = try OpenDesignUsageParser.funding(fundingData, workspace: workspace)
                return .loaded(workspace: workspace, windows: windows)
            } catch OpenDesignUsageParser.Failure.noPlan {
                return .noPlan
            } catch {
                return .malformed
            }
        } catch {
            return .transportFailure
        }
    }

    private static func outcome(status: Int) -> OpenDesignUsage {
        status == 401 ? .unauthorized : .httpFailure(status)
    }

    private static let pathSegmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private func request(path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: apiBaseURL.absoluteString + path)!)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // URLSessionConfiguration below already ignores cookies; this keeps the
        // request itself explicit for injected transports.
        request.httpShouldHandleCookies = false
        return request
    }

    static func live() -> Self {
        Self(loadControlKey: { try OpenDesignCredential.live() }, transport: { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        })
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
