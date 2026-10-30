import XCTest
@testable import CodexUsageWidget

final class ClaudeCLIUsageTests: XCTestCase {
    private static let okJSON = Data("""
    [{"provider":"claude","source":"claude","usage":{"primary":{"usedPercent":30,"windowMinutes":300,"resetsAt":"2026-10-30T07:50:00Z"},"secondary":{"usedPercent":72,"windowMinutes":10080,"resetsAt":"2026-11-02T00:00:00Z"}}}]
    """.utf8)

    private func result(_ data: Data, status: Int32 = 0) -> CodexUsageService.CommandResult {
        CodexUsageService.CommandResult(terminationStatus: status, stdout: data, stderr: Data())
    }

    func testUsesCLISourceArgumentsAndLabelsSource() async {
        let seen = OSAllocatedUnfairLockBox()
        let cli = ClaudeCLIUsage(runner: { args in seen.set(args); return self.result(Self.okJSON) })
        let t0 = Date()
        XCTAssertNil(cli.section(now: t0, timeZone: .current), "first call must not wait")
        var section = cli.section(now: Date(), timeZone: .current)
        for _ in 0..<100 where section == nil {  // background refresh started by the first call
            try? await Task.sleep(for: .milliseconds(20))
            section = cli.section(now: Date(), timeZone: .current)
        }
        XCTAssertEqual(section?.fromCache, false)
        XCTAssertEqual(seen.get(), ["usage", "--provider", "claude", "--source", "cli", "--format", "json"])
        XCTAssertFalse(seen.get().contains("web"))
        let merged = ClaudeCLIUsage.merge(cli: section, proxy: nil)
        XCTAssertEqual(merged?.windows.count, 2)
        XCTAssertEqual(merged?.stats.last, ProviderStat(title: "取得元", valueText: "CodexBar CLI"))
    }

    func testFallsBackToProxyWhenCLIFails() async {
        let cli = ClaudeCLIUsage(runner: { _ in self.result(Data("[]".utf8), status: 1) })
        _ = await cli.refreshNow(now: Date(), timeZone: .current)
        let section = cli.section(now: Date(), timeZone: .current)
        XCTAssertNil(section)
        let proxy = ProviderSection(provider: .claude, windows: [], stats: [], failureText: "x")
        XCTAssertEqual(ClaudeCLIUsage.merge(cli: section, proxy: proxy)?.stats.last?.valueText, "CLIProxyAPI（予備）")
    }

    func testCachedValueReturnedWithoutWaitingAndMarkedStale() async {
        let calls = OSAllocatedUnfairLockBox()
        let cli = ClaudeCLIUsage(runner: { args in calls.set(args); return self.result(Self.okJSON) }, refreshInterval: 60)
        let t0 = Date()
        _ = await cli.refreshNow(now: t0, timeZone: .current)
        let later = cli.section(now: t0.addingTimeInterval(120), timeZone: .current)
        XCTAssertEqual(later?.fromCache, true)
        XCTAssertNil(cli.section(now: t0.addingTimeInterval(700), timeZone: .current), "old cache falls back to proxy")
        XCTAssertEqual(ClaudeCLIUsage.merge(cli: later, proxy: nil)?.stats.last?.valueText, "CodexBar CLI（前回値）")
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [String] { lock.lock(); defer { lock.unlock() }; return value }
}
