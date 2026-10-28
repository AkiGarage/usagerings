import Foundation

struct MultiUsageService: Sendable {
    private let cliProxyClient: CLIProxyClient
    private let cliPath: String
    private let commandRunner: CodexUsageService.CommandRunner?
    private let zaiTicketClient: ZaiResetTicketClient?
    private let claudeRateLimitMonitor: ClaudeRateLimitMonitor?

    init(
        cliPath: String = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        commandRunner: CodexUsageService.CommandRunner? = nil,
        cliProxyClient: CLIProxyClient = CLIProxyClient(),
        zaiTicketClient: ZaiResetTicketClient? = nil,
        claudeRateLimitMonitor: ClaudeRateLimitMonitor? = nil
    ) {
        self.cliProxyClient = cliProxyClient
        self.cliPath = cliPath
        self.commandRunner = commandRunner
        self.zaiTicketClient = zaiTicketClient ?? (commandRunner == nil ? .live() : nil)
        self.claudeRateLimitMonitor = claudeRateLimitMonitor ?? (commandRunner == nil ? .live() : nil)
    }

    /// Never throws: a provider that fails anywhere in the chain resolves
    /// to its own section carrying a failure reason, and the other sections
    /// are unaffected.
    func fetchAll(
        now: Date = Date(),
        disabled: Set<ProviderID> = [],
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) async -> MultiUsageSnapshot {
        async let proxySections = cliProxyClient.fetchSections(now: now, skipping: disabled)
        async let codex = fetchProviderUnlessDisabled(.codex, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let zai = fetchProviderUnlessDisabled(.zai, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let minimax = fetchProviderUnlessDisabled(.minimax, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let kimi = fetchProviderUnlessDisabled(.kimi, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let deepseek = fetchProviderUnlessDisabled(.deepseek, disabled: disabled, now: now, timeZone: timeZone, calendar: calendar)
        async let tickets = disabled.contains(.zai) ? nil : zaiTicketClient?.fetch()
        async let blocks = disabled.contains(.claude) ? nil : claudeRateLimitMonitor?.blocks(now: now)
        let (codexResult, zaiResult, proxy, ticketResult, blockResult) = await (codex, zai, proxySections, tickets, blocks)
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
        // The optional ticket reader has no account identity; never attach its
        // default-config inventory to an arbitrary member of a multi-account response.
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

    /// Diagnostics contain structural quota data only, never remote text or account identity.
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
            case .zai, .grok, .claude, .antigravity, .minimax, .kimi, .deepseek:
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
                    failureText: Self.failureText(for: error)
                ),
                codexSnapshot: nil
            )
        }
    }

    private func run(_ provider: ProviderID) async throws -> CodexUsageService.CommandResult {
        let arguments = ["usage", "--provider", provider.rawValue, "--format", "json", "--all-accounts"]
        if let commandRunner {
            return try commandRunner(arguments)
        }
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath))
        let result = try await runner.run(arguments)
        // A single API-key setup (e.g. GLM/zai) has no token accounts; --all-accounts then
        // returns only an error. Fall back to the plain single-account query.
        if provider != .codex, Self.isNoTokenAccounts(result.stdout) {
            return try await runner.run(Array(arguments.dropLast()))
        }
        return result
    }

    static func isNoTokenAccounts(_ stdout: Data) -> Bool {
        guard let rows = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]], !rows.isEmpty else { return false }
        return rows.allSatisfy { (($0["error"] as? [String: Any])?["message"] as? String)?.hasPrefix("No token accounts configured") == true }
    }

    /// Codex windows come from the contract parser; credits and tickets are
    /// the sidecar read of what that parser drops. The parser's snapshot is
    /// also the published artifact.
    /// "完全リセット · 使用可 · 期限 10/23 05:56 · 付与 09/23 05:56 · codex_rate_limits" (calendar's zone = JST on the Air).
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
                section.accounts.append(ProviderAccount(index: index, failureText: Self.failureText(for: error), id: id))
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
            // Machine-readable expiries of usable tickets for the vertical list (ISO 8601, UTC).
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

    /// CodexUsageError descriptions are already sanitized and bounded; the
    /// parser errors carry their own fixed strings.
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
