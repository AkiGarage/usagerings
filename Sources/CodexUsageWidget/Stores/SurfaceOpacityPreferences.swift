import AppKit

@MainActor
final class SurfaceOpacityPreferences {
    enum Surface: String { case tab, panel }
    nonisolated static let range = 0.2...1.0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func opacity(for surface: Surface) -> CGFloat {
        Self.clamped(defaults.object(forKey: key(for: surface)) as? Double ?? 1)
    }

    @discardableResult
    func setOpacity(_ value: CGFloat, for surface: Surface) -> CGFloat {
        let value = Self.clamped(value)
        defaults.set(value, forKey: key(for: surface))
        return value
    }

    private func key(for surface: Surface) -> String { "\(surface.rawValue)WindowOpacity" }

    nonisolated static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
