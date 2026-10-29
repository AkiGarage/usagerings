import XCTest
@testable import CodexUsageWidget

final class ResetRefreshPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(_ p: ProviderID, _ dt: TimeInterval) -> ResetKey { ResetKey(provider: p, at: t0.addingTimeInterval(dt)) }
    private func section(_ p: ProviderID, resets: [TimeInterval], failed: Bool = false) -> ProviderSection {
        ProviderSection(provider: p, windows: resets.map { var w = UsageLimit(title: "W", leftPercent: 1, resetText: ""); w.resetAt = t0.addingTimeInterval($0); return w },
                        stats: [], failureText: failed ? "x" : nil)
    }

    func testFiresFiveSecondsAfterEarliestFutureReset() {
        let attempts = [key(.grok, 600): ResetRefreshPlanner.Attempts(), key(.zai, 60): .init()]
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0.addingTimeInterval(65))
        XCTAssertEqual(ResetRefreshPlanner.due(attempts: attempts, now: t0.addingTimeInterval(65)), [key(.zai, 60)],
                       "Only the provider whose reset passed is fetched")
    }

    func testPastResetAfterWakeFiresNowThenSpacedRetriesThenStops() {
        let k = key(.grok, -3600)
        var attempts = [k: ResetRefreshPlanner.Attempts()]
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0)
        attempts = ResetRefreshPlanner.recordFire([k], attempts: attempts, now: t0)
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0.addingTimeInterval(31))
        attempts = ResetRefreshPlanner.recordFire([k], attempts: attempts, now: t0.addingTimeInterval(31))
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0.addingTimeInterval(31)), t0.addingTimeInterval(122))
        attempts = ResetRefreshPlanner.recordFire([k], attempts: attempts, now: t0.addingTimeInterval(122))
        XCTAssertNil(ResetRefreshPlanner.next(attempts: attempts, now: t0.addingTimeInterval(200)), "At most 3 checks per reset")
    }

    func testNoResetsMeansNoExtraRefresh() {
        XCTAssertNil(ResetRefreshPlanner.next(attempts: [:], now: t0))
    }

    func testFailedFetchKeepsResetSoRetriesContinue() {
        let k = key(.grok, -10)
        var attempts = ResetRefreshPlanner.recordFire([k], attempts: [k: .init()], now: t0)
        // The post-reset fetch failed and the window vanished: the reset stays tracked.
        attempts = ResetRefreshPlanner.track(attempts, sections: [section(.grok, resets: [], failed: true)], fetched: [.grok], skipped: [], now: t0)
        XCTAssertEqual(attempts[k]?.count, 1)
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0.addingTimeInterval(31))
    }

    func testConclusiveNewWindowSettlesResetAndUntouchedProvidersStay() {
        let grok = key(.grok, -10), zai = key(.zai, -5)
        var attempts = ResetRefreshPlanner.recordFire([grok, zai], attempts: [:], now: t0)
        attempts = ResetRefreshPlanner.track(attempts, sections: [section(.grok, resets: [18_000]), section(.zai, resets: [])],
                                             fetched: [.grok], skipped: [], now: t0)
        XCTAssertNil(attempts[grok], "Provider shows its next window: done, no retry")
        XCTAssertEqual(attempts[key(.grok, 18_000)], .init())
        XCTAssertEqual(attempts[zai]?.count, 1, "A provider not fetched keeps its state")
    }

    func testQueuedResetIsNotConsumedWhileAFetchIsInFlight() {
        // Due during an in-flight fetch: nothing is recorded, so once that fetch is applied
        // (still echoing the old reset) it fires immediately instead of being dropped.
        let k = key(.zai, -10)
        let attempts = ResetRefreshPlanner.track([k: .init()], sections: [section(.zai, resets: [-10])], fetched: [.zai], skipped: [], now: t0)
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0)
    }

    func testDayOldEchoedResetIsNeverChased() {
        let attempts = ResetRefreshPlanner.track([:], sections: [section(.claude, resets: [-90_000])], fetched: [.claude], skipped: [], now: t0)
        XCTAssertNil(ResetRefreshPlanner.next(attempts: attempts, now: t0), "No refresh loop on a stale echo")
    }

    func testHiddenProvidersAreNeverScheduled() {
        let attempts = ResetRefreshPlanner.track([key(.kimi, 60): .init()], sections: [], fetched: [], skipped: [.kimi], now: t0)
        XCTAssertTrue(attempts.isEmpty)
    }

    func testClientRecheckOncePerResetAndBoundedRetries() {
        let fetched = t0
        let reset = t0.addingTimeInterval(60)
        var w = UsageLimit(title: "W", leftPercent: 1, resetText: ""); w.resetAt = reset
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: fetched, retries: 0, now: t0.addingTimeInterval(59)), .none)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: fetched, retries: 0, now: t0.addingTimeInterval(61)), .afterReset)
        // Refetched at +65 but provider still echoes the passed reset.
        let refetched = t0.addingTimeInterval(65)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: refetched, retries: 0, now: refetched.addingTimeInterval(29)), .none)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: refetched, retries: 0, now: refetched.addingTimeInterval(30)), .staleRetry)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: refetched, retries: 1, now: refetched.addingTimeInterval(89)), .none)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: refetched, retries: 1, now: refetched.addingTimeInterval(90)), .staleRetry)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: refetched, retries: 2, now: refetched.addingTimeInterval(9999)), .none)
        XCTAssertEqual(CLIProxyClient.resetRecheck(resets: [reset], fetchedAt: nil, retries: 0, now: refetched), .none)
    }
}

