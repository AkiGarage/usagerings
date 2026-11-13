import AppKit
import Foundation

/// A reset one provider announced (rounded up to the whole second).
struct ResetKey: Hashable {
    enum Account: Hashable { case identified(AccountID), index(Int) }
    let provider: ProviderID
    let at: Date
    var account: Account = .index(0)
}

/// Plans exactly one targeted refresh per announced reset. Pure, for tests.
enum ResetRefreshPlanner {
    struct Attempts: Equatable { var count = 0 }
    static let grace: TimeInterval = 20

    static func fireTime(_ key: ResetKey, _ done: Attempts, now: Date) -> Date? {
        guard done.count == 0 else { return nil }
        return max(key.at.addingTimeInterval(grace), now)
    }

    /// Earliest fire across every pending reset; `attempts` holds every reset still in play.
    static func next(attempts: [ResetKey: Attempts], now: Date) -> Date? {
        attempts.compactMap { fireTime($0.key, $0.value, now: now) }.min()
    }

    /// Resets due at `now`: one targeted refresh serves all of them.
    static func due(attempts: [ResetKey: Attempts], now: Date) -> Set<ResetKey> {
        Set(attempts.filter { (fireTime($0.key, $0.value, now: now) ?? .distantFuture) <= now }.keys)
    }

    static func recordFire(_ keys: Set<ResetKey>, attempts: [ResetKey: Attempts], now: Date) -> [ResetKey: Attempts] {
        var attempts = attempts
        for key in keys {
            var done = attempts[key] ?? Attempts()
            done.count += 1
            attempts[key] = done
        }
        return attempts
    }

    static func resets(in section: ProviderSection) -> Set<ResetKey> {
        Set(section.windows.compactMap { window in
            window.resetAt.map {
                ResetKey(provider: section.provider, at: Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.up)),
                         account: accountKey(section.accounts.first { $0.index == (window.accountIndex ?? 0) },
                                             index: window.accountIndex ?? 0))
            }
        })
    }

    private static func accountKey(_ account: ProviderAccount?, index: Int) -> ResetKey.Account {
        account?.id.map { .identified($0) } ?? .index(index)
    }

    /// A reading that can settle a reset: fetched now, nothing failed or retained.
    static func isConclusive(_ section: ProviderSection) -> Bool {
        section.failureText == nil && section.failureReason == nil && !section.isStale && !section.windows.isEmpty
            && !section.accounts.contains { $0.failureText != nil || $0.failureReason != nil || $0.isStale }
    }

    /// Fresh accounts replace their own deadlines; failed accounts keep known ones.
    /// A deadline future at fetch start remains eligible if the fetch spans its reset.
    static func track(_ attempts: [ResetKey: Attempts], sections: [ProviderSection], fetched: Set<ProviderID>,
                      skipped: Set<ProviderID>, now: Date, knownAt: Date? = nil) -> [ResetKey: Attempts] {
        var attempts = attempts.filter { !skipped.contains($0.key.provider) }
        for section in sections where fetched.contains(section.provider) && !skipped.contains(section.provider) {
            guard !section.isStale else { continue }
            if section.accounts.isEmpty, section.failureText != nil || section.failureReason != nil { continue }
            let seen = resets(in: section)
            let healthy: Set<ResetKey.Account>
            if section.accounts.isEmpty {
                healthy = Set(seen.map(\.account))
            } else {
                healthy = Set(section.accounts.filter {
                    $0.failureText == nil && $0.failureReason == nil && !$0.isStale
                }.map { accountKey($0, index: $0.index) })
            }
            let complete = isConclusive(section)
            attempts = attempts.filter {
                $0.key.provider != section.provider || seen.contains($0.key)
                    || (!complete && !healthy.contains($0.key.account))
            }
            for key in seen where healthy.contains(key.account) && key.at > (knownAt ?? now) && attempts[key] == nil {
                attempts[key] = Attempts()
            }
        }
        return attempts
    }
}

@MainActor
final class MultiUsageStore: ObservableObject {
    @Published private(set) var snapshot: MultiUsageSnapshot = .placeholder
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var opacityHUDPercent: Int?
    /// Current Claude account choice and its plain-Japanese reason (nil when not applicable).
    @Published private(set) var claudeChoice: ClaudeAccountPolicy.Decision?
    private var rawSnapshot: MultiUsageSnapshot?
    private var lastClaudeDecision: ClaudeAccountPolicy.Decision?
    /// Injected for tests; nil disables publishing the decision file.
    var claudeChoiceURL: URL? = nil
    var claudeProfileMasks: () -> [String: String] = { ClaudeAccountChoice.localProfileMasks() }

