import XCTest
@testable import CodexUsageWidget

final class MultiAccountProviderTests: XCTestCase {
    private func fetchCodex(_ json: String, status: Int32 = 0) async -> MultiUsageSnapshot {
        let service = MultiUsageService(commandRunner: { arguments in
            if arguments[2] == "codex" {
                XCTAssertTrue(arguments.contains("--all-accounts"))
                return .init(terminationStatus: status, stdout: Data(json.utf8), stderr: Data())
            }
            XCTAssertFalse(arguments.contains("--all-accounts"))
            return .init(terminationStatus: 0, stdout: Data("[]".utf8), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        return await service.fetchAll()
    }

    private static let first = #"{"provider":"codex","usage":{"accountEmail":"sample-one@example.test","primary":{"usedPercent":20},"secondary":{"usedPercent":40}},"credits":{"remaining":123}}"#
    private static let second = #"{"provider":"codex","usage":{"accountEmail":"sample-two@example.test","primary":{"usedPercent":60},"secondary":{"usedPercent":10}},"credits":{"remaining":456}}"#

    func testCodexAccountsKeepWindowsCreditsAndHoverCardsSeparate() async throws {
        let snapshot = await fetchCodex("[\(Self.first),\(Self.second)]")
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .codex })
        XCTAssertEqual(section.accountIndices, [0, 1])
        XCTAssertEqual(snapshot.codexSnapshot?.session?.leftPercent, 80)
        let rows = ServiceRowModel.rows(for: section, showAccounts: true)
        XCTAssertEqual(rows.map(\.id), ["codex-0", "codex-1"])
        XCTAssertEqual(rows.map(\.name), ["Codex A", "Codex B"])
        XCTAssertEqual(rows.map { $0.five?.leftPercent }, [80, 40])
        XCTAssertEqual(rows.map { $0.week?.leftPercent }, [60, 90])
        XCTAssertEqual(rows.map(\.chips), [["123 credits"], ["456 credits"]])
        // Identical masked labels must not merge distinct accounts.
        XCTAssertEqual(rows.map(\.account), ["sam***@e***", "sam***@e***"])
        XCTAssertTrue(ServiceRowModel.rows(for: section).allSatisfy { $0.account == nil })
        let bars = CollapsedUsageBar.bars(for: snapshot).filter { $0.id.hasPrefix("codex-") }
        XCTAssertEqual(bars.map(\.id), rows.map(\.id))
        XCTAssertEqual(bars.map { $0.codexExtras?.creditsText }, ["123 credits", "456 credits"])
        for (bar, row) in zip(bars, rows) {
            let arcs = MultiCollapsedUsageView.g1(for: bar, rows: rows)
            XCTAssertEqual(arcs.outer, row.five)
            XCTAssertEqual(arcs.inner, row.week)
            XCTAssertEqual(bar.windows.count, 2)
            let card = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: Date()))
            XCTAssertEqual(card.extras?.creditsText, bar.codexExtras?.creditsText)
        }
    }

    func testCodexFailedAccountKeepsItsRowWithoutHidingHealthyAccount() async throws {
        let failure = #"{"provider":"codex","error":{"message":"synthetic-private-error"}}"#
        let snapshot = await fetchCodex("[\(failure),\(Self.second)]", status: 1)
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .codex })
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.map(\.name), ["Codex A", "Codex B"])
        XCTAssertNotNil(rows[0].failureText)
        XCTAssertFalse(rows[0].failureText!.contains("synthetic-private-error"))
        XCTAssertNil(rows[0].primary)
        XCTAssertNil(rows[1].failureText)
        XCTAssertEqual(rows[1].five?.leftPercent, 40)
        XCTAssertNil(snapshot.codexSnapshot)
        XCTAssertEqual(rows[1].chips, ["456 credits"])
    }

    func testSingleAccountCodexAndGrokRetainTheirNamesAndIDs() async throws {
        let snapshot = await fetchCodex("[\(Self.first)]")
        let codex = try XCTUnwrap(snapshot.sections.first { $0.provider == .codex })
        let grok = ProviderSection(provider: .grok,
                                   windows: [UsageLimit(title: "Account · Weekly", leftPercent: 75, resetText: "Reset pending")],
                                   stats: [], failureText: nil, accounts: [ProviderAccount(index: 0)])
        let single = MultiUsageSnapshot(sections: [codex, grok], codexSnapshot: nil, updatedAt: Date())
        let rows = ServiceRowModel.rows(for: single)
        XCTAssertEqual(rows.map(\.id), ["codex-main", "grok-main"])
        XCTAssertEqual(rows.map(\.name), ["Codex", "Grok"])
        let bars = CollapsedUsageBar.bars(for: single).filter { $0.id == "codex" || $0.id == "grok" }
        XCTAssertEqual(bars.map(\.label), ["C", "X"])
        XCTAssertEqual(bars.map(\.title), ["Codex", "Grok"])
        XCTAssertEqual(bars[0].codexExtras?.creditsText, "123 credits")
    }

    func testGrokMissingQuotaAndNoticesStayWithTheirAccount() {
        var weekly = UsageLimit(title: "Account · Weekly", leftPercent: 75, resetText: "Reset pending")
        weekly.accountIndex = 1
        let section = ProviderSection(provider: .grok, windows: [weekly],
                                      stats: [ProviderStat(title: "Account · Grok Weekly", valueText: "rate limited", accountIndex: 0)],
                                      failureText: "Some accounts unavailable",
                                      accounts: [ProviderAccount(index: 0, failureText: "Usage unavailable"), ProviderAccount(index: 1)])
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.map(\.name), ["Grok A", "Grok B"])
        XCTAssertNil(rows[0].primary)
        XCTAssertEqual(rows[0].failureText, "Usage unavailable")
        XCTAssertEqual(rows[0].notes, ["Grok Weekly: rate limited"])
        XCTAssertEqual(rows[1].week?.leftPercent, 75)
        XCTAssertNil(rows[1].failureText)
        XCTAssertTrue(rows[1].notes.isEmpty)
    }

    func testDemoIncludesMultipleCodexAndGrokAccountsWithoutInventingMonthlyQuota() throws {
        let snapshot = UsageRingsDemoFixture.snapshot()
        for provider in [ProviderID.codex, .grok] {
            let section = try XCTUnwrap(snapshot.sections.first { $0.provider == provider })
            XCTAssertEqual(section.accountIndices, [0, 1])
            XCTAssertEqual(ServiceRowModel.rows(for: section).count, 2)
        }
        let grok = try XCTUnwrap(snapshot.sections.first { $0.provider == .grok })
        XCTAssertTrue(grok.windows.allSatisfy { $0.title == "Weekly" })
        XCTAssertFalse(grok.stats.contains { $0.title.contains("Monthly") })
    }
}
