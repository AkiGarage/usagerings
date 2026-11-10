import Combine
import XCTest
@testable import CodexUsageWidget

@MainActor
final class StoreLifecycleTests: XCTestCase {
    func testProviderTurnedOnDuringFetchQueuesOneFullRefresh() async throws {
        let preferences = makePreferences()
        let runner = GatedRunner()
        let store = makeStore(runner, preferences: preferences)
        preferences.onProviderVisibilityChange = { [weak store] turnedOn in
            store?.providerVisibilityChanged(turnedOn: turnedOn)
        }
        defer { runner.release(); store.stop() }

        store.refresh()
        try await waitUntil("first fetch starts") { runner.calls("zai") == 1 }
        preferences.setProviderVisible(true, for: .kimi)
        store.refresh()
        store.refresh() // Full refresh requests coalesce.
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(runner.calls("zai"), 1)
        XCTAssertEqual(runner.calls("kimi"), 0, "The new fetch must wait for the in-flight fetch")

        runner.release()
        try await waitUntil("queued full refresh completes") { !store.isRefreshing }
        XCTAssertEqual(runner.calls("zai"), 2)
        XCTAssertEqual(runner.calls("kimi"), 1)
        XCTAssertEqual(runner.maximumActiveZaiCalls, 1)
        XCTAssertEqual(store.snapshot.sections.first { $0.provider == .kimi }?.windows.first?.leftPercent, 79)
    }

    func testTargetedRefreshDuringFetchDoesNotQueue() async throws {
        let preferences = makePreferences()
        preferences.setProviderVisible(true, for: .kimi)
        let runner = GatedRunner()
        let store = makeStore(runner, preferences: preferences)
        defer { runner.release(); store.stop() }

        store.refresh(only: [.zai])
        try await waitUntil("targeted fetch starts") { runner.calls("zai") == 1 }
        store.refresh(only: [.kimi])
        runner.release()
        try await waitUntil("targeted fetch completes") { !store.isRefreshing }
        XCTAssertEqual(runner.calls("zai"), 1)
        XCTAssertEqual(runner.calls("kimi"), 0, "The reset planner owns targeted retries")
    }

