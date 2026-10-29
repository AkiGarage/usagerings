import XCTest
@testable import CodexUsageWidget

final class GeminiAppUsageParserTests: XCTestCase {
    let en = """
    Usage limits
    Your plan's limits determine how much you can use Gemini over time.
    Current usage
    23% used
    Resets at 4:10 PM
    Weekly limit
    61% used
    Resets Nov 2
    Upgrade
    """

    func testEnglishPage() {
        guard case let .reading(r) = GeminiAppUsageParser.parse(en) else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 23); XCTAssertEqual(r.weeklyUsed, 61)
        XCTAssertEqual(r.fiveHourReset, "Resets at 4:10 PM")
        let s = GeminiAppUsageParser.section(from: .reading(r), observedAt: Date(timeIntervalSince1970: 0))!
        XCTAssertEqual(s.windows.map(\.leftPercent), [77, 39])
        XCTAssertEqual(s.windows.map { ServiceRowModel.kind($0.title) }, [.five, .week])
    }

    func testJapanesePageAndLeftWording() {
        let ja = "使用量の上限\n現在の使用量\n残り 70%\n16:10 にリセット\n週間の上限\n12% 使用済み\n"
        guard case let .reading(r) = GeminiAppUsageParser.parse(ja) else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 30); XCTAssertEqual(r.weeklyUsed, 12)
    }

    func testVerificationPageBlocks() {
        XCTAssertEqual(GeminiAppUsageParser.parse("Our systems have detected unusual traffic from your computer"), .blocked)
        XCTAssertEqual(GeminiAppUsageParser.parse("Sign in\nto continue to Gemini"), .blocked)
    }

    func testNoNumbersOrAmbiguousIsUnknown() {
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\nLoading…"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n20% 40%\nWeekly limit\n"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse(""), .unknown)
    }

    func testPercentOver100Ignored() {
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n150%\n"), .unknown)
    }
}

final class GeminiReadPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func sig(_ dt: TimeInterval, front: Bool, idle: TimeInterval = 5, asleep: Bool = false, hour: Int = 14) -> GeminiReadPolicy.Signals {
        .init(now: t0.addingTimeInterval(dt), geminiFrontmost: front, idleSeconds: idle, screenAsleep: asleep, hour: hour)
    }

    func testReadsOnceAtStartThenEveryFiveMinutes() {
        var st = GeminiReadPolicy.State(); var reads: [TimeInterval] = []
        for dt in stride(from: 0.0, through: 900, by: 30) {
            let (n, read) = GeminiReadPolicy.step(st, sig(dt, front: true)); st = n
            if read { reads.append(dt); st.lastRead = t0.addingTimeInterval(dt) }
        }
        XCTAssertEqual(reads, [0, 300, 600, 900])
    }

    func testNoReadWhenNeverUsedIdleAsleepOrNight() {
        let st = GeminiReadPolicy.State()
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(0, front: false)).1)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(0, front: true, idle: 600)).1)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(0, front: true, asleep: true)).1)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(0, front: true, hour: 3)).1)
        var halted = st; halted.halted = true
        XCTAssertFalse(GeminiReadPolicy.step(halted, sig(0, front: true)).1)
    }

    func testStopsAfterRecentUseWindow() {
        var st = GeminiReadPolicy.State(lastSeenGemini: t0, lastRead: t0)
        XCTAssertTrue(GeminiReadPolicy.step(st, sig(300, front: false)).1) // used within 5 min
        st.lastRead = t0.addingTimeInterval(300)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(601, front: false)).1)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(1200, front: false)).1)
    }

    func testNewSessionReadsImmediatelyButNotTwiceInAMinute() {
        let st = GeminiReadPolicy.State(lastSeenGemini: t0, lastRead: t0.addingTimeInterval(-10))
        XCTAssertTrue(GeminiReadPolicy.step(GeminiReadPolicy.State(lastSeenGemini: t0, lastRead: t0), sig(1000, front: true)).1)
        XCTAssertFalse(GeminiReadPolicy.step(st, sig(30, front: true)).1)
    }
}

