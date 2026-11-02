import XCTest
@testable import CodexUsageWidget

final class ClaudeCLIUsageTests: XCTestCase {
    private static func json(_ five: Int, _ week: Int) -> Data {
        Data("""
        [{"provider":"claude","source":"claude","usage":{"primary":{"usedPercent":\(five),"windowMinutes":300,"resetsAt":"2026-10-30T07:50:00Z"},"secondary":{"usedPercent":\(week),"windowMinutes":10080,"resetsAt":"2026-11-02T00:00:00Z"}}}]
        """.utf8)
    }
    private let salt = Data(repeating: 7, count: 32)
    private let a = ClaudeCLIAccount(label: "A", configDir: "/h/.claude-a")
    private let b = ClaudeCLIAccount(label: "B", configDir: "/h/.claude-b")

    private func cli(_ calls: CallLog, failB: Bool = false) -> ClaudeCLIUsage {
        ClaudeCLIUsage(runner: { args, env in
            calls.append(args, env)
            let dir = env?["CLAUDE_CONFIG_DIR"]
            if failB, dir == "/h/.claude-b" {
                return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
            }
            return CodexUsageService.CommandResult(terminationStatus: 0,
                stdout: dir == "/h/.claude-b" ? Self.json(0, 0) : Self.json(30, 72), stderr: Data())
        })
    }

    func testFetchesEachConfigDirSequentiallyWithEnvAndCLISource() async {
        let calls = CallLog()
        let usage = cli(calls)
        let t0 = Date()
        XCTAssertNil(usage.section(accounts: [a, b], now: t0, timeZone: .current, salt: salt), "never waits")
        for _ in 0..<200 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.envs, ["/h/.claude-a", "/h/.claude-b"])
        XCTAssertTrue(calls.args.allSatisfy { $0 == ClaudeCLIUsage.arguments })
        XCTAssertEqual(calls.maxConcurrent, 1)

