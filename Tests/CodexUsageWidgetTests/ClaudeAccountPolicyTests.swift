import XCTest
@testable import CodexUsageWidget

final class ClaudeAccountPolicyTests: XCTestCase {
    typealias P = ClaudeAccountPolicy
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func h(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    func acct(_ key: String, five: Double? = 50, fiveReset: Double? = 2, week: Double? = 50, weekReset: Double? = 48,
              session: Double? = nil, weeklyBlock: Double? = nil) -> P.Account {
        P.Account(key: key, fiveLeft: five, fiveResetAt: fiveReset.map(h), weeklyLeft: week,
                  weeklyResetAt: weekReset.map(h), sessionBlockUntil: session.map(h), weeklyBlockUntil: weeklyBlock.map(h))
    }

    // T1: preferred = earlier weekly reset
    func testPrefersEarlierWeeklyReset() {
        let d = P.decide([acct("a", weekReset: 100), acct("b", weekReset: 20)], previous: nil, now: now)
        XCTAssertEqual(d.selected, "b"); XCTAssertEqual(d.preferred, "b"); XCTAssertEqual(d.state, .preferred)
        XCTAssertTrue(d.reason.contains("週の制限が先にリセット"))
        XCTAssertEqual(d.order, ["b", "a"])
    }

    // T2: preferred hits 5h → fallback, reason mentions return time
    func testPreferredFiveHourLimitFallsBack() {
        let d = P.decide([acct("a", five: 0, fiveReset: 1.5, weekReset: 20), acct("b", weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.selected, "b"); XCTAssertEqual(d.preferred, "a"); XCTAssertEqual(d.state, .fallback)
        XCTAssertTrue(d.reason.contains("5時間制限中")); XCTAssertTrue(d.reason.contains("に戻します"))
    }

    // T2b: session log block counts as 5h limit even when % says otherwise
    func testSessionBlockCountsAsLimit() {
        let d = P.decide([acct("a", five: 40, weekReset: 20, session: 1), acct("b", weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.selected, "b")
    }

    // T3: 5h clears (reset passed, full again) → back to preferred
    func testReturnsWhenFiveHourClears() {
        let limited = P.decide([acct("a", five: 0, fiveReset: 1, weekReset: 20), acct("b", weekReset: 100)], previous: nil, now: now)
        let later = P.decide([acct("a", five: 100, fiveReset: 6, weekReset: 20), acct("b", weekReset: 100)], previous: limited, now: now)
        XCTAssertEqual(later.selected, "a"); XCTAssertEqual(later.state, .preferred)
    }

    // T4: hysteresis band — just above 0 after a limit stays on fallback while other is free
    func testHysteresisBandAvoidsFlapping() {
        let limited = P.decide([acct("a", five: 0, fiveReset: 1, weekReset: 20), acct("b", weekReset: 100)], previous: nil, now: now)
        let wobble = P.decide([acct("a", five: 3, fiveReset: 1, weekReset: 20), acct("b", weekReset: 100)], previous: limited, now: now)
        XCTAssertEqual(wobble.selected, "b")
        let again = P.decide([acct("a", five: 0, fiveReset: 1, weekReset: 20), acct("b", weekReset: 100)], previous: wobble, now: now)
        XCTAssertEqual(again.selected, "b")
        let clear = P.decide([acct("a", five: 6, fiveReset: 1, weekReset: 20), acct("b", weekReset: 100)], previous: again, now: now)
        XCTAssertEqual(clear.selected, "a")
    }

    // T4b: band account is still used when the other is limited (property)
    func testBandAccountUsedWhenOtherLimited() {
        let limited = P.decide([acct("a", five: 0, weekReset: 20), acct("b", weekReset: 100)], previous: nil, now: now)
        let d = P.decide([acct("a", five: 3, weekReset: 20), acct("b", five: 0, weekReset: 100)], previous: limited, now: now)
        XCTAssertEqual(d.selected, "a")
    }

    // T5: both at 5h → all limited, wait for the soonest clear
    func testBothFiveHourLimitedWaitsForSoonest() {
        let d = P.decide([acct("a", five: 0, fiveReset: 3, weekReset: 20), acct("b", five: 0, fiveReset: 1, weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.state, .allLimited); XCTAssertEqual(d.selected, "b")
        XCTAssertTrue(d.reason.contains("すべて制限中"))
    }

    // T6: weekly exhausted account is never preferred
    func testWeeklyExhaustedNotPreferred() {
        let d = P.decide([acct("a", week: 0, weekReset: 5), acct("b", weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.selected, "b"); XCTAssertEqual(d.preferred, "b")
        XCTAssertTrue(d.reason.contains("週の上限"))
    }

    // T6b: weekly exhausted + other at 5h → all limited, soonest clear
    func testWeeklyAndFiveLimited() {
        let d = P.decide([acct("a", week: 0, weekReset: 5), acct("b", five: 0, fiveReset: 2, weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.state, .allLimited); XCTAssertEqual(d.selected, "b")
    }

    // T7: unknown reset times → keep previous / account order
    func testUnknownResetsUseOrderThenPrevious() {
        let d1 = P.decide([acct("a", weekReset: nil), acct("b", weekReset: nil)], previous: nil, now: now)
        XCTAssertEqual(d1.selected, "a")
        let prev = P.decide([acct("a", weekReset: 100), acct("b", weekReset: 20)], previous: nil, now: now)
        let d2 = P.decide([acct("a", weekReset: nil), acct("b", weekReset: nil)], previous: prev, now: now)
        XCTAssertEqual(d2.selected, "b")
    }

    // T7b: known reset beats unknown
    func testKnownResetBeatsUnknown() {
        let d = P.decide([acct("a", weekReset: nil), acct("b", weekReset: 100)], previous: nil, now: now)
        XCTAssertEqual(d.preferred, "b")
    }

    // T8: tie within 30 min keeps previous; no previous → account order
    func testTieKeepsPrevious() {
        let d1 = P.decide([acct("a", weekReset: 20.2), acct("b", weekReset: 20)], previous: nil, now: now)
        XCTAssertEqual(d1.selected, "a")
        let prev = P.Decision(selected: "b", preferred: "b", state: .preferred, reason: "", fiveLimited: [], order: ["b", "a"])
        let d2 = P.decide([acct("a", weekReset: 20), acct("b", weekReset: 20.3)], previous: prev, now: now)
        XCTAssertEqual(d2.selected, "b")
        let d3 = P.decide([acct("a", weekReset: 19), acct("b", weekReset: 20.3)], previous: prev, now: now)
        XCTAssertEqual(d3.selected, "a")
    }

    // T9: after weekly reset passes, preference moves on
    func testPreviousPreferredWhoseResetPassedIsReplaced() {
        let prev = P.Decision(selected: "a", preferred: "a", state: .preferred, reason: "", fiveLimited: [], order: ["a", "b"])
        let d = P.decide([acct("a", weekReset: -1), acct("b", weekReset: 30)], previous: prev, now: now)
        XCTAssertEqual(d.preferred, "b")
    }

    // T10: no data
    func testNoData() {
        let d = P.decide([P.Account(key: "a"), P.Account(key: "b")], previous: nil, now: now)
        XCTAssertEqual(d.state, .noData); XCTAssertNil(d.selected); XCTAssertTrue(d.order.isEmpty)
        XCTAssertNil(ClaudeAccountChoice.payload(d, now: now))
    }

    // T11: expired limit (reset time passed but stale 0%) is not treated as limited
    func testStaleZeroAfterResetIsNotLimited() {
        XCTAssertFalse(P.isFiveLimited(acct("a", five: 0, fiveReset: -0.1), now: now))
        XCTAssertFalse(P.isWeeklyLimited(acct("a", week: 0, weekReset: -0.1), now: now))
    }

    // Property: never select a limited account when another is not limited.
    func testPropertyNeverSelectsLimitedWhenAnotherIsFree() {
        var rng = SystemRandomNumberGenerator()
        let fives: [Double?] = [nil, 0, 2, 4, 5, 50, 100]
        let weeks: [Double?] = [nil, 0, 1, 60]
        let resets: [Double?] = [nil, -1, 0.5, 3, 20, 20.2, 150]
        for _ in 0..<20_000 {
            func random(_ k: String) -> P.Account {
                acct(k, five: fives.randomElement(using: &rng)!, fiveReset: resets.randomElement(using: &rng)!,
                     week: weeks.randomElement(using: &rng)!, weekReset: resets.randomElement(using: &rng)!,
                     session: Bool.random(using: &rng) ? nil : resets.randomElement(using: &rng)!,
                     weeklyBlock: Int.random(in: 0..<6, using: &rng) == 0 ? resets.randomElement(using: &rng)! : nil)
            }
            let accounts = [random("a"), random("b")]
            var previous: P.Decision? = nil
            if Bool.random(using: &rng) {
                previous = P.Decision(selected: ["a", "b"].randomElement()!, preferred: [nil, "a", "b"].randomElement()!,
                                      state: .preferred, reason: "", fiveLimited: Set(["a", "b"].filter { _ in Bool.random() }),
                                      order: ["a", "b"])
            }
            let d = P.decide(accounts, previous: previous, now: now)
            if !accounts.contains(where: \.hasData) { XCTAssertNil(d.selected); continue }
            let selected = accounts.first { $0.key == d.selected }!
            if accounts.contains(where: { !P.isLimited($0, now: now) }) {
                XCTAssertFalse(P.isLimited(selected, now: now), "\(accounts) prev=\(String(describing: previous)) -> \(d)")
                XCTAssertNotEqual(d.state, .allLimited)
            } else {
                XCTAssertEqual(d.state, .allLimited)
            }
            XCTAssertEqual(Set(d.order), ["a", "b"]); XCTAssertEqual(d.order.first, d.selected)
            // Determinism / no flapping: same inputs with its own result as history give the same choice.
            let again = P.decide(accounts, previous: d, now: now)
            XCTAssertEqual(again.selected, d.selected, "\(accounts) -> \(d) then \(again)")
        }
    }

    // Mapping + payload
    func testProfileMapAndPayload() throws {
        var w1 = UsageLimit(title: "aki***@g*** · 5h", leftPercent: 0, resetText: ""); w1.accountIndex = 0; w1.resetAt = h(1)
        var w2 = UsageLimit(title: "aki***@g*** · Weekly", leftPercent: 40, resetText: ""); w2.accountIndex = 0; w2.resetAt = h(10)
        var w3 = UsageLimit(title: "a.k***@g*** · 5h", leftPercent: 80, resetText: ""); w3.accountIndex = 1
        var w4 = UsageLimit(title: "a.k***@g*** · Weekly", leftPercent: 80, resetText: ""); w4.accountIndex = 1; w4.resetAt = h(90)
        let section = ProviderSection(provider: .claude, windows: [w1, w2, w3, w4], stats: [])
        let map = ClaudeAccountChoice.profileMap(section: section, masks: ["a": "a.k***@g***", "b": "aki***@g***"])
        XCTAssertEqual(map, [0: "b", 1: "a"])
        let accounts = ClaudeAccountChoice.accounts(section: section, map: map, now: now)
        XCTAssertEqual(accounts.map(\.key), ["a", "b"])
        let d = P.decide(accounts, previous: nil, now: now)
        XCTAssertEqual(d.selected, "a"); XCTAssertEqual(d.preferred, "b")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("c.json")
        XCTAssertTrue(ClaudeAccountChoice.publish(d, now: now, url: url))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["order"] as? [String], ["a", "b"])
        XCTAssertEqual(obj["expiresAt"] as? Int, Int(now.timeIntervalSince1970) + 600)
        // Ambiguous masks → no mapping → no file
        let none = ClaudeAccountChoice.profileMap(section: section, masks: ["a": "aki***@g***", "b": "aki***@g***"])
        XCTAssertTrue(none.isEmpty)
        let unmapped = P.decide(ClaudeAccountChoice.accounts(section: section, map: none, now: now), previous: nil, now: now)
        XCTAssertNil(ClaudeAccountChoice.payload(unmapped, now: now))
    }
}

final class ClaudeAccountPolicyReviewTests: XCTestCase {
    typealias P = ClaudeAccountPolicy
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func h(_ x: Double) -> Date { now.addingTimeInterval(x * 3600) }

    // R3: reset time passed with stale 0% → back to preferred (not stuck in "recovering")
    func testReturnsAfterResetTimeEvenWithStaleZero() {
        let prev = P.Decision(selected: "b", preferred: "a", state: .fallback, reason: "", fiveLimited: ["a"], order: ["b", "a"])
        let a = P.Account(key: "a", fiveLeft: 0, fiveResetAt: h(-0.1), weeklyLeft: 50, weeklyResetAt: h(20))
        let b = P.Account(key: "b", fiveLeft: 50, fiveResetAt: h(2), weeklyLeft: 50, weeklyResetAt: h(100))
        XCTAssertEqual(P.decide([a, b], previous: prev, now: now).selected, "a")
    }

    // R4: unknown clear time ranks after a known one when all are limited
    func testAllLimitedUnknownClearRanksLast() {
        let a = P.Account(key: "a", fiveLeft: 0, fiveResetAt: h(1), weeklyLeft: 50, weeklyResetAt: h(20), weeklyBlockUntil: nil)
        var aw = a; aw.weeklyLeft = 0; aw.weeklyResetAt = nil
        let b = P.Account(key: "b", fiveLeft: 0, fiveResetAt: h(2), weeklyLeft: 50, weeklyResetAt: h(100))
        let d = P.decide([aw, b], previous: nil, now: now)
        XCTAssertEqual(d.state, .allLimited); XCTAssertEqual(d.selected, "b")
    }

    // R5: profile order a,b regardless of CLIProxy index order
    func testMappedAccountsAreInProfileOrder() {
        var w0 = UsageLimit(title: "x · Weekly", leftPercent: 50, resetText: ""); w0.accountIndex = 0; w0.resetAt = h(20)
        var w1 = UsageLimit(title: "y · Weekly", leftPercent: 50, resetText: ""); w1.accountIndex = 1; w1.resetAt = h(20)
        let section = ProviderSection(provider: .claude, windows: [w0, w1], stats: [])
        let accounts = ClaudeAccountChoice.accounts(section: section, map: [0: "b", 1: "a"], now: now)
        XCTAssertEqual(accounts.map(\.key), ["a", "b"])
        XCTAssertEqual(P.decide(accounts, previous: nil, now: now).selected, "a")
    }
}

final class ProviderProbeTests: XCTestCase {
    @MainActor
    func testUndecidedProvidersProbedAtMostEvery30Minutes() throws {
        let name = "ProviderProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = PanelPreferences(defaults: defaults)
        prefs.setProviderVisible(true, for: .codex)
        prefs.setProviderVisible(false, for: .kimi)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = prefs.providersToSkip(now: t0)
        XCTAssertEqual(first, [.kimi])
        let second = prefs.providersToSkip(now: t0.addingTimeInterval(60))
        XCTAssertTrue(second.contains(.minimax)); XCTAssertFalse(second.contains(.codex)); XCTAssertTrue(second.contains(.kimi))
        let third = prefs.providersToSkip(now: t0.addingTimeInterval(31 * 60))
        XCTAssertEqual(third, [.kimi])
        XCTAssertTrue(prefs.claudeAutoSwitch)
    }
}