final class FakeGeminiBridge: ChromeUsageBridge {
    var chromeRunning = true
    var chromeFrontmost = true
    var status: ChromeAutomationStatus = .granted
    var url: String? = "https://gemini.google.com/app/abc"
    var text: Result<String, ChromeReadError>? = .success("Usage limits\nCurrent usage\n40% used\nWeekly limit\n10% used")
    var asked = 0, textReads = 0, urlReads = 0
    func automationStatus(ask: Bool) -> ChromeAutomationStatus {
        if ask { asked += 1; if status == .notDetermined { status = .granted } }
        return status
    }
    func activeTabURL() -> String? { urlReads += 1; return url }
    func usageTabText() -> Result<String, ChromeReadError>? { textReads += 1; return text }
}

@MainActor
final class GeminiAppUsageMonitorTests: XCTestCase {
    var defaults: UserDefaults!
    override func setUp() {
        defaults = UserDefaults(suiteName: "gemini-test-\(UUID().uuidString)")!
    }

    func make(_ b: FakeGeminiBridge, now: Date) -> GeminiAppUsageMonitor {
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        return m
    }
    var noon: Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    func testDisabledByDefaultTouchesNothing() {
        let b = FakeGeminiBridge(); let m = make(b, now: noon)
        m.tick()
        XCTAssertEqual(b.textReads + b.urlReads + b.asked, 0)
    }

    func testEnableAsksOnlyWhenUndeterminedAndReads() {
        let b = FakeGeminiBridge(); b.status = .notDetermined
        let m = make(b, now: noon)
        m.setEnabled(true)
        XCTAssertEqual(b.asked, 1)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        m.tick(); m.tick()
        XCTAssertEqual(b.asked, 1, "ticks never show the permission dialog")
        XCTAssertEqual(b.textReads, 1, "no second read within 5 minutes")
    }

    func testDeniedNeverReadsAndNeverReasks() {
        let b = FakeGeminiBridge(); b.status = .denied
        let m = make(b, now: noon)
        m.setEnabled(true); m.tick()
        XCTAssertEqual(b.asked, 0); XCTAssertEqual(b.textReads, 0)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertNotNil(m.section.failureText)
    }

    func testChromeNotRunningOrNotFrontmost() {
        let b = FakeGeminiBridge(); b.chromeRunning = false
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        m.tick(); XCTAssertEqual(b.urlReads + b.textReads, 0)
        b.chromeRunning = true; b.chromeFrontmost = false
        m.tick(); XCTAssertEqual(b.urlReads + b.textReads, 0)
    }

    func testVerificationPageHaltsAndKeepsLastValueAsStale() {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        m.setEnabled(true)
        XCTAssertFalse(m.section.isStale)
        b.text = .success("Our systems have detected unusual traffic")
        now = now.addingTimeInterval(301); m.tick()
        XCTAssertTrue(m.state.halted)
        XCTAssertTrue(m.section.isStale)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        XCTAssertTrue(m.section.failureText?.contains("停止") ?? false)
        now = now.addingTimeInterval(301); m.tick()
        XCTAssertEqual(b.textReads, 2, "halted: no more reads")
    }

    func testNoUsageTabShowsUnknownWithoutNumbers() {
        let b = FakeGeminiBridge(); b.text = nil
        let m = make(b, now: noon)
        m.setEnabled(true)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertTrue(m.section.failureText?.contains("不明") ?? false)
    }

    func testNonGeminiFrontTabDoesNotRead() {
        let b = FakeGeminiBridge(); b.url = "https://mail.google.com/"
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        m.tick()
        XCTAssertEqual(b.textReads, 0)
    }

    func testStoreMergeKeepsOtherProviders() {
        let base = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: Date())
        let g = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        let merged = MultiUsageStore.withGemini(g, in: MultiUsageStore.withGemini(g, in: base))
        XCTAssertEqual(merged.sections.map(\.provider), [.codex, .gemini])
    }
}
