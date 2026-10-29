import XCTest
@testable import CodexUsageWidget

/// Every provider ring locks like Claude when a quota window is at 0%.
final class ProviderLockTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(_ title: String, left: Double, resetIn: TimeInterval?) -> UsageLimit {
        var w = UsageLimit(title: title, leftPercent: left, resetText: "")
        w.resetAt = resetIn.map { now.addingTimeInterval($0) }
        return w
    }

    func bars(_ provider: ProviderID, _ windows: [UsageLimit]) -> [CollapsedUsageBar] {
        let snap = MultiUsageSnapshot(sections: [ProviderSection(provider: provider, windows: windows, stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: now)
        return CollapsedUsageBar.bars(for: snap, blockedPreview: nil).filter { $0.provider == provider }
    }

    func assertLocked(_ provider: ProviderID, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let reset = 3 * 3600.0
        let all = bars(provider, [window(title, left: 0, resetIn: reset)])
        XCTAssertFalse(all.isEmpty, "\(provider) has a ring", file: file, line: line)
        for bar in all where !bar.windows.isEmpty {
            XCTAssertEqual(bar.block?.resetAt, now.addingTimeInterval(reset), "\(provider) locks until its reset", file: file, line: line)
        }
        let open = bars(provider, [window(title, left: 37, resetIn: reset)])
        XCTAssertTrue(open.allSatisfy { $0.block == nil }, "\(provider) with quota left is not locked", file: file, line: line)
    }

    func testCodex() { assertLocked(.codex, title: "Session") }
    func testGLM() { assertLocked(.zai, title: "5h") }
    func testGLMExhaustedMCPQuotaDoesNotLock() {
        let all = bars(.zai, [window("5h", left: 60, resetIn: 3600), window("Monthly", left: 0, resetIn: 5 * 86_400),
                              window("Weekly", left: 30, resetIn: 86_400)])
        XCTAssertTrue(all.allSatisfy { $0.block == nil }, "GLM locks only on the 5-hour window")
    }
    func testGrok() { assertLocked(.grok, title: "Weekly") }
    func testDeepSeek() { assertLocked(.deepseek, title: "Balance") }
    func testMiniMax() { assertLocked(.minimax, title: "5h") }
    func testKimi() { assertLocked(.kimi, title: "Weekly") }
    func testGeminiApp() { assertLocked(.gemini, title: "Gemini · 5h") }
    func testGeminiAppWeekly() { assertLocked(.gemini, title: "Gemini · Weekly") }

    func testAntigravityArgonLocksOnlyItsOwnRing() {
        let argon = window("Gemini 4 Argon · 5h", left: 0, resetIn: 7200)
        let flash = window("Gemini Models · 5h", left: 80, resetIn: 7200)
        let all = bars(.antigravity, [argon, flash])
        let argonBar = all.first { $0.title.localizedCaseInsensitiveContains("argon") }
        XCTAssertEqual(argonBar?.block?.resetAt, argon.resetAt)
        XCTAssertTrue(argonBar?.isBlocked == false || argonBar?.block != nil)
        XCTAssertNil(all.first { $0.title == "Gemini Models" }?.block)
    }

    func testAntigravityFlashLocks() {
        let all = bars(.antigravity, [window("Gemini Models · 5h", left: 0, resetIn: 600)])
        XCTAssertNotNil(all.first { $0.title == "Gemini Models" }?.block)
    }

    func testRoundsToZeroLocks() {
        XCTAssertNotNil(CollapsedUsageBar.quotaBlock([window("5h", left: 0.3, resetIn: 60)], now: now))
        XCTAssertNil(CollapsedUsageBar.quotaBlock([window("5h", left: 0.6, resetIn: 60)], now: now))
    }

    func testUnknownResetLocksWithUnknownText() {
        let block = CollapsedUsageBar.quotaBlock([window("Gemini · 5h", left: 0, resetIn: nil)], now: now)
        XCTAssertEqual(block?.resetUnknown, true)
        XCTAssertTrue(block!.isActive(at: now))
        XCTAssertEqual(ClaudeRateLimitParser.cardLine(block: block!, now: now), "5時間枠の制限中・解除時刻不明")
        XCTAssertEqual(ClaudeRateLimitParser.recoveryLines(resetAt: block!.resetAt).time, "不明")
    }

    func testPastResetIsOldDataNotLock() {
        XCTAssertNil(CollapsedUsageBar.quotaBlock([window("5h", left: 0, resetIn: -60)], now: now))
    }

    func testLatestResetWinsAndUnknownBeatsKnown() {
        let a = window("5h", left: 0, resetIn: 3600), b = window("Weekly", left: 0, resetIn: 86400 * 3)
        XCTAssertEqual(CollapsedUsageBar.quotaBlock([a, b], now: now)?.kind, .weekly)
        XCTAssertEqual(CollapsedUsageBar.quotaBlock([a, window("Weekly", left: 0, resetIn: nil)], now: now)?.resetUnknown, true)
    }

    func testClaudeStillLocks() {
        let snap = MultiUsageSnapshot(sections: [ProviderSection(provider: .claude, windows: [window("5h", left: 0, resetIn: 3600)], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: now)
        let a = CollapsedUsageBar.bars(for: snap, blockedPreview: nil).first { $0.id == "claude-0" }
        XCTAssertEqual(a?.block?.resetAt, now.addingTimeInterval(3600))
    }
}
