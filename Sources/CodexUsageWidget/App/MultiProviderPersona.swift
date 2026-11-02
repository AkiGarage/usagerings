import AppKit
import SwiftUI

@MainActor
final class MultiProviderPersona: AppPersona {
    private let store: MultiUsageStore
    private let preferences: PanelPreferences
    private let ringHover = RingDetailCardController()
    var panelPreferences: PanelPreferences? { preferences }
    var onPanelContentSizeChange: ((CGSize) -> Void)?
    var ringHoverCard: RingDetailCardController? { ringHover }

    init(demoMode: DemoMode = .production) {
        preferences = PanelPreferences(defaults: demoMode.defaults)
        if demoMode.isEnabled {
            store = MultiUsageStore(demoSnapshot: UsageRingsDemoFixture.snapshot())
        } else {
            let live = MultiUsageStore(preferences: preferences)
            store = live
            preferences.onProviderVisibilityChange = { [weak live] turnedOn in
                live?.providerVisibilityChanged(turnedOn: turnedOn)
            }
            preferences.onClaudeAutoSwitchChange = { [weak live] enabled in
                live?.claudeAutoSwitchChanged(enabled: enabled)
            }
            preferences.onCloudSyncChange = { [weak live] enabled in
                await live?.cloudSyncChanged(enabled: enabled)
            }
        }
    }

    var quitMenuItemTitle: String { "Quit UsageRings" }
    var panelDefaultSize: NSSize { NSSize(width: 270, height: 260) }
    var panelMinSize: NSSize { NSSize(width: 180, height: 112) }
    var panelMaxSize: NSSize { NSSize(width: 560, height: 480) }

    var panelRootView: AnyView {
        AnyView(MultiWidgetView(store: store, preferences: preferences) { [weak self] size in
            self?.onPanelContentSizeChange?(size)
        })
    }

    func tabRootView(presentation: EdgeTabPresentationState) -> AnyView {
        ringHover.attach(store: store, preferences: preferences, presentation: presentation)
        return AnyView(MultiEdgeTabView(store: store, presentation: presentation, preferences: preferences,
                                        ringHighlight: ringHover.highlight))
    }

    func start() { store.start() }
    /// nil when there is no live Gemini reader (demo mode or before start).
    var geminiReadingEnabled: Bool? { store.geminiMonitor?.isEnabled }
    func setGeminiReading(_ on: Bool) {
        if on { preferences.setProviderVisible(true, for: .gemini) }
        guard let monitor = store.geminiMonitor else { return }
        Task { @MainActor in await monitor.setEnabled(on) }
    }
    func stop() { store.stop() }
    func refresh() { store.refresh() }
    func showOpacityHUD(percent: Int) { store.showOpacityHUD(percent: percent) }
}
