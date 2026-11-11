import Foundation
import XCTest
import SwiftUI
@testable import CodexUsageWidget

/// Aki t1655u: hidden ticket labels, no 0% stub, single grey bar and 使用不可 while rate-limited.
final class HideTicketsAndBlockedBarTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")!

    func testZeroShareDrawsNoStubButTinyShareStaysVisible() {
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: 0), 0)
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: -0.1), 0)
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: 0.001), 2)
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: 0.5), 100)
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: 1.5), 200)
        XCTAssertEqual(BasisBar.fillWidth(width: 200, share: .nan), 0)
    }

    func testTodayTargetReadsUnavailableWhileBlocked() throws {
        let weekly = UsageLimit(title: "Weekly", leftPercent: 60, resetText: "Resets 10/24 12:00")
        let pace = WeeklyPace(label: "週の枠", limit: weekly, now: now)
        XCTAssertNotNil(pace.todayTarget, "fixture must have a today target")
        XCTAssertEqual(pace.todayText(.used, blocked: true), "今日の目安：使用不可")
        XCTAssertEqual(pace.todayText(.left, blocked: true), "今日の目安：使用不可")
        XCTAssertEqual(pace.todayText(.used, blocked: false), pace.todayText(.used))
        let five = WeeklyPace(label: "5時間枠", limit: UsageLimit(title: "5h", leftPercent: 0, resetText: "Resets 10/21 14:00"),
                              now: now, period: WeeklyPace.fiveHours)
        XCTAssertNil(five.todayText(.used, blocked: true), "5h has no today target")
    }

    func testCodexHoverKeepsOnlyAvailableCount() throws {
        let extras = CodexExtrasParser.Extras(creditsText: nil, availableCount: 3, ticketExpiries: [], tickets: [
            CodexExtrasParser.Ticket(title: "完全リセット", status: "available", resetType: nil, grantedAt: nil,
                                     expiresAt: now.addingTimeInterval(86_400))])
        let bar = CollapsedUsageBar(id: "codex", label: "C", title: "Codex", providerColor: .white,
                                    limit: nil, windows: [], codexExtras: extras)
        let model = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
        XCTAssertEqual(model.extras?.availableCount, 3)
        // t1660u: the expiry line is back, no 完全リセット title, no 使用可.
        XCTAssertEqual(model.extras?.tickets.count, 1)
        XCTAssertNil(model.extras?.tickets.first?.title)
        XCTAssertNil(model.extras?.tickets.first?.statusText)
        XCTAssertTrue(model.extras?.tickets.first?.expiresText?.hasPrefix("期限 ") == true)
        XCTAssertTrue(model.extras?.tickets.first?.expiresText?.hasSuffix(" JST") == true)
    }

    func testZaiWindowTicketLabelIsTicketTypeOnOneLine() {
        let section = ProviderSection(provider: .zai, windows: [], stats: [], zaiResetTickets: .loaded([
            .init(title: "週リセット", available: true, expiresAt: Date().addingTimeInterval(7_200)),
            .init(title: "5時間リセット", available: true, expiresAt: Date().addingTimeInterval(3_600)),
            .init(title: "5時間リセット", available: true, expiresAt: Date().addingTimeInterval(-60)),
        ]))
        let row = ServiceRowModel.rows(for: section)[0]
        XCTAssertEqual(row.ticketTitles, ["5時間リセット", "週リセット"], "sorted with expiries, expired hidden")
        XCTAssertEqual(row.ticketExpiries.count, 2)
        XCTAssertTrue(row.ticketExpiries[0] < row.ticketExpiries[1])
        XCTAssertEqual(TicketList.label(index: 0, titles: row.ticketTitles), "5時間リセット")
        XCTAssertEqual(TicketList.label(index: 1, titles: []), "リセット 2", "Codex keeps its numbered label")
    }

    func testZaiWindowListsOnlyUnexpiredUsableTickets() {
        let section = ProviderSection(provider: .zai, windows: [], stats: [], zaiResetTickets: .loaded([
            .init(title: "5時間リセット", available: true, expiresAt: Date().addingTimeInterval(-60)),
            .init(title: "週リセット", available: true, expiresAt: Date().addingTimeInterval(3_600)),
            .init(title: "5時間リセット", available: false, expiresAt: Date().addingTimeInterval(7_200)),
        ]))
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.first?.ticketExpiries.count, 1)
    }

    func testWindowRingShowsUnlockDateTimeForEveryBlockedRow() {
        let reset = Date().addingTimeInterval(2 * 3600)
        var row = ServiceRowModel(id: "x", name: "X", color: .gray)
        XCTAssertNil(G1Gauge.unlockLines(row))
        row.block = ClaudeBlock(kind: .session, resetAt: reset, timeZoneKnown: true)
        let lines = G1Gauge.unlockLines(row)
        XCTAssertNotNil(lines)
        XCTAssertEqual(lines?.date, ClaudeRateLimitParser.recoveryLines(resetAt: reset).date)
        XCTAssertEqual(lines?.time, ClaudeRateLimitParser.recoveryLines(resetAt: reset).time)
        // Every provider's rows get the same lock as the tab ring.
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        let r = "Resets \(f.string(from: reset))"
        let snap = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [UsageLimit(title: "5h", leftPercent: 0, resetText: r)], stats: [], failureText: nil),
            ProviderSection(provider: .antigravity, windows: [UsageLimit(title: "Gemini 4 Argon · 5h", leftPercent: 0, resetText: r)], stats: [], failureText: nil),
            ProviderSection(provider: .zai, windows: [UsageLimit(title: "5h", leftPercent: 0, resetText: r)], stats: [], failureText: nil),
            ProviderSection(provider: .claude, windows: [UsageLimit(title: "5h", leftPercent: 0, resetText: r)], stats: [], failureText: nil),
        ], codexSnapshot: nil, updatedAt: Date())
        let rows = ServiceRowModel.rows(for: snap)
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        for row in rows { XCTAssertNotNil(G1Gauge.unlockLines(row), row.name) }
    }

    @MainActor
    func testLockedWindowRingRendersDifferentlyFromUnlocked() throws {
        var row = ServiceRowModel(id: "x", name: "X", color: .gray)
        let open = try XCTUnwrap(ImageRenderer(content: G1Gauge(row: row, size: 60)).nsImage?.tiffRepresentation)
        row.block = ClaudeBlock(kind: .session, resetAt: Date().addingTimeInterval(7200), timeZoneKnown: true)
        let locked = try XCTUnwrap(ImageRenderer(content: G1Gauge(row: row, size: 60)).nsImage?.tiffRepresentation)
        XCTAssertNotEqual(open, locked, "lock icon + unlock lines must change the ring")
    }

    func testNoBlockLeavesEveryWindowUnlocked() {
        let row = ServiceRowModel(id: "x", name: "X", color: .gray)
        XCTAssertFalse(row.isLockedOut(UsageLimit(title: "5h", leftPercent: 0, resetText: "")))
        XCTAssertFalse(row.isLockedOut(UsageLimit(title: "Weekly", leftPercent: 40, resetText: "")))
    }

    func testSessionLockGraysOnlyTheFiveHourWindow() {
        var row = ServiceRowModel(id: "x", name: "X", color: .gray)
        row.block = ClaudeBlock(kind: .session, resetAt: Date().addingTimeInterval(3600), timeZoneKnown: true)
        XCTAssertTrue(row.isLockedOut(UsageLimit(title: "5h", leftPercent: 0, resetText: "")))
        XCTAssertFalse(row.isLockedOut(UsageLimit(title: "Weekly", leftPercent: 40, resetText: "")))
        XCTAssertTrue(row.isLockedOut(UsageLimit(title: "MCP", leftPercent: 0, resetText: "")))
    }

    func testWeeklyLockGraysEveryWindow() {
        var row = ServiceRowModel(id: "x", name: "X", color: .gray)
        row.block = ClaudeBlock(kind: .weekly, resetAt: Date().addingTimeInterval(3600), timeZoneKnown: true)
        XCTAssertTrue(row.isLockedOut(UsageLimit(title: "5h", leftPercent: 0, resetText: "")))
        XCTAssertTrue(row.isLockedOut(UsageLimit(title: "Weekly", leftPercent: 0, resetText: "")))
    }

    func testGeminiMenuTitleHasNoChromeTabSuffix() {
        XCTAssertEqual(AppDelegate.geminiReadingMenuTitle, "Gemini の使用量を読む")
    }

    func testHeaderDropsBasisCaptionAndEnlargesControls() {
        XCTAssertEqual(UsageModeControls.captions, ["表示"], "no 基準 caption (t1662u)")
        let scale = MultiPanelContent.headerControlFontSize / 11
        XCTAssertTrue((1.2...1.3).contains(scale), "\(scale)")
    }
}
