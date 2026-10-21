import AppKit
import XCTest
@testable import CodexUsageWidget

final class TabPositioningTests: XCTestCase {
    func testNanoUpdaterPolicyReservesBridgeBuildAndRequiresForwardPublicBuild() {
        XCTAssertEqual(NanoUpdaterPolicy.bridgeBuild, 2)
        XCTAssertEqual(NanoUpdaterPolicy.testOnlyBuild, 3)
        XCTAssertFalse(NanoUpdaterPolicy.isAllowedPublicAutoUpdate(build: 3))
        XCTAssertTrue(NanoUpdaterPolicy.isAllowedPublicAutoUpdate(build: 4))
        XCTAssertTrue(NanoUpdaterPolicy.isForwardFix(from: 4, to: 5))
        XCTAssertFalse(NanoUpdaterPolicy.isForwardFix(from: 5, to: 4))
    }

    func testNanoUpdaterConfigurationRequiresNanoIdentityAndFailClosedSettings() {
        let valid: [String: Any] = [
            "CFBundleIdentifier": "local.codex.CodexUsageNano",
            "SUFeedURL": "https://akigarage.github.io/codex-usage-nano/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
            "SURequireSignedFeed": true,
            "SUVerifyUpdateBeforeExtraction": true,
            "SUSignedFeedFailureExpirationInterval": 0,
            "SUAllowsAutomaticUpdates": false,
        ]

        XCTAssertTrue(NanoUpdaterConfiguration.isValid(info: valid))
        XCTAssertFalse(NanoUpdaterConfiguration.isValid(info: valid.merging([
            "CFBundleIdentifier": "local.codex.CodexUsageWidget"
        ]) { _, new in new }))
        XCTAssertFalse(NanoUpdaterConfiguration.isValid(info: valid.merging([
            "SUSignedFeedFailureExpirationInterval": 1
        ]) { _, new in new }))
    }

    func testPanelOffsetStoreResetClearsSavedOffset() {
        let suiteName = "PanelOffsetStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PanelOffsetStore(defaults: defaults)

        store.save(NSSize(width: -120, height: -240))
        XCTAssertEqual(store.load(), NSSize(width: -120, height: -240))

        store.reset()

        XCTAssertNil(store.load())
        XCTAssertFalse(store.hasSavedOffset)
    }

    func testEdgeTabPresentationUsesSlimCollapsedBar() {
        XCTAssertEqual(EdgeTabPresentation.size(for: .collapsed), CGSize(width: 52, height: 16))
        XCTAssertEqual(EdgeTabPresentation.size(for: .dragging), CGSize(width: 52, height: 16))
        XCTAssertEqual(EdgeTabPresentation.size(for: .expanded), CGSize(width: 52, height: 30))
    }

    func testEdgeTabUsageBarHasNoFillAtZeroPercent() {
        XCTAssertEqual(EdgeTabUsageBarLayout.fillWidth(for: 0, in: 36), 0)
        XCTAssertEqual(EdgeTabUsageBarLayout.fillWidth(for: -5, in: 36), 0)
    }

    func testEdgeTabUsageBarKeepsLowNonzeroPercentVisible() {
        XCTAssertEqual(EdgeTabUsageBarLayout.fillWidth(for: 1, in: 36), 4)
        XCTAssertEqual(EdgeTabUsageBarLayout.fillWidth(for: 100, in: 36), 36)
        XCTAssertEqual(EdgeTabUsageBarLayout.fillWidth(for: 150, in: 36), 36)
    }

    func testDefaultPanelSizeIsSeventyFivePercentOfDesignSize() {
        XCTAssertEqual(TabPositioning.panelDesignSize, NSSize(width: 360, height: 190))
        XCTAssertEqual(TabPositioning.defaultPanelDisplayScale, 0.75)
        XCTAssertEqual(TabPositioning.defaultPanelSize, NSSize(width: 270, height: 142.5))
    }

    func testPanelSizeResetUsesDefaultTabRelationWithoutSavedOffset() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let screenFrame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let tabFrame = NSRect(x: 709, y: 926, width: 52, height: 30)
        let resizedDefaultFrame = NSRect(x: 544, y: 686, width: 360, height: 236)
        let defaultSize = TabPositioning.defaultPanelSize

        let origin = TabPositioning.panelResetOrigin(
            size: defaultSize,
            currentFrame: resizedDefaultFrame,
            anchor: tabFrame,
            hasSavedOffset: false,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(origin.x + defaultSize.width / 2, tabFrame.midX)
        XCTAssertEqual(origin.y + defaultSize.height + TabPositioning.panelTopGap, tabFrame.minY)
    }

    func testPanelSizeResetKeepsCurrentCenterWithSavedOffset() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let screenFrame = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let tabFrame = NSRect(x: 1200, y: 760, width: 52, height: 30)
        let currentFrame = NSRect(x: 992, y: 470, width: 270, height: 179)
        let defaultSize = TabPositioning.defaultPanelSize

