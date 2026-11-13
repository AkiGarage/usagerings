import XCTest
@testable import CodexUsageWidget

final class ResetRefreshPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func key(_ p: ProviderID, _ dt: TimeInterval) -> ResetKey { ResetKey(provider: p, at: t0.addingTimeInterval(dt)) }
    private func section(_ p: ProviderID, resets: [TimeInterval], failed: Bool = false) -> ProviderSection {
        ProviderSection(provider: p, windows: resets.map { var w = UsageLimit(title: "W", leftPercent: 1, resetText: ""); w.resetAt = t0.addingTimeInterval($0); return w },
                        stats: [], failureText: failed ? "x" : nil)
    }

    func testFiresTwentySecondsAfterEarliestFutureReset() {
        let attempts = [key(.grok, 600): ResetRefreshPlanner.Attempts(), key(.zai, 60): .init()]
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0.addingTimeInterval(80))
        XCTAssertEqual(ResetRefreshPlanner.due(attempts: attempts, now: t0.addingTimeInterval(80)), [key(.zai, 60)],
                       "Only the provider whose reset passed is fetched")
    }

    func testKnownResetAfterWakeFiresOnceEvenWhenProviderEchoesIt() {
        let k = key(.grok, -3600)
        var attempts = [k: ResetRefreshPlanner.Attempts()]
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0)
        attempts = ResetRefreshPlanner.recordFire([k], attempts: attempts, now: t0)
        attempts = ResetRefreshPlanner.track(attempts, sections: [section(.grok, resets: [-3600])],
                                             fetched: [.grok], skipped: [], now: t0)
        XCTAssertNil(ResetRefreshPlanner.next(attempts: attempts, now: t0.addingTimeInterval(300)))
    }

    func testNoResetsMeansNoExtraRefresh() {
        XCTAssertNil(ResetRefreshPlanner.next(attempts: [:], now: t0))
    }

    func testFailedResetFetchDoesNotScheduleAdditionalResetChecks() {
        let k = key(.grok, -10)
        var attempts = ResetRefreshPlanner.recordFire([k], attempts: [k: .init()], now: t0)
        // The consumed reset stays tracked so failures cannot re-arm it.
        attempts = ResetRefreshPlanner.track(attempts, sections: [section(.grok, resets: [], failed: true)], fetched: [.grok], skipped: [], now: t0)
        XCTAssertEqual(attempts[k]?.count, 1)
        XCTAssertNil(ResetRefreshPlanner.next(attempts: attempts, now: t0))
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
        let k = key(.zai, -30)
        let attempts = ResetRefreshPlanner.track([k: .init()], sections: [section(.zai, resets: [-30])], fetched: [.zai], skipped: [], now: t0)
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0)
    }

    func testUnknownPastResetAndFailedFutureDataAreNotScheduled() {
        XCTAssertTrue(ResetRefreshPlanner.track([:], sections: [section(.grok, resets: [-1])],
                                              fetched: [.grok], skipped: [], now: t0).isEmpty)
        XCTAssertTrue(ResetRefreshPlanner.track([:], sections: [section(.grok, resets: [60], failed: true)],
                                              fetched: [.grok], skipped: [], now: t0).isEmpty)
    }

    func testDuplicateWindowsCoalesceAndChangedDeadlineReplacesOldOne() {
        var attempts = ResetRefreshPlanner.track([:], sections: [section(.grok, resets: [60, 60])],
                                                fetched: [.grok], skipped: [], now: t0)
        XCTAssertEqual(attempts.count, 1)
        attempts = ResetRefreshPlanner.track(attempts, sections: [section(.grok, resets: [120])],
                                             fetched: [.grok], skipped: [], now: t0)
        XCTAssertNil(attempts[key(.grok, 60)])
        XCTAssertEqual(ResetRefreshPlanner.next(attempts: attempts, now: t0), t0.addingTimeInterval(140))
    }

    func testPartialAccountSuccessReplacesOnlyHealthyAccountDeadlines() {
        let a = AccountID(provider: .claude, source: "id", value: "synthetic-a", salt: Data(repeating: 0, count: 32))
        let b = AccountID(provider: .claude, source: "id", value: "synthetic-b", salt: Data(repeating: 0, count: 32))
        func reading(_ resetA: TimeInterval, staleB: Bool) -> ProviderSection {
            var result = section(.claude, resets: [resetA, 90])
            result.failureText = staleB ? "Some accounts unavailable" : nil
            result.windows[0].accountIndex = 0
            result.windows[1].accountIndex = 1
            result.accounts = [ProviderAccount(index: 0, id: a),
                               ProviderAccount(index: 1, failureText: staleB ? "Stale" : nil, id: b, isStale: staleB)]
            return result
        }
        let oldA = ResetKey(provider: .claude, at: t0.addingTimeInterval(60), account: .identified(a))
        let newA = ResetKey(provider: .claude, at: t0.addingTimeInterval(120), account: .identified(a))
        let keyB = ResetKey(provider: .claude, at: t0.addingTimeInterval(90), account: .identified(b))
        var attempts = ResetRefreshPlanner.track([:], sections: [reading(60, staleB: true)], fetched: [.claude], skipped: [], now: t0)
        XCTAssertNotNil(attempts[oldA], "Healthy A must schedule even while B is stale")
        XCTAssertNil(attempts[keyB], "Stale B cannot introduce a deadline")
        attempts = ResetRefreshPlanner.track(attempts, sections: [reading(60, staleB: false)], fetched: [.claude], skipped: [], now: t0)
        attempts = ResetRefreshPlanner.track(attempts, sections: [reading(120, staleB: true)], fetched: [.claude], skipped: [], now: t0)
        XCTAssertNil(attempts[oldA])
        XCTAssertNotNil(attempts[newA])
        XCTAssertNotNil(attempts[keyB], "Failed B keeps its known deadline")
        var reordered = reading(120, staleB: false)
        reordered.accounts[0] = ProviderAccount(index: 1, id: a)
        reordered.accounts[1] = ProviderAccount(index: 0, id: b)
        reordered.windows[0].accountIndex = 1
        reordered.windows[1].accountIndex = 0
        attempts = ResetRefreshPlanner.track(attempts, sections: [reordered], fetched: [.claude], skipped: [], now: t0)
        XCTAssertEqual(Set(attempts.keys), [newA, keyB], "Recovery and reordered accounts must not duplicate deadlines")
    }

    func testDayOldEchoedResetIsNeverChased() {
        let attempts = ResetRefreshPlanner.track([:], sections: [section(.claude, resets: [-90_000])], fetched: [.claude], skipped: [], now: t0)
        XCTAssertNil(ResetRefreshPlanner.next(attempts: attempts, now: t0), "No refresh loop on a stale echo")
    }

    func testHiddenProvidersAreNeverScheduled() {
        let attempts = ResetRefreshPlanner.track([key(.kimi, 60): .init()], sections: [], fetched: [], skipped: [.kimi], now: t0)
        XCTAssertTrue(attempts.isEmpty)
    }

}

