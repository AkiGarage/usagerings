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

    init(demoMode: DemoMode = .production, demoDummy8: Bool = false,
         demoShrink: Bool = false, demoShrinkDelay: TimeInterval = 0) {
        preferences = PanelPreferences(defaults: demoMode.defaults)
        if demoMode.isEnabled {
            let useDummy8 = demoDummy8 || demoShrink
            if useDummy8 {
                preferences.setBarZoom(2.5)
                preferences.appearance = .dark
                preferences.orientation = .horizontal
            }
            let snapshot = useDummy8 ? UsageRingsDemoFixture.dummy8Snapshot() : UsageRingsDemoFixture.snapshot()
            store = MultiUsageStore(demoSnapshot: snapshot, shrinkTimeline: demoShrink,
                                    shrinkDelay: demoShrinkDelay)
        } else {
            let live = MultiUsageStore(preferences: preferences)
            store = live
            preferences.onProviderVisibilityChange = { [weak live] turnedOn in
                live?.providerVisibilityChanged(turnedOn: turnedOn)
            }
            preferences.onClaudeAutoSwitchChange = { [weak live] enabled in
                live?.claudeAutoSwitchChanged(enabled: enabled)
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
    func stop() { store.stop() }
    func refresh() { store.refresh() }
    func showOpacityHUD(percent: Int) { store.showOpacityHUD(percent: percent) }
}
