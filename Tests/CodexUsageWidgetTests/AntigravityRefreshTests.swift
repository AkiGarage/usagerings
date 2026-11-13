import XCTest
@testable import CodexUsageWidget

final class AntigravityRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailureBackoffAndSuccessReset() {
        var policy = AntigravityRefreshPolicy()
        XCTAssertTrue(policy.shouldFetch(now: now, trigger: .periodic))
        for minutes in [10, 20, 40, 60, 60] {
            policy.recordAttempt(at: now)
            policy.recordResult(success: false, at: now)
            XCTAssertEqual(policy.interval, Double(minutes * 60))
            XCTAssertFalse(policy.shouldFetch(now: now.addingTimeInterval(Double(minutes * 60 - 1)), trigger: .periodic))
            XCTAssertTrue(policy.shouldFetch(now: now.addingTimeInterval(Double(minutes * 60)), trigger: .periodic))
        }
        policy.recordResult(success: true, at: now)
        XCTAssertEqual(policy.interval, 600)
        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(policy.lastSuccess, now)
    }

    func testManualAndResetBypassBackoffButRespectHardFloor() {
        var policy = AntigravityRefreshPolicy()
        policy.recordAttempt(at: now)
        for _ in 0..<4 { policy.recordResult(success: false, at: now) }
        for trigger in [AntigravityRefreshPolicy.Trigger.manual, .reset] {
            XCTAssertFalse(policy.shouldFetch(now: now.addingTimeInterval(59), trigger: trigger))
            XCTAssertTrue(policy.shouldFetch(now: now.addingTimeInterval(60), trigger: trigger))
        }
        XCTAssertFalse(policy.shouldFetch(now: now.addingTimeInterval(60), trigger: .periodic))
        XCTAssertGreaterThan(AntigravityRefreshPolicy.displayMaxAge, AntigravityRefreshPolicy.maximumInterval + 600)
    }
}

