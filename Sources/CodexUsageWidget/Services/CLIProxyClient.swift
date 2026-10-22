import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol CLIProxyKeyProvider: Sendable {
    func managementKey() -> String?
}

struct KeychainCLIProxyKeyProvider: CLIProxyKeyProvider {
    func managementKey() -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cliproxyapi-management",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }
}

protocol CLIProxyTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// Never follow a management redirect with the Authorization header.
final class CLIProxyURLSessionTransport: NSObject, CLIProxyTransport, URLSessionTaskDelegate, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor CLIProxyClient {
    static let missingKeyText = "Management key not in Keychain (cliproxyapi-management)"
    static let rejectedKeyText = "CLIProxyAPI rejected management key"
    private let transport: any CLIProxyTransport
    private let keyProvider: any CLIProxyKeyProvider
    private let clock: @Sendable () -> Date
    private var blockedKey: SHA256.Digest?
    private var blockedUntil: Date?
    private var refresh: Task<[ProviderSection], Never>?
    private struct CachedUsage {
        var providerName = "Claude"
        var windows: [UsageLimit] = []
        var stats: [ProviderStat] = []
        var fetchedAt: Date?
        var nextAttempt = Date.distantPast
        var backoff: TimeInterval = 0
        var failure: String?
        var rateLimited = false

        var notice: String? {
            if rateLimited {
                if let fetchedAt { return "rate limited · data from \(CLIProxyClient.time(fetchedAt))" }
                return "\(providerName) usage rate-limited; retry ~\(CLIProxyClient.time(nextAttempt))"
            }
            guard let failure else { return nil }
            return fetchedAt.map { "\(failure) · data from \(CLIProxyClient.time($0))" } ?? failure
        }
    }
    // Stable proxy account identity, never the (potentially identical) masked label.
    private var claudeUsage: [AccountID: CachedUsage] = [:]
    private struct GrokUsage {
        var periods = [CachedUsage(providerName: "Grok Weekly"), CachedUsage(providerName: "Grok Monthly")]
        var nextAttempt = Date.distantPast
        var backoff: TimeInterval = 0
    }
    private var grokUsage: [AccountID: GrokUsage] = [:]
    private static let claudeMinimumInterval: TimeInterval = 5 * 60

