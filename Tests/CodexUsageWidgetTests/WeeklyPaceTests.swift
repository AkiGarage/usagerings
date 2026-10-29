import XCTest
@testable import CodexUsageWidget

final class WeeklyPaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func weekly(left: Double, resetIn: TimeInterval?) -> UsageLimit {
        var w = UsageLimit(title: "Weekly", leftPercent: left, resetText: "")
        w.resetAt = resetIn.map { now.addingTimeInterval($0) }
        return w
    }

    func testOveruseAheadOfPace() {
        // 2 days into the week (5 days to reset) = 28.6% elapsed; 41% used -> +12.
        let p = WeeklyPace(label: "週", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.elapsedPercent!, 200.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.paceText, "均等より+12%使いすぎ")
        XCTAssertEqual(p.tone, .over)
    }

    func testSurplusBehindPace() {
        // 4 days in = 57.1% elapsed; 49% used -> -8.
        let p = WeeklyPace(label: "週", limit: weekly(left: 51, resetIn: 3 * 86_400), now: now)
        XCTAssertEqual(p.paceText, "余裕 -8%")
        XCTAssertEqual(p.tone, .under)
    }

    func testUnknownResetHasNoMarker() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: nil), now: now)
        XCTAssertNil(p.elapsedPercent)
        XCTAssertEqual(p.rangeText, "リセット 不明")
        XCTAssertTrue(p.paceText.contains("不明"))
    }

    func testPassedResetIsUnknown() {
        XCTAssertNil(WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: -60), now: now).elapsedPercent)
    }

    func testCardShowsOnlyWeeklyPaces() {
        var five = UsageLimit(title: "5h", leftPercent: 50, resetText: ""); five.resetAt = now.addingTimeInterval(3600)
        let snap = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [five, weekly(left: 59, resetIn: 5 * 86_400)], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: now)
        let bar = CollapsedUsageBar.bars(for: snap, blockedPreview: nil).first { $0.provider == .codex }!
        let model = RingDetailCardModel.make(bar: bar, now: now)!
        XCTAssertEqual(model.paces.count, 1)
        XCTAssertEqual(model.paces.first?.paceText, "均等より+12%使いすぎ")
    }
}