@MainActor
final class ResetRefreshStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(_ state: ResponseState, _ timer: ManualTimer) -> MultiUsageStore {
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: { args in
            state.record(args[2])
            guard args[2] == "zai" else {
                return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            let (count, reset, gate) = state.next()
            gate?.wait()
            let at = ISO8601DateFormatter().string(from: reset)
            let json = #"[{"provider":"zai","usage":{"primary":{"usedPercent":\#(count == 1 ? 100 : 0),"windowMinutes":300,"resetsAt":"\#(at)"}}}]"#
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        }, retryDelay: 0), snapshotURLs: [])
        store.resetClock = { timer.now }
        store.resetScheduler = { timer.schedule($0, $1) }
        return store
    }

    private func settle(_ store: MultiUsageStore) async throws {
        for _ in 0..<200 {
            if !store.isRefreshing { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Fetch did not settle")
    }

    func testOneTargetedRefreshAtResetUpdatesDisplayAndDoesNotRetryEcho() async throws {
        let timer = ManualTimer(now: t0)
        let state = ResponseState(reset: t0.addingTimeInterval(60))
        let store = makeStore(state, timer)
        store.start()
        defer { store.stop() }
        try await settle(store)
        XCTAssertEqual(timer.activeCount, 1)
        XCTAssertEqual(timer.deadline, t0.addingTimeInterval(80))
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 0)
        let otherCalls = state.otherCalls
        timer.advance(to: t0.addingTimeInterval(79))
        XCTAssertEqual(state.count, 1)
        timer.advance(to: t0.addingTimeInterval(80))
        try await settle(store)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 100)
        XCTAssertEqual(timer.activeCount, 0)
        timer.advance(to: t0.addingTimeInterval(1000))
        XCTAssertEqual(state.count, 2, "An echoed reset must never trigger a second reset check")
        XCTAssertEqual(state.otherCalls, otherCalls, "A reset must not fetch unrelated providers")
    }

    func testNewSnapshotReplacesDeadlineAndRepeatedPlanningLeavesOneTimer() async throws {
        let timer = ManualTimer(now: t0)
        let state = ResponseState(reset: t0.addingTimeInterval(60))
        let store = makeStore(state, timer)
        store.start()
        defer { store.stop() }
        try await settle(store)
        let obsolete = try XCTUnwrap(timer.latest)
        state.setReset(t0.addingTimeInterval(120))
        store.refresh(only: [.zai])
        try await settle(store)
        for _ in 0..<5 { store.scheduleResetRefresh() }
        XCTAssertEqual(timer.activeCount, 1)
        XCTAssertEqual(timer.deadline, t0.addingTimeInterval(140))
        timer.advance(to: t0.addingTimeInterval(80))
        obsolete.fire() // cancellation can race an already enqueued callback
        XCTAssertEqual(state.count, 2)
        timer.advance(to: t0.addingTimeInterval(140))
        try await settle(store)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(timer.activeCount, 0)
    }

    func testDueTimerWaitsForInFlightFetchWithoutConsumingReset() async throws {
        let timer = ManualTimer(now: t0)
        let state = ResponseState(reset: t0.addingTimeInterval(60))
        let store = makeStore(state, timer)
        store.start()
        defer { store.stop() }
        try await settle(store)
        let gate = DispatchSemaphore(value: 0)
        state.blockNext(gate)
        defer { gate.signal() }
        store.refresh(only: [.zai])
        timer.advance(to: t0.addingTimeInterval(80))
        XCTAssertTrue(store.isRefreshing)
        gate.signal()
        try await settle(store)
        XCTAssertEqual(state.count, 2, "Reset callback must not overlap the running fetch")
        XCTAssertEqual(timer.deadline, timer.now, "Due reset is re-planned after completion")
        timer.advance(to: timer.now)
        try await settle(store)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(timer.activeCount, 0)
    }

    func testInitialFetchSpanningResetSchedulesCatchUpCheck() async throws {
        let timer = ManualTimer(now: t0)
        let state = ResponseState(reset: t0.addingTimeInterval(60))
        let gate = DispatchSemaphore(value: 0)
        state.blockNext(gate)
        defer { gate.signal() }
        let store = makeStore(state, timer)
        store.start()
        defer { store.stop() }
        timer.advance(to: t0.addingTimeInterval(80))
        gate.signal()
        try await settle(store)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(timer.deadline, timer.now)
        timer.advance(to: timer.now)
        try await settle(store)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .zai }?.windows.first?.leftPercent, 100)
        XCTAssertEqual(timer.activeCount, 0)
    }

    func testStopCancelsTimerAndRejectsAlreadyEnqueuedCallback() async throws {
        let timer = ManualTimer(now: t0)
        let state = ResponseState(reset: t0.addingTimeInterval(60))
        let store = makeStore(state, timer)
        store.start()
        try await settle(store)
        let callback = try XCTUnwrap(timer.latest)
        store.stop()
        XCTAssertEqual(timer.activeCount, 0)
        timer.advance(to: t0.addingTimeInterval(80))
        callback.fire()
        await Task.yield()
        XCTAssertEqual(state.count, 1)
        XCTAssertFalse(store.isRefreshing)
    }
}

