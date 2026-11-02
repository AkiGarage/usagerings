import Foundation
import os

struct MultiUsageService: Sendable {
    private let cliPath: String
    private let commandRunner: CodexUsageService.CommandRunner?
    private let zaiTicketClient: ZaiResetTicketClient?
    private let claudeRateLimitMonitor: ClaudeRateLimitMonitor?
    private let claudeCLI: ClaudeCLIUsage?

    init(
        cliPath: String = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        commandRunner: CodexUsageService.CommandRunner? = nil,
        zaiTicketClient: ZaiResetTicketClient? = nil,
        claudeRateLimitMonitor: ClaudeRateLimitMonitor? = nil,
        claudeCLI: ClaudeCLIUsage? = nil
    ) {
        self.cliPath = cliPath
        self.commandRunner = commandRunner
        self.zaiTicketClient = zaiTicketClient ?? (commandRunner == nil ? .live() : nil)
        self.claudeRateLimitMonitor = claudeRateLimitMonitor ?? (commandRunner == nil ? .live() : nil)
        self.claudeCLI = claudeCLI ?? (commandRunner == nil ? Self.sharedClaudeCLI(cliPath) : nil)
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
        async let tickets = disabled.contains(.zai) ? nil : zaiTicketClient?.fetch()
        async let blocks = disabled.contains(.claude) ? nil : claudeRateLimitMonitor?.blocks(now: now)
        let (codexResult, zaiResult, ticketResult, blockResult) = await (codex, zai, tickets, blocks)
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
        let additional = await [minimax.section, kimi.section, deepseek.section]
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

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "CodexBarCLI timed out"
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

    private func fetchProvider(
        _ provider: ProviderID,
        now: Date,
        timeZone: TimeZone,
        calendar: Calendar
    ) async -> ProviderResult {
        do {
            let result = try await run(provider)
            if result.timedOut {
                throw ProviderFailure.timedOut
            }
            if provider == .codex, result.terminationStatus != 0,
               let partial = try? codexResult(from: result.stdout, now: now, timeZone: timeZone, calendar: calendar),
               partial.section.accounts.count > 1, !partial.section.windows.isEmpty,
               partial.section.accounts.contains(where: { $0.failureText != nil }) {
                return partial
            }
            if provider != .codex, result.terminationStatus != 0,
               let partial = try? MultiProviderParser.parse(result.stdout, provider: provider, now: now, timeZone: timeZone),
               partial.accounts.count > 1, partial.accounts.contains(where: { $0.failureText != nil }),
               !partial.windows.isEmpty || !partial.stats.isEmpty {
                return ProviderResult(provider: provider, section: partial, codexSnapshot: nil)
            }
            guard result.terminationStatus == 0 else {
                throw CodexUsageError.commandFailure(
                    exitCode: result.terminationStatus,
                    stdout: result.stdout,
                    stderr: result.stderr
                )
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
            }
        } catch {
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

    private func run(_ provider: ProviderID) async throws -> CodexUsageService.CommandResult {
        let arguments = ["usage", "--provider", provider.rawValue, "--format", "json"] + Self.sourceArguments(provider) + ["--all-accounts"]
        var retried = false
        func attempt(_ arguments: [String]) async throws -> CodexUsageService.CommandResult {
            while true {
                try Task.checkCancellation()
                do {
                    let result: CodexUsageService.CommandResult
                    if let commandRunner {
                        result = try commandRunner(arguments)
                    } else {
                        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath), timeout: 30)
                        result = try await runner.run(arguments)
                    }
                    if result.timedOut && !retried { retried = true; continue }
                    return result
                } catch let error as CodexUsageError {
                    if case .commandFailed(-1, _) = error, !retried { retried = true; continue }
                    throw error
                }
            }
        }
        let result = try await attempt(arguments)
        if provider != .codex, Self.isNoTokenAccounts(result.stdout) {
            return try await attempt(Array(arguments.dropLast()))
        }
        return result
    }

    static func sourceArguments(_ provider: ProviderID) -> [String] {
        switch provider {
        case .antigravity, .grok, .claude: ["--source", "cli"]
        case .codex, .zai, .minimax, .kimi, .deepseek, .gemini: []
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

    private static func failureReason(for error: Error) -> UsageFailureReason {
        if case ProviderFailure.timedOut = error { return .timeout }
        if case CodexUsageError.commandFailed(-1, _) = error { return .launchFailure }
        return .other
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