    func testStopDiscardsInFlightResultAndClearsQueuedRefresh() async throws {
        let preferences = makePreferences()
        let runner = GatedRunner()
        let store = makeStore(runner, preferences: preferences)
        var snapshotUpdates = 0
        let subscription = store.$snapshot.dropFirst().sink { _ in snapshotUpdates += 1 }
        defer { subscription.cancel(); runner.release(); store.stop() }

        store.start()
        try await waitUntil("fetch starts before stop") { runner.calls("zai") == 1 }
        store.refresh()
        store.stop()
        XCTAssertTrue(store.isRefreshing, "The CLI fetch still owns the in-flight slot")
        runner.release()
        try await waitUntil("stopped fetch completes") { !store.isRefreshing }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.calls("zai"), 1, "stop() must clear the old queued refresh")
        XCTAssertEqual(snapshotUpdates, 0, "A stopped fetch must neither apply data nor arm expiry updates")
    }

    func testStartAfterStopWaitsForOldFetchBeforeRefreshing() async throws {
        let runner = GatedRunner()
        let store = makeStore(runner, preferences: makePreferences())
        var displayedPercentages: [Double] = []
        let subscription = store.$snapshot.dropFirst().sink { snapshot in
            if let left = snapshot.sections.first(where: { $0.provider == .zai })?.windows.first?.leftPercent {
                displayedPercentages.append(left)
            }
        }
        defer { subscription.cancel(); runner.release(); store.stop() }

        store.start()
        try await waitUntil("old fetch starts") { runner.calls("zai") == 1 }
        store.stop()
        store.start()
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(runner.calls("zai"), 1)
        runner.release()
        try await waitUntil("restarted fetch completes") { !store.isRefreshing }
        XCTAssertEqual(runner.calls("zai"), 2)
        XCTAssertEqual(runner.maximumActiveZaiCalls, 1)
        XCTAssertEqual(displayedPercentages, [78], "Only the new generation may update the display")
    }

    func testMultiUsageStoreReplacementOpacityHUDKeepsItsOwnLifetime() async throws {
        let store = MultiUsageStore(demoSnapshot: .placeholder)
        defer { store.stop() }
        store.opacityHUDDuration = 0.01
        store.showOpacityHUD(percent: 40)
        await Task.yield()
        store.opacityHUDDuration = 0.2
        store.showOpacityHUD(percent: 80)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.opacityHUDPercent, 80, "The older task must not clear the replacement HUD")
        try await waitUntil("replacement multi-store HUD expires") { store.opacityHUDPercent == nil }
    }

    func testUsageStoreReplacementOpacityHUDKeepsItsOwnLifetime() async throws {
        let store = UsageStore(service: CodexUsageService(commandRunner: { _ in
            CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(), stderr: Data())
        }))
        defer { store.stop() }
        store.opacityHUDDuration = 0.01
        store.showOpacityHUD(percent: 40)
        await Task.yield()
        store.opacityHUDDuration = 0.2
        store.showOpacityHUD(percent: 80)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(store.opacityHUDPercent, 80, "The older task must not clear the replacement HUD")
        try await waitUntil("replacement single-store HUD expires") { store.opacityHUDPercent == nil }
    }

    func testUndecidedProbeTracksResetUsingSkipSetFromFetch() async throws {
        let preferences = makePreferences(undecidedZai: true)
        let reset = Date(timeIntervalSince1970: 2_000_003_600)
        let runner = GatedRunner(reset: reset)
        let store = makeStore(runner, preferences: preferences)
        var now = reset.addingTimeInterval(-3600)
        store.resetClock = { now }
        var hidProvider = false
        // Successful data normally auto-enables an undecided provider. Change visibility
        // at publication to distinguish the captured skip set from a second calculation.
        let subscription = store.$snapshot.dropFirst().sink { snapshot in
            guard !hidProvider, snapshot.sections.contains(where: { $0.provider == .zai && !$0.windows.isEmpty }) else { return }
            hidProvider = true
            preferences.setProviderVisible(false, for: .zai)
        }
        defer { subscription.cancel(); runner.release(); store.stop() }

        XCTAssertNil(preferences.providerVisibility[ProviderID.zai.rawValue])
        store.start()
        try await waitUntil("undecided probe starts") { runner.calls("zai") == 1 }
        runner.release()
        try await waitUntil("undecided probe applies") { !store.isRefreshing }
        XCTAssertTrue(hidProvider)
        // No visibility callback is attached: only the reset planner can start this fetch.
        preferences.setProviderVisible(true, for: .zai)
        now = reset.addingTimeInterval(5)
        store.scheduleResetRefresh()
        try await waitUntil("announced reset triggers its targeted refresh") {
            runner.calls("zai") == 2 && !store.isRefreshing
        }
        XCTAssertEqual(runner.calls("kimi"), 0)
        XCTAssertEqual(runner.maximumActiveZaiCalls, 1)
    }

    private func makePreferences(undecidedZai: Bool = false) -> PanelPreferences {
        let defaults = UserDefaults(suiteName: "StoreLifecycleTests-\(UUID())")!
        var visibility = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0.rawValue, false) })
        if !undecidedZai { visibility[ProviderID.zai.rawValue] = true }
        else { visibility.removeValue(forKey: ProviderID.zai.rawValue) }
        defaults.set(visibility, forKey: PanelPreferences.providerVisibilityKey)
        return PanelPreferences(defaults: defaults)
    }

    private func makeStore(_ runner: GatedRunner, preferences: PanelPreferences) -> MultiUsageStore {
        MultiUsageStore(service: MultiUsageService(commandRunner: { arguments in
            runner.run(arguments)
        }, retryDelay: 0), snapshotURLs: [], preferences: preferences)
    }

    private func waitUntil(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("waitUntil timed out: \(message)", file: file, line: line)
    }
}

/// A synchronous fake CLI boundary, matching CodexUsageService.CommandRunner.
/// Blocking only the first Zai call lets tests control completion without timing guesses.
private final class GatedRunner: @unchecked Sendable {
    private let condition = NSCondition()
    private let reset: Date
    private var released = false
    private var counts: [String: Int] = [:]
    private var activeZaiCalls = 0
    private var maximumActiveZai = 0

    init(reset: Date = Date(timeIntervalSince1970: 4_000_000_000)) {
        self.reset = reset
    }

    func calls(_ provider: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return counts[provider] ?? 0
    }

    var maximumActiveZaiCalls: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveZai
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func run(_ arguments: [String]) -> CodexUsageService.CommandResult {
        let provider = arguments[2]
        condition.lock()
        counts[provider, default: 0] += 1
        let call = counts[provider]!
        if provider == "zai" {
            activeZaiCalls += 1
            maximumActiveZai = max(maximumActiveZai, activeZaiCalls)
            if call == 1 {
                let deadline = Date().addingTimeInterval(5)
                while !released {
                    if !condition.wait(until: deadline) { break }
                }
            }
        }
        condition.unlock()

        let resetText = ISO8601DateFormatter().string(from: reset)
        let json = #"[{"provider":"\#(provider)","usage":{"primary":{"usedPercent":\#(20 + call),"windowMinutes":300,"resetsAt":"\#(resetText)"}}}]"#
        let result = CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        if provider == "zai" {
            condition.lock()
            activeZaiCalls -= 1
            condition.unlock()
        }
        return result
    }
}
