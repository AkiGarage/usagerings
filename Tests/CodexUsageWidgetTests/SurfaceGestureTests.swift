import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class SurfaceGestureTests: XCTestCase {
    @MainActor
    func testOpacityPersistsIndependentlyAndClamps() throws {
        let name = "SurfaceGestureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SurfaceOpacityPreferences(defaults: defaults)
        XCTAssertEqual(settings.opacity(for: .tab), 1)
        XCTAssertEqual(settings.opacity(for: .panel), 1)
        settings.setOpacity(0.35, for: .tab)
        settings.setOpacity(0.8, for: .panel)
        let reloaded = SurfaceOpacityPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.opacity(for: .tab), 0.35, accuracy: 0.0001)
        XCTAssertEqual(reloaded.opacity(for: .panel), 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.setOpacity(-1, for: .tab), 0.2)
        XCTAssertEqual(settings.setOpacity(3, for: .panel), 1)
        XCTAssertEqual(reloaded.opacity(for: .tab), 0.2)
        XCTAssertEqual(settings.setOpacity(.nan, for: .tab), 1)
        defaults.set(-0.5, forKey: "panelWindowOpacity")
        XCTAssertEqual(reloaded.opacity(for: .panel), 0.2)
        defaults.set(Double.infinity, forKey: "panelWindowOpacity")
        XCTAssertEqual(reloaded.opacity(for: .panel), 1)
    }

    @MainActor
    func testTabPinchOverNonKeyPanelScalesOnlyWhenCursorIsOverTab() throws {
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 80, height: 20),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        let tab = DraggableTabHostingView(rootView: Color.red)
        var steps = 0
        tab.zoomInput.onSteps = { steps += $0 }
        panel.contentView = tab
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertFalse(panel.isKeyWindow)

        // Outside the tab: ignored.
        XCTAssertFalse(tab.handleTabMagnification(0.2, phase: .began, mouseLocation: NSPoint(x: 10, y: 10)))
        XCTAssertEqual(steps, 0)
        // Over the tab: grows in 5% steps, and continues even if the cursor drifts out.
        XCTAssertTrue(tab.handleTabMagnification(0.1, phase: .began, mouseLocation: NSPoint(x: 120, y: 110)))
        XCTAssertTrue(tab.handleTabMagnification(0.05, phase: .changed, mouseLocation: NSPoint(x: 10, y: 10)))
        XCTAssertTrue(tab.handleTabMagnification(0, phase: .ended, mouseLocation: NSPoint(x: 10, y: 10)))
        XCTAssertEqual(steps, 3)
        // After the gesture ends, an outside pinch is ignored again.
        XCTAssertFalse(tab.handleTabMagnification(-0.1, phase: .changed, mouseLocation: NSPoint(x: 10, y: 10)))
        XCTAssertEqual(steps, 3)
    }

    @MainActor
    func testMultiPanelPreservesContentScrollAndRoutesShiftOpacityAndOptionZoom() throws {
        let host = OpacityAdjustingHostingView(rootView: Color.red)
        host.scrollAdjustsOpacity = false
        var deltas: [CGFloat] = []
        var steps = 0
        host.onOpacityDelta = { deltas.append($0) }
        host.zoomInput.onSteps = { steps += $0 }

        XCTAssertFalse(host.handleSurfaceEvent(try scrollEvent(deltaY: 10)))
        XCTAssertEqual(deltas, [])
        XCTAssertTrue(host.handleSurfaceEvent(try scrollEvent(deltaY: 10, flags: .maskShift)))
        XCTAssertEqual(deltas, [10])
        XCTAssertFalse(host.handleSurfaceEvent(try scrollEvent(deltaY: 0, deltaX: 20, flags: .maskShift)))
        XCTAssertTrue(host.handleSurfaceEvent(try scrollEvent(deltaY: 10, flags: .maskAlternate)))
        XCTAssertEqual(steps, 1)
        XCTAssertEqual(deltas, [10])
        XCTAssertFalse(host.handleSurfaceEvent(try scrollEvent(deltaY: 10, flags: .maskCommand)))
        host.scrollAdjustsOpacity = true
        XCTAssertTrue(host.handleSurfaceEvent(try scrollEvent(deltaY: -10)))
        XCTAssertEqual(deltas, [10, -10])
    }

    @MainActor
    func testPanelAndTabZoomUseSeparatePersistedValuesAndBounds() throws {
        let name = "SurfaceGestureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = PanelPreferences(defaults: defaults)
        let tab = DraggableTabHostingView(rootView: Color.red)
        tab.zoomInput.onSteps = { settings.adjustBarZoom(steps: $0) }
        tab.zoomInput.currentZoom = { settings.barZoom }
        let panel = OpacityAdjustingHostingView(rootView: Color.blue)
        panel.zoomInput.range = PanelPreferences.zoomRange
        panel.zoomInput.onSteps = {
            settings.setZoom(settings.zoom + Double($0) * PanelPreferences.barZoomGestureStep)
        }
        panel.zoomInput.currentZoom = { settings.zoom }

        tab.zoomInput.handleMagnification(-2, phase: .began)
        XCTAssertEqual(settings.barZoom, 0.6, accuracy: 0.0001)
        XCTAssertEqual(settings.zoom, 1)
        tab.zoomInput.handleMagnification(0.05, phase: .changed)
        XCTAssertEqual(settings.barZoom, 0.65, accuracy: 0.0001)
        panel.zoomInput.handleMagnification(2, phase: .began)
        XCTAssertEqual(settings.zoom, 2, accuracy: 0.0001)
        XCTAssertEqual(settings.barZoom, 0.65, accuracy: 0.0001)
        panel.zoomInput.handleMagnification(-0.05, phase: .changed)
        XCTAssertEqual(settings.zoom, 1.95, accuracy: 0.0001)
        let reloaded = PanelPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.zoom, 1.95, accuracy: 0.0001)
        XCTAssertEqual(reloaded.barZoom, 0.65, accuracy: 0.0001)
    }

    @MainActor
    func testTabScrollChangesOnlyItsWindowAlphaWithoutZooming() throws {
        let name = "SurfaceGestureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SurfaceOpacityPreferences(defaults: defaults)
        let tab = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let panel = NSPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let host = DraggableTabHostingView(rootView: Color.red)
        var zoomSteps = 0
        host.zoomInput.onSteps = { zoomSteps += $0 }
        host.onOpacityDelta = { delta in
            tab.alphaValue = settings.setOpacity(
                TabPositioning.adjustedOpacity(current: tab.alphaValue, scrollDeltaY: delta), for: .tab)
        }
        host.scrollWheel(with: try scrollEvent(deltaY: -100))
        XCTAssertEqual(tab.alphaValue, 0.8, accuracy: 0.0001)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(zoomSteps, 0)
        host.scrollWheel(with: try scrollEvent(deltaY: 10, flags: .maskAlternate))
        XCTAssertEqual(zoomSteps, 1)
        XCTAssertEqual(tab.alphaValue, 0.8, accuracy: 0.0001)
        XCTAssertEqual(SurfaceOpacityPreferences(defaults: defaults).opacity(for: .tab), 0.8, accuracy: 0.0001)
        XCTAssertFalse(tab.isVisible)
        XCTAssertFalse(panel.isVisible)
    }

    private func scrollEvent(deltaY: Int32, deltaX: Int32 = 0,
                             flags: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
