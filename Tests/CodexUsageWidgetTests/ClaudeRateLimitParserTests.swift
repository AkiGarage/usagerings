import XCTest
import SwiftUI
@testable import CodexUsageWidget

final class ClaudeRateLimitParserTests: XCTestCase {
    private let event = date("2026-10-21T04:50:50.364Z")

    func testSessionMinuteClock() throws {
        let block = try parse("session", "2:20pm")
        XCTAssertEqual(block.kind, .session)
        XCTAssertEqual(block.resetAt, date("2026-10-21T05:20:00Z"))
        XCTAssertTrue(block.timeZoneKnown)
    }

    func testSessionHourClock() throws {
        XCTAssertEqual(try parse("session", "3pm").resetAt, date("2026-10-21T06:00:00Z"))
    }

    func testWeeklyClockUsesNextDay() throws {
        let block = try parse("weekly", "9am")
        XCTAssertEqual(block.kind, .weekly)
        XCTAssertEqual(block.resetAt, date("2026-10-22T00:00:00Z"))
    }

    func testExplicitMonthAt() throws {
        XCTAssertEqual(try parse("weekly", "Oct 19 at 9am", at: date("2026-10-15T04:50:50Z")).resetAt,
                       date("2026-10-19T00:00:00Z"))
    }

    func testExplicitMonthComma() throws {
        XCTAssertEqual(try parse("weekly", "Oct 19, 9am", at: date("2026-10-15T04:50:50Z")).resetAt,
                       date("2026-10-19T00:00:00Z"))
    }

    func testYearRollover() throws {
        XCTAssertEqual(try parse("weekly", "Oct 19 9am").resetAt, date("2027-10-19T00:00:00Z"))
    }

    func testRecentExplicitPastDoesNotRollYear() throws {
        let block = try parse("weekly", "Oct 21 at 9am")
        XCTAssertEqual(block.resetAt, date("2026-10-21T00:00:00Z"))
        XCTAssertFalse(block.isActive(at: event))
    }

    func testUnknownAndMissingZonesUseTokyo() throws {
        for suffix in [" (Mars/Base)", ""] {
            let block = try XCTUnwrap(ClaudeRateLimitParser.parse(
                text: "You've hit your session limit · resets 3pm" + suffix, eventTimestamp: event))
            XCTAssertFalse(block.timeZoneKnown)
            XCTAssertEqual(block.resetAt, date("2026-10-21T06:00:00Z"))
        }
    }

    func testKnownNonTokyoZone() throws {
        let block = try XCTUnwrap(ClaudeRateLimitParser.parse(
            text: "You've hit your session limit · resets 3pm (America/New_York)", eventTimestamp: event))
        XCTAssertEqual(block.resetAt, date("2026-10-21T19:00:00Z"))
        XCTAssertTrue(block.timeZoneKnown)
    }

    func testCurlyApostropheAndNonClaudeError() throws {
        XCTAssertNotNil(ClaudeRateLimitParser.parse(text: "You’ve hit your session limit · resets 3pm (Asia/Tokyo)", eventTimestamp: event))
        XCTAssertNil(ClaudeRateLimitParser.parse(text: "[1302][Rate limit reached for requests]", eventTimestamp: event))
        XCTAssertNil(ClaudeRateLimitParser.parse(text: "You've hit your session limit · resets 13pm", eventTimestamp: event))
        XCTAssertNil(ClaudeRateLimitParser.parse(text: "You've hit your weekly limit · resets Feb 31 at 9am", eventTimestamp: event))
    }

    func testNoonMidnightAndStrictlyAfter() throws {
        XCTAssertEqual(try parse("session", "12am").resetAt, date("2026-10-21T15:00:00Z"))
        XCTAssertEqual(try parse("session", "12pm").resetAt, date("2026-10-22T03:00:00Z"))
        XCTAssertEqual(try parse("session", "3pm", at: date("2026-10-21T06:00:00Z")).resetAt,
                       date("2026-10-22T06:00:00Z"))
    }

    func testClassifierUsesTopLevelFields() {
        let user = #"{"type":"user","timestamp":"2026-10-21T04:50:50.364Z","message":{"content":[{"text":"\"isApiErrorMessage\":true rate_limit"}]}}"#
        XCTAssertEqual(ClaudeRateLimitParser.classify(line: user), .other)
        XCTAssertEqual(ClaudeRateLimitParser.classify(line: normal(model: "<synthetic>")), .other)
        XCTAssertEqual(ClaudeRateLimitParser.classify(line: normal()), .normalAssistant(timestamp: date("2026-10-21T04:51:00Z")))
        XCTAssertEqual(ClaudeRateLimitParser.classify(line: "broken json"), .other)
    }

    func testSanitizedRealTranscriptFixture() throws {
        // Only the event fields required by the parser are retained.
        let fixture = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-10-17T13:59:54.622Z","message":{"content":[{"text":"You've hit your session limit · resets 1:30am (Asia/Tokyo)"}]}}"#
        guard case let .rateLimit(text, timestamp) = ClaudeRateLimitParser.classify(line: fixture) else {
            return XCTFail("Real fixture was not classified")
        }
        XCTAssertEqual(timestamp, date("2026-10-17T13:59:54.622Z"))
        XCTAssertEqual(ClaudeRateLimitParser.parse(text: text, eventTimestamp: timestamp)?.resetAt,
                       date("2026-10-17T16:30:00Z"))
    }

