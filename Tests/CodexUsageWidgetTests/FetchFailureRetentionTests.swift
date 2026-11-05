import XCTest
@testable import CodexUsageWidget

@MainActor
final class FetchFailureRetentionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T02:00:00Z")!

    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private func service(_ runner: @escaping CodexUsageService.CommandRunner) -> MultiUsageService {
        MultiUsageService(commandRunner: runner, retryDelay: 0)
    }

    private func zaiRunner(status: Int32 = 0, stdout: String? = nil, stderr: String = "") -> CodexUsageService.CommandRunner {
        { arguments in
            arguments[2] == "zai"
                ? .init(terminationStatus: status, stdout: Data((stdout ?? Fixtures.zai).utf8), stderr: Data(stderr.utf8))
                : Fixtures.commandResult("[]")
        }
    }

    private func retained(_ fresh: MultiUsageSnapshot, previous: MultiUsageSnapshot, at time: Date) -> MultiUsageSnapshot {
        MultiUsageStore.retainingStaleValues(in: fresh, previous: previous, now: time)
    }

    func testNonZeroExitRetainsLastGoodValueMarkedStale() async {
        let good = await service(zaiRunner()).fetchAll(now: now, timeZone: utc, calendar: utcCalendar)
        let stamped = retained(good, previous: MultiUsageSnapshot(sections: [], codexSnapshot: nil, updatedAt: now), at: now)
        let zaiGood = stamped.sections.first { $0.provider == .zai }!
        XCTAssertEqual(zaiGood.windows.map(\.leftPercent), [90])

        let failed = await service(zaiRunner(status: 1, stdout: "[]", stderr: "HTTP 500 upstream"))
            .fetchAll(now: now.addingTimeInterval(5), timeZone: utc, calendar: utcCalendar)
        let failing = failed.sections.first { $0.provider == .zai }!
        XCTAssertEqual(failing.failureReason, .providerError)
        XCTAssertTrue(failing.windows.isEmpty)

        let result = retained(failed, previous: stamped, at: now.addingTimeInterval(5))
        let zai = result.sections.first { $0.provider == .zai }!
        XCTAssertEqual(zai.windows.map(\.leftPercent), [90])
        XCTAssertTrue(zai.isStale)
    }

    func testLogoutFailureShowsNoValue() async {
        let good = await service(zaiRunner()).fetchAll(now: now, timeZone: utc, calendar: utcCalendar)
        let stamped = retained(good, previous: MultiUsageSnapshot(sections: [], codexSnapshot: nil, updatedAt: now), at: now)

        let loggedOut = await service(zaiRunner(status: 1, stdout: #"{"provider":"zai","error":{"message":"Not logged in"}}"#))
            .fetchAll(now: now.addingTimeInterval(5), timeZone: utc, calendar: utcCalendar)
        let section = loggedOut.sections.first { $0.provider == .zai }!
        XCTAssertEqual(section.failureReason, .logout)

        let result = retained(loggedOut, previous: stamped, at: now.addingTimeInterval(5))
        XCTAssertTrue(result.sections.first { $0.provider == .zai }!.windows.isEmpty)
    }

    func testParseFailureRetainsLastGoodValue() async {
        let good = await service(zaiRunner()).fetchAll(now: now, timeZone: utc, calendar: utcCalendar)
        let stamped = retained(good, previous: MultiUsageSnapshot(sections: [], codexSnapshot: nil, updatedAt: now), at: now)

        for payload in ["[]", "not json at all"] {
            let failed = await service(zaiRunner(stdout: payload))
                .fetchAll(now: now.addingTimeInterval(5), timeZone: utc, calendar: utcCalendar)
            XCTAssertEqual(failed.sections.first { $0.provider == .zai }?.failureReason, .providerError, payload)
            let result = retained(failed, previous: stamped, at: now.addingTimeInterval(5))
            let zai = result.sections.first { $0.provider == .zai }!
            XCTAssertEqual(zai.windows.map(\.leftPercent), [90], payload)
            XCTAssertTrue(zai.isStale, payload)
        }
    }

    func testPartialMultiAccountRetainsOnlyTheFailedAccount() async {
        let good = await service { arguments in
            arguments[2] == "codex"
                ? Fixtures.commandResult("[\(Fixtures.codexFirst),\(Fixtures.codexSecond)]")
                : Fixtures.commandResult("[]")
        }.fetchAll(now: now, timeZone: utc, calendar: utcCalendar)
        let stamped = retained(good, previous: MultiUsageSnapshot(sections: [], codexSnapshot: nil, updatedAt: now), at: now)
        let healthy = stamped.sections.first { $0.provider == .codex }!
        XCTAssertEqual(healthy.windows.compactMap(\.accountIndex).sorted(), [0, 1])

        let partial = await service { arguments in
            arguments[2] == "codex"
                ? Fixtures.commandResult("[\(Fixtures.codexFirst),\(Fixtures.codexSecondFailed)]", status: 1)
                : Fixtures.commandResult("[]")
        }.fetchAll(now: now.addingTimeInterval(5), timeZone: utc, calendar: utcCalendar)
        let failing = partial.sections.first { $0.provider == .codex }!
        XCTAssertEqual(failing.failureText, "Some accounts unavailable")
        XCTAssertEqual(failing.accounts[1].failureReason, .providerError)

        let result = retained(partial, previous: stamped, at: now.addingTimeInterval(5))
        let codex = result.sections.first { $0.provider == .codex }!
        XCTAssertEqual(codex.windows.filter { $0.accountIndex == 0 }.map(\.leftPercent), [80])
        XCTAssertEqual(codex.windows.filter { $0.accountIndex == 1 }.map(\.leftPercent), [40])
        XCTAssertEqual(codex.accounts.map(\.isStale), [false, true])
    }

    func testFetchFailureLogRecordsSanitizedLines() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fetch-failures.log")
        let service = MultiUsageService(
            commandRunner: { arguments in
                arguments[2] == "codex"
                    ? Fixtures.commandResult(#"[{"provider":"codex","error":{"kind":"provider","code":503}}]"#, status: 1)
                    : Fixtures.commandResult("[]")
            },
            retryDelay: 0,
            failureLog: FetchFailureLog(fileURL: url)
        )
        _ = await service.fetchAll(timeZone: utc, calendar: utcCalendar)

        let line = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").first { $0.contains("\tcodex\t") }
        let fields = try XCTUnwrap(line).components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields[1], "codex")
        XCTAssertEqual(fields[2], "providerError")
        XCTAssertEqual(fields[3], "1")
        XCTAssertEqual(fields[4], "CodexBarCLI exited 1: Codex provider error (provider, code 503)")
    }

    func testFetchFailureLogFlattensProviderAndMessageSeparators() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fetch-failures.log")
        FetchFailureLog(fileURL: url).record(
            provider: "claude-cli(A\tcopy\n2)",
            reason: .providerError,
            exitCode: 3,
            message: "first line\nsecond line\twith tab aki@example.com",
            at: now
        )
        let line = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n").first { !$0.isEmpty }
        let fields = try XCTUnwrap(line).components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 5, "separators must not break the one-line record")
        XCTAssertEqual(fields[1], "claude-cli(A copy 2)")
        XCTAssertEqual(fields[4], "first line second line with tab [redacted]")
    }

    func testClaudeAccountTransientFailureRetainsCachedValueStale() async {
        let runner = FlippableCLIRunner()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in runner.run(arguments, environment) })
        let t0 = ISO8601DateFormatter().date(from: "2026-11-05T02:00:00Z")!
        await usage.refreshNow([runner.accountA], timeZone: utc, now: { t0 })
        let fresh = usage.section(accounts: [runner.accountA], now: t0.addingTimeInterval(1), timeZone: utc)
        XCTAssertEqual(fresh?.section.forAccount(0).windows.isEmpty, false)

        runner.setMode(.http500, for: runner.accountA)
        let t1 = t0.addingTimeInterval(60)
        await usage.refreshNow([runner.accountA], timeZone: utc, now: { t1 })
        let stale = usage.section(accounts: [runner.accountA], now: t1.addingTimeInterval(1), timeZone: utc)
        XCTAssertEqual(stale?.section.forAccount(0).windows.isEmpty, false, "transient failure retains the young cache")
        XCTAssertEqual(stale?.section.accounts.first?.isStale, true)
        XCTAssertEqual(stale?.section.accounts.first?.failureText?.hasPrefix("前回値（"), true)
        let displayed = MultiUsageStore.retainingStaleValues(
            in: MultiUsageSnapshot(sections: [stale!.section], codexSnapshot: nil, updatedAt: t1), previous: nil, now: t1.addingTimeInterval(1))
        XCTAssertEqual(displayed.sections.first?.windows.isEmpty, false, "the store must still show the cached Claude value")
    }

    func testClaudeAccountLogoutSuppressesCachedValueImmediately() async {
        let runner = FlippableCLIRunner()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in runner.run(arguments, environment) })
        let t0 = ISO8601DateFormatter().date(from: "2026-11-05T02:00:00Z")!
        await usage.refreshNow([runner.accountA, runner.accountB], timeZone: utc, now: { t0 })
        let cached = usage.section(accounts: [runner.accountA, runner.accountB], now: t0.addingTimeInterval(1), timeZone: utc)
        XCTAssertEqual(cached?.section.forAccount(0).windows.isEmpty, false)

        runner.setMode(.logout, for: runner.accountA)
        let t1 = t0.addingTimeInterval(60)
        await usage.refreshNow([runner.accountA, runner.accountB], timeZone: utc, now: { t1 })
        let loggedOut = usage.section(accounts: [runner.accountA, runner.accountB], now: t1.addingTimeInterval(1), timeZone: utc)
        XCTAssertEqual(loggedOut?.section.forAccount(0).windows.isEmpty, true, "logged-out cache must be suppressed at once")
        XCTAssertEqual(loggedOut?.section.accounts.first?.failureReason, .logout)
        XCTAssertEqual(loggedOut?.section.accounts.first?.failureText?.hasPrefix("取得失敗"), true)
        XCTAssertEqual(loggedOut?.section.forAccount(1).windows.isEmpty, false)
    }

    func testFetchFailureLogRedactsRecordedMessages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("fetch-failures.log")
        FetchFailureLog(fileURL: url).record(
            provider: "claude-cli(A)",
            reason: .providerError,
            exitCode: 1,
            message: "mail aki@example.com key sk-proj-AbCdEf123456 bearer Bearer AbCdEf123456 jwt eyJhbGciOiJIUzI1NiJ9.run long ABCDEFGHIJKLMNOPQRSTUVWX",
            at: now
        )
        let line = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(line.contains("aki@example.com"))
        XCTAssertFalse(line.contains("sk-proj-AbCdEf123456"))
        XCTAssertFalse(line.contains("Bearer AbCdEf123456"))
        XCTAssertFalse(line.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(line.contains("ABCDEFGHIJKLMNOPQRSTUVWX"))
        XCTAssertTrue(line.contains("claude-cli(A)"))
        XCTAssertTrue(line.contains("[redacted]"))
    }

    func testRedactionCoversEmailKeyJWTBearerAndLongRuns() {
        let redacted = FetchFailureLog.redacted(
            "mail aki@example.com key sk-proj-AbCdEf123456 bearer Bearer AbCdEf123456 jwt eyJhbGciOiJIUzI1NiJ9.run long ABCDEFGHIJKLMNOPQRSTUVWX")
        XCTAssertFalse(redacted.contains("aki@example.com"))
        XCTAssertFalse(redacted.contains("sk-proj-AbCdEf123456"))
        XCTAssertFalse(redacted.contains("Bearer AbCdEf123456"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(redacted.contains("ABCDEFGHIJKLMNOPQRSTUVWX"))
    }

    func testRunnerIsCalledTwiceOnExitOneAndOnceOnLogout() async {
        let exitOne = ProviderCallCount()
        _ = await service({ arguments in
            if arguments[2] == "zai" { exitOne.increment() }
            return arguments[2] == "zai"
                ? Fixtures.commandResult(#"{"provider":"zai","error":{"message":"HTTP 503"}}"#, status: 1)
                : Fixtures.commandResult("[]")
        }).fetchAll(timeZone: utc, calendar: utcCalendar)
        XCTAssertEqual(exitOne.count, 2)

        let loggedOut = ProviderCallCount()
        _ = await service({ arguments in
            if arguments[2] == "zai" { loggedOut.increment() }
            return arguments[2] == "zai"
                ? Fixtures.commandResult(#"{"provider":"zai","error":{"message":"Not logged in"}}"#, status: 1)
                : Fixtures.commandResult("[]")
        }).fetchAll(timeZone: utc, calendar: utcCalendar)
        XCTAssertEqual(loggedOut.count, 1)
    }

    func testLogRotatesPast256KB() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent("fetch-failures.log")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: FetchFailureLog.byteCap + 1).write(to: url)
        let rotated = url.appendingPathExtension("1")

        FetchFailureLog(fileURL: url).record(provider: "zai", reason: .providerError, exitCode: 1,
                                             message: "rotated", at: now)

        XCTAssertEqual(try fileManager.attributesOfItem(atPath: rotated.path)[.size] as? Int, FetchFailureLog.byteCap + 1)
        let fresh = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(fresh.contains("\tzai\tproviderError\t1\trotated"), fresh)
        XCTAssertLessThan(try fileManager.attributesOfItem(atPath: url.path)[.size] as! Int, 200)
    }
}

private final class ProviderCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}

