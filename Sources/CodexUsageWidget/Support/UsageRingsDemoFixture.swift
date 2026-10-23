import Foundation

/// Fictional, stable quota values that exercise every UsageRings provider UI.
/// Deadlines are based on one captured `now`, so refreshes keep the same data.
enum UsageRingsDemoFixture {
    static let shrinkDuration: TimeInterval = 8
    static let shrinkLimitAt: TimeInterval = 8.45
    static let dummy8RingIDs: Set<String> = [
        "codex", "claude-0", "claude-1", "grok", "zai", "kimi", "deepseek",
        "antigravity-Gemini Models"
    ]

    static func snapshot(now: Date = Date()) -> MultiUsageSnapshot {
        let timeZone = RingResetFormat.tokyo

        func limit(_ title: String, _ percent: Double, resetIn hours: Double) -> UsageLimit {
            UsageLimit(title: title, leftPercent: percent,
                       resetText: UsageDurationFormat.resetText(
                        for: now.addingTimeInterval(hours * 3_600), now: now, timeZone: timeZone))
        }

        func accountLimit(_ title: String, _ percent: Double, resetIn hours: Double,
                          account: Int) -> UsageLimit {
            var value = limit(title, percent, resetIn: hours)
            value.accountIndex = account
            return value
        }

        let codexExtras = CodexExtrasParser.Extras(
            creditsText: "1,284 credits",
            availableCount: 2,
            ticketExpiries: [now.addingTimeInterval(18 * 3_600), now.addingTimeInterval(6 * 86_400)],
            tickets: [
                CodexExtrasParser.Ticket(title: "5時間リセット", status: "available", resetType: "five_hour",
                                         grantedAt: now.addingTimeInterval(-86_400),
                                         expiresAt: now.addingTimeInterval(18 * 3_600)),
                CodexExtrasParser.Ticket(title: "週リセット", status: "available", resetType: "weekly",
                                         grantedAt: now.addingTimeInterval(-2 * 86_400),
                                         expiresAt: now.addingTimeInterval(6 * 86_400)),
                CodexExtrasParser.Ticket(title: "前回リセット", status: "used", resetType: "five_hour",
                                         grantedAt: now.addingTimeInterval(-5 * 86_400),
                                         expiresAt: now.addingTimeInterval(-3 * 86_400))
            ],
            ticketsUpdatedAt: now,
            maskedAccount: nil
        )
        let codexSnapshot = UsageSnapshot(
            session: limit("Session", 76, resetIn: 2.4),
            weekly: limit("Weekly", 49, resetIn: 94),
            updatedAt: now
        )

        let zaiTickets: [ZaiResetTickets.Ticket] = [
            .init(title: "5時間リセット", available: true, expiresAt: now.addingTimeInterval(11 * 3_600)),
            .init(title: "週リセット", available: true, expiresAt: now.addingTimeInterval(5 * 86_400)),
            .init(title: "5時間リセット", available: false, expiresAt: now.addingTimeInterval(2 * 86_400))
        ]
        let ticketCalendar = RingResetFormat.tokyoCalendar
        let zaiStats = [
            ProviderStat(title: "Reset tickets", valueText: "2 available"),
            ProviderStat(title: "Reset ticket", valueText: "5時間リセット · 使用可 · 期限 \(UsageDurationFormat.timestamp(zaiTickets[0].expiresAt, now: now, calendar: ticketCalendar)) JST"),
            ProviderStat(title: "Reset ticket", valueText: "週リセット · 使用可 · 期限 \(UsageDurationFormat.timestamp(zaiTickets[1].expiresAt, now: now, calendar: ticketCalendar)) JST"),
            ProviderStat(title: "Reset ticket", valueText: "5時間リセット · 使用不可 · 期限 \(UsageDurationFormat.timestamp(zaiTickets[2].expiresAt, now: now, calendar: ticketCalendar)) JST")
        ]

        let sections = [
            ProviderSection(provider: .codex,
                            windows: [accountLimit("Session", 76, resetIn: 2.4, account: 0),
                                      accountLimit("Weekly", 49, resetIn: 94, account: 0),
                                      accountLimit("Session", 61, resetIn: 1.2, account: 1),
                                      accountLimit("Weekly", 83, resetIn: 116, account: 1)],
                            stats: [ProviderStat(title: "Credits", valueText: "1,284 credits"),
                                    ProviderStat(title: "Reset tickets", valueText: "2 available")]
                                + codexExtras.ticketExpiries.map {
                                    ProviderStat(title: "Reset ticket expiry",
                                                 valueText: ISO8601DateFormatter().string(from: $0))
                                },
                            failureText: nil,
                            accounts: [ProviderAccount(index: 0, codexExtras: codexExtras),
                                       ProviderAccount(index: 1)]),
            ProviderSection(provider: .claude,
                            windows: [accountLimit("5h", 28, resetIn: 3, account: 0),
                                      accountLimit("Weekly", 58, resetIn: 86, account: 0),
                                      accountLimit("5h", 14, resetIn: 2, account: 1),
                                      accountLimit("Weekly", 34, resetIn: 69, account: 1)],
                            stats: [], failureText: nil,
                            claudeProfileBlocks: [1: ClaudeBlock(kind: .session,
                                                          resetAt: now.addingTimeInterval(2 * 3_600),
                                                          timeZoneKnown: true)]),
            ProviderSection(provider: .grok,
                            windows: [accountLimit("Weekly", 68, resetIn: 120, account: 0),
                                      accountLimit("Weekly", 41, resetIn: 96, account: 1)],
                            stats: [], failureText: nil),
            ProviderSection(provider: .zai,
                            windows: [limit("5h", 82, resetIn: 2.8), limit("Weekly", 64, resetIn: 112)],
                            stats: zaiStats, failureText: nil,
                            zaiResetTickets: .loaded(zaiTickets)),
            ProviderSection(provider: .minimax,
                            windows: [limit("Weekly", 72, resetIn: 103)],
                            stats: [], failureText: nil),
            ProviderSection(provider: .kimi,
                            windows: [limit("Weekly", 56, resetIn: 89)],
                            stats: [], failureText: nil),
            ProviderSection(provider: .deepseek, windows: [],
                            stats: [ProviderStat(title: "Balance", valueText: "$23.50 (Paid: $20.00 / Granted: $3.50)"),
                                    ProviderStat(title: "Today", valueText: "$0.12 · 12,000 tokens")],
                            failureText: nil),
            ProviderSection(provider: .antigravity,
                            windows: [accountLimit("Gemini 4 Argon · 5h", 87, resetIn: 4, account: 0),
                                      accountLimit("Gemini 4 Argon · Weekly", 73, resetIn: 102, account: 0),
                                      accountLimit("Gemini Models · 5h", 18, resetIn: 3, account: 0),
                                      accountLimit("Gemini Models · Weekly", 52, resetIn: 98, account: 0),
                                      accountLimit("Claude and GPT models · 5h", 38, resetIn: 2, account: 0),
                                      accountLimit("Claude and GPT models · Weekly", 27, resetIn: 73, account: 0),
                                      accountLimit("Gemini 4 Argon · 5h", 64, resetIn: 3.5, account: 1),
                                      accountLimit("Gemini 4 Argon · Weekly", 44, resetIn: 118, account: 1),
                                      accountLimit("Gemini Models · 5h", 69, resetIn: 1.5, account: 1),
                                      accountLimit("Gemini Models · Weekly", 81, resetIn: 110, account: 1),
                                      accountLimit("Claude and GPT models · 5h", 57, resetIn: 2.5, account: 1),
                                      accountLimit("Claude and GPT models · Weekly", 62, resetIn: 132, account: 1)],
                            stats: [], failureText: nil)
        ]

        return MultiUsageSnapshot(sections: sections, codexSnapshot: codexSnapshot, updatedAt: now)
    }

