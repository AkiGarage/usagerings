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
