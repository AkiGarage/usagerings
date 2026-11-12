import CoreFoundation
import CryptoKit
import Foundation

enum ClaudeOAuthCredential {
    enum Failure: Error, Equatable {
        case missing
        case expired
        case malformed
    }

    private static let servicePrefix = "Claude Code-credentials"

    static func serviceName(configDir: String?) -> String {
        guard let configDir else { return servicePrefix }
        let normalized = configDir.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return servicePrefix + "-" + prefix
    }

    static func accountName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let raw = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        guard raw.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
            return "claude-code-user"
        }
        return raw
    }

    static func accessToken(keychainJSON: Data, now: Date) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: keychainJSON) as? [String: Any] else {
            throw Failure.malformed
        }
        guard let oauth = object["claudeAiOauth"] else { throw Failure.missing }
        guard let oauthObject = oauth as? [String: Any] else { throw Failure.malformed }
        guard let rawToken = oauthObject["accessToken"] else { throw Failure.missing }
        guard let token = rawToken as? String else { throw Failure.malformed }
        guard !token.isEmpty else { throw Failure.missing }
        guard !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.malformed
        }
        guard let rawExpiry = oauthObject["expiresAt"] else { throw Failure.missing }
        guard let number = rawExpiry as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else {
            throw Failure.malformed
        }
        let expiry = Date(timeIntervalSince1970: number.doubleValue / 1000)
        guard expiry > now.addingTimeInterval(60) else { throw Failure.expired }
        return token
    }

    static func live(configDir: String?) async throws -> String {
        let result = try await SubprocessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            timeout: 10
        ).run([
            "find-generic-password",
            "-a", accountName(),
            "-w",
            "-s", serviceName(configDir: configDir)
        ])
        guard !result.timedOut, result.terminationStatus == 0 else { throw Failure.missing }
        return try accessToken(keychainJSON: result.stdout, now: Date())
    }
}

struct ClaudeResetGrant: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case session
        case weekly
        case full
        case unknown
    }

    let kind: Kind
    let resetsLeft: Int
    let endsAt: Date?
    let paused: Bool
    let usableNow: Bool
}

enum ClaudeResetGrantsOutcome: Equatable, Sendable {
    case loaded([ClaudeResetGrant])
    case notOffered
    case notLoggedIn
    case loginExpired
    case unauthorized
    case httpFailure(Int)
    case rateLimited(TimeInterval)
    case transportFailure
    case malformed
}