        let section = usage.section(accounts: [a, b], now: t0, timeZone: .current, salt: salt)!.section
        XCTAssertEqual(section.accountIndices, [0, 1])
        XCTAssertEqual(section.forAccount(0).windows.map(\.leftPercent), [70, 28])
        XCTAssertEqual(section.forAccount(1).windows.map(\.leftPercent), [100, 100])
        XCTAssertEqual(section.accounts.map(\.id), [a.accountID(salt: salt), b.accountID(salt: salt)])
        XCTAssertNotEqual(a.accountID(salt: salt), b.accountID(salt: salt))
        XCTAssertTrue(section.forAccount(1).stats.contains { $0.valueText.hasPrefix("CodexBar CLI · B") })
    }

    func testOldCacheExpiresToProxy() async {
        let usage = cli(CallLog())
        await usage.refreshNow([a], timeZone: .current)
        let later = Date().addingTimeInterval(700)
        XCTAssertNil(usage.section(accounts: [a], now: later, timeZone: .current, salt: salt))
    }

    func testDefaultAccountHasNoEnvOverride() async {
        let calls = CallLog()
        let usage = cli(calls)
        await usage.refreshNow([ClaudeCLIAccount(label: "Claude", configDir: nil)], timeZone: .current)
        XCTAssertEqual(calls.rawEnvs.count, 1)
        XCTAssertEqual(calls.rawEnvs[0], ["CLAUDE_CONFIG_DIR": ""])  // blank = strip inherited value
    }

    func testStaleValueIsMarkedPerAccountWithPreviousTime() async {
        let usage = cli(CallLog(), failB: true)
        let t0 = Date()
        await usage.refreshNow([a, b], timeZone: .current, now: { t0 })
        let fresh = usage.section(accounts: [a, b], now: t0.addingTimeInterval(60), timeZone: .current, salt: salt)!
        XCTAssertFalse(fresh.section.accounts[0].isStale)
        let old = usage.section(accounts: [a, b], now: t0.addingTimeInterval(usage.staleAge + 1), timeZone: .current, salt: salt)!
        XCTAssertTrue(old.fromCache)
        XCTAssertTrue(old.section.accounts[0].isStale)
        XCTAssertEqual(old.section.accounts[0].failureText?.hasPrefix("前回値（"), true)
        XCTAssertEqual(RingDetailCardView.staleLine(staleFailureText(old.section.accounts[0].failureText))?.hasPrefix("前回値（"), true)
    }

    func testSettingsChangeRestartsQueueAndDropsRemovedFolders() async {
        let calls = CallLog()
        let gate = Gate()
        let usage = ClaudeCLIUsage(runner: { args, env in
            calls.append(args, env)
            if env?["CLAUDE_CONFIG_DIR"] == "/h/.claude-a" { await gate.wait() }
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Self.json(10, 20), stderr: Data())
        })
        let t0 = Date()
        _ = usage.section(accounts: [a], now: t0, timeZone: .current, salt: salt)  // starts a queue blocked on A
        for _ in 0..<200 where calls.count < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        _ = usage.section(accounts: [b], now: t0, timeZone: .current, salt: salt)  // settings changed: new queue for B
        for _ in 0..<200 where calls.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls.envs, ["/h/.claude-a", "/h/.claude-b"])
        await gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        let result = usage.section(accounts: [b], now: t0, timeZone: .current, salt: salt)
        XCTAssertEqual(result?.section.accounts.count, 1)
        XCTAssertNil(result?.section.accounts[0].failureText)
        // The old run's late result for A was dropped.
        let back = usage.section(accounts: [a], now: t0, timeZone: .current, salt: salt)
        XCTAssertNil(back, "A's stale-generation value must not be stored")
    }

    func testOldProxyLabelMigratesToFolderAccount() {
        let proxyB = AccountID(provider: .claude, source: "proxy-account-id", value: "pb", salt: salt)
        var prefs = AccountPreferences()
        prefs.setLabel("仕事", for: proxyB)
        let folder = b.accountID(salt: salt).merging(proxyB)
        var section = ProviderSection(provider: .claude, windows: [], stats: [], failureText: nil)
        section.accounts = [ProviderAccount(index: 0, id: folder)]
        section.accountInventoryComplete = true
        prefs.reconcile(MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: Date()), salt: salt)
        XCTAssertEqual(prefs.label(for: folder), "仕事")
    }

    func testDetectionAndParsing() {
        XCTAssertEqual(ClaudeCLIAccountSettings.detected(home: "/h", isDirectory: { _ in false }),
                       [ClaudeCLIAccount(label: "Claude", configDir: nil)])
        XCTAssertEqual(ClaudeCLIAccountSettings.detected(home: "/h", isDirectory: { _ in true }).map(\.label), ["A", "B"])
        XCTAssertEqual(ClaudeCLIAccountSettings.detected(home: "/h", isDirectory: { $0.hasSuffix("-b") }).map(\.configDir), ["/h/.claude-b"])
        let parsed = ClaudeCLIAccountSettings.parse("A = ~/.claude-a\nMain = ~/.claude\n\n= x\nB ~/.claude-b", home: "/h")
        XCTAssertEqual(parsed, [ClaudeCLIAccount(label: "A", configDir: "/h/.claude-a"), ClaudeCLIAccount(label: "Main", configDir: nil)])
        let defaults = UserDefaults(suiteName: "ClaudeCLIUsageTests-\(UUID())")!
        ClaudeCLIAccountSettings.save(parsed, defaults: defaults)
        XCTAssertEqual(ClaudeCLIAccountSettings.load(defaults: defaults, home: "/h", isDirectory: { _ in false }), parsed)
    }

    func testLicenseTextIsComplete() {
        XCTAssertTrue(Acknowledgements.codexBarLicense.contains("Copyright (c) 2026 Peter Steinberger"))
        XCTAssertTrue(Acknowledgements.codexBarLicense.contains("The above copyright notice and this permission notice shall be included"))
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maxConcurrent = 0
    private var entries: [([String], [String: String]?)] = []
    func append(_ args: [String], _ env: [String: String]?) {
        lock.lock(); entries.append((args, env)); active += 1; maxConcurrent = max(maxConcurrent, active); active -= 1; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    var args: [[String]] { lock.lock(); defer { lock.unlock() }; return entries.map(\.0) }
    var rawEnvs: [[String: String]?] { lock.lock(); defer { lock.unlock() }; return entries.map(\.1) }
    var envs: [String?] { rawEnvs.map { $0?["CLAUDE_CONFIG_DIR"] } }
}

actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

final class WindowLockParityTests: XCTestCase {
    func testWindowRowLockMatchesTabRingForEveryProvider() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func w(_ t: String, _ p: Double, account: Int? = nil) -> UsageLimit {
            var l = UsageLimit(title: t, leftPercent: p, resetText: "Resets in 2h")
            l.resetAt = now.addingTimeInterval(7200); l.accountIndex = account; return l
        }
        let snap = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .antigravity, windows: [w("Gemini 4 Argon · 5h", 0), w("Gemini Models · Weekly", 70)], stats: [], failureText: nil),
            ProviderSection(provider: .zai, windows: [w("5h", 50), w("MCP monthly", 0)], stats: [], failureText: nil),
            ProviderSection(provider: .codex, windows: [w("5h", 0)], stats: [], failureText: nil),
        ], codexSnapshot: nil, updatedAt: now)
        let rows = ServiceRowModel.rows(for: snap)
        let bars = CollapsedUsageBar.bars(for: snap, blockedPreview: nil)
        let argonRow = rows.first { $0.name.localizedCaseInsensitiveContains("argon") }
        let argonBar = bars.first { $0.title.localizedCaseInsensitiveContains("argon") }
        XCTAssertNotNil(argonRow?.block); XCTAssertNotNil(argonBar?.block)
        XCTAssertNil(rows.first { $0.id.hasPrefix("zai") }?.block, "GLM MCP 0% is not a lock")
        XCTAssertNotNil(rows.first { $0.id.hasPrefix("codex") }?.block)
        XCTAssertNil(rows.first { $0.name.contains("Gemini Models") }?.block)
    }
}
