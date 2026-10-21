import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class PanelPreferencesTests: XCTestCase {
    @MainActor
    func testZoomClampingStepsResetAndPersistence() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        XCTAssertEqual(settings.zoom, 1)
        settings.setZoom(0.1)
        XCTAssertEqual(settings.zoom, 0.75)
        settings.zoomOut()
        XCTAssertEqual(settings.zoom, 0.75)
        settings.zoomIn()
        XCTAssertEqual(settings.zoom, 1)
        settings.setZoom(3)
        settings.zoomIn()
        XCTAssertEqual(settings.zoom, 2)
        settings.zoomOut()
        XCTAssertEqual(settings.percent, 175)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 1.75)
        settings.resetZoom()
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 1)
        for invalid in [Double.nan, .infinity, -.infinity] {
            settings.setZoom(invalid)
            XCTAssertEqual(settings.zoom, 1)
        }
        defaults.set(-10, forKey: PanelPreferences.zoomKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 0.75)
        defaults.set(10, forKey: PanelPreferences.zoomKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 2)
    }

    @MainActor
    func testSteppedZoomSnapsByFivePercentAndClamps() {
        for (current, delta, expected) in [(1.0, 0.25, 1.25),
                                           (1.02, 0.0, 1.0),
                                           (1.03, 0.0, 1.05),
                                           (0.6, 0.0, 0.75),
                                           (2.4, 0.0, 2.0)] {
            XCTAssertEqual(PanelPreferences.steppedZoom(current: current, by: delta), expected, accuracy: 0.0001)
        }
        XCTAssertEqual(PanelPreferences.steppedZoom(current: .nan, by: 0.05), 1)
        XCTAssertEqual(PanelPreferences.steppedZoom(current: 1.5, by: .infinity), 1)
    }

    @MainActor
    func testBarZoomClampingPersistenceAndPanelZoomIndependence() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)

        XCTAssertEqual(settings.barZoom, 1)
        settings.setZoom(1.5)
        settings.setBarZoom(0.1)
        XCTAssertEqual(settings.barZoom, 0.6)
        settings.barZoomOut()
        XCTAssertEqual(settings.barZoom, 0.6)
        settings.barZoomIn()
        XCTAssertEqual(settings.barZoom, 0.85, accuracy: 0.0001)
        settings.setBarZoom(2)
        XCTAssertEqual(settings.barZoom, 2, accuracy: 0.0001)
        XCTAssertEqual(settings.barZoomPercent, 200)
        // The + button climbs past 1.5 now and saturates at the raised bound.
        for _ in 0..<10 { settings.barZoomIn() }
        XCTAssertEqual(settings.barZoom, 2.5, accuracy: 0.0001)
        XCTAssertEqual(settings.barZoomPercent, 250)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 2.5, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 1.5, accuracy: 0.0001)

        settings.resetBarZoom()
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 1)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 1.5)
        for invalid in [Double.nan, .infinity, -.infinity] {
            settings.setBarZoom(invalid)
            XCTAssertEqual(settings.barZoom, 1)
        }
        defaults.set(0.1, forKey: PanelPreferences.barZoomKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 0.6)
        defaults.set(3, forKey: PanelPreferences.barZoomKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 2.5)
    }

    @MainActor
    func testAdjustBarZoomUsesFivePercentStepsAndPersistsIndependently() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        settings.setZoom(1.25)
        settings.adjustBarZoom(steps: 1)
        XCTAssertEqual(settings.barZoom, 1.05, accuracy: 0.0001)
        settings.setBarZoom(1.02)
        settings.adjustBarZoom(steps: -1)
        XCTAssertEqual(settings.barZoom, 0.95, accuracy: 0.0001)
        settings.adjustBarZoom(steps: -20)
        XCTAssertEqual(settings.barZoom, 0.6, accuracy: 0.0001)
        settings.adjustBarZoom(steps: 40)
        XCTAssertEqual(settings.barZoom, 2.5, accuracy: 0.0001)
        settings.adjustBarZoom(steps: 0)
        XCTAssertEqual(settings.barZoom, 2.5, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 2.5, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).zoom, 1.25, accuracy: 0.0001)
    }

    @MainActor
    func testAppearancePersistenceAndSystemReset() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        XCTAssertEqual(settings.appearance, .system)
        var changes = 0
        settings.onAppearanceChange = { changes += 1 }
        for appearance in [PanelAppearance.dark, .light, .system] {
            settings.appearance = appearance
            XCTAssertEqual(PanelPreferences(defaults: defaults).appearance, appearance)
        }
        XCTAssertEqual(changes, 3)
        XCTAssertNil(settings.appearance.colorScheme)
        XCTAssertNil(settings.appearance.nsAppearance)
        XCTAssertEqual(PanelAppearance.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(PanelAppearance.light.nsAppearance?.name, .aqua)
        defaults.set("invalid", forKey: PanelPreferences.appearanceKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).appearance, .system)
    }

    @MainActor
    func testAppearanceToggleAndOrientationTogglePersist() throws {
        let cases: [(PanelAppearance, ColorScheme, PanelAppearance)] = [
            (.system, .light, .dark),
            (.system, .dark, .light),
            (.light, .light, .dark),
            (.light, .dark, .dark),
            (.dark, .light, .light),
            (.dark, .dark, .light)
        ]
        for (appearance, effective, expected) in cases {
            XCTAssertEqual(PanelPreferences.toggled(appearance, effective: effective), expected)
        }

        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        settings.toggleAppearance(effective: .dark)
        settings.toggleOrientation()

        let restored = PanelPreferences(defaults: defaults)
        XCTAssertEqual(restored.appearance, .light)
        XCTAssertEqual(restored.orientation, .vertical)
        restored.toggleOrientation()
        XCTAssertEqual(PanelPreferences(defaults: defaults).orientation, .horizontal)
    }

    @MainActor
    func testAppearanceChangesReachNativePanelAndFloatingTabWindows() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
        let tab = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                          styleMask: .borderless, backing: .buffered, defer: false)
        AppDelegate.bindAppearanceUpdates(for: settings) { [panel, tab] }
        XCTAssertNil(panel.appearance)
        XCTAssertNil(tab.appearance)

        for (appearance, expectedName) in [(PanelAppearance.light, NSAppearance.Name.aqua),
                                            (.dark, .darkAqua)] {
            settings.appearance = appearance
            XCTAssertEqual(panel.appearance?.name, expectedName)
            XCTAssertEqual(tab.appearance?.name, expectedName)
        }
        settings.appearance = .system
        XCTAssertNil(panel.appearance)
        XCTAssertNil(tab.appearance)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(tab.isVisible)
        withExtendedLifetime((panel, tab)) { }
    }

    @MainActor
    func testKeyboardMappingsAndModifierIsolation() throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        func event(_ characters: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }
        for (key, flags, expected) in [("=", NSEvent.ModifierFlags.command, 1.25),
                                       ("+", [.command, .shift], 1.5), ("-", .command, 1.25),
                                       ("0", .command, 1.0)] {
            XCTAssertTrue(settings.handleKeyEquivalent(try event(key, flags)))
            XCTAssertEqual(settings.zoom, expected)
        }
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .option], [.command, .control]] {
            XCTAssertFalse(settings.handleKeyEquivalent(try event("=", flags)))
            XCTAssertEqual(settings.zoom, 1)
        }
        // An offscreen, non-key panel must not consume shortcuts or change zoom.
        let panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                               styleMask: .borderless, backing: .buffered, defer: false)
        panel.preferences = settings
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.performKeyEquivalent(with: try event("=")))
        XCTAssertEqual(settings.zoom, 1)
    }

    @MainActor
    func testHostingReportsScaledContentSizeInsideScrollViewport() async throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(snapshotURLs: [])
        var measuredSizes: [CGSize] = []
        let initial = expectation(description: "Initial intrinsic content size")
        let enlarged = expectation(description: "Zoom updates the native host size callback")
        var receivedInitial = false
        var receivedEnlarged = false
        let host = OpacityAdjustingHostingView(rootView:
            MultiWidgetView(store: store, preferences: settings) { size in
                measuredSizes.append(size)
                if size.width == 480, !receivedInitial {
                    receivedInitial = true
                    initial.fulfill()
                }
                if size.width == 960, !receivedEnlarged {
                    receivedEnlarged = true
                    enlarged.fulfill()
                }
            })
        host.sizingOptions = []
        host.scrollAdjustsOpacity = false
        let window = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        func renderOffscreen() throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        try renderOffscreen()
        await fulfillment(of: [initial], timeout: 2)
        settings.setZoom(2)
        try renderOffscreen()
        await fulfillment(of: [enlarged], timeout: 2)
        let first = try XCTUnwrap(measuredSizes.first { $0.width == 480 }, "Measured: \(measuredSizes)")
        let last = try XCTUnwrap(measuredSizes.last { $0.width == 960 })
        XCTAssertEqual(last.height, first.height * 2, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        withExtendedLifetime(window) { }
    }

    @MainActor
    func testBarZoomAndRuntimeMenuBarHeightUpdateNativeFloatingTabGeometry() async throws {
        let name = "PanelPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(snapshotURLs: [])
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 24
        let baseSize = MultiCollapsedUsageView.size(for: store.snapshot, barZoom: 1, menuBarHeight: 24)
        let smallSize = MultiCollapsedUsageView.size(for: store.snapshot, barZoom: 0.75, menuBarHeight: 24)
        let enlargedSize = MultiCollapsedUsageView.size(for: store.snapshot, barZoom: 1.5, menuBarHeight: 24)
        let base = expectation(description: "Initial floating tab size reaches native presentation")
        let small = expectation(description: "Five-percent bar size reaches native presentation")
        let enlarged = expectation(description: "Bar size preference reaches native presentation")
        let tallerScreen = expectation(description: "Runtime menu-bar height reaches native presentation")
        presentation.onSizeChange = {
            if presentation.collapsedSize == baseSize { base.fulfill() }
            if presentation.collapsedSize == smallSize { small.fulfill() }
            if presentation.collapsedSize == enlargedSize { enlarged.fulfill() }
            if presentation.collapsedSize.height == 40.5 { tallerScreen.fulfill() }
        }
        let host = NSHostingView(rootView:
            MultiEdgeTabView(store: store, presentation: presentation, preferences: preferences))
        host.sizingOptions = []
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: baseSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: baseSize)
        func renderOffscreen() throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }

        try renderOffscreen()
        await fulfillment(of: [base], timeout: 2)
        XCTAssertEqual(window.frame.height, ceil(baseSize.height), accuracy: 0.5)
        AppDelegate.applyTabFrame(NSRect(origin: .zero, size: smallSize), to: window)
        preferences.adjustBarZoom(steps: -5)
        try renderOffscreen()
        await fulfillment(of: [small], timeout: 2)
        XCTAssertEqual(window.frame.height, ceil(smallSize.height), accuracy: 0.5)
        AppDelegate.applyTabFrame(NSRect(origin: .zero, size: enlargedSize), to: window)
        preferences.adjustBarZoom(steps: 15)
        try renderOffscreen()
        await fulfillment(of: [enlarged], timeout: 2)
        XCTAssertEqual(window.frame.height, ceil(enlargedSize.height), accuracy: 0.5)

        presentation.menuBarHeight = 37
        try renderOffscreen()
        await fulfillment(of: [tallerScreen], timeout: 2)
        XCTAssertEqual(presentation.collapsedSize.height, 40.5, accuracy: 0.001)
        let changedSize = presentation.collapsedSize
        AppDelegate.applyTabFrame(NSRect(origin: .zero, size: changedSize), to: window)
        XCTAssertEqual(window.frame.height, ceil(changedSize.height), accuracy: 0.5)
        XCTAssertGreaterThan(presentation.collapsedSize.width, baseSize.width * 1.3)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 1.5, accuracy: 0.0001)
        XCTAssertFalse(window.isVisible)
        withExtendedLifetime(window) { }
    }

    @MainActor
    func testViewportFitsContentAndOnlyScrollsBeyondScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 900)
        XCTAssertEqual(AppDelegate.panelViewportSize(content: CGSize(width: 960, height: 800), visibleFrame: screen),
                       CGSize(width: 960, height: 800))
        XCTAssertEqual(AppDelegate.panelViewportSize(content: CGSize(width: 1600, height: 1500), visibleFrame: screen),
                       CGSize(width: 1184, height: 884))
    }
}
