import XCTest
@testable import CodexUsageWidget

final class CodexBarAccountScopeTests: XCTestCase {
    static let antigravityCLIPayload = #"[{"provider":"antigravity","rateWindowLabels":{"secondary":"Claude and GPT","primary":"Gemini Models"},"usage":{"secondary":{"resetsAt":"2026-11-09T19:36:51Z","usedPercent":0,"windowMinutes":300},"tertiary":null,"updatedAt":"2026-11-09T14:36:52Z","identity":{"providerID":"antigravity"},"extraRateWindows":[{"id":"antigravity-quota-summary-gemini-5h","title":"Gemini 5-hour","window":{"windowMinutes":300,"resetsAt":"2026-11-09T19:36:51Z","usedPercent":0}},{"id":"antigravity-quota-summary-gemini-weekly","title":"Gemini weekly","window":{"windowMinutes":10080,"resetsAt":"2026-11-14T01:23:28Z","usedPercent":2.587026357650757}},{"id":"antigravity-quota-summary-3p-5h","title":"Claude/GPT 5-hour","window":{"windowMinutes":300,"resetsAt":"2026-11-09T19:36:51Z","usedPercent":0}},{"id":"antigravity-quota-summary-3p-weekly","title":"Claude/GPT weekly","window":{"windowMinutes":10080,"resetsAt":"2026-11-16T14:36:51Z","usedPercent":0}},{"id":"antigravity-quota-summary-gemini-argon-wtu-weekly","title":"Gemini 4 Argon weekly","window":{"windowMinutes":10080,"resetsAt":"2026-11-16T04:54:07Z","usedPercent":1.164335012435913}}],"primary":{"resetsAt":"2026-11-14T01:23:28Z","usedPercent":2.587026357650757,"windowMinutes":10080}},"source":"cli"}]"#

    static let localLoginRejection = #"[{"provider":"antigravity","source":"cli","error":{"kind":"provider","message":"Antigravity CLI uses its local login and cannot select saved Google accounts. Use --source auto or --source oauth with account selection.","code":1}}]"#

    static func codexBar0820(_ arguments: [String]) -> CodexUsageService.CommandResult {
        let provider = arguments[2]
        let cliSource = arguments.firstIndex(of: "--source").map { arguments[$0 + 1] } == "cli"
        if provider == "antigravity" {
            if cliSource, arguments.contains("--all-accounts") {
                return .init(terminationStatus: 1, stdout: Data(localLoginRejection.utf8), stderr: Data())
            }
            return .init(terminationStatus: 0, stdout: Data(antigravityCLIPayload.utf8), stderr: Data())
        }
        return .init(terminationStatus: 0, stdout: Data("[]".utf8), stderr: Data())
    }

    func testCLISourceProvidersReadTheirLocalLoginWithoutSavedAccountSelection() {
        for provider in ProviderID.allCases {
            let arguments = MultiUsageService.usageArguments(provider)
            let usesCLISource = MultiUsageService.sourceArguments(provider) == ["--source", "cli"]
            XCTAssertEqual(MultiUsageService.accountScope(provider) == .localLogin, usesCLISource, provider.rawValue)
            XCTAssertEqual(arguments.contains("--all-accounts"), !usesCLISource, provider.rawValue)
            XCTAssertEqual(Array(arguments.prefix(5)), ["usage", "--provider", provider.rawValue, "--format", "json"])
        }
    }

    func testAntigravityShowsAllQuotaGroupsAgainstCodexBar0820() async throws {
        let service = MultiUsageService(commandRunner: Self.codexBar0820, retryDelay: 0)
        let snapshot = await service.fetchAll(now: Date(timeIntervalSince1970: 1_794_236_212))
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .antigravity })
        XCTAssertNil(section.failureText)
        XCTAssertGreaterThanOrEqual(section.windows.count, 5)
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(Set(rows.map(\.name)), ["Argon", "Gemini", "Claude/GPT"])
        let rings = CollapsedUsageBar.bars(for: snapshot, accountPreferences: AccountPreferences()).filter { $0.provider == .antigravity }
        XCTAssertEqual(rings.count, 3)
        XCTAssertTrue(rings.allSatisfy { $0.limit != nil })
        for row in rows {
            XCTAssertNil(row.failureText, row.name)
            XCTAssertNotNil(row.week, row.name)
        }
    }

    func testNonCodexStructuredErrorsKeepKindAndCodeButRedactTheMessage() {
        let stdout = Data(#"[{"provider":"minimax","source":"auto","error":{"kind":"provider","message":"synthetic-sensitive-message","code":1}}]"#.utf8)
        let error = CodexUsageError.commandFailure(exitCode: 1, stdout: stdout, stderr: Data(), provider: .minimax)
        XCTAssertEqual(error, .commandFailed(1, "MiniMax provider error (provider, code 1)"))
        XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-message"))
        XCTAssertFalse(error.localizedDescription.contains("no structured error details"))
    }
}
