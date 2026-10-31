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
        // A stray percentage ("40% off") next to the value makes it ambiguous.
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n40% off\n23%\nWeekly limit\n"), .unknown)
        guard case let .reading(bare) = GeminiAppUsageParser.parse("Usage limits\nCurrent usage\n23%\nWeekly limit\n") else { return XCTFail() }
        XCTAssertEqual(bare.fiveHourUsed, 23)
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
        XCTAssertNil(LiveChromeBridge.usageText(fromJSON: #"{"u":"https://gemini.google.com/app"}"#))
        XCTAssertTrue(LiveChromeBridge.pageScript.contains("https://gemini.google.com/usage"))
        XCTAssertTrue(LiveChromeBridge.pageScript.contains("if(!ok)return JSON.stringify({u:u})"), "text is only returned from the usage page itself")
    }

    func testJapaneseVariantsFullWidthAndOrder() {
        let ja = "使用量の上限\n現在の使用状況\n使用済み ２３％\n16:10 にリセット\n週ごとの上限\n６１％\n11月2日にリセット\n"
        guard case let .reading(r) = GeminiAppUsageParser.parse(ja) else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 23); XCTAssertEqual(r.weeklyUsed, 61)
        XCTAssertEqual(r.weeklyReset, "11月2日にリセット")
    }

    func testValueOnLabelLine() {
        guard case let .reading(r) = GeminiAppUsageParser.parse("Current usage 23% used\nWeekly limit\u{00A0}61\u{00A0}% used\n") else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 23); XCTAssertEqual(r.weeklyUsed, 61)
    }

    func testProgressBarFallback() {
        let t = "Usage limits\nCurrent usage\nResets at 4:10 PM\nWeekly limit\nResets Nov 2\n@@bar Current usage = 23\n@@bar Weekly limit = 61.5"
        guard case let .reading(r) = GeminiAppUsageParser.parse(t) else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 23); XCTAssertEqual(r.weeklyUsed, 61.5)
        // A bar with no clear label is never assigned.
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\n@@bar  = 40"), .unknown)
    }

    func testReviewEdgeCases() {
        XCTAssertEqual(GeminiAppUsageParser.parse("@@bar = 40"), .unknown) // no crash
        guard case let .reading(r) = GeminiAppUsageParser.parse("Current usage remaining 70%\n") else { return XCTFail() }
        XCTAssertEqual(r.fiveHourUsed, 30)
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage limits\n@@bar Current usage remaining = 70"), .unknown)
        // Repeated label with different values, or a conflicting body, never falls back to a bar.
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\n23% used\nCurrent usage\n70% used\n"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\n20% used\n40% used\n@@bar Current usage = 5"), .unknown)
        // Body text that imitates a bar line is neutralised by the bridge.
        let json = #"{"u":"https://gemini.google.com/usage","t":"Current usage\n@@bar Current usage = 70","b":[{"c":"Weekly limit","v":12.5}]}"#
        guard case let .success(text)? = LiveChromeBridge.usageText(fromJSON: json),
              case let .reading(b) = GeminiAppUsageParser.parse(text) else { return XCTFail() }
        XCTAssertNil(b.fiveHourUsed); XCTAssertEqual(b.weeklyUsed, 12.5)
        XCTAssertFalse(GeminiAppUsageParser.redactedSample("Usage account 12345").contains("12345"))
        XCTAssertFalse(GeminiAppUsageParser.redactedSample("Current usage account 1234567890: x").contains("1234567890"))
        XCTAssertTrue(GeminiAppUsageParser.redactedSample("Resets at 4:10 PM, 23% used").contains("4:10"))
        let fw = #"{"u":"https://gemini.google.com/usage","t":"Current usage\n＠＠bar Current usage = 70","b":[]}"#
        if case let .success(ft)? = LiveChromeBridge.usageText(fromJSON: fw) { XCTAssertEqual(GeminiAppUsageParser.parse(ft), .unknown) } else { XCTFail() }
        guard case let .reading(a) = GeminiAppUsageParser.parse("Current usage available 70%\nWeekly limit\nRemaining\n70%\n") else { return XCTFail() }
        XCTAssertEqual(a.fiveHourUsed, 30); XCTAssertEqual(a.weeklyUsed, 30)
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\n20%\n40%\n@@bar Current usage = 5"), .unknown)
        guard case let .reading(h) = GeminiAppUsageParser.parse("Current usage remaining\n70%\n") else { return XCTFail() }
        XCTAssertEqual(h.fiveHourUsed, 30)
        XCTAssertEqual(GeminiAppUsageParser.parse("Current usage\n23% of 80% used\n"), .unknown)
        XCTAssertEqual(GeminiAppUsageParser.parse("Usage\n@@bar Current usage Remaining = 70"), .unknown)
        let red = GeminiAppUsageParser.redactedSample("Current usage for Sample Person\nCurrent usage account ①②③\n現在の使用量\n23% used")
        XCTAssertFalse(red.contains("Sample")); XCTAssertFalse(red.contains("①"))
        XCTAssertFalse(GeminiAppUsageParser.redactedSample("Current usage for Inon").contains("Inon"))
        guard case let .reading(tr) = GeminiAppUsageParser.parse("Current usage\n23%\nTime remaining\n2 hours\n") else { return XCTFail() }
        XCTAssertEqual(tr.fiveHourUsed, 23)
        XCTAssertTrue(red.contains("現在の使用量")); XCTAssertTrue(red.contains("23% used"))
    }

    func testRedactedSampleDropsEmailAndChatter() {
        let s = GeminiAppUsageParser.redactedSample("aki@example.com\nHello there friend\nCurrent usage\n23% used")
        XCTAssertFalse(s.contains("aki@example.com")); XCTAssertFalse(s.contains("Hello"))
        XCTAssertTrue(s.contains("23% used"))
    }

    func testOversizedPageIsUnknownNotTruncated() {
        let big = "Current usage\n23% used\n" + String(repeating: "x", count: GeminiAppUsageParser.maxTextLength)
        XCTAssertEqual(GeminiAppUsageParser.parse(big), .unknown)
    }
}