struct ClaudeResetGrantsClient: Sendable {
    typealias LoadToken = @Sendable (String?) async throws -> String
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int, String?)

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let timeout: TimeInterval = 15
    static let maximumTickets = 100

    let loadToken: LoadToken
    let transport: Transport

    init(loadToken: @escaping LoadToken, transport: @escaping Transport) {
        self.loadToken = loadToken
        self.transport = transport
    }

    func fetch(configDir: String?) async -> ClaudeResetGrantsOutcome {
        let token: String
        do {
            token = try await loadToken(configDir)
        } catch ClaudeOAuthCredential.Failure.expired {
            return .loginExpired
        } catch ClaudeOAuthCredential.Failure.malformed {
            return .malformed
        } catch {
            return .notLoggedIn
        }
        guard !token.isEmpty, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .notLoggedIn
        }
        do {
            let (data, status, retryAfter) = try await transport(request(token: token))
            switch status {
            case 200:
                return Self.parse(data)
            case 429:
                return .rateLimited(Self.retryInterval(retryAfter, now: Date()))
            case 401, 403:
                return .unauthorized
            default:
                return .httpFailure(status)
            }
        } catch {
            return .transportFailure
        }
    }

    static let fallbackCLIVersion = "2.1.319"
    static let userAgent = "claude-cli/\(installedCLIVersion() ?? fallbackCLIVersion) (external, cli)"

    /// Newest installed Claude Code version (file names in ~/.local/share/claude/versions; empty
    /// placeholder files from an interrupted update are skipped), or nil.
    static func installedCLIVersion(directory: String = NSHomeDirectory() + "/.local/share/claude/versions") -> String? {
        let manager = FileManager.default
        let versions = ((try? manager.contentsOfDirectory(atPath: directory)) ?? []).compactMap { name -> [Int]? in
            let parts = name.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3, name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                  let size = (try? manager.attributesOfItem(atPath: directory + "/" + name))?[.size] as? Int,
                  size > 0 else { return nil }
            return parts
        }
        return versions.max { $0.lexicographicallyPrecedes($1) }.map { $0.map(String.init).joined(separator: ".") }
    }

    private func request(token: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Claude only includes reset grants for recent Claude Code clients, which identify as
        // `claude-cli/<version> (external, cli)` (Claude Code 2.1.319's own builder, KB()).
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    static func parse(_ data: Data) -> ClaudeResetGrantsOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let rawBlock = object["cedar_ember"], !(rawBlock is NSNull) else { return .notOffered }
        guard let block = rawBlock as? [String: Any] else { return .malformed }
        guard let eligible = boolean(block["eligible"]) else { return .malformed }
        guard eligible else { return .notOffered }
        guard let rawGrants = block["grants"], !(rawGrants is NSNull) else { return .loaded([]) }
        guard let entries = rawGrants as? [Any], entries.count <= maximumTickets else { return .malformed }
        var grants: [ClaudeResetGrant] = []
        for entry in entries {
            guard let item = entry as? [String: Any] else { return .malformed }
            guard let grant = grant(from: item),
                  grant.resetsLeft <= maximumTickets - grants.reduce(0, { $0 + $1.resetsLeft }) else {
                return .malformed
            }
            grants.append(grant)
        }
        return .loaded(grants)
    }

    private static func grant(from object: [String: Any]) -> ClaudeResetGrant? {
        guard let resetsLeft = integer(object["resets_left"]),
              object["type"] == nil || object["type"] is String,
              object["paused"] == nil || boolean(object["paused"]) != nil,
              object["usable_now"] == nil || boolean(object["usable_now"]) != nil else { return nil }
        var endsAt: Date?
        if let rawEnd = object["ends_at"], !(rawEnd is NSNull) {
            guard let text = rawEnd as? String, let date = timestamp(text) else { return nil }
            endsAt = date
        }
        let kind: ClaudeResetGrant.Kind
        switch object["type"] as? String {
        case "session": kind = .session
        case "weekly": kind = .weekly
        case "full": kind = .full
        default: kind = .unknown
        }
        let paused = boolean(object["paused"]) ?? false
        return ClaudeResetGrant(
            kind: kind,
            resetsLeft: resetsLeft,
            endsAt: endsAt,
            paused: paused,
            usableNow: boolean(object["usable_now"]) ?? !paused
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= Double(maximumTickets), value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func timestamp(_ raw: String) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = raw.contains(".") ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.date(from: raw)
    }

    static func retryInterval(_ raw: String?, now: Date) -> TimeInterval {
        guard let raw else { return ClaudeCLIUsage.grantsRefreshInterval }
        let seconds: TimeInterval?
        if let value = Double(raw), value.isFinite {
            seconds = value
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: raw)?.timeIntervalSince(now)
        }
        return max(ClaudeCLIUsage.grantsRefreshInterval, seconds ?? 0)
    }

    /// Stat keys the card and panel read for one Claude account's tickets (values are Japanese).
    static let countStat = "Reset tickets"          // "2" when known, "未確認" otherwise
    static let noteStat = "Reset tickets note"      // one short line: where/when, or why unknown
    static let ticketStat = "Reset ticket"          // "期限 11/17 16:59 JST" per ticket
    static let expiryStat = "Reset ticket expiry"   // ISO 8601, same order as ticketStat
    static let unknownCount = "未確認"

    /// Always returns the ticket section for one account: a count only when it is really known
    /// (held tickets, an eligible empty answer, or a fresh Desktop negative), otherwise 未確認 with
    /// the reason. `outcome` nil = nothing fetched yet. `desktopObservedAt` = the outcome is a
    /// Claude Desktop cache observation. `retryAt` = when the next OAuth attempt may run.
    static func stats(for outcome: ClaudeResetGrantsOutcome?, accountIndex: Int, now: Date,
                      calendar: Calendar, desktopObservedAt: Date? = nil, retryAt: Date? = nil) -> [ProviderStat] {
        func stat(_ title: String, _ value: String) -> ProviderStat {
            ProviderStat(title: title, valueText: value, accountIndex: accountIndex)
        }
        func time(_ date: Date) -> String { "\(UsageDurationFormat.timestamp(date, now: now, calendar: calendar)) JST" }
        func unknown(_ reason: String) -> [ProviderStat] { [stat(countStat, unknownCount), stat(noteStat, reason)] }
        let source = desktopObservedAt.map { "Claude Desktop・\(time($0)) 確認" }
        let retry = retryAt.flatMap { $0 > now ? "・\(time($0)) 以降に再取得" : nil } ?? ""
        switch outcome {
        case .loaded(let grants):
            guard grants.count <= maximumTickets,
                  grants.allSatisfy({ (0...maximumTickets).contains($0.resetsLeft) }),
                  grants.reduce(0, { $0 + $1.resetsLeft }) <= maximumTickets else {
                return unknown("取得できません")
            }
            // Inventory, not "spendable this instant": usable_now is false while e.g. the window is
            // still fresh, yet the stored ticket remains (CodexBar docs/claude.md counts it the same way).
            let tickets = heldGrants(grants, now: now)
                .flatMap { grant in Array(repeating: grant, count: grant.resetsLeft) }
                .sorted { ($0.endsAt ?? .distantFuture) < ($1.endsAt ?? .distantFuture) }
            var stats = [stat(countStat, "\(tickets.count)")]
            if let source { stats.append(stat(noteStat, source)) }
            for ticket in tickets {
                // type "full" does not say which limits it clears (a Fable-only grant is "full" too),
                // so only session/weekly name their kind.
                var text = ticket.endsAt.map { "期限 \(time($0))" } ?? "期限なし"
                if let kind = kindLabel(ticket.kind) { text += "（\(kind)）" }
                if !ticket.usableNow { text += "・\(notUsableNowStatus)" }
                stats.append(stat(ticketStat, text))
            }
            let formatter = ISO8601DateFormatter()
            stats += tickets.compactMap { $0.endsAt.map { stat(expiryStat, formatter.string(from: $0)) } }
            return stats
        case .notOffered where source != nil:
            // Only a fresh Desktop answer reaches here (ClaudeCLIUsage drops stale negatives).
            return [stat(countStat, "0"), stat(noteStat, source!)]
        case .notOffered:
            return unknown("公式APIは券情報を返しません")
        case .loginExpired:
            return unknown("Claude Codeを一度使うとログインが更新されます")
        case .unauthorized:
            return unknown("Claude Codeで再ログインしてください")
        case .rateLimited, .httpFailure(429):
            return unknown("取得制限中" + retry)
        case .httpFailure(let status):
            return unknown("取得できません（HTTP \(status)）")
        case .transportFailure, .malformed:
            return unknown("取得できません")
        case .notLoggedIn:
            return unknown("ログインがありません")
        case nil:
            return unknown("取得中")
        }
    }

    static func heldGrants(_ grants: [ClaudeResetGrant], now: Date) -> [ClaudeResetGrant] {
        grants.filter { $0.resetsLeft > 0 && !$0.paused && ($0.endsAt.map { $0 > now } ?? true) }
    }

    static let notUsableNowStatus = "今は使用不可"

    private static func kindLabel(_ kind: ClaudeResetGrant.Kind) -> String? {
        switch kind {
        case .session: "5時間リセット"
        case .weekly: "週リセット"
        case .full, .unknown: nil
        }
    }

    static func live() -> Self {
        Self(loadToken: { configDir in
            try await ClaudeOAuthCredential.live(configDir: configDir)
        }, transport: { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Retry-After"))
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
