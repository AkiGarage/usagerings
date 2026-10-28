import Foundation

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
    private var refreshTask: Task<Void, Never>?
    private var opacityHUDTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(service: MultiUsageService = MultiUsageService(), snapshotURLs: [URL]? = nil,
         preferences: PanelPreferences? = nil) {
        self.preferences = preferences
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
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval), tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        opacityHUDTask?.cancel()
        opacityHUDTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        switch dataSource {
        case let .demo(demoSnapshot):
            snapshot = demoSnapshot
            errorMessage = nil
            isRefreshing = false
            return
        case let .live(service, _):
            isRefreshing = true
            Task {
                let snapshot = await service.fetchAll(disabled: preferences?.providersToSkip() ?? [])
                apply(snapshot)
            }
        }
    }

    func showOpacityHUD(percent: Int) {
        opacityHUDPercent = percent
        opacityHUDTask?.cancel()
        opacityHUDTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.opacityHUDPercent = nil
                self?.opacityHUDTask = nil
            }
        }
    }

    private func apply(_ snapshot: MultiUsageSnapshot) {
        isRefreshing = false
        preferences?.reconcileAccounts(in: snapshot)
        preferences?.reconcileProviders(in: snapshot)
        let displaySnapshot = Self.retainingStaleValues(in: snapshot, previous: rawSnapshot, now: Date())
        rawSnapshot = displaySnapshot
        updateClaudeChoice(from: snapshot, now: Date())
        self.snapshot = visible(displaySnapshot)
        expiryTask?.cancel()
        expiryTask = nil
        scheduleExpiry()
        if let codexSnapshot = snapshot.codexSnapshot {
            publish(codexSnapshot)
        }
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
