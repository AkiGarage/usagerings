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

    static let remoteClaudeStatTitle = "Remote Claude logs"

    /// Never throws: a provider that fails anywhere in the chain resolves
    /// to its own section carrying a failure reason, and the other sections
    /// are unaffected.
    func fetchAll(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) async -> MultiUsageSnapshot {
        async let proxySections = cliProxyClient.fetchSections(now: now)
        async let codex = fetchProvider(.codex, now: now, timeZone: timeZone, calendar: calendar)
        async let zai = fetchProvider(.zai, now: now, timeZone: timeZone, calendar: calendar)
        async let tickets = zaiTicketClient?.fetch()
        async let blocks = claudeRateLimitMonitor?.blocks(now: now)
        let (codexResult, zaiResult, proxy, ticketResult, blockResult) = await (codex, zai, proxySections, tickets, blocks)
        let sshFailure = await claudeRateLimitMonitor?.remoteFailureText()
        let proxyWithBlocks = proxy.map { section in
            var section = section
            if section.provider == .claude {
                section.claudeBlocks = blockResult ?? [:]
                if let sshFailure {
                    section.stats.append(ProviderStat(title: Self.remoteClaudeStatTitle, valueText: sshFailure))
                }
            }
            return section
        }
        var zaiSection = zaiResult.section
        zaiSection.zaiResetTickets = ticketResult
        Self.writeWindowDump([codexResult.section, zaiSection] + proxyWithBlocks)
        return MultiUsageSnapshot(
            sections: MultiUsageSnapshot.ordered([codexResult.section, zaiSection] + proxyWithBlocks),
            codexSnapshot: codexResult.codexSnapshot,
            updatedAt: now
        )
    }

    /// Writes provider/title/percent (titles are already account-masked) so field mapping can be checked.
    private static func writeWindowDump(_ sections: [ProviderSection]) {
        guard Bundle.main.bundleIdentifier != nil, NSClassFromString("XCTestCase") == nil else { return }
        let rows: [[String: Any]] = sections.flatMap { section in
            section.windows.map { ["provider": section.provider.rawValue, "title": $0.title,
                                   "left": $0.leftPercent, "reset": $0.resetText] }
            + section.stats.map { ["provider": section.provider.rawValue, "stat": $0.title] }
        }
        guard let url = PrivateTempPaths.file("codex-usage-widget-panel-windows.json"),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) else { return }
        PrivateTempPaths.writePrivately(data, to: url)
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
            case .zai, .grok, .claude, .antigravity:
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
        let arguments = ["usage", "--provider", provider.rawValue, "--format", "json"]
        if let commandRunner {
            return try commandRunner(arguments)
        }
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath))
        return try await runner.run(arguments)
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
        UsageLimit(
            title: title,
            leftPercent: leftPercent,
            resetText: resetText,
            detailText: detailText,
            projectionText: projectionText,
            markerPercent: markerPercent
        )
    }
}
