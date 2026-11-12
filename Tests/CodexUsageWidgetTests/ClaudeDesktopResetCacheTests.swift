import Foundation
import XCTest
@testable import CodexUsageWidget

/// Synthetic Chromium Simple Cache entries shaped like Claude Desktop's real `usage?cedar_ember=1`
/// responses (fake organization UUIDs and grant IDs; zstd frames made with Python's compression.zstd).
final class ClaudeDesktopResetCacheTests: XCTestCase {
    private enum Body {
        // Two unused `type: full` grants ending 2026-11-17T07:59Z and 2026-12-10T22:00Z.
        static let twoTickets = "KLUv/WB1AxUNAPYXRyJAi6oDwLiPlBLaEnjxI0rWkqRnimF4Jnexsk0kt95RFIELPgA7AD0A/CuN61vmCyIlBYphGW13HOaJZABCC6FFgBKVDikdChRSubJXYR/+5UECKK1sjvU2MGYdE7LyRbfQO1giIQEJIjHteQxScoDeNuzEOa3kbdcAAA2f5Eq+spwn0+HQ8J0rGZYQhJWw2z5FHubY4P5pY3keX688K0zBAnkSEFYqGmMsjpU8EYh2+/LeNGswVvjHogKMD9f0rCyMeQ55EyuZw7hNnoRkzkReGtMr9t3h9O15OSBYCBQR5S9UtRfeGsZdLBw27jXazLpFbQ/HsHNLR5QaWEklKCl1IgzM+B/KWFZReAdjto5tMU8yx0SufMPQjbcBMyBQIkGISD3miQcu5N8CjsC+KRIH7Ae6EdclV7eZMRw0FrsAyIPQA/RZN6a/NeChVOx1hFC9S7jY761PliL25jEFw66xQbfGDuljxTCHVHooYFtEygdje7CASqCP48mddugBRzK5hFRYnIyzS9PCKMGsDE+FrAVXN0JLLxez5gsR+Bk="
        // The same two grants with resets_left 0.
        static let spent = "KLUv/WAZA10MAMZWQyJAiVYHALWAVkhsRkBFjSj2S3Jm5Cg6k9QbN4HY72CKopgbOgA1ADsAm0+ZXRAqIVgQZdKtY+HRc4CUWEpsICVLHZQ6EKy0zt6asBfuO0oBSbG7prUuNG4dH2F/sVnkOlrikQ2PEnsnlhU7azdtMDTc5Oy8ivLR1eHQcPvsTHvkgB2206c4Yo4O6r507Wjja/ZlpSka7yqN3XiqcI2xNKwcPZFst8tbp1ujccJ9LSbA+GhcLisK49FC1gQ7szCqc4TwdHkxGGCIlCAU4/aoQCUG6WlP8i4ysxXWNYy6UFjoNM/J5tYupns0DDfN0s9aAkytJKm10ANhxu4jGYsqCdfRuKlDXTw6c0ycfR1IMCBgIiFEtgeK6YF0/l1jBNZNXXbAdiAVcaXl6hwZg86xqgXAF0Kn6xPNGLjWWlOlIk/uUi/me8vJVsSUPaZg2KFo0LWxjb3xDaeCBodWOjtg3CWHQqDL8fROc2gDQ59UWHwG26VpYZRg1sNTImv56ozQouVi1nwhwjwD"
        // `cedar_ember: null`, as the plain usage keys always return.
        static let nullBlock = "KLUv/SClVQMAYoYWG3BpdbCSRg6wTilFMWy6/n/VAKsmo5ZK6f8XAg1jsandDg6bnEqWIEjkQAiVpLbLPp/Gxa+/Bo6gNDKNAx1ZDVV6cN86nwOe6qYsqBKLLRjNqF1UDGmXVTATBACA0BLLxYT5QoRyBg=="
        // `eligible: false, ineligible_reason: "no_grant"`.
        static let ineligible = "KLUv/WCAAKUGAGJNKSBgh9oGYEM8trSz9lOzhijEsjR6w8Ahs1TTmpewIQiWCw0+2EC1waqgUvdyUYvt0KW03UvFoT8Nk+4W1hbsH+a30nl7PVwNppgxRO9iGTt/CgjS3c97ZVMgW3epDdf+qONMpCsfVrGselgotlSKGEAMheSRCpcy1P00B0AoIZQEkCFBCAhCKCQoeXonulan7QcFICR9se08WN5+Z9LbYwoqYxNnAhAAcfNAzvqGqY22kmGGQXCthmdC81XV1dGWsa8NWcu7OiC0xHIxYb4QoZwB"
    }