    static let refreshInterval: TimeInterval = 60

    private enum DataSource {
        case live(service: MultiUsageService, publisher: UsageSnapshotPublisher?)
        case demo(snapshot: MultiUsageSnapshot)
    }

    private let dataSource: DataSource
    private let preferences: PanelPreferences?
    private var cloudSender: CloudSnapshotSender?
    private var refreshTask: Task<Void, Never>?
    private var opacityHUDTask: Task<Void, Never>?
    /// Per-instance so tests can shorten the HUD lifetime without affecting other stores.
    var opacityHUDDuration: TimeInterval = 1.2
    private var expiryTask: Task<Void, Never>?
    private var cancelResetTimer: (() -> Void)?
    private var resetTimerGeneration: UInt = 0
    private var resetAttempts: [ResetKey: ResetRefreshPlanner.Attempts] = [:]
    /// Providers the in-flight fetch covers (all when it is a regular refresh).
    private var inFlightTargets: Set<ProviderID> = []
    private var inFlightStartedAt = Date.distantPast
    private var inFlightSkipped: Set<ProviderID> = []
    private var queuedFullRefresh = false
    private var stopGeneration: UInt = 0
    private var resetSchedulingEnabled = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// Injected for tests.
    var resetClock: () -> Date = { Date() }
    /// Returns cancellation; a generation check also rejects callbacks already enqueued.
    var resetScheduler: (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void) = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(500))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }
    /// Gemini app quota: read from Aki's open Chrome usage tab on its own activity schedule,
    /// never by the regular or reset refresh (those make no Gemini request at all).
    private(set) var geminiMonitor: GeminiAppUsageMonitor?

    init(service: MultiUsageService = MultiUsageService(), snapshotURLs: [URL]? = nil,
         preferences: PanelPreferences? = nil, cloudTransport: CloudSnapshotTransport = CloudKitSnapshotTransport()) {
        self.preferences = preferences
        if let preferences {
            cloudSender = CloudSnapshotSender(defaults: preferences.defaults, transport: cloudTransport, enabled: preferences.cloudSyncEnabled)
        }
        if preferences != nil, NSClassFromString("XCTestCase") == nil { claudeChoiceURL = ClaudeAccountChoice.fileURL() }
        do {
            let publisher = try UsageSnapshotPublisher(urls: snapshotURLs ?? MultiAppPaths.defaultSnapshotURLs())
            dataSource = .live(service: service, publisher: publisher)
        } catch {
            dataSource = .live(service: service, publisher: nil)
            errorMessage = "Local snapshot publisher unavailable: \(error.localizedDescription)"
        }
        snapshot = visible(snapshot)
    }

    /// A closed fixture-only path: no provider service or snapshot publisher is
    /// constructed, so demo refreshes cannot access credentials or publish data.
    init(demoSnapshot: MultiUsageSnapshot) {
        preferences = nil
        self.snapshot = demoSnapshot
        dataSource = .demo(snapshot: demoSnapshot)
    }

    var snapshotPublishingIsEnabled: Bool {
        guard case let .live(_, publisher) = dataSource else { return false }
        return publisher != nil
    }

    func start() {
        resetSchedulingEnabled = true
        if geminiMonitor == nil, case .live = dataSource, preferences != nil, NSClassFromString("XCTestCase") == nil {
            let monitor = GeminiAppUsageMonitor()
            // Hidden in "サービス表示" = not fetched, same as every other provider.
            monitor.isVisible = { [weak preferences] in preferences?.isProviderVisible(.gemini) ?? false }
            attachGeminiMonitor(monitor)
        }
        geminiMonitor?.start()
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval), tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
        observeWakeAndClock()
    }

    /// Sleep/wake and clock changes invalidate sleeping timers: re-plan from wall time.
    private func observeWakeAndClock() {
        guard wakeObservers.isEmpty else { return }
        let replan: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.scheduleResetRefresh() }
        }
        wakeObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: replan),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: replan),
        ]
    }

    func attachGeminiMonitor(_ monitor: GeminiAppUsageMonitor) {
        geminiMonitor = monitor
        monitor.onChange = { [weak self] section in self?.applyGemini(section) }
    }

    /// Swap in the Gemini section without touching any other provider.
    func applyGemini(_ section: ProviderSection) {
        guard let raw = rawSnapshot else { return }
        let merged = Self.withGemini(section, in: raw)
        rawSnapshot = merged
        snapshot = visible(merged)
    }

    static func withGemini(_ section: ProviderSection?, in snapshot: MultiUsageSnapshot) -> MultiUsageSnapshot {
        guard let section else { return snapshot }
        let sections = snapshot.sections.filter { $0.provider != .gemini } + [section]
        return MultiUsageSnapshot(sections: MultiUsageSnapshot.ordered(sections), codexSnapshot: snapshot.codexSnapshot,
                                  updatedAt: snapshot.updatedAt, hiddenProviders: snapshot.hiddenProviders)
    }

    func stop() {
        stopGeneration &+= 1
        queuedFullRefresh = false
        // Keep the in-flight slot occupied until its CLI fetch actually finishes.
        geminiMonitor?.stop()
        refreshTask?.cancel()
        refreshTask = nil
        opacityHUDTask?.cancel()
        opacityHUDTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        resetSchedulingEnabled = false
        resetTimerGeneration &+= 1
        cancelResetTimer?()
        cancelResetTimer = nil
        for observer in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        wakeObservers = []
    }

    /// One targeted refresh just after the earliest announced reset (no tighter global polling).
    /// A reset that comes due while a fetch is in flight is not consumed: its attempt is
    /// recorded only when a refresh actually starts, so apply() re-plans it at once
    /// unless that in-flight result already settled it.
    func scheduleResetRefresh() {
        resetTimerGeneration &+= 1
        cancelResetTimer?()
        cancelResetTimer = nil
        guard resetSchedulingEnabled, !isRefreshing, case .live = dataSource,
              let fire = ResetRefreshPlanner.next(attempts: resetAttempts, now: resetClock()) else { return }
        let generation = resetTimerGeneration
        cancelResetTimer = resetScheduler(max(0, fire.timeIntervalSince(resetClock()))) { [weak self] in
            guard let self, self.resetSchedulingEnabled, generation == self.resetTimerGeneration else { return }
            self.resetTimerGeneration &+= 1
            self.cancelResetTimer = nil
            guard !self.isRefreshing else { return } // apply() re-plans without consuming the reset
            let now = self.resetClock()
            let due = ResetRefreshPlanner.due(attempts: self.resetAttempts, now: now)
            guard !due.isEmpty else { self.scheduleResetRefresh(); return }
            self.resetAttempts = ResetRefreshPlanner.recordFire(due, attempts: self.resetAttempts, now: now)
            self.refresh(only: Set(due.map(\.provider)))
        }
    }

    /// `only`: fetch just these providers and keep every other section as it is,
    /// so a reset of one service costs no request to the others (Antigravity included).
    func refresh(only targets: Set<ProviderID>? = nil) {
        guard !isRefreshing else {
            if targets == nil { queuedFullRefresh = true }
            return
        }
        switch dataSource {
        case let .demo(demoSnapshot):
            snapshot = demoSnapshot
            errorMessage = nil
            isRefreshing = false
            return
        case let .live(service, _):
            isRefreshing = true
            inFlightStartedAt = resetClock()
            var skip = preferences?.providersToSkip() ?? []
            if preferences?.cloudSyncEnabled == true, preferences?.cloudSyncStopping == false {
                // iPhone sync needs Codex, Claude and Grok even when hidden on the Mac.
                skip.subtract([.codex, .claude, .grok])
            }
            let others = targets.map { Set(ProviderID.allCases).subtracting($0) } ?? []
            inFlightTargets = Set(ProviderID.allCases).subtracting(skip).subtracting(others)
            inFlightSkipped = skip
            let disabled = skip.union(others)
            let cloudDataComplete = disabled.isDisjoint(with: [.codex, .claude, .grok])
            let generation = stopGeneration
            Task {
                let snapshot = await service.fetchAll(disabled: disabled)
                guard generation == self.stopGeneration else {
                    // Only a full request made after stop() may restart the store.
                    self.isRefreshing = false
                    self.refreshIfQueued()
                    return
                }
                self.apply(snapshot, partial: targets != nil, cloudDataComplete: cloudDataComplete)
            }
        }
    }

    func showOpacityHUD(percent: Int) {
        opacityHUDPercent = percent
        opacityHUDTask?.cancel()
        let duration = opacityHUDDuration
        opacityHUDTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            // This task inherits MainActor: checking cancellation and clearing are atomic.
            guard !Task.isCancelled else { return }
            self?.opacityHUDPercent = nil
            self?.opacityHUDTask = nil
        }
    }

    private func apply(_ fetched: MultiUsageSnapshot, partial: Bool = false, cloudDataComplete: Bool = true) {
        let targets = inFlightTargets
        var snapshot = fetched
        if partial, let previous = rawSnapshot {
            // Untouched providers keep their current sections and Codex snapshot.
            let sections = previous.sections.filter { !targets.contains($0.provider) }
                + fetched.sections.filter { targets.contains($0.provider) }
            snapshot = MultiUsageSnapshot(sections: MultiUsageSnapshot.ordered(sections),
                                          codexSnapshot: targets.contains(.codex) ? fetched.codexSnapshot : previous.codexSnapshot,
                                          updatedAt: fetched.updatedAt, hiddenProviders: previous.hiddenProviders)
        }
        snapshot = Self.withGemini(geminiMonitor?.section ?? rawSnapshot?.sections.first { $0.provider == .gemini }, in: snapshot)
        preferences?.reconcileAccounts(in: snapshot)
        preferences?.reconcileProviders(in: snapshot)
        var displaySnapshot = Self.retainingStaleValues(in: snapshot, previous: rawSnapshot, now: Date())
        // Gemini keeps its own observation times and stale marking.
        displaySnapshot = Self.withGemini(snapshot.sections.first { $0.provider == .gemini }, in: displaySnapshot)
        rawSnapshot = displaySnapshot
        if targets.contains(.claude) { updateClaudeChoice(from: snapshot, now: Date()) }
        self.snapshot = visible(displaySnapshot)
        if preferences?.cloudSyncEnabled == true, preferences?.cloudSyncStopping == false {
            // The sender gets the fresh observation (not retained stale values).
            if cloudDataComplete { cloudSender?.offer(snapshot) } else if !partial { refresh() }
        }
        expiryTask?.cancel()
        expiryTask = nil
        scheduleExpiry()
        if targets.contains(.codex), let codexSnapshot = snapshot.codexSnapshot {
            publish(codexSnapshot)
        }
        resetAttempts = ResetRefreshPlanner.track(resetAttempts, sections: fetched.sections, fetched: targets,
                                                  skipped: inFlightSkipped.union([.gemini]), now: resetClock(), knownAt: inFlightStartedAt)
        isRefreshing = false
        refreshIfQueued()
        scheduleResetRefresh()
    }

    private func refreshIfQueued() {
        guard queuedFullRefresh else { return }
        queuedFullRefresh = false
        refresh()
    }

    /// Keep display data only; decisions and the published Codex snapshot use the fresh result.
    static func retainingStaleValues(in fresh: MultiUsageSnapshot, previous: MultiUsageSnapshot?, now: Date) -> MultiUsageSnapshot {
        let sections = fresh.sections.map { section -> ProviderSection in
            var result = section
            // Cache entries carry their own original observation time.
            result.windows = result.windows.compactMap { window in
                var window = window
                let accountStale = section.accounts.first { $0.index == (window.accountIndex ?? 0) }?.isStale ?? false
                if section.isStale || accountStale { return window.isRetainable(at: now) ? window : nil }
                if window.observedAt == nil { window.observedAt = fresh.updatedAt }
                return window
            }
            guard let old = previous?.sections.first(where: { $0.provider == section.provider }) else { return result }
            if section.windows.isEmpty, section.accounts.isEmpty, section.failureReason?.isTransient == true {
                result.windows = old.windows.filter { $0.isRetainable(at: now) }
                if !result.windows.isEmpty {
                    result.accounts = old.accounts
                    result.isStale = true
                }
                return result
            }
            for i in result.accounts.indices {
                let account = result.accounts[i]
                guard account.failureReason?.isTransient == true, let id = account.id,
                      let oldAccount = old.accounts.first(where: { $0.id == id }),
                      !result.windows.contains(where: { ($0.accountIndex ?? 0) == account.index }) else { continue }
                let retained = old.windows.filter { ($0.accountIndex ?? 0) == oldAccount.index && $0.isRetainable(at: now) }.map {
                    var window = $0
                    window.accountIndex = account.index
                    return window
                }
                result.windows += retained
                result.accounts[i].isStale = !retained.isEmpty
            }
            return result
        }
        return MultiUsageSnapshot(sections: sections, codexSnapshot: fresh.codexSnapshot,
                                  updatedAt: fresh.updatedAt, hiddenProviders: fresh.hiddenProviders)
    }

    private func scheduleExpiry() {
        guard let rawSnapshot else { return }
        let now = Date()
        let staleDeadlines = rawSnapshot.sections.flatMap { section in
            section.windows.compactMap { window -> Date? in
                let stale = section.isStale || (section.accounts.first { $0.index == (window.accountIndex ?? 0) }?.isStale ?? false)
                guard stale, let observed = window.observedAt else { return nil }
                return min(observed.addingTimeInterval(UsageLimit.staleMaxAge), window.resetAt ?? .distantFuture)
            }
        }
        let blockDeadlines = rawSnapshot.sections.flatMap { $0.claudeProfileBlocks.values }
            .filter { $0.isActive(at: now) }.map(\.resetAt)
        guard let deadline = (staleDeadlines + blockDeadlines).min() else { return }
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow + 0.01)))
            guard !Task.isCancelled, let self, let current = self.rawSnapshot else { return }
            let now = Date()
            let blockExpired = current.sections.flatMap { $0.claudeProfileBlocks.values }
                .contains { !$0.isActive(at: now) }
            let sections = current.sections.map { section -> ProviderSection in
                var section = section
                section.claudeProfileBlocks = section.claudeProfileBlocks.filter { $0.value.isActive(at: now) }
                section.windows.removeAll { window in
                    let stale = section.isStale || (section.accounts.first { $0.index == (window.accountIndex ?? 0) }?.isStale ?? false)
                    return stale && !window.isRetainable(at: now)
                }
                return section
            }
            let expired = MultiUsageSnapshot(sections: sections, codexSnapshot: current.codexSnapshot,
                                              updatedAt: current.updatedAt, hiddenProviders: current.hiddenProviders)
            self.rawSnapshot = expired
            self.snapshot = self.visible(expired)
            self.scheduleExpiry()
            if blockExpired { self.refresh() }
        }
    }

    func cloudSyncChanged(enabled: Bool) async {
        if enabled, preferences?.cloudSyncEnabled != true || preferences?.cloudSyncStopping == true { return }
        await cloudSender?.setEnabled(enabled)
        if enabled, preferences?.cloudSyncStopping == false { refresh() }
    }

    /// Re-filter after a visibility toggle; a provider turned on is fetched immediately.
    func providerVisibilityChanged(turnedOn: Bool) {
        snapshot = visible(rawSnapshot ?? .placeholder)
        if rawSnapshot != nil {
            if preferences?.isProviderVisible(.claude) == false {
                claudeChoice = nil
                if let url = claudeChoiceURL { ClaudeAccountChoice.retract(now: Date(), url: url) }
            }
        }
        if turnedOn { refresh() }
    }

    func visible(_ snapshot: MultiUsageSnapshot) -> MultiUsageSnapshot {
        guard let preferences else { return snapshot }
        let hidden = Set(ProviderID.allCases.filter { !preferences.isProviderVisible($0) })
        return MultiUsageSnapshot(sections: snapshot.sections.filter { !hidden.contains($0.provider) },
                                  codexSnapshot: snapshot.codexSnapshot, updatedAt: snapshot.updatedAt,
                                  hiddenProviders: hidden)
    }

    func updateClaudeChoice(from snapshot: MultiUsageSnapshot, now: Date) {
        guard let section = snapshot.sections.first(where: { $0.provider == .claude }),
              !section.isStale, !section.accounts.contains(where: \.isStale),
              section.accountIndices.count >= 2, preferences?.isProviderVisible(.claude) ?? true else {
            claudeChoice = nil
            if let url = claudeChoiceURL { ClaudeAccountChoice.retract(now: now, url: url) }
            return
        }
        let map = ClaudeAccountChoice.profileMap(section: section, masks: claudeProfileMasks())
        let accounts = ClaudeAccountChoice.accounts(section: section, map: map, now: now)
        let mapped = accounts.allSatisfy { ClaudeAccountChoice.profileKeys.contains($0.key) }
        let decision = ClaudeAccountPolicy.decide(accounts, previous: lastClaudeDecision, now: now,
                                                  name: { mapped ? "claude-\($0)" : "Claude \($0)" })
        lastClaudeDecision = decision
        claudeChoice = decision
        guard let url = claudeChoiceURL else { return }
        if mapped, preferences?.claudeAutoSwitch ?? false, ClaudeAccountChoice.publish(decision, now: now, url: url) { return }
        ClaudeAccountChoice.retract(now: now, url: url)
    }

    /// Called when the auto-switch setting changes; turning it off retracts the hint immediately.
    func claudeAutoSwitchChanged(enabled: Bool) {
        guard let url = claudeChoiceURL else { return }
        if enabled { refresh() } else { ClaudeAccountChoice.retract(now: Date(), url: url) }
    }

    private func publish(_ snapshot: UsageSnapshot) {
        guard case let .live(_, publisher) = dataSource, let publisher else { return }
        do {
            try publisher.publish(snapshot)
            errorMessage = nil
        } catch {
            errorMessage = "Local snapshot update failed: \(error.localizedDescription)"
        }
    }
}