        let origin = TabPositioning.panelResetOrigin(
            size: defaultSize,
            currentFrame: currentFrame,
            anchor: tabFrame,
            hasSavedOffset: true,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(origin.x + defaultSize.width / 2, currentFrame.midX)
        XCTAssertEqual(origin.y + defaultSize.height / 2, currentFrame.midY)
    }

    func testPanelOffsetPersistenceIgnoresMoveEventsDuringLiveResize() {
        XCTAssertFalse(PanelOffsetPersistence.shouldSaveMoveOffset(isLiveResizing: true))
        XCTAssertTrue(PanelOffsetPersistence.shouldSaveMoveOffset(isLiveResizing: false))
    }

    func testPanelOffsetPersistenceOnlySavesResizeWhenCustomOffsetAlreadyExisted() {
        XCTAssertFalse(PanelOffsetPersistence.shouldSaveResizeOffset(hadSavedOffsetAtResizeStart: false))
        XCTAssertTrue(PanelOffsetPersistence.shouldSaveResizeOffset(hadSavedOffsetAtResizeStart: true))
    }

    func testTabWindowLevelCanOccupyMenuBarArea() {
        XCTAssertEqual(TabPositioning.windowLevel, .statusBar)
        XCTAssertGreaterThan(TabPositioning.windowLevel.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testPanelCentersUnderTopTabWithSmallGap() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let panelSize = NSSize(width: 360, height: 190)
        let tabFrame = NSRect(x: 709, y: 926, width: 52, height: 30)

        let origin = TabPositioning.panelOrigin(
            size: panelSize,
            anchor: tabFrame,
            visibleFrame: visibleFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956)
        )

        XCTAssertEqual(origin.x + panelSize.width / 2, tabFrame.midX)
        XCTAssertEqual(origin.y + panelSize.height + TabPositioning.panelTopGap, tabFrame.minY)
    }

    func testPanelClampsHorizontallyNearRightEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let panelSize = NSSize(width: 360, height: 190)
        let tabFrame = NSRect(x: 1400, y: 926, width: 52, height: 30)

