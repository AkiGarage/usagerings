import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .placeholder
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var opacityHUDPercent: Int?

    private let service: CodexUsageService
    private let publisher: UsageSnapshotPublisher?
    private var refreshTask: Task<Void, Never>?
    private var opacityHUDTask: Task<Void, Never>?
    /// Per-instance so tests can shorten the HUD lifetime without affecting other stores.
    var opacityHUDDuration: TimeInterval = 1.2

    init(service: CodexUsageService) {
        self.service = service
        do {
            publisher = try UsageSnapshotPublisher()
        } catch {
            publisher = nil
            errorMessage = "Local snapshot publisher unavailable: \(error.localizedDescription)"
        }
    }

    func start() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(5))
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
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let service = service

        Task {
            let result = await Task.detached { () -> Result<UsageSnapshot, Error> in
                Result { try service.fetch() }
            }.value
            apply(result)
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

    private func apply(_ result: Result<UsageSnapshot, Error>) {
        isRefreshing = false
        switch result {
        case let .success(snapshot):
            self.snapshot = snapshot
            errorMessage = nil
            publish(snapshot)
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private func publish(_ snapshot: UsageSnapshot) {
        guard let publisher else { return }
        do {
            try publisher.publish(snapshot)
        } catch {
            errorMessage = "Local snapshot update failed: \(error.localizedDescription)"
        }
    }
}
