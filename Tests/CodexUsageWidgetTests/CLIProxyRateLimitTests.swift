import XCTest
@testable import CodexUsageWidget

final class CLIProxyRateLimitTests: XCTestCase {
    func testCacheIsPerAccountAndManualRefreshCannotBypassFiveMinutes() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        let client = client(transport, clock)
        let first = await client.fetchSections()
        XCTAssertFalse(first[0].windows.isEmpty)
        XCTAssertTrue(first[0].windows.allSatisfy { $0.observedAt == clock.read() })
        for elapsed in [0.0, 59, 1, 239] {
            clock.advance(elapsed)
            let cached = await client.fetchSections()
            XCTAssertEqual(cached[0].windows, first[0].windows)
        }
        var counts = await transport.counts
        XCTAssertEqual(counts, ["c1": 1, "c2": 1])
        clock.advance(1)
        _ = await client.fetchSections()
        counts = await transport.counts
        XCTAssertEqual(counts, ["c1": 2, "c2": 2])
    }

    func testRetryAfterRetainsLastGoodWindowsAndDoesNotBlockOtherAccount() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        let client = client(transport, clock)
        let good = await client.fetchSections()
        clock.advance(300)
        await transport.respond(status: 429, header: ["rEtRy-AfTeR": ["900"]])
        let limited = await client.fetchSections()
        XCTAssertEqual(limited[0].windows, good[0].windows)
        XCTAssertEqual(limited[0].stats.first?.valueText,
                       "rate limited · data from \(time(clock.read().addingTimeInterval(-300)))")
        clock.advance(899)
        let stale = await client.fetchSections()
        XCTAssertEqual(stale[0].windows, good[0].windows)
        XCTAssertEqual(stale[0].stats, limited[0].stats)
        var counts = await transport.counts
        XCTAssertEqual(counts, ["c1": 2, "c2": 3])
        clock.advance(1)
        await transport.respond(status: 200)
        let recovered = await client.fetchSections()
        XCTAssertNil(recovered[0].failureText)
        XCTAssertTrue(recovered[0].stats.isEmpty)
        counts = await transport.counts
        XCTAssertEqual(counts["c1"], 3)
    }

    func testLoggedOutAccountDropsStaleWindowsAndKeepsOtherAccount() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        let client = client(transport, clock)
        let good = await client.fetchSections()
        XCTAssertTrue(good[0].windows.contains { $0.accountIndex == 0 })
        clock.advance(300)
        await transport.respond(status: 401)
        let out = await client.fetchSections()
        XCTAssertNotEqual(out[0].failureText, CLIProxyClient.rejectedKeyText)
        XCTAssertFalse(out[0].windows.contains { $0.accountIndex == 0 })
        XCTAssertTrue(out[0].windows.contains { $0.accountIndex == 1 })
        XCTAssertEqual(out[0].stats.first?.valueText, "取得失敗: ログアウト/認証切れ")
    }

    func testHTTPDateRetryAfterAndNoPreviousDataMessage() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        let retryAt = clock.read().addingTimeInterval(1200)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        await transport.respond(status: 429, header: ["Retry-After": formatter.string(from: retryAt)])
        let client = client(transport, clock)
        let limited = await client.fetchSections()
        XCTAssertEqual(limited[0].windows.map(\.accountIndex), [1, 1])
        XCTAssertEqual(limited[0].stats.first?.valueText,
                       "Claude usage rate-limited; retry ~\(time(retryAt))")
        clock.advance(1199)
        _ = await client.fetchSections()
        var counts = await transport.counts
        XCTAssertEqual(counts["c1"], 1)
        clock.advance(1)
        await transport.respond(status: 200)
        _ = await client.fetchSections()
        counts = await transport.counts
        XCTAssertEqual(counts["c1"], 2)
    }

    func testBackoffGrowsCapsAndSuccessResetsIt() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        await transport.respond(status: 429, header: ["Retry-After": "invalid"])
        let client = client(transport, clock)
        _ = await client.fetchSections()
        var expectedCalls = 1
        for delay in [300.0, 600, 1200, 1800, 1800] {
            clock.advance(delay - 1)
            _ = await client.fetchSections()
            var counts = await transport.counts
            XCTAssertEqual(counts["c1"], expectedCalls)
            clock.advance(1)
            _ = await client.fetchSections()
            expectedCalls += 1
            counts = await transport.counts
            XCTAssertEqual(counts["c1"], expectedCalls)
        }
        clock.advance(1800)
        await transport.respond(status: 200)
        _ = await client.fetchSections()
        expectedCalls += 1
        clock.advance(300)
        await transport.respond(status: 429)
        _ = await client.fetchSections()
        expectedCalls += 1
        clock.advance(299)
        _ = await client.fetchSections()
        var counts = await transport.counts
        XCTAssertEqual(counts["c1"], expectedCalls)
        clock.advance(1)
        _ = await client.fetchSections()
        counts = await transport.counts
        XCTAssertEqual(counts["c1"], expectedCalls + 1)
    }

    func testShortRetryAfterStillRespectsMinimumInterval() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        await transport.respond(status: 429, header: ["Retry-After": "60"])
        let client = client(transport, clock)
        _ = await client.fetchSections()
        clock.advance(60)
        _ = await client.fetchSections()
        let counts = await transport.counts
        XCTAssertEqual(counts["c1"], 1)
    }

    func testConcurrentRefreshesAndFailedRequestsRespectMinimumInterval() async {
        let clock = QuotaClock()
        let transport = QuotaTransport()
        await transport.respond(status: 503)
        let client = client(transport, clock)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await client.fetchSections() } }
        }
        clock.advance(60)
        _ = await client.fetchSections()
        let counts = await transport.counts
        XCTAssertEqual(counts, ["c1": 1, "c2": 1])
    }

    private func client(_ transport: QuotaTransport, _ clock: QuotaClock) -> CLIProxyClient {
        CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier(), clock: { clock.read() })
    }

    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private final class QuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_792_238_400)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private actor QuotaTransport: CLIProxyTransport {
    private var status = 200
    private var header: [String: [String]] = [:]
    private var scalarHeaders = false
    private(set) var counts: [String: Int] = [:]

    func respond(status: Int, header: [String: String] = [:]) {
        self.status = status
        self.header = header.mapValues { [$0] }
        scalarHeaders = true
    }

    func respond(status: Int, header: [String: [String]]) {
        self.status = status
        self.header = header
        scalarHeaders = false
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard let body = request.httpBody else {
            return (Data(CLIProxyFixtures.credentials.utf8), 200)
        }
        let call = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let account = try XCTUnwrap(call["authIndex"] as? String)
        if account == "a1" { return (CLIProxyFixtures.envelope(CLIProxyFixtures.antigravity), 200) }
        counts[account, default: 0] += 1
        if account == "c1", status != 200 {
            let responseHeader: Any = scalarHeaders ? header.mapValues { $0[0] } as Any : header as Any
            return (try JSONSerialization.data(withJSONObject: [
                "status_code": status, "header": responseHeader, "body": "{}"
            ]), 200)
        }
        return (CLIProxyFixtures.envelope(CLIProxyFixtures.claude), 200)
    }
}
