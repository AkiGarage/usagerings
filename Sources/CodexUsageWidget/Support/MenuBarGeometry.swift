import AppKit

/// Pure menu-bar geometry used by tests and the AppKit shell.
///
/// A window frame and its visible frame must always come from the same screen.
/// Keeping that pairing here avoids measuring one screen's frame against
/// another screen's menu-bar inset.
enum MenuBarGeometry {
    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    static let emergencyFallbackHeight: CGFloat = 24

    static func height(
        screenFrame: CGRect?,
        visibleFrame: CGRect?,
        mainMenuHeight: CGFloat?,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        if let screenFrame, let visibleFrame {
            let candidate = screenFrame.maxY - visibleFrame.maxY
            if candidate.isFinite, candidate > 0 { return candidate }
        }
        if let mainMenuHeight, mainMenuHeight.isFinite, mainMenuHeight > 0 {
            return mainMenuHeight
        }
        if statusBarThickness.isFinite, statusBarThickness > 0 {
            return statusBarThickness
        }
        return emergencyFallbackHeight
    }

    /// Select the screen with the largest overlap with `frame`. If the frame is
    /// outside every screen, choose the nearest screen by center distance.
    static func screen(for frame: CGRect, screens: [Screen]) -> Screen? {
        guard !screens.isEmpty else { return nil }

        let candidates = screens.map { screen in
            (screen: screen, area: intersectionArea(frame, screen.frame))
        }
        if let best = candidates.max(by: { lhs, rhs in
            if lhs.area == rhs.area {
                return centerDistance(frame, lhs.screen.frame) > centerDistance(frame, rhs.screen.frame)
            }
            return lhs.area < rhs.area
        }), best.area > 0 {
            return best.screen
        }

        return screens.min {
            centerDistance(frame, $0.frame) < centerDistance(frame, $1.frame)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.intersection(rhs).width * lhs.intersection(rhs).height
    }

    private static func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }
}
