import AppKit
import XCTest
@testable import CodexUsageWidget

final class MenuBarGeometryTests: XCTestCase {
    func testRuntimeHostScreenGeometryComesFromOneScreen() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "No AppKit hosting screen is available")
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let height = MenuBarGeometry.height(screenFrame: screen.frame,
                                            visibleFrame: screen.visibleFrame,
                                            mainMenuHeight: NSApp.mainMenu?.menuBarHeight,
                                            statusBarThickness: NSStatusBar.system.thickness)
        XCTAssertGreaterThan(height, 0)
        let layout = MultiCollapsedUsageView.layout(barZoom: 1, menuBarThickness: height)
        print("HOST_SCREEN_GEOMETRY frame=\(NSStringFromRect(screen.frame)) visible=\(NSStringFromRect(screen.visibleFrame)) menuBarHeight=\(height) tabHeight=\(layout.tabHeight) ring=\(layout.ringDiameter)")
    }

    func testScreenDifferenceWinsAndFallbacksAreFinite() {
        XCTAssertEqual(MenuBarGeometry.height(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                              visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 919),
                                              mainMenuHeight: 24,
                                              statusBarThickness: 22), 37)
        XCTAssertEqual(MenuBarGeometry.height(screenFrame: nil, visibleFrame: nil,
                                              mainMenuHeight: 27, statusBarThickness: 22), 27)
        XCTAssertEqual(MenuBarGeometry.height(screenFrame: nil, visibleFrame: nil,
                                              mainMenuHeight: nil, statusBarThickness: 24), 24)
        XCTAssertEqual(MenuBarGeometry.height(screenFrame: .zero, visibleFrame: .zero,
                                              mainMenuHeight: 0, statusBarThickness: 0), 24)
        XCTAssertEqual(MenuBarGeometry.height(
            screenFrame: .zero,
            visibleFrame: CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
            mainMenuHeight: CGFloat.nan,
            statusBarThickness: -CGFloat.infinity
        ), 24)
    }

    func testScreenSelectionUsesLargestIntersectionThenNearestScreen() {
        let left = MenuBarGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                          visibleFrame: CGRect(x: 0, y: 30, width: 100, height: 63))
        let right = MenuBarGeometry.Screen(frame: CGRect(x: 100, y: 0, width: 100, height: 100),
                                           visibleFrame: CGRect(x: 100, y: 24, width: 100, height: 69))
        XCTAssertEqual(MenuBarGeometry.screen(for: CGRect(x: 95, y: 40, width: 20, height: 20),
                                              screens: [left, right]), right)
        XCTAssertEqual(MenuBarGeometry.screen(for: CGRect(x: 220, y: 0, width: 20, height: 10),
                                              screens: [left, right]), right)
        XCTAssertEqual(MenuBarGeometry.screen(for: CGRect(x: -20, y: 50, width: 10, height: 10),
                                              screens: [left, right]), left)
        XCTAssertNil(MenuBarGeometry.screen(for: .zero, screens: []))
    }

    func testMultiResizeCentersInMenuBarAndPreservesDesktopPosition() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 863)
        let current = NSRect(x: 700, y: 880, width: 70, height: 27)
        let size = NSSize(width: 70, height: 36)

        let menuBarOrigin = TabPositioning.multiResizedOrigin(
            from: current, to: size, visibleFrame: visibleFrame,
            screenFrame: screenFrame, menuBarHeight: 37
        )
        XCTAssertEqual(menuBarOrigin.y, screenFrame.maxY - 37 + (37 - size.height) / 2, accuracy: 0.001)

        let desktop = NSRect(x: 300, y: 400, width: 70, height: 27)
        let desktopOrigin = TabPositioning.multiResizedOrigin(
            from: desktop, to: NSSize(width: 105, height: 40.5),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37
        )
        XCTAssertEqual(desktopOrigin.x, desktop.minX, accuracy: 0.001)
        XCTAssertEqual(desktopOrigin.y + 40.5 / 2, desktop.midY, accuracy: 0.001)
    }

    func testMenuBarCenteredOriginAnchorsTallTabToScreenTop() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let centered = NSRect(x: 700, y: 950, width: 70, height: 27)

        // A tab grown past the menu-bar height hangs down from the screen top.
        let tallOrigin = try XCTUnwrap(TabPositioning.menuBarCenteredOrigin(
            currentFrame: centered, to: NSSize(width: 105, height: 40.5),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37))
        XCTAssertEqual(tallOrigin.y + 40.5, screenFrame.maxY, accuracy: 0.001)
        let tallFrame = NSRect(origin: tallOrigin, size: NSSize(width: 105, height: 40.5))
        XCTAssertGreaterThanOrEqual(tallFrame.minX, screenFrame.minX)
        XCTAssertLessThanOrEqual(tallFrame.maxX, screenFrame.maxX)
        XCTAssertGreaterThanOrEqual(tallFrame.minY, screenFrame.minY)
        XCTAssertLessThanOrEqual(tallFrame.maxY, screenFrame.maxY + 0.001)

        // The grown tab still touches the screen top, so later zoom changes keep
        // the menu-bar path instead of falling back to desktop positioning.
        let grown = TabPositioning.multiResizedOrigin(
            from: tallFrame, to: NSSize(width: 70, height: 27),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37)
        XCTAssertEqual(grown.y, 950, accuracy: 0.001)

        // Growing from a centered in-menu-bar tab also anchors to the screen top.
        let fromCentered = TabPositioning.multiResizedOrigin(
            from: centered, to: NSSize(width: 105, height: 40.5),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37)
        XCTAssertEqual(fromCentered.y + 40.5, screenFrame.maxY, accuracy: 0.001)

        // Menu-bar-height tabs keep centering exactly as before.
        let stillCentered = try XCTUnwrap(TabPositioning.menuBarCenteredOrigin(
            currentFrame: centered, to: NSSize(width: 70, height: 27),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37))
        XCTAssertEqual(stillCentered.y, 945 + 5, accuracy: 0.001)
    }

    func testMenuBarCenteredOriginKeepsMaxZoomTabOnScreen() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 945)
        // Same 8-bar shape as the MenuBarSnapshotTests fixture, at the 2.5 cap
        // on a 37pt menu bar: the tab is 175×67.5 and clearly hangs below it.
        let size = MultiCollapsedUsageView.size(for: .placeholder, barZoom: 2.5, menuBarHeight: 37)
        XCTAssertGreaterThan(size.width, 175)
        XCTAssertEqual(size.height, 67.5, accuracy: 0.001)

        for current in [NSRect(x: 700, y: 950, width: 70, height: 27),
                        NSRect(x: 1480, y: 950, width: 70, height: 27)] {
            let origin = try XCTUnwrap(TabPositioning.menuBarCenteredOrigin(
                currentFrame: current, to: size,
                visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37))
            XCTAssertEqual(origin.y + size.height, screenFrame.maxY, accuracy: 0.001)
            let frame = NSRect(origin: origin, size: size)
            XCTAssertGreaterThanOrEqual(frame.minX, screenFrame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, screenFrame.maxX)
            XCTAssertGreaterThanOrEqual(frame.minY, screenFrame.minY)
            XCTAssertLessThanOrEqual(frame.maxY, screenFrame.maxY + 0.001)
        }
    }

    @MainActor
    func testNativePanelFrameAndGeometryChangeUpdateWithoutSizeChange() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 863)
        let panel = NSPanel(contentRect: NSRect(x: 700, y: 880, width: 70, height: 27),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let frame = NSRect(origin: try XCTUnwrap(TabPositioning.menuBarCenteredOrigin(
            currentFrame: NSRect(x: 700, y: 880, width: 70, height: 27),
            to: NSSize(width: 70, height: 27),
            visibleFrame: visibleFrame, screenFrame: screenFrame, menuBarHeight: 37
        )), size: NSSize(width: 70, height: 27))
        AppDelegate.applyTabFrame(frame, to: panel)
        XCTAssertEqual(panel.frame.height, 27, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, screenFrame.maxY - 37 + 5, accuracy: 0.001)

        let changedScreenFrame = screenFrame
        let changedVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 850)
        let sameSize = NSSize(width: 70, height: 27)
        let changedFrame = NSRect(origin: try XCTUnwrap(TabPositioning.menuBarCenteredOrigin(
            currentFrame: frame, to: sameSize,
            visibleFrame: changedVisibleFrame, screenFrame: changedScreenFrame, menuBarHeight: 47
        )), size: sameSize)
        AppDelegate.applyTabFrame(changedFrame, to: panel)
        XCTAssertEqual(panel.frame.size, sameSize)
        XCTAssertEqual(panel.frame.minY, changedScreenFrame.maxY - 47 + 10, accuracy: 0.001)
        XCTAssertFalse(panel.isVisible)
        withExtendedLifetime(panel) { }
    }
}
