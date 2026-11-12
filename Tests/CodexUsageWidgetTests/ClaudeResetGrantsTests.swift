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

    private func tokenClient(transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int, String?))
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
            return (Self.grantsBody(), 200, nil)
        }
        _ = await client.fetch(configDir: nil)
        let request = try XCTUnwrap(recorder.last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?
            .range(of: #"^claude-cli/\d+\.\d+\.\d+ \(external, cli\)$"#, options: .regularExpression) != nil)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testOutcomeMappingForStatusesAndBodies() async {
        let recorded = RequestRecorder()
        let client = tokenClient { request in
            recorded.record(request)
            return (Self.grantsBody(), 200, nil)
        }
        let loaded = await client.fetch(configDir: "/tmp/claude-test-config")
        guard case .loaded(let grants) = loaded else { return XCTFail("expected loaded") }
        XCTAssertEqual(grants.map(\.kind), [.session, .weekly])
        XCTAssertEqual(grants.map(\.resetsLeft), [2, 1])
        XCTAssertEqual(grants[0].endsAt, ISO8601DateFormatter().date(from: "2027-01-16T12:00:00Z"))
        XCTAssertEqual(grants.map(\.paused), [false, false])
        XCTAssertEqual(grants.map(\.usableNow), [true, true])

        let noBlock = tokenClient { _ in (Self.json(#"{"weekly_resets_at":"2027-01-20T12:00:00Z"}"#), 200, nil) }
        let noBlockOutcome = await noBlock.fetch(configDir: nil)
        XCTAssertEqual(noBlockOutcome, .notOffered)

        let ineligible = tokenClient { _ in
            (Self.json(#"{"cedar_ember":{"eligible":false,"grants":[]}}"#), 200, nil)
        }
        let ineligibleOutcome = await ineligible.fetch(configDir: nil)
        XCTAssertEqual(ineligibleOutcome, .notOffered)

        for status in [401, 403] {
            let client = tokenClient { _ in (Data(), status, nil) }
            let outcome = await client.fetch(configDir: nil)
            XCTAssertEqual(outcome, .unauthorized)
        }
        let throttled = tokenClient { _ in (Data(), 429, nil) }
        let throttledOutcome = await throttled.fetch(configDir: nil)
        XCTAssertEqual(throttledOutcome, .rateLimited(900))

        let transportFailure = tokenClient { _ in throw URLError(.cannotConnectToHost) }
        let transportOutcome = await transportFailure.fetch(configDir: nil)
        XCTAssertEqual(transportOutcome, .transportFailure)

        let garbage = tokenClient { _ in (Data("garbage".utf8), 200, nil) }
        let garbageOutcome = await garbage.fetch(configDir: nil)
        XCTAssertEqual(garbageOutcome, .malformed)

        let expiredToken = ClaudeResetGrantsClient(
            loadToken: { _ in throw ClaudeOAuthCredential.Failure.expired },
            transport: { _ in (Data(), 200, nil) }
        )
        let expiredOutcome = await expiredToken.fetch(configDir: nil)
        XCTAssertEqual(expiredOutcome, .loginExpired)

        let missingToken = ClaudeResetGrantsClient(
            loadToken: { _ in throw ClaudeOAuthCredential.Failure.missing },
            transport: { _ in (Data(), 200, nil) }
        )
        let missingOutcome = await missingToken.fetch(configDir: nil)
        XCTAssertEqual(missingOutcome, .notLoggedIn)
        XCTAssertEqual(recorded.requests.count, 1)
    }

    func testMalformedGrantFieldsAreRejectedBeforeRendering() {
        let invalid = [
            #""resets_left":9223372036854775807"#,
            #""resets_left":1.9"#, #""resets_left":-1"#,
            #""resets_left":true"#, #""resets_left":"1""#,
            #""resets_left":101"#, #""resets_left":1,"paused":"false""#,
            #""resets_left":1,"usable_now":1"#,
            #""resets_left":1,"ends_at":"invalid""#,
            #""resets_left":1,"ends_at":"2027-02-30T12:00:00Z""#,
            #""resets_left":1,"ends_at":123"#,
            #""resets_left":1,"type":12"#
        ]
        for fields in invalid {
            let body = Self.json("{\"cedar_ember\":{\"eligible\":true,\"grants\":[{\(fields)}]}}")
            XCTAssertEqual(ClaudeResetGrantsClient.parse(body), .malformed, fields)
        }
        let tooMany = Array(repeating: #"{"resets_left":1}"#, count: 101).joined(separator: ",")
        XCTAssertEqual(ClaudeResetGrantsClient.parse(Self.json(
            "{\"cedar_ember\":{\"eligible\":true,\"grants\":[\(tooMany)]}}")), .malformed)
    }

    func testRemovingAndReaddingAccountKeepsGrantCooldown() async {
        let calls = GrantCallLog()
        let client = tokenClient { request in
            calls.record(request)
            return (Self.grantsBody(), 200, nil)
        }
        let runner = CLIStub()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in
            await runner.run(arguments, environment)
        }, grantsClient: client)
        let account = ClaudeCLIAccount(label: "A", configDir: "/tmp/claude-test-config")
        let t0 = now
        await usage.refreshNow([account], timeZone: .current, now: { t0 })
        await usage.refreshNow([], timeZone: .current, now: { t0.addingTimeInterval(1) })
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(2) })
        XCTAssertEqual(calls.count, 1)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(901) })
        XCTAssertEqual(calls.count, 2)
    }

    func testCooldownIsClaimedBeforeAwaitAndSurvivesDiscardedResponse() async {
        let calls = GrantCallLog()
        let entered = Gate(), release = Gate()
        let client = tokenClient { request in
            calls.record(request)
            await entered.open()
            await release.wait()
            return (Self.grantsBody(), 200, nil)
        }
        let runner = CLIStub()
        let usage = ClaudeCLIUsage(runner: { arguments, environment in
            await runner.run(arguments, environment)
        }, grantsClient: client)
        let account = ClaudeCLIAccount(label: "A", configDir: nil)
        let t0 = now
        let first = Task { await usage.refreshNow([account], timeZone: .current, now: { t0 }) }
        await entered.wait()
        await usage.refreshNow([], timeZone: .current, now: { t0.addingTimeInterval(1) })
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(2) })
        XCTAssertEqual(calls.count, 1)
        await release.open()
        await first.value
        let section = usage.section(accounts: [account], now: t0.addingTimeInterval(2), timeZone: .current)
        // The discarded response leaves the account unknown, never a count.
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(section?.section.stats ?? [], 0), "未確認|取得中|")
    }

    func testRateLimitHonorsRetryAfterWithoutCreatingEmptyCard() async {
        let calls = GrantCallLog()
        let client = tokenClient { request in
            calls.record(request)
            return (Data(), 429, "3600")
        }
        let usage = ClaudeCLIUsage(runner: { _, _ in
            CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, grantsClient: client)
        let account = ClaudeCLIAccount(label: "A", configDir: nil)
        let t0 = now
        await usage.refreshNow([account], timeZone: .current, now: { t0 })
        let result = usage.section(accounts: [account], now: t0, timeZone: .current)
        // A rate-limit note alone is not a real usage/ticket reading.
        // The provider must remain pending, rather than creating an empty ring.
        XCTAssertNil(result)
        await usage.refreshNow([], timeZone: .current, now: { t0.addingTimeInterval(1) })
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(901) })
        XCTAssertEqual(calls.count, 1)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(3601) })
        XCTAssertEqual(calls.count, 2)
        let retryDate = DateFormatter()
        retryDate.locale = Locale(identifier: "en_US_POSIX")
        retryDate.timeZone = TimeZone(secondsFromGMT: 0)
        retryDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(ClaudeResetGrantsClient.retryInterval(retryDate.string(from: t0.addingTimeInterval(7200)), now: t0), 7200)
        XCTAssertEqual(ClaudeResetGrantsClient.retryInterval("invalid", now: t0), 900)
        XCTAssertEqual(ClaudeResetGrantsClient.retryInterval("NaN", now: t0), 900)
        // usable_now only says whether a ticket can be spent this instant (e.g. not while a window is
        // still fresh); a stored, unpaused, unexpired ticket still counts toward the inventory.
        // It is still never labelled 使用可.
        let notUsableYet = ClaudeResetGrant(kind: .session, resetsLeft: 1, endsAt: nil, paused: false, usableNow: false)
        let heldStats = ClaudeResetGrantsClient.stats(for: .loaded([notUsableYet]), accountIndex: 0, now: t0, calendar: tokyoCalendar())
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(heldStats, 0), "利用可能 1件||期限なし（5時間リセット）・今は使用不可")
        XCTAssertEqual(RingDetailCardModel.claudeTicketExtras(heldStats)?.tickets.map(\.isGreyedOut), [true])
        let extreme = ClaudeResetGrant(kind: .session, resetsLeft: Int.max, endsAt: nil, paused: false, usableNow: true)
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(ClaudeResetGrantsClient.stats(for: .loaded([extreme]), accountIndex: 0, now: t0, calendar: tokyoCalendar()), 0),
                       "未確認|取得できません|")
    }

    func testLoginChangeAndLogoutDiscardOldTicketsWithoutBypassingCooldown() async {
        let calls = GrantCallLog(), runner = LoginChangeStub()
        let client = tokenClient { request in
            calls.record(request)
            return (Self.grantsBody(), 200, nil)
        }
        let usage = ClaudeCLIUsage(runner: { _, _ in await runner.run() }, grantsClient: client)
        let account = ClaudeCLIAccount(label: "A", configDir: nil)
        let t0 = now
        await usage.refreshNow([account], timeZone: .current, now: { t0 })
        XCTAssertTrue(usage.section(accounts: [account], now: t0, timeZone: .current)?.section.stats.contains { $0.title == "Reset ticket" } == true)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(1) })
        XCTAssertFalse(usage.section(accounts: [account], now: t0.addingTimeInterval(1), timeZone: .current)?.section.stats.contains { $0.title == "Reset ticket" } ?? true)
        XCTAssertEqual(calls.count, 1)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(901) })
        XCTAssertEqual(calls.count, 2)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(902) })
        XCTAssertNil(usage.section(accounts: [account], now: t0.addingTimeInterval(902), timeZone: .current))
        XCTAssertEqual(calls.count, 2)
        await usage.refreshNow([account], timeZone: .current, now: { t0.addingTimeInterval(1802) })
        XCTAssertNil(usage.section(accounts: [account], now: t0.addingTimeInterval(1802), timeZone: .current))
        XCTAssertEqual(calls.count, 2)
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
        // Paused, expired and empty grants drop out; 2 + 1 + 1 held, soonest expiry first, no-expiry last.
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(stats, 2),
                       "利用可能 4件||期限 18:00 JST（5時間リセット）;期限 18:00 JST（5時間リセット）;期限 19:00 JST（週リセット）;期限なし")
        XCTAssertEqual(stats.filter { $0.title == ClaudeResetGrantsClient.expiryStat }.map(\.valueText),
                       [now.addingTimeInterval(3_600), now.addingTimeInterval(3_600), now.addingTimeInterval(7_200)]
                           .map { ISO8601DateFormatter().string(from: $0) })
        XCTAssertTrue(stats.allSatisfy { $0.accountIndex == 2 })
        // An eligible answer with no grants is a known zero.
        let empty = ClaudeResetGrantsClient.stats(for: .loaded([]), accountIndex: 0, now: now, calendar: calendar)
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(empty, 0), "利用可能 0件||")
    }

    func testFableAndCompleteResetKindsUseActualGrantLabelAndScope() {
        // Both live kinds have raw type "full"; never classify from that field or from expiry.
        // Synthetic dates and grant labels (no identifiers or credentials) exercise the real payload shape.
        let body = Self.json("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"label":"New model launch: one Fable reset for Pro","type":"full",
           "clears":["five_hour","seven_day_overage_included"],
           "resets_left":1,"paused":false,"usable_now":true,"ends_at":"2027-01-16T12:00:00Z"},
          {"label":"One full limit reset (January 2027)","type":"full",
           "clears":["five_hour","seven_day","seven_day_overage_included"],
           "resets_left":1,"paused":false,"usable_now":true,"ends_at":"2027-01-20T12:00:00Z"},
          {"type":"full","clears":["five_hour"],"resets_left":1,
           "paused":false,"usable_now":true,"ends_at":"2027-01-21T12:00:00Z"}
        ]}}
        """)
        guard case .loaded(let grants) = ClaudeResetGrantsClient.parse(body) else {
            return XCTFail("expected real-grant-shaped payload to load")
        }
        XCTAssertEqual(grants.map(\.kind), [.fable, .full, .unknown])
        let stats = ClaudeResetGrantsClient.stats(
            for: .loaded(grants), accountIndex: 1, now: now, calendar: tokyoCalendar()
        )
        XCTAssertEqual(
            ClaudeDesktopResetCacheTests.card(stats, 1),
            "利用可能 3件||期限 1/16 21:00 JST（Fableリセット）;期限 1/20 21:00 JST（完全リセット）;期限 1/21 21:00 JST"
        )
        XCTAssertTrue(stats.allSatisfy { $0.accountIndex == 1 })
    }

    func testConflictingFableLabelAndWeeklyScopeIsNotMislabelled() {
        let body = Self.json("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"label":"Fable reset","type":"full","clears":["five_hour","seven_day"],
           "resets_left":1,"paused":false,"usable_now":true,"ends_at":"2027-01-16T12:00:00Z"}
        ]}}
        """)
        guard case .loaded(let grants) = ClaudeResetGrantsClient.parse(body) else { return XCTFail("expected loaded") }
        XCTAssertEqual(grants.map(\.kind), [.unknown])
    }

    /// API shape seen live: stored tickets come back with usable_now:false. They are inventory and
    /// must be counted (CodexBar docs/claude.md), but shown as held, not as 使用可.
    func testStoredTicketsWithUsableNowFalseAreCountedButNotLabelledUsable() {
        let body = Self.json("""
        {"cedar_ember":{"eligible":true,"grants":[
          {"resets_left":2,"ends_at":"2027-01-16T12:00:00Z","paused":false,"usable_now":false,"type":"session"},
          {"resets_left":1,"ends_at":"2027-01-20T12:00:00Z","paused":false,"usable_now":true,"type":"weekly"},
          {"resets_left":4,"ends_at":"2027-01-20T12:00:00Z","paused":true,"usable_now":false,"type":"full"}
        ]}}
        """)
        guard case .loaded(let grants) = ClaudeResetGrantsClient.parse(body) else { return XCTFail("not loaded") }
        let stats = ClaudeResetGrantsClient.stats(for: .loaded(grants), accountIndex: 1, now: now, calendar: tokyoCalendar())
        XCTAssertEqual(ClaudeDesktopResetCacheTests.card(stats, 1),
                       "利用可能 3件||期限 1/16 21:00 JST（5時間リセット）・今は使用不可;期限 1/16 21:00 JST（5時間リセット）・今は使用不可;期限 1/20 21:00 JST（週リセット）")
        XCTAssertEqual(RingDetailCardModel.claudeTicketExtras(stats)?.tickets.map(\.isGreyedOut), [true, true, false])
    }

    func testFailureNotesAndSilentOutcomes() {
        let calendar = tokyoCalendar()
        func stats(_ outcome: ClaudeResetGrantsOutcome) -> [ProviderStat] {
            ClaudeResetGrantsClient.stats(for: outcome, accountIndex: 1, now: now, calendar: calendar)
        }
        func shown(_ outcome: ClaudeResetGrantsOutcome?) -> String { ClaudeDesktopResetCacheTests.card(ClaudeResetGrantsClient.stats(
            for: outcome, accountIndex: 1, now: now, calendar: calendar, retryAt: now.addingTimeInterval(900)), 1) }
        // Every failure keeps the heading as 未確認 with one short reason; none is shown as 0.
        XCTAssertEqual(shown(.loginExpired), "未確認|Claude Codeを一度使うとログインが更新されます|")
        XCTAssertEqual(shown(.unauthorized), "未確認|Claude Codeで再ログインしてください|")
        XCTAssertEqual(shown(.httpFailure(429)), "未確認|取得制限中・17:15 JST 以降に再取得|")
        XCTAssertEqual(shown(.rateLimited(3600)), "未確認|取得制限中・17:15 JST 以降に再取得|")
        XCTAssertEqual(shown(.httpFailure(500)), "未確認|取得できません（HTTP 500）|")
        XCTAssertEqual(shown(.transportFailure), "未確認|取得できません|")
        XCTAssertEqual(shown(.malformed), "未確認|取得できません|")
        XCTAssertEqual(shown(.notOffered), "未確認|公式APIは券情報を返しません|")
        XCTAssertEqual(shown(.notLoggedIn), "未確認|ログインがありません|")
        XCTAssertEqual(shown(nil), "未確認|取得中|")
        XCTAssertTrue(stats(.malformed).allSatisfy { $0.accountIndex == 1 })
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
                return (Self.grantsBody(), 200, nil)
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
                       ["3"])
        XCTAssertEqual(section.forAccount(0).stats.filter { $0.title == "Reset ticket" }.count, 3)
        XCTAssertEqual(section.forAccount(0).stats.first { $0.title == "Reset tickets" }?.accountIndex, 0)
        XCTAssertEqual(section.forAccount(1).stats.filter { $0.title == "Reset tickets" }.map(\.valueText),
                       ["3"])
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
            case .rateLimited: name = "rateLimited"
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

private actor LoginChangeStub {
    private var count = 0
    func run() -> CodexUsageService.CommandResult {
        defer { count += 1 }
        if count >= 3 {
            return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data("not logged in".utf8))
        }
        let email = count == 0 ? "first@example.test" : "second@example.test"
        return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data("""
        [{"provider":"claude","usage":{"identity":{"accountEmail":"\(email)"},"primary":{"usedPercent":30,"windowMinutes":300},"secondary":{"usedPercent":72,"windowMinutes":10080}}}]
        """.utf8), stderr: Data())
    }
}
