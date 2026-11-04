import XCTest
@testable import CodexUsageWidget

final class RecoveryCountdownTests: XCTestCase {
    let fetchedMidMinute = Date(timeIntervalSince1970: 1_800_000_037)

    func untouchedWindow(_ title: String, period: TimeInterval) -> UsageLimit {
        var limit = UsageLimit(title: title, leftPercent: 100, resetText: "")
        limit.resetAt = fetchedMidMinute.addingTimeInterval(period)
        return limit
    }

    func testUntouchedAntigravityFiveHourWindowKeepsColour() {
        let pace = WeeklyPace(label: "5時間枠", limit: untouchedWindow("Gemini Models · Five Hour Limit Remaining", period: WeeklyPace.fiveHours),
                              now: fetchedMidMinute, period: WeeklyPace.fiveHours)
        XCTAssertNotEqual(pace.tone, .unknown)
        XCTAssertNil(pace.unknownReason)
    }

    func testUntouchedAntigravityWeeklyWindowKeepsColour() {
        let pace = WeeklyPace(label: "週の枠", limit: untouchedWindow("Claude and GPT models · Weekly Limit Remaining", period: WeeklyPace.week),
                              now: fetchedMidMinute)
        XCTAssertNotEqual(pace.tone, .unknown)
        XCTAssertNil(pace.unknownReason)
    }

    func testServerClockAheadByAFewSecondsStillKnown() {
        var limit = untouchedWindow("Weekly", period: WeeklyPace.week)
        limit.resetAt = limit.resetAt!.addingTimeInterval(30)
        XCTAssertNotEqual(WeeklyPace(label: "週の枠", limit: limit, now: fetchedMidMinute).tone, .unknown)
    }

    func testResetFarBeyondTheWindowIsStillUnknown() {
        var limit = untouchedWindow("Weekly", period: WeeklyPace.week)
        limit.resetAt = limit.resetAt!.addingTimeInterval(3600)
        XCTAssertEqual(WeeklyPace(label: "週の枠", limit: limit, now: fetchedMidMinute).tone, .unknown)
    }

    func testFiveHourTextCarriesDateAndTime() {
        let now = date(2026, 11, 4, 9, 52)
        XCTAssertEqual(WeeklyPace.recoverText(reset: date(2026, 11, 4, 11, 30), now: now), "あと1時間38分で回復（11/4 11:30 JST）")
        XCTAssertEqual(WeeklyPace.recoverText(reset: date(2026, 11, 4, 10, 0), now: now), "あと8分で回復（11/4 10:00 JST）")
    }

    func testWeeklyTextUsesDaysHoursMinutes() {
        let now = date(2026, 11, 4, 9, 52)
        XCTAssertEqual(WeeklyPace.recoverText(reset: date(2026, 11, 5, 2, 0), now: now), "あと16時間8分で回復（11/5 02:00 JST）")
        XCTAssertEqual(WeeklyPace.recoverText(reset: date(2026, 11, 9, 20, 38), now: now), "あと5日10時間46分で回復（11/9 20:38 JST）")
        XCTAssertEqual(WeeklyPace.recoverText(reset: date(2026, 11, 6, 9, 55), now: now), "あと2日0時間3分で回復（11/6 09:55 JST）")
    }

    func testWeeklyPaceShowsRecoveryInsteadOfPeriod() {
        let now = date(2026, 11, 4, 9, 52)
        var weekly = UsageLimit(title: "Weekly", leftPercent: 73, resetText: "")
        weekly.resetAt = date(2026, 11, 5, 2, 0)
        let pace = WeeklyPace(label: "週の枠", limit: weekly, now: now)
        XCTAssertEqual(pace.resetStatusText, "あと16時間8分で回復（11/5 02:00 JST）")
        XCTAssertFalse(pace.footerText.contains("今の期間"))
    }

    func testCountdownCountsClockMinutesToTheShownTime() {
        let now = date(2026, 11, 4, 9, 52).addingTimeInterval(50)
        XCTAssertEqual(WeeklyPace.recoverText(reset: now.addingTimeInterval(15), now: now), "あと1分で回復（11/4 09:53 JST）")
    }

    func testJustPassedResetIsNotCountedDown() {
        let now = date(2026, 11, 4, 10, 0).addingTimeInterval(12)
        var limit = UsageLimit(title: "5h", leftPercent: 50, resetText: "")
        limit.resetAt = now.addingTimeInterval(-2)
        XCTAssertNil(WeeklyPace(label: "5時間枠", limit: limit, now: now, period: WeeklyPace.fiveHours).recoverText)
    }

    func testRingCardSimpleRowsCarryRecovery() throws {
        let now = date(2026, 11, 4, 9, 52).addingTimeInterval(41)
        var five = UsageLimit(title: "Account B · 5h", leftPercent: 39, resetText: ""); five.resetAt = now.addingTimeInterval(98 * 60)
        var week = UsageLimit(title: "Account B · Weekly", leftPercent: 73, resetText: ""); week.resetAt = now.addingTimeInterval(16 * 3600)
        let row5 = RingDetailCardModel.Row(label: "5時間枠", leftPercent: 39, kind: .five, resetAt: five.resetAt)
        let rowW = RingDetailCardModel.Row(label: "週の枠", leftPercent: 73, kind: .week, resetAt: week.resetAt)
        XCTAssertEqual(row5.recoverText(now: now), "あと1時間38分で回復（11/4 11:30 JST）")
        XCTAssertEqual(rowW.recoverText(now: now), "あと16時間0分で回復（11/5 01:52 JST）")
        XCTAssertNil(RingDetailCardModel.Row(label: "MCP", leftPercent: 10, kind: .other, resetAt: week.resetAt).recoverText(now: now))
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        RingResetFormat.tokyoCalendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
}
