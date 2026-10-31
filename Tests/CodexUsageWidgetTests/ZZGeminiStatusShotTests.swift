import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class ZZGeminiStatusShotTests: XCTestCase {
    @MainActor
    func testGeminiStatusShots() throws {
        guard let out = ProcessInfo.processInfo.environment["UR_SHOTS"] else { return }
        let name = "GShots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = PanelPreferences(defaults: defaults); prefs.appearance = .dark
        for (file, value) in [("gemini-missing.png", "ウィンドウなし"), ("gemini-ok.png", "正常")] {
            var l = UsageLimit(title: "Gemini · 5h", leftPercent: 70, resetText: "Resets 23:50")
            l.resetAt = Date().addingTimeInterval(3000)
            let sec = ProviderSection(provider: .gemini, windows: value == "正常" ? [l] : [], stats: [ProviderStat(title: "Gemini読み取り", valueText: value)], failureText: value == "正常" ? nil : "?")
            let snap = MultiUsageSnapshot(sections: [sec], codexSnapshot: nil, updatedAt: Date())
            let host = NSHostingView(rootView: MultiPanelContent(snapshot: snap, preferences: prefs).background(Color(white: 0.1)).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua); win.contentView = host
            host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            let bm = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bm)
            try XCTUnwrap(bm.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out).appendingPathComponent(file))
            withExtendedLifetime(win) {}
        }
    }
}
