import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class ZZShotsTmpTests: XCTestCase {
    @MainActor
    func testShots() throws {
        guard let out = ProcessInfo.processInfo.environment["UR_SHOTS"] else { return }
        let dir = URL(fileURLWithPath: out)
        let name = "Shots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = PanelPreferences(defaults: defaults)
        prefs.appearance = .dark
        let now = Date()
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        func w(_ t: String, _ p: Double, _ h: Double, _ a: Int? = nil) -> UsageLimit {
            var l = UsageLimit(title: t, leftPercent: p, resetText: "Resets \(f.string(from: now.addingTimeInterval(h*3600)))")
            l.accountIndex = a; return l
        }
        let snap = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [w("5h", 78, 3), w("Weekly", 49, 60)], stats: [], failureText: nil),
            ProviderSection(provider: .claude, windows: [w("Account A · 5h", 62, 2, 0), w("Account A · Weekly", 40, 90, 0),
                w("Account B · 5h", 30, 4, 1), w("Account B · Weekly", 18, 30, 1)], stats: [], failureText: nil),
            ProviderSection(provider: .antigravity, windows: [w("Gemini 4 Argon · 5h", 0, 2), w("Gemini Models · Weekly", 76, 50)], stats: [], failureText: nil),
            ProviderSection(provider: .zai, windows: [w("5h", 88, 1), w("Weekly", 70, 100), w("MCP monthly", 95, 400)], stats: [], failureText: nil),
        ], codexSnapshot: nil, updatedAt: now)
        func save(_ v: some View, _ file: String) throws {
            let host = NSHostingView(rootView: v.background(Color(white: 0.10)).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua); win.contentView = host
            host.frame = CGRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            let bm = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bm)
            try XCTUnwrap(bm.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent(file))
            withExtendedLifetime(win) {}
        }
        let bars = CollapsedUsageBar.bars(for: snap)
        print("SHOTBARS", bars.map(\.title))
        for style in UsageStyle.allCases { for basis in UsageBasis.allCases {
            UserDefaults.standard.set(style.rawValue, forKey: UsageStyle.key)
            UserDefaults.standard.set(basis.rawValue, forKey: UsageBasis.key)
            try save(MultiPanelContent(snapshot: snap, preferences: prefs), "panel-\(style.rawValue)-\(basis.rawValue).png")
            for bar in bars {
                guard let m = RingDetailCardModel.make(bar: bar, now: now) else { continue }
                let slug = bar.title.replacingOccurrences(of: " ", with: "_")
                try save(RingDetailCardView(model: m).padding(12), "hover-\(slug)-\(style.rawValue)-\(basis.rawValue).png")
            }
        }}
        // v3: real window background (AdaptiveGlass .panel) over a busy backdrop, every style/basis.
        let back = LinearGradient(colors: [Color(red: 0.95, green: 0.9, blue: 0.75), Color(red: 0.4, green: 0.7, blue: 0.95), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        for style in UsageStyle.allCases { for basis in UsageBasis.allCases {
            UserDefaults.standard.set(style.rawValue, forKey: UsageStyle.key)
            UserDefaults.standard.set(basis.rawValue, forKey: UsageBasis.key)
            let panel = MultiPanelContent(snapshot: snap, preferences: prefs)
                .background(PanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: PanelBackground.cornerRadius, style: .continuous))
                .padding(16).background(back)
            try save(panel, "window-\(style.rawValue)-\(basis.rawValue).png")
        }}
        UserDefaults.standard.removeObject(forKey: UsageStyle.key); UserDefaults.standard.removeObject(forKey: UsageBasis.key)
    }
}