@MainActor
final class AntigravityRefreshStoreTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    func testPeriodicDayNeverRestoresSixtySecondAntigravityPolling() async throws {
        let calls = Calls()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: calls.run, retryDelay: 0), snapshotURLs: [])
        var now = epoch
        store.resetClock = { now }
        defer { store.stop() }
        XCTAssertEqual(MultiUsageStore.refreshInterval, 60)
        for minute in 0..<1440 {
            now = epoch.addingTimeInterval(Double(minute * 60))
            store.refresh(trigger: .periodic)
            try await settle(store)
            let section = try XCTUnwrap(store.snapshot.sections.first { $0.provider == .antigravity })
            XCTAssertFalse(section.isStale)
            XCTAssertFalse(section.windows.isEmpty)
            XCTAssertNil(section.failureText)
        }
        XCTAssertEqual(calls.count(.antigravity), 144)
        for provider in ProviderID.allCases where ![.antigravity, .gemini, .opendesign].contains(provider) {
            XCTAssertEqual(calls.count(provider), 1440, "\(provider) must retain the 60 s cadence")
        }
    }

    func testFailuresKeepLastGoodDisplayAcrossBackoffAndResetDates() async throws {
        let calls = Calls()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: calls.run, retryDelay: 0), snapshotURLs: [])
        var now = epoch
        store.resetClock = { now }
        defer { store.stop() }
        store.refresh(trigger: .periodic)
        try await settle(store)
        let original = try XCTUnwrap(store.snapshot.sections.first { $0.provider == .antigravity })
        let failures: [Calls.Outcome] = [.timeout, .error, .quota, .empty, .limit]
        var minutes = 10
        for (index, outcome) in failures.enumerated() {
            now = now.addingTimeInterval(Double(minutes * 60))
            calls.set(outcome)
            store.refresh(trigger: .periodic)
            try await settle(store)
            XCTAssertEqual(calls.count(.antigravity), index + 2, "No immediate CLI retry on failure")
            minutes = [10, 20, 40, 60, 60][index]
            let retained = try XCTUnwrap(store.snapshot.sections.first { $0.provider == .antigravity })
            XCTAssertEqual(retained, original)
            let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .antigravity })
            XCTAssertNotNil(bar.limit)
            XCTAssertFalse(bar.isStale)
            XCTAssertFalse(ServiceRowModel.rows(for: store.snapshot).filter { $0.id.hasPrefix("antigravity-") }.contains { $0.failureText != nil })
            now = now.addingTimeInterval(Double(minutes * 60 - 60))
            store.refresh(trigger: .periodic)
            try await settle(store)
            XCTAssertEqual(calls.count(.antigravity), index + 2)
            now = now.addingTimeInterval(-Double(minutes * 60 - 60))
        }
        now = now.addingTimeInterval(3600)
        calls.set(.success)
        store.refresh(trigger: .periodic)
        try await settle(store)
        let recoveredCount = calls.count(.antigravity)
        now = now.addingTimeInterval(600)
        store.refresh(trigger: .periodic)
        try await settle(store)
        XCTAssertEqual(calls.count(.antigravity), recoveredCount + 1)
    }

    func testManualAndTargetedResetUseSixtySecondFloor() async throws {
        let calls = Calls()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: calls.run, retryDelay: 0), snapshotURLs: [])
        var now = epoch
        store.resetClock = { now }
        defer { store.stop() }
        store.refresh(trigger: .periodic)
        try await settle(store)
        for trigger in [AntigravityRefreshPolicy.Trigger.manual, .reset] {
            now = now.addingTimeInterval(59)
            store.refresh(only: [.antigravity], trigger: trigger)
            try await settle(store)
            let before = calls.count(.antigravity)
            now = now.addingTimeInterval(1)
            store.refresh(only: [.antigravity], trigger: trigger)
            try await settle(store)
            XCTAssertEqual(calls.count(.antigravity), before + 1)
            store.refresh(only: [.antigravity], trigger: trigger)
            try await settle(store)
            XCTAssertEqual(calls.count(.antigravity), before + 1)
        }
        XCTAssertEqual(calls.count(.antigravity), 3)
        XCTAssertEqual(calls.count(.grok), 1)
    }

    func testQueuedPeriodicRefreshCannotBecomeManual() async throws {
        let calls = Calls()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: calls.run, retryDelay: 0), snapshotURLs: [])
        var now = epoch
        store.resetClock = { now }
        defer { store.stop() }
        store.refresh(trigger: .periodic)
        try await settle(store)
        now = epoch.addingTimeInterval(60)
        store.refresh(trigger: .periodic)
        store.refresh(trigger: .periodic)
        try await settle(store)
        XCTAssertEqual(calls.count(.antigravity), 1)
        XCTAssertEqual(calls.count(.grok), 3)
    }

    func testResetPlannerWaitsForFloorThenFetchesImmediately() async throws {
        let calls = Calls(resetAt: epoch.addingTimeInterval(10))
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: calls.run, retryDelay: 0), snapshotURLs: [])
        var now = epoch
        store.resetClock = { now }
        store.start()
        defer { store.stop() }
        try await settle(store)
        now = epoch.addingTimeInterval(59)
        store.scheduleResetRefresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.count(.antigravity), 1)
        now = epoch.addingTimeInterval(60)
        store.scheduleResetRefresh()
        for _ in 0..<1000 {
            if calls.count(.antigravity) == 2, !store.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(calls.count(.antigravity), 2)
        XCTAssertEqual(calls.count(.grok), 1)
        XCTAssertFalse(store.snapshot.sections.first { $0.provider == .antigravity }!.isStale)
        now = epoch.addingTimeInterval(600)
        store.scheduleResetRefresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.count(.antigravity), 2)
    }

    private func settle(_ store: MultiUsageStore) async throws {
        for _ in 0..<1000 {
            if !store.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Refresh did not settle")
    }

    private final class Calls: @unchecked Sendable {
        enum Outcome { case success, timeout, error, quota, empty, limit }
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var outcome = Outcome.success
        private let resetText: String

        init(resetAt: Date = Date(timeIntervalSince1970: 1_800_000_060)) {
            resetText = ISO8601DateFormatter().string(from: resetAt)
        }

        func count(_ provider: ProviderID) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[provider.rawValue, default: 0]
        }

        func set(_ value: Outcome) {
            lock.lock()
            defer { lock.unlock() }
            outcome = value
        }

        func run(_ args: [String]) throws -> CodexUsageService.CommandResult {
            lock.lock()
            counts[args[2], default: 0] += 1
            let selected = args[2] == "antigravity" ? outcome : .success
            lock.unlock()
            switch selected {
            case .timeout:
                return .init(terminationStatus: 1, stdout: Data(), stderr: Data(), timedOut: true)
            case .error:
                throw CodexUsageError.commandFailed(-1, "synthetic failure")
            case .quota:
                return .init(terminationStatus: 1, stdout: Data("quota exceeded".utf8), stderr: Data())
            case .limit:
                return .init(terminationStatus: 0, stdout: Data("rate limit reached".utf8), stderr: Data())
            case .empty:
                return .init(terminationStatus: 0, stdout: Data("[]".utf8), stderr: Data())
            case .success:
                let reset = args[2] == "antigravity" ? resetText : "2099-01-15T08:01:00Z"
                let window: [String: Any] = ["usedPercent": 21, "windowMinutes": 300, "resetsAt": reset]
                let usage: [String: Any] = args[2] == "antigravity"
                    ? ["extraRateWindows": ["Gemini 4 Argon", "Gemini Models", "Claude and GPT models"].map {
                        ["title": $0 + " · 5h", "window": window] as [String: Any]
                    }]
                    : ["primary": window]
                return .init(terminationStatus: 0, stdout: try JSONSerialization.data(withJSONObject: [["usage": usage]]), stderr: Data())
            }
        }
    }
}
