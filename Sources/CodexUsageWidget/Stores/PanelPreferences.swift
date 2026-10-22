import AppKit
import SwiftUI

enum PanelOrientation: String, CaseIterable {
    case horizontal, vertical

    var title: String {
        switch self {
        case .horizontal: return "横"
        case .vertical: return "縦"
        }
    }
}

enum PanelAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Follow system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class PanelPreferences: ObservableObject {
    static let zoomKey = "multiPanelZoom"
    static let barZoomKey = "multiBarZoom"
    static let appearanceKey = "multiPanelAppearance"
    static let orientationKey = "multiPanelOrientation"
    static let zoomRange = 0.75...2.0
    static let zoomStep = 0.05
    // The tab scale is independent of the detail panel zoom. Keep its existing defaults key.
    static let barZoomRange = 0.6...2.5
    static let barZoomGestureStep = 0.05
    let defaults: UserDefaults
    @Published private(set) var zoom: Double
    @Published private(set) var barZoom: Double
    @Published var orientation: PanelOrientation {
        didSet { defaults.set(orientation.rawValue, forKey: Self.orientationKey) }
    }
    @Published var appearance: PanelAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            onAppearanceChange?()
        }
    }
    var onAppearanceChange: (() -> Void)?
    static let showAccountNamesKey = "multiShowAccountNames"
    /// Masked account labels for every service that reports one. Default hidden.
    @Published var showAccountNames: Bool {
        didSet { defaults.set(showAccountNames, forKey: Self.showAccountNamesKey) }
    }
    static let splitAntigravityAccountsKey = "multiSplitAntigravityAccounts"
    @Published var splitAntigravityAccounts: Bool {
        didSet { defaults.set(splitAntigravityAccounts, forKey: Self.splitAntigravityAccountsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.zoomKey) as? Double ?? 1
        zoom = Self.clamped(stored)
        let storedBarZoom = defaults.object(forKey: Self.barZoomKey) as? Double ?? 1
        barZoom = Self.clampedBarZoom(storedBarZoom)
        orientation = PanelOrientation(rawValue: defaults.string(forKey: Self.orientationKey) ?? "") ?? .horizontal
        appearance = PanelAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        showAccountNames = defaults.bool(forKey: Self.showAccountNamesKey)
        splitAntigravityAccounts = defaults.bool(forKey: Self.splitAntigravityAccountsKey)
    }

    var percent: Int { Int((zoom * 100).rounded()) }
    var barZoomPercent: Int { Int((barZoom * 100).rounded()) }

    static func toggled(_ appearance: PanelAppearance, effective: ColorScheme) -> PanelAppearance {
        switch appearance {
        case .system:
            return effective == .dark ? .light : .dark
        case .light:
            return .dark
        case .dark:
            return .light
        }
    }

    static func steppedZoom(current: Double, by delta: Double) -> Double {
        guard current.isFinite, delta.isFinite else { return 1 }
        let clamped = min(max(current + delta, zoomRange.lowerBound), zoomRange.upperBound)
        let snapped = (clamped / zoomStep).rounded() * zoomStep
        return min(max(snapped, zoomRange.lowerBound), zoomRange.upperBound)
    }

    func toggleAppearance(effective: ColorScheme) {
        appearance = Self.toggled(appearance, effective: effective)
    }

    func toggleOrientation() {
        orientation = orientation == .horizontal ? .vertical : .horizontal
    }

    func setZoom(_ value: Double) {
        zoom = Self.clamped(value)
        defaults.set(zoom, forKey: Self.zoomKey)
    }
    func zoomIn() { setZoom(Self.steppedZoom(current: zoom, by: 0.25)) }
    func zoomOut() { setZoom(Self.steppedZoom(current: zoom, by: -0.25)) }
    func resetZoom() { setZoom(1) }

    func setBarZoom(_ value: Double) {
        barZoom = Self.clampedBarZoom(value)
        defaults.set(barZoom, forKey: Self.barZoomKey)
    }
    func adjustBarZoom(steps: Int) {
        guard steps != 0 else { return }
        let currentSteps = (barZoom / Self.barZoomGestureStep).rounded()
        setBarZoom((currentSteps + Double(steps)) * Self.barZoomGestureStep)
    }
    func barZoomIn() { setBarZoom(barZoom + 0.25) }
    func barZoomOut() { setBarZoom(barZoom - 0.25) }
    func resetBarZoom() { setBarZoom(1) }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoomIn()
        case "-": zoomOut()
        case "0" where modifiers == .command: resetZoom()
        default: return false
        }
        return true
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    private static func clampedBarZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, barZoomRange.lowerBound), barZoomRange.upperBound)
    }
}

final class UsagePanel: NSPanel {
    var preferences: PanelPreferences?
    var onOrderOut: (() -> Void)?
    override var canBecomeKey: Bool { preferences != nil || super.canBecomeKey }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow, preferences?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onOrderOut?()
    }
}
