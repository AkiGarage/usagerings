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
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n150% used\n"), .unknown)
    }

    func testStrictLabelAnchoredParsing() {
        // Unrelated percentages, bare numbers and non-percent "left" are ignored.
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n40% off\n23%\nWeekly limit\n"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n40% used; 2 requests left\n"), .unknown)
        guard case let .reading(r) = GeminiAppUsageParser.parse("Current usage\n40% used\n2 requests left\n") else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 40)
        // A label inside a sentence is not a section label.
        XCTAssertEqual(GeminiAppUsageParser.parse("Check your current usage below\n50% used\n"), .unknown)
        // Percent far below the label (beyond 4 lines) is not taken.
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\na\nb\nc\nd\n50% used\n"), .unknown)
        // Weekly numbers do not leak into the 5h section.
        guard case let .reading(w) = GeminiAppUsageParser.parse("Current usage\nWeekly limit\n61% used\n") else { return XCTFail() }
        XCTAssertNil(w.fiveHourUsed); XCTAssertEqual(w.weeklyUsed, 61)
    }

    func testRemainingPercentMath() {
        guard case let .reading(r) = GeminiAppUsageParser.parse("Current usage\n70% left\nWeekly limit\n100% remaining\n") else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 30); XCTAssertEqual(r.weeklyUsed, 0)
        let s = GeminiAppUsageParser.section(from: .reading(r), observedAt: Date())!
        XCTAssertEqual(s.windows.map(\.leftPercent), [70, 100])
    }

    func testAnyVerificationTextBlocksEvenWithUsageHeading() {
        XCTAssertEqual(GeminiAppUsageParser.parse(en + "\nVerify it's you"), .blocked)
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n23% used\nSign in"), .blocked)
    }

    func testExactUsageURL() {
        XCTAssertTrue(GeminiUsageURL.isUsagePage("https://gemini.google.com/usage"))
        XCTAssertTrue(GeminiUsageURL.isUsagePage("https://gemini.google.com/usage?hl=ja"))
        XCTAssertFalse(GeminiUsageURL.isUsagePage("https://gemini.google.com/usage-other"))
        XCTAssertFalse(GeminiUsageURL.isUsagePage("https://gemini.google.com/usage/x"))
        XCTAssertFalse(GeminiUsageURL.isUsagePage("http://gemini.google.com/usage"))
    }

    func testRawEventsNeverPromptAndTimeOut() {
        XCTAssertEqual(LiveChromeBridge.code("getd"), 0x6765_7464)
        XCTAssertTrue(LiveChromeBridge.sendOptions.contains(.neverInteract))
        XCTAssertTrue(LiveChromeBridge.sendOptions.contains(LiveChromeBridge.doNotPrompt))
        XCTAssertEqual(LiveChromeBridge.timeoutSeconds, 8)
    }

    func testUnknownHeadingEndsSection() {
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\nMonthly limit\n23% used\n"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\n2-hour limit\n23% used\n"), .unknown)
    }

    func testOversizedVerificationPageStillBlocks() {
        let big = String(repeating: "x", count: GeminiAppUsageParser.maxTextLength) + "unusual traffic"
        XCTAssertEqual(GeminiAppUsageParser.parse(big), .blocked)
    }

    func testPageMustReportExactUsageURL() {
        XCTAssertEqual(LiveChromeBridge.usageText(fromJSON: #"{"u":"https://gemini.google.com/usage","t":"hi"}"#), .success("hi"))
        XCTAssertNil(LiveChromeBridge.usageText(fromJSON: #"{"u":"https://gemini.google.com/app","t":"hi"}"#))
        XCTAssertEqual(LiveChromeBridge.usageText(fromJSON: "garbage"), .failure(.failed))
    }

    func testOversizedPageIsUnknownNotTruncated() {
        let big = "Current usage\n23% used\n" + String(repeating: "x", count: GeminiAppUsageParser.maxTextLength)
        XCTAssertEqual(GeminiAppUsageParser.parse(big), .unknown)
    }
}

final class GeminiReadPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func sig(_ dt: TimeInterval, front: Bool, idle: TimeInterval = 5, asleep: Bool = false, hour: Int = 14) -> GeminiReadPolicy.Signals {
        .init(now: t0.addingTimeInterval(dt), geminiFrontmost: front, idleSeconds: idle, screenAsleep: asleep, hour: hour)
    }

    func testReadsOnceAtStartThenEveryFiveMinutes() {
        var st = GeminiReadPolicy.State(); var reads: [TimeInterval] = []
        for dt in stride(from: 0.0, through: 900, by: 30) where GeminiReadPolicy.shouldRead(st, sig(dt, front: true)) {
            reads.append(dt); st.lastRead = t0.addingTimeInterval(dt)
        }
        XCTAssertEqual(reads, [0, 300, 600, 900])
    }

    func testNoReadWhenNotFrontmostIdleAsleepNightOrHalted() {
        let st = GeminiReadPolicy.State()
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: false)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, idle: 600)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, asleep: true)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, hour: 3)))
        var halted = st; halted.halted = true
        XCTAssertFalse(GeminiReadPolicy.shouldRead(halted, sig(0, front: true)))
    }

    func testNotFrontmostNeverReadsEvenRightAfterUse() {
        let st = GeminiReadPolicy.State(lastRead: t0.addingTimeInterval(-600))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(10, front: false)))
        XCTAssertTrue(GeminiReadPolicy.shouldRead(st, sig(10, front: true)))
    }

    func testNewSessionReadsAtOnceButNeverWithinFiveMinutes() {
        XCTAssertTrue(GeminiReadPolicy.shouldRead(.init(lastRead: t0), sig(1000, front: true)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(.init(lastRead: t0), sig(299, front: true)))
    }
}
final class FakeGeminiBridge: ChromeUsageBridge, @unchecked Sendable {
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

