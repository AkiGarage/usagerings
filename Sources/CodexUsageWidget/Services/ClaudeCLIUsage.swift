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

    typealias Runner = @Sendable (_ arguments: [String], _ environment: [String: String]?) async throws
        -> CodexUsageService.CommandResult
    /// Reset grants cached by Claude Desktop for the organization of this config dir, or nil.
    typealias DesktopResets = @Sendable (_ configDir: String?, _ now: Date) -> ClaudeDesktopResetCache.Reading?

    private struct Entry {
        var section: ProviderSection?
        var fetchedAt: Date?
        var attemptedAt: Date?
        /// Identity CodexBar reported for this folder (salted digest only).
        var sourceID: AccountID?
        var maskedEmail: String?
        var failureReason: UsageFailureReason?
        var failureMessage: String?
        var grants: ClaudeResetGrantsOutcome?
        var grantsFetchedAt: Date?
        /// Grants Claude Desktop cached for this login's organization; replaced (never kept) each cycle.
        var desktopResets: ClaudeDesktopResetCache.Reading?
        /// Newest Desktop observation adopted for this folder's organization. A later read for the
        /// same organization dated before it (the newer entry was evicted, leaving an older variant)
        /// is refused, so tickets a newer response already spent cannot come back. A different
        /// organization (the folder was logged into another account) starts its own mark.
        var desktopHighWater: (organization: String, at: Date)?
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var grantsRetryAt: [String: Date] = [:]
        var refreshing = false
        /// Bumped when the account settings change; results of older runs are dropped.
        var generation = 0
        var accountsSignature: [String]?
        var task: Task<Void, Never>?
    }

    private let runner: Runner
    private let refreshInterval: TimeInterval
    private let maxCacheAge: TimeInterval
    private let failureLog: FetchFailureLog?
    private let grantsClient: ClaudeResetGrantsClient?
    private let desktopResets: DesktopResets?
    private let state = OSAllocatedUnfairLock(initialState: State())

    static let grantsRefreshInterval: TimeInterval = 900

    init(runner: @escaping Runner, refreshInterval: TimeInterval = 120, maxCacheAge: TimeInterval = 600,
         failureLog: FetchFailureLog? = nil, grantsClient: ClaudeResetGrantsClient? = nil,
         desktopResets: DesktopResets? = nil) {
        self.runner = runner
        self.desktopResets = desktopResets
        self.refreshInterval = refreshInterval
        self.maxCacheAge = maxCacheAge
        self.failureLog = failureLog
        self.grantsClient = grantsClient
    }

    static func live(cliPath: String, timeout: TimeInterval = 60) -> ClaudeCLIUsage {
        ClaudeCLIUsage(runner: { arguments, environment in
            try await SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath), timeout: timeout,
                                       environment: environment).run(arguments)
        }, failureLog: .live(), grantsClient: .live(), desktopResets: liveDesktopResets)
    }

    static let liveDesktopResets: DesktopResets = { configDir, now in
        guard let organization = ClaudeDesktopResetCache.organization(configDir: configDir) else { return nil }
        return ClaudeDesktopResetCache().reading(organization: organization, now: now)
    }

    struct Result {
        var section: ProviderSection
        /// Every account's value is from this refresh cycle (none older than the interval).
        var fromCache: Bool
        var maskedEmails: [Int: String] = [:]
    }

    /// Prior value is shown as 前回値 once it is older than this (one interval plus a sequential probe slack).
    var staleAge: TimeInterval { refreshInterval * 1.75 }

    private static func key(_ account: ClaudeCLIAccount) -> String { account.configDir ?? "" }

    /// Never waits. Returns nil until at least one account has a usable value.
    func section(accounts: [ClaudeCLIAccount], now: Date, timeZone: TimeZone, salt: Data? = nil) -> Result? {
        guard !accounts.isEmpty else { return nil }
        // One lock: settings check, due list, claim and task hand-off are atomic, so an old queue
        // can never start under a new generation and the stored task is always cancellable.
        let signature = Self.signature(accounts), keys = Set(accounts.map(Self.key))
        let interval = refreshInterval
        let (entries, old) = state.withLock { s -> ([String: Entry], Task<Void, Never>?) in
            let old = Self.rotate(&s, signature: signature, keys: keys)
            let due = accounts.filter { now.timeIntervalSince(s.entries[Self.key($0)]?.attemptedAt ?? .distantPast) >= interval }
            if !due.isEmpty, !s.refreshing {
                s.refreshing = true
                let generation = s.generation
                s.task = Task.detached { [self] in await self.runRefresh(due, timeZone: timeZone, generation: generation) }
            }
            return (s.entries, old)
        }
        old?.cancel()
        return Self.build(accounts: accounts, entries: entries, now: now,
                          staleAge: staleAge, maxCacheAge: maxCacheAge, salt: salt)
    }

    /// Test hook: refresh the given accounts sequentially and wait.
    func refreshNow(_ accounts: [ClaudeCLIAccount], timeZone: TimeZone, now: @escaping @Sendable () -> Date = Date.init) async {
        resetIfAccountsChanged(accounts)
        guard let generation = startRefreshIfIdle() else { return }
        await runRefresh(accounts, timeZone: timeZone, generation: generation, now: now)
    }

    /// A settings change cancels the running queue and drops values of removed folders,
    /// so the next call starts a fresh queue for the new list.
    private static func signature(_ accounts: [ClaudeCLIAccount]) -> [String] {
        accounts.map { "\($0.label)\u{0}\(Self.key($0))" }
    }

    /// Under the lock: on a changed account list bump the generation, drop removed folders and
    /// hand back the old task to cancel.
    private static func rotate(_ s: inout State, signature: [String], keys: Set<String>) -> Task<Void, Never>? {
        defer { s.accountsSignature = signature }
        guard let previous = s.accountsSignature, previous != signature else { return nil }
        s.generation += 1
        s.refreshing = false
        s.entries = s.entries.filter { keys.contains($0.key) }
        let task = s.task
        s.task = nil
        return task
    }

    private func resetIfAccountsChanged(_ accounts: [ClaudeCLIAccount]) {
        let signature = Self.signature(accounts), keys = Set(accounts.map(Self.key))
        state.withLock { Self.rotate(&$0, signature: signature, keys: keys) }?.cancel()
    }

    private func startRefreshIfIdle() -> Int? {
        state.withLock { s in
            if s.refreshing { return nil }
            s.refreshing = true
            return s.generation
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation == generation } }

    /// Identity CodexBar reported (account id / email digest), never the slot fallback.
    static func reportedID(_ stdout: Data) -> AccountID? {
        guard let objects = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]],
              let entry = objects.first(where: { ($0["provider"] as? String).map { $0 == "claude" } ?? true }) else { return nil }
        return AccountID.codexBar(entry, provider: .claude)
    }

    static func maskedEmail(_ stdout: Data) -> String? {
        guard let objects = try? JSONSerialization.jsonObject(with: stdout) as? [[String: Any]] else { return nil }
        for entry in objects where (entry["provider"] as? String).map({ $0 == "claude" }) ?? true {
            let usage = entry["usage"] as? [String: Any] ?? [:]
            let identity = usage["identity"] as? [String: Any] ?? [:]
            let account = entry["account"] as? [String: Any] ?? [:]
            for object in [identity, usage, account] {
                for key in ["accountEmail", "email"] {
                    if let value = object[key] as? String, value.contains("@") {
                        return UsageText.mask(value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }
        return nil
    }

    private func runRefresh(_ accounts: [ClaudeCLIAccount], timeZone: TimeZone, generation: Int,
                            now: @Sendable () -> Date = Date.init) async {
        for account in accounts {  // sequential: one `claude` probe at a time
            guard !Task.isCancelled, isCurrent(generation) else { return }
            let started = now()
            var parsed: ProviderSection?
            var masked: String?
            var reported: AccountID?
            var failure: (reason: UsageFailureReason, exitCode: Int32?, message: String)?
            // Default login: blank value strips any inherited CLAUDE_CONFIG_DIR (see SubprocessRunner).
            let env = ["CLAUDE_CONFIG_DIR": account.configDir ?? ""]
            do {
                let result = try await runner(Self.arguments, env)
                if result.timedOut {
                    failure = (.timeout, nil, "CodexBarCLI timed out")
                } else if result.terminationStatus != 0 {
                    let error = CodexUsageError.commandFailure(
                        exitCode: result.terminationStatus, stdout: result.stdout, stderr: result.stderr, provider: .claude)
                    failure = (MultiUsageService.isLogout(stdout: result.stdout, stderr: result.stderr) ? .logout : .providerError,
                               result.terminationStatus, error.localizedDescription)
                } else if let section = try? MultiProviderParser.parse(result.stdout, provider: .claude, now: started, timeZone: timeZone),
                          section.failureText == nil, !section.windows.isEmpty {
                    parsed = section
                    masked = Self.maskedEmail(result.stdout)
                    reported = Self.reportedID(result.stdout)
                } else {
                    failure = (.providerError, nil, "Claude usage unreadable")
                }
            } catch {
                failure = (MultiUsageService.failureReason(for: error), nil, error.localizedDescription)
            }
            if let failure {
                failureLog?.record(provider: "claude-cli(\(account.label))", reason: failure.reason,
                                   exitCode: failure.exitCode, message: failure.message, at: started)
            }
            let parsedValue = parsed, maskedValue = masked, reportedValue = reported
            let failureValue = failure
            let current = state.withLock { s -> Bool in
                guard s.generation == generation else { return false }
                var entry = s.entries[Self.key(account)] ?? Entry()
                entry.attemptedAt = started
                if let parsedValue {
                    if entry.sourceID != reportedValue { entry.grants = nil }
                    entry.section = parsedValue; entry.fetchedAt = started
                    entry.sourceID = reportedValue
                    entry.maskedEmail = maskedValue
                    entry.failureReason = nil
                    entry.failureMessage = nil
                } else if let failureValue {
                    entry.failureReason = failureValue.reason
                    entry.failureMessage = failureValue.message
                    if failureValue.reason == .logout {
                        entry.grants = nil
                        entry.section = nil
                        entry.fetchedAt = nil
                    }
                }
                s.entries[Self.key(account)] = entry
                return true
            }
            guard current else { return }
            if let desktopResets {
                // Local and bounded (at most two cache files), so read every cycle. The result
                // replaces the last one, nil included: a vanished entry must not leave old tickets up.
                let reading = failureValue?.reason == .logout ? nil : desktopResets(account.configDir, now())
                let stored = state.withLock { s -> Bool in
                    guard s.generation == generation else { return false }
                    var entry = s.entries[Self.key(account)] ?? Entry()
                    let floor = reading.flatMap { reading in
                        entry.desktopHighWater.flatMap { $0.organization == reading.organization ? $0.at : nil }
                    } ?? .distantPast
                    if let reading, reading.observedAt >= floor {
                        entry.desktopResets = reading
                        entry.desktopHighWater = (reading.organization, reading.observedAt)
                    } else {
                        entry.desktopResets = nil
                        if failureValue?.reason == .logout { entry.desktopHighWater = nil }
                    }
                    s.entries[Self.key(account)] = entry
                    return true
                }
                guard stored else { return }
            }
            guard failureValue?.reason != .logout, let grantsClient else { continue }
            let grantsStarted = now()
            let grantsDue = state.withLock { s -> Bool in
                guard s.generation == generation else { return false }
                let key = Self.key(account)
                guard grantsStarted >= (s.grantsRetryAt[key] ?? .distantPast) else { return false }
                s.grantsRetryAt[key] = grantsStarted.addingTimeInterval(Self.grantsRefreshInterval)
                return true
            }
            guard grantsDue else { continue }
            let grants = await grantsClient.fetch(configDir: account.configDir)
            let grantsStored = state.withLock { s -> Bool in
                if case .rateLimited(let retryAfter) = grants {
                    let key = Self.key(account)
                    let deadline = now().addingTimeInterval(retryAfter)
                    s.grantsRetryAt[key] = max(s.grantsRetryAt[key] ?? .distantPast, deadline)
                }
                guard s.generation == generation else { return false }
                var entry = s.entries[Self.key(account)] ?? Entry()
                entry.grants = grants
                entry.grantsFetchedAt = grantsStarted
                s.entries[Self.key(account)] = entry
                return true
            }
            guard grantsStored else { return }
        }
        state.withLock { s in
            guard s.generation == generation else { return }
            s.refreshing = false
            s.task = nil
        }
    }

    private static func build(accounts: [ClaudeCLIAccount], entries: [String: Entry], now: Date,
                              staleAge: TimeInterval, maxCacheAge: TimeInterval, salt: Data?) -> Result? {
        var combined = ProviderSection(provider: .claude, windows: [], stats: [], failureText: nil)
        var anyValue = false
        var anyCached = false
        var maskedEmails: [Int: String] = [:]
        for (index, account) in accounts.enumerated() {
            let entry = entries[key(account)]
            let id = (salt.map { account.accountID(salt: $0) } ?? account.accountID()).merging(entry?.sourceID)
            if let preferred = preferredGrants(entry, now: now) {
                combined.stats += ClaudeResetGrantsClient.stats(
                    for: preferred.0, accountIndex: index, now: now, calendar: RingResetFormat.tokyoCalendar,
                    desktopObservedAt: preferred.1
                )
            }
            let age = entry?.fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard let cached = entry?.section, age < maxCacheAge else {
                let neverAttempted = entry?.attemptedAt == nil
                let text = neverAttempted ? "取得中…（\(account.displayDir)）" : "取得失敗（\(account.displayDir)）"
                combined.accounts.append(ProviderAccount(
                    index: index,
                    failureText: text,
                    id: id,
                    failureReason: neverAttempted ? nil : (entry?.failureReason ?? .providerError)
                ))
                continue
            }
            anyValue = true
            let lastAttemptFailed = (entry?.attemptedAt).map { $0 > entry!.fetchedAt! } ?? false
            let fromCache = age >= staleAge || lastAttemptFailed
            anyCached = anyCached || fromCache
            combined.windows += cached.windows.map { var w = $0; w.accountIndex = index; if w.observedAt == nil { w.observedAt = entry?.fetchedAt }; return w }
            combined.stats += cached.stats.filter { $0.title != sourceTitle }.map { var s = $0; s.accountIndex = index; return s }
            combined.stats.append(ProviderStat(title: sourceTitle,
                                               valueText: "\(fromCache ? cachedSource : cliSource) · \(account.label): \(account.displayDir)",
                                               accountIndex: index))
            var item = ProviderAccount(index: index, id: id)
            if fromCache, let fetched = entry?.fetchedAt {
                item.isStale = true
                item.failureText = previousValueText(fetched, now: now)
            }
            combined.accounts.append(item)
            if let masked = entry?.maskedEmail { maskedEmails[index] = masked }
        }
        guard anyValue || !combined.stats.isEmpty else { return nil }
        combined.accountInventoryComplete = true
        return Result(section: combined, fromCache: anyCached, maskedEmails: maskedEmails)
    }

    /// How long a Desktop answer of "no tickets" (null, ineligible, spent, malformed) may stand in
    /// for the current OAuth result. Desktop refreshes grants only while Settings → Usage is open,
    /// so an older negative is an old observation, not a current zero.
    static let desktopNegativeFreshness: TimeInterval = 30 * 60

    /// Desktop's cached grants win unless the OAuth endpoint itself answered (eligible) more recently
    /// (today it answers "surface" ineligible, so in practice Desktop is the only real source).
    /// Held tickets are shown at any age, dated; a Desktop negative only when fresh, otherwise the
    /// current OAuth outcome (e.g. the rate-limit note) stays. Second element: Desktop observation time.
    private static func preferredGrants(_ entry: Entry?, now: Date) -> (ClaudeResetGrantsOutcome, Date?)? {
        guard let entry else { return nil }
        let oauth = entry.grants.map { ($0, Date?.none) }
        guard let desktop = entry.desktopResets else { return oauth }
        // Any eligible OAuth answer, empty included, is a newer statement about the same tickets.
        if case .loaded? = entry.grants, let fetched = entry.grantsFetchedAt, fetched > desktop.observedAt {
            return oauth
        }
        if case .loaded(let grants) = desktop.outcome,
           !ClaudeResetGrantsClient.heldGrants(grants, now: now).isEmpty {
            return (desktop.outcome, desktop.observedAt)
        }
        guard now.timeIntervalSince(desktop.observedAt) < desktopNegativeFreshness else { return oauth }
        return (desktop.outcome, desktop.observedAt)
    }

    static func previousValueText(_ fetched: Date, now: Date) -> String {
        "前回値（\(UsageDurationFormat.timestamp(fetched, now: now, calendar: RingResetFormat.tokyoCalendar)) JST 取得）"
    }


}
