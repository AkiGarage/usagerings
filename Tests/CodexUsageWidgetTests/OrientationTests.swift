import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class OrientationTests: XCTestCase {
    @MainActor
    func testOrientationDefaultsAndPersistenceRoundTrip() throws {
        let name = "OrientationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        XCTAssertEqual(preferences.orientation, .horizontal)
        preferences.setBarZoom(2.5)
        preferences.setZoom(1.5)
        preferences.appearance = .dark
        for orientation in [PanelOrientation.vertical, .horizontal] {
            preferences.orientation = orientation
            XCTAssertEqual(defaults.string(forKey: PanelPreferences.orientationKey), orientation.rawValue)
            let restored = PanelPreferences(defaults: defaults)
            XCTAssertEqual(restored.orientation, orientation)
            XCTAssertEqual(restored.barZoom, 2.5)
            XCTAssertEqual(restored.zoom, 1.5)
            XCTAssertEqual(restored.appearance, .dark)
        }
        defaults.set("invalid", forKey: PanelPreferences.orientationKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).orientation, .horizontal)
    }

    func testVerticalSizeTransposesHorizontalAtEveryZoomAndMenuBarHeight() {
        for height: CGFloat in [22, 24, 37, 48] {
            for zoom in [0.6, 0.75, 1, 1.5, 2.5] {
                let horizontal = MultiCollapsedUsageView.size(for: .placeholder, barZoom: zoom,
                                                             menuBarHeight: height)
                let vertical = MultiCollapsedUsageView.size(for: .placeholder, barZoom: zoom,
                                                           menuBarHeight: height, orientation: .vertical)
                XCTAssertEqual(vertical, CGSize(width: horizontal.height, height: horizontal.width))
                let layout = MultiCollapsedUsageView.layout(barZoom: zoom, menuBarThickness: height)
                let count = CGFloat(CollapsedUsageBar.bars(for: .placeholder).count)
                let occupiedLength = count * layout.ringDiameter + (count - 1) * MultiCollapsedUsageView.spacing
                XCTAssertGreaterThanOrEqual(vertical.height - occupiedLength, layout.horizontalPadding * 2)
                XCTAssertGreaterThanOrEqual(vertical.width, layout.ringDiameter)
            }
        }
    }

    @MainActor
    func testContextMenuSelectsOrientationAndChecksCurrentValue() throws {
        let name = "OrientationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let delegate = AppDelegate(persona: OfflinePersona(preferences: preferences))
        func choices() throws -> NSMenu {
            let display = try XCTUnwrap(delegate.makeTabMenu().item(withTitle: "表示")?.submenu)
            return try XCTUnwrap(display.item(withTitle: "表示の向き")?.submenu)
        }
        for orientation in [PanelOrientation.vertical, .horizontal] {
            let menu = try choices()
            XCTAssertEqual(menu.items.map(\.title), ["横", "縦"])
            XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), [preferences.orientation.title])
            let item = try XCTUnwrap(menu.item(withTitle: orientation.title))
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            XCTAssertEqual(preferences.orientation, orientation)
            XCTAssertEqual(PanelPreferences(defaults: defaults).orientation, orientation)
            XCTAssertEqual(try choices().items.filter { $0.state == .on }.map(\.title), [orientation.title])
            XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
        }
        for (title, expected) in [("縦表示に切り替え", PanelOrientation.vertical),
                                   ("横表示に切り替え", .horizontal)] {
            let item = try XCTUnwrap(delegate.makeTabMenu().item(withTitle: title))
            XCTAssertNil(item.submenu)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(preferences.orientation, expected)
            XCTAssertEqual(PanelPreferences(defaults: defaults).orientation, expected)
        }
    }

    @MainActor
    func testOrientationAndZoomReachNativeTabAndStayOnScreen() async throws {
        let name = "OrientationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(snapshotURLs: [])
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 37
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: store.snapshot, menuBarHeight: 37)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let size = presentation.size
        let window = NSPanel(contentRect: CGRect(x: screen.maxX - size.width - 8,
                                                y: screen.maxY - size.height,
                                                width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation,
                                                          preferences: preferences))
        host.sizingOptions = []
        window.contentView = host
        func render() throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        try render()
        for (orientation, zoom) in [(PanelOrientation.vertical, 1.0), (.vertical, 0.6),
                                    (.vertical, 2.5), (.horizontal, 2.5), (.horizontal, 1.0)] {
            let expected = MultiCollapsedUsageView.size(for: store.snapshot, barZoom: zoom,
                                                       menuBarHeight: 37, orientation: orientation)
            let updated = expectation(description: "Native size \(orientation) at \(zoom)")
            presentation.onSizeChange = {
                let origin = TabPositioning.multiResizedOrigin(
                    from: window.frame, to: presentation.size, visibleFrame: visible,
                    screenFrame: screen, menuBarHeight: 37)
                AppDelegate.applyTabFrame(CGRect(origin: origin, size: presentation.size), to: window)
                if presentation.collapsedSize == expected { updated.fulfill() }
            }
            preferences.orientation = orientation
            preferences.setBarZoom(zoom)
            try render()
            await fulfillment(of: [updated], timeout: 2)
            XCTAssertEqual(window.frame.width, ceil(expected.width), accuracy: 0.5)
            XCTAssertEqual(window.frame.height, ceil(expected.height), accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX)
            XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY)
            XCTAssertLessThanOrEqual(window.frame.maxX, visible.maxX)
            XCTAssertLessThanOrEqual(window.frame.maxY, screen.maxY)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
        presentation.onSizeChange = nil
        withExtendedLifetime(window) { }
    }

    @MainActor
    func testPortraitHoverReservesRoomForPercentageAtMinimumZoom() {
        let presentation = EdgeTabPresentationState()
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: .placeholder, barZoom: 0.6,
                                                                 menuBarHeight: 22, orientation: .vertical)
        for mode in [EdgeTabPresentationMode.collapsed, .dragging] {
            presentation.mode = mode
            XCTAssertEqual(presentation.size, presentation.collapsedSize)
        }
        presentation.mode = .expanded
        XCTAssertGreaterThanOrEqual(presentation.size.width, EdgeTabPresentation.expandedSize.width)
        XCTAssertEqual(presentation.size.height, presentation.collapsedSize.height)
    }

    func testOrientationSwitchClampsAtEdgesAndKeepsScreenAnchors() {
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -1512, y: 200, width: 1512, height: 982)] {
            let visible = CGRect(x: screen.minX + 40, y: screen.minY + 40,
                                 width: screen.width - 40, height: screen.height - 77)
            for zoom in [0.6, 1.0, 2.5] {
                let horizontal = MultiCollapsedUsageView.size(for: .placeholder, barZoom: zoom, menuBarHeight: 37)
                let vertical = MultiCollapsedUsageView.size(for: .placeholder, barZoom: zoom,
                                                           menuBarHeight: 37, orientation: .vertical)
                for onRight in [false, true] {
                    for onTop in [false, true] {
                        let start = CGRect(x: onRight ? visible.maxX - horizontal.width - 8 : visible.minX + 8,
                                           y: onTop ? screen.maxY - horizontal.height : visible.minY + 8,
                                           width: horizontal.width, height: horizontal.height)
                        let origin = TabPositioning.multiResizedOrigin(from: start, to: vertical,
                            visibleFrame: visible, screenFrame: screen, menuBarHeight: 37)
                        let frame = CGRect(origin: origin, size: vertical)
                        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + 8)
                        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 8)
                        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
                        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
                        XCTAssertEqual(onRight ? frame.maxX : frame.minX,
                                       onRight ? start.maxX : start.minX, accuracy: 0.001)
                        XCTAssertEqual(onTop ? frame.maxY : frame.minY,
                                       onTop ? screen.maxY : start.minY, accuracy: 0.001)
                        let back = TabPositioning.multiResizedOrigin(from: frame, to: horizontal,
                            visibleFrame: visible, screenFrame: screen, menuBarHeight: 37)
                        XCTAssertGreaterThanOrEqual(back.x, visible.minX + 8)
                        XCTAssertLessThanOrEqual(back.x + horizontal.width, visible.maxX - 8)
                        XCTAssertGreaterThanOrEqual(back.y, visible.minY + 8)
                        XCTAssertLessThanOrEqual(back.y + horizontal.height, screen.maxY)
                    }
                }
                let center = CGRect(x: visible.midX - horizontal.width / 2, y: visible.midY - horizontal.height / 2,
                                    width: horizontal.width, height: horizontal.height)
                let origin = TabPositioning.multiResizedOrigin(from: center, to: vertical,
                    visibleFrame: visible, screenFrame: screen, menuBarHeight: 37)
                XCTAssertEqual(origin.y + vertical.height / 2, center.midY, accuracy: 0.001)
            }
        }
    }

    func testPortraitPanelOpensBesideTabAndRespectsSavedPosition() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let size = CGSize(width: 480, height: 500)
        for x: CGFloat in [8, 1477] {
            let tab = CGRect(x: x, y: 400, width: 27, height: 256)
            let origin = TabPositioning.panelOrigin(size: size, anchor: tab, visibleFrame: visible,
                                                   screenFrame: screen, orientation: .vertical)
            XCTAssertEqual(origin.y + size.height, tab.maxY)
            if x == 8 { XCTAssertEqual(origin.x, tab.maxX + TabPositioning.panelTopGap) }
            else { XCTAssertEqual(origin.x + size.width, tab.minX - TabPositioning.panelTopGap) }
            let reset = TabPositioning.panelResetOrigin(size: size, currentFrame: .zero, anchor: tab,
                hasSavedOffset: false, visibleFrame: visible, screenFrame: screen, orientation: .vertical)
            XCTAssertEqual(reset, origin)
        }
        let tab = CGRect(x: 700, y: 200, width: 27, height: 256)
        let offset = CGSize(width: 40, height: 50)
        let saved = TabPositioning.panelOrigin(size: size, anchor: tab, savedOffset: offset,
            visibleFrame: visible, screenFrame: screen, orientation: .vertical)
        XCTAssertEqual(saved, CGPoint(x: 740, y: 250))
        let top = TabPositioning.panelOrigin(size: size, anchor: CGRect(x: 1477, y: 726, width: 27, height: 256),
            visibleFrame: visible, screenFrame: screen, orientation: .vertical)
        XCTAssertEqual(top.y + size.height, screen.maxY - TabPositioning.edgePadding)
        let bottom = TabPositioning.panelOrigin(size: size, anchor: CGRect(x: 8, y: 48, width: 27, height: 256),
            visibleFrame: visible, screenFrame: screen, orientation: .vertical)
        XCTAssertGreaterThanOrEqual(bottom.y, screen.minY + TabPositioning.edgePadding)
    }
}

@MainActor
private final class OfflinePersona: AppPersona {
    let panelPreferences: PanelPreferences?
    init(preferences: PanelPreferences) { panelPreferences = preferences }
    var quitMenuItemTitle: String { "Quit" }
    var panelDefaultSize: NSSize { CGSize(width: 480, height: 500) }
    var panelMinSize: NSSize { panelDefaultSize }
    var panelMaxSize: NSSize { panelDefaultSize }
    var panelRootView: AnyView { AnyView(EmptyView()) }
    func tabRootView(presentation: EdgeTabPresentationState) -> AnyView { AnyView(EmptyView()) }
    func start() {}
    func stop() {}
    func refresh() {}
    func showOpacityHUD(percent: Int) {}
}