final class GeminiReadPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func sig(_ dt: TimeInterval, front: Bool = true, idle: TimeInterval = 5, asleep: Bool = false, hour: Int = 14) -> GeminiReadPolicy.Signals {
        .init(now: t0.addingTimeInterval(dt), idleSeconds: idle, screenAsleep: asleep, hour: hour)
    }

    func testReadsOnceAtStartThenEveryFiveMinutes() {
        var st = GeminiReadPolicy.State(); var reads: [TimeInterval] = []
        for dt in stride(from: 0.0, through: 900, by: 30) where GeminiReadPolicy.shouldRead(st, sig(dt, front: true)) {
            reads.append(dt); st.lastRead = t0.addingTimeInterval(dt)
        }
        XCTAssertEqual(reads, [0, 300, 600, 900])
    }

    func testNoReadWhenIdle15MinAsleepNightOrHalted() {
        let st = GeminiReadPolicy.State()
        XCTAssertTrue(GeminiReadPolicy.shouldRead(st, sig(0, idle: 600)), "10 min idle still reads")
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, idle: 15 * 60)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, asleep: true)))
        XCTAssertFalse(GeminiReadPolicy.shouldRead(st, sig(0, front: true, hour: 3)))
        var halted = st; halted.halted = true
        XCTAssertFalse(GeminiReadPolicy.shouldRead(halted, sig(0, front: true)))
    }

    func testBackgroundReadNeedsNoFrontmostChrome() {
        let st = GeminiReadPolicy.State(lastRead: t0.addingTimeInterval(-600))
        XCTAssertTrue(GeminiReadPolicy.shouldRead(st, sig(10)))
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
    var invalidated = 0
    func invalidatePending() { invalidated += 1 }
    var closed = 0
    func closeDedicatedWindow() { closed += 1 }
}

@MainActor
final class GeminiAppUsageMonitorTests: XCTestCase {
    var defaults: UserDefaults!
    override func setUp() {
        defaults = UserDefaults(suiteName: "gemini-test-\(UUID().uuidString)")!
    }

    func make(_ b: FakeGeminiBridge, now: Date) -> GeminiAppUsageMonitor {
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        var upm = 0.0; m.uptime = { upm += 1000; return upm }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        return m
    }
    var noon: Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    func testStoredValueWhoseResetPassedIsUnknownAtLaunch() {
        let past = Date().addingTimeInterval(-60).timeIntervalSince1970
        defaults.set(["at": past - 3600, "windows": [["title": "Gemini · 5h", "left": 0.0, "reset": "Resets at 4:10 PM", "resetAt": past]]],
                     forKey: GeminiAppUsageMonitor.cacheKey)
        let m = GeminiAppUsageMonitor(bridge: FakeGeminiBridge(), defaults: defaults)
        XCTAssertTrue(m.section.windows.isEmpty, "no old % (and no lock) once the stored reset has passed")
        XCTAssertTrue(m.section.failureText?.contains("要更新") == true)
    }

