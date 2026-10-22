import AppKit
import XCTest
@testable import CodexUsageWidget

final class DemoModeTests: XCTestCase {
    func testLaunchFlagsAndEnvironmentSelectDemoMode() throws {
        XCTAssertEqual(
            try UsageRingsLaunchOptions.parse(arguments: ["UsageRings", "--usagerings-demo"], environment: [:]),
            UsageRingsLaunchOptions(demoEnabled: true, showcase: false, exportDirectory: nil)
        )
        XCTAssertEqual(
            try UsageRingsLaunchOptions.parse(arguments: ["UsageRings"], environment: ["USAGERINGS_DEMO": "1"]),
            UsageRingsLaunchOptions(demoEnabled: true, showcase: false, exportDirectory: nil)
        )
        XCTAssertEqual(
            try UsageRingsLaunchOptions.parse(arguments: ["UsageRings", "--demo-showcase"], environment: [:]),
            UsageRingsLaunchOptions(demoEnabled: true, showcase: true, exportDirectory: nil)
        )
        XCTAssertEqual(
            try UsageRingsLaunchOptions.parse(arguments: ["UsageRings", "--demo-export", "/tmp/usagerings-demo"], environment: [:]),
            UsageRingsLaunchOptions(demoEnabled: true, showcase: false,
                                    exportDirectory: URL(fileURLWithPath: "/tmp/usagerings-demo", isDirectory: true))
        )
        XCTAssertThrowsError(try UsageRingsLaunchOptions.parse(
            arguments: ["UsageRings", "--demo-export", "relative"], environment: [:]))
    }

    func testFixtureCoversEveryProviderAndCollapsedRingDetail() throws {
        let now = Date().addingTimeInterval(24 * 3_600)
        let snapshot = UsageRingsDemoFixture.snapshot(now: now)

        XCTAssertEqual(snapshot.sections.map(\.provider), ProviderID.allCases)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.codexSnapshot?.session?.leftPercent, 76)
        XCTAssertEqual(snapshot.codexSnapshot?.weekly?.leftPercent, 49)
        let sessionResetText = try XCTUnwrap(snapshot.codexSnapshot?.session?.resetText)
        let sessionResetDate = try XCTUnwrap(RingResetFormat.date(
            fromResetText: sessionResetText, now: now, sourceTimeZone: RingResetFormat.tokyo))
        XCTAssertEqual(sessionResetDate.timeIntervalSince(now.addingTimeInterval(2.4 * 3_600)),
                       0, accuracy: 61)

        let codex = try XCTUnwrap(snapshot.sections.first { $0.provider == .codex })
        XCTAssertNil(codex.codexExtras)
        XCTAssertEqual(codex.forAccount(0).codexExtras?.creditsText, "1,284 credits")
        XCTAssertEqual(codex.forAccount(0).codexExtras?.availableCount, 2)
        XCTAssertEqual(codex.forAccount(0).codexExtras?.tickets.count, 3)
        XCTAssertEqual(codex.forAccount(0).codexExtras?.tickets.compactMap(\.title),
                       ["5時間リセット", "週リセット", "前回リセット"])

        let claude = try XCTUnwrap(snapshot.sections.first { $0.provider == .claude })
        XCTAssertEqual(Set(claude.windows.compactMap(\.accountIndex)), [0, 1])
        XCTAssertEqual(claude.windows.map { RingCardLabel.label(for: $0.title) },
                       ["5時間枠", "週の枠", "5時間枠", "週の枠"])
        XCTAssertEqual(claude.claudeProfileBlocks[1]?.kind, .session)

        let zai = try XCTUnwrap(snapshot.sections.first { $0.provider == .zai })
        guard case let .loaded(tickets) = try XCTUnwrap(zai.zaiResetTickets) else {
            return XCTFail("Expected the demo Z.ai reset tickets")
        }
        XCTAssertEqual(tickets.filter(\.available).count, 2)
        XCTAssertEqual(tickets.filter { !$0.available }.count, 1)

