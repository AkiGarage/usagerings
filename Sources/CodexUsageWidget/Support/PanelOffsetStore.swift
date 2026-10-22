import AppKit
import Foundation

struct PanelOffsetStore {
    private static let offsetXKey = "panelOffsetX"
    private static let offsetYKey = "panelOffsetY"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasSavedOffset: Bool {
        defaults.object(forKey: Self.offsetXKey) != nil
            && defaults.object(forKey: Self.offsetYKey) != nil
    }

    func load() -> NSSize? {
        guard hasSavedOffset else { return nil }
        return NSSize(
            width: defaults.double(forKey: Self.offsetXKey),
            height: defaults.double(forKey: Self.offsetYKey)
        )
    }

    func save(_ offset: NSSize) {
        defaults.set(offset.width, forKey: Self.offsetXKey)
        defaults.set(offset.height, forKey: Self.offsetYKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.offsetXKey)
        defaults.removeObject(forKey: Self.offsetYKey)
    }
}

struct TabOriginStore {
    private static let originXKey = "tabOriginX"
    private static let originYKey = "tabOriginY"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NSPoint? {
        guard defaults.object(forKey: Self.originXKey) != nil,
              defaults.object(forKey: Self.originYKey) != nil
        else { return nil }
        return NSPoint(x: defaults.double(forKey: Self.originXKey),
                       y: defaults.double(forKey: Self.originYKey))
    }

    func save(_ origin: NSPoint) {
        defaults.set(origin.x, forKey: Self.originXKey)
        defaults.set(origin.y, forKey: Self.originYKey)
    }
}
