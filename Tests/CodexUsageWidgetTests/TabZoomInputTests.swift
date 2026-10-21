import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class TabZoomInputTests: XCTestCase {
    @MainActor
    func testPinchAccumulatesSmallDeltasAndEndsCleanly() throws {
        let defaults = try isolatedDefaults()
        let settings = PanelPreferences(defaults: defaults)
        let view = try zoomHost(settings)
        var began = 0
        view.zoomInput.onInteractionBegan = { began += 1 }
        view.zoomInput.handleMagnification(0.02, phase: .began)
        view.zoomInput.handleMagnification(0.02, phase: .changed)
        XCTAssertEqual(settings.barZoom, 1)
        view.zoomInput.handleMagnification(0.02, phase: .changed)
        XCTAssertEqual(settings.barZoom, 1.05, accuracy: 0.0001)
        XCTAssertEqual(began, 1)

        view.zoomInput.handleMagnification(0.04, phase: .ended)
        XCTAssertEqual(settings.barZoom, 1.1, accuracy: 0.0001)
        view.zoomInput.handleMagnification(0.04, phase: .changed)
        XCTAssertEqual(settings.barZoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 1.1, accuracy: 0.0001)
        view.zoomInput.handleMagnification(0.01, phase: .began)
        view.zoomInput.handleMagnification(0.04, phase: .cancelled)
        XCTAssertEqual(settings.barZoom, 1.15, accuracy: 0.0001)
        view.zoomInput.handleMagnification(0.04, phase: .changed)
        XCTAssertEqual(settings.barZoom, 1.15, accuracy: 0.0001)
        XCTAssertEqual(began, 2)
    }

    @MainActor
    func testPinchReversesImmediatelyAtUpperClamp() throws {
        let defaults = try isolatedDefaults()
        let settings = PanelPreferences(defaults: defaults)
        settings.setBarZoom(2.5)
        let view = try zoomHost(settings)
        view.zoomInput.handleMagnification(0, phase: .began)
        view.zoomInput.handleMagnification(0.2, phase: .changed)
        XCTAssertEqual(settings.barZoom, 2.5, accuracy: 0.0001)
        view.zoomInput.handleMagnification(-0.05, phase: .changed)
        XCTAssertEqual(settings.barZoom, 2.45, accuracy: 0.0001)
        view.zoomInput.handleMagnification(0, phase: .ended)
        XCTAssertEqual(settings.barZoom, 2.45, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 2.45, accuracy: 0.0001)
    }

    @MainActor
    func testOptionScrollSaturatesAtRaisedUpperBoundAndStepsBackDown() throws {
        let defaults = try isolatedDefaults()
        let settings = PanelPreferences(defaults: defaults)
        let view = try zoomHost(settings)
        settings.setBarZoom(2.5)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 40, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 2.5, accuracy: 0.0001)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: -10, hasPreciseScrolling: false, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 2.45, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 2.45, accuracy: 0.0001)
    }

    @MainActor
    func testOptionPreciseAndNormalScrollUseFivePercentStepsAndPersist() throws {
        let defaults = try isolatedDefaults()
        let settings = PanelPreferences(defaults: defaults)
        let view = try zoomHost(settings)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 9, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 1)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 1, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 1.05, accuracy: 0.0001)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: -20, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 0.95, accuracy: 0.0001)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: -1, hasPreciseScrolling: false, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 0.9, accuracy: 0.0001)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 100, hasPreciseScrolling: true, hasMomentum: true))
        XCTAssertEqual(settings.barZoom, 0.9, accuracy: 0.0001)
        view.zoomInput.handleModifierFlagsChanged(optionPressed: true)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 9, hasPreciseScrolling: true, hasMomentum: false))
        view.zoomInput.handleModifierFlagsChanged(optionPressed: false)
        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 1, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(settings.barZoom, 0.9, accuracy: 0.0001)
        XCTAssertEqual(PanelPreferences(defaults: defaults).barZoom, 0.9, accuracy: 0.0001)
    }

    @MainActor
    func testOptionScrollDoesNotAdjustOpacityButNormalScrollDoes() throws {
        let defaults = try isolatedDefaults()
        let settings = PanelPreferences(defaults: defaults)
        let view = DraggableTabHostingView(rootView: Color.red)
        view.zoomInput.onSteps = { settings.adjustBarZoom(steps: $0) }
        view.zoomInput.currentZoom = { settings.barZoom }
        var opacityDeltas: [CGFloat] = []
        view.onOpacityDelta = { opacityDeltas.append($0) }

        XCTAssertTrue(view.zoomInput.handleScroll(deltaY: 20, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(opacityDeltas, [])
        XCTAssertEqual(settings.barZoom, 1.1, accuracy: 0.0001)

        let classic = DraggableTabHostingView(rootView: Color.red)
        classic.onOpacityDelta = { opacityDeltas.append($0) }
        XCTAssertFalse(classic.zoomInput.handleScroll(deltaY: 20, hasPreciseScrolling: true, hasMomentum: false))
        XCTAssertEqual(opacityDeltas, [])
        // A non-Option scroll continues through the production override to opacity.
        classic.scrollWheel(with: try scrollEvent(option: false, deltaY: 12))
        XCTAssertEqual(opacityDeltas, [12])
    }

    @MainActor
    func testZoomCollapseAndMultiHoverKeepsRingsForTheCard() throws {
        let delegate = AppDelegate(persona: MultiProviderPersona())
        delegate.setTabMode(.expanded)
        delegate.handleBarZoomInteractionBegan()
        XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
        // Multi hover must not expand: expanded mode swaps the rings away, so
        // the ring hover card could never appear.
        delegate.handleTabHoverChanged(true)
        XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
        delegate.handleTabHoverChanged(false)
        delegate.handleTabHoverChanged(true)
        XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
    }

    @MainActor
    private func zoomHost(_ settings: PanelPreferences) throws -> DraggableTabHostingView<Color> {
        let view = DraggableTabHostingView(rootView: Color.red)
        view.zoomInput.onSteps = { settings.adjustBarZoom(steps: $0) }
        view.zoomInput.currentZoom = { settings.barZoom }
        return view
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "TabZoomInputTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func scrollEvent(option: Bool, deltaY: CGFloat) throws -> NSEvent {
        var modifiers: NSEvent.ModifierFlags = []
        if option { modifiers.insert(.option) }
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.flags = option ? .maskAlternate : []
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
