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
    static let cloudSyncKey = "cloudSnapshotSyncEnabledV1"
    @Published private(set) var cloudSyncEnabled: Bool
    @Published private(set) var cloudSyncStopping = false
    var onCloudSyncChange: ((Bool) async -> Void)?

    func setCloudSyncEnabled(_ enabled: Bool) {
        guard !cloudSyncStopping, enabled != cloudSyncEnabled else { return }
        if enabled {
            cloudSyncEnabled = true
            defaults.set(true, forKey: Self.cloudSyncKey)
            Task { await onCloudSyncChange?(true) }
        } else {
            cloudSyncStopping = true
            defaults.set(false, forKey: Self.cloudSyncKey)
            Task {
                await onCloudSyncChange?(false)
                cloudSyncEnabled = false
                cloudSyncStopping = false
            }
        }
    }
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
    static let accountPreferencesKey = "multiAccountPreferencesV1"
    static let accountPreferencesBackupKey = "multiAccountPreferencesV1Backup"
    static let accountPreferencesArchiveKey = "multiAccountPreferencesArchiveV1"
    @Published private(set) var accountPreferences: AccountPreferences
    private let canSaveAccountPreferences: Bool
    static let providerVisibilityKey = "multiProviderVisibilityV1"
    /// Explicit per-provider choice. Missing = automatic (shown once the provider reports data).
    @Published private(set) var providerVisibility: [String: Bool]
    var onProviderVisibilityChange: ((_ turnedOn: Bool) -> Void)?
    static let claudeAutoSwitchKey = "multiClaudeAutoSwitchV1"
    /// Let UsageRings decide which Claude profile claude-ab tries first. Default on.
    @Published var claudeAutoSwitch: Bool {
        didSet {
            defaults.set(claudeAutoSwitch, forKey: Self.claudeAutoSwitchKey)
            onClaudeAutoSwitchChange?(claudeAutoSwitch)
        }
    }
    var onClaudeAutoSwitchChange: ((Bool) -> Void)?
    /// Providers with no explicit choice and no data yet are re-probed at most this often.
    static let autoProbeInterval: TimeInterval = 30 * 60
    private var lastAutoProbe: [ProviderID: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cloudSyncEnabled = defaults.bool(forKey: Self.cloudSyncKey)
        _ = AccountIdentitySalt.load(defaults: defaults)
        let stored = defaults.object(forKey: Self.zoomKey) as? Double ?? 1
        zoom = Self.clamped(stored)
        let storedBarZoom = defaults.object(forKey: Self.barZoomKey) as? Double ?? 1
        barZoom = Self.clampedBarZoom(storedBarZoom)
        orientation = PanelOrientation(rawValue: defaults.string(forKey: Self.orientationKey) ?? "") ?? .horizontal
        appearance = PanelAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        showAccountNames = defaults.bool(forKey: Self.showAccountNamesKey)
        splitAntigravityAccounts = defaults.bool(forKey: Self.splitAntigravityAccountsKey)
        claudeAutoSwitch = defaults.object(forKey: Self.claudeAutoSwitchKey) as? Bool ?? true
        providerVisibility = (defaults.dictionary(forKey: Self.providerVisibilityKey) as? [String: Bool] ?? [:])
            .filter { ProviderID(rawValue: $0.key) != nil }
        if let data = defaults.data(forKey: Self.accountPreferencesKey) {
            do {
                accountPreferences = try JSONDecoder().decode(AccountPreferences.self, from: data)
                canSaveAccountPreferences = true
            } catch {
                if defaults.object(forKey: Self.accountPreferencesBackupKey) == nil {
                    defaults.set(data, forKey: Self.accountPreferencesBackupKey)
                }
                accountPreferences = AccountPreferences()
                canSaveAccountPreferences = false
            }
        } else {
            accountPreferences = AccountPreferences()
            canSaveAccountPreferences = true
        }
    }

    func setAccountLabel(_ label: String, for id: AccountID) {
        accountPreferences.setLabel(label, for: id)
        saveAccounts()
    }

    func setAccountVisible(_ visible: Bool, for id: AccountID) {
        accountPreferences.setVisible(visible, for: id)
        saveAccounts()
    }

    func setPrimaryAccount(_ id: AccountID?, for provider: ProviderID) {
        accountPreferences.setPrimary(id, for: provider)
        saveAccounts()
    }

    func isProviderVisible(_ provider: ProviderID) -> Bool { providerVisibility[provider.rawValue] == true }

    /// Hidden providers are not fetched at all.
    var disabledProviders: Set<ProviderID> {
        Set(ProviderID.allCases.filter { providerVisibility[$0.rawValue] == false })
    }

    /// Providers to skip on this refresh: explicit off, plus undecided providers probed recently.
    /// Calling this marks the undecided providers that will be probed now.
    func providersToSkip(now: Date = Date()) -> Set<ProviderID> {
        var skip = disabledProviders
        for provider in ProviderID.allCases where providerVisibility[provider.rawValue] == nil {
            if let last = lastAutoProbe[provider], now.timeIntervalSince(last) < Self.autoProbeInterval {
                skip.insert(provider)
            } else {
                lastAutoProbe[provider] = now
            }
        }
        return skip
    }

    func setProviderVisible(_ visible: Bool, for provider: ProviderID) {
        guard providerVisibility[provider.rawValue] != visible else { return }
        providerVisibility[provider.rawValue] = visible
        defaults.set(providerVisibility, forKey: Self.providerVisibilityKey)
        onProviderVisibilityChange?(visible)
    }

    /// Automatic default: a provider with no explicit choice is turned on (and remembered)
    /// the first time it reports configured usage data. Never turns anything off.
    func reconcileProviders(in snapshot: MultiUsageSnapshot) {
        var changed = false
        for section in snapshot.sections where providerVisibility[section.provider.rawValue] == nil
            && Self.hasConfiguredData(section) {
            providerVisibility[section.provider.rawValue] = true
            changed = true
        }
        if changed { defaults.set(providerVisibility, forKey: Self.providerVisibilityKey) }
    }

    static func hasConfiguredData(_ section: ProviderSection) -> Bool {
        !section.windows.isEmpty || section.accounts.contains { $0.id != nil && $0.failureText == nil }
    }

    func reconcileAccounts(in snapshot: MultiUsageSnapshot, now: Date = Date()) {
        guard canSaveAccountPreferences else { return }
        var updated = accountPreferences
        let archived = updated.reconcile(snapshot, now: now, salt: AccountIdentitySalt.load(defaults: defaults))
        guard updated != accountPreferences else { return }
        if !archived.observations.isEmpty, let data = try? JSONEncoder().encode(archived) {
            // Keep expired choices recoverable outside the active preferences.
            var archive = defaults.array(forKey: Self.accountPreferencesArchiveKey) as? [Data] ?? []
            archive.append(data)
            defaults.set(archive, forKey: Self.accountPreferencesArchiveKey)
        }
        accountPreferences = updated
        saveAccounts()
    }

    private func saveAccounts() {
        guard canSaveAccountPreferences, let data = try? JSONEncoder().encode(accountPreferences) else { return }
        defaults.set(data, forKey: Self.accountPreferencesKey)
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