    func testJSTRecoveryAndCardText() throws {
        let session = try parse("session", "3pm")
        XCTAssertEqual(ClaudeRateLimitParser.recoveryShort(resetAt: session.resetAt, now: event), "15:00")
        XCTAssertEqual(ClaudeRateLimitParser.cardLine(block: session, now: event), "5時間枠の制限中・15:00に復帰")
        let weekly = ClaudeBlock(kind: .weekly, resetAt: date("2026-10-24T04:00:00Z"), timeZoneKnown: false)
        XCTAssertEqual(ClaudeRateLimitParser.recoveryShort(resetAt: weekly.resetAt, now: event), "10/24 13:00")
        XCTAssertEqual(ClaudeRateLimitParser.cardLine(block: weekly, now: event), "週の制限中・10/24 13:00に復帰（時帯未確認）")
    }

    func testMonitorActiveAndExpired() async throws {
        let root = try directory()
        try write(errorLine(), to: root, name: "event", modified: event)
        let monitor = ClaudeRateLimitMonitor(accounts: [0: [root]], remote: nil)
        let active = await monitor.blocks(now: event)
        XCTAssertEqual(active[0]?.resetAt, date("2026-10-21T06:00:00Z"))
        let expired = await monitor.blocks(now: date("2026-10-21T06:00:00Z"))
        XCTAssertTrue(expired.isEmpty)
    }

    func testMonitorClearedAcrossFiles() async throws {
        let root = try directory()
        try write(errorLine(), to: root, name: "error", modified: event)
        try write(normal(), to: root, name: "normal", modified: event)
        let blocks = await ClaudeRateLimitMonitor(accounts: [0: [root]]).blocks(now: event.addingTimeInterval(60))
        XCTAssertTrue(blocks.isEmpty)
    }

    func testSyntheticDoesNotClearAndOlderNormalDoesNotClear() async throws {
        let root = try directory()
        try write(normal(timestamp: "2026-10-21T04:00:00Z") + "\n" + errorLine() + "\n" + normal(model: "<synthetic>"),
                  to: root, name: "event", modified: event)
        let blocks = await ClaudeRateLimitMonitor(accounts: [0: [root]]).blocks(now: event)
        XCTAssertNotNil(blocks[0])
    }

    func testLatestParsedEventWinsNotFileOrder() async throws {
        let root = try directory()
        try write(errorLine(clock: "3pm"), to: root, name: "older", modified: event)
        try write(errorLine(clock: "4pm", timestamp: "2026-10-21T05:00:00Z"), to: root, name: "newer", modified: event.addingTimeInterval(-1))
        let blocks = await ClaudeRateLimitMonitor(accounts: [0: [root]]).blocks(now: event.addingTimeInterval(600))
        XCTAssertEqual(blocks[0]?.resetAt, date("2026-10-21T07:00:00Z"))
    }

    func testOldFilesAndSixthNewestIgnored() async throws {
        let root = try directory()
        try write(errorLine(), to: root, name: "old", modified: event.addingTimeInterval(-9 * 86400))
        let monitor = ClaudeRateLimitMonitor(accounts: [0: [root]])
        let old = await monitor.blocks(now: event)
        XCTAssertTrue(old.isEmpty)
        try write(errorLine(), to: root, name: "sixth", modified: event.addingTimeInterval(-60))
        for i in 0..<5 { try write("{}", to: root, name: "new\(i)", modified: event) }
        let capped = await monitor.blocks(now: event)
        XCTAssertTrue(capped.isEmpty)
    }

    func testTailCutMidLineAndOversizedLine() async throws {
        let root = try directory()
        try write(String(repeating: "é", count: 140000) + "\n" + errorLine(), to: root, name: "large", modified: event)
        let monitor = ClaudeRateLimitMonitor(accounts: [0: [root]])
        let blocks = await monitor.blocks(now: event)
        XCTAssertNotNil(blocks[0])
        try write(String(repeating: "x", count: 300000), to: root, name: "large", modified: event)
        let oversized = await monitor.blocks(now: event)
        XCTAssertTrue(oversized.isEmpty)
    }

    func testRemoteIsOnlyBAndCanClearLocalB() async throws {
        let root = try directory()
        try write(errorLine(), to: root, name: "event", modified: event)
        let blocks = await ClaudeRateLimitMonitor(accounts: [0: [root], 1: [root]], remote: Remote(fixture: [normal()]))
            .blocks(now: event.addingTimeInterval(60))
        XCTAssertNotNil(blocks[0])
        XCTAssertNil(blocks[1])
        let remoteOnly = await ClaudeRateLimitMonitor(accounts: [:], remote: Remote(fixture: [errorLine()])).blocks(now: event)
        XCTAssertNotNil(remoteOnly[1])
        XCTAssertNil(remoteOnly[0])
    }

