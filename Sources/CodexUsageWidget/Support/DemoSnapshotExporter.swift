import AppKit
import SwiftUI

/// Renders the production SwiftUI views offscreen. This path never runs the
/// app event loop or orders a window, which keeps capture safe on a shared Mac.
@MainActor
enum DemoSnapshotExporter {
    static let scale: CGFloat = 3

    static func export(to directory: URL, mode: DemoMode,
                       now: Date = Date()) throws -> [URL] {
        guard mode.isEnabled else { throw DemoLaunchError.exportRequiresDemoMode }

        let snapshot = UsageRingsDemoFixture.snapshot(now: now)
        let exportSuite = "\(DemoMode.preferenceSuiteName).render.\(UUID().uuidString)"
        guard let exportDefaults = UserDefaults(suiteName: exportSuite) else {
            throw DemoLaunchError.preferencesUnavailable
        }
        defer {
            exportDefaults.removePersistentDomain(forName: exportSuite)
        }
        let preferences = PanelPreferences(defaults: exportDefaults)
        preferences.setZoom(1)
        preferences.setBarZoom(2.5)
        preferences.appearance = .light

        let panelBackground = RoundedRectangle(cornerRadius: PanelBackground.cornerRadius,
                                               style: .continuous)
        let panelLight = MultiPanelContent(snapshot: snapshot, preferences: preferences)
            .background(Color.white)
            .clipShape(panelBackground)
            .environment(\.colorScheme, .light)
        let lightData = try renderHostedPNG(panelLight, appearance: .light)

        preferences.appearance = .dark
        let panelDark = MultiPanelContent(snapshot: snapshot, preferences: preferences)
            .background(Color(white: 0.10))
            .clipShape(panelBackground)
            .environment(\.colorScheme, .dark)
        let darkData = try renderHostedPNG(panelDark, appearance: .dark)

        let ringSize = MultiCollapsedUsageView.size(for: snapshot, barZoom: 2.5,
                                                    menuBarHeight: 45, orientation: .horizontal)
        let horizontalRings = MultiCollapsedUsageView(snapshot: snapshot, barZoom: 2.5,
                                                      menuBarHeight: 45, orientation: .horizontal)
            .padding(16)
        let horizontalData = try renderImagePNG(horizontalRings, size: CGSize(width: ringSize.width + 32,
                                                                              height: ringSize.height + 32),
                                                appearance: .dark)
        let verticalSize = MultiCollapsedUsageView.size(for: snapshot, barZoom: 2.5,
                                                        menuBarHeight: 45, orientation: .vertical)
        let verticalRings = MultiCollapsedUsageView(snapshot: snapshot, barZoom: 2.5,
                                                    menuBarHeight: 45, orientation: .vertical)
            .padding(16)
        let verticalData = try renderImagePNG(verticalRings, size: CGSize(width: verticalSize.width + 32,
                                                                          height: verticalSize.height + 32),
                                              appearance: .dark)

        let warningCriticalData = try renderImagePNG(
            MultiCollapsedUsageView(snapshot: snapshot, barZoom: 2.5, menuBarHeight: 45,
                                    orientation: .horizontal)
                .padding(16),
            size: CGSize(width: ringSize.width + 32, height: ringSize.height + 32),
            appearance: .dark
        )

        var failureSections = snapshot.sections
        if let grokIndex = failureSections.firstIndex(where: { $0.provider == .grok }) {
            failureSections[grokIndex].windows = []
            failureSections[grokIndex].stats = [
                ProviderStat(title: "Weekly", valueText: "No data"),
                ProviderStat(title: "Monthly", valueText: "No monthly cap")
            ]
            failureSections[grokIndex].failureText = "Demo-only provider failure fixture"
        }
        let failureSnapshot = MultiUsageSnapshot(sections: failureSections,
                                                 codexSnapshot: snapshot.codexSnapshot,
                                                 updatedAt: snapshot.updatedAt)
        let failurePanel = MultiPanelContent(snapshot: failureSnapshot, preferences: preferences)
            .background(Color(white: 0.10))
            .clipShape(panelBackground)
            .environment(\.colorScheme, .dark)
        let failureData = try renderHostedPNG(failurePanel, appearance: .dark)
        let hudStore = MultiUsageStore(demoSnapshot: snapshot)
        hudStore.showOpacityHUD(percent: 65)
        let opacityHUD = MultiWidgetView(store: hudStore, preferences: preferences)
            .background(Color(white: 0.10))
            .clipShape(panelBackground)
            .environment(\.colorScheme, .dark)
        let opacityHUDData = try renderHostedPNG(opacityHUD, appearance: .dark)

        let bars = CollapsedUsageBar.bars(for: snapshot, blockedPreview: nil)
        let cardFiles: [(String, String)] = [
            ("hover-codex.png", "codex"),
            ("hover-claude-0.png", "claude-0"),
            ("hover-claude-1.png", "claude-1"),
            ("hover-grok.png", "grok"),
            ("hover-zai.png", "zai"),
            ("hover-antigravity-argon.png", "antigravity-Gemini 4 Argon"),
            ("hover-antigravity-gemini-models.png", "antigravity-Gemini Models"),
            ("hover-antigravity-claude-gpt.png", "antigravity-Claude and GPT models")
        ]
        var outputs: [(String, Data)] = [
            ("rings-horizontal.png", horizontalData),
            ("rings-vertical.png", verticalData),
            ("rings-warning-critical.png", warningCriticalData),
            ("panel-light.png", lightData),
            ("panel-dark.png", darkData),
            ("panel-failure-no-data.png", failureData),
            ("opacity-hud.png", opacityHUDData)
        ]
        for (filename, barID) in cardFiles {
            guard let bar = bars.first(where: { $0.id == barID }),
                  let model = RingDetailCardModel.make(bar: UsageRingsDemoFixture.detailCardBar(for: bar), now: now,
                                                       sourceTimeZone: RingResetFormat.tokyo)
            else { throw DemoLaunchError.unableToRender(filename) }
            let card = RingDetailCardView(model: model)
                .padding(14)
                .background(Color(white: 0.12))
                .environment(\.colorScheme, .dark)
            outputs.append((filename, try renderImagePNG(card, appearance: .dark)))
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (filename, _) in outputs {
            let url = directory.appendingPathComponent(filename)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw DemoLaunchError.outputAlreadyExists(url)
            }
        }
        let urls = try outputs.map { filename, data -> URL in
            let url = directory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        }
        return urls
    }