    private let orgB = "11111111-2222-4333-8444-555555555555"
    private let orgA = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    /// 2026-11-12 10:15 JST, twelve minutes after the reset response was cached.
    private let now = Date(timeIntervalSince1970: 1_794_446_100)
    private let responseDate = "Thu, 12 Nov 2026 01:03:08 GMT"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-reset-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(key: String, body: String?, date: String?) -> Data {
        var bytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        append(UInt64(0xfcfb_6d1b_a772_5c30))
        append(UInt32(5))
        append(UInt32(key.utf8.count))
        append(UInt32(0))
        append(UInt32(0))
        bytes.append(contentsOf: key.utf8)
        if let body { bytes.append(Data(base64Encoded: body)!) }
        bytes.append(contentsOf: [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4])
        var headers = "HTTP/1.1 200\u{0}content-type:application/json\u{0}content-encoding:zstd\u{0}"
        if let date { headers += "date:\(date)\u{0}" }
        bytes.append(contentsOf: headers.utf8)
        bytes.append(Data(repeating: 0, count: 32))
        return bytes
    }

    @discardableResult
    private func write(org: String, variant: Int = 0, body: String?, date: String?, modified: Date,
                       storedKey: String? = nil) throws -> URL {
        let key = ClaudeDesktopResetCache.keys(organization: org)[variant]
        let url = directory.appendingPathComponent(ClaudeDesktopResetCache.entryFileName(forKey: key))
        try entry(key: storedKey ?? key, body: body, date: date).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private var cache: ClaudeDesktopResetCache { ClaudeDesktopResetCache(directory: directory) }

    private func tickets(_ reading: ClaudeDesktopResetCache.Reading?, index: Int = 1) -> [ProviderStat] {
        guard let reading else { return [] }
        return ClaudeResetGrantsClient.stats(for: reading.outcome, accountIndex: index, now: now,
                                             calendar: RingResetFormat.tokyoCalendar,
                                             desktopObservedAt: reading.observedAt)
    }

    func testEntryFileNameIsChromiumSimpleCacheHash() {
        XCTAssertEqual(ClaudeDesktopResetCache.entryFileName(forKey: ClaudeDesktopResetCache.keys(organization: orgB)[0]),
                       "d2ae1cc58ddb066d_0")
    }

    func testTwoFullGrantsBecomeTwoTicketsWithTheirOwnExpiries() throws {
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now.addingTimeInterval(-700))
        let reading = cache.reading(organization: orgB.uppercased(), now: now)
        XCTAssertEqual(reading?.observedAt, Date(timeIntervalSince1970: 1_794_445_388))
        let stats = tickets(reading)
        XCTAssertEqual(stats.first?.title, "Reset tickets")
        XCTAssertEqual(stats.first?.valueText, "2 available · Claude Desktop 10:03 JST 確認")
        XCTAssertEqual(stats.filter { $0.title == "Reset ticket" }.map(\.valueText), [
            "全リセット · 使用可 · 期限 11/17 16:59",
            "全リセット · 使用可 · 期限 12/11 07:00"
        ])
        XCTAssertEqual(stats.filter { $0.title == "Reset ticket expiry" }.map(\.valueText),
                       ["2026-11-17T07:59:00Z", "2026-12-10T22:00:00Z"])
        XCTAssertTrue(stats.allSatisfy { $0.accountIndex == 1 })
    }

