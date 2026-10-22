import Foundation

@MainActor
final class MultiUsageStore: ObservableObject {
    @Published private(set) var snapshot: MultiUsageSnapshot = .placeholder
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var opacityHUDPercent: Int?

    static let refreshInterval: TimeInterval = 60

    private enum DataSource {
        case live(service: MultiUsageService, publisher: UsageSnapshotPublisher?)
        case demo(snapshot: MultiUsageSnapshot)
    }

    private let dataSource: DataSource
    private var refreshTask: Task<Void, Never>?
    private var opacityHUDTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(service: MultiUsageService = MultiUsageService(), snapshotURLs: [URL]? = nil) {
        do {
            let publisher = try UsageSnapshotPublisher(urls: snapshotURLs ?? MultiAppPaths.defaultSnapshotURLs())
            dataSource = .live(service: service, publisher: publisher)
        } catch {
            dataSource = .live(service: service, publisher: nil)
            errorMessage = "Local snapshot publisher unavailable: \(error.localizedDescription)"
        }
    }

    /// A closed fixture-only path: no provider service or snapshot publisher is
    /// constructed, so demo refreshes cannot access credentials or publish data.
    init(demoSnapshot: MultiUsageSnapshot) {
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
                let snapshot = await service.fetchAll()
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
        self.snapshot = snapshot
        expiryTask?.cancel()
        expiryTask = nil
        let now = Date()
        if let resetAt = snapshot.sections.flatMap({ $0.claudeBlocks.values })
            .filter({ $0.isActive(at: now) }).map(\.resetAt).min() {
            expiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, resetAt.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled, let self else { return }
                // Update both the rings and the hover-card snapshot subscription
                // immediately, even if a provider fetch is already in flight.
                let now = Date()
                let sections = self.snapshot.sections.map { section in
                    var section = section
                    section.claudeBlocks = section.claudeBlocks.filter { $0.value.isActive(at: now) }
                    return section
                }
                self.snapshot = MultiUsageSnapshot(sections: sections, codexSnapshot: self.snapshot.codexSnapshot,
                                                   updatedAt: self.snapshot.updatedAt)
                self.refresh()
            }
        }
        if let codexSnapshot = snapshot.codexSnapshot {
            publish(codexSnapshot)
        }
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
