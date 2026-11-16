import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class RingVisibilityTests: XCTestCase {
    private func makeDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "RingVisibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    @MainActor
    func testAntigravityGroupVisibilityDefaultsAndPersistence() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PanelPreferences(defaults: defaults)
        for group in ServiceRowModel.antigravityGroupNames {
            XCTAssertTrue(preferences.isAntigravityGroupVisible(group))
        }
        XCTAssertTrue(preferences.hiddenAntigravityGroups.isEmpty)

        preferences.setAntigravityGroupVisible(false, for: "Gemini 4 Argon")
        XCTAssertFalse(preferences.isAntigravityGroupVisible("Gemini 4 Argon"))
        XCTAssertTrue(preferences.isAntigravityGroupVisible("Gemini Models"))
        XCTAssertTrue(preferences.isAntigravityGroupVisible("Claude and GPT models"))
        XCTAssertEqual(defaults.stringArray(forKey: PanelPreferences.hiddenAntigravityGroupsKey),
                       ["Gemini 4 Argon"])

        let reloaded = PanelPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.isAntigravityGroupVisible("Gemini 4 Argon"))
        XCTAssertTrue(reloaded.isAntigravityGroupVisible("Gemini Models"))

        reloaded.setAntigravityGroupVisible(true, for: "Gemini 4 Argon")
        XCTAssertTrue(reloaded.isAntigravityGroupVisible("Gemini 4 Argon"))
        XCTAssertEqual(defaults.stringArray(forKey: PanelPreferences.hiddenAntigravityGroupsKey), [])
    }

    @MainActor
    func testShowAllRingsRestoresAllProvidersAndAntigravityGroups() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = PanelPreferences(defaults: defaults)
        for provider in MultiUsageSnapshot.displayOrder {
            preferences.setProviderVisible(false, for: provider)
        }
        for group in ServiceRowModel.antigravityGroupNames {
            preferences.setAntigravityGroupVisible(false, for: group)
        }

        var callbackValues: [Bool] = []
        preferences.onProviderVisibilityChange = { turnedOn in
            callbackValues.append(turnedOn)
        }

        preferences.showAllRings()

        for provider in MultiUsageSnapshot.displayOrder {
            XCTAssertTrue(preferences.isProviderVisible(provider))
        }
        for group in ServiceRowModel.antigravityGroupNames {
            XCTAssertTrue(preferences.isAntigravityGroupVisible(group))
        }
        XCTAssertTrue(preferences.hiddenAntigravityGroups.isEmpty)
        XCTAssertEqual(callbackValues, [true])

        // Calling again when everything is already visible is a no-op.
        preferences.showAllRings()
        XCTAssertEqual(callbackValues, [true])
    }

    @MainActor
    func testShowAllRingsKeepsUndecidedProvidersAutomatic() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PanelPreferences(defaults: defaults)
        preferences.setProviderVisible(false, for: .zai)
        preferences.showAllRings()
        XCTAssertTrue(preferences.isProviderVisible(.zai))
        XCTAssertNil(preferences.providerVisibility[ProviderID.kimi.rawValue])
    }

    @MainActor
    func testCollapsedBarsExcludeHiddenAntigravityGroups() {
        let snapshot = UsageRingsDemoFixture.snapshot()
        let baseline = CollapsedUsageBar.bars(for: snapshot)
        let baselineAntigravity = baseline.filter { $0.provider == .antigravity }
        XCTAssertFalse(baselineAntigravity.isEmpty)

        let hidden: Set<String> = ["Gemini 4 Argon"]
        let filtered = CollapsedUsageBar.bars(for: snapshot, hiddenAntigravityGroups: hidden)
        let filteredAntigravity = filtered.filter { $0.provider == .antigravity }

        XCTAssertLessThan(filteredAntigravity.count, baselineAntigravity.count)
        XCTAssertFalse(filteredAntigravity.contains { $0.id.hasSuffix("Gemini 4 Argon") })
        XCTAssertTrue(filteredAntigravity.contains { $0.id.hasSuffix("Gemini Models") })
        XCTAssertTrue(filteredAntigravity.contains { $0.id.hasSuffix("Claude and GPT models") })

        let splitFiltered = CollapsedUsageBar.bars(for: snapshot,
                                                   splitAntigravityAccounts: true,
                                                   hiddenAntigravityGroups: hidden)
        let splitAntigravity = splitFiltered.filter { $0.provider == .antigravity }
        XCTAssertFalse(splitAntigravity.contains { $0.id.hasSuffix("Gemini 4 Argon") })

        let allHidden = CollapsedUsageBar.bars(for: snapshot,
                                               hiddenAntigravityGroups: Set(ServiceRowModel.antigravityGroupNames))
        XCTAssertTrue(allHidden.filter { $0.provider == .antigravity }.isEmpty)
    }

    @MainActor
    func testAllRingsHiddenProducesNonEmptyCollapsedSurfaceWithoutCrash() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let allGroups = Set(ServiceRowModel.antigravityGroupNames)
        let hiddenSnapshot = MultiUsageSnapshot(sections: [],
                                                codexSnapshot: nil,
                                                updatedAt: Date(),
                                                hiddenProviders: Set(ProviderID.allCases))
        let bars = CollapsedUsageBar.bars(for: hiddenSnapshot, hiddenAntigravityGroups: allGroups)
        XCTAssertTrue(bars.isEmpty)

        let horizontalSize = MultiCollapsedUsageView.size(for: hiddenSnapshot,
                                                          orientation: .horizontal,
                                                          hiddenAntigravityGroups: allGroups)
        XCTAssertGreaterThan(horizontalSize.width, 0)
        XCTAssertGreaterThan(horizontalSize.height, 0)

        let verticalSize = MultiCollapsedUsageView.size(for: hiddenSnapshot,
                                                        orientation: .vertical,
                                                        hiddenAntigravityGroups: allGroups)
        XCTAssertGreaterThan(verticalSize.width, 0)
        XCTAssertGreaterThan(verticalSize.height, 0)

        let layout = MultiCollapsedUsageView.layout(barZoom: 1, menuBarThickness: 24)
        XCTAssertNil(MultiCollapsedUsageView.ringFrame(index: 0,
                                                       size: horizontalSize,
                                                       layout: layout,
                                                       count: 0,
                                                       orientation: .horizontal))
        XCTAssertNil(MultiCollapsedUsageView.ringIndex(at: CGPoint(x: 5, y: 5),
                                                       size: horizontalSize,
                                                       layout: layout,
                                                       count: 0,
                                                       orientation: .horizontal))

        let collapsedHost = NSHostingView(rootView: MultiCollapsedUsageView(snapshot: hiddenSnapshot,
                                                                            hiddenAntigravityGroups: allGroups))
        collapsedHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(collapsedHost.fittingSize.width, 0)
        XCTAssertGreaterThan(collapsedHost.fittingSize.height, 0)

        let preferences = PanelPreferences(defaults: defaults)
        for provider in MultiUsageSnapshot.displayOrder {
            preferences.setProviderVisible(false, for: provider)
        }
        for group in allGroups {
            preferences.setAntigravityGroupVisible(false, for: group)
        }
        let presentation = EdgeTabPresentationState()
        let tabHost = NSHostingView(rootView: MultiEdgeTabView(store: MultiUsageStore(demoSnapshot: hiddenSnapshot),
                                                               presentation: presentation,
                                                               preferences: preferences))
        tabHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tabHost.fittingSize.width, 0)
        XCTAssertGreaterThan(tabHost.fittingSize.height, 0)
    }

    @MainActor
    func testTabMenuIncludesRingVisibilitySubmenuAndActionsMutatePreferences() throws {
        let suiteName = "RingVisibilityTests-Menu-\(UUID().uuidString)"
        let mode = try DemoMode.isolated(suiteName: suiteName)
        defer { mode.defaults.removePersistentDomain(forName: suiteName) }

        let persona = MultiProviderPersona(demoMode: mode)
        let preferences = try XCTUnwrap(persona.panelPreferences)
        let delegate = AppDelegate(persona: persona, demoMode: mode)

        let menu = delegate.makeTabMenu()
        let ringsMenuItem = try XCTUnwrap(menu.items.first { $0.title == "表示するリング" })
        let submenu = try XCTUnwrap(ringsMenuItem.submenu)

        let providerItems = submenu.items.filter { item in
            guard let raw = item.representedObject as? String else { return false }
            return ProviderID(rawValue: raw) != nil
        }
        XCTAssertEqual(providerItems.compactMap { ($0.representedObject as? String).flatMap(ProviderID.init(rawValue:)) },
                       MultiUsageSnapshot.displayOrder)

        let antigravityIndex = try XCTUnwrap(submenu.items.firstIndex {
            ($0.representedObject as? String) == ProviderID.antigravity.rawValue
        })
        let groupItems = Array(submenu.items[(antigravityIndex + 1)...(antigravityIndex + ServiceRowModel.antigravityGroupNames.count)])
        XCTAssertEqual(groupItems.compactMap { $0.representedObject as? String },
                       ServiceRowModel.antigravityGroupNames)
        XCTAssertTrue(groupItems.allSatisfy { $0.indentationLevel == 1 })

        let showAllItem = try XCTUnwrap(submenu.items.first { $0.title == "すべて表示" })

        let codexItem = try XCTUnwrap(providerItems.first { ($0.representedObject as? String) == ProviderID.codex.rawValue })
        let initialCodexVisible = preferences.isProviderVisible(.codex)
        let codexTarget = try XCTUnwrap(codexItem.target as AnyObject?)
        let codexAction = try XCTUnwrap(codexItem.action)
        _ = codexTarget.perform(codexAction, with: codexItem)
        XCTAssertEqual(preferences.isProviderVisible(.codex), !initialCodexVisible)

        let argonItem = try XCTUnwrap(groupItems.first { ($0.representedObject as? String) == "Gemini 4 Argon" })
        XCTAssertEqual(argonItem.state, .on)
        let argonTarget = try XCTUnwrap(argonItem.target as AnyObject?)
        let argonAction = try XCTUnwrap(argonItem.action)
        _ = argonTarget.perform(argonAction, with: argonItem)
        XCTAssertFalse(preferences.isAntigravityGroupVisible("Gemini 4 Argon"))

        let rebuiltSubmenu = try XCTUnwrap(delegate.makeTabMenu().items.first { $0.title == "表示するリング" }?.submenu)
        let rebuiltArgonItem = try XCTUnwrap(rebuiltSubmenu.items.first { ($0.representedObject as? String) == "Gemini 4 Argon" })
        XCTAssertEqual(rebuiltArgonItem.state, .off)

        let showAllTarget = try XCTUnwrap(showAllItem.target as AnyObject?)
        let showAllAction = try XCTUnwrap(showAllItem.action)
        _ = showAllTarget.perform(showAllAction, with: showAllItem)

        XCTAssertTrue(preferences.disabledProviders.isEmpty)
        for group in ServiceRowModel.antigravityGroupNames {
            XCTAssertTrue(preferences.isAntigravityGroupVisible(group))
        }
    }
}