    /// Eight actual collapsed rings for a safe recording fixture; no provider clients are involved.
    static func dummy8Snapshot(now: Date = Date()) -> MultiUsageSnapshot {
        let timeZone = RingResetFormat.tokyo
        func limit(_ title: String, _ percent: Double, resetIn hours: Double) -> UsageLimit {
            let resetAt = now.addingTimeInterval(hours * 3_600)
            var value = UsageLimit(title: title, leftPercent: percent,
                                   resetText: UsageDurationFormat.resetText(for: resetAt, now: now, timeZone: timeZone))
            value.resetAt = resetAt
            return value
        }
        func accountLimit(_ title: String, _ percent: Double, resetIn hours: Double,
                          account: Int) -> UsageLimit {
            var value = limit(title, percent, resetIn: hours)
            value.accountIndex = account
            return value
        }

        let codex = ProviderSection(provider: .codex,
                                    windows: [accountLimit("Session", 76, resetIn: 2.4, account: 0),
                                              accountLimit("Weekly", 49, resetIn: 94, account: 0)],
                                    stats: [], failureText: nil)
        let claude = ProviderSection(provider: .claude,
                                     windows: [accountLimit("5h", 62, resetIn: 3, account: 0),
                                               accountLimit("Weekly", 58, resetIn: 86, account: 0),
                                               accountLimit("5h", 0, resetIn: 2, account: 1),
                                               accountLimit("Weekly", 34, resetIn: 69, account: 1)],
                                     stats: [], failureText: nil)
        let grok = ProviderSection(provider: .grok,
                                   windows: [accountLimit("Weekly", 68, resetIn: 120, account: 0)],
                                   stats: [], failureText: nil)
        let zai = ProviderSection(provider: .zai,
                                  windows: [limit("5h", 82, resetIn: 2.8), limit("Weekly", 64, resetIn: 112)],
                                  stats: [], failureText: nil)
        let kimi = ProviderSection(provider: .kimi,
                                   windows: [limit("Weekly", 56, resetIn: 89)], stats: [], failureText: nil)
        let deepseek = ProviderSection(provider: .deepseek, windows: [limit("Weekly", 74, resetIn: 24)],
                                       stats: [ProviderStat(title: "Balance", valueText: "$23.50")],
                                       failureText: nil)
        let antigravity = ProviderSection(provider: .antigravity,
                                          windows: [accountLimit("Gemini Models · 5h", 72, resetIn: 4, account: 0),
                                                    accountLimit("Gemini Models · Weekly", 53, resetIn: 102, account: 0)],
                                          stats: [], failureText: nil)
        let codexSnapshot = UsageSnapshot(session: limit("Session", 76, resetIn: 2.4),
                                          weekly: limit("Weekly", 49, resetIn: 94), updatedAt: now)
        return MultiUsageSnapshot(sections: [codex, claude, grok, zai, kimi, deepseek, antigravity],
                                  codexSnapshot: codexSnapshot, updatedAt: now,
                                  visibleRingIDs: dummy8RingIDs)
    }

