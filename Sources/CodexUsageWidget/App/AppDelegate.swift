import AppKit
import Sparkle
import SwiftUI

enum NanoUpdaterPolicy {
    static let bridgeBuild = 2
    static let testOnlyBuild = 3
    static let firstPublicAutoUpdateBuild = 4
    static let productionFeedURL = "https://akigarage.github.io/codex-usage-nano/appcast.xml"

    static func isAllowedPublicAutoUpdate(build: Int) -> Bool {
        build >= firstPublicAutoUpdateBuild
    }

    static func isForwardFix(from currentBuild: Int, to candidateBuild: Int) -> Bool {
        candidateBuild > currentBuild && isAllowedPublicAutoUpdate(build: candidateBuild)
    }
}

enum NanoUpdaterConfiguration {
    static func isValid(info: [String: Any]) -> Bool {
        guard info["CFBundleIdentifier"] as? String == "local.codex.CodexUsageNano",
              info["SUFeedURL"] as? String == NanoUpdaterPolicy.productionFeedURL,
              let encodedKey = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: encodedKey)?.count == 32,
              (info["SURequireSignedFeed"] as? NSNumber)?.boolValue == true,
              (info["SUVerifyUpdateBeforeExtraction"] as? NSNumber)?.boolValue == true,
              (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.intValue == 0,
              (info["SUAllowsAutomaticUpdates"] as? NSNumber)?.boolValue == false,
              info["SUEnableAutomaticChecks"] == nil
        else {
            return false
        }
        return true
    }
}

@MainActor
final class NanoUpdateController {
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        guard let info = bundle.infoDictionary,
              NanoUpdaterConfiguration.isValid(info: info)
        else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool {
        controller != nil
    }

    func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let persona: any AppPersona
    private let tabPresentation = EdgeTabPresentationState()
    private let panelOffsetStore = PanelOffsetStore()
    private let opacityPreferences = SurfaceOpacityPreferences()
    private var panelSize: NSSize { persona.panelDefaultSize }
    private let tabOriginXKey = "tabOriginX"
    private let tabOriginYKey = "tabOriginY"
    private let debugOpenPanelOnLaunchKey = "debugOpenPanelOnLaunch"
    private var panel: NSPanel?
    private var tabPanel: NSPanel?
    private var isTabDragging = false
    private var isPositioningPanel = false
    private var isPanelLiveResizing = false
    private var hadSavedPanelOffsetAtResizeStart = false
    /// Blocks hover→.expanded until the pointer leaves. For personas with a ring hover card this is a no-op on the hover path (they never expand by hover); still set by drag/zoom/orientation flows.
    private var suppressHoverExpansionUntilExit = false
    private var didExitDuringDrag = false
    private var screenParametersObserver: NSObjectProtocol?
    private var lastTabScreenGeometry: MenuBarGeometry.Screen?
    private var updateController: NanoUpdateController?

    @MainActor
    init(persona: (any AppPersona)? = nil) {
        self.persona = persona ?? makeAppPersona(
            for: AppVariant.current(bundleIdentifier: Bundle.main.bundleIdentifier)
        )
        super.init()
    }

