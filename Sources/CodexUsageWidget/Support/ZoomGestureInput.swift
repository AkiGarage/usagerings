import AppKit

/// Accumulates the same five-percent gesture steps for either surface.
@MainActor
final class ZoomGestureInput {
    var onSteps: ((Int) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var currentZoom: (() -> Double)?
    var range = PanelPreferences.barZoomRange
    var isMouseDragging = false
    private var pinchZoomResidual: CGFloat = 0
    private var scrollZoomResidual: CGFloat = 0
    private var isBarZoomPinchActive = false
    private var wasOptionPressed = false
    var isPinchActive: Bool { isBarZoomPinchActive }

    func handleMagnification(_ magnification: CGFloat, phase: NSEvent.Phase) {
        guard onSteps != nil, magnification.isFinite, !isMouseDragging else { return }
        let endsGesture = phase.contains(.ended) || phase.contains(.cancelled)
        if phase.contains(.began) {
            beginBarZoomGestureIfNeeded()
        } else if !endsGesture, !isBarZoomPinchActive {
            return
        }
        pinchZoomResidual += magnification
        emitPinchZoomSteps()
        if endsGesture {
            endBarZoomGesture()
        }
    }

    private func beginBarZoomGestureIfNeeded() {
        guard onSteps != nil, !isBarZoomPinchActive, !isMouseDragging else { return }
        isBarZoomPinchActive = true
        pinchZoomResidual = 0
        onInteractionBegan?()
    }

    private func endBarZoomGesture() {
        guard isBarZoomPinchActive else { return }
        pinchZoomResidual = 0
        isBarZoomPinchActive = false
    }

    func cancelBarZoomGesture() {
        guard isBarZoomPinchActive else { return }
        pinchZoomResidual = 0
        isBarZoomPinchActive = false
    }

    func handleScroll(deltaY: CGFloat,
                             hasPreciseScrolling: Bool,
                             hasMomentum: Bool) -> Bool {
        guard onSteps != nil, !isMouseDragging else { return false }
        guard !hasMomentum else { return true }
        guard deltaY.isFinite else { return true }

        if !hasPreciseScrolling {
            guard deltaY != 0 else { return true }
            beginBarZoomInteractionIfNeeded()
            emitZoomStep(deltaY > 0 ? 1 : -1)
            return true
        }

        scrollZoomResidual += CGFloat(deltaY / 200)
        while abs(scrollZoomResidual) + 0.000001 >= PanelPreferences.barZoomGestureStep {
            let step = scrollZoomResidual >= 0 ? 1 : -1
            beginBarZoomInteractionIfNeeded()
            if emitZoomStep(step) {
                scrollZoomResidual -= CGFloat(step) * PanelPreferences.barZoomGestureStep
            } else {
                break
            }
        }
        return true
    }

    func handleModifierFlagsChanged(optionPressed: Bool) {
        if wasOptionPressed && !optionPressed {
            scrollZoomResidual = 0
        }
        wasOptionPressed = optionPressed
    }

    private func beginBarZoomInteractionIfNeeded() {
        onInteractionBegan?()
    }

    private func emitPinchZoomSteps() {
        while abs(pinchZoomResidual) + 0.000001 >= PanelPreferences.barZoomGestureStep {
            let step = pinchZoomResidual >= 0 ? 1 : -1
            beginBarZoomGestureIfNeeded()
            if emitZoomStep(step) {
                pinchZoomResidual -= CGFloat(step) * PanelPreferences.barZoomGestureStep
            } else {
                break
            }
        }
    }

    @discardableResult
    private func emitZoomStep(_ step: Int) -> Bool {
        onSteps?(step)
        guard let zoom = currentZoom?() else { return true }
        if zoom >= range.upperBound, step > 0 {
            pinchZoomResidual = 0
            scrollZoomResidual = 0
            return false
        } else if zoom <= range.lowerBound, step < 0 {
            pinchZoomResidual = 0
            scrollZoomResidual = 0
            return false
        }
        return true
    }
}
