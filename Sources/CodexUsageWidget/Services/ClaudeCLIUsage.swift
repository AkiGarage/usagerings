import Foundation
import os

/// Claude usage via `CodexBarCLI usage --provider claude --source cli` (no browser cookies).
/// The CLI probe takes 20-30 s, so a cached value is returned at once and refreshed in the
/// background; only the very first fetch waits (bounded by `timeout`).
final class ClaudeCLIUsage: Sendable {
    static let arguments = ["usage", "--provider", "claude", "--source", "cli", "--format", "json"]
    static let sourceTitle = "取得元"
    static let cliSource = "CodexBar CLI"
    static let cachedSource = "CodexBar CLI（前回値）"
    static let proxySource = "CLIProxyAPI（予備）"

    typealias Runner = @Sendable ([String]) async throws -> CodexUsageService.CommandResult

    private struct State {
        var section: ProviderSection?
        var fetchedAt: Date?
        var refreshing = false
    }

    private let runner: Runner
    private let refreshInterval: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    private let maxCacheAge: TimeInterval

    init(runner: @escaping Runner, refreshInterval: TimeInterval = 120, maxCacheAge: TimeInterval = 600) {
        self.runner = runner
        self.refreshInterval = refreshInterval
        self.maxCacheAge = maxCacheAge
    }

    static func live(cliPath: String, timeout: TimeInterval = 60) -> ClaudeCLIUsage {
        ClaudeCLIUsage(runner: { arguments in
            try await SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath), timeout: timeout).run(arguments)
        })
    }

    struct Result {
        var section: ProviderSection
        var fromCache: Bool
    }

    /// Never waits for the CLI: returns the cached section (nil before the first success) and
    /// kicks a background refresh when due. Cache older than `maxCacheAge` is dropped so a
    /// broken CLI falls back to CLIProxyAPI instead of pinning old numbers.
    func section(now: Date, timeZone: TimeZone) -> Result? {
        let snapshot = state.withLock { $0 }
        let age = snapshot.fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
        if age >= refreshInterval, startRefreshIfIdle() {
            Task.detached { [self] in _ = await self.runRefresh(now: Date(), timeZone: timeZone) }
        }
        guard let cached = snapshot.section, age < maxCacheAge else { return nil }
        return Result(section: cached, fromCache: age >= refreshInterval)
    }

    /// Test hook: run one refresh and wait for it.
    func refreshNow(now: Date, timeZone: TimeZone) async -> ProviderSection? {
        guard startRefreshIfIdle() else { return nil }
        return await runRefresh(now: now, timeZone: timeZone)
    }

    private func startRefreshIfIdle() -> Bool {
        state.withLock { s in
            if s.refreshing { return false }
            s.refreshing = true
            return true
        }
    }

    private func runRefresh(now: Date, timeZone: TimeZone) async -> ProviderSection? {
        var parsed: ProviderSection?
        if let result = try? await runner(Self.arguments), !result.timedOut, result.terminationStatus == 0,
           let section = try? MultiProviderParser.parse(result.stdout, provider: .claude, now: now, timeZone: timeZone),
           section.failureText == nil, !section.windows.isEmpty {
            parsed = section
        }
        return state.withLock { s in
            s.refreshing = false
            if let parsed {
                s.section = parsed
                s.fetchedAt = now
            }
            return parsed
        }
    }

    /// CLI first; the CLIProxyAPI section only when the CLI has never succeeded.
    static func merge(cli result: Result?, proxy: ProviderSection?) -> ProviderSection? {
        if let result {
            var cli = result.section
            cli.stats.removeAll { $0.title == sourceTitle }
            cli.stats.append(ProviderStat(title: sourceTitle, valueText: result.fromCache ? cachedSource : cliSource))
            if let proxy {
                cli.claudeProfileBlocks = proxy.claudeProfileBlocks
                cli.claudeRemoteFailureText = proxy.claudeRemoteFailureText
            }
            return cli
        }
        guard var proxy else { return nil }
        proxy.stats.append(ProviderStat(title: sourceTitle, valueText: proxySource))
        return proxy
    }
}
