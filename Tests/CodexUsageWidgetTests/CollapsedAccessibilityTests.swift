import XCTest
@testable import CodexUsageWidget

final class CollapsedAccessibilityTests: XCTestCase {
    func testSummaryMatchesDisplayedArcsInsteadOfLowestWindow() throws {
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [
                UsageLimit(title: "5h", leftPercent: 78, resetText: "Resets 15:10"),
                UsageLimit(title: "Weekly", leftPercent: 27, resetText: "Resets 10/25 07:03")
            ], stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: Date())
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "codex" })
        XCTAssertEqual(bar.limit?.percentInt, 27)
        XCTAssertEqual(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: ServiceRowModel.rows(for: snapshot)),
                       "Codex: 5h: 78% left, Resets 15:10; Weekly: 27% left, Resets 10/25 07:03")
    }

    func testWeeklyOnlyAccountDoesNotAnnounceFiveHourQuota() throws {
        var weekly = UsageLimit(title: "Weekly", leftPercent: 0, resetText: "Resets tomorrow")
        weekly.accountIndex = 0
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .claude, windows: [weekly], stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: Date())
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "claude-0" })
        XCTAssertEqual(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: ServiceRowModel.rows(for: snapshot)),
                       "Claude A: Weekly: 0% left, Resets tomorrow")
    }

    func testMissingQuotaDoesNotAnnounceZero() throws {
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: .placeholder).first)
        XCTAssertEqual(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: []), "Codex: No data")
    }

    func testBlockedAccountAnnouncesRecoveryInsteadOfCachedPercent() {
        let bar = CollapsedUsageBar(id: "claude-0", label: "A", title: "Claude A 5h",
                                    providerColor: .orange,
                                    limit: UsageLimit(title: "5h", leftPercent: 80, resetText: "Resets soon"),
                                    block: ClaudeBlock(kind: .session, resetAt: Date().addingTimeInterval(3600),
                                                       timeZoneKnown: true))
        let text = MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: [])
        XCTAssertTrue(text.hasPrefix("Claude A: "))
        XCTAssertFalse(text.contains("80%"))
        XCTAssertTrue(text.contains("制限中"))
        XCTAssertTrue(text.contains("復帰"))
    }
}
