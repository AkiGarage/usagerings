import Foundation
import os

struct MultiUsageService: Sendable {
    private let cliPath: String
    private let commandRunner: CodexUsageService.CommandRunner?
    private let zaiTicketClient: ZaiResetTicketClient?
    private let claudeRateLimitMonitor: ClaudeRateLimitMonitor?
    private let claudeCLI: ClaudeCLIUsage?
    private let openDesignClient: OpenDesignUsageClient?
    private let retryDelay: TimeInterval
    private let fetchFailureLog: FetchFailureLog?

    init(
        cliPath: String = CodexBarRequirement.cliPath,
        commandRunner: CodexUsageService.CommandRunner? = nil,
        zaiTicketClient: ZaiResetTicketClient? = nil,
        claudeRateLimitMonitor: ClaudeRateLimitMonitor? = nil,
        claudeCLI: ClaudeCLIUsage? = nil,
        openDesignClient: OpenDesignUsageClient? = nil,
        retryDelay: TimeInterval = 2.5,
        failureLog: FetchFailureLog? = nil
    ) {
        self.cliPath = cliPath
        self.commandRunner = commandRunner
        self.zaiTicketClient = zaiTicketClient ?? (commandRunner == nil ? .live() : nil)
        self.claudeRateLimitMonitor = claudeRateLimitMonitor ?? (commandRunner == nil ? .live() : nil)
        self.claudeCLI = claudeCLI ?? (commandRunner == nil ? Self.sharedClaudeCLI(cliPath) : nil)
        self.openDesignClient = openDesignClient ?? (commandRunner == nil ? .live() : nil)
        self.retryDelay = retryDelay
        self.fetchFailureLog = failureLog ?? (commandRunner == nil ? .live() : nil)
    }

    private static let claudeCLICache = OSAllocatedUnfairLock<[String: ClaudeCLIUsage]>(initialState: [:])
    private static func sharedClaudeCLI(_ path: String) -> ClaudeCLIUsage {
        claudeCLICache.withLock { cache in
            if let existing = cache[path] { return existing }
            let created = ClaudeCLIUsage.live(cliPath: path)
            cache[path] = created
            return created
        }
    }

