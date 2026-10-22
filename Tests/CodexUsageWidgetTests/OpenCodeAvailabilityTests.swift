import XCTest
@testable import CodexUsageWidget

final class OpenCodeAvailabilityTests: XCTestCase {
    // OpenCode 1.15.10's local session schema has cumulative cost/token counters,
    // but no provider quota, remaining percentage, or reset time. These are fake
    // counters, not a supported OpenCode export format or a live database read.
    func testSessionAccountingCannotBecomeQuotaData() throws {
        for tokens in [0, 42_000, 9_000_000] {
            let counters: [String: Any] = [
                "cost": 1.25, "tokens_input": tokens, "tokens_output": 120,
                "tokens_reasoning": 80, "tokens_cache_read": 300,
                "tokens_cache_write": 200
            ]
            for payload in [[counters], [["usage": counters]]] {
                let data = try JSONSerialization.data(withJSONObject: payload)
                for provider in [ProviderID.zai, .minimax, .kimi, .deepseek] {
                    XCTAssertThrowsError(try MultiProviderParser.parse(data, provider: provider)) { error in
                        XCTAssertEqual(error as? MultiProviderParser.ParseError, .noWindows)
                    }
                }
            }
        }
    }

    func testCounterOnlySourceStaysUnavailableInsteadOfShowingFullQuota() async throws {
        let counters = Data(#"[{"usage":{"cost":0,"tokens_input":0,"tokens_output":0}}]"#.utf8)
        let service = MultiUsageService(commandRunner: { _ in
            .init(terminationStatus: 0, stdout: counters, stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll()
        for provider in [ProviderID.codex, .zai, .minimax, .kimi, .deepseek] {
            let section = try XCTUnwrap(snapshot.sections.first { $0.provider == provider })
            XCTAssertTrue(section.windows.isEmpty)
            XCTAssertNotNil(section.failureText)
            XCTAssertNil(section.lowestLeftWindow)
        }
    }
}