    func testStoredValueWithFutureResetIsKeptAsStale() {
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        defaults.set(["at": Date().timeIntervalSince1970 - 60, "windows": [["title": "Gemini · 5h", "left": 0.0, "reset": "x", "resetAt": future]]],
                     forKey: GeminiAppUsageMonitor.cacheKey)
        let m = GeminiAppUsageMonitor(bridge: FakeGeminiBridge(), defaults: defaults)
        XCTAssertEqual(m.section.windows.first?.resetAt?.timeIntervalSince1970 ?? 0, future, accuracy: 1)
        XCTAssertTrue(m.section.isStale)
    }

    func testAsleepTabShowsUnknownWithoutHalting() async {
        let b = FakeGeminiBridge(); b.text = .failure(.tabAsleep)
        let m = make(b, now: noon)
        await m.setEnabled(true)
        XCTAssertTrue(m.section.windows.isEmpty)
        XCTAssertTrue(m.section.failureText?.contains("スリープ") == true)
        XCTAssertFalse(m.state.halted, "a sleeping tab must not stop future reads")
    }

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

    func testChromeNotRunningNeverReadsButBackgroundChromeDoes() async {
        let b = FakeGeminiBridge(); b.chromeRunning = false
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        await m.tick(); XCTAssertEqual(b.urlReads + b.textReads, 0)
        b.chromeRunning = true; b.chromeFrontmost = false; b.url = "https://mail.google.com/"
        await m.tick()
        XCTAssertEqual(b.textReads, 1, "Chrome in the background with another tab selected still reads")
        XCTAssertEqual(b.urlReads, 0, "the selected tab is not even asked for")
    }

    func testIdleMacDoesNotRead() async {
        let b = FakeGeminiBridge(); let m = make(b, now: noon); m.idleSeconds = { 16 * 60 }
        defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        await m.tick(); XCTAssertEqual(b.textReads, 0)
    }