    func testAnotherOrganizationNeverSeesTheseTickets() throws {
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now)
        XCTAssertNil(cache.reading(organization: orgA, now: now))
        try write(org: orgA, body: Body.ineligible, date: "Sun, 08 Nov 2026 13:52:19 GMT", modified: now.addingTimeInterval(-300_000))
        let a = cache.reading(organization: orgA, now: now)
        XCTAssertEqual(a?.outcome, .notOffered)
        XCTAssertEqual(tickets(a, index: 0), [])
        XCTAssertEqual(tickets(cache.reading(organization: orgB, now: now)).first?.valueText.hasPrefix("2 available"), true)
    }

    func testNewerSpentOrNullResponseSupersedesOlderTickets() throws {
        try write(org: orgB, variant: 1, body: Body.twoTickets, date: "Wed, 11 Nov 2026 01:00:00 GMT",
                  modified: now.addingTimeInterval(-86_000))
        try write(org: orgB, variant: 0, body: Body.spent, date: responseDate, modified: now.addingTimeInterval(-700))
        XCTAssertEqual(tickets(cache.reading(organization: orgB, now: now)), [])
        try write(org: orgB, variant: 0, body: Body.nullBlock, date: responseDate, modified: now.addingTimeInterval(-600))
        XCTAssertEqual(cache.reading(organization: orgB, now: now)?.outcome, .notOffered)
    }

    func testUnreadableNewestEntryIsUnknownNotTheOlderTickets() throws {
        try write(org: orgB, variant: 1, body: Body.twoTickets, date: responseDate, modified: now.addingTimeInterval(-86_000))
        try write(org: orgB, variant: 0, body: nil, date: responseDate, modified: now.addingTimeInterval(-60))
        XCTAssertNil(cache.reading(organization: orgB, now: now))
    }

    func testHashCollisionWithAnotherKeyIsRejected() throws {
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now,
                  storedKey: ClaudeDesktopResetCache.keys(organization: orgA)[0])
        XCTAssertNil(cache.reading(organization: orgB, now: now))
    }

    func testMissingDateFallsBackToMtimeAndFutureCaptureIsRejected() throws {
        let modified = now.addingTimeInterval(-120)
        try write(org: orgB, body: Body.twoTickets, date: nil, modified: modified)
        XCTAssertEqual(cache.reading(organization: orgB, now: now)?.observedAt.timeIntervalSince1970 ?? 0,
                       modified.timeIntervalSince1970, accuracy: 1)
        try write(org: orgB, body: Body.twoTickets, date: "Fri, 13 Nov 2026 01:03:08 GMT", modified: now)
        XCTAssertNil(cache.reading(organization: orgB, now: now))
    }

    func testExpiredTicketDropsOutWhileTheOtherStays() throws {
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now)
        let later = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18
        let stats = ClaudeResetGrantsClient.stats(for: cache.reading(organization: orgB, now: now)!.outcome,
                                                  accountIndex: 1, now: later,
                                                  calendar: RingResetFormat.tokyoCalendar)
        XCTAssertEqual(stats.first?.valueText, "1 available")
    }

    func testRejectsNonUUIDOrganizationAndMissingDirectory() {
        XCTAssertNil(cache.reading(organization: "../../etc", now: now))
        XCTAssertNil(ClaudeDesktopResetCache(directory: directory.appendingPathComponent("missing"))
            .reading(organization: orgB, now: now))
    }

    func testOrganizationComesFromThatLoginsStateFile() throws {
        let dirA = directory.appendingPathComponent("a"), dirB = directory.appendingPathComponent("b")
        for (dir, org) in [(dirA, orgA), (dirB, orgB.uppercased())] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"projects":{},"oauthAccount":{"organizationUuid":"\#(org)","emailAddress":"x@example.com"}}"#.utf8)
                .write(to: dir.appendingPathComponent(".claude.json"))
        }
        XCTAssertEqual(ClaudeDesktopResetCache.organization(configDir: dirA.path), orgA)
        XCTAssertEqual(ClaudeDesktopResetCache.organization(configDir: dirB.path), orgB)
        XCTAssertEqual(ClaudeDesktopResetCache.organization(configDir: nil, home: dirA.path), orgA)
        XCTAssertNil(ClaudeDesktopResetCache.organization(configDir: directory.appendingPathComponent("none").path))
    }

    // MARK: - ClaudeCLIUsage integration

    func testOnlyTheMatchingAccountShowsDesktopTicketsAndThePositionIsNeverCopied() async throws {
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now)
        let cache = self.cache, orgA = self.orgA, orgB = self.orgB
        let configs = ["/tmp/test-claude-a": orgA, "/tmp/test-claude-b": orgB]
        let usage = ClaudeCLIUsage(runner: { _, _ in Self.cliResult }, grantsClient: Self.notOfferedClient,
                                   desktopResets: { configDir, now in
                                       configDir.flatMap { configs[$0] }.flatMap { cache.reading(organization: $0, now: now) }
                                   })
        let accounts = [ClaudeCLIAccount(label: "A", configDir: "/tmp/test-claude-a"),
                        ClaudeCLIAccount(label: "B", configDir: "/tmp/test-claude-b")]
        let t0 = now
        await usage.refreshNow(accounts, timeZone: .current, now: { t0 })
        let stats = usage.section(accounts: accounts, now: t0, timeZone: .current)?.section.stats ?? []
        let ticketStats = stats.filter { $0.title.hasPrefix("Reset ticket") }
        XCTAssertEqual(ticketStats.filter { $0.title == "Reset ticket" }.count, 2)
        XCTAssertTrue(ticketStats.allSatisfy { $0.accountIndex == 1 }, "\(ticketStats)")
        XCTAssertFalse(stats.contains { $0.accountIndex == 0 && $0.title.hasPrefix("Reset ticket") })
    }

    func testNextCycleWithSpentResponseClearsTicketsInsteadOfKeepingThem() async throws {
        let url = try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now)
        let cache = self.cache, orgB = self.orgB
        let usage = ClaudeCLIUsage(runner: { _, _ in Self.cliResult }, grantsClient: Self.notOfferedClient,
                                   desktopResets: { _, now in cache.reading(organization: orgB, now: now) })
        let account = [ClaudeCLIAccount(label: "B", configDir: "/tmp/test-claude-b")]
        let t0 = now
        await usage.refreshNow(account, timeZone: .current, now: { t0 })
        XCTAssertEqual(usage.section(accounts: account, now: t0, timeZone: .current)?.section.stats
            .filter { $0.title == "Reset ticket" }.count, 2)
        try write(org: orgB, body: Body.spent, date: "Thu, 12 Nov 2026 01:20:00 GMT", modified: now.addingTimeInterval(300))
        await usage.refreshNow(account, timeZone: .current, now: { t0.addingTimeInterval(400) })
        XCTAssertEqual(usage.section(accounts: account, now: t0.addingTimeInterval(400), timeZone: .current)?.section.stats
            .filter { $0.title.hasPrefix("Reset ticket") }, [])
        try FileManager.default.removeItem(at: url)
        await usage.refreshNow(account, timeZone: .current, now: { t0.addingTimeInterval(800) })
        XCTAssertEqual(usage.section(accounts: account, now: t0.addingTimeInterval(800), timeZone: .current)?.section.stats
            .filter { $0.title.hasPrefix("Reset ticket") }, [])
    }

    func testStaleDesktopNegativeKeepsTheCurrentRateLimitNoteWhileHeldTicketsStillShow() async throws {
        // A: Desktop's last word is a four-day-old "no_grant"; B: tickets observed 12 minutes ago.
        try write(org: orgA, body: Body.ineligible, date: "Sun, 08 Nov 2026 13:52:19 GMT",
                  modified: now.addingTimeInterval(-300_000))
        try write(org: orgB, body: Body.twoTickets, date: responseDate, modified: now.addingTimeInterval(-700))
        let cache = self.cache, orgA = self.orgA, orgB = self.orgB
        let configs = ["/tmp/test-claude-a": orgA, "/tmp/test-claude-b": orgB]
        let limited = ClaudeResetGrantsClient(loadToken: { _ in "test-token" }, transport: { _ in (Data(), 429, "3600") })
        let usage = ClaudeCLIUsage(runner: { _, _ in Self.cliResult }, grantsClient: limited,
                                   desktopResets: { configDir, now in
                                       configDir.flatMap { configs[$0] }.flatMap { cache.reading(organization: $0, now: now) }
                                   })
        let accounts = [ClaudeCLIAccount(label: "A", configDir: "/tmp/test-claude-a"),
                        ClaudeCLIAccount(label: "B", configDir: "/tmp/test-claude-b")]
        let t0 = now
        await usage.refreshNow(accounts, timeZone: .current, now: { t0 })
        let stats = usage.section(accounts: accounts, now: t0, timeZone: .current)?.section.stats ?? []
        let a = stats.filter { $0.accountIndex == 0 && ($0.title.hasPrefix("Reset ticket") || $0.title == "リセットチケット") }
        XCTAssertEqual(a.map(\.title), ["リセットチケット"])
        XCTAssertTrue(a.first?.valueText.hasPrefix("取得の回数制限中") ?? false, "\(a)")
        let b = stats.filter { $0.accountIndex == 1 && $0.title.hasPrefix("Reset ticket") }
        XCTAssertEqual(b.first?.valueText, "2 available · Claude Desktop 10:03 JST 確認")
        XCTAssertEqual(b.filter { $0.title == "Reset ticket" }.count, 2)
    }

    func testFreshDesktopNegativeStillReplacesTheOAuthNote() async throws {
        try write(org: orgB, body: Body.spent, date: responseDate, modified: now)
        let cache = self.cache, orgB = self.orgB
        let limited = ClaudeResetGrantsClient(loadToken: { _ in "test-token" }, transport: { _ in (Data(), 429, "3600") })
        let usage = ClaudeCLIUsage(runner: { _, _ in Self.cliResult }, grantsClient: limited,
                                   desktopResets: { _, now in cache.reading(organization: orgB, now: now) })
        let account = [ClaudeCLIAccount(label: "B", configDir: "/tmp/test-claude-b")]
        let t0 = now
        await usage.refreshNow(account, timeZone: .current, now: { t0 })
        XCTAssertEqual(usage.section(accounts: account, now: t0, timeZone: .current)?.section.stats
            .filter { $0.title.hasPrefix("Reset ticket") || $0.title == "リセットチケット" }, [])
    }

    /// Opt-in check against this Mac's real Claude Desktop cache and Claude Code logins. Reads only;
    /// prints counts and expiries, never organization IDs or grant IDs.
    func testLiveDesktopCacheIfRequested() throws {
        guard let expected = ProcessInfo.processInfo.environment["USAGERINGS_LIVE_DESKTOP_RESETS"] else {
            throw XCTSkip("set USAGERINGS_LIVE_DESKTOP_RESETS=<configDir>:<count>[,<configDir>:<count>] to run")
        }
        let now = Date()
        for item in expected.split(separator: ",") {
            let parts = item.split(separator: ":").map(String.init)
            let configDir = parts[0], count = Int(parts[1])!
            let reading = ClaudeCLIUsage.liveDesktopResets(configDir, now)
            let stats = reading.map {
                ClaudeResetGrantsClient.stats(for: $0.outcome, accountIndex: 0, now: now,
                                              calendar: RingResetFormat.tokyoCalendar, desktopObservedAt: $0.observedAt)
            } ?? []
            let shown = stats.filter { $0.title == "Reset ticket" }.map(\.valueText)
            print("LIVE \(URL(fileURLWithPath: configDir).lastPathComponent): reading=\(reading != nil)",
                  "summary=\(stats.first?.valueText ?? "-")", "tickets=\(shown)")
            XCTAssertEqual(shown.count, count, configDir)
        }
    }

    private static let cliResult = CodexUsageService.CommandResult(
        terminationStatus: 0,
        stdout: Data("""
        [{"provider":"claude","source":"claude","usage":{"primary":{"usedPercent":30,"windowMinutes":300,"resetsAt":"2026-11-12T05:00:00Z"},"secondary":{"usedPercent":2,"windowMinutes":10080,"resetsAt":"2026-11-16T17:00:00Z"}}}]
        """.utf8),
        stderr: Data()
    )

    /// What the OAuth endpoint really answers today: `eligible: false, ineligible_reason: "surface"`.
    private static let notOfferedClient = ClaudeResetGrantsClient(loadToken: { _ in "test-token" }, transport: { _ in
        (Data(#"{"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#.utf8), 200, nil)
    })
}
