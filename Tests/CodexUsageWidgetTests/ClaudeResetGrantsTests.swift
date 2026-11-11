import Foundation
import XCTest
@testable import CodexUsageWidget

final class ClaudeResetGrantsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static func grantsBody() -> Data {
        json("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"id":"g1","label":"Session","resets_total":2,"resets_left":2,"starts_at":null,
           "ends_at":"2027-01-16T12:00:00Z","paused":false,"usable_now":true,"type":"session"},
          {"id":"g2","label":"Weekly","resets_total":1,"resets_left":1,
           "ends_at":"2027-01-20T12:00:00Z","paused":false,"usable_now":true,"type":"weekly"}
        ],"weekly_resets_at":"2027-01-20T12:00:00Z","unknown_field":{"x":1}}}
        """)
    }

    private static func credential(expiresAt: Double, token: String = "sk-ant-oat-test-token") -> Data {
        json("""
        {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":\(expiresAt),"refreshToken":"refresh-value"}}
        """)
    }

    private func tokenClient(transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int))
        -> ClaudeResetGrantsClient {
        ClaudeResetGrantsClient(loadToken: { _ in "sk-ant-oat-test-token" }, transport: transport)
    }

    func testServiceNameUsesCredentialServiceForDefaultAndHashedDir() {
        XCTAssertEqual(ClaudeOAuthCredential.serviceName(configDir: nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudeOAuthCredential.serviceName(configDir: "/tmp/claude-test-config"),
                       "Claude Code-credentials-3d315a6d")
    }

    func testAccountNameUsesUserAndFallsBackForUnsafeValues() {
        XCTAssertEqual(ClaudeOAuthCredential.accountName(environment: ["USER": "aki_1.test"]), "aki_1.test")
        XCTAssertEqual(ClaudeOAuthCredential.accountName(environment: [:]), NSUserName())
        XCTAssertEqual(ClaudeOAuthCredential.accountName(environment: ["USER": "aki test"]), "claude-code-user")
        XCTAssertEqual(ClaudeOAuthCredential.accountName(environment: ["USER": "aki@example.com"]), "claude-code-user")
        XCTAssertEqual(ClaudeOAuthCredential.accountName(environment: ["USER": "aki/../x"]), "claude-code-user")
    }

    func testTokenParsingAcceptsValidLoginWithMilliseconds() throws {
        let token = try ClaudeOAuthCredential.accessToken(
            keychainJSON: Self.credential(expiresAt: (now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000)),
            now: now
        )
        XCTAssertEqual(token, "sk-ant-oat-test-token")
    }

    func testTokenParsingRejectsExpiredNearExpiredMissingAndMalformed() {
        let expired = Self.credential(expiresAt: (now.addingTimeInterval(-1).timeIntervalSince1970 * 1000))
        XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(keychainJSON: expired, now: now)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .expired)
        }
        let nearExpired = Self.credential(expiresAt: (now.addingTimeInterval(30).timeIntervalSince1970 * 1000))
        XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(keychainJSON: nearExpired, now: now)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .expired)
        }
        XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(
            keychainJSON: Self.json(#"{"claudeAiOauth":{"expiresAt":1900000000000}}"#), now: now)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .missing)
        }
        XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(
            keychainJSON: Self.json(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-test-token"}}"#), now: now)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .missing)
        }
        XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(
            keychainJSON: Self.json(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat-test-token","expiresAt":"soon"}}"#),
            now: now)) {
            XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .malformed)
        }
        for data in [Data(), Self.json("not json"), Self.json("[]")] {
            XCTAssertThrowsError(try ClaudeOAuthCredential.accessToken(keychainJSON: data, now: now)) {
                XCTAssertEqual($0 as? ClaudeOAuthCredential.Failure, .malformed)
            }
        }
    }

    func testTokenErrorsNeverContainTheTokenText() {
        let token = "sk-ant-oat-secret-value"
        let cases = [
            Self.credential(expiresAt: (now.addingTimeInterval(-60).timeIntervalSince1970 * 1000), token: token),
            Self.json(#"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":null}}"#),
            Self.json(#"{"claudeAiOauth":{"accessToken":"\#(token)"}}"#),
            Self.json(#"[]"#)
        ]
        for data in cases {
            do {
                _ = try ClaudeOAuthCredential.accessToken(keychainJSON: data, now: now)
                XCTFail("expected an error")
            } catch {
                XCTAssertFalse(String(describing: error).contains(token))
                XCTAssertFalse((error as? ClaudeOAuthCredential.Failure).map { "\($0)" }?.contains(token) ?? false)
            }
        }
    }

    func testRequestUsesFixedEndpointGetAndOAuthHeaders() async throws {
        let recorder = RequestRecorder()
        let client = tokenClient { request in
            recorder.record(request)
            return (Self.grantsBody(), 200)
        }
        _ = await client.fetch(configDir: nil)
        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testOutcomeMappingForStatusesAndBodies() async {
        let recorded = RequestRecorder()
        let client = tokenClient { request in
            recorded.record(request)
            return (Self.grantsBody(), 200)
        }
        let loaded = await client.fetch(configDir: "/tmp/claude-test-config")
        guard case .loaded(let grants) = loaded else { return XCTFail("expected loaded") }
        XCTAssertEqual(grants.map(\.kind), [.session, .weekly])
        XCTAssertEqual(grants.map(\.resetsLeft), [2, 1])
        XCTAssertEqual(grants[0].endsAt, ISO8601DateFormatter().date(from: "2027-01-16T12:00:00Z"))
        XCTAssertEqual(grants.map(\.paused), [false, false])
        XCTAssertEqual(grants.map(\.usableNow), [true, true])

        let noBlock = tokenClient { _ in (Self.json(#"{"weekly_resets_at":"2027-01-20T12:00:00Z"}"#), 200) }
        let noBlockOutcome = await noBlock.fetch(configDir: nil)
        XCTAssertEqual(noBlockOutcome, .notOffered)

        let ineligible = tokenClient { _ in
            (Self.json(#"{"cedar_ember":{"eligible":false,"grants":[]}}"#), 200)
        }
        let ineligibleOutcome = await ineligible.fetch(configDir: nil)
        XCTAssertEqual(ineligibleOutcome, .notOffered)

        for status in [401, 403] {
            let client = tokenClient { _ in (Data(), status) }
            let outcome = await client.fetch(configDir: nil)
            XCTAssertEqual(outcome, .unauthorized)
        }
        let throttled = tokenClient { _ in (Data(), 429) }
        let throttledOutcome = await throttled.fetch(configDir: nil)
        XCTAssertEqual(throttledOutcome, .httpFailure(429))

        let transportFailure = tokenClient { _ in throw URLError(.cannotConnectToHost) }
        let transportOutcome = await transportFailure.fetch(configDir: nil)
        XCTAssertEqual(transportOutcome, .transportFailure)

        let garbage = tokenClient { _ in (Data("garbage".utf8), 200) }
        let garbageOutcome = await garbage.fetch(configDir: nil)
        XCTAssertEqual(garbageOutcome, .malformed)

        let expiredToken = ClaudeResetGrantsClient(
            loadToken: { _ in throw ClaudeOAuthCredential.Failure.expired },
            transport: { _ in (Data(), 200) }
        )
        let expiredOutcome = await expiredToken.fetch(configDir: nil)
        XCTAssertEqual(expiredOutcome, .loginExpired)

        let missingToken = ClaudeResetGrantsClient(
            loadToken: { _ in throw ClaudeOAuthCredential.Failure.missing },
            transport: { _ in (Data(), 200) }
        )
        let missingOutcome = await missingToken.fetch(configDir: nil)
        XCTAssertEqual(missingOutcome, .notLoggedIn)
        XCTAssertEqual(recorded.requests.count, 1)
    }

    func testStatsExpandUsableGrantsAndSkipPausedExpiredAndEmptyOnes() {
        let calendar = tokyoCalendar()
        let grants = [
            ClaudeResetGrant(kind: .session, resetsLeft: 2, endsAt: now.addingTimeInterval(3_600), paused: false, usableNow: true),
            ClaudeResetGrant(kind: .weekly, resetsLeft: 1, endsAt: now.addingTimeInterval(7_200), paused: false, usableNow: true),
            ClaudeResetGrant(kind: .full, resetsLeft: 3, endsAt: now.addingTimeInterval(9_000), paused: true, usableNow: false),
            ClaudeResetGrant(kind: .full, resetsLeft: 1, endsAt: now.addingTimeInterval(-60), paused: false, usableNow: false),
            ClaudeResetGrant(kind: .unknown, resetsLeft: 0, endsAt: nil, paused: false, usableNow: true),
            ClaudeResetGrant(kind: .unknown, resetsLeft: 1, endsAt: nil, paused: false, usableNow: true)
        ]
        let stats = ClaudeResetGrantsClient.stats(for: .loaded(grants), accountIndex: 2, now: now, calendar: calendar)
        XCTAssertEqual(stats.first?.title, "Reset tickets")
        XCTAssertEqual(stats.first?.valueText, "4 available")
        XCTAssertEqual(stats.filter { $0.title == "Reset tickets" }.count, 1)
        XCTAssertEqual(stats.filter { $0.title == "Reset ticket" }.count, 4)
        XCTAssertEqual(stats.filter { $0.title == "Reset ticket expiry" }.count, 3)
        XCTAssertTrue(stats.allSatisfy { $0.accountIndex == 2 })
        XCTAssertEqual(stats.filter { $0.title == "Reset ticket" }.map(\.valueText).first,
                       MultiUsageService.ticketText(
                           CodexExtrasParser.Ticket(title: "5時間リセット", status: "available",
                                                    resetType: nil, grantedAt: nil,
                                                    expiresAt: now.addingTimeInterval(3_600)),
                           now: now, calendar: calendar))
        XCTAssertTrue(stats[1].valueText.hasPrefix("5時間リセット · 使用可 · 期限 "))
        XCTAssertTrue(stats[3].valueText.hasPrefix("週リセット · 使用可 · 期限 "))
        XCTAssertTrue(stats[4].valueText.hasPrefix("リセット · 使用可"))
        XCTAssertEqual(stats[5].valueText, ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600)))
        XCTAssertEqual(stats[6].valueText, ISO8601DateFormatter().string(from: now.addingTimeInterval(3_600)))
        XCTAssertEqual(stats[7].valueText, ISO8601DateFormatter().string(from: now.addingTimeInterval(7_200)))
        let empty = ClaudeResetGrantsClient.stats(for: .loaded([]), accountIndex: 0, now: now, calendar: calendar)
        XCTAssertTrue(empty.isEmpty)
    }

    func testFailureNotesAndSilentOutcomes() {
        let calendar = tokyoCalendar()
        func stats(_ outcome: ClaudeResetGrantsOutcome) -> [ProviderStat] {
            ClaudeResetGrantsClient.stats(for: outcome, accountIndex: 1, now: now, calendar: calendar)
        }
        XCTAssertEqual(stats(.loginExpired).map(\.valueText),
                       ["Claude Codeを一度使うとログインが更新されます"])
        XCTAssertEqual(stats(.unauthorized).map(\.valueText), ["Claude Codeで再ログインしてください"])
        XCTAssertEqual(stats(.httpFailure(429)).map(\.valueText), ["取得の回数制限中（15分ごとに再取得）"])
        XCTAssertEqual(stats(.httpFailure(500)).map(\.valueText), ["取得できません（HTTP 500）"])
        XCTAssertEqual(stats(.transportFailure).map(\.valueText), ["取得できません"])
        XCTAssertEqual(stats(.malformed).map(\.valueText), ["取得できません"])
        for outcome in [ClaudeResetGrantsOutcome.loginExpired, .unauthorized, .httpFailure(500),
                        .transportFailure, .malformed] {
            XCTAssertEqual(stats(outcome).count, 1)
            XCTAssertEqual(stats(outcome).first?.title, "リセットチケット")
            XCTAssertEqual(stats(outcome).first?.accountIndex, 1)
        }
        XCTAssertTrue(stats(.notOffered).isEmpty)
        XCTAssertTrue(stats(.notLoggedIn).isEmpty)
    }

    func testNotesRenderAsPanelNotesForTheClaudeRow() {
        let note = ClaudeResetGrantsClient.stats(for: .unauthorized, accountIndex: 0, now: now,
                                                 calendar: tokyoCalendar())
        var section = ProviderSection(provider: .claude, windows: [], stats: note, failureText: nil)
        section.stats += ClaudeResetGrantsClient.stats(for: .unauthorized, accountIndex: 1, now: now,
                                                       calendar: tokyoCalendar())
        let row = ServiceRowModel.rows(for: section).first
        XCTAssertEqual(row?.notes, ["リセットチケット: Claude Codeで再ログインしてください"])
    }

    private func tokyoCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private static func cliJSON(_ five: Int, _ week: Int) -> Data {
        Data("""
        [{"provider":"claude","source":"claude","usage":{"primary":{"usedPercent":\(five),"windowMinutes":300,"resetsAt":"2026-10-30T07:50:00Z"},"secondary":{"usedPercent":\(week),"windowMinutes":10080,"resetsAt":"2026-11-02T00:00:00Z"}}}]
        """.utf8)
    }

    func testInjectedGrantsClientAddsTicketStatsToTheRightAccountAndHonorsTheInterval() async {
        let calls = GrantCallLog()
        let client = ClaudeResetGrantsClient(
            loadToken: { configDir in
                calls.record(configDir: configDir)
                return "sk-ant-oat-test-token"
            },
            transport: { request in
                calls.record(request)
                return (Self.grantsBody(), 200)
            }
        )
        let runner = CLIStub()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in
            await runner.run(arguments, environment)
        }, grantsClient: client)
        let a = ClaudeCLIAccount(label: "A", configDir: "/tmp/claude-test-config")
        let b = ClaudeCLIAccount(label: "B", configDir: nil)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        await usage.refreshNow([a, b], timeZone: .current, now: { t0 })

        let section = usage.section(accounts: [a, b], now: t0, timeZone: .current)!.section
        XCTAssertEqual(section.forAccount(0).stats.filter { $0.title == "Reset tickets" }.map(\.valueText),
                       ["3 available"])
        XCTAssertEqual(section.forAccount(0).stats.filter { $0.title == "Reset ticket" }.count, 3)
        XCTAssertEqual(section.forAccount(0).stats.first { $0.title == "Reset tickets" }?.accountIndex, 0)
        XCTAssertEqual(section.forAccount(1).stats.filter { $0.title == "Reset tickets" }.map(\.valueText),
                       ["3 available"])
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.seenDirs, ["/tmp/claude-test-config", nil])

        await usage.refreshNow([a, b], timeZone: .current, now: { t0.addingTimeInterval(60) })
        XCTAssertEqual(calls.count, 2, "grants must not refetch inside the 15 minute window")

        await usage.refreshNow([a, b], timeZone: .current, now: { t0.addingTimeInterval(ClaudeCLIUsage.grantsRefreshInterval + 1) })
        XCTAssertEqual(calls.count, 4)
    }

    func testWithoutGrantsClientStatsStayUnchanged() async {
        let runner = CLIStub()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in
            await runner.run(arguments, environment)
        })
        let a = ClaudeCLIAccount(label: "A", configDir: "/tmp/claude-test-config")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        await usage.refreshNow([a], timeZone: .current, now: { t0 })
        let stats = usage.section(accounts: [a], now: t0, timeZone: .current)!.section.stats
        XCTAssertFalse(stats.contains { $0.title == "Reset tickets" || $0.title == "リセットチケット" })
        XCTAssertTrue(stats.contains { $0.title == ClaudeCLIUsage.sourceTitle })
    }
}

final class ClaudeGrantsLiveTests: XCTestCase {
    func testLiveGrantsPrintSummaryOnly() async throws {
        guard ProcessInfo.processInfo.environment["USAGERINGS_CLAUDE_GRANTS_LIVE"] == "1" else {
            throw XCTSkip("Set USAGERINGS_CLAUDE_GRANTS_LIVE=1 on a logged-in Mac")
        }
        let client = ClaudeResetGrantsClient.live()
        for account in ClaudeCLIAccountSettings.load() {
            let outcome = await client.fetch(configDir: account.configDir)
            let name: String
            var tickets: [ClaudeResetGrant] = []
            switch outcome {
            case .loaded(let grants):
                name = "loaded"
                tickets = grants.filter { $0.resetsLeft > 0 && !$0.paused }
            case .notOffered: name = "notOffered"
            case .notLoggedIn: name = "notLoggedIn"
            case .loginExpired: name = "loginExpired"
            case .unauthorized: name = "unauthorized"
            case .httpFailure(let status): name = "httpFailure(\(status))"
            case .transportFailure: name = "transportFailure"
            case .malformed: name = "malformed"
            }
            let count = tickets.reduce(0) { $0 + $1.resetsLeft }
            let kinds = Set(tickets.map { "\($0.kind)" }).sorted().joined(separator: ",")
            let earliest = tickets.compactMap(\.endsAt).min().map { ISO8601DateFormatter().string(from: $0) } ?? "none"
            print("Claude grants \(account.label): \(name); tickets \(count); kinds \(kinds); earliest \(earliest)")
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    func record(_ request: URLRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    var last: URLRequest? { requests.last }
}

private final class GrantCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var dirs: [String?] = []
    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
    func record(configDir: String?) {
        lock.lock()
        dirs.append(configDir)
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
    var seenDirs: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return dirs
    }
}

private actor CLIStub {
    func run(_ arguments: [String], _ environment: [String: String]?) async -> CodexUsageService.CommandResult {
        CodexUsageService.CommandResult(
            terminationStatus: 0,
            stdout: Data("""
            [{"provider":"claude","source":"claude","usage":{"primary":{"usedPercent":30,"windowMinutes":300,"resetsAt":"2026-10-30T07:50:00Z"},"secondary":{"usedPercent":72,"windowMinutes":10080,"resetsAt":"2026-11-02T00:00:00Z"}}}]
            """.utf8),
            stderr: Data()
        )
    }
}