    func testDisabledByDefaultTouchesNothing() async {
        let b = FakeGeminiBridge(); let m = make(b, now: noon)
        await m.tick()
        XCTAssertEqual(b.textReads + b.urlReads + b.asked, 0)
    }

    func testEnableAsksOnlyWhenUndeterminedAndReads() async {
        let b = FakeGeminiBridge(); b.status = .notDetermined
        let m = make(b, now: noon)
        await m.setEnabled(true)
        XCTAssertEqual(b.asked, 1)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        await m.tick(); await m.tick()
        XCTAssertEqual(b.asked, 1, "ticks never show the permission dialog")
        XCTAssertEqual(b.textReads, 1, "no second read within 5 minutes")
    }

    func testDeniedNeverReadsAndNeverReasks() async {
        let b = FakeGeminiBridge(); b.status = .denied
        let m = make(b, now: noon)
        await m.setEnabled(true); await m.tick()
        XCTAssertEqual(b.asked, 0); XCTAssertEqual(b.textReads, 0)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertNotNil(m.section.failureText)
    }

    func testChromeNotRunningOrNotFrontmost() async {
        let b = FakeGeminiBridge(); b.chromeRunning = false
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        await m.tick(); XCTAssertEqual(b.urlReads + b.textReads, 0)
        b.chromeRunning = true; b.chromeFrontmost = false
        await m.tick(); XCTAssertEqual(b.urlReads + b.textReads, 0)
    }

    func testVerificationPageHaltsAndKeepsLastValueAsStale() async {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        XCTAssertFalse(m.section.isStale)
        b.text = .success("Our systems have detected unusual traffic")
        now = now.addingTimeInterval(301); await m.tick()
        XCTAssertTrue(m.state.halted)
        XCTAssertTrue(m.section.isStale)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        XCTAssertTrue(m.section.failureText?.contains("停止") ?? false)
        now = now.addingTimeInterval(301); await m.tick()
        XCTAssertEqual(b.textReads, 2, "halted: no more reads")
    }

    func testNoUsageTabShowsUnknownWithoutNumbers() async {
        let b = FakeGeminiBridge(); b.text = nil
        let m = make(b, now: noon)
        await m.setEnabled(true)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertTrue(m.section.failureText?.contains("不明") ?? false)
    }

    func testNonGeminiFrontTabDoesNotRead() async {
        let b = FakeGeminiBridge(); b.url = "https://mail.google.com/"
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        await m.tick()
        XCTAssertEqual(b.textReads, 0)
    }

    func testLastReadPersistsAcrossToggleAndRestart() async {
        let b = FakeGeminiBridge(); let now = noon
        let m = make(b, now: now)
        await m.setEnabled(true)
        XCTAssertEqual(b.textReads, 1)
        await m.setEnabled(false); await m.setEnabled(true)
        XCTAssertEqual(b.textReads, 1, "toggling does not allow an early read")
        let restarted = make(b, now: now.addingTimeInterval(60))
        await restarted.tick()
        XCTAssertEqual(b.textReads, 1, "restart keeps the 5-minute spacing")
        XCTAssertEqual(restarted.state.lastRead, now)
    }

    func testHaltSurvivesRestartUntilMenuToggle() async {
        let b = FakeGeminiBridge(); b.text = .success("unusual traffic")
        var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        b.text = .success("Current usage\n40% used")
        now = now.addingTimeInterval(3600)
        let restarted = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        restarted.clock = { now }; restarted.idleSeconds = { 1 }; restarted.screenAsleep = { false }
        await restarted.tick()
        XCTAssertEqual(b.textReads, 1)
        await restarted.setEnabled(true)
        XCTAssertEqual(b.textReads, 2)
    }

    func testHiddenProviderNeverReads() async {
        let b = FakeGeminiBridge(); let m = make(b, now: noon)
        m.isVisible = { false }
        await m.setEnabled(true); await m.tick()
        XCTAssertEqual(b.textReads + b.urlReads, 0)
    }

    func testClockMovedBackRebasesInsteadOfReading() async {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        now = now.addingTimeInterval(-7200); await m.tick()
        XCTAssertEqual(b.textReads, 1)
        now = now.addingTimeInterval(301); await m.tick()
        XCTAssertEqual(b.textReads, 2)
    }

    func testVerificationTextSavesNothing() async {
        let b = FakeGeminiBridge(); b.text = .success("Usage limits\nCurrent usage\n23% used\nVerify it's you")
        let m = make(b, now: noon)
        await m.setEnabled(true)
        XCTAssertTrue(m.state.halted)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertNil(defaults.dictionary(forKey: GeminiAppUsageMonitor.cacheKey))
    }

    func testOldValueBecomesStaleWhenNotInUse() async {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        XCTAssertFalse(m.section.isStale)
        b.chromeFrontmost = false
        now = now.addingTimeInterval(GeminiReadPolicy.staleAfter + 1); await m.tick()
        XCTAssertTrue(m.section.isStale)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        XCTAssertEqual(b.textReads, 1)
    }

    func testStoreMergeKeepsOtherProviders() async {
        let base = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: Date())
        let g = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        let merged = MultiUsageStore.withGemini(g, in: MultiUsageStore.withGemini(g, in: base))
        XCTAssertEqual(merged.sections.map(\.provider), [.codex, .gemini])
    }
}