    var tabPresentationModeForTesting: EdgeTabPresentationMode {
        tabPresentation.mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createTabPanel()
        updateController = NanoUpdateController()
        persona.start()
        showPanelOnLaunchIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persona.stop()
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            persona.refresh()
            if panel.alphaValue <= 0.01 {
                setPanelOpacity(1, showsHUD: false)
            }
            showPanel(context: "toggle")
        }
    }

    private func showPanelOnLaunchIfRequested() {
        guard UserDefaults.standard.bool(forKey: debugOpenPanelOnLaunchKey) else { return }
        UserDefaults.standard.removeObject(forKey: debugOpenPanelOnLaunchKey)
        DispatchQueue.main.async { [weak self] in
            self?.persona.refresh()
            self?.showPanel(context: "debug-open-panel-on-launch")
        }
    }

    private func createPanel() {
        let panel = UsagePanel(
            contentRect: frameNearTab(for: panelSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = TabPositioning.windowLevel
        panel.minSize = persona.panelMinSize
        panel.maxSize = persona.panelMaxSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        panel.alphaValue = opacityPreferences.opacity(for: .panel)
        panel.preferences = persona.panelPreferences
        if let preferences = persona.panelPreferences {
            Self.applyAppearance(preferences.appearance, to: [panel])
            persona.onPanelContentSizeChange = { [weak self] size in
                // Geometry delivery occurs during SwiftUI layout; resize on the next turn.
                DispatchQueue.main.async { self?.fitPanel(to: size) }
            }
        }
        panel.onOrderOut = { [weak self] in self?.detachPanelContent() }
        self.panel = panel
        if let preferences = persona.panelPreferences {
            Self.bindAppearanceUpdates(for: preferences) { [weak self] in
                [self?.panel, self?.tabPanel]
            }
        }
    }

    /// The hidden panel keeps no SwiftUI hierarchy: it is built on show and released on
    /// hide, so a closed window costs neither memory nor per-refresh layout work.
    private var panelContentAttached = false

    private func attachPanelContentIfNeeded() {
        guard let panel, !panelContentAttached else { return }
        panel.contentView = makePanelContentView()
        panelContentAttached = true
    }

    private func detachPanelContent() {
        guard let panel, panelContentAttached else { return }
        panelContentAttached = false
        panel.contentView = NSView(frame: panel.contentLayoutRect)
    }

    private func makePanelContentView() -> NSView {
        let panelView = OpacityAdjustingHostingView(rootView: persona.panelRootView)
        if let preferences = persona.panelPreferences {
            panelView.sizingOptions = []
            panelView.scrollAdjustsOpacity = false
            panelView.zoomInput.range = PanelPreferences.zoomRange
            panelView.zoomInput.onSteps = { [weak preferences] steps in
                guard let preferences else { return }
                preferences.setZoom(PanelPreferences.steppedZoom(
                    current: preferences.zoom,
                    by: Double(steps) * PanelPreferences.zoomStep
                ))
            }
            panelView.zoomInput.currentZoom = { [weak preferences] in preferences?.zoom ?? 1 }
        }
        panelView.onOpacityDelta = { [weak self] deltaY in
            self?.adjustPanelOpacity(deltaY: deltaY, context: "panel-scroll")
        }
        panelView.onDoubleClick = { [weak self] in
            self?.resetPanelSizeAndShow()
        }
        return panelView
    }

    private func fitPanel(to contentSize: CGSize) {
        guard let panel, contentSize.width > 0, contentSize.height > 0 else { return }
        let visible = visibleFrame(containing: panel.frame)
        let size = Self.panelViewportSize(content: contentSize, visibleFrame: visible)
        panel.minSize = .zero
        panel.maxSize = NSSize(width: max(size.width, persona.panelMaxSize.width),
                               height: max(size.height, persona.panelMaxSize.height))
        guard panel.frame.size != size else { return }
        let origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - size.height)
        setPanelFrame(constrainedPanelFrame(NSRect(origin: origin, size: size)))
    }

    static func panelViewportSize(content: CGSize, visibleFrame: NSRect) -> CGSize {
        CGSize(width: min(ceil(content.width), max(1, visibleFrame.width - 16)),
               height: min(ceil(content.height), max(1, visibleFrame.height - 16)))
    }

    static func bindAppearanceUpdates(for preferences: PanelPreferences,
                                      windows: @escaping () -> [NSWindow?]) {
        preferences.onAppearanceChange = { [weak preferences] in
            guard let preferences else { return }
            applyAppearance(preferences.appearance, to: windows())
        }
        applyAppearance(preferences.appearance, to: windows())
    }

    static func applyAppearance(_ appearance: PanelAppearance, to windows: [NSWindow?]) {
        for window in windows {
            window?.appearance = appearance.nsAppearance
        }
    }

    private func createTabPanel() {
        tabPresentation.onSizeChange = { [weak self] in
            guard let self else { return }
            self.setTabMode(self.tabPresentation.mode)
        }
        let tabPanel = NSPanel(
            contentRect: frameForTab(),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        tabPanel.alphaValue = opacityPreferences.opacity(for: .tab)
        tabPanel.isOpaque = false
        tabPanel.backgroundColor = .clear
        if let appearance = persona.panelPreferences?.appearance {
            Self.applyAppearance(appearance, to: [tabPanel])
        }
        tabPanel.hasShadow = true
        tabPanel.animationBehavior = .none
        tabPanel.level = TabPositioning.windowLevel
        tabPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        tabPanel.delegate = self
        let tabView = DraggableTabHostingView(rootView: persona.tabRootView(presentation: tabPresentation))
        tabView.sizingOptions = []
        tabView.onClick = { [weak self] in
            self?.togglePanel()
        }
        tabView.onDoubleClick = { [weak self] in
            self?.persona.panelPreferences?.resetBarZoom()
            self?.setTabOpacity(1, showsHUD: true)
            self?.resetPanelPositionOpacityAndShow()
        }
        tabView.onOpacityDelta = { [weak self] deltaY in
            guard let self, let tabPanel = self.tabPanel else { return }
            self.setTabOpacity(TabPositioning.adjustedOpacity(current: tabPanel.alphaValue,
                                                              scrollDeltaY: deltaY), showsHUD: true)
        }
        tabView.onContextMenu = { [weak self, weak tabView] event in
            guard let tabView else { return }
            self?.showTabMenu(for: tabView, event: event)
        }
        tabView.onHoverChanged = { [weak self] isHovering in
            self?.handleTabHoverChanged(isHovering)
        }
        tabView.onMouseMoved = { [weak self, weak tabView] point in
            guard let self, let tabView else { return }
            self.persona.ringHoverCard?.mouseMoved(to: point, in: tabView)
        }
        tabView.onDragStarted = { [weak self] in
            self?.handleTabDragStarted()
        }
        tabView.onMove = { [weak self] origin in
            self?.moveTab(to: origin)
        }
        tabView.onMoveEnded = { [weak self] in
            self?.handleTabDragEnded()
        }
        if let preferences = persona.panelPreferences {
            tabView.zoomInput.onInteractionBegan = { [weak self] in
                self?.handleBarZoomInteractionBegan()
            }
            tabView.zoomInput.onSteps = { [weak self] steps in
                self?.handleBarZoomSteps(steps)
            }
            tabView.zoomInput.currentZoom = { [weak preferences] in
                preferences?.barZoom ?? 1
            }
        }
        tabPanel.contentView = tabView
        self.tabPanel = tabPanel
        persona.ringHoverCard?.watchTabPanel(tabPanel)
        observeTabScreenGeometry()
        refreshTabScreenGeometry()
        setTabMode(tabPresentation.mode)
    }

    private func showTabMenu(for view: NSView, event: NSEvent) {
        NSMenu.popUpContextMenu(makeTabMenu(), with: event, for: view)
    }

    func makeTabMenu() -> NSMenu {
        let menu = NSMenu()
        let toggleTitle = panel?.isVisible == true ? "Hide Panel" : "Show Panel"
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshUsage), keyEquivalent: ""))
        if updateController?.isAvailable == true {
            menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        }
        if let preferences = persona.panelPreferences {
            menu.addItem(.separator())
            let orientationToggle = NSMenuItem(
                title: preferences.orientation == .horizontal ? "縦表示に切り替え" : "横表示に切り替え",
                action: #selector(togglePanelOrientation), keyEquivalent: "")
            orientationToggle.target = self
            menu.addItem(orientationToggle)
            let view = NSMenuItem(title: "表示", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            func item(_ title: String, _ action: Selector, enabled: Bool = true) {
                let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
                i.target = self; i.isEnabled = enabled; sub.addItem(i)
            }
            sub.autoenablesItems = false
            item("パネル拡大", #selector(panelZoomIn), enabled: preferences.zoom < PanelPreferences.zoomRange.upperBound)
            item("パネル縮小", #selector(panelZoomOut), enabled: preferences.zoom > PanelPreferences.zoomRange.lowerBound)
            item("パネル 100%（今 \(preferences.percent)%）", #selector(panelZoomReset))
            sub.addItem(.separator())
            item("バー拡大", #selector(barZoomIn), enabled: preferences.barZoom < PanelPreferences.barZoomRange.upperBound)
            item("バー縮小", #selector(barZoomOut), enabled: preferences.barZoom > PanelPreferences.barZoomRange.lowerBound)
            item("バー 100%（今 \(preferences.barZoomPercent)%）", #selector(barZoomReset))
            sub.addItem(.separator())
            let orientationItem = NSMenuItem(title: "表示の向き", action: nil, keyEquivalent: "")
            let orientationMenu = NSMenu()
            for orientation in PanelOrientation.allCases {
                let i = NSMenuItem(title: orientation.title, action: #selector(selectOrientation(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = orientation.rawValue
                i.state = preferences.orientation == orientation ? .on : .off
                orientationMenu.addItem(i)
            }
            orientationItem.submenu = orientationMenu
            sub.addItem(orientationItem)
            sub.addItem(.separator())
            for appearance in PanelAppearance.allCases {
                let i = NSMenuItem(title: appearance.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = appearance.rawValue
                i.state = preferences.appearance == appearance ? .on : .off
                sub.addItem(i)
            }
            sub.addItem(.separator())
            let accounts = NSMenuItem(title: "アカウント名を表示", action: #selector(toggleAccountNames), keyEquivalent: "")
            accounts.target = self
            accounts.state = preferences.showAccountNames ? .on : .off
            sub.addItem(accounts)
            view.submenu = sub
            menu.addItem(view)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: persona.quitMenuItemTitle, action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func panelZoomIn() { persona.panelPreferences?.zoomIn() }
    @objc private func panelZoomOut() { persona.panelPreferences?.zoomOut() }
    @objc private func panelZoomReset() { persona.panelPreferences?.resetZoom() }
    @objc private func togglePanelOrientation() {
        persona.panelPreferences?.toggleOrientation()
        suppressHoverExpansionUntilExit = true
        setTabMode(.collapsed)
    }
    @objc private func barZoomIn() { persona.panelPreferences?.barZoomIn() }
    @objc private func barZoomOut() { persona.panelPreferences?.barZoomOut() }
    @objc private func barZoomReset() { persona.panelPreferences?.resetBarZoom() }
    @objc private func toggleAccountNames() {
        guard let preferences = persona.panelPreferences else { return }
        preferences.showAccountNames.toggle()
    }
    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let appearance = PanelAppearance(rawValue: raw) else { return }
        persona.panelPreferences?.appearance = appearance
    }

    @objc private func selectOrientation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let orientation = PanelOrientation(rawValue: raw),
              let preferences = persona.panelPreferences else { return }
        preferences.orientation = orientation
        suppressHoverExpansionUntilExit = true
        setTabMode(.collapsed)
    }

    @objc private func refreshUsage() {
        persona.refresh()
    }

    @objc private func checkForUpdates() {
        updateController?.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func moveTab(to proposedOrigin: NSPoint) {
        guard let tabPanel else { return }
        refreshTabScreenGeometry()
        let constrainedFrame = NSRect(origin: constrainedOrigin(proposedOrigin, size: tabPanel.frame.size),
                                      size: tabPanel.frame.size)
        let origin = menuBarCenteredOrigin(for: constrainedFrame) ?? constrainedFrame.origin
        tabPanel.setFrameOrigin(origin)

        if panel?.isVisible == true {
            setPanelFrame(frameNearTab(for: panel?.frame.size ?? panelSize))
            alignPanelToVisibleTab(context: "moveTab")
        }
    }

    func handleTabHoverChanged(_ isHovering: Bool) {
        if isHovering {
            guard !isTabDragging, !suppressHoverExpansionUntilExit else { return }
            // Product decision (2026-10-21): personas with ring hover cards (multi) keep hover for the per-ring card and never enter .expanded by hover — expanded mode would swap the rings away. The old "NN%" expanded label is intentionally unreachable for the multi tab.
            guard persona.ringHoverCard == nil else { return }
            setTabMode(.expanded)
        } else {
            if isTabDragging {
                didExitDuringDrag = true
            }
            suppressHoverExpansionUntilExit = false
            setTabMode(.collapsed)
        }
    }

    private func handleTabDragStarted() {
        isTabDragging = true
        didExitDuringDrag = false
        suppressHoverExpansionUntilExit = true
        persona.ringHoverCard?.hide(immediately: true)
        setTabMode(.dragging)
    }

    private func handleTabDragEnded() {
        isTabDragging = false
        suppressHoverExpansionUntilExit = !didExitDuringDrag
        didExitDuringDrag = false
        setTabMode(.collapsed)
        saveTabPosition()
    }

    func handleBarZoomInteractionBegan() {
        guard persona.panelPreferences != nil, !isTabDragging else { return }
        suppressHoverExpansionUntilExit = true
        setTabMode(.collapsed)
    }

    func handleBarZoomSteps(_ steps: Int) {
        guard let preferences = persona.panelPreferences, !isTabDragging else { return }
        preferences.adjustBarZoom(steps: steps)
    }

    func setTabMode(_ mode: EdgeTabPresentationMode) {
        tabPresentation.mode = mode
        guard let tabPanel else { return }
        let size = tabPresentation.size
        let origin: NSPoint
        if persona.panelPreferences != nil {
            let geometry = screenGeometry(containing: tabPanel.frame)
            origin = TabPositioning.multiResizedOrigin(
                from: tabPanel.frame,
                to: size,
                visibleFrame: geometry.visibleFrame,
                screenFrame: geometry.frame,
                menuBarHeight: tabPresentation.menuBarHeight
            )
        } else {
            origin = resizedTabOrigin(from: tabPanel.frame, to: size)
        }
        let frame = NSRect(origin: origin, size: size)
        if tabPanel.frame != frame {
            Self.applyTabFrame(frame, to: tabPanel)
        }
        if panel?.isVisible == true {
            setPanelFrame(frameNearTab(for: panel?.frame.size ?? panelSize))
            alignPanelToVisibleTab(context: "setTabMode")
        }
        tabPanel.orderFrontRegardless()
    }

    @MainActor
    static func applyTabFrame(_ frame: NSRect, to panel: NSPanel) {
        panel.setFrame(frame, display: true, animate: false)
    }

    private func observeTabScreenGeometry() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTabScreenGeometry()
            }
        }
    }

    private func refreshTabScreenGeometry() {
        guard let tabPanel else { return }
        let screenPairs = NSScreen.screens.map { screen in
            (screen: screen, geometry: MenuBarGeometry.Screen(frame: screen.frame,
                                                              visibleFrame: screen.visibleFrame))
        }
        let geometry: MenuBarGeometry.Screen
        if let panelScreen = tabPanel.screen,
           let pair = screenPairs.first(where: { $0.screen === panelScreen }) {
            geometry = pair.geometry
        } else if let selected = MenuBarGeometry.screen(for: tabPanel.frame,
                                                       screens: screenPairs.map(\.geometry)) {
            geometry = selected
        } else if let main = NSScreen.main,
                  let pair = screenPairs.first(where: { $0.screen === main }) {
            geometry = pair.geometry
        } else {
            return
        }

        let height = MenuBarGeometry.height(
            screenFrame: geometry.frame,
            visibleFrame: geometry.visibleFrame,
            mainMenuHeight: NSApp.mainMenu?.menuBarHeight,
            statusBarThickness: NSStatusBar.system.thickness
        )
        let geometryChanged = lastTabScreenGeometry != geometry
        let heightChanged = tabPresentation.menuBarHeight != height
        lastTabScreenGeometry = geometry
        if heightChanged {
            tabPresentation.menuBarHeight = height
        }
        if geometryChanged || heightChanged {
            setTabMode(tabPresentation.mode)
        }
    }

    private func menuBarCenteredOrigin(for frame: NSRect) -> NSPoint? {
        guard persona.panelPreferences != nil else { return nil }
        let geometry = screenGeometry(containing: frame)
        return TabPositioning.menuBarCenteredOrigin(
            currentFrame: frame,
            to: frame.size,
            visibleFrame: geometry.visibleFrame,
            screenFrame: geometry.frame,
            menuBarHeight: tabPresentation.menuBarHeight
        )
    }

    private func showPanel(context: String) {
        guard let panel else { return }
        attachPanelContentIfNeeded()
        setPanelFrame(frameNearTab(for: panel.frame.size))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        tabPanel?.orderFrontRegardless()
        alignPanelToVisibleTab(context: context)
    }

    private func adjustPanelOpacity(deltaY: CGFloat, context: String) {
        guard let panel else { return }
        if !panel.isVisible {
            persona.refresh()
            showPanel(context: context)
        } else {
            tabPanel?.orderFrontRegardless()
        }

        let nextOpacity = TabPositioning.adjustedOpacity(
            current: panel.alphaValue,
            scrollDeltaY: deltaY
        )
        setPanelOpacity(nextOpacity, showsHUD: true)
    }

    private func resetPanelPositionOpacityAndShow() {
        panelOffsetStore.reset()
        setPanelOpacity(1, showsHUD: true)
        persona.refresh()
        showPanel(context: "tab-double-click")
    }

    private func resetPanelSizeAndShow() {
        guard let panel else { return }
        setPanelOpacity(1, showsHUD: true)
        if let preferences = persona.panelPreferences {
            preferences.resetZoom()
            showPanel(context: "panel-reset-zoom")
            return
        }
        persona.refresh()
        let frame = NSRect(
            origin: resetPanelOrigin(for: panelSize, currentFrame: panel.frame),
            size: panelSize
        )
        attachPanelContentIfNeeded()
        setPanelFrame(frame)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        tabPanel?.orderFrontRegardless()
        alignPanelToVisibleTab(context: "panel-double-click")
    }

    private func setPanelOpacity(_ opacity: CGFloat, showsHUD: Bool) {
        panel?.alphaValue = opacityPreferences.setOpacity(opacity, for: .panel)
        if showsHUD {
            persona.showOpacityHUD(percent: TabPositioning.opacityPercent(for: opacity))
        }
    }

    private func setTabOpacity(_ opacity: CGFloat, showsHUD: Bool) {
        let value = opacityPreferences.setOpacity(opacity, for: .tab)
        tabPanel?.alphaValue = value
        if showsHUD {
            persona.showOpacityHUD(percent: TabPositioning.opacityPercent(for: value))
        }
    }

    private func saveTabPosition() {
        guard let tabPanel else { return }
        let origin = tabPanel.frame.origin
        UserDefaults.standard.set(origin.x, forKey: tabOriginXKey)
        UserDefaults.standard.set(origin.y, forKey: tabOriginYKey)
    }

    private func frameNearTab(for size: NSSize) -> NSRect {
        let tabFrame = tabPanel?.frame ?? frameForTab()
        return frame(for: size, anchoredTo: tabFrame)
    }

    private func frame(for size: NSSize, anchoredTo anchor: NSRect) -> NSRect {
        let visibleFrame = visibleFrame(containing: anchor)
        let screenFrame = screenFrame(containing: anchor)
        return NSRect(
            origin: TabPositioning.panelOrigin(
                size: size,
                anchor: anchor,
                savedOffset: savedPanelOffset(),
                visibleFrame: visibleFrame,
                screenFrame: screenFrame,
                orientation: persona.panelPreferences?.orientation ?? .horizontal
            ),
            size: size
        )
    }

    private func frameForTab() -> NSRect {
        let tabSize = tabPresentation.collapsedSize
        if let savedOrigin = savedTabOrigin() {
            return NSRect(
                origin: constrainedOrigin(savedOrigin, size: tabSize),
                size: tabSize
            )
        }

        let screenFrame = widestVisibleFrame()
        let origin = NSPoint(
            x: max(screenFrame.minX + 8, screenFrame.maxX - tabSize.width - 8),
            y: max(screenFrame.minY + 8, screenFrame.midY - tabSize.height / 2)
        )
        return NSRect(origin: origin, size: tabSize)
    }

    private func savedTabOrigin() -> NSPoint? {
        guard UserDefaults.standard.object(forKey: tabOriginXKey) != nil,
              UserDefaults.standard.object(forKey: tabOriginYKey) != nil
        else {
            return nil
        }
        return NSPoint(
            x: UserDefaults.standard.double(forKey: tabOriginXKey),
            y: UserDefaults.standard.double(forKey: tabOriginYKey)
        )
    }

    private func constrainedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let rect = NSRect(origin: origin, size: size)
        return TabPositioning.constrainedOrigin(
            origin,
            size: size,
            visibleFrame: visibleFrame(containing: rect),
            screenFrame: screenFrame(containing: rect)
        )
    }

    private func setPanelFrame(_ frame: NSRect) {
        guard let panel else { return }
        isPositioningPanel = true
        panel.setFrame(frame, display: true)
        isPositioningPanel = false
        saveCorrectedPanelOffsetIfNeeded(for: panel.frame)
    }

    private func handlePanelDidMove(_ notification: Notification) {
        guard let movedWindow = notification.object as? NSWindow,
              movedWindow === panel,
              let panel,
              !isPositioningPanel,
              panel.isVisible
        else {
            return
        }

        constrainPanelFrameIfNeeded(panel)
        guard PanelOffsetPersistence.shouldSaveMoveOffset(isLiveResizing: isPanelLiveResizing) else { return }
        savePanelOffset(for: panel.frame)
    }

    func windowDidMove(_ notification: Notification) {
        handlePanelDidMove(notification)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow,
              changedWindow === tabPanel
        else { return }
        refreshTabScreenGeometry()
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === panel,
              let panel,
              !isPanelLiveResizing,
              panel.isVisible
        else {
            return
        }
        guard PanelOffsetPersistence.shouldSaveResizeOffset(
            hadSavedOffsetAtResizeStart: hasSavedPanelOffset
        ) else { return }
        savePanelOffset(for: panel.frame)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === panel
        else {
            return
        }
        hadSavedPanelOffsetAtResizeStart = hasSavedPanelOffset
        isPanelLiveResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === panel,
              let panel
        else {
            return
        }
        let shouldSaveOffset = PanelOffsetPersistence.shouldSaveResizeOffset(
            hadSavedOffsetAtResizeStart: hadSavedPanelOffsetAtResizeStart
        )
        constrainPanelFrameIfNeeded(panel)
        DispatchQueue.main.async { [weak self] in
            self?.isPanelLiveResizing = false
            self?.hadSavedPanelOffsetAtResizeStart = false
        }
        guard shouldSaveOffset else { return }
        savePanelOffset(for: panel.frame)
    }

    private func constrainPanelFrameIfNeeded(_ panel: NSWindow) {
        let correctedFrame = constrainedPanelFrame(panel.frame)
        guard correctedFrame.origin != panel.frame.origin else { return }
        isPositioningPanel = true
        panel.setFrame(correctedFrame, display: true)
        isPositioningPanel = false
    }

    private func constrainedPanelFrame(_ frame: NSRect) -> NSRect {
        let anchor = tabPanel?.frame ?? frameForTab()
        return NSRect(
            origin: TabPositioning.constrainedPanelOrigin(
                frame.origin,
                size: frame.size,
                visibleFrame: visibleFrame(containing: anchor),
                screenFrame: screenFrame(containing: anchor)
            ),
            size: frame.size
        )
    }

    private func resetPanelOrigin(for size: NSSize, currentFrame: NSRect) -> NSPoint {
        let anchor = tabPanel?.frame ?? frameForTab()
        let referenceFrame = hasSavedPanelOffset ? currentFrame : anchor
        return TabPositioning.panelResetOrigin(
            size: size,
            currentFrame: currentFrame,
            anchor: anchor,
            hasSavedOffset: hasSavedPanelOffset,
            visibleFrame: visibleFrame(containing: referenceFrame),
            screenFrame: screenFrame(containing: referenceFrame),
            orientation: persona.panelPreferences?.orientation ?? .horizontal
        )
    }

    private var hasSavedPanelOffset: Bool {
        panelOffsetStore.hasSavedOffset
    }

    private func savedPanelOffset() -> NSSize? {
        panelOffsetStore.load()
    }

    private func saveCorrectedPanelOffsetIfNeeded(for panelFrame: NSRect) {
        guard hasSavedPanelOffset else { return }
        savePanelOffset(for: panelFrame)
    }

    private func savePanelOffset(for panelFrame: NSRect) {
        let anchor = tabPanel?.frame ?? frameForTab()
        let offset = TabPositioning.panelOffset(panelOrigin: panelFrame.origin, anchor: anchor)
        panelOffsetStore.save(offset)
    }

    private func resizedTabOrigin(from frame: NSRect, to size: NSSize) -> NSPoint {
        TabPositioning.resizedOrigin(
            from: frame,
            to: size,
            visibleFrame: visibleFrame(containing: frame),
            screenFrame: screenFrame(containing: frame)
        )
    }

    private func screenFrame(containing rect: NSRect) -> NSRect {
        screenGeometry(containing: rect).frame
    }

    private func visibleFrame(containing rect: NSRect) -> NSRect {
        screenGeometry(containing: rect).visibleFrame
    }

    private func screenGeometry(containing rect: NSRect) -> MenuBarGeometry.Screen {
        let screens = NSScreen.screens.map { screen in
            MenuBarGeometry.Screen(frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        return MenuBarGeometry.screen(for: rect, screens: screens)
            ?? MenuBarGeometry.Screen(frame: widestScreenFrame(), visibleFrame: widestVisibleFrame())
    }

    private func widestVisibleFrame() -> NSRect {
        let screenFrame = NSScreen.screens
            .map(\.visibleFrame)
            .max { $0.width < $1.width } ?? .zero
        return screenFrame
    }

    private func widestScreenFrame() -> NSRect {
        let screenFrame = NSScreen.screens
            .map(\.frame)
            .max { $0.width < $1.width } ?? .zero
        return screenFrame
    }

    private func alignPanelToVisibleTab(context: String) {
        DispatchQueue.main.async { [weak self] in
            self?.alignPanelToVisibleTabNow(context: context)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.alignPanelToVisibleTabNow(context: "\(context):followup")
        }
    }

    private func alignPanelToVisibleTabNow(context: String) {
        guard let panel, let tabPanel, panel.isVisible else { return }
        guard !hasSavedPanelOffset else { return }
        guard persona.panelPreferences?.orientation != .vertical else { return }
        let visibleFrame = visibleFrame(containing: tabPanel.frame)
        guard tabPanel.frame.maxY > visibleFrame.maxY else { return }
        guard let tabBounds = RuntimeWindowFrames.bounds(for: tabPanel.windowNumber),
              let panelBounds = RuntimeWindowFrames.bounds(for: panel.windowNumber)
        else {
            FrameDiagnostics.log(context: context, tabFrame: tabPanel.frame, panelFrame: panel.frame)
            return
        }

        let actualGap = panelBounds.minY - tabBounds.maxY
        let delta = actualGap - TabPositioning.panelTopGap
        FrameDiagnostics.log(
            context: context,
            tabFrame: tabPanel.frame,
            panelFrame: panel.frame,
            tabBounds: tabBounds,
            panelBounds: panelBounds,
            delta: delta
        )
        guard abs(delta) > 1 else { return }
        isPositioningPanel = true
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + delta))
        isPositioningPanel = false
    }
}

enum RuntimeWindowFrames {
    static func bounds(for windowNumber: Int) -> NSRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowNumber as String] as? Int == windowNumber,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

enum PanelOffsetPersistence {
    static func shouldSaveMoveOffset(isLiveResizing: Bool) -> Bool {
        !isLiveResizing
    }

    static func shouldSaveResizeOffset(hadSavedOffsetAtResizeStart: Bool) -> Bool {
        hadSavedOffsetAtResizeStart
    }
}

enum FrameDiagnostics {
    static func log(
        context: String,
        tabFrame: NSRect,
        panelFrame: NSRect,
        tabBounds: NSRect? = nil,
        panelBounds: NSRect? = nil,
        delta: CGFloat? = nil
    ) {
        let message = [
            "context=\(context)",
            "tabFrame=\(NSStringFromRect(tabFrame))",
            "panelFrame=\(NSStringFromRect(panelFrame))",
            "tabBounds=\(tabBounds.map(NSStringFromRect) ?? "nil")",
            "panelBounds=\(panelBounds.map(NSStringFromRect) ?? "nil")",
            "delta=\(delta.map { String(format: "%.2f", Double($0)) } ?? "nil")"
        ].joined(separator: " ")
        NSLog("CodexUsageWidgetFrame %@", message)
        appendToFile(message)
    }

    private static func appendToFile(_ message: String) {
        let url = URL(fileURLWithPath: "/private/tmp/codex-usage-widget-frames.log")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

enum TabPositioning {
    static let windowLevel = NSWindow.Level.statusBar
    static let edgePadding: CGFloat = 8
    static let panelTopGap: CGFloat = 4
    static let panelDesignSize = NSSize(width: 360, height: 190)
    static let defaultPanelDisplayScale: CGFloat = 0.75
    static var defaultPanelSize: NSSize {
        NSSize(
            width: panelDesignSize.width * defaultPanelDisplayScale,
            height: panelDesignSize.height * defaultPanelDisplayScale
        )
    }

    static func constrainedOrigin(
        _ origin: NSPoint,
        size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect
    ) -> NSPoint {
        NSPoint(
            x: min(max(visibleFrame.minX + edgePadding, origin.x), visibleFrame.maxX - size.width - edgePadding),
            y: min(max(visibleFrame.minY + edgePadding, origin.y), screenFrame.maxY - size.height)
        )
    }

    static func panelOrigin(
        size: NSSize,
        anchor: NSRect,
        savedOffset: NSSize? = nil,
        visibleFrame: NSRect,
        screenFrame: NSRect,
        orientation: PanelOrientation = .horizontal
    ) -> NSPoint {
        let offset: NSSize
        if let savedOffset {
            offset = savedOffset
        } else if orientation == .vertical {
            let rightSpace = visibleFrame.maxX - edgePadding - anchor.maxX - panelTopGap
            let leftSpace = anchor.minX - visibleFrame.minX - edgePadding - panelTopGap
            let opensRight = rightSpace >= size.width || rightSpace >= leftSpace
            offset = NSSize(width: opensRight ? anchor.width + panelTopGap : -size.width - panelTopGap,
                            height: anchor.height - size.height)
        } else {
            offset = defaultPanelOffset(size: size, anchor: anchor)
        }
        let proposedOrigin = NSPoint(
            x: anchor.minX + offset.width,
            y: anchor.minY + offset.height
        )
        return constrainedPanelOrigin(
            proposedOrigin,
            size: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
    }

    static func panelOffset(panelOrigin: NSPoint, anchor: NSRect) -> NSSize {
        NSSize(
            width: panelOrigin.x - anchor.minX,
            height: panelOrigin.y - anchor.minY
        )
    }

    static func constrainedPanelOrigin(
        _ origin: NSPoint,
        size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect
    ) -> NSPoint {
        NSPoint(
            x: min(max(visibleFrame.minX + edgePadding, origin.x), visibleFrame.maxX - size.width - edgePadding),
            y: min(max(screenFrame.minY + edgePadding, origin.y), screenFrame.maxY - size.height - edgePadding)
        )
    }

    static func panelResetOrigin(
        size: NSSize,
        currentFrame: NSRect,
        anchor: NSRect,
        hasSavedOffset: Bool,
        visibleFrame: NSRect,
        screenFrame: NSRect,
        orientation: PanelOrientation = .horizontal
    ) -> NSPoint {
        guard hasSavedOffset else {
            return panelOrigin(
                size: size,
                anchor: anchor,
                visibleFrame: visibleFrame,
                screenFrame: screenFrame,
                orientation: orientation
            )
        }

        let proposedOrigin = NSPoint(
            x: currentFrame.midX - size.width / 2,
            y: currentFrame.midY - size.height / 2
        )
        return constrainedPanelOrigin(
            proposedOrigin,
            size: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
    }

    private static func defaultPanelOffset(size: NSSize, anchor: NSRect) -> NSSize {
        NSSize(
            width: anchor.width / 2 - size.width / 2,
            height: -panelTopGap - size.height
        )
    }

    static func resizedOrigin(
        from currentFrame: NSRect,
        to size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect
    ) -> NSPoint {
        let keepsRightEdge = currentFrame.midX >= visibleFrame.midX
        let proposedX = keepsRightEdge ? currentFrame.maxX - size.width : currentFrame.minX
        let proposedY = resizedY(from: currentFrame, toHeight: size.height, visibleFrame: visibleFrame, screenFrame: screenFrame)
        return constrainedOrigin(
            NSPoint(x: proposedX, y: proposedY),
            size: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
    }

    static func multiResizedOrigin(
        from currentFrame: NSRect,
        to size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect,
        menuBarHeight: CGFloat
    ) -> NSPoint {
        if let centered = menuBarCenteredOrigin(
            currentFrame: currentFrame,
            to: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame,
            menuBarHeight: menuBarHeight
        ) {
            return centered
        }
        return resizedOrigin(from: currentFrame, to: size,
                             visibleFrame: visibleFrame, screenFrame: screenFrame)
    }

    static func menuBarCenteredOrigin(
        currentFrame: NSRect,
        to size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect,
        menuBarHeight: CGFloat
    ) -> NSPoint? {
        guard menuBarHeight.isFinite, menuBarHeight > 0 else { return nil }
        let tolerance: CGFloat = 0.5
        let overlapsMenuBar = currentFrame.maxY > visibleFrame.maxY
        let touchesScreenTop = currentFrame.maxY >= screenFrame.maxY - tolerance
        guard overlapsMenuBar || touchesScreenTop else { return nil }

        let menuBarBottom = screenFrame.maxY - menuBarHeight
        // A tab taller than the menu bar (barZoom > 1) anchors to the screen top
        // and hangs down over the desktop; its maxY stays at screenFrame.maxY so
        // later zoom changes keep taking this menu-bar path.
        let proposed = NSPoint(
            x: currentFrame.midX >= visibleFrame.midX
                ? currentFrame.maxX - size.width
                : currentFrame.minX,
            y: size.height > menuBarHeight
                ? screenFrame.maxY - size.height
                : menuBarBottom + (menuBarHeight - size.height) / 2
        )
        return constrainedOrigin(proposed, size: size,
                                 visibleFrame: visibleFrame, screenFrame: screenFrame)
    }

    static func adjustedOpacity(current: CGFloat, scrollDeltaY: CGFloat) -> CGFloat {
        guard scrollDeltaY.isFinite else { return SurfaceOpacityPreferences.clamped(current) }
        return SurfaceOpacityPreferences.clamped(current + scrollDeltaY / 500)
    }

    static func opacityPercent(for opacity: CGFloat) -> Int {
        Int((min(max(opacity, 0), 1) * 100).rounded())
    }

    private static func resizedY(
        from currentFrame: NSRect,
        toHeight height: CGFloat,
        visibleFrame: NSRect,
        screenFrame: NSRect
    ) -> CGFloat {
        let tolerance: CGFloat = 0.5
        let bottomLimit = visibleFrame.minY + 8
        if currentFrame.maxY >= screenFrame.maxY - tolerance {
            return currentFrame.maxY - height
        }
        if currentFrame.minY <= bottomLimit + tolerance {
            return currentFrame.minY
        }
        return currentFrame.midY - height / 2
    }
}