        let bars = CollapsedUsageBar.bars(for: snapshot, blockedPreview: nil)
        XCTAssertEqual(bars.count, 14)
        let accountA = try XCTUnwrap(bars.first { $0.id == "claude-0" })
        XCTAssertTrue(accountA.isWarning)
        let accountB = try XCTUnwrap(bars.first { $0.id == "claude-1" })
        XCTAssertNil(accountB.block)
        XCTAssertFalse(accountB.isBlocked)
        let profileB = try XCTUnwrap(bars.first { $0.id == "claude-profile-1" })
        XCTAssertEqual(profileB.block?.kind, .session)
        XCTAssertTrue(profileB.isBlocked)
        XCTAssertNotNil(RingDetailCardModel.make(bar: profileB, now: now)?.blockText)
        let accountBDetail = try XCTUnwrap(RingDetailCardModel.make(
            bar: accountB, now: now, sourceTimeZone: RingResetFormat.tokyo))
        XCTAssertEqual(accountBDetail.rows.map(\.label), ["5時間枠", "週の枠"])
        XCTAssertEqual(bars.filter { $0.id.hasPrefix("antigravity-") }.count, 3)
        let critical = try XCTUnwrap(bars.first { $0.id == "antigravity-Gemini Models" })
        XCTAssertEqual(critical.limit?.tone, .critical)
        let antigravityCards = bars.filter { $0.id.hasPrefix("antigravity-") }
        for bar in antigravityCards {
            let cardBar = UsageRingsDemoFixture.detailCardBar(for: bar)
            XCTAssertEqual(cardBar.title, bar.title)
            XCTAssertEqual(cardBar.windows.map { RingCardLabel.label(for: $0.title) },
                           ["5時間枠", "週の枠", "5時間枠", "週の枠"])
            let model = try XCTUnwrap(RingDetailCardModel.make(
                bar: cardBar, now: now, sourceTimeZone: RingResetFormat.tokyo))
            XCTAssertTrue(model.title.hasPrefix(bar.title))
        }
        XCTAssertEqual(bars.first { $0.id == "zai" }?.zaiResetTickets, zai.zaiResetTickets)
    }

    @MainActor
    func testDemoPreferencesAndPositionsStayInTheirSuite() throws {
        let productionName = "DemoModeTests.production.\(UUID().uuidString)"
        let demoName = "DemoModeTests.demo.\(UUID().uuidString)"
        let production = try XCTUnwrap(UserDefaults(suiteName: productionName))
        let demo = try XCTUnwrap(UserDefaults(suiteName: demoName))
        defer {
            production.removePersistentDomain(forName: productionName)
            demo.removePersistentDomain(forName: demoName)
        }

        production.set(1.4, forKey: PanelPreferences.zoomKey)
        production.set(0.7, forKey: "panelOffsetX")
        production.set(0.8, forKey: "tabWindowOpacity")
        let mode = try DemoMode.isolated(suiteName: demoName)
        let settings = PanelPreferences(defaults: mode.defaults)
        settings.setZoom(1.5)
        settings.setBarZoom(2)
        settings.orientation = .vertical
        settings.appearance = .dark
        settings.showAccountNames = true
        settings.splitAntigravityAccounts = true
        PanelOffsetStore(defaults: mode.defaults).save(NSSize(width: 36, height: -22))
        TabOriginStore(defaults: mode.defaults).save(NSPoint(x: 1430, y: 420))
        let opacity = SurfaceOpacityPreferences(defaults: mode.defaults)
        opacity.setOpacity(0.55, for: .tab)
        opacity.setOpacity(0.65, for: .panel)

        XCTAssertEqual(PanelPreferences(defaults: mode.defaults).zoom, 1.5)
        XCTAssertEqual(PanelPreferences(defaults: production).zoom, 1.4)
        XCTAssertEqual(PanelOffsetStore(defaults: mode.defaults).load(), NSSize(width: 36, height: -22))
        XCTAssertEqual(TabOriginStore(defaults: mode.defaults).load(), NSPoint(x: 1430, y: 420))
        XCTAssertEqual(opacity.opacity(for: .tab), 0.55, accuracy: 0.001)
        XCTAssertEqual(opacity.opacity(for: .panel), 0.65, accuracy: 0.001)
        XCTAssertEqual(production.double(forKey: "panelOffsetX"), 0.7, accuracy: 0.001)
        XCTAssertEqual(production.double(forKey: "tabWindowOpacity"), 0.8, accuracy: 0.001)
        XCTAssertNil(production.object(forKey: PanelPreferences.barZoomKey))
        XCTAssertNil(production.object(forKey: PanelPreferences.orientationKey))
        XCTAssertNil(production.object(forKey: PanelPreferences.appearanceKey))
        XCTAssertNil(production.object(forKey: PanelPreferences.showAccountNamesKey))
        XCTAssertNil(production.object(forKey: PanelPreferences.splitAntigravityAccountsKey))
        XCTAssertTrue(PanelPreferences(defaults: mode.defaults).splitAntigravityAccounts)
    }

    @MainActor
    func testDemoPersonaForcesFixtureAndRefreshCannotPublishSnapshots() throws {
        let mode = try DemoMode.isolated(suiteName: "DemoModeTests.persona.\(UUID().uuidString)")
        let persona = makeAppPersona(for: .single, demoMode: mode)
        XCTAssertTrue(persona is MultiProviderPersona)

        let fixture = UsageRingsDemoFixture.snapshot()
        let store = MultiUsageStore(demoSnapshot: fixture)
        XCTAssertFalse(store.snapshotPublishingIsEnabled)
        XCTAssertEqual(store.snapshot, fixture)
        store.refresh()
        store.refresh()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot, fixture)
        XCTAssertFalse(store.snapshotPublishingIsEnabled)
    }
}
