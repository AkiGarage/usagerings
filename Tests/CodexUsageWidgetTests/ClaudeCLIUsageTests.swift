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

    func testOneFailingAccountKeepsTheOtherAndProxyStaysFallback() async {
        let usage = cli(CallLog(), failB: true)
        await usage.refreshNow([a, b], timeZone: .current)
        let result = usage.section(accounts: [a, b], now: Date(), timeZone: .current, salt: salt)
        XCTAssertEqual(result?.section.forAccount(0).windows.count, 2)
        XCTAssertEqual(result?.section.forAccount(1).failureText?.hasPrefix("取得失敗"), true)

        let none = ClaudeCLIUsage(runner: { _, _ in .init(terminationStatus: 1, stdout: Data(), stderr: Data()) })
        await none.refreshNow([a], timeZone: .current)
        let proxy = ProviderSection(provider: .claude, windows: [], stats: [], failureText: "x")
        XCTAssertNil(none.section(accounts: [a], now: Date(), timeZone: .current, salt: salt))
        XCTAssertEqual(ClaudeCLIUsage.merge(cli: nil, proxy: proxy)?.stats.last?.valueText, "CLIProxyAPI（予備）")
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