    /// Pure SwiftUI surfaces render through ImageRenderer so text and arcs are
    /// drawn at the requested pixel scale instead of a 1x host backing store.
    private static func renderImagePNG<Content: View>(_ content: Content,
                                                       size requestedSize: CGSize? = nil,
                                                       appearance: PanelAppearance) throws -> Data {
        let scheme: ColorScheme = appearance == .dark ? .dark : .light
        let backdrop = appearance == .dark ? Color(white: 0.10) : Color.white
        let root = AnyView(content.environment(\.colorScheme, scheme).background(backdrop))
        let size = requestedSize ?? NSHostingView(rootView: root).fittingSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw DemoLaunchError.unableToRender("view with invalid size")
        }
        let renderer = ImageRenderer(content: root.frame(width: size.width, height: size.height,
                                                         alignment: .topLeading))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else {
            throw DemoLaunchError.unableToRender("SwiftUI image renderer")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard image.width == Int(ceil(size.width * scale)),
              image.height == Int(ceil(size.height * scale)),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DemoLaunchError.unableToRender("SwiftUI PNG encoding")
        }
        return data
    }

    /// Native toolbar buttons need AppKit hosting. Scale the SwiftUI tree before
    /// caching so AppKit's 1x backing store rasterizes text at final pixel size.
    /// The attached window remains unordered.
    private static func renderHostedPNG<Content: View>(_ content: Content,
                                                        size requestedSize: CGSize? = nil,
                                                        appearance: PanelAppearance) throws -> Data {
        let scheme: ColorScheme = appearance == .dark ? .dark : .light
        let root = AnyView(content.environment(\.colorScheme, scheme))
        let measurementHost = NSHostingView(rootView: root)
        let size = requestedSize ?? measurementHost.fittingSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw DemoLaunchError.unableToRender("view with invalid size")
        }
        let pixelSize = CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        let scaledRoot = root
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: pixelSize.width, height: pixelSize.height, alignment: .topLeading)
        let host = NSHostingView(rootView: scaledRoot)
        host.appearance = appearance.nsAppearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: pixelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: pixelSize)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(pixelSize.width),
                                            pixelsHigh: Int(pixelSize.height),
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw DemoLaunchError.unableToRender("bitmap allocation")
        }
        bitmap.size = pixelSize
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard !window.isVisible else {
            throw DemoLaunchError.unableToRender("offscreen host unexpectedly became visible")
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DemoLaunchError.unableToRender("PNG encoding")
        }
        withExtendedLifetime(window) { }
        return data
    }
}