private final class FlippableCLIRunner: @unchecked Sendable {
    enum Mode { case good, http500, logout }

    let accountA = ClaudeCLIAccount(label: "A", configDir: "/tmp/claude-a")
    let accountB = ClaudeCLIAccount(label: "B", configDir: "/tmp/claude-b")
    private let lock = NSLock()
    private var modes: [String: Mode] = [:]

    func setMode(_ mode: Mode, for account: ClaudeCLIAccount) {
        lock.lock(); defer { lock.unlock() }
        modes[account.configDir ?? ""] = mode
    }

    func run(_ arguments: [String], _ environment: [String: String]?) -> CodexUsageService.CommandResult {
        lock.lock(); defer { lock.unlock() }
        let dir = environment?["CLAUDE_CONFIG_DIR"] ?? ""
        switch modes[dir] ?? .good {
        case .good:
            let percent = dir == "/tmp/claude-b" ? 40 : 30
            return Fixtures.commandResult(#"[{"provider":"claude","usage":{"primary":{"usedPercent":\#(percent),"windowMinutes":300,"resetsAt":"2026-11-05T06:00:00Z"}}}]"#)
        case .http500:
            return .init(terminationStatus: 1, stdout: Data("[]".utf8), stderr: Data("HTTP 500 upstream".utf8))
        case .logout:
            return .init(terminationStatus: 1, stdout: Data("[]".utf8), stderr: Data("Error: not logged in, please log in".utf8))
        }
    }
}

private enum Fixtures {
    static let zai = """
        [
          {
            "provider": "zai",
            "usage": {
              "primary": { "usedPercent": 10, "windowMinutes": 300, "resetsAt": "2026-11-05T06:00:00Z" }
            }
          }
        ]
        """

    static let codexFirst = #"{"provider":"codex","usage":{"identity":{"accountID":"acct-0"},"primary":{"usedPercent":20,"windowMinutes":300}}}"#
    static let codexSecond = #"{"provider":"codex","usage":{"identity":{"accountID":"acct-1"},"primary":{"usedPercent":60,"windowMinutes":300}}}"#
    static let codexSecondFailed = #"{"provider":"codex","usage":{"identity":{"accountID":"acct-1"},"error":{"message":"upstream unavailable"}}}"#

    static func commandResult(_ json: String, status: Int32 = 0) -> CodexUsageService.CommandResult {
        .init(terminationStatus: status, stdout: Data(json.utf8), stderr: Data())
    }
}
