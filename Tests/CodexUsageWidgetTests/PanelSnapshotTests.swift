import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class PanelSnapshotTests: XCTestCase {
    @MainActor
    func testPanelSnapshot() throws {
        let name = "PanelSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("artifacts/usage-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var baseHeight = 0
        for (zoom, appearance) in [(1.0, PanelAppearance.light), (1.5, .dark), (2.0, .dark)] {
            preferences.setZoom(zoom)
            preferences.appearance = appearance
            let diagT0 = Date()
            // Native toolbar buttons need an AppKit host; ImageRenderer
            // substitutes unsupported-view symbols. Keep the window offscreen/unordered.
            let host = NSHostingView(rootView: MultiPanelContent(snapshot: fixture, preferences: preferences)
                // Test content contrast against a deterministic backdrop; native
                // glass is composited by WindowServer and absent from cacheDisplay.
                .background(appearance == .dark ? Color(white: 0.10) : .white)
                .environment(\.colorScheme, appearance.colorScheme ?? .light))
            let size = host.fittingSize
            let diagT1 = Date()
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance.nsAppearance
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let diagT2 = Date()
            XCTAssertEqual(image.width, Int(MultiPanelContent.baseWidth * zoom * 2))
            if zoom == 1 { baseHeight = image.height }
            XCTAssertEqual(Double(image.height), Double(baseHeight) * zoom, accuracy: 2)
            let background = try XCTUnwrap(bitmap.colorAt(x: image.width / 2, y: image.height - 4))
            let expected: CGFloat = appearance == .dark ? 0.10 : 1
            XCTAssertEqual(background.redComponent, expected, accuracy: 0.06)
            XCTAssertEqual(background.greenComponent, expected, accuracy: 0.06)
            XCTAssertEqual(background.blueComponent, expected, accuracy: 0.06)
            // Both low-quota colors must survive real rendering on either background.
            var environment = EnvironmentValues()
            environment.colorScheme = appearance == .dark ? .dark : .light
            let resolvedColors = [CollapsedUsageBar.warningColor, CollapsedUsageBar.criticalColor]
                .map { $0.resolve(in: environment) }
            var counts = Array(repeating: 0, count: resolvedColors.count)
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                    for (index, resolved) in resolvedColors.enumerated() {
                        if abs(pixel.redComponent - CGFloat(resolved.red)) < 0.04,
                           abs(pixel.greenComponent - CGFloat(resolved.green)) < 0.04,
                           abs(pixel.blueComponent - CGFloat(resolved.blue)) < 0.04 { counts[index] += 1 }
                    }
                }
            }
            let diagT3 = Date()
            var countsC = Array(repeating: 0, count: resolvedColors.count)
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                    _ = pixel
                }
            }
            let diagT4 = Date()
            let data = try XCTUnwrap(bitmap.bitmapData)
            let bpr = bitmap.bytesPerRow
            let spp = bitmap.samplesPerPixel
            var countsD = Array(repeating: 0, count: resolvedColors.count)
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    let o = y * bpr + x * spp
                    let r = CGFloat(data[o]) / 255, g = CGFloat(data[o + 1]) / 255, b = CGFloat(data[o + 2]) / 255
                    for (index, resolved) in resolvedColors.enumerated() {
                        if abs(r - CGFloat(resolved.red)) < 0.04, abs(g - CGFloat(resolved.green)) < 0.04,
                           abs(b - CGFloat(resolved.blue)) < 0.04 { countsD[index] += 1 }
                    }
                }
            }
            let diagT5 = Date()
            countsC = countsD
            print("PANEL_DIAG zoom=\(zoom) px=\(image.width)x\(image.height) format=\(bitmap.bitmapFormat.rawValue) spp=\(spp) render=\(diagT1.timeIntervalSince(diagT0)) draw=\(diagT2.timeIntervalSince(diagT1)) scanColorAtCompare=\(diagT3.timeIntervalSince(diagT2)) colorAtOnly=\(diagT4.timeIntervalSince(diagT3)) rawCompare=\(diagT5.timeIntervalSince(diagT4)) counts=\(counts) raw=\(countsC)")
            for count in counts {
                XCTAssertGreaterThan(count, Int(50 * zoom * zoom)) // G1 gauges are thinner than the old 104pt rings
            }
            if ProcessInfo.processInfo.environment["CODEX_USAGE_WIDGET_WRITE_LEGACY_SNAPSHOTS"] == "1" {
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("panel-\(preferences.percent)-\(appearance.rawValue).png"),
                              options: .atomic)
            }
        }
    }

    @MainActor
    func testLongFailureAndInformationalStatsRenderWithoutCropping() throws {
        let name = "PanelSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let failure = "Provider CLI request failed · account boundary stayed explicit · this safe notice must remain complete"
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .grok, windows: [], stats: [
                ProviderStat(title: "Account · Monthly", valueText: "No monthly cap"),
                ProviderStat(title: "Account · Weekly", valueText: "No data")
            ], failureText: failure)
        ], codexSnapshot: nil, updatedAt: Date(timeIntervalSince1970: 0))

        let host = NSHostingView(rootView: MultiPanelContent(snapshot: snapshot, preferences: preferences)
            .background(Color(white: 0.10))
            .environment(\.colorScheme, .dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        XCTAssertGreaterThan(size.height, 130) // G1 rows are compact

        var redPixels = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y),
                      pixel.redComponent > 0.65,
                      pixel.greenComponent < 0.45,
                      pixel.blueComponent < 0.45
                else { continue }
                redPixels += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(redPixels, 100)
        XCTAssertGreaterThan(maxX - minX, 300, "Long failure did not occupy wrapped text width")
        XCTAssertGreaterThan(maxY - minY, 20, "Long failure did not wrap to multiple rows")
        let compact = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .grok, windows: [], stats: [], failureText: "Short failure")
        ], codexSnapshot: nil, updatedAt: Date(timeIntervalSince1970: 0))
        let compactSize = NSHostingView(rootView:
            MultiPanelContent(snapshot: compact, preferences: preferences)
                .environment(\.colorScheme, .dark)).fittingSize
        XCTAssertGreaterThan(size.height - compactSize.height, 10)
        XCTAssertFalse(window.isVisible)
        withExtendedLifetime(window) { }
    }

    private var fixture: MultiUsageSnapshot {
        func window(_ title: String, _ percent: Double, account: Int? = nil) -> UsageLimit {
            var limit = UsageLimit(title: title, leftPercent: percent, resetText: "Resets in 2h")
            limit.accountIndex = account
            return limit
        }
        return MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [window("Session", 78)], stats: [], failureText: nil),
            ProviderSection(provider: .claude, windows: [window("Account A · 5h", 25, account: 0),
                window("Account B · Weekly", 10, account: 1)], stats: [], failureText: nil),
            ProviderSection(provider: .antigravity, windows: [window("Gemini 4 Argon · 5h", 86),
                window("Gemini Models · Weekly", 76), window("Claude and GPT models · Weekly", 66)],
                stats: [], failureText: nil),
            ProviderSection(provider: .zai, windows: [window("5h", 88)], stats: [], failureText: nil),
            ProviderSection(provider: .grok, windows: [window("Weekly", 75), window("Monthly", 90)], stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }
}
