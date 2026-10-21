import AppKit
import SwiftUI

@MainActor
final class MultiProviderPersona: AppPersona {
    private let store: MultiUsageStore
    private let preferences = PanelPreferences()
    private let ringHover = RingDetailCardController()
    var panelPreferences: PanelPreferences? { preferences }
    var onPanelContentSizeChange: ((CGSize) -> Void)?
    var ringHoverCard: RingDetailCardController? { ringHover }

    init() {
        store = MultiUsageStore()
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