    /// Updates only Claude A's model value, holds at 9%, then reaches its real exhausted state.
    static func shrunkDummy8Snapshot(base: MultiUsageSnapshot, elapsed: TimeInterval,
                                     now: Date = Date()) -> MultiUsageSnapshot {
        let progress = min(max(elapsed / shrinkDuration, 0), 1)
        let percent = elapsed >= shrinkLimitAt ? 0 : 62 + (9 - 62) * progress
        let sections = base.sections.map { section -> ProviderSection in
            guard section.provider == .claude else { return section }
            var updated = section
            updated.windows = section.windows.map { window in
                guard window.accountIndex == 0, ServiceRowModel.kind(window.title) == .five else { return window }
                var value = UsageLimit(title: window.title, leftPercent: percent,
                                       resetText: window.resetAt.map {
                                        UsageDurationFormat.resetText(for: $0, now: now, timeZone: RingResetFormat.tokyo)
                                       } ?? window.resetText,
                                       detailText: window.detailText, projectionText: window.projectionText,
                                       markerPercent: window.markerPercent)
                value.accountIndex = window.accountIndex
                value.resetAt = window.resetAt
                return value
            }
            return updated
        }
        return MultiUsageSnapshot(sections: sections, codexSnapshot: base.codexSnapshot, updatedAt: now,
                                  hiddenProviders: base.hiddenProviders, visibleRingIDs: base.visibleRingIDs)
    }

    /// Keep Antigravity's provider-specific group in the card title while the
    /// production card rows show the quota period without repeating that group.
    static func detailCardBar(for bar: CollapsedUsageBar) -> CollapsedUsageBar {
        guard bar.id.hasPrefix("antigravity-") else { return bar }

        func periodOnly(_ limit: UsageLimit) -> UsageLimit {
            let title: String
            switch ServiceRowModel.kind(limit.title) {
            case .five: title = "5h"
            case .week: title = "Weekly"
            case .other: return limit
            }
            var value = UsageLimit(title: title, leftPercent: limit.leftPercent,
                                   resetText: limit.resetText, detailText: limit.detailText,
                                   projectionText: limit.projectionText, markerPercent: limit.markerPercent)
            value.accountIndex = limit.accountIndex
            return value
        }

        return CollapsedUsageBar(id: bar.id, label: bar.label, title: bar.title,
                                 providerColor: bar.providerColor,
                                 limit: bar.limit.map(periodOnly),
                                 windows: bar.windows.map(periodOnly),
                                 codexExtras: bar.codexExtras,
                                 zaiResetTickets: bar.zaiResetTickets,
                                 block: bar.block,
                                 blockedSymbolName: bar.blockedSymbolName,
                                 stats: bar.stats, failureText: bar.failureText)
    }
}
