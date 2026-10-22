import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class GrokQuotaTests: XCTestCase {
    func testBillingAliasesCentsAndReset() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")!
        let weekly = try CLIProxyParser.grok(Data(GrokFixtures.weekly.utf8), label: "Account", weekly: true, now: now)
        let monthly = try CLIProxyParser.grok(Data(GrokFixtures.monthly.utf8), label: "Account", weekly: false, now: now)
        XCTAssertEqual(quota(weekly)?.leftPercent, 75)
        XCTAssertEqual(quota(monthly)?.leftPercent, 90)
        XCTAssertEqual(quota(weekly)?.resetText, "Resets 10/18 09:00 (1d0h)")
        XCTAssertEqual(quota(monthly)?.resetText, "Resets 10/24 09:00 (7d0h)")
        for body in [#"{ "config": { "monthlyLimit": { "val": "2000" }, "used": { "val": "500" }, "billingPeriodEnd": "2026-10-18T00:00:00Z" } }"#,
                     #"{ "config": { "monthly_limit": 2000, "used": 500, "billing_period_end": "2026-10-18T00:00:00Z" } }"#] {
            let result = try CLIProxyParser.grok(Data(body.utf8), label: "Account", weekly: false, now: now)
            XCTAssertEqual(quota(result)?.leftPercent, 75)
            XCTAssertEqual(quota(result)?.resetText, "Resets 10/18 09:00 (1d0h)")
        }
    }

    func testMissingInvalidAndExplicitNoCapDataDoNotCreateQuota() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")!
        for body in [#"{ "config": { "creditUsagePercent": true } }"#,
                     #"{ "config": { "creditUsagePercent": "NaN" } }"#,
                     #"{ "config": { "credit_usage_percent": -1 } }"#,
                     #"{ "config": { } }"#,
                     #"{ "config": { "creditUsagePercent": null } }"#] {
            XCTAssertEqual(try CLIProxyParser.grok(Data(body.utf8), label: "Account", weekly: true, now: now), .noData)
        }

        let noCap = #"{ "config": { "monthlyLimit": { "val": 0 }, "used": { "val": 88 } } }"#
        XCTAssertEqual(try CLIProxyParser.grok(Data(noCap.utf8), label: "Account", weekly: false, now: now), .noMonthlyCap)
        let noCapWithPercentage = #"{ "config": { "monthlyLimit": 0, "creditUsagePercent": 12 } }"#
        XCTAssertEqual(try CLIProxyParser.grok(Data(noCapWithPercentage.utf8), label: "Account", weekly: false, now: now), .noMonthlyCap)
    }

    func testProvidedLiveShapeUsesSyntheticFixtures() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")!
        let weekly = try CLIProxyParser.grok(Data(GrokFixtures.liveWeekly.utf8), label: "Account", weekly: true, now: now)
        let monthly = try CLIProxyParser.grok(Data(GrokFixtures.liveMonthly.utf8), label: "Account", weekly: false, now: now)
        XCTAssertEqual(quota(weekly)?.leftPercent, 2)
        XCTAssertEqual(quota(weekly)?.tone, .critical)
        XCTAssertTrue(quota(weekly)?.resetText.contains("5d") == true)
        XCTAssertEqual(monthly, .noMonthlyCap)
    }

    func testCredentialUserIDAliases() throws {
        for field in [#""user_id":"fixture-user""#, #""userId":"fixture-user""#,
                      #""metadata":{"user_id":"fixture-user"}"#] {
            let json = "[{\"type\":\"xai\",\"authIndex\":\"x1\",\(field)}]"
            XCTAssertEqual(try CLIProxyParser.credentials(Data(json.utf8)).first?.userID, "fixture-user")
        }
    }

    func testTwoEndpointsHeadersFilteringAndAccountIdentity() async throws {
        let transport = GrokTransport()
        let sections = await client(transport, GrokClock()).fetchSections()
        let grok = try XCTUnwrap(sections.first { $0.provider == .grok })
        XCTAssertNil(grok.failureText)
        XCTAssertEqual(grok.windows.map(\.leftPercent), [75, 90, 75, 90])
        XCTAssertEqual(grok.windows.map(\.accountIndex), [0, 0, 1, 1])
        XCTAssertEqual(grok.windows.map(\.title), ["Account · Weekly", "Account · Monthly", "Account · Weekly", "Account · Monthly"])
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.account), ["x1", "x1", "x2", "x2"])
        XCTAssertEqual(calls.map(\.url), Array(repeating: [GrokFixtures.weeklyURL, GrokFixtures.monthlyURL], count: 2).flatMap { $0 })
        XCTAssertEqual(calls[0].headers, ["Authorization": "Bearer $TOKEN$", "x-xai-token-auth": "xai-grok-cli",
            "x-grok-client-version": "1.0.46", "accept": "*/*",
            "user-agent": "grok-pager/1.0.46 grok-shell/1.0.46 (macos; aarch64)", "x-userid": "fixture-user"])
        XCTAssertNil(calls[2].headers["x-userid"])
    }

    func testEitherEndpointCanFailAndOnlyBothFailTheSection() async throws {
        for failed in [0, 1, 2] {
            let transport = GrokTransport()
            if failed != 1 { await transport.respond(weekly: true, status: 503) }
            if failed != 0 { await transport.respond(weekly: false, status: 503) }
            let section = try await grok(client(transport, GrokClock()))
            XCTAssertEqual(section.windows.count, failed == 2 ? 2 : 3)
            XCTAssertEqual(section.failureText != nil, failed == 2)
            XCTAssertEqual(section.stats.count, failed == 2 ? 2 : 1)
        }
    }

    func testSuccessfulNullResponseReplacesStaleQuotaAndCapResultReplacesMonthlyWindow() async throws {
        let clock = GrokClock(), transport = GrokTransport()
        let client = client(transport, clock)
        let initial = try await grok(client)
        XCTAssertEqual(initial.windows.map(\.leftPercent), [75, 90, 75, 90])

        clock.advance(300)
        await transport.respond(weekly: true, body: GrokFixtures.noData)
        let missing = try await grok(client)
        XCTAssertEqual(missing.windows.filter { $0.title.contains("Weekly") }.count, 0)
        XCTAssertTrue(missing.stats.contains { $0.valueText == "No data" })
        XCTAssertNil(missing.failureText)

        clock.advance(300)
        await transport.respond(weekly: true, body: GrokFixtures.weekly)
        await transport.respond(weekly: false, body: GrokFixtures.liveMonthly)
        let noCap = try await grok(client)
        XCTAssertFalse(noCap.windows.contains { $0.title.contains("Monthly") })
        XCTAssertFalse(noCap.stats.contains { $0.title.contains("Monthly") })
        XCTAssertNil(noCap.failureText)
    }

    func testWeeklyCriticalAndMonthlyNoCapRemainVisibleWithoutFailure() async throws {
        let clock = GrokClock(), transport = GrokTransport()
        await transport.respond(weekly: true, body: GrokFixtures.liveWeekly)
        await transport.respond(weekly: false, body: GrokFixtures.liveMonthly)
        let section = try await grok(client(transport, clock))
        XCTAssertNil(section.failureText)
        XCTAssertEqual(section.windows.map(\.leftPercent), [2, 2])
        XCTAssertTrue(section.windows.allSatisfy { $0.tone == .critical })
        XCTAssertEqual(section.stats, [])

        let bars = CollapsedUsageBar.bars(for: MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: clock.read()))
        let grok = bars.filter { $0.id.hasPrefix("grok-") }
        XCTAssertEqual(grok.map(\.label), ["A", "B"])
        XCTAssertTrue(grok.allSatisfy(\.isWarning))
    }

    func testMinimumIntervalConcurrentRefreshAndPerAccountRetryAfter() async throws {
        let clock = GrokClock(), transport = GrokTransport()
        let client = client(transport, clock)
        let good = try await grok(client)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await client.fetchSections() } }
        }
        clock.advance(299)
        _ = await client.fetchSections()
        var counts = await transport.counts
        XCTAssertEqual(counts, ["x1": 2, "x2": 2])
        clock.advance(1)
        await transport.respond(weekly: true, status: 429, header: ["rEtRy-AfTeR": ["900"]])
        let limited = try await grok(client)
        XCTAssertEqual(limited.windows, good.windows)
        XCTAssertNil(limited.failureText)
        XCTAssertTrue(limited.stats[0].valueText.contains("rate limited · data from"))
        clock.advance(899)
        _ = await client.fetchSections()
        counts = await transport.counts
        XCTAssertEqual(counts, ["x1": 4, "x2": 6])
        clock.advance(1)
        await transport.respond(weekly: true, status: 200)
        let recovered = try await grok(client)
        XCTAssertTrue(recovered.stats.isEmpty)
        counts = await transport.counts
        XCTAssertEqual(counts["x1"], 6)
    }

    func testBackoffDoublesToThirtyMinutesAndResetsAfterRecovery() async throws {
        let clock = GrokClock(), transport = GrokTransport()
        let client = client(transport, clock)
        await transport.respond(weekly: true, status: 429)
        await transport.respond(weekly: false, status: 429)
        var expected = 0
        for delay in [300.0, 600, 1200, 1800, 1800] {
            let section = try await grok(client)
            XCTAssertNotNil(section.failureText)
            XCTAssertTrue(section.stats.allSatisfy { $0.valueText.contains("retry ~") })
            expected += 2
            clock.advance(delay - 1)
            _ = await client.fetchSections()
            let counts = await transport.counts
            XCTAssertEqual(counts["x1"], expected)
            clock.advance(1)
        }
        await transport.respond(weekly: true, status: 200)
        await transport.respond(weekly: false, status: 200)
        let recovered = try await grok(client)
        XCTAssertTrue(recovered.stats.isEmpty)
        clock.advance(300)
        await transport.respond(weekly: true, status: 429)
        _ = await client.fetchSections()
        let before = await transport.counts["x1"]
        clock.advance(300)
        _ = await client.fetchSections()
        let after = await transport.counts["x1"]
        XCTAssertEqual(after, before.map { $0 + 2 })
    }

    func testHTTPDateRetryAfterAndStaleDataOnBothFailures() async throws {
        let clock = GrokClock(), transport = GrokTransport()
        let client = client(transport, clock)
        let good = try await grok(client)
        clock.advance(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        await transport.respond(weekly: true, status: 429,
            header: ["Retry-After": [formatter.string(from: clock.read().addingTimeInterval(1200))]])
        await transport.respond(weekly: false, status: 503)
        let stale = try await grok(client)
        XCTAssertEqual(stale.windows, good.windows)
        XCTAssertNotNil(stale.failureText)
        XCTAssertTrue(stale.stats.allSatisfy { $0.valueText.contains("data from") })
        clock.advance(1199)
        _ = await client.fetchSections()
        var counts = await transport.counts
        XCTAssertEqual(counts["x1"], 4)
        clock.advance(1)
        _ = await client.fetchSections()
        counts = await transport.counts
        XCTAssertEqual(counts["x1"], 6)
    }

    func testGrok401LatchesAllProvidersAndStopsSecondCallThenRecovers() async {
        for outer in [false, true] {
            let clock = GrokClock(), transport = GrokTransport()
            let client = client(transport, clock)
            await transport.respond(weekly: true, status: 401, outer: outer)
            let sections = await client.fetchSections()
            XCTAssertTrue(sections.allSatisfy { $0.failureText == CLIProxyClient.rejectedKeyText })
            clock.advance(1799)
            _ = await client.fetchSections()
            var calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
            await transport.respond(weekly: true, status: 200)
            clock.advance(1)
            let resumed = await client.fetchSections()
            XCTAssertNil(resumed.first { $0.provider == .grok }?.failureText)
            calls = await transport.calls
            XCTAssertEqual(calls.count, 5)
        }
    }

    @MainActor
    func testGrokLetterColorOrderAndWarnings() throws {
        XCTAssertEqual(ProviderID.grok.displayName, "Grok")
        XCTAssertEqual(MultiUsageSnapshot.placeholder.sections.map(\.provider), [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .antigravity])
        for percent in [75.0, 30, 15] {
            let snapshot = MultiUsageSnapshot(sections: [ProviderSection(provider: .grok,
                windows: [UsageLimit(title: "Weekly", leftPercent: percent, resetText: "")], stats: [], failureText: nil)],
                codexSnapshot: nil, updatedAt: Date())
            let bars = CollapsedUsageBar.bars(for: snapshot)
            let bar = try XCTUnwrap(bars.first { $0.id == "grok" })
            XCTAssertEqual(bars.map(\.id).prefix(5), ["codex", "claude-0", "claude-1", "grok", "zai"])
            XCTAssertEqual(bar.label, "X")
            XCTAssertEqual(bar.isWarning, percent <= 30)
            XCTAssertEqual(bar.fillColor == bar.providerColor, percent > 30)
            for scheme in [ColorScheme.dark, .light] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let color = bar.providerColor.resolve(in: environment)
                XCTAssertEqual(color.red, color.green, accuracy: 0.01)
                XCTAssertEqual(color.green, color.blue, accuracy: 0.01)
                if scheme == .dark { XCTAssertGreaterThan(color.red, 0.8) }
                else { XCTAssertLessThan(color.red, 0.3) }
            }
        }
    }

    private func quota(_ result: CLIProxyParser.GrokBillingResult) -> UsageLimit? {
        guard case let .quota(window) = result else { return nil }
        return window
    }

    private func client(_ transport: GrokTransport, _ clock: GrokClock) -> CLIProxyClient {
        CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), clock: { clock.read() })
    }
    private func grok(_ client: CLIProxyClient) async throws -> ProviderSection {
        let sections = await client.fetchSections()
        return try XCTUnwrap(sections.first { $0.provider == .grok })
    }
}