@MainActor
private final class ManualTimer {
    final class Entry {
        let deadline: Date
        let fire: @MainActor () -> Void
        var cancelled = false
        init(deadline: Date, fire: @escaping @MainActor () -> Void) { self.deadline = deadline; self.fire = fire }
    }
    var now: Date
    var entries: [Entry] = []
    var latest: Entry? { entries.last }
    var activeCount: Int { entries.filter { !$0.cancelled }.count }
    var deadline: Date? { entries.filter { !$0.cancelled }.map(\.deadline).min() }
    init(now: Date) { self.now = now }
    func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let entry = Entry(deadline: now.addingTimeInterval(delay), fire: fire)
        entries.append(entry)
        return { entry.cancelled = true }
    }
    func advance(to date: Date) {
        now = date
        for entry in entries.filter({ !$0.cancelled && $0.deadline <= date }) {
            entry.cancelled = true
            entry.fire()
        }
    }
}

private final class ResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var providers: [String: Int] = [:]
    var otherCalls: [String: Int] { lock.lock(); defer { lock.unlock() }; return providers.filter { $0.key != "zai" } }
    func record(_ provider: String) { lock.lock(); defer { lock.unlock() }; providers[provider, default: 0] += 1 }
    private var reset: Date
    private var gate: DispatchSemaphore?
    init(reset: Date) { self.reset = reset }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func setReset(_ value: Date) { lock.lock(); defer { lock.unlock() }; reset = value }
    func blockNext(_ value: DispatchSemaphore) { lock.lock(); defer { lock.unlock() }; gate = value }
    func next() -> (Int, Date, DispatchSemaphore?) {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let result = (calls, reset, gate)
        gate = nil
        return result
    }
}
