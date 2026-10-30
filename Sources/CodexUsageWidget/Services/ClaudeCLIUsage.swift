import Foundation
import os

/// One Claude login, identified only by its config directory (never its contents).
struct ClaudeCLIAccount: Codable, Equatable, Sendable {
    var label: String
    /// Absolute path, or nil for the CLI default (~/.claude, no CLAUDE_CONFIG_DIR).
    var configDir: String?

    var displayDir: String {
        guard let configDir else { return "~/.claude" }
        let home = NSHomeDirectory()
        return configDir.hasPrefix(home + "/") ? "~" + configDir.dropFirst(home.count) : configDir
    }

    /// Stable per directory so labels and hide settings survive refreshes and restarts.
    func accountID(salt: Data = AccountIdentitySalt.load()) -> AccountID {
        let dir = configDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "default"
        return AccountID(provider: .claude, source: "claude-config-dir", value: dir, salt: salt)
    }
}

/// "Claude accounts" setting. Empty storage = auto-detect: ~/.claude-a / ~/.claude-b
/// directories when they exist (existence only), otherwise ~/.claude alone.
enum ClaudeCLIAccountSettings {
    static let key = "claudeCLIAccounts"

    static func load(defaults: UserDefaults = .standard, home: String = NSHomeDirectory(),
                     isDirectory: (String) -> Bool = Self.directoryExists) -> [ClaudeCLIAccount] {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([ClaudeCLIAccount].self, from: data), !stored.isEmpty {
            return stored
        }
        return detected(home: home, isDirectory: isDirectory)
    }

    static func detected(home: String, isDirectory: (String) -> Bool) -> [ClaudeCLIAccount] {
        let found = [("A", "/.claude-a"), ("B", "/.claude-b")]
            .filter { isDirectory(home + $0.1) }
            .map { ClaudeCLIAccount(label: $0.0, configDir: home + $0.1) }
        return found.isEmpty ? [ClaudeCLIAccount(label: "Claude", configDir: nil)] : found
    }

    static func save(_ accounts: [ClaudeCLIAccount], defaults: UserDefaults = .standard) {
        if accounts.isEmpty { defaults.removeObject(forKey: key); return }
        defaults.set(try? JSONEncoder().encode(accounts), forKey: key)
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// One "label = path" per line; blank path or "~/.claude" means the default login.
    static func parse(_ text: String, home: String = NSHomeDirectory()) -> [ClaudeCLIAccount] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let label = parts.first, !label.isEmpty else { return nil }  // reject lines without "="
            var path = parts[1]
            if path.hasPrefix("~") { path = home + path.dropFirst() }
            let isDefault = path.isEmpty || path == home + "/.claude"
            return ClaudeCLIAccount(label: label, configDir: isDefault ? nil : path)
        }
    }

    static func format(_ accounts: [ClaudeCLIAccount]) -> String {
        accounts.map { "\($0.label) = \($0.displayDir)" }.joined(separator: "\n")
    }
}

/// Claude usage via `CodexBarCLI usage --provider claude --source cli`, one run per configured
/// config dir (CLAUDE_CONFIG_DIR). Runs take 10-30 s, so callers never wait: cached values are
/// returned at once and due accounts are refreshed one after another in the background.
final class ClaudeCLIUsage: Sendable {
    static let arguments = ["usage", "--provider", "claude", "--source", "cli", "--format", "json"]
    static let sourceTitle = "取得元"
    static let cliSource = "CodexBar CLI"
    static let cachedSource = "CodexBar CLI（前回値）"
    static let proxySource = "CLIProxyAPI（予備）"

    typealias Runner = @Sendable (_ arguments: [String], _ environment: [String: String]?) async throws
        -> CodexUsageService.CommandResult

    private struct Entry {
        var section: ProviderSection?
        var fetchedAt: Date?
        var attemptedAt: Date?
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var refreshing = false
    }

    private let runner: Runner
    private let refreshInterval: TimeInterval
    private let maxCacheAge: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(runner: @escaping Runner, refreshInterval: TimeInterval = 120, maxCacheAge: TimeInterval = 600) {
        self.runner = runner
        self.refreshInterval = refreshInterval
        self.maxCacheAge = maxCacheAge
    }