    func fetchAll(
        now: Date = Date(),
        disabled: Set<ProviderID> = [],
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) async -> MultiUsageSnapshot {
        async let antigravity = fetchProviderUnlessDisabled(.antigravity, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let grok = fetchProviderUnlessDisabled(.grok, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let codex = fetchProviderUnlessDisabled(.codex, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let zai = fetchProviderUnlessDisabled(.zai, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let minimax = fetchProviderUnlessDisabled(.minimax, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let kimi = fetchProviderUnlessDisabled(.kimi, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let deepseek = fetchProviderUnlessDisabled(.deepseek, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let opendesign = fetchOpenDesignUnlessDisabled(disabled: disabled, now: now)
        async let tickets = disabled.contains(.zai) ? nil : zaiTicketClient?.fetch()
        async let blocks = disabled.contains(.claude) ? nil : claudeRateLimitMonitor?.blocks(now: now)
        let (codexResult, zaiResult, openDesignResult, ticketResult, blockResult) =
            await (codex, zai, opendesign, tickets, blocks)
        let cliClaude = disabled.contains(.claude) ? nil : claudeCLI?.section(accounts: ClaudeCLIAccountSettings.load(), now: now, timeZone: timeZone)
        var proxy = await [antigravity.section, grok.section]
        if !disabled.contains(.claude) {
            if claudeCLI != nil {
                proxy.append(cliClaude?.section ?? Self.claudePendingSection)
            } else {
                proxy.append(await fetchProvider(.claude, now: now, timeZone: timeZone, calendar: calendar).section)
            }
        }
        let sshFailure = disabled.contains(.claude) ? nil : await claudeRateLimitMonitor?.remoteFailureText()
        let proxyWithBlocks = proxy.map { section in
            var section = section
            if section.provider == .claude {
                section.claudeProfileBlocks = blockResult ?? [:]
                section.claudeRemoteFailureText = sshFailure
            }
            return section
        }
        var zaiSection = zaiResult.section
        zaiSection.zaiResetTickets = zaiSection.accounts.count > 1 ? nil : ticketResult
        let additional = await [minimax.section, kimi.section, deepseek.section, openDesignResult]
        let sections = MultiUsageSnapshot.ordered([codexResult.section, zaiSection] + additional + proxyWithBlocks)
        Self.writeWindowDump(sections)
        return MultiUsageSnapshot(
            sections: sections,
            codexSnapshot: codexResult.codexSnapshot,
            updatedAt: now
        )
    }

    private static func writeWindowDump(_ sections: [ProviderSection]) {
        guard Bundle.main.bundleIdentifier != nil, NSClassFromString("XCTestCase") == nil else { return }
        guard let url = PrivateTempPaths.file("codex-usage-widget-panel-windows.json"),
              let data = windowDumpData(sections) else { return }
        PrivateTempPaths.writePrivately(data, to: url)
    }

    static func windowDumpData(_ sections: [ProviderSection]) -> Data? {
        let rows: [[String: Any]] = sections.flatMap { section in
            section.windows.map { window in
                let kind: String
                switch ServiceRowModel.kind(window.title) {
                case .five: kind = "5h"
                case .week: kind = "weekly"
                case .other: kind = "other"
                }
                return ["provider": section.provider.rawValue, "window": kind, "left": window.leftPercent]
            } + [["provider": section.provider.rawValue, "statCount": section.stats.count]]
        }
        return try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
    }

    private struct ProviderResult: Sendable {
        let provider: ProviderID
        let section: ProviderSection
        let codexSnapshot: UsageSnapshot?
    }

    private enum ProviderFailure: LocalizedError {
        case timedOut
        case logout(CodexUsageError)

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "CodexBarCLI timed out"
            case .logout(let error):
                error.errorDescription
            }
        }
    }

    static let claudePendingText = "Claude: CodexBar CLI の値を取得中"

    static let claudePendingSection = ProviderSection(provider: .claude, windows: [], stats: [], failureText: claudePendingText)

    static let hiddenText = "非表示（取得していません）"

    private func fetchProviderUnlessDisabled(_ provider: ProviderID, disabled: Set<ProviderID>, now: Date,
                                             timeZone: TimeZone, calendar: Calendar) async -> ProviderResult {
        guard !disabled.contains(provider) else {
            return ProviderResult(provider: provider,
                                  section: ProviderSection(provider: provider, windows: [], stats: [], failureText: Self.hiddenText),
                                  codexSnapshot: nil)
        }
        return await fetchProvider(provider, now: now, timeZone: timeZone, calendar: calendar)
    }

    private func fetchOpenDesignUnlessDisabled(disabled: Set<ProviderID>, now: Date) async -> ProviderSection {
        guard !disabled.contains(.opendesign) else {
            return ProviderSection(provider: .opendesign, windows: [], stats: [], failureText: Self.hiddenText)
        }
        guard let client = openDesignClient else { return Self.openDesignSection(.notLoggedIn, now: now) }
        return Self.openDesignSection(await client.fetch(), now: now)
    }

    static func openDesignSection(_ outcome: OpenDesignUsage, now: Date) -> ProviderSection {
        switch outcome {
        case let .loaded(_, windows):
            let limits = windows.map { window -> UsageLimit in
                var limit = UsageLimit(
                    title: window.kind.title,
                    leftPercent: window.leftPercent,
                    resetText: window.resetsAt.map { UsageDurationFormat.resetText(for: $0, now: now) } ?? openDesignUnknownReset
                )
                limit.resetAt = window.resetsAt
                return limit
            }
            return ProviderSection(provider: .opendesign, windows: limits, stats: [], failureText: nil)
        case .notLoggedIn:
            return ProviderSection(provider: .opendesign, windows: [], stats: [],
                                   failureText: openDesignLoginText, failureReason: .logout)
        case .unauthorized:
            return ProviderSection(provider: .opendesign, windows: [], stats: [],
                                   failureText: openDesignLoginText, failureReason: .logout)
        case let .httpFailure(status):
            return ProviderSection(provider: .opendesign, windows: [], stats: [],
                                   failureText: "\(openDesignUnavailableText) (\(status))", failureReason: .providerError)
        case .transportFailure:
            return ProviderSection(provider: .opendesign, windows: [], stats: [],
                                   failureText: openDesignUnavailableText, failureReason: .transport)
        case .malformed, .noPlan, .noPersonalWorkspace:
            return ProviderSection(provider: .opendesign, windows: [], stats: [],
                                   failureText: openDesignUnavailableText, failureReason: .providerError)
        }
    }

    static let openDesignLoginText = "OpenDesignアプリでログインしてください"
    static let openDesignUnavailableText = "OpenDesignの使用量を取得できません"
    static let openDesignUnknownReset = "リセット時刻 不明"

    private func fetchProvider(
        _ provider: ProviderID,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) async -> ProviderResult {
        do {
            let result = try await run(provider, now: now, timeZone: timeZone, calendar: calendar)
            if result.timedOut {
                throw ProviderFailure.timedOut
            }
            if let partial = partialResult(for: provider, result: result, now: now, timeZone: timeZone, calendar: calendar) {
                if provider != .codex {
                    for account in partial.section.accounts where account.failureText != nil {
                        fetchFailureLog?.record(provider: "\(provider.rawValue):\(account.index)",
                                                reason: account.failureReason ?? .providerError,
                                                exitCode: result.terminationStatus,
                                                message: account.failureText ?? "")
                    }
                }
                return partial
            }
            guard result.terminationStatus == 0 else {
                let error = CodexUsageError.commandFailure(
                    exitCode: result.terminationStatus,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    provider: provider
                )
                if Self.isLogout(stdout: result.stdout, stderr: result.stderr) {
                    throw ProviderFailure.logout(error)
                }
                throw error
            }
            switch provider {
            case .codex:
                return try codexResult(from: result.stdout, now: now, timeZone: timeZone, calendar: calendar)
            case .zai, .grok, .claude, .antigravity, .minimax, .kimi, .deepseek, .gemini:
                let section = try MultiProviderParser.parse(
                    result.stdout,
                    provider: provider,
                    now: now,
                    timeZone: timeZone
                )
                return ProviderResult(provider: provider, section: section, codexSnapshot: nil)
            case .opendesign:
                throw MultiProviderParser.ParseError.noWindows
            }
        } catch {
            Self.recordFailure(fetchFailureLog, provider: provider.rawValue, error: error)
            return ProviderResult(
                provider: provider,
                section: ProviderSection(
                    provider: provider,
                    windows: [],
                    stats: [],
                    failureText: Self.failureText(for: error),
                    failureReason: Self.failureReason(for: error)
                ),
                codexSnapshot: nil
            )
        }
    }

    static func isLogout(stdout: Data, stderr: Data) -> Bool {
        [stdout, stderr].contains { data in
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return isLogoutMessage(text)
        }
    }

    static func isLogoutMessage(_ text: String) -> Bool {
        let phrases = ["not logged in", "unauthorized", "unauthorised", "no credentials",
                       "login required", "please log in", "not authenticated"]
        if phrases.contains(where: { text.range(of: $0, options: .caseInsensitive) != nil }) { return true }
        guard let code401 else { return false }
        return code401.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let code401 = try? NSRegularExpression(
        pattern: "(?:http|status|code|error|response|request)[ \\t=:\"'()/]{0,8}401(?:[^0-9]|$)",
        options: [.caseInsensitive]
    )

    private func partialResult(
        for provider: ProviderID,
        result: CodexUsageService.CommandResult,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> ProviderResult? {
        guard result.terminationStatus != 0 else { return nil }
        if provider == .codex {
            guard let partial = try? codexResult(from: result.stdout, now: now, timeZone: timeZone, calendar: calendar),
                  partial.section.accounts.count > 1, !partial.section.windows.isEmpty,
                  partial.section.accounts.contains(where: { $0.failureText != nil }) else { return nil }
            return partial
        }
        guard let partial = try? MultiProviderParser.parse(result.stdout, provider: provider, now: now, timeZone: timeZone),
              partial.accounts.count > 1, partial.accounts.contains(where: { $0.failureText != nil }),
              !partial.windows.isEmpty || !partial.stats.isEmpty else { return nil }
        return ProviderResult(provider: provider, section: partial, codexSnapshot: nil)
    }

    private func run(
        _ provider: ProviderID,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) async throws -> CodexUsageService.CommandResult {
        let arguments = Self.usageArguments(provider)
        func attempt(_ arguments: [String]) async throws -> CodexUsageService.CommandResult {
            var retried = provider == .antigravity
            while true {
                try Task.checkCancellation()
                do {
                    let result: CodexUsageService.CommandResult
                    if let commandRunner {
                        result = try commandRunner(arguments)
                    } else {
                        let runner = SubprocessRunner(
                            executableURL: URL(fileURLWithPath: cliPath), timeout: 30,
                            environment: provider == .codex ? CodexUsageService.codexEnvironmentOverride() : nil)
                        result = try await runner.run(arguments)
                    }
                    if result.timedOut && !retried { retried = true; continue }
                    if result.terminationStatus != 0, !retried,
                       !Self.isLogout(stdout: result.stdout, stderr: result.stderr),
                       partialResult(for: provider, result: result, now: now, timeZone: timeZone, calendar: calendar) == nil {
                        retried = true
                        if retryDelay > 0 { try? await Task.sleep(for: .seconds(retryDelay)) }
                        continue
                    }
                    return result
                } catch let error as CodexUsageError {
                    if case .commandFailed(-1, _) = error, !retried { retried = true; continue }
                    throw error
                }
            }
        }
        let result = try await attempt(arguments)
        if Self.accountScope(provider) == .savedAccounts, provider != .codex, Self.isNoTokenAccounts(result.stdout) {
            return try await attempt(Array(arguments.dropLast()))
        }
        return result
    }

    static func recordFailure(_ log: FetchFailureLog?, provider: String, error: Error) {
        guard let log else { return }
        var exitCode: Int32?
        if case let CodexUsageError.commandFailed(code, _) = error { exitCode = code }
        if case ProviderFailure.logout(let inner) = error, case let CodexUsageError.commandFailed(code, _) = inner { exitCode = code }
        log.record(provider: provider, reason: Self.failureReason(for: error), exitCode: exitCode,
                   message: Self.failureText(for: error))
    }

    enum CodexBarAccountScope: Equatable, Sendable {
        case savedAccounts
        case localLogin
    }

    static func accountScope(_ provider: ProviderID) -> CodexBarAccountScope {
        switch provider {
        case .antigravity, .grok, .claude: .localLogin
        case .codex, .zai, .minimax, .kimi, .deepseek, .opendesign, .gemini: .savedAccounts
        }
    }

    static func usageArguments(_ provider: ProviderID) -> [String] {
        let scope: [String] = switch accountScope(provider) {
        case .savedAccounts: ["--all-accounts"]
        case .localLogin: []
        }
        return ["usage", "--provider", provider.rawValue, "--format", "json"] + sourceArguments(provider) + scope
    }

    static func sourceArguments(_ provider: ProviderID) -> [String] {
        switch provider {
        case .antigravity, .grok, .claude: ["--source", "cli"]
        case .codex, .zai, .minimax, .kimi, .deepseek, .opendesign, .gemini: []
        }
    }

    static func isNoTokenAccounts(_ stdout: Data) -> Bool {
        guard let rows = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]], !rows.isEmpty else { return false }
        return rows.allSatisfy { (($0["error"] as? [String: Any])?["message"] as? String)?.hasPrefix("No token accounts configured") == true }
    }

    static func ticketText(_ ticket: CodexExtrasParser.Ticket, now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if let title = ticket.title, !title.isEmpty { parts.append(title) }
        switch ticket.status {
        case "available": parts.append("使用可")
        case "used", "redeemed", "consumed": parts.append("使用済み")
        case "expired": parts.append("期限切れ")
        case let other?: parts.append(other)
        case nil: break
        }
        if let expires = ticket.expiresAt {
            parts.append("期限 \(UsageDurationFormat.timestamp(expires, now: now, calendar: calendar))")
        }
        if let granted = ticket.grantedAt {
            parts.append("付与 \(UsageDurationFormat.timestamp(granted, now: now, calendar: calendar))")
        }
        if let type = ticket.resetType, !type.isEmpty { parts.append(type) }
        return parts.joined(separator: " · ")
    }

    private func codexResult(
        from data: Data,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) throws -> ProviderResult {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CodexUsageError.invalidJSON
        }
        let accounts = entries.filter { $0["provider"] as? String == "codex" }
        guard accounts.count > 1 else {
            let result = try codexAccountResult(from: data, now: now, timeZone: timeZone, calendar: calendar)
            var section = result.section
            section.accounts = [ProviderAccount(index: 0, codexExtras: section.codexExtras,
                id: accounts.first.flatMap { AccountID.codexBar($0, provider: .codex) } ?? .singleton(.codex))]
            section.codexExtras = nil
            return ProviderResult(provider: .codex, section: section, codexSnapshot: result.codexSnapshot)
        }
        var section = ProviderSection(provider: .codex, windows: [], stats: [], failureText: nil)
        var primarySnapshot: UsageSnapshot?
        for (index, entry) in accounts.enumerated() {
            let id = AccountID.codexBar(entry, provider: .codex)
            do {
                let data = try JSONSerialization.data(withJSONObject: [entry])
                let result = try codexAccountResult(from: data, now: now, timeZone: timeZone, calendar: calendar)
                if index == 0 {
                    primarySnapshot = result.codexSnapshot
                }
                section.accounts.append(ProviderAccount(index: index, codexExtras: result.section.codexExtras, id: id))
                section.windows += result.section.windows.map { window in
                    var window = window
                    window.accountIndex = index
                    return window
                }
                section.stats += result.section.stats.map { stat in
                    var stat = stat
                    stat.accountIndex = index
                    return stat
                }
            } catch {
                Self.recordFailure(fetchFailureLog, provider: "codex:\(index)", error: error)
                section.accounts.append(ProviderAccount(index: index, failureText: Self.failureText(for: error), id: id, failureReason: Self.failureReason(for: error)))
                section.failureText = "Some accounts unavailable"
            }
        }
        return ProviderResult(provider: .codex, section: section, codexSnapshot: primarySnapshot)
    }

    private func codexAccountResult(
        from data: Data,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) throws -> ProviderResult {
        let snapshot = try CodexUsageTextParser.parseJSON(data, now: now, timeZone: timeZone)
        let extras = CodexExtrasParser.parse(data)
        let cardExtras = extras.creditsText != nil || extras.availableCount != nil || !extras.tickets.isEmpty
            ? extras
            : nil

        var windows: [UsageLimit] = []
        var stats: [ProviderStat] = []

        if let session = snapshot.session {
            windows.append(session.retitled("5h"))
        } else {
            stats.append(ProviderStat(title: "5h", valueText: "Not reported"))
        }
        if let weekly = snapshot.weekly {
            windows.append(weekly)
        }

        if let creditsText = extras.creditsText {
            stats.append(ProviderStat(title: "Credits", valueText: creditsText))
        } else {
            stats.append(ProviderStat(title: "Credits", valueText: "Not readable"))
        }

        if let count = extras.availableCount {
            var summary = "\(count) available"
            if let next = extras.ticketExpiries.first {
                summary += " · next expires \(UsageDurationFormat.timestamp(next, now: now, calendar: calendar))"
            }
            stats.append(ProviderStat(title: "Reset tickets", valueText: summary))
            for ticket in extras.tickets {
                stats.append(ProviderStat(title: "Reset ticket", valueText: Self.ticketText(ticket, now: now, calendar: calendar)))
            }
            for expiry in extras.ticketExpiries {
                stats.append(ProviderStat(title: "Reset ticket expiry", valueText: ISO8601DateFormatter().string(from: expiry)))
            }
            if let updated = extras.ticketsUpdatedAt {
                stats.append(ProviderStat(title: "Reset tickets updated",
                                          valueText: UsageDurationFormat.timestamp(updated, now: now, calendar: calendar)))
            }
        }

        if let account = extras.maskedAccount {
            stats.append(ProviderStat(title: "Account", valueText: account))
        }

        return ProviderResult(
            provider: .codex,
            section: ProviderSection(
                provider: .codex,
                windows: windows,
                stats: stats,
                failureText: nil,
                codexExtras: cardExtras
            ),
            codexSnapshot: snapshot
        )
    }

    static func failureReason(for error: Error) -> UsageFailureReason {
        if case ProviderFailure.timedOut = error { return .timeout }
        if case ProviderFailure.logout = error { return .logout }
        switch error {
        case let error as CodexUsageError:
            if case .commandFailed(-1, _) = error { return .launchFailure }
            return .providerError
        case is MultiProviderParser.ParseError, is DecodingError:
            return .providerError
        default:
            return .other
        }
    }

    private static func failureText(for error: Error) -> String {
        error.localizedDescription
    }
}

private extension UsageLimit {
    func retitled(_ title: String) -> UsageLimit {
        var result = UsageLimit(
            title: title,
            leftPercent: leftPercent,
            resetText: resetText,
            detailText: detailText,
            projectionText: projectionText,
            markerPercent: markerPercent
        )
        result.resetAt = resetAt
        result.observedAt = observedAt
        return result
    }
}
