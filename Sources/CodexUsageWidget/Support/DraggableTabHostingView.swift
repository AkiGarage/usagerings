import AppKit
import SwiftUI

final class DraggableTabHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    /// Cursor position in view coordinates while hovered; nil on exit.
    var onMouseMoved: ((NSPoint?) -> Void)?
    var onDragStarted: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onOpacityDelta: ((CGFloat) -> Void)?
    let zoomInput = ZoomGestureInput()

    private var trackingArea: NSTrackingArea?
    private var localMagnifyMonitor: Any?
    private var gestureTap: GestureEventTap?

    /// The tab lives in a non-activating panel that never becomes key, and the app is
    /// usually inactive. AppKit routes trackpad gesture events (magnify) to the key
    /// window of the active app, so `magnify(with:)` on this view never fires; and
    /// `NSEvent.addGlobalMonitorForEvents` does not receive gesture events at all.
    /// A listen-only Quartz event tap does see gestures system-wide, so it is used
    /// and filtered by the cursor being over the tab. A local monitor is the fallback.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let localMagnifyMonitor { NSEvent.removeMonitor(localMagnifyMonitor) }
        localMagnifyMonitor = nil
        gestureTap = nil
        guard window != nil else { return }
        gestureTap = GestureEventTap { [weak self] event in
            self?.handleMonitoredMagnify(event)
        }
        if gestureTap == nil {
            NSLog("CodexUsageWidget: gesture event tap unavailable; tab pinch falls back to local events")
            localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleMonitoredMagnify(event) ?? false }
                return handled ? nil : event
            }
        }
    }

    /// Returns true when the gesture is over the tab (or continues a tab pinch).
    @discardableResult
    func handleMonitoredMagnify(_ event: NSEvent) -> Bool {
        handleTabMagnification(event.magnification, phase: event.phase, mouseLocation: NSEvent.mouseLocation)
    }

    @discardableResult
    func handleTabMagnification(_ magnification: CGFloat, phase: NSEvent.Phase, mouseLocation: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let continuing = zoomInput.isPinchActive && !phase.contains(.began)
        guard continuing || window.frame.contains(mouseLocation) else { return false }
        zoomInput.handleMagnification(magnification, phase: phase)
        return true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        onMouseMoved?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        // View coordinates (flipped-aware); consumers convert to top-left themselves.
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onContextMenu?(event)
            return
        }

        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }

        guard let window else { return }

        zoomInput.isMouseDragging = true
        defer { zoomInput.isMouseDragging = false }
        var startMouse = NSEvent.mouseLocation
        var startOrigin = window.frame.origin
        var didDrag = false

        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            switch nextEvent.type {
            case .leftMouseDragged:
                let currentMouse = NSEvent.mouseLocation
                let delta = NSPoint(
                    x: currentMouse.x - startMouse.x,
                    y: currentMouse.y - startMouse.y
                )
                if !didDrag, hypot(delta.x, delta.y) > 3 {
                    didDrag = true
                    onDragStarted?()
                    let collapsedOrigin = window.frame.origin
                    onMove?(
                        NSPoint(
                            x: collapsedOrigin.x + delta.x,
                            y: collapsedOrigin.y + delta.y
                        )
                    )
                    startMouse = currentMouse
                    startOrigin = window.frame.origin
                    continue
                }
                if didDrag {
                    onMove?(NSPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y))
                }
            case .leftMouseUp:
                if didDrag {
                    onMoveEnded?()
                } else {
                    onClick?()
                }
                return
            default:
                break
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    override func scrollWheel(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        zoomInput.handleModifierFlagsChanged(optionPressed: option)
        if option, zoomInput.handleScroll(deltaY: event.scrollingDeltaY,
                                         hasPreciseScrolling: event.hasPreciseScrollingDeltas,
                                         hasMomentum: event.momentumPhase != []) {
            return
        }
        let deltaY = event.scrollingDeltaY
        guard deltaY.isFinite, deltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        onOpacityDelta?(deltaY)
    }

    override func flagsChanged(with event: NSEvent) {
        zoomInput.handleModifierFlagsChanged(optionPressed: event.modifierFlags.contains(.option))
        super.flagsChanged(with: event)
    }

    override func magnify(with event: NSEvent) {
        // Delivered directly only when the monitors are absent (e.g. no window yet).
        if localMagnifyMonitor == nil, gestureTap == nil {
            zoomInput.handleMagnification(event.magnification, phase: event.phase)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        zoomInput.cancelBarZoomGesture()
        super.cancelOperation(sender)
    }
}

/// Listen-only session event tap for trackpad magnify gestures. It never modifies or
/// swallows events. Returns nil if the system refuses the tap.
@MainActor
final class GestureEventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (NSEvent) -> Void

    init?(handler: @escaping (NSEvent) -> Void) {
        self.handler = handler
        // NSEventType.gesture = 29, .magnify = 30
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let owner = Unmanaged<GestureEventTap>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { owner.reenable() }
                    return Unmanaged.passUnretained(cgEvent)
                }
                if let event = NSEvent(cgEvent: cgEvent), event.type == .magnify {
                    MainActor.assumeIsolated { owner.handler(event) }
                }
                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: refcon
        ) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func invalidate() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    isolated deinit {
        invalidate()
    }
}
