import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class AntigravityAccountTests: XCTestCase {
    private var fixture: MultiUsageSnapshot { UsageRingsDemoFixture.snapshot() }

    func testDefaultGroupsStayMergedAndOptInSeparatesEveryWindow() throws {
        let section = try XCTUnwrap(fixture.sections.first { $0.provider == .antigravity })
        let merged = ServiceRowModel.rows(for: section)
        XCTAssertEqual(merged.map(\.name), ["Argon", "Gemini", "Claude/GPT"])
        XCTAssertEqual(merged.flatMap { [$0.five, $0.week].compactMap { $0 } + $0.extras }.count, 12)
        XCTAssertEqual(CollapsedUsageBar.bars(for: fixture).filter { $0.id.hasPrefix("antigravity-") }.count, 3)

        let rows = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true)
        XCTAssertEqual(rows.map(\.name), ["Argon A", "Gemini A", "Claude/GPT A", "Argon B", "Gemini B", "Claude/GPT B"])
        XCTAssertEqual(rows.compactMap { $0.five?.leftPercent }, [87, 18, 38, 64, 69, 57])
        XCTAssertEqual(rows.compactMap { $0.week?.leftPercent }, [73, 52, 27, 44, 81, 62])
        XCTAssertTrue(rows.allSatisfy { $0.extras.isEmpty && $0.account == nil })
        let bars = CollapsedUsageBar.bars(for: fixture, splitAntigravityAccounts: true)
            .filter { $0.id.hasPrefix("antigravity-") }
        XCTAssertEqual(bars.map(\.id), rows.map(\.id))
        for (bar, row) in zip(bars, rows) {
            XCTAssertEqual(Set(bar.windows.compactMap(\.accountIndex)).count, 1)
            let arcs = MultiCollapsedUsageView.g1(for: bar, rows: rows)
            XCTAssertEqual(arcs.outer, row.five)
            XCTAssertEqual(arcs.inner, row.week)
            let card = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: fixture.updatedAt))
            XCTAssertEqual(card.rows.map(\.leftPercent), bar.windows.map(\.leftPercent))
            XCTAssertEqual(card.rows.map(\.label), ["5時間枠", "週の枠"])
            XCTAssertTrue(["5時間枠", "週の枠"].contains(card.resetLabel ?? ""))
            XCTAssertTrue(card.title.contains(bar.title))
        }
    }

    func testSingleAccountKeepsExistingNamesIDsAndValuesWithOptionEnabled() throws {
        let section = try XCTUnwrap(fixture.sections.first { $0.provider == .antigravity }).forAccount(1)
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: fixture.updatedAt)
        let merged = ServiceRowModel.rows(for: section)
        let split = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true)
        XCTAssertEqual(split.map(\.id), merged.map(\.id))
        XCTAssertEqual(split.map(\.name), merged.map(\.name))
        XCTAssertEqual(split.map(\.five), merged.map(\.five))
        XCTAssertEqual(CollapsedUsageBar.bars(for: snapshot, splitAntigravityAccounts: true).map(\.id),
                       CollapsedUsageBar.bars(for: snapshot).map(\.id))
    }

    func testGroupAliasesResolveToTheirOwnAccountRings() {
        var section = fixture.sections.first { $0.provider == .antigravity }!
        section.windows = section.windows.map { window in
            var copy = UsageLimit(title: window.title.uppercased(), leftPercent: window.leftPercent,
                                  resetText: window.resetText)
            copy.accountIndex = window.accountIndex
            return copy
        }
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: fixture.updatedAt)
        let rows = ServiceRowModel.rows(for: snapshot, splitAntigravityAccounts: true)
        for bar in CollapsedUsageBar.bars(for: snapshot, splitAntigravityAccounts: true)
            where bar.id.hasPrefix("antigravity-") {
            let row = MultiCollapsedUsageView.weekly(for: bar, rows: rows)
            XCTAssertEqual(row?.id, bar.id)
            XCTAssertEqual(row?.five?.accountIndex, bar.windows.first?.accountIndex)
        }
    }

    func testProxyKeepsFailedAccountAndScopesItsNotice() async throws {
        let client = CLIProxyClient(transport: AntigravityAccountsTransport(), keyProvider: FixtureCLIProxyKey())
        let sections = await client.fetchSections()
        let section = try XCTUnwrap(sections.first { $0.provider == .antigravity })
        XCTAssertEqual(section.accountIndices, [0, 1])
        XCTAssertEqual(section.windows.map(\.accountIndex), [0, 0])
        XCTAssertNil(section.forAccount(0).failureText)
        XCTAssertTrue(section.forAccount(0).stats.isEmpty)
        XCTAssertNotNil(section.forAccount(1).failureText)
        XCTAssertEqual(section.stats.map(\.accountIndex), [1])
        let rows = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true)
        XCTAssertEqual(rows.map(\.name), ["Argon A", "Antigravity B"])
        XCTAssertNil(rows[0].failureText)
        XCTAssertNil(rows[1].primary)
        XCTAssertNotNil(rows[1].failureText)
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: Date())
        let failedBars = CollapsedUsageBar.bars(for: snapshot, splitAntigravityAccounts: true)
            .filter { $0.id.hasPrefix("antigravity-1-") }
        XCTAssertEqual(failedBars.count, 3)
        XCTAssertTrue(failedBars.allSatisfy { $0.limit == nil && $0.windows.isEmpty })
        for bar in failedBars {
            let card = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: Date()))
            XCTAssertEqual(card.failureText, section.forAccount(1).failureText)
            XCTAssertTrue(card.rows.isEmpty)
            XCTAssertEqual(MultiCollapsedUsageView.accessibilitySummary(for: bar, rows: rows),
                           "\(bar.ringName): \(card.failureText!)")
        }
    }

    func testProxyAssignsTwoSuccessfulAccountsTheirOwnQuota() async throws {
        let client = CLIProxyClient(transport: AntigravityAccountsTransport(secondAccountHasProject: true),
                                    keyProvider: FixtureCLIProxyKey())
        let sections = await client.fetchSections()
        let section = try XCTUnwrap(sections.first { $0.provider == .antigravity })
        XCTAssertEqual(section.accountIndices, [0, 1])
        XCTAssertEqual(section.windows.map(\.accountIndex), [0, 0, 1, 1])
        XCTAssertEqual(section.forAccount(0).windows.map(\.leftPercent), [80, 60])
        XCTAssertEqual(section.forAccount(1).windows.map(\.leftPercent), [30, 90])
        XCTAssertTrue(section.accounts.allSatisfy { $0.failureText == nil })
        let rows = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true)
        XCTAssertEqual(rows.map(\.name), ["Argon A", "Argon B"])
        XCTAssertEqual(rows.map { $0.five?.leftPercent }, [80, 30])
        XCTAssertEqual(rows.map { $0.week?.leftPercent }, [60, 90])
    }

    @MainActor
    func testPreferenceDefaultsOffAndContextMenuPersistsBothStates() throws {
        let suite = "AntigravityAccountTests.\(UUID().uuidString)"
        let mode = try DemoMode.isolated(suiteName: suite)
        defer { mode.defaults.removePersistentDomain(forName: suite) }
        let persona = MultiProviderPersona(demoMode: mode)
        let preferences = try XCTUnwrap(persona.panelPreferences)
        XCTAssertFalse(preferences.splitAntigravityAccounts)
        let delegate = AppDelegate(persona: persona, demoMode: mode)
        for enabled in [true, false] {
            let menu = try XCTUnwrap(delegate.makeTabMenu().item(withTitle: "表示")?.submenu)
            let item = try XCTUnwrap(menu.item(withTitle: "Antigravityをアカウント別に表示"))
            XCTAssertEqual(item.state, enabled ? .off : .on)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(preferences.splitAntigravityAccounts, enabled)
            XCTAssertEqual(PanelPreferences(defaults: mode.defaults).splitAntigravityAccounts, enabled)
            XCTAssertFalse(preferences.showAccountNames)
        }
    }

    @MainActor
    func testToggleResizesOffscreenTabAndKeepsEveryRingHittable() async throws {
        let suite = "AntigravityAccountTests.geometry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(demoSnapshot: fixture)
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 37
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation, preferences: preferences))
        host.sizingOptions = []
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: MultiCollapsedUsageView.size(for: fixture, menuBarHeight: 37)),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        func render() throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        try render()
        for (orientation, split) in [(PanelOrientation.horizontal, true), (.vertical, true), (.vertical, false)] {
            let expected = MultiCollapsedUsageView.size(for: fixture, menuBarHeight: 37,
                                                        orientation: orientation, splitAntigravityAccounts: split)
            let resized = expectation(description: "Option reaches native tab size")
            presentation.onSizeChange = {
                if presentation.collapsedSize == expected { resized.fulfill() }
            }
            preferences.orientation = orientation
            preferences.splitAntigravityAccounts = split
            try render()
            await fulfillment(of: [resized], timeout: 2)
            XCTAssertEqual(presentation.collapsedSize, expected)
            let bars = CollapsedUsageBar.bars(for: fixture, splitAntigravityAccounts: split)
            let layout = MultiCollapsedUsageView.layout(barZoom: 1, menuBarThickness: 37)
            for index in bars.indices {
                let frame = try XCTUnwrap(MultiCollapsedUsageView.ringFrame(index: index, size: expected,
                    layout: layout, count: bars.count, orientation: orientation))
                XCTAssertEqual(MultiCollapsedUsageView.ringIndex(at: CGPoint(x: frame.midX, y: frame.midY),
                    size: expected, layout: layout, count: bars.count, orientation: orientation), index)
            }
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    @MainActor
    func testOptionChangeClearsHoverHighlightForObsoleteGroupID() throws {
        let suite = "AntigravityAccountTests.hover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(demoSnapshot: fixture)
        let presentation = EdgeTabPresentationState()
        let controller = RingDetailCardController()
        controller.attach(store: store, preferences: preferences, presentation: presentation)
        controller.highlight.barID = "antigravity-Gemini Models"
        preferences.splitAntigravityAccounts = true
        XCTAssertNil(controller.highlight.barID)
        controller.highlight.barID = "antigravity-1-Gemini Models"
        preferences.splitAntigravityAccounts = false
        XCTAssertNil(controller.highlight.barID)
    }
}

private struct AntigravityAccountsTransport: CLIProxyTransport {
    var secondAccountHasProject = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "credentials" {
            let secondProject = secondAccountHasProject ? #", "project_id":"fixture-project-b""# : ""
            let credentials = """
            {"files":[{"provider":"antigravity","auth_index":"a1","email":"same@example.test","project_id":"fixture-project"},
                      {"provider":"antigravity","auth_index":"a2","email":"same@example.test"\(secondProject)},
                      {"provider":"antigravity","auth_index":"a3","disabled":true}]}
            """
            return (Data(credentials.utf8), 200)
        }
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        let account = body?["authIndex"] as? String
        XCTAssertTrue(account == "a1" || (secondAccountHasProject && account == "a2"))
        let five = account == "a1" ? 0.8 : 0.3
        let week = account == "a1" ? 0.6 : 0.9
        return (CLIProxyFixtures.envelope("""
            {"groups":[{"displayName":"Gemini 4 Argon","buckets":[
            {"displayName":"5h","remainingFraction":\(five)},{"displayName":"Weekly","remainingFraction":\(week)}]}]}
            """), 200)
    }
}