@MainActor
final class ResetRefreshStoreTests: XCTestCase {
    private func makeStore(_ counts: Counts, reset: Date, slowFirst: Bool = false) -> MultiUsageStore {
        let iso = ISO8601DateFormatter()
        return MultiUsageStore(service: MultiUsageService(commandRunner: { args in
            let n = counts.next(args[2])
            guard args[2] == "zai" else {
                return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data("[]".utf8), stderr: Data())
            }
            // The provider flips to the new window only once the reset has really passed.
            let (used, at) = Date() < reset ? (100, reset) : (0, reset.addingTimeInterval(18_000))
            if slowFirst, n == 1 { Thread.sleep(forTimeInterval: 1.5) }
            let json = #"[{"provider":"zai","usage":{"primary":{"usedPercent":\#(used),"windowMinutes":300,"resetsAt":"\#(iso.string(from: at))"}}}]"#
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client()), snapshotURLs: [])
    }

    private func waitForZai(_ store: MultiUsageStore, _ left: Double) async throws {
        for _ in 0..<100 {
            if store.snapshot.sections.first(where: { $0.provider == .zai })?.windows.first?.leftPercent == left { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testResetTimeTriggersTargetedRefreshAndUpdatesDisplay() async throws {
        let counts = Counts()
        let reset = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 1)
        let store = makeStore(counts, reset: reset)
        store.resetClock = { Date().addingTimeInterval(5) } // skip the +5 s offset in tests
        store.start()
        defer { store.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 0)
        try await waitForZai(store, 100)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 100,
                       "A reset must refresh the display without waiting for the 60 s poll")
        XCTAssertEqual(counts["zai"], 2, "Initial fetch + one at the reset")
        XCTAssertEqual(counts["kimi"], 1, "Other providers are not fetched for zai's reset")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(counts["zai"], 2, "No further checks once the new window is shown")
        XCTAssertEqual(counts["kimi"], 1)
    }

    func testResetDuringInFlightFetchIsQueuedNotDropped() async throws {
        let counts = Counts()
        let reset = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 1)
        let store = makeStore(counts, reset: reset, slowFirst: true) // first fetch spans the reset
        store.resetClock = { Date().addingTimeInterval(5) }
        store.start()
        defer { store.stop() }
        try await waitForZai(store, 100)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 100)
        XCTAssertEqual(counts["zai"], 2, "The queued reset runs right after the in-flight fetch")
        XCTAssertEqual(counts["kimi"], 1)
    }
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [String: Int] = [:]
    subscript(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; return n[k] ?? 0 }
    func next(_ k: String) -> Int { lock.lock(); defer { lock.unlock() }; n[k, default: 0] += 1; return n[k]! }
}
