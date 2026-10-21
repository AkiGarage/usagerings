import AppKit
import SwiftUI

final class OpacityAdjustingHostingView<Content: View>: NSHostingView<Content> {
    var onOpacityDelta: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    var scrollAdjustsOpacity = true

    let zoomInput = ZoomGestureInput()
    private var gestureMonitor: Any?

    deinit {
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
    }

    private var resizeCursorTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
        gestureMonitor = nil
        if window != nil {
            // Intercept only our surface, before a nested SwiftUI ScrollView consumes it.
            gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .flagsChanged]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return false }
                    if event.type == .flagsChanged {
                        self.zoomInput.handleModifierFlagsChanged(optionPressed: event.modifierFlags.contains(.option))
                        return false
                    }
                    guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return false }
                    return self.handleSurfaceEvent(event)
                }
                return handled ? nil : event
            }
        }
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeCursorTrackingArea {
            removeTrackingArea(resizeCursorTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .cursorUpdate,
                .enabledDuringMouseDrag,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        resizeCursorTrackingArea = trackingArea
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in PanelResizeCursorRegion.regions(in: bounds, isFlipped: isFlipped) {
            addCursorRect(region.rect, cursor: region.cursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        setResizeCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setResizeCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else {
            super.mouseDown(with: event)
            return
        }

        onDoubleClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        if !handleSurfaceEvent(event) { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if !handleSurfaceEvent(event) { super.magnify(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        zoomInput.cancelBarZoomGesture()
        super.cancelOperation(sender)
    }

    /// Returns false for ordinary content scrolling, leaving the event untouched.
    func handleSurfaceEvent(_ event: NSEvent) -> Bool {
        if event.type == .magnify {
            guard zoomInput.onSteps != nil else { return false }
            zoomInput.handleMagnification(event.magnification, phase: event.phase)
            return true
        }
        guard event.type == .scrollWheel else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        zoomInput.handleModifierFlagsChanged(optionPressed: modifiers.contains(.option))
        if modifiers == .option {
            return zoomInput.handleScroll(deltaY: event.scrollingDeltaY,
                                          hasPreciseScrolling: event.hasPreciseScrollingDeltas,
                                          hasMomentum: event.momentumPhase != [])
        }
        guard modifiers == .shift || (modifiers.isEmpty && scrollAdjustsOpacity) else { return false }
        // macOS moves a Shift+mouse-wheel delta into deltaX; accept it so wheel users can adjust too.
        let usesSwappedWheel = modifiers == .shift && !event.hasPreciseScrollingDeltas && event.scrollingDeltaY == 0
        let deltaY = usesSwappedWheel ? event.scrollingDeltaX : event.scrollingDeltaY
        guard deltaY.isFinite, deltaY != 0,
              usesSwappedWheel || abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              let onOpacityDelta else { return false }
        onOpacityDelta(deltaY)
        return true
    }

    private func setResizeCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cursor = PanelResizeCursorRegion.cursor(at: point, in: bounds, isFlipped: isFlipped) ?? .arrow
        cursor.set()
    }
}

struct PanelResizeCursorRegion {
    enum Placement: CaseIterable, Hashable {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    static let edgeThickness: CGFloat = 3
    static let cornerLength: CGFloat = 3

    let placement: Placement
    let rect: NSRect

    var cursor: NSCursor {
        placement.cursor
    }

    static func regions(in bounds: NSRect, isFlipped: Bool) -> [PanelResizeCursorRegion] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }

        let thickness = min(edgeThickness, bounds.width / 2, bounds.height / 2)
        let cornerWidth = min(cornerLength, bounds.width / 2)
        let cornerHeight = min(cornerLength, bounds.height / 2)
        let sideHeight = max(0, bounds.height - cornerHeight * 2)
        let horizontalWidth = max(0, bounds.width - cornerWidth * 2)
        let topY = isFlipped ? bounds.minY : bounds.maxY - cornerHeight
        let bottomY = isFlipped ? bounds.maxY - cornerHeight : bounds.minY
        let topEdgeY = isFlipped ? bounds.minY : bounds.maxY - thickness
        let bottomEdgeY = isFlipped ? bounds.maxY - thickness : bounds.minY

        let regions = [
            PanelResizeCursorRegion(
                placement: .topLeft,
                rect: NSRect(x: bounds.minX, y: topY, width: cornerWidth, height: cornerHeight)
            ),
            PanelResizeCursorRegion(
                placement: .top,
                rect: NSRect(x: bounds.minX + cornerWidth, y: topEdgeY, width: horizontalWidth, height: thickness)
            ),
            PanelResizeCursorRegion(
                placement: .topRight,
                rect: NSRect(x: bounds.maxX - cornerWidth, y: topY, width: cornerWidth, height: cornerHeight)
            ),
            PanelResizeCursorRegion(
                placement: .right,
                rect: NSRect(x: bounds.maxX - thickness, y: bounds.minY + cornerHeight, width: thickness, height: sideHeight)
            ),
            PanelResizeCursorRegion(
                placement: .bottomRight,
                rect: NSRect(x: bounds.maxX - cornerWidth, y: bottomY, width: cornerWidth, height: cornerHeight)
            ),
            PanelResizeCursorRegion(
                placement: .bottom,
                rect: NSRect(x: bounds.minX + cornerWidth, y: bottomEdgeY, width: horizontalWidth, height: thickness)
            ),
            PanelResizeCursorRegion(
                placement: .bottomLeft,
                rect: NSRect(x: bounds.minX, y: bottomY, width: cornerWidth, height: cornerHeight)
            ),
            PanelResizeCursorRegion(
                placement: .left,
                rect: NSRect(x: bounds.minX, y: bounds.minY + cornerHeight, width: thickness, height: sideHeight)
            )
        ]
        return regions.filter { $0.rect.width > 0 && $0.rect.height > 0 }
    }

    static func cursor(at point: NSPoint, in bounds: NSRect, isFlipped: Bool) -> NSCursor? {
        regions(in: bounds, isFlipped: isFlipped)
            .first { $0.rect.contains(point) }?
            .cursor
    }
}

private extension PanelResizeCursorRegion.Placement {
    var cursor: NSCursor {
        if let frameResizeCursor {
            return frameResizeCursor
        }

        switch self {
        case .top:
            return .resizeUp
        case .right, .topRight, .bottomRight:
            return .resizeRight
        case .bottom:
            return .resizeDown
        case .left, .topLeft, .bottomLeft:
            return .resizeLeft
        }
    }

    private var frameResizeCursor: NSCursor? {
        let selector = NSSelectorFromString("frameResizeCursorFromPosition:inDirections:")
        guard NSCursor.responds(to: selector),
              let method = NSCursor.method(for: selector)
        else {
            return nil
        }
        typealias FrameResizeCursorFunction = @convention(c) (AnyClass, Selector, UInt, UInt) -> NSCursor
        let function = unsafeBitCast(method, to: FrameResizeCursorFunction.self)
        let cursor = function(NSCursor.self, selector, frameResizePositionRawValue, 1)
        guard cursor.image.size != .zero else { return nil }
        return cursor
    }

    private var frameResizePositionRawValue: UInt {
        switch self {
        case .topLeft:
            return 3
        case .top:
            return 1
        case .topRight:
            return 9
        case .right:
            return 8
        case .bottomRight:
            return 12
        case .bottom:
            return 4
        case .bottomLeft:
            return 6
        case .left:
            return 2
        }
    }
}
