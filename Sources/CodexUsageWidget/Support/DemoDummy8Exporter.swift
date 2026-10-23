import AppKit
import SwiftUI

/// Demo-only offscreen renderer for the dummy8 recording: renders the production
/// ring strip and ring detail card at a high pixel scale (no window, no real data).
/// Usage: `--demo-export-dummy8 /abs/spec.json` (demo mode is implied).
@MainActor
enum DemoDummy8Exporter {
    struct Spec: Decodable {
        struct Item: Decodable {
            let name: String
            let count: Int
            let elapsed: Double
            let card: Int?
            let highlight: String?
        }
        let out: String
        let scale: Double
        let menuBarHeight: Double
        let now: Double
        let items: [Item]
    }

    static func specPath(arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "--demo-export-dummy8"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func run(specPath: String) throws -> [String] {
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
        let now = Date(timeIntervalSince1970: spec.now)
        let outDir = URL(fileURLWithPath: spec.out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var written: [String] = []
        for item in spec.items {
            let ids = Set(UsageRingsDemoFixture.dummy8RingOrder.prefix(item.count))
            let full = UsageRingsDemoFixture.dummy8Snapshot(now: now)
            let base = MultiUsageSnapshot(sections: full.sections, codexSnapshot: full.codexSnapshot,
                                          updatedAt: now, visibleRingIDs: ids)
            let snapshot = UsageRingsDemoFixture.shrunkDummy8Snapshot(base: base, elapsed: item.elapsed, now: now)
            let data: Data
            if let cardIndex = item.card {
                let bars = CollapsedUsageBar.bars(for: snapshot)
                guard cardIndex < bars.count,
                      let model = RingDetailCardModel.make(bar: bars[cardIndex], now: now) else {
                    throw DemoLaunchError.unableToRender(item.name)
                }
                let view = RingDetailCardView(model: model).environment(\.colorScheme, .dark)
                let size = NSHostingView(rootView: view).fittingSize
                data = try render(view, size: size, scale: spec.scale)
            } else {
                let size = MultiCollapsedUsageView.size(for: snapshot, barZoom: 2.5,
                                                        menuBarHeight: spec.menuBarHeight, orientation: .horizontal)
                var view = MultiCollapsedUsageView(snapshot: snapshot, barZoom: 2.5,
                                                   menuBarHeight: spec.menuBarHeight, orientation: .horizontal)
                view.highlightedBarID = item.highlight
                data = try renderHosted(view, size: size, scale: spec.scale)
            }
            let url = outDir.appendingPathComponent(item.name)
            try data.write(to: url, options: .atomic)
            written.append(url.path)
        }
        return written
    }

    /// AppKit-hosted path (dark appearance) so semantic/vibrant colors resolve like the live tab.
    private static func renderHosted<Content: View>(_ content: Content, size: CGSize, scale: Double) throws -> Data {
        let pixel = CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
        let root = content
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: pixel.width, height: pixel.height, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        let dark = NSAppearance(named: .darkAqua)
        host.appearance = dark
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: pixel), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = dark
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: pixel)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixel.width),
                                            pixelsHigh: Int(pixel.height), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else {
            throw DemoLaunchError.unableToRender("dummy8 bitmap")
        }
        bitmap.size = pixel
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard !window.isVisible, let data = bitmap.representation(using: .png, properties: [:]) else {
            throw DemoLaunchError.unableToRender("dummy8 hosted PNG")
        }
        withExtendedLifetime(window) { }
        return data
    }

    private static func render<Content: View>(_ content: Content, size: CGSize, scale: Double) throws -> Data {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DemoLaunchError.unableToRender("dummy8 frame")
        }
        return data
    }
}