    func testLiveSSHDisabledUnderXCTest() async {
        let lines = await ClaudeRateLimitSSH.shared.lines()
        XCTAssertTrue(lines.isEmpty)
    }

    func testZeroPercentDoesNotBlock() {
        let bar = CollapsedUsageBar(id: "claude-1", label: "B", title: "Claude B", providerColor: .orange,
                                    limit: UsageLimit(title: "5h", leftPercent: 0, resetText: ""))
        XCTAssertFalse(bar.isBlocked)
        XCTAssertTrue(bar.isWarning)
        XCTAssertEqual(bar.fillColor, CollapsedUsageBar.criticalColor)
        XCTAssertNil(RingDetailCardModel.make(bar: bar, now: Date())?.blockText)
    }

    func testBlockedBarAndCardWithoutUsageAndExpiredBar() throws {
        let now = Date()
        var bar = CollapsedUsageBar(id: "claude-1", label: "B", title: "Claude B", providerColor: .orange, limit: nil,
                                    block: ClaudeBlock(kind: .session, resetAt: now.addingTimeInterval(7200), timeZoneKnown: false))
        XCTAssertTrue(bar.isBlocked)
        XCTAssertFalse(bar.isWarning)
        XCTAssertEqual(bar.fillColor, .secondary)
        XCTAssertEqual(bar.blockedSymbolName, CollapsedUsageBar.blockedSymbol)
        XCTAssertTrue(try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now)?.blockText).contains("時帯未確認"))
        bar.block = ClaudeBlock(kind: .session, resetAt: now.addingTimeInterval(-1), timeZoneKnown: true)
        XCTAssertFalse(bar.isBlocked)
        XCTAssertEqual(bar.fillColor, .orange)
        XCTAssertNil(RingDetailCardModel.make(bar: bar, now: now))
    }

    func testPreviewOnlyBlocksBWithRequestedSymbol() {
        for mode in ["lock", "pause"] {
            let bars = CollapsedUsageBar.bars(for: .placeholder, blockedPreview: mode)
            XCTAssertEqual(bars.filter(\.isBlocked).map(\.id), ["claude-1"])
            XCTAssertEqual(bars.first { $0.id == "claude-1" }?.blockedSymbolName,
                           mode == "pause" ? CollapsedUsageBar.blockedPauseSymbol : CollapsedUsageBar.blockedSymbol)
        }
        XCTAssertFalse(CollapsedUsageBar.bars(for: .placeholder, blockedPreview: nil).contains(where: \.isBlocked))
    }

    func testServiceAttachesMonitorToClaudeOnly() async throws {
        let root = try directory()
        try write(errorLine(), to: root, name: "event", modified: event)
        let service = MultiUsageService(commandRunner: { _ in
            CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client(), claudeRateLimitMonitor: ClaudeRateLimitMonitor(accounts: [1: [root]]))
        let snapshot = await service.fetchAll(now: event)
        XCTAssertNotNil(snapshot.sections.first { $0.provider == .claude }?.claudeProfileBlocks[1])
        XCTAssertTrue(snapshot.sections.filter { $0.provider != .claude }.allSatisfy { $0.claudeProfileBlocks.isEmpty })
        let bars = CollapsedUsageBar.bars(for: snapshot, blockedPreview: nil)
        XCTAssertNotNil(bars.first { $0.id == "claude-profile-1" }?.block)
        XCTAssertNil(bars.first { $0.id == "claude-profile-1" }?.accountID)
        XCTAssertNil(bars.first { $0.id == "claude-1" }?.block)
        XCTAssertNil(bars.first { $0.id == "claude-0" }?.block)
    }

    private func parse(_ kind: String, _ clock: String, at timestamp: Date? = nil) throws -> ClaudeBlock {
        try XCTUnwrap(ClaudeRateLimitParser.parse(text: "You've hit your \(kind) limit · resets \(clock) (Asia/Tokyo)", eventTimestamp: timestamp ?? event))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-rate-limit-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to root: URL, name: String, modified: Date) throws {
        let url = root.appendingPathComponent(name + ".jsonl")
        try Data((text + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func errorLine(clock: String = "3pm", timestamp: String = "2026-10-21T04:50:50.364Z") -> String {
        #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"\#(timestamp)","message":{"content":[{"text":"You've hit your session limit · resets \#(clock) (Asia/Tokyo)"}]}}"#
    }

    private func normal(model: String = "claude-sonnet-4-6", timestamp: String = "2026-10-21T04:51:00Z") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","message":{"model":"\#(model)","content":[]}}"#
    }

    private struct Remote: ClaudeRateLimitRemote {
        let fixture: [String]
        func lines() async -> [String] { fixture }
    }

    func testRecoveryLinesAlwaysIncludeTokyoDate() {
        let lines = ClaudeRateLimitParser.recoveryLines(resetAt: Date(timeIntervalSince1970: 1792602000))
        XCTAssertEqual(lines.date, "10/22")
        XCTAssertEqual(lines.time, "02:00")
    }
}

private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)!

}
