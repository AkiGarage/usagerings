import Foundation

/// Fictional, stable quota values that exercise every UsageRings provider UI.
/// Deadlines are based on one captured `now`, so refreshes keep the same data.
enum UsageRingsDemoFixture {
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
                            windows: [limit("Session", 76, resetIn: 2.4), limit("Weekly", 49, resetIn: 94)],
                            stats: [ProviderStat(title: "Credits", valueText: "1,284 credits"),
                                    ProviderStat(title: "Reset tickets", valueText: "2 available")]
                                + codexExtras.ticketExpiries.map {
                                    ProviderStat(title: "Reset ticket expiry",
                                                 valueText: ISO8601DateFormatter().string(from: $0))
                                },
                            failureText: nil,
                            codexExtras: codexExtras),
            ProviderSection(provider: .claude,
                            windows: [accountLimit("5h", 28, resetIn: 3, account: 0),
                                      accountLimit("Weekly", 58, resetIn: 86, account: 0),
                                      accountLimit("5h", 14, resetIn: 2, account: 1),
                                      accountLimit("Weekly", 34, resetIn: 69, account: 1)],
                            stats: [], failureText: nil,
                            claudeBlocks: [1: ClaudeBlock(kind: .session,
                                                          resetAt: now.addingTimeInterval(2 * 3_600),
                                                          timeZoneKnown: true)]),
            ProviderSection(provider: .grok,
                            windows: [limit("Weekly", 68, resetIn: 120)],
                            stats: [], failureText: nil),
            ProviderSection(provider: .zai,
                            windows: [limit("5h", 82, resetIn: 2.8), limit("Weekly", 64, resetIn: 112)],
                            stats: zaiStats, failureText: nil,
                            zaiResetTickets: .loaded(zaiTickets)),
            ProviderSection(provider: .antigravity,
                            windows: [limit("Gemini 4 Argon · 5h", 87, resetIn: 4),
                                      limit("Gemini 4 Argon · Weekly", 73, resetIn: 102),
                                      limit("Gemini Models · 5h", 18, resetIn: 3),
                                      limit("Gemini Models · Weekly", 52, resetIn: 98),
                                      limit("Claude and GPT models · 5h", 38, resetIn: 2),
                                      limit("Claude and GPT models · Weekly", 27, resetIn: 73)],
                            stats: [], failureText: nil)
        ]

        return MultiUsageSnapshot(sections: sections, codexSnapshot: codexSnapshot, updatedAt: now)
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
                                 blockedSymbolName: bar.blockedSymbolName)
    }
}
