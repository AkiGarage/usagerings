import XCTest
@testable import CodexUsageWidget

@MainActor
final class MultiUsageStoreTests: XCTestCase {
    func testRefreshSendsProviderReadingsOnlyAfterOptIn() async throws {
        let defaults = UserDefaults(suiteName: "CloudStoreTests-\(UUID())")!
        let preferences = PanelPreferences(defaults: defaults)
        let transport = CloudSnapshotSenderTests.MockTransport()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: Self.successRunner), snapshotURLs: [], preferences: preferences, cloudTransport: transport)
        store.refresh()
        try await waitUntil("refresh settles") { !store.isRefreshing }
        XCTAssertTrue(transport.sent.isEmpty)
        preferences.setCloudSyncEnabled(true)
        await store.cloudSyncChanged(enabled: true)
        try await waitUntil("cloud publish settles") { !transport.sent.isEmpty }
        let reading = try XCTUnwrap(transport.sent.first?.readings.first { $0.provider == "codex" && $0.window == "weekly" })
        XCTAssertEqual(reading.remainingPercent, 81)
        XCTAssertFalse(transport.sent.first!.readings.contains { $0.provider == "gemini" })
    }

    func testHiddenProviderIsFetchedAndSentWhenSyncEnabled() async throws {
        let defaults = UserDefaults(suiteName: "CloudStoreTests-\(UUID())")!
        let preferences = PanelPreferences(defaults: defaults)
        preferences.setProviderVisible(false, for: .codex)
        let transport = CloudSnapshotSenderTests.MockTransport()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: Self.successRunner), snapshotURLs: [], preferences: preferences, cloudTransport: transport)
        store.refresh()
        try await waitUntil("refresh settles before opt-in") { !store.isRefreshing }
        XCTAssertTrue(transport.sent.isEmpty)
        preferences.setCloudSyncEnabled(true)
        await store.cloudSyncChanged(enabled: true)
        try await waitUntil("hidden provider sent") { !transport.sent.isEmpty }
        XCTAssertFalse(store.snapshot.sections.contains { $0.provider == .codex })
        XCTAssertTrue(transport.sent[0].readings.contains { $0.provider == "codex" && $0.window == "weekly" })
    }

    func testCodexResetDateSurvivesTheMultiProviderPath() async throws {
        let service = MultiUsageService(commandRunner: { _ in
            let json = #"[{"provider":"codex","usage":{"primary":{"usedPercent":20,"windowMinutes":300,"resetsAt":"2026-10-29T00:00:00Z"}}}]"#
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        })
        let snapshot = await service.fetchAll(disabled: Set(ProviderID.allCases.filter { $0 != .codex }))
        let limit = try XCTUnwrap(snapshot.sections.first { $0.provider == .codex }?.windows.first)
        XCTAssertEqual(limit.title, "5h")
        XCTAssertEqual(limit.resetAt, ISO8601DateFormatter().date(from: "2026-10-29T00:00:00Z"))
    }

    func testSuccessfulPublishClearsPreviousWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("snapshot-directory")
        try Data("synthetic blocker".utf8).write(to: blocker)
        let fileURL = blocker.appendingPathComponent("snapshot.json")
        let store = MultiUsageStore(
            service: MultiUsageService(commandRunner: Self.successRunner),
            snapshotURLs: [fileURL]
        )

        store.refresh()
        try await waitUntil("failed write settles") { !store.isRefreshing }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try FileManager.default.removeItem(at: blocker)
        store.refresh()
        try await waitUntil("recovery write settles") { !store.isRefreshing }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 2)
        XCTAssertNil(store.errorMessage, "A successful retry must dismiss the old failure notice")
    }

    func testRefreshPublishesCodexSnapshotToInjectedPaths() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("latest-usage-snapshot.json")
        let store = MultiUsageStore(
            service: MultiUsageService(commandRunner: Self.successRunner),
            snapshotURLs: [fileURL]
        )

        store.refresh()
        try await waitUntil("snapshot file is written") { FileManager.default.fileExists(atPath: fileURL.path) }

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 2)
        XCTAssertEqual(json?["source"] as? String, "CodexBarCLI")
        XCTAssertEqual((json?["weekly"] as? [String: Any])?["remainingPercent"] as? Int, 81)
        XCTAssertNil(store.errorMessage)
    }

    func testRefreshKeepsOtherSectionsWhenOneProviderFails() async throws {
        let store = MultiUsageStore(
            service: MultiUsageService(commandRunner: { arguments in
                if arguments[2] == "zai" {
                    return CodexUsageService.CommandResult(
                        terminationStatus: 1,
                        stdout: Data(Self.zaiError.utf8),
                        stderr: Data()
                    )
                }
                return try Self.successRunner(arguments)
            }),
            snapshotURLs: []
        )

        store.refresh()
        try await waitUntil("snapshot sections settle after partial failure") {
            store.snapshot.sections.first?.failureText == nil
        }

        XCTAssertEqual(store.snapshot.sections.map(\.provider), [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .antigravity])
        XCTAssertNotNil(store.snapshot.sections[3].failureText)
        XCTAssertEqual(store.snapshot.sections[1].windows.count, 2)
        XCTAssertFalse(store.isRefreshing)
    }

    func testTimeoutRetainsLastGoodRingAndOtherProviderUpdates() async throws {
        let state = RefreshState()
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: { args in
            if args[2] == "zai", state.shouldFail() {
                return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data(), timedOut: true)
            }
            if args[2] == "zai", state.isRecovered {
                return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(Self.zai.replacingOccurrences(of: "\"usedPercent\":10", with: "\"usedPercent\":35").utf8), stderr: Data())
            }
            return try Self.successRunner(args)
        }), snapshotURLs: [])
        store.refresh()
        try await waitUntil("first refresh") { !store.isRefreshing }
        let before = CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .zai }?.limit
        XCTAssertNotNil(before)
        state.fail()
        store.refresh()
        try await waitUntil("second refresh") { !store.isRefreshing }
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .zai })
        XCTAssertEqual(bar.limit, before, "A transient timeout must not replace a previous value with ?")
        XCTAssertTrue(bar.isStale)
        XCTAssertTrue(ServiceRowModel.rows(for: store.snapshot).first { $0.id.hasPrefix("zai-") }?.failureText?.contains("Stale") == true)
        XCTAssertEqual(state.failedAttempts, 2, "A timeout gets exactly one retry")
        XCTAssertTrue(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: ServiceRowModel.rows(for: store.snapshot)).contains("Stale"))
        XCTAssertNotNil(CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .codex }?.limit)
        state.recover()
        store.refresh()
        try await waitUntil("recovery") { !store.isRefreshing }
        let recovered = try XCTUnwrap(CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .zai })
        XCTAssertEqual(recovered.limit?.leftPercent, 65)
        XCTAssertNotEqual(recovered.limit?.leftPercent, before?.leftPercent)
        XCTAssertFalse(recovered.isStale)
    }

    func testFirstFailureHasNoInventedRingValue() async throws {
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: { args in
            if args[2] == "zai" {
                return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data(), timedOut: true)
            }
            return try Self.successRunner(args)
        }), snapshotURLs: [])
        store.refresh()
        try await waitUntil("first failure") { !store.isRefreshing }
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: store.snapshot).first { $0.provider == .zai })
        XCTAssertNil(bar.limit)
        XCTAssertFalse(bar.isStale)
    }

    func testStaleClaudeAccountDoesNotProduceAutomaticChoice() {
        let store = MultiUsageStore(demoSnapshot: .placeholder)
        store.claudeProfileMasks = { [:] }
        var first = UsageLimit(title: "5h", leftPercent: 70, resetText: "Reset pending")
        first.accountIndex = 0
        var second = UsageLimit(title: "5h", leftPercent: 20, resetText: "Reset pending")
        second.accountIndex = 1
        var section = ProviderSection(provider: .claude, windows: [first, second], stats: [], failureText: nil,
                                      accounts: [ProviderAccount(index: 0), ProviderAccount(index: 1)])
        let now = Date()
        store.updateClaudeChoice(from: MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now), now: now)
        XCTAssertNotNil(store.claudeChoice)
        section.accounts[0].isStale = true
        store.updateClaudeChoice(from: MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now), now: now)
        XCTAssertNil(store.claudeChoice, "Stale usage must not select an account")
    }

    private final class RefreshState: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        private var recovered = false
        var isRecovered: Bool { lock.lock(); defer { lock.unlock() }; return recovered }
        private var attempts = 0
        var failedAttempts: Int { lock.lock(); defer { lock.unlock() }; return attempts }
        func shouldFail() -> Bool { lock.lock(); defer { lock.unlock() }; if failing { attempts += 1 }; return failing }
        func fail() { lock.lock(); defer { lock.unlock() }; failing = true }
        func recover() { lock.lock(); defer { lock.unlock() }; failing = false; recovered = true }
    }

    private static let successRunner: CodexUsageService.CommandRunner = { arguments in
        let json: String
        switch arguments[2] {
        case "codex":
            json = MultiUsageStoreTests.codex
        case "zai":
            json = MultiUsageStoreTests.zai
        default:
            json = MultiUsageStoreTests.claude
        }
        return CodexUsageService.CommandResult(
            terminationStatus: 0,
            stdout: Data(json.utf8),
            stderr: Data()
        )
    }

    private func waitUntil(_ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("waitUntil timed out: \(message)", file: file, line: line)
    }

    private static let codex = #"[{"provider":"codex","usage":{"updatedAt":"2023-11-14T22:13:20.000Z","primary":{"usedPercent":null,"windowMinutes":null,"resetsAt":null},"secondary":{"usedPercent":19,"windowMinutes":10080,"resetsAt":"2026-10-22T06:38:56Z"}},"credits":{"remaining":61003.32,"balanceReadSucceeded":true}}]"#

    private static let zai = #"[{"provider":"zai","usage":{"primary":{"usedPercent":10,"windowMinutes":300,"resetsAt":"2099-10-16T15:52:28Z"},"secondary":null,"tertiary":null,"extraRateWindows":[{"title":"MCP","window":{"usedPercent":0.4,"windowMinutes":43200,"resetsAt":"2026-11-04T05:08:05Z"}}]}}]"#

    private static let claude = #"[{"provider":"claude","usage":{"primary":{"usedPercent":21,"windowMinutes":300,"resetsAt":"2026-10-16T14:39:59Z"},"secondary":{"usedPercent":36,"windowMinutes":10080,"resetsAt":"2026-10-21T16:59:59Z"}}}]"#

    private static let zaiError = #"[{"provider":"zai","error":{"code":1,"kind":"provider","message":"synthetic-sensitive-message"}}]"#
}