    func testOldPageIsMarkedWithItsAge() async {
        let b = FakeGeminiBridge(); let now = noon
        let loaded = Int(now.timeIntervalSince1970) - 3 * 3600
        b.text = .success("Usage limits\nCurrent usage\n40% used\n@@loaded \(loaded)")
        let m = make(b, now: now)
        await m.setEnabled(true)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60])
        XCTAssertTrue(m.section.isStale)
        XCTAssertTrue(m.section.failureText?.contains("3時間前") ?? false, m.section.failureText ?? "")
    }

    func testRecentPageIsFresh() async {
        let b = FakeGeminiBridge(); let now = noon
        b.text = .success("Usage limits\nCurrent usage\n40% used\n@@loaded \(Int(now.timeIntervalSince1970) - 60)")
        let m = make(b, now: now)
        await m.setEnabled(true)
        XCTAssertFalse(m.section.isStale)
    }

    func testPageTextCannotSpoofLoadedMarker() {
        let json = #"{"u":"https://gemini.google.com/usage","t":"@@loaded 1\nCurrent usage\n4% used","b":[]}"#
        guard case let .success(text)? = LiveChromeBridge.usageText(fromJSON: json) else { return XCTFail() }
        XCTAssertNil(GeminiAppUsageParser.pageLoadedAt(text))
        let json2 = #"{"u":"https://gemini.google.com/usage","t":"x","b":[],"o":1800000000000}"#
        guard case let .success(t2)? = LiveChromeBridge.usageText(fromJSON: json2) else { return XCTFail() }
        XCTAssertEqual(GeminiAppUsageParser.pageLoadedAt(t2), Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testVerificationPageHaltsAndKeepsLastValueAsStale() async {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        var upm = 0.0; m.uptime = { upm += 1000; return upm }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
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

    func testNonGeminiFrontTabStillReadsUsageTabInBackground() async {
        let b = FakeGeminiBridge(); b.url = "https://mail.google.com/"
        let m = make(b, now: noon); defaults.set(true, forKey: GeminiAppUsageMonitor.enabledKey)
        await m.tick()
        XCTAssertEqual(b.textReads, 1)
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
        var upm = 0.0; m.uptime = { upm += 1000; return upm }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        b.text = .success("Current usage\n40% used")
        now = now.addingTimeInterval(3600)
        let restarted = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        var uprestarted = 0.0; restarted.uptime = { uprestarted += 1000; return uprestarted }; restarted.clock = { now }; restarted.idleSeconds = { 1 }; restarted.screenAsleep = { false }
        await restarted.tick()
        XCTAssertEqual(b.textReads, 1)
        await restarted.setEnabled(true)
        XCTAssertEqual(b.textReads, 2)
    }

    func testToggleOffDropsQueuedChromeWork() async {
        let b = FakeGeminiBridge(); let m = make(b, now: noon)
        await m.setEnabled(true); await m.setEnabled(false)
        XCTAssertEqual(b.invalidated, 1)
        XCTAssertEqual(b.closed, 1, "toggle-off closes only our own hidden window")
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
        var upm = 0.0; m.uptime = { upm += 1000; return upm }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
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
        var upm = 0.0; m.uptime = { upm += 1000; return upm }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        XCTAssertFalse(m.section.isStale)
        m.idleSeconds = { 3600 }
        now = now.addingTimeInterval(GeminiReadPolicy.staleAfter + 1); await m.tick()
        XCTAssertTrue(m.section.isStale)
        XCTAssertEqual(m.section.windows.map(\.leftPercent), [60, 90])
        XCTAssertEqual(b.textReads, 1)
    }

    func testWallClockJumpForwardDoesNotShortenSpacing() async {
        let b = FakeGeminiBridge(); var now = noon
        let m = GeminiAppUsageMonitor(bridge: b, defaults: defaults)
        m.uptime = { 500 }; m.clock = { now }; m.idleSeconds = { 1 }; m.screenAsleep = { false }
        await m.setEnabled(true)
        XCTAssertEqual(b.textReads, 1)
        now = now.addingTimeInterval(GeminiReadPolicy.interval + 60); await m.tick()
        XCTAssertEqual(b.textReads, 1) // only 0 s of real time passed
    }

    func testStoreMergeKeepsOtherProviders() async {
        let base = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: Date())
        let g = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        let merged = MultiUsageStore.withGemini(g, in: MultiUsageStore.withGemini(g, in: base))
        XCTAssertEqual(merged.sections.map(\.provider), [.codex, .gemini])
    }

    // Structure of the real ja page (2026-10-29); numbers, times and chat titles replaced.
    func testRealJapaneseUsagePage20261029() {
        let raw = """
        Gemini
        チャットを新規作成
        Pro
        使用量上限
        PRO

        Gemini を使用できる時間は、プランの上限によって決まります。高度なモデルや機能を使用すると、さらに使用量が多くなる可能性があります。詳細

        更新: 7 分前

        現在の使用量
        info
        3% 使用中
        2:15にリセット
        1 週間の上限
        1月9日の6:05にリセットされます
        27% 使用中
        AI Ultra なら使用量が 5 倍に
        月額 ￥14,500
        アップグレード
        """
        guard case let .reading(r) = GeminiAppUsageParser.parse(raw) else { return XCTFail("unreadable") }
        XCTAssertEqual(r.fiveHourUsed, 3)
        XCTAssertEqual(r.weeklyUsed, 27)
    }

    func testPicksAkisChromeNotHeadlessOrphan() {
        let headless = ChromeInstance(pid: 2847, regular: false, terminated: false, active: false, launched: Date(timeIntervalSince1970: 10))
        let real = ChromeInstance(pid: 411, regular: true, terminated: false, active: false, launched: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(ChromeInstance.pick([headless, real]), 411)
        XCTAssertNil(ChromeInstance.pick([headless]))
        let other = ChromeInstance(pid: 9, regular: true, terminated: false, active: true, launched: Date(timeIntervalSince1970: 30))
        XCTAssertEqual(ChromeInstance.pick([real, other]), 9)
        let dead = ChromeInstance(pid: 5, regular: true, terminated: true, active: true, launched: nil)
        XCTAssertEqual(ChromeInstance.pick([dead, real]), 411)
        let noDate = ChromeInstance(pid: 7, regular: true, terminated: false, active: false, launched: nil)
        XCTAssertEqual(ChromeInstance.pick([noDate, real]), 411)
    }

    func testSessionPinsOneChromeForWholeRead() {
        let a = ChromeIdentity(pid: 411, launched: Date(timeIntervalSince1970: 20), bundleID: "com.google.Chrome", regular: true, terminated: false)
        let session = ChromeSession()
        XCTAssertNil(session.target)
        let seen: [pid_t?] = session.run(pinning: a) { [session.target?.pid, session.target?.pid] }
        XCTAssertEqual(seen, [411, 411])
        XCTAssertNil(session.target, "no target outside a read slot")
        XCTAssertNil(session.run(pinning: nil) { session.target })
    }

    func testPinnedChromeFailsClosedOnReuseOrChange() {
        let a = ChromeIdentity(pid: 411, launched: Date(timeIntervalSince1970: 20), bundleID: "com.google.Chrome", regular: true, terminated: false)
        XCTAssertTrue(a.stillSame(as: a))
        var reused = a; reused.launched = Date(timeIntervalSince1970: 99)
        XCTAssertFalse(a.stillSame(as: reused), "same pid, new process")
        var headless = a; headless.regular = false
        XCTAssertFalse(a.stillSame(as: headless))
        var gone = a; gone.terminated = true
        XCTAssertFalse(a.stillSame(as: gone))
        var other = a; other.bundleID = "com.example.Other"
        XCTAssertFalse(a.stillSame(as: other))
        XCTAssertFalse(a.stillSame(as: nil))
        var noDate = a; noDate.launched = nil
        XCTAssertFalse(noDate.stillSame(as: noDate), "no launch date = cannot prove identity")
    }
}

@MainActor final class GeminiResetResolutionTests: XCTestCase {
    private let cal = Calendar.current
    private func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: day, hour: h, minute: mi))!
    }

    func testResetTextParsesRelativeToPageLoad() {
        let loaded = d(2026, 10, 29, 15, 0)
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("Resets at 4:10 PM", after: loaded), d(2026, 10, 29, 16, 10))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("Resets at 2:10 PM", after: loaded), d(2026, 10, 30, 14, 10))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("16:10にリセット", after: loaded), d(2026, 10, 29, 16, 10))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("Resets Nov 2", after: loaded), d(2026, 11, 2, 0, 0))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("11月2日にリセット", after: loaded), d(2026, 11, 2, 0, 0))
        XCTAssertNil(GeminiAppUsageMonitor.resetDate("", after: loaded))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("11月4日の7:39にリセットされます", after: loaded), d(2026, 11, 4, 7, 39))
        XCTAssertEqual(GeminiAppUsageMonitor.resetDate("0:39にリセット", after: loaded), d(2026, 10, 30, 0, 39))
    }

    func testPassedResetDropsOldPercentAndAsksForReload() {
        let loaded = d(2026, 10, 29, 15, 0)
        let s = ProviderSection(provider: .gemini, windows: [
            UsageLimit(title: "Gemini · 5h", leftPercent: 0, resetText: "Resets at 4:10 PM"),
            UsageLimit(title: "Gemini · Weekly", leftPercent: 40, resetText: "Resets Nov 2")
        ], stats: [], failureText: nil)
        let later = GeminiAppUsageMonitor.resolvingResets(s, pageLoaded: loaded, now: d(2026, 10, 29, 17, 0))
        XCTAssertEqual(later.windows.map(\.title), ["Gemini · Weekly"])
        XCTAssertTrue(later.isStale)
        XCTAssertTrue(later.failureText?.contains("要更新") == true)
        let before = GeminiAppUsageMonitor.resolvingResets(s, pageLoaded: loaded, now: d(2026, 10, 29, 15, 30))
        XCTAssertEqual(before.windows.count, 2)
        XCTAssertEqual(before.windows.first?.resetAt, d(2026, 10, 29, 16, 10))
        XCTAssertFalse(before.isStale)
    }
}


final class GeminiDedicatedWindowTests: XCTestCase {
    func testReopensAtMostHourly() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(GeminiDedicatedWindow.mayOpen(lastOpen: nil, now: t))
        XCTAssertFalse(GeminiDedicatedWindow.mayOpen(lastOpen: t, now: t.addingTimeInterval(3599)))
        XCTAssertTrue(GeminiDedicatedWindow.mayOpen(lastOpen: t, now: t.addingTimeInterval(3600)))
    }
}