enum GrokFixtures {
    static let weeklyURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let monthlyURL = "https://cli-chat-proxy.grok.com/v1/billing"
    static let weekly = #"{"config":{"currentPeriod":{"start":"2026-10-11T00:00:00Z","end":"2026-10-18T00:00:00Z"},"creditUsagePercent":25,"productUsage":[{"product":"grok","usagePercent":99}]}}"#
    static let monthly = #"{"config":{"current_period":{"end":"2026-10-24T00:00:00Z"},"credit_usage_percent":"10","product_usage":[],"monthlyLimit":{"val":1000},"used":{"val":900}}}"#
    static let liveWeekly = #"{"config":{"creditUsagePercent":98.0,"currentPeriod":{"end":"2026-10-22T04:30:00Z"}}}"#
    static let liveMonthly = #"{"config":{"monthlyLimit":{"val":0},"used":{"val":88}}}"#
    static let noData = #"{"config":{"creditUsagePercent":null}}"#
    static let credentials = #"{"credentials":[{"provider":"xai","auth_index":"x1","user_id":"fixture-user"},{"type":"xai","authIndex":"x2"},{"provider":"xai","auth_index":"disabled","disabled":true},{"provider":"other","auth_index":"other"}]}"#
}

private final class GrokClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_792_238_400)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private actor GrokTransport: CLIProxyTransport {
    struct Call: Sendable { let account: String; let url: String; let headers: [String: String] }
    private var responses: [Bool: (Int, [String: [String]], Bool)] = [:]
    private var responseBodies: [Bool: String] = [:]
    private(set) var counts: [String: Int] = [:]
    private(set) var calls: [Call] = []
    func respond(weekly: Bool, status: Int, header: [String: [String]] = [:], outer: Bool = false) {
        responses[weekly] = (status, header, outer)
    }
    func respond(weekly: Bool, body: String) {
        responseBodies[weekly] = body
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        guard let body = request.httpBody else {
            XCTAssertEqual(request.url?.path, "/v8/management/credentials")
            XCTAssertEqual(request.httpMethod, "GET")
            return (Data(GrokFixtures.credentials.utf8), 200)
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v8/management/requests/api-call")
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(call["method"] as? String, "GET")
        let account = try XCTUnwrap(call["authIndex"] as? String)
        let url = try XCTUnwrap(call["url"] as? String)
        let headers = try XCTUnwrap(call["header"] as? [String: String])
        calls.append(Call(account: account, url: url, headers: headers))
        counts[account, default: 0] += 1
        let weekly = url == GrokFixtures.weeklyURL
        let response = account == "x1" ? responses[weekly] ?? (200, [:], false) : (200, [:], false)
        if response.2 { return (Data(), response.0) }
        let fixture = responseBodies[weekly]
        let payload: Any
        if let fixture {
            payload = fixture
        } else {
            payload = weekly ? GrokFixtures.weekly : try JSONSerialization.jsonObject(with: Data(GrokFixtures.monthly.utf8))
        }
        return (try JSONSerialization.data(withJSONObject: ["status_code": response.0, "header": response.1, "body": payload]), 200)
    }
}
