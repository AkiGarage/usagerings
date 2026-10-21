import AppKit
import SwiftUI

/// The seam between the shared app shell and one product personality. The
/// shell owns panels, dragging, hover, opacity, and positioning; the persona
/// owns which store and views run behind them.
@MainActor
protocol AppPersona: AnyObject {
    var quitMenuItemTitle: String { get }
    var panelDefaultSize: NSSize { get }
    var panelMinSize: NSSize { get }
    var panelMaxSize: NSSize { get }
    var panelRootView: AnyView { get }
    var panelPreferences: PanelPreferences? { get }
    var onPanelContentSizeChange: ((CGSize) -> Void)? { get set }
    /// Multi-only: hover detail card for the collapsed tab's rings.
    var ringHoverCard: RingDetailCardController? { get }
    func tabRootView(presentation: EdgeTabPresentationState) -> AnyView
    func start()
    func stop()
    func refresh()
    func showOpacityHUD(percent: Int)
}

extension AppPersona {
    var panelPreferences: PanelPreferences? { nil }
    var ringHoverCard: RingDetailCardController? { nil }
    var onPanelContentSizeChange: ((CGSize) -> Void)? {
        get { nil }
        set { }
    }
}

@MainActor
final class SingleProviderPersona: AppPersona {
    private let store: UsageStore

    init(service: CodexUsageService = CodexUsageService()) {
        store = UsageStore(service: service)
    }

    var quitMenuItemTitle: String { "Quit Codex Usage Widget" }
    var panelDefaultSize: NSSize { TabPositioning.defaultPanelSize }
    var panelMinSize: NSSize { NSSize(width: 180, height: 112) }
    var panelMaxSize: NSSize { NSSize(width: 560, height: 320) }

    var panelRootView: AnyView {
        AnyView(WidgetView(store: store))
    }

    func tabRootView(presentation: EdgeTabPresentationState) -> AnyView {
        AnyView(EdgeTabView(store: store, presentation: presentation))
    }

    func start() { store.start() }
    func stop() { store.stop() }
    func refresh() { store.refresh() }
    func showOpacityHUD(percent: Int) { store.showOpacityHUD(percent: percent) }
}
