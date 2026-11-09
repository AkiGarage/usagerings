import XCTest
@testable import CodexUsageWidget

final class DeepSeekEmptyBalanceTests: XCTestCase {
    static let emptyBalance = #"[{"source":"web","provider":"deepseek","rateWindowLabels":{"primary":"Balance"},"usage":{"primary":{"resetDescription":"$0.00 — add credits at platform.deepseek.com","usedPercent":100},"secondary":null,"tertiary":null,"updatedAt":"2026-11-09T14:43:28Z","identity":{"providerID":"deepseek"},"details":[{"title":"Usage","rows":[{"label":"Today","value":"— · 0 tokens"},{"label":"Last 30 days","value":"$0.0000 · 0 tokens"},{"label":"Requests","value":"0"}]}]}}]"#

    func testEmptyBalanceStillShowsTheBalanceAndUsageRows() throws {
        let section = try MultiProviderParser.parse(Data(Self.emptyBalance.utf8), provider: .deepseek)
        XCTAssertEqual(section.stats.first?.title, "Balance")
        XCTAssertEqual(section.stats.first?.valueText, "$0.00 — add credits at platform.deepseek.com")
        XCTAssertTrue(section.windows.isEmpty)
    }

    func testEmptyBalanceSurvivesTheServiceFallbackFromSavedAccounts() async throws {
        let service = MultiUsageService(commandRunner: { arguments in
            guard arguments[2] == "deepseek" else { return .init(terminationStatus: 0, stdout: Data("[]".utf8), stderr: Data()) }
            if arguments.contains("--all-accounts") {
                let none = #"[{"source":"auto","error":{"code":1,"kind":"provider","message":"No token accounts configured for deepseek."},"provider":"deepseek"}]"#
                return .init(terminationStatus: 1, stdout: Data(none.utf8), stderr: Data())
            }
            return .init(terminationStatus: 0, stdout: Data(Self.emptyBalance.utf8), stderr: Data())
        }, retryDelay: 0)
        let snapshot = await service.fetchAll()
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .deepseek })
        XCTAssertNil(section.failureText)
        XCTAssertEqual(section.stats.first?.title, "Balance")
    }
}
