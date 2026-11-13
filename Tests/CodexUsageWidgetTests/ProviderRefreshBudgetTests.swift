import XCTest
@testable import CodexUsageWidget

@MainActor
final class ProviderRefreshBudgetTests: XCTestCase {
    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var failing = false
        let resetAt: Date?
        init(resetAt: Date? = nil) { self.resetAt = resetAt }
        func count(_ provider: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[provider, default: 0]
        }
        func run(_ args: [String]) -> CodexUsageService.CommandResult {
            lock.lock(); defer { lock.unlock() }
            let provider = args[2]
            counts[provider, default: 0] += 1
            if provider == "antigravity", failing {
                return .init(terminationStatus: 1, stdout: Data(), stderr: Data("synthetic provider failure".utf8))
            }
            let reset = resetAt.map { ",\"resetsAt\":\"\(ISO8601DateFormatter().string(from: $0))\"" } ?? ""
            let json = "[{\"provider\":\"\(provider)\",\"usage\":{\"primary\":{\"usedPercent\":20,\"windowMinutes\":300\(reset)}}}]"
            return .init(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        }
        func fail(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    }

    private func settle(_ store: MultiUsageStore) async throws {
        for _ in 0..<200 {
            if !store.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("refresh did not finish")
    }

    func testAutomaticIntervalPreservesObservationAndCheapProvidersStillFetch() async throws {
        let runner = Runner()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run, retryDelay: 0), snapshotURLs: [])
        var now = Date()
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        let original = try XCTUnwrap(store.snapshot.sections.first { $0.provider == .antigravity }?.windows.first)
        now += 899
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 1)
        XCTAssertEqual(runner.count("codex"), 2)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .antigravity }?.windows.first, original)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .antigravity }?.windows.first?.observedAt, original.observedAt)
        now += 1
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 2)
    }

    func testUserAndTargetedResetBypassBudget() async throws {
        let runner = Runner()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run), snapshotURLs: [])
        let now = Date()
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        store.refresh()
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 2)
        store.refresh(only: [.antigravity], reason: .reset)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 3)
        XCTAssertEqual(runner.count("codex"), 2)
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 3)
    }

    func testQueuedUserRefreshSurvivesLaterAutomaticRefresh() async throws {
        let runner = Runner()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run), snapshotURLs: [])
        defer { store.stop() }
        let now = Date()
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 1)

        store.refresh(reason: .automatic)
        XCTAssertTrue(store.isRefreshing)
        store.refresh(reason: .userInitiated)
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 2, "Queued user action must still bypass the budget")
        XCTAssertEqual(runner.count("codex"), 3, "Overlapping full requests coalesce into one follow-up")
    }

    func testFailuresBackOffAndSuccessRestoresNormalInterval() async throws {
        let runner = Runner()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run, retryDelay: 0), snapshotURLs: [])
        var now = Date()
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        runner.fail(true)
        now += 900
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 3, "One bounded immediate retry remains")
        XCTAssertTrue(store.snapshot.sections.first { $0.provider == .antigravity }!.isStale)
        now += 1799
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 3)
        now += 1
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 5)
        now += 3599
        runner.fail(false)
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 5)
        now += 1
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 6)
        XCTAssertFalse(store.snapshot.sections.first { $0.provider == .antigravity }!.isStale)
        now += 900
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 7)
    }

    func testDeferredValueExpiresAtResetWithoutAnotherCLIInvocation() async throws {
        var now = Date()
        let runner = Runner(resetAt: now + 600)
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run), snapshotURLs: [])
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertFalse(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        now += 601
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 1)
        XCTAssertTrue(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        store.stop()
    }

    func testExpiryTimerClearsBudgetedFreshValueWithoutPolling() async throws {
        let reset = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 1)
        let runner = Runner(resetAt: reset)
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run), snapshotURLs: [])
        defer { store.stop() }
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertFalse(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        for _ in 0..<400 {
            if store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        XCTAssertEqual(runner.count("antigravity"), 1)
    }

    func testDeferredValueExpiresAfterFiveHoursWithLongConfiguredInterval() async throws {
        let defaults = UserDefaults(suiteName: "ProviderBudgetTests-\(UUID())")!
        defaults.set(86400, forKey: "providerRefreshIntervalSeconds.antigravity")
        let preferences = PanelPreferences(defaults: defaults)
        preferences.setProviderVisible(true, for: .antigravity)
        let runner = Runner()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner.run), snapshotURLs: [], preferences: preferences)
        var now = Date()
        store.resetClock = { now }
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertFalse(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        now += 18000
        store.refresh(reason: .automatic)
        try await settle(store)
        XCTAssertEqual(runner.count("antigravity"), 1)
        XCTAssertTrue(store.snapshot.sections.first { $0.provider == .antigravity }!.windows.isEmpty)
        store.stop()
    }

    func testBackoffCapPartialFailureAndOverrides() {
        var budget = ProviderRefreshBudget(intervals: [.antigravity: 900])
        var section = ProviderSection(provider: .antigravity, windows: [], stats: [], failureText: nil,
                                      accounts: [ProviderAccount(index: 0, failureReason: .transport)])
        let now = Date()
        for _ in 0..<10 { budget.record(section, at: now) }
        XCTAssertTrue(budget.deferred(at: now + 7199, reason: .automatic).contains(.antigravity))
        XCTAssertTrue(budget.deferred(at: now + 7200, reason: .automatic).isEmpty)
        XCTAssertTrue(budget.deferred(at: now, reason: .userInitiated).isEmpty)
        XCTAssertTrue(budget.deferred(at: now, reason: .reset).isEmpty)
        section.accounts = []
        budget.record(section, at: now)
        XCTAssertTrue(budget.deferred(at: now + 900, reason: .automatic).isEmpty)
    }

    func testPreferenceValidationAndProviderConfiguration() {
        let defaults = UserDefaults(suiteName: "ProviderBudgetTests-\(UUID())")!
        defaults.set(600, forKey: "providerRefreshIntervalSeconds.antigravity")
        defaults.set(1200, forKey: "providerRefreshIntervalSeconds.grok")
        defaults.set(-1, forKey: "providerRefreshIntervalSeconds.codex")
        defaults.set("invalid", forKey: "providerRefreshIntervalSeconds.claude")
        let intervals = ProviderRefreshBudget.intervals(defaults: defaults)
        XCTAssertEqual(intervals[.antigravity], 600)
        XCTAssertEqual(intervals[.grok], 1200)
        XCTAssertNil(intervals[.codex])
        XCTAssertNil(intervals[.claude])
    }
}
