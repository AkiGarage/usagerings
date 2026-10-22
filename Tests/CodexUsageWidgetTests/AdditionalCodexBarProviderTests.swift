import XCTest
@testable import CodexUsageWidget

// Synthetic normalized CodexBar payloads; no saved credentials or account data.
enum AdditionalCodexBarFixtures {
    static func quota(_ provider: String) -> String {
        """
        [{"provider":"\(provider)","usage":{
          "primary":{"usedPercent":28,"windowMinutes":10080},
          "secondary":{"usedPercent":12,"windowMinutes":300}}}]
        """
    }
    static let balance = #"[{"provider":"deepseek","usage":{"primary":{"usedPercent":0,"windowMinutes":null,"resetDescription":"$23.50 (Paid: $20.00 / Granted: $3.50)"},"details":[{"title":"Usage","rows":[{"label":"Today","value":"$0.12 · 12,000 tokens"},{"label":"This month","value":"$1.23 · 123,000 tokens"},{"label":"Requests","value":"42"},{"label":"Account","value":"synthetic-private-label"}]}]}}]"#
}

final class AdditionalCodexBarProviderTests: XCTestCase {
    func testMiniMaxAndKimiUseReportedWindowDurations() throws {
        for provider in [ProviderID.minimax, .kimi] {
            let section = try MultiProviderParser.parse(Data(AdditionalCodexBarFixtures.quota(provider.rawValue).utf8), provider: provider)
            XCTAssertEqual(section.windows.map(\.title), ["Weekly", "5h"])
            XCTAssertEqual(section.windows.map(\.leftPercent), [72, 88])
            XCTAssertEqual(ServiceRowModel.rows(for: section).first?.name, provider.displayName)
            XCTAssertFalse(section.windows.contains { $0.title == "Monthly" })
        }
    }

    func testDeepSeekBalanceSentinelNeverBecomesPercentageOrReset() throws {
        for percent in [0, 100] {
            let json = AdditionalCodexBarFixtures.balance.replacingOccurrences(of: "\"usedPercent\":0", with: "\"usedPercent\":\(percent)")
            let section = try MultiProviderParser.parse(Data(json.utf8), provider: .deepseek)
            XCTAssertTrue(section.windows.isEmpty)
            XCTAssertEqual(section.stats.map(\.title), ["Balance", "Today", "This month", "Requests"])
            XCTAssertFalse(section.stats.contains { $0.valueText.contains("synthetic-private-label") })
            let row = try XCTUnwrap(ServiceRowModel.rows(for: section).first)
            XCTAssertNil(row.primary)
            XCTAssertNil(row.emptyStateText)
            let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: Date())
            let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "deepseek" })
            XCTAssertNil(bar.limit)
            let card = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: Date()))
            XCTAssertTrue(card.rows.isEmpty)
            XCTAssertNil(card.resetText)
            XCTAssertEqual(card.stats, section.stats)
            XCTAssertTrue(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: [row]).contains("Balance: $23.50"))
        }
    }

    func testDeepSeekWithoutReadableBalanceOrUsageIsUnavailable() {
        let json = #"[{"provider":"deepseek","usage":{"primary":{"usedPercent":0}}}]"#
        XCTAssertThrowsError(try MultiProviderParser.parse(Data(json.utf8), provider: .deepseek))
    }

    func testNewProvidersUseCodexBarAndFailuresStayIsolated() async throws {
        let service = MultiUsageService(commandRunner: { arguments in
            let provider = arguments[2]
            XCTAssertEqual(Array(arguments.prefix(5)), ["usage", "--provider", provider, "--format", "json"])
            if provider == "kimi" {
                return .init(terminationStatus: 1, stdout: Data(), stderr: Data("synthetic-private-error".utf8))
            }
            let json = provider == "deepseek" ? AdditionalCodexBarFixtures.balance : AdditionalCodexBarFixtures.quota(provider)
            return .init(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll()
        XCTAssertEqual(snapshot.sections.map(\.provider), MultiUsageSnapshot.displayOrder)
        for provider in [ProviderID.minimax, .deepseek] {
            XCTAssertNil(snapshot.sections.first { $0.provider == provider }?.failureText)
        }
        let kimi = try XCTUnwrap(snapshot.sections.first { $0.provider == .kimi })
        XCTAssertNotNil(kimi.failureText)
        XCTAssertFalse(kimi.failureText!.contains("synthetic-private-error"))
        XCTAssertTrue(kimi.windows.isEmpty)
    }

    func testDemoUsesRealWindowKindsAndBalanceOnlyForDeepSeek() throws {
        let snapshot = UsageRingsDemoFixture.snapshot()
        for provider in [ProviderID.minimax, .kimi] {
            let section = try XCTUnwrap(snapshot.sections.first { $0.provider == provider })
            XCTAssertEqual(section.windows.map(\.title), ["Weekly"])
        }
        let deepseek = try XCTUnwrap(snapshot.sections.first { $0.provider == .deepseek })
        XCTAssertTrue(deepseek.windows.isEmpty)
        XCTAssertEqual(deepseek.stats.first?.title, "Balance")
    }
}
