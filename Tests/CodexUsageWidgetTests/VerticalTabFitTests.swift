import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

/// The vertical (portrait) tab is one ring per provider and can outgrow a
/// short screen at a large bar zoom. It then draws at the largest zoom that
/// fits, while `PanelPreferences.barZoom` keeps the value the user chose.
final class VerticalTabFitTests: XCTestCase {
    /// A 13" MacBook Air: 1512×982 points with a 77pt menu bar and Dock inset.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var visible: CGRect { CGRect(x: 0, y: 40, width: 1512, height: 905) }

    @MainActor
    private func makePreferences(barZoom: Double) throws -> (PanelPreferences, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "VerticalTabFitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = PanelPreferences(defaults: defaults)
        preferences.setBarZoom(barZoom)
        return (preferences, defaults, suite)
    }

    // (a) The reported regression: 13 rings at zoom 2.5 on a 905pt screen.
    @MainActor
    func testVerticalTabFitsAThirteenInchScreenWithoutChangingTheSavedZoom() throws {
        let (preferences, defaults, suite) = try makePreferences(barZoom: 2.5)
        defer { defaults.removePersistentDomain(forName: suite) }
        let maxLength = try XCTUnwrap(TabPositioning.maxVerticalTabLength(visibleHeight: visible.height))
        XCTAssertEqual(maxLength, visible.height - TabPositioning.edgePadding * 2)

        let size = MultiCollapsedUsageView.size(for: .placeholder, barZoom: preferences.barZoom,
                                                menuBarHeight: 37, orientation: .vertical,
                                                maxVerticalLength: maxLength)
        XCTAssertLessThanOrEqual(size.height, maxLength)

        let start = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        let origin = TabPositioning.multiResizedOrigin(from: start, to: size, visibleFrame: visible,
                                                      screenFrame: screen, menuBarHeight: 37)
        let frame = CGRect(origin: origin, size: size)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + TabPositioning.edgePadding)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + TabPositioning.edgePadding)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - TabPositioning.edgePadding)

        // The render shrank, the preference did not.
        let rendered = MultiCollapsedUsageView(snapshot: .placeholder, barZoom: preferences.barZoom,
                                              menuBarHeight: 37, orientation: .vertical,
                                              maxVerticalLength: maxLength).renderedBarZoom
        XCTAssertLessThan(rendered, 2.5)
        XCTAssertGreaterThanOrEqual(rendered, PanelPreferences.barZoomRange.lowerBound)
        XCTAssertEqual(preferences.barZoom, 2.5)
        XCTAssertEqual(defaults.double(forKey: PanelPreferences.barZoomKey), 2.5)
    }

    // (b) No shrink when the strip already fits.
    @MainActor
    func testVerticalTabKeepsTheRequestedZoomWhenItFits() throws {
        let (preferences, defaults, suite) = try makePreferences(barZoom: 1.0)
        defer { defaults.removePersistentDomain(forName: suite) }
        let maxLength = try XCTUnwrap(TabPositioning.maxVerticalTabLength(visibleHeight: visible.height))
        let size = MultiCollapsedUsageView.size(for: .placeholder, barZoom: preferences.barZoom,
                                                menuBarHeight: 37, orientation: .vertical,
                                                maxVerticalLength: maxLength)
        XCTAssertEqual(size, MultiCollapsedUsageView.size(for: .placeholder, barZoom: 1.0,
                                                          menuBarHeight: 37, orientation: .vertical))
        let view = MultiCollapsedUsageView(snapshot: .placeholder, barZoom: preferences.barZoom,
                                           menuBarHeight: 37, orientation: .vertical,
                                           maxVerticalLength: maxLength)
        XCTAssertEqual(view.renderedBarZoom, 1.0)
        XCTAssertEqual(preferences.barZoom, 1.0)
    }

    // (c) The pure fit at its boundaries.
    @MainActor
    func testFittedZoomBoundaries() {
        let count = 13
        let atMax = MultiCollapsedUsageView.verticalLength(count: count, barZoom: 2.5, menuBarHeight: 37)
        XCTAssertEqual(MultiCollapsedUsageView.fittedBarZoom(2.5, count: count, menuBarHeight: 37,
                                                            maxLength: atMax), 2.5)
        XCTAssertLessThan(MultiCollapsedUsageView.fittedBarZoom(2.5, count: count, menuBarHeight: 37,
                                                               maxLength: atMax - 1), 2.5)
        // Even the smallest strip can be too long: never below the preference minimum.
        XCTAssertEqual(MultiCollapsedUsageView.fittedBarZoom(2.5, count: count, menuBarHeight: 37,
                                                            maxLength: 1),
                       PanelPreferences.barZoomRange.lowerBound)
        // No measurement (nil / non-finite / empty): the requested zoom is kept.
        for unknown in [nil, .nan, 0] as [CGFloat?] {
            XCTAssertEqual(MultiCollapsedUsageView.fittedBarZoom(2.5, count: count, menuBarHeight: 37,
                                                                maxLength: unknown), 2.5)
        }
        XCTAssertEqual(MultiCollapsedUsageView.fittedBarZoom(2.5, count: 0, menuBarHeight: 37,
                                                            maxLength: atMax), 2.5)
        // A taller screen restores the full size.
        let tall = CGFloat(1100) - TabPositioning.edgePadding * 2
        XCTAssertEqual(MultiCollapsedUsageView.fittedBarZoom(2.5, count: count, menuBarHeight: 37,
                                                            maxLength: tall), 2.5)

        // Horizontal sizing never consults the vertical cap.
        XCTAssertEqual(MultiCollapsedUsageView.size(for: .placeholder, barZoom: 2.5, menuBarHeight: 37,
                                                    maxVerticalLength: 1),
                       MultiCollapsedUsageView.size(for: .placeholder, barZoom: 2.5, menuBarHeight: 37))
    }

    @MainActor
    func testScreenChangesResizeTheNativeViewAndRestoreSavedZoom() async throws {
        let (preferences, defaults, suite) = try makePreferences(barZoom: 2.5)
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.orientation = .vertical
        let store = MultiUsageStore(snapshotURLs: [])
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 37
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation,
                                                          preferences: preferences))
        host.sizingOptions = []
        let window = NSPanel(contentRect: CGRect(x: 8, y: 48, width: 100, height: 900),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        defer { presentation.onSizeChange = nil }
        for available in [CGFloat(889), 1084, 889] {
            let expected = MultiCollapsedUsageView.size(for: store.snapshot, barZoom: 2.5,
                menuBarHeight: 37, orientation: .vertical, maxVerticalLength: available)
            let changed = expectation(description: "Screen height \(available)")
            presentation.onSizeChange = {
                AppDelegate.applyTabFrame(CGRect(origin: CGPoint(x: 8, y: 48), size: presentation.size), to: window)
                if presentation.collapsedSize == expected { changed.fulfill() }
            }
            presentation.maxCollapsedLength = available
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            await fulfillment(of: [changed], timeout: 2)
            XCTAssertEqual(window.frame.height, expected.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(window.frame.height, available)
            XCTAssertEqual(preferences.barZoom, 2.5)
            XCTAssertEqual(defaults.double(forKey: PanelPreferences.barZoomKey), 2.5)
            XCTAssertFalse(window.isVisible)
        }
        XCTAssertEqual(MultiCollapsedUsageView.renderedBarZoom(2.5, barCount: 13,
            menuBarHeight: 37, orientation: .vertical, maxVerticalLength: 1084), 2.5)
    }

    func testFittedRingHitTargetsMatchEveryDrawnRing() throws {
        let snapshot = MultiUsageSnapshot.placeholder
        let count = CollapsedUsageBar.bars(for: snapshot).count
        let zoom = MultiCollapsedUsageView.renderedBarZoom(2.5, barCount: count, menuBarHeight: 37,
                                                          orientation: .vertical, maxVerticalLength: 889)
        let layout = MultiCollapsedUsageView.layout(barZoom: zoom, menuBarThickness: 37)
        let size = MultiCollapsedUsageView.size(for: snapshot, barZoom: 2.5, menuBarHeight: 37,
                                               orientation: .vertical, maxVerticalLength: 889)
        for index in 0..<count {
            let ring = try XCTUnwrap(MultiCollapsedUsageView.ringFrame(index: index, size: size,
                layout: layout, count: count, orientation: .vertical))
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(ring))
            XCTAssertEqual(MultiCollapsedUsageView.ringIndex(at: CGPoint(x: ring.midX, y: ring.midY),
                size: size, layout: layout, count: count, orientation: .vertical), index)
        }
    }

    func testFitLengthUsesBothEdgeMargins() {
        XCTAssertEqual(TabPositioning.maxVerticalTabLength(visibleHeight: 905), 889)
        XCTAssertEqual(TabPositioning.maxVerticalTabLength(visibleHeight: 0), nil)
        XCTAssertEqual(TabPositioning.maxVerticalTabLength(visibleHeight: .infinity), nil)
        XCTAssertEqual(TabPositioning.maxVerticalTabLength(visibleHeight: 10), nil)
    }
}
