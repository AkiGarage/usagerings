import XCTest
@testable import CodexUsageWidget

final class ServiceRowStateTests: XCTestCase {
    func testSuccessfulEmptyProvidersExplainMissingQuota() throws {
        for provider in ProviderID.allCases {
            let rows = ServiceRowModel.rows(for: ProviderSection(provider: provider, windows: [],
                                                                stats: [], failureText: nil))
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.emptyStateText, "使用量データがありません")
            XCTAssertNil(row.primary)
        }
    }

    func testErrorsAndLoadingKeepTheirSpecificNotice() throws {
        for failure in ["Refreshing", "Usage refresh failed"] {
            let row = try XCTUnwrap(ServiceRowModel.rows(for: ProviderSection(
                provider: .codex, windows: [], stats: [], failureText: failure)).first)
            XCTAssertNil(row.emptyStateText)
            XCTAssertEqual(row.failureText, failure)
        }
    }

    func testZeroQuotaInAnyWindowIsDataRatherThanEmpty() throws {
        for title in ["5h", "Weekly", "Monthly"] {
            let row = try XCTUnwrap(ServiceRowModel.rows(for: ProviderSection(
                provider: .zai, windows: [UsageLimit(title: title, leftPercent: 0, resetText: "Resets tomorrow")],
                stats: [], failureText: nil)).first)
            XCTAssertNil(row.emptyStateText)
            XCTAssertEqual(row.primary?.percentInt, 0)
        }
    }

    func testInformationalStatsSurviveTheEmptyState() throws {
        let row = try XCTUnwrap(ServiceRowModel.rows(for: ProviderSection(
            provider: .grok, windows: [], stats: [ProviderStat(title: "Monthly", valueText: "No monthly cap")],
            failureText: nil)).first)
        XCTAssertEqual(row.notes, ["Monthly: No monthly cap"])
        XCTAssertEqual(row.emptyStateText, "使用量データがありません")
    }
}
