import XCTest
@testable import CodexUsageWidget

final class UsageAccessibilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPanelWindowUsesVisibleLabelWhenAccountNamesAreHidden() throws {
        let section = ProviderSection(provider: .claude, windows: [
            UsageLimit(title: "masked*** · 5h", leftPercent: 78, resetText: "Resets 15:10"),
            UsageLimit(title: "masked*** · Monthly", leftPercent: 42, resetText: "Resets 11/20 09:00")
        ], stats: [], failureText: nil)
        let row = try XCTUnwrap(ServiceRowModel.rows(for: section, showAccounts: false).first)
        XCTAssertNil(row.account)
        let five = try XCTUnwrap(row.five)
        let simple = row.windowAccessibility(label: "5h", limit: five)
        XCTAssertEqual(simple, .init(label: "Claude A, 5h", value: "残り 78%、リセット 15:10"))
        let extra = try XCTUnwrap(row.extras.first)
        let detail = row.windowAccessibility(label: ServiceRowModel.shortLabel(extra.title), limit: extra)
        XCTAssertEqual(detail, .init(label: "Claude A, 月", value: "残り 42%、リセット 11/20 09:00"))
        for reading in [simple, detail] {
            XCTAssertFalse(reading.summary.contains("masked"))
        }
    }

    func testWindowNamesProviderAccountAndFullWindowWithoutLosingReset() {
        let limit = UsageLimit(title: "Opus Weekly", leftPercent: 27.4, resetText: "Resets 11/20 09:00",
                               detailText: "Shared quota", projectionText: "At current pace")
        let reading = UsageAccessibility.window(provider: "Claude B", title: limit.title, limit: limit)
        XCTAssertEqual(reading.label, "Claude B, Opus Weekly")
        XCTAssertEqual(reading.value, "残り 27%、残量注意、リセット 11/20 09:00、Shared quota、At current pace")
    }

    func testPercentIsClampedAndMissingWindowIsNotZero() {
        for (percent, expected) in [(-10.0, "残り 0%、残量わずか"), (120.0, "残り 100%"), (78.6, "残り 79%")] {
            let limit = UsageLimit(title: "Monthly", leftPercent: percent, resetText: "Unknown")
            XCTAssertEqual(UsageAccessibility.window(provider: "Grok", title: limit.title, limit: limit).value,
                           "\(expected)、リセット Unknown")
        }
        XCTAssertEqual(UsageAccessibility.window(provider: "Codex", title: "5h", limit: nil),
                       .init(label: "Codex, 5h", value: "枠なし"))
    }

    func testLockedWindowDoesNotAdvertiseCachedAvailablePercent() {
        let limit = UsageLimit(title: "5h", leftPercent: 80, resetText: "Resets 11/20 09:00")
        XCTAssertEqual(UsageAccessibility.window(provider: "Claude A", title: limit.title, limit: limit, blocked: true).value,
                       "使用不可、リセット 11/20 09:00")
    }

    func testNonColorCuesFollowExistingToneBoundaries() {
        for percent in [0.0, 19.9, 20, 34.9, 35, 100] {
            let tone = UsageLimit(title: "5h", leftPercent: percent, resetText: "Unknown").tone
            let symbol = UsageAccessibility.statusSymbol(tone)
            let text = UsageAccessibility.statusText(tone)
            XCTAssertEqual(UsageAccessibility.statusSymbol(leftPercent: percent), symbol)
            if percent < 20 {
                XCTAssertEqual(symbol, "exclamationmark.triangle.fill")
                XCTAssertEqual(text, "残量わずか")
            } else if percent < 35 {
                XCTAssertEqual(symbol, "exclamationmark.circle")
                XCTAssertEqual(text, "残量注意")
            } else {
                XCTAssertNil(symbol)
                XCTAssertNil(text)
            }
        }
    }

    func testRingLabelAndValueMatchBothDisplayedArcs() throws {
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [
                UsageLimit(title: "5h", leftPercent: 78, resetText: "Resets 15:10"),
                UsageLimit(title: "Weekly", leftPercent: 27, resetText: "Resets 11/20 09:00")
            ], stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: now)
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "codex" })
        let reading = UsageAccessibility.ring(bar: bar, rows: ServiceRowModel.rows(for: snapshot), now: now)
        XCTAssertEqual(reading.label, "Codex")
        XCTAssertEqual(reading.value, "5h: 78% left, Resets 15:10; Weekly: 27% left, Resets 11/20 09:00")
    }

    func testRingLockUsesSuppliedClockAndRetainsStaleNotice() {
        var bar = CollapsedUsageBar(id: "claude-0", label: "A", title: "Claude A 5h", providerColor: .orange,
                                    limit: UsageLimit(title: "5h", leftPercent: 80, resetText: "Resets later"),
                                    block: ClaudeBlock(kind: .session, resetAt: now.addingTimeInterval(3600), timeZoneKnown: true))
        bar.isStale = true
        bar.failureText = "Stale reading"
        let locked = UsageAccessibility.ring(bar: bar, rows: [], now: now)
        XCTAssertEqual(locked.label, "Claude A")
        XCTAssertTrue(locked.value.hasPrefix("Stale reading; "))
        XCTAssertTrue(locked.value.contains("制限中"))
        XCTAssertFalse(locked.value.contains("80%"))
        XCTAssertEqual(UsageAccessibility.ring(bar: bar, rows: [], now: now.addingTimeInterval(3601)).value,
                       "Stale reading; 5h: 80% left, Resets later")
    }

    func testRingMissingAndFailureValuesStayDistinctFromZero() {
        var bar = CollapsedUsageBar(id: "codex", label: "C", title: "Codex", providerColor: .blue, limit: nil)
        XCTAssertEqual(UsageAccessibility.ring(bar: bar, rows: [], now: now).value, "No data")
        bar.failureText = "Usage unavailable"
        XCTAssertEqual(UsageAccessibility.ring(bar: bar, rows: [], now: now).value, "Usage unavailable")
    }

    func testDetailedPaceIncludesResetAndUsesBlockedTodayWording() {
        var limit = UsageLimit(title: "Weekly", leftPercent: 70, resetText: "Unknown")
        limit.resetAt = now.addingTimeInterval(86_400)
        let pace = WeeklyPace(label: "週の枠", limit: limit, now: now)
        for basis in UsageBasis.allCases {
            let normal = WeeklyPaceBar.accessibilityValue(pace: pace, basis: basis, blocked: false)
            XCTAssertTrue(normal.hasPrefix(pace.valueText(basis)))
            XCTAssertTrue(normal.contains(pace.resetStatusText))
            XCTAssertTrue(normal.contains(pace.todayText(basis)!))
            let locked = WeeklyPaceBar.accessibilityValue(pace: pace, basis: basis, blocked: true)
            XCTAssertTrue(locked.hasPrefix("使用不可、"))
            XCTAssertTrue(locked.contains("今日の目安：使用不可"))
            XCTAssertFalse(locked.contains("70%"))
            XCTAssertFalse(locked.contains(pace.paceText(basis)))
        }
    }
}