        let origin = TabPositioning.panelOrigin(
            size: panelSize,
            anchor: tabFrame,
            visibleFrame: visibleFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956)
        )

        XCTAssertEqual(origin.x + panelSize.width + TabPositioning.edgePadding, visibleFrame.maxX)
        XCTAssertEqual(origin.y + panelSize.height + TabPositioning.panelTopGap, tabFrame.minY)
    }

    func testPanelClampsHorizontallyNearLeftEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let panelSize = NSSize(width: 360, height: 190)
        let tabFrame = NSRect(x: 4, y: 926, width: 52, height: 30)

        let origin = TabPositioning.panelOrigin(
            size: panelSize,
            anchor: tabFrame,
            visibleFrame: visibleFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956)
        )

        XCTAssertEqual(origin.x, visibleFrame.minX + TabPositioning.edgePadding)
        XCTAssertEqual(origin.y + panelSize.height + TabPositioning.panelTopGap, tabFrame.minY)
    }

    func testSavedPanelOffsetRestoresRelativePosition() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let panelSize = NSSize(width: 360, height: 190)
        let tabFrame = NSRect(x: 700, y: 700, width: 52, height: 30)
        let savedOffset = NSSize(width: -120, height: -240)

        let origin = TabPositioning.panelOrigin(
            size: panelSize,
            anchor: tabFrame,
            savedOffset: savedOffset,
            visibleFrame: visibleFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956)
        )

        XCTAssertEqual(origin.x, tabFrame.minX + savedOffset.width)
        XCTAssertEqual(origin.y, tabFrame.minY + savedOffset.height)
    }

    func testSavedPanelOffsetIsClampedOnScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let panelSize = NSSize(width: 360, height: 190)
        let tabFrame = NSRect(x: 1400, y: 910, width: 52, height: 30)
        let savedOffset = NSSize(width: 100, height: 100)

        let origin = TabPositioning.panelOrigin(
            size: panelSize,
            anchor: tabFrame,
            savedOffset: savedOffset,
            visibleFrame: visibleFrame,
            screenFrame: NSRect(x: 0, y: 0, width: 1470, height: 956)
        )

        XCTAssertEqual(origin.x + panelSize.width + TabPositioning.edgePadding, visibleFrame.maxX)
        XCTAssertEqual(origin.y + panelSize.height + TabPositioning.edgePadding, 956)
    }

    func testOpacityAdjustsContinuouslyAndClamps() {
        XCTAssertEqual(TabPositioning.adjustedOpacity(current: 0.5, scrollDeltaY: 25), 0.55)
        XCTAssertEqual(TabPositioning.adjustedOpacity(current: 0, scrollDeltaY: 25), 0.2)
        XCTAssertEqual(TabPositioning.adjustedOpacity(current: 0.5, scrollDeltaY: -1_000), 0.2)
        XCTAssertEqual(TabPositioning.adjustedOpacity(current: 0.5, scrollDeltaY: 1_000), 1)
    }

    func testOpacityPercentRoundsAndClamps() {
        XCTAssertEqual(TabPositioning.opacityPercent(for: 0), 0)
        XCTAssertEqual(TabPositioning.opacityPercent(for: 0.754), 75)
        XCTAssertEqual(TabPositioning.opacityPercent(for: 1.4), 100)
        XCTAssertEqual(TabPositioning.opacityPercent(for: -0.2), 0)
    }

    func testPanelResizeCursorRegionsCoverEdgesAndCorners() {
        let bounds = NSRect(x: 0, y: 0, width: 270, height: 142.5)
        let regions = PanelResizeCursorRegion.regions(in: bounds, isFlipped: false)
        let rectsByPlacement = Dictionary(uniqueKeysWithValues: regions.map { ($0.placement, $0.rect) })

        XCTAssertEqual(regions.map(\.placement), PanelResizeCursorRegion.Placement.allCases)
        XCTAssertEqual(rectsByPlacement[.topLeft], NSRect(x: 0, y: 139.5, width: 3, height: 3))
        XCTAssertEqual(rectsByPlacement[.top], NSRect(x: 3, y: 139.5, width: 264, height: 3))
        XCTAssertEqual(rectsByPlacement[.topRight], NSRect(x: 267, y: 139.5, width: 3, height: 3))
        XCTAssertEqual(rectsByPlacement[.right], NSRect(x: 267, y: 3, width: 3, height: 136.5))
        XCTAssertEqual(rectsByPlacement[.bottomRight], NSRect(x: 267, y: 0, width: 3, height: 3))
        XCTAssertEqual(rectsByPlacement[.bottom], NSRect(x: 3, y: 0, width: 264, height: 3))
        XCTAssertEqual(rectsByPlacement[.bottomLeft], NSRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertEqual(rectsByPlacement[.left], NSRect(x: 0, y: 3, width: 3, height: 136.5))
    }

    func testPanelResizeCursorRegionsPreservePhysicalTopWhenViewIsFlipped() {
        let bounds = NSRect(x: 0, y: 0, width: 270, height: 142.5)
        let regions = PanelResizeCursorRegion.regions(in: bounds, isFlipped: true)
        let rectsByPlacement = Dictionary(uniqueKeysWithValues: regions.map { ($0.placement, $0.rect) })

        XCTAssertEqual(rectsByPlacement[.topLeft], NSRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertEqual(rectsByPlacement[.top], NSRect(x: 3, y: 0, width: 264, height: 3))
        XCTAssertEqual(rectsByPlacement[.bottom], NSRect(x: 3, y: 139.5, width: 264, height: 3))
        XCTAssertEqual(rectsByPlacement[.bottomLeft], NSRect(x: 0, y: 139.5, width: 3, height: 3))
    }

    func testPanelResizeCursorHitTestingOnlyMatchesPanelPerimeter() {
        let bounds = NSRect(x: 0, y: 0, width: 270, height: 142.5)

        XCTAssertNotNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 1, y: 1), in: bounds, isFlipped: false))
        XCTAssertNotNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 268, y: 141), in: bounds, isFlipped: false))
        XCTAssertNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 4, y: 4), in: bounds, isFlipped: false))
        XCTAssertNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 266, y: 138), in: bounds, isFlipped: false))
        XCTAssertNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 266, y: 70), in: bounds, isFlipped: false))
        XCTAssertNil(PanelResizeCursorRegion.cursor(at: NSPoint(x: 135, y: 70), in: bounds, isFlipped: false))
    }

    func testTabCanReachScreenTopAboveVisibleFrame() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 865)
        let tabSize = NSSize(width: 76, height: 30)

        let origin = TabPositioning.constrainedOrigin(
            NSPoint(x: 500, y: 900),
            size: tabSize,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(origin.y, 870)
    }

    func testTabBottomAndHorizontalEdgesStayInsideVisibleFrame() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 24, y: 40, width: 1392, height: 825)
        let tabSize = NSSize(width: 76, height: 30)

        let origin = TabPositioning.constrainedOrigin(
            NSPoint(x: -100, y: -100),
            size: tabSize,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(origin.x, 32)
        XCTAssertEqual(origin.y, 48)
    }

    func testTabResizeKeepsTopEdgeWhenDockedAtScreenTop() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 865)
        let currentFrame = NSRect(origin: NSPoint(x: 1328, y: 884), size: EdgeTabPresentation.collapsedSize)

        let origin = TabPositioning.resizedOrigin(
            from: currentFrame,
            to: EdgeTabPresentation.expandedSize,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )

        XCTAssertEqual(origin.y + EdgeTabPresentation.expandedSize.height, screenFrame.maxY)
    }
}
