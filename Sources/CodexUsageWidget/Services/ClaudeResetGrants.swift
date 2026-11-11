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
    case transportFailure
    case malformed
}

struct ClaudeResetGrantsClient: Sendable {
    typealias LoadToken = @Sendable (String?) async throws -> String
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let timeout: TimeInterval = 15

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
            let (data, status) = try await transport(request(token: token))
            switch status {
            case 200:
                return Self.parse(data)
            case 401, 403:
                return .unauthorized
            default:
                return .httpFailure(status)
            }
        } catch {
            return .transportFailure
        }
    }

    private func request(token: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        return request
    }

    static func parse(_ data: Data) -> ClaudeResetGrantsOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        guard let rawBlock = object["cedar_ember"], !(rawBlock is NSNull) else { return .notOffered }
        guard let block = rawBlock as? [String: Any] else { return .malformed }
        guard boolean(block["eligible"]) == true else { return .notOffered }
        guard let rawGrants = block["grants"], !(rawGrants is NSNull) else { return .loaded([]) }
        guard let entries = rawGrants as? [Any] else { return .malformed }
        var grants: [ClaudeResetGrant] = []
        for entry in entries {
            guard let item = entry as? [String: Any] else { return .malformed }
            grants.append(grant(from: item))
        }
        return .loaded(grants)
    }

    private static func grant(from object: [String: Any]) -> ClaudeResetGrant {
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
            resetsLeft: integer(object["resets_left"]) ?? 0,
            endsAt: (object["ends_at"] as? String).flatMap(timestamp),
            paused: paused,
            usableNow: boolean(object["usable_now"]) ?? !paused
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        return number.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func timestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func stats(for outcome: ClaudeResetGrantsOutcome, accountIndex: Int, now: Date,
                      calendar: Calendar) -> [ProviderStat] {
        switch outcome {
        case .loaded(let grants):
            let usable = grants.filter {
                $0.resetsLeft > 0 && !$0.paused && ($0.endsAt.map { $0 > now } ?? true)
            }
            let tickets = usable.flatMap { grant in Array(repeating: grant, count: grant.resetsLeft) }
            guard !tickets.isEmpty else { return [] }
            var stats = [ProviderStat(title: "Reset tickets", valueText: "\(tickets.count) available",
                                      accountIndex: accountIndex)]
            for ticket in tickets {
                let text = MultiUsageService.ticketText(
                    CodexExtrasParser.Ticket(title: title(for: ticket.kind), status: "available",
                                             resetType: nil, grantedAt: nil, expiresAt: ticket.endsAt),
                    now: now,
                    calendar: calendar
                )
                stats.append(ProviderStat(title: "Reset ticket", valueText: text, accountIndex: accountIndex))
            }
            let formatter = ISO8601DateFormatter()
            for ticket in tickets {
                guard let endsAt = ticket.endsAt else { continue }
                stats.append(ProviderStat(title: "Reset ticket expiry",
                                          valueText: formatter.string(from: endsAt),
                                          accountIndex: accountIndex))
            }
            return stats
        case .loginExpired:
            return note("Claude Codeを一度使うとログインが更新されます", accountIndex: accountIndex)
        case .unauthorized:
            return note("Claude Codeで再ログインしてください", accountIndex: accountIndex)
        case .httpFailure(429):
            return note("取得の回数制限中（\(Int(ClaudeCLIUsage.grantsRefreshInterval / 60))分ごとに再取得）", accountIndex: accountIndex)
        case .httpFailure(let status):
            return note("取得できません（HTTP \(status)）", accountIndex: accountIndex)
        case .transportFailure, .malformed:
            return note("取得できません", accountIndex: accountIndex)
        case .notOffered, .notLoggedIn:
            return []
        }
    }

    private static func note(_ text: String, accountIndex: Int) -> [ProviderStat] {
        [ProviderStat(title: "リセットチケット", valueText: text, accountIndex: accountIndex)]
    }

    private static func title(for kind: ClaudeResetGrant.Kind) -> String {
        switch kind {
        case .session: "5時間リセット"
        case .weekly: "週リセット"
        case .full: "全リセット"
        case .unknown: "リセット"
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
