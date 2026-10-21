import XCTest
@testable import CodexUsageWidget

@MainActor
final class MultiUsageStoreTests: XCTestCase {
    func testRefreshPublishesCodexSnapshotToInjectedPaths() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("latest-usage-snapshot.json")
        let store = MultiUsageStore(
            service: MultiUsageService(commandRunner: Self.successRunner, cliProxyClient: CLIProxyFixtures.client()),
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
            }, cliProxyClient: CLIProxyFixtures.client()),
            snapshotURLs: []
        )

        store.refresh()
        try await waitUntil("snapshot sections settle after partial failure") {
            store.snapshot.sections.first?.failureText == nil
        }

        XCTAssertEqual(store.snapshot.sections.map(\.provider), [.codex, .claude, .grok, .zai, .antigravity])
        XCTAssertNotNil(store.snapshot.sections[3].failureText)
        XCTAssertEqual(store.snapshot.sections[1].windows.count, 4)
        XCTAssertFalse(store.isRefreshing)
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

    private static let codex = #"[{"provider":"codex","usage":{"primary":{"usedPercent":null,"windowMinutes":null,"resetsAt":null},"secondary":{"usedPercent":19,"windowMinutes":10080,"resetsAt":"2026-10-22T06:38:56Z"}},"credits":{"remaining":61003.32,"balanceReadSucceeded":true}}]"#

    private static let zai = #"[{"provider":"zai","usage":{"primary":{"usedPercent":10,"windowMinutes":300,"resetsAt":"2026-10-16T15:52:28Z"},"secondary":null,"tertiary":null,"extraRateWindows":[{"title":"MCP","window":{"usedPercent":0.4,"windowMinutes":43200,"resetsAt":"2026-11-04T05:08:05Z"}}]}}]"#

    private static let claude = #"[{"provider":"claude","usage":{"primary":{"usedPercent":21,"windowMinutes":300,"resetsAt":"2026-10-16T14:39:59Z"},"secondary":{"usedPercent":36,"windowMinutes":10080,"resetsAt":"2026-10-21T16:59:59Z"}}}]"#

    private static let zaiError = #"[{"provider":"zai","error":{"code":1,"kind":"provider","message":"synthetic-sensitive-message"}}]"#
}