    static func live(cliPath: String, timeout: TimeInterval = 60) -> ClaudeCLIUsage {
        ClaudeCLIUsage(runner: { arguments, environment in
            try await SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath), timeout: timeout,
                                       environment: environment).run(arguments)
        })
    }

    struct Result {
        var section: ProviderSection
        /// Every account's value is from this refresh cycle (none older than the interval).
        var fromCache: Bool
    }

    private static func key(_ account: ClaudeCLIAccount) -> String { account.configDir ?? "" }

    /// Never waits. Returns nil until at least one account has a usable value.
    func section(accounts: [ClaudeCLIAccount], now: Date, timeZone: TimeZone, salt: Data? = nil) -> Result? {
        guard !accounts.isEmpty else { return nil }
        let entries = state.withLock { $0.entries }
        let due = accounts.filter { account in
            let entry = entries[Self.key(account)]
            let last = entry?.attemptedAt ?? .distantPast
            return now.timeIntervalSince(last) >= refreshInterval
        }
        if !due.isEmpty, startRefreshIfIdle() {
            Task.detached { [self] in await self.runRefresh(due, timeZone: timeZone) }
        }
        return Self.build(accounts: accounts, entries: entries, now: now,
                          refreshInterval: refreshInterval, maxCacheAge: maxCacheAge, salt: salt)
    }

    /// Test hook: refresh the given accounts sequentially and wait.
    func refreshNow(_ accounts: [ClaudeCLIAccount], timeZone: TimeZone, now: @escaping @Sendable () -> Date = Date.init) async {
        guard startRefreshIfIdle() else { return }
        await runRefresh(accounts, timeZone: timeZone, now: now)
    }

    private func startRefreshIfIdle() -> Bool {
        state.withLock { s in
            if s.refreshing { return false }
            s.refreshing = true
            return true
        }
    }

    private func runRefresh(_ accounts: [ClaudeCLIAccount], timeZone: TimeZone,
                            now: @Sendable () -> Date = Date.init) async {
        for account in accounts {  // sequential: one `claude` probe at a time
            let started = now()
            var parsed: ProviderSection?
            // Default login: blank value strips any inherited CLAUDE_CONFIG_DIR (see SubprocessRunner).
            let env = ["CLAUDE_CONFIG_DIR": account.configDir ?? ""]
            if let result = try? await runner(Self.arguments, env), !result.timedOut, result.terminationStatus == 0,
               let section = try? MultiProviderParser.parse(result.stdout, provider: .claude, now: started, timeZone: timeZone),
               section.failureText == nil, !section.windows.isEmpty {
                parsed = section
            }
            state.withLock { s in
                var entry = s.entries[Self.key(account)] ?? Entry()
                entry.attemptedAt = started
                if let parsed { entry.section = parsed; entry.fetchedAt = started }
                s.entries[Self.key(account)] = entry
            }
        }
        state.withLock { $0.refreshing = false }
    }

    private static func build(accounts: [ClaudeCLIAccount], entries: [String: Entry], now: Date,
                              refreshInterval: TimeInterval, maxCacheAge: TimeInterval, salt: Data?) -> Result? {
        var combined = ProviderSection(provider: .claude, windows: [], stats: [], failureText: nil)
        var anyValue = false
        var anyCached = false
        for (index, account) in accounts.enumerated() {
            let id = salt.map { account.accountID(salt: $0) } ?? account.accountID()
            let entry = entries[key(account)]
            let age = entry?.fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard let cached = entry?.section, age < maxCacheAge else {
                let text = entry?.attemptedAt == nil ? "取得中…（\(account.displayDir)）" : "取得失敗（\(account.displayDir)）"
                combined.accounts.append(ProviderAccount(index: index, failureText: text, id: id))
                continue
            }
            anyValue = true
            let lastAttemptFailed = (entry?.attemptedAt).map { $0 > entry!.fetchedAt! } ?? false
            let fromCache = age >= refreshInterval * 2 || lastAttemptFailed
            anyCached = anyCached || fromCache
            combined.windows += cached.windows.map { var w = $0; w.accountIndex = index; return w }
            combined.stats += cached.stats.filter { $0.title != sourceTitle }.map { var s = $0; s.accountIndex = index; return s }
            combined.stats.append(ProviderStat(title: sourceTitle,
                                               valueText: "\(fromCache ? cachedSource : cliSource) · \(account.label): \(account.displayDir)",
                                               accountIndex: index))
            combined.accounts.append(ProviderAccount(index: index, id: id))
        }
        guard anyValue else { return nil }
        combined.accountInventoryComplete = true
        return Result(section: combined, fromCache: anyCached)
    }

    /// CLI first; the CLIProxyAPI section only when no CLI account has a usable value.
    static func merge(cli result: Result?, proxy: ProviderSection?) -> ProviderSection? {
        if let result {
            var cli = result.section
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