    init(
        transport: any CLIProxyTransport = CLIProxyURLSessionTransport(),
        keyProvider: any CLIProxyKeyProvider = KeychainCLIProxyKeyProvider(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.keyProvider = keyProvider
        self.clock = clock
    }

    func fetchSections(now: Date = Date(), skipping: Set<ProviderID> = []) async -> [ProviderSection] {
        // Actor reentrancy must not allow overlapping refreshes to race the 401 latch.
        if let refresh { return await refresh.value }
        let task = Task { await self.fetchSerially(now: now, skipping: skipping) }
        refresh = task
        let sections = await task.value
        refresh = nil
        return sections
    }

    private enum Failure: Error {
        case rejected, request, payload, noCredentials, noQuota, missingProject
        case rateLimited(retryAfter: TimeInterval?)
        var text: String {
            switch self {
            case .rejected: CLIProxyClient.rejectedKeyText
            case .request: "CLIProxyAPI request failed"
            case .payload: "CLIProxyAPI returned an unreadable response"
            case .noCredentials: "No enabled CLIProxyAPI credentials"
            case .noQuota: "No quota data reported"
            case .missingProject: "Antigravity project ID not available"
            case .rateLimited: "Usage rate-limited"
            }
        }
    }

    private func fetchSerially(now: Date, skipping: Set<ProviderID> = []) async -> [ProviderSection] {
        let providers: [ProviderID] = [.claude, .antigravity, .grok].filter { !skipping.contains($0) }
        guard !providers.isEmpty else { return [] }
        func failed(_ text: String) -> [ProviderSection] {
            providers.map { ProviderSection(provider: $0, windows: [], stats: [], failureText: text) }
        }
        guard let key = keyProvider.managementKey(), !key.isEmpty else {
            return failed(Self.missingKeyText)
        }
        let fingerprint = SHA256.hash(data: Data(key.utf8))
        if blockedKey == fingerprint, let blockedUntil, clock() < blockedUntil {
            return failed(Self.rejectedKeyText)
        }
        blockedKey = nil
        blockedUntil = nil
        do {
            let inventory = try CLIProxyParser.credentialInventory(
                try await management(path: "credentials", key: key)
            )
            let credentials = inventory.credentials
            var sections: [ProviderSection] = []
            for provider in providers {
                var section = ProviderSection(provider: provider, windows: [], stats: [], failureText: nil)
                let accounts = credentials.filter { $0.provider == (provider == .grok ? "xai" : provider.rawValue) && !$0.disabled }
                if accounts.isEmpty { section.failureText = Failure.noCredentials.text }
                // An empty successful inventory is different from an unavailable fetch.
                section.accountInventoryComplete = inventory.isComplete
                for (accountIndex, account) in accounts.enumerated() {
                    let statsStart = section.stats.count
                    var accountState = ProviderAccount(index: accountIndex,
                        id: AccountID.cliProxy(account, provider: provider))
                    do {
                        let windows: [UsageLimit]
                        if provider == .claude {
                            let usage = try await cachedClaudeUsage(account, key: key, now: now)
                            windows = usage.windows
                            if let notice = usage.notice {
                                section.accountInventoryComplete = false
                                section.stats.append(ProviderStat(title: account.maskedEmail, valueText: notice))
                                section.failureText = usage.rateLimited ? "Some accounts rate limited" : "Some accounts unavailable"
                                accountState.failureText = notice
                            }
                        } else if provider == .grok {
                            let usage = try await cachedGrokUsage(account, key: key, now: now)
                            windows = usage.periods.flatMap(\.windows)
                            var unavailablePeriods = 0
                            for period in usage.periods {
                                section.stats.append(contentsOf: period.stats)
                                if let notice = period.notice {
                                    section.accountInventoryComplete = false
                                    section.stats.append(ProviderStat(title: "\(account.maskedEmail) · \(period.providerName)",
                                                                      valueText: notice))
                                    unavailablePeriods += 1
                                }
                            }
                            if !usage.periods.isEmpty, unavailablePeriods == usage.periods.count {
                                section.failureText = "Some accounts unavailable"
                                accountState.failureText = "Usage unavailable"
                            }
                        } else {
                            windows = try await quota(account, provider: provider, key: key, now: now)
                            guard !windows.isEmpty else { throw Failure.noQuota }
                        }
                        section.windows += windows.map { window in
                            var identified = window
                            identified.accountIndex = accountIndex
                            return identified
                        }
                    } catch Failure.rejected {
                        // Invalidate even earlier results so every CLIProxy section explains the pause.
                        throw Failure.rejected
                    } catch {
                        section.accountInventoryComplete = false
                        let reason = (error as? Failure)?.text ?? Failure.payload.text
                        section.stats.append(ProviderStat(title: account.maskedEmail, valueText: reason))
                        section.failureText = "Some accounts unavailable"
                        accountState.failureText = reason
                    }
                    section.accounts.append(accountState)
                    for index in statsStart..<section.stats.count {
                        section.stats[index].accountIndex = accountIndex
                    }
                }
                sections.append(section)
            }
            // Remote labels are untrusted, including an accidental echo of the management key.
            return sections.map { section in
                var safe = section
                safe.windows = section.windows.map {
                    var window = UsageLimit(title: $0.title.replacingOccurrences(of: key, with: "[redacted]"),
                                            leftPercent: $0.leftPercent, resetText: $0.resetText)
                    window.accountIndex = $0.accountIndex
                    window.resetAt = $0.resetAt
                    return window
                }
                safe.stats = section.stats.map {
                    ProviderStat(title: $0.title.replacingOccurrences(of: key, with: "[redacted]"),
                                 valueText: $0.valueText, accountIndex: $0.accountIndex)
                }
                return safe
            }
        } catch {
            return failed((error as? Failure)?.text ?? Failure.payload.text)
        }
    }

    private func management(path: String, key: String, body: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8317/v8/management/\(path)")!, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let status: Int
        do { (data, status) = try await transport.send(request) }
        catch { throw Failure.request }
        try checkStatus(status, key: key)
        return data
    }

    private func checkStatus(_ status: Int, key: String) throws {
        if status == 401 {
            blockedKey = SHA256.hash(data: Data(key.utf8))
            blockedUntil = clock().addingTimeInterval(30 * 60)
            throw Failure.rejected
        }
        guard (200..<300).contains(status) else { throw Failure.request }
    }

    private func apiCall(_ account: CLIProxyCredential, method: String, url: String,
                         headers: [String: String], data: String? = nil, key: String) async throws -> Data {
        var body: [String: Any] = ["authIndex": account.authIndex, "method": method, "url": url, "header": headers]
        if let data { body["data"] = data }
        let response = try await management(path: "requests/api-call", key: key, body: body)
        guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let status = envelope["status_code"] as? Int else { throw Failure.payload }
        if status == 429 {
            throw Failure.rateLimited(retryAfter: retryAfter(envelope["header"]))
        }
        try checkStatus(status, key: key)
        if let string = envelope["body"] as? String { return Data(string.utf8) }
        guard let object = envelope["body"], JSONSerialization.isValidJSONObject(object) else { throw Failure.payload }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func cachedClaudeUsage(_ account: CLIProxyCredential, key: String, now: Date) async throws -> CachedUsage {
        let id = AccountID.cliProxy(account, provider: .claude)
        var cached = claudeUsage[id] ?? CachedUsage()
        let startedAt = clock()
        guard startedAt >= cached.nextAttempt else { return cached }
        cached.nextAttempt = startedAt.addingTimeInterval(Self.claudeMinimumInterval)
        do {
            let windows = try await quota(account, provider: .claude, key: key, now: now)
            guard !windows.isEmpty else { throw Failure.noQuota }
            cached.windows = windows
            cached.fetchedAt = clock()
            cached.backoff = 0
            cached.failure = nil
            cached.rateLimited = false
        } catch Failure.rejected {
            // Preserve the existing global management-key latch and recovery path.
            throw Failure.rejected
        } catch Failure.rateLimited(let retryAfter) {
            cached.backoff = min(cached.backoff == 0 ? Self.claudeMinimumInterval : cached.backoff * 2, 30 * 60)
            cached.nextAttempt = max(cached.nextAttempt, clock().addingTimeInterval(retryAfter ?? cached.backoff))
            cached.rateLimited = true
            cached.failure = nil
        } catch {
            cached.failure = (error as? Failure)?.text ?? Failure.payload.text
            cached.rateLimited = false
        }
        claudeUsage[id] = cached
        return cached
    }

    private func cachedGrokUsage(_ account: CLIProxyCredential, key: String, now: Date) async throws -> GrokUsage {
        let id = AccountID.cliProxy(account, provider: .grok)
        var cached = grokUsage[id] ?? GrokUsage()
        guard clock() >= cached.nextAttempt else { return cached }
        cached.nextAttempt = clock().addingTimeInterval(Self.claudeMinimumInterval)
        var headers = ["Authorization": "Bearer $TOKEN$", "x-xai-token-auth": "xai-grok-cli",
                       "x-grok-client-version": "1.0.46", "accept": "*/*",
                       "user-agent": "grok-pager/1.0.46 grok-shell/1.0.46 (macos; aarch64)"]
        if let userID = account.userID, !userID.isEmpty { headers["x-userid"] = userID }
        var rateLimited = false
        let backoff = min(cached.backoff == 0 ? Self.claudeMinimumInterval : cached.backoff * 2, 30 * 60)
        for index in cached.periods.indices {
            var period = cached.periods[index]
            do {
                let url = "https://cli-chat-proxy.grok.com/v1/billing" + (index == 0 ? "?format=credits" : "")
                let data = try await apiCall(account, method: "GET", url: url, headers: headers, key: key)
                switch try CLIProxyParser.grok(data, label: account.maskedEmail, weekly: index == 0, now: now) {
                case .quota(let window):
                    period.windows = [window]
                    period.stats = []
                case .noMonthlyCap:
                    // SuperGrok-style plans report monthlyLimit 0 (no monthly window): show nothing.
                    period.windows = []
                    period.stats = []
                case .noData:
                    period.windows = []
                    period.stats = [ProviderStat(title: "\(account.maskedEmail) · \(period.providerName)",
                                                 valueText: "No data")]
                }
                period.fetchedAt = clock()
                period.failure = nil
                period.rateLimited = false
            } catch Failure.rejected {
                throw Failure.rejected
            } catch Failure.rateLimited(let retryAfter) {
                rateLimited = true
                cached.nextAttempt = max(cached.nextAttempt, clock().addingTimeInterval(retryAfter ?? backoff))
                period.rateLimited = true
                period.failure = nil
            } catch {
                period.failure = (error as? Failure)?.text ?? Failure.payload.text
                period.rateLimited = false
            }
            cached.periods[index] = period
        }
        cached.backoff = rateLimited ? backoff : 0
        for index in cached.periods.indices { cached.periods[index].nextAttempt = cached.nextAttempt }
        grokUsage[id] = cached
        return cached
    }

    private func retryAfter(_ header: Any?) -> TimeInterval? {
        guard let headers = header as? [String: Any],
              let entry = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }),
              let value = (entry.value as? String) ?? (entry.value as? [String])?.first else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(clock()))
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func quota(_ account: CLIProxyCredential, provider: ProviderID, key: String, now: Date) async throws -> [UsageLimit] {
        if provider == .claude {
            let data = try await apiCall(account, method: "GET", url: "https://api.anthropic.com/api/oauth/usage", headers: [
                "User-Agent": "claude-cli/2.1.280 (external, cli)", "Authorization": "Bearer $TOKEN$",
                "Content-Type": "application/json", "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"
            ], key: key)
            return try CLIProxyParser.claude(data, label: account.maskedEmail, now: now)
        }
        guard let project = account.projectID, !project.isEmpty else { throw Failure.missingProject }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["project": project]), as: UTF8.self)
        for host in ["daily-cloudcode-pa.googleapis.com", "daily-cloudcode-pa.sandbox.googleapis.com", "cloudcode-pa.googleapis.com"] {
            do {
                let data = try await apiCall(account, method: "POST", url: "https://\(host)/v1internal:retrieveUserQuotaSummary", headers: [
                    "Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
                    "User-Agent": "antigravity/hub/2.23.0 darwin/arm64"
                ], data: body, key: key)
                let windows = try CLIProxyParser.antigravity(data, now: now)
                if !windows.isEmpty { return windows }
            } catch Failure.rejected { throw Failure.rejected }
            catch { continue }
        }
        throw Failure.noQuota
    }
}
