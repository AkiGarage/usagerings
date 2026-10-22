import XCTest
@testable import CodexUsageWidget

final class ProviderVisibilityTests: XCTestCase {
    @MainActor
    func testAutoOnOnlyWithDataPersistedAndExplicitOffWins() throws {
        let name = "ProviderVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = PanelPreferences(defaults: defaults)
        XCTAssertTrue(ProviderID.allCases.allSatisfy { !prefs.isProviderVisible($0) })
        var w = UsageLimit(title: "5h", leftPercent: 50, resetText: ""); w.accountIndex = 0
        let snap = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [w], stats: []),
            ProviderSection(provider: .minimax, windows: [], stats: [], failureText: "not configured"),
            ProviderSection(provider: .claude, windows: [], stats: [], failureText: "x",
                            accounts: [ProviderAccount(index: 0, failureText: "Usage rate-limited", id: .singleton(.claude))])
        ], codexSnapshot: nil, updatedAt: Date())
        prefs.reconcileProviders(in: snap)
        XCTAssertTrue(prefs.isProviderVisible(.codex))
        XCTAssertFalse(prefs.isProviderVisible(.minimax))
        XCTAssertFalse(prefs.isProviderVisible(.claude))
        XCTAssertTrue(prefs.disabledProviders.isEmpty, "auto-unknown providers keep being probed")
        prefs.setProviderVisible(false, for: .codex)
        prefs.reconcileProviders(in: snap)
        XCTAssertFalse(prefs.isProviderVisible(.codex), "auto never overrides an explicit off")
        XCTAssertEqual(prefs.disabledProviders, [.codex])
        prefs.setProviderVisible(true, for: .minimax)
        let reloaded = PanelPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.isProviderVisible(.codex))
        XCTAssertTrue(reloaded.isProviderVisible(.minimax))
    }

    @MainActor
    func testStoreFiltersHiddenProvidersAndReappliesOnToggle() throws {
        let name = "ProviderVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = PanelPreferences(defaults: defaults)
        prefs.setProviderVisible(true, for: .codex)
        let store = MultiUsageStore(preferences: prefs)
        let snap = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [], stats: []),
            ProviderSection(provider: .kimi, windows: [], stats: [])
        ], codexSnapshot: nil, updatedAt: Date())
        XCTAssertEqual(store.visible(snap).sections.map(\.provider), [.codex])
        prefs.setProviderVisible(true, for: .kimi)
        XCTAssertEqual(store.visible(snap).sections.map(\.provider), [.codex, .kimi])
    }

    func testDisabledProvidersAreNotFetched() async {
        let recorder = Recorder()
        let service = MultiUsageService(commandRunner: { args in
            recorder.add(args.joined(separator: " "))
            return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        })
        let snapshot = await service.fetchAll(disabled: [.minimax, .kimi, .deepseek, .zai, .claude, .antigravity, .grok])
        let calls = recorder.calls
        XCTAssertFalse(calls.contains { $0.contains("minimax") || $0.contains("kimi") || $0.contains("deepseek") || $0.contains("zai") })
        XCTAssertEqual(snapshot.sections.first { $0.provider == .minimax }?.failureText, MultiUsageService.hiddenText)
        XCTAssertNil(snapshot.sections.first { $0.provider == .claude })
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ s: String) { lock.lock(); stored.append(s); lock.unlock() }
}
