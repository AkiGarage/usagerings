import XCTest
import AppKit
import SwiftUI
@testable import CodexUsageWidget

final class WeeklyPaceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func weekly(left: Double, resetIn: TimeInterval?) -> UsageLimit {
        var w = UsageLimit(title: "Weekly", leftPercent: left, resetText: "")
        w.resetAt = resetIn.map { now.addingTimeInterval($0) }
        return w
    }

    func testOveruseAheadOfPace() {
        // 2 days into the week (5 days to reset) = 28.6% elapsed; 41% used -> +12.
        let p = WeeklyPace(label: "週", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.elapsedPercent!, 200.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.paceText, "均等より+12%使いすぎ")
        XCTAssertEqual(p.tone, .over)
    }

    func testSurplusBehindPace() {
        // 4 days in = 57.1% elapsed; 49% used -> -8.
        let p = WeeklyPace(label: "週", limit: weekly(left: 51, resetIn: 3 * 86_400), now: now)
        XCTAssertEqual(p.paceText, "均等より使用8%少ない（余裕あり）")
        XCTAssertEqual(p.tone, .under)
    }

    func testUnknownResetHasNoMarker() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: nil), now: now)
        XCTAssertNil(p.elapsedPercent)
        XCTAssertEqual(p.resetStatusText, "リセット 不明")
        XCTAssertTrue(p.paceText.contains("不明"))
    }

    func testPassedResetIsUnknown() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: -60), now: now)
        XCTAssertNil(p.elapsedPercent)
        XCTAssertTrue(p.resetStatusText.contains("要更新"))
    }

    func testToneMatchesRoundedText() {
        // 2.6 points ahead rounds to +3: text and colour agree.
        let left = 100 - (200.0 / 7 + 2.6)
        let p = WeeklyPace(label: "週", limit: weekly(left: left, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.paceText, "均等より+3%使いすぎ")
        XCTAssertEqual(p.tone, .over)
    }

    func testCardShowsOnlyWeeklyPaces() {
        var five = UsageLimit(title: "5h", leftPercent: 50, resetText: ""); five.resetAt = now.addingTimeInterval(3600)
        let snap = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [five, weekly(left: 59, resetIn: 5 * 86_400)], stats: [], failureText: nil)],
                                      codexSnapshot: nil, updatedAt: now)
        let bar = CollapsedUsageBar.bars(for: snap, blockedPreview: nil).first { $0.provider == .codex }!
        let model = RingDetailCardModel.make(bar: bar, now: now)!
        XCTAssertEqual(model.paces.count, 2)
        XCTAssertTrue(model.paces[0].isFiveHour)
        XCTAssertEqual(model.paces.last?.paceText, "均等より+12%使いすぎ")
    }

    func testTodaySliceIsTheDayContainingNow() {
        // 2 days in (5 to reset): day 3 of 7, even use should go from 28.6% to 42.9% today.
        let p = WeeklyPace(label: "週", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.todayIndex, 2)
        XCTAssertEqual(p.todayRange!.lowerBound, 200.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.todayRange!.upperBound, 300.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.todayText, "今日の目安：使用43%まで（あと 2%）")
        XCTAssertTrue(p.footerText.hasSuffix("今日の目安：使用43%まで（あと 2%）"))
        XCTAssertTrue(p.resetStatusText.hasPrefix("あと"), p.resetStatusText)
        XCTAssertFalse(p.todayOver)
    }

    func testGeminiAppWindowsAreLabelledByWindow() {
        XCTAssertEqual(RingCardLabel.label(for: "Gemini · 5h"), "5時間枠")
        XCTAssertEqual(RingCardLabel.label(for: "Gemini · Weekly"), "週の枠")
    }

    func testTodayLeftFollowsEachUsageRefresh() {
        // Same day and reset; only the usage changes between refreshes -> target fixed, remainder live.
        let reset: TimeInterval = 5 * 86_400
        let a = WeeklyPace(label: "週", limit: weekly(left: 70, resetIn: reset), now: now)
        let b = WeeklyPace(label: "週", limit: weekly(left: 62, resetIn: reset - 600), now: now.addingTimeInterval(600))
        let c = WeeklyPace(label: "週", limit: weekly(left: 50, resetIn: reset - 1200), now: now.addingTimeInterval(1200))
        XCTAssertEqual([a.todayTarget, b.todayTarget, c.todayTarget], [43, 43, 43])
        XCTAssertEqual(a.todayText, "今日の目安：使用43%まで（あと 13%）")
        XCTAssertEqual(b.todayText, "今日の目安：使用43%まで（あと 5%）")
        XCTAssertEqual(c.todayText, "今日の目安：使用43%まで（7% 超過）")
        XCTAssertTrue(c.todayOver)
        XCTAssertFalse(a.todayOver)
    }

    func testTodaySliceEdges() {
        let first = WeeklyPace(label: "週", limit: weekly(left: 99, resetIn: 7 * 86_400 - 60), now: now)
        XCTAssertEqual(first.todayIndex, 0)
        let last = WeeklyPace(label: "週", limit: weekly(left: 10, resetIn: 60), now: now)
        XCTAssertEqual(last.todayIndex, 6)
        XCTAssertEqual(last.todayRange!.upperBound, 100, accuracy: 0.001)
        let mid = WeeklyPace(label: "週", limit: weekly(left: 50, resetIn: 3.5 * 86_400 - 1), now: now)
        XCTAssertEqual(mid.todayIndex, 3)
    }

    func testUnknownResetHasNoDaySlices() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: nil), now: now)
        XCTAssertNil(p.todayIndex)
        XCTAssertNil(p.todayRange)
        XCTAssertEqual(p.footerText, "リセット 不明")
    }

    @MainActor
    func testWritePaceBarPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PACE_SHOTS_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paces = [
            WeeklyPace(label: "Codex 週", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now),
            WeeklyPace(label: "Claude 週", limit: weekly(left: 51, resetIn: 3 * 86_400 + 7200), now: now),
            WeeklyPace(label: "Grok 週", limit: weekly(left: 92, resetIn: 6.5 * 86_400), now: now),
            WeeklyPace(label: "Kimi 週", limit: weekly(left: 20, resetIn: 4 * 86_400), now: now),
            WeeklyPace(label: "Z.ai 週", limit: weekly(left: 40, resetIn: nil), now: now),
        ]
        let styles: [(WeeklyPaceBar.MarkerStyle, String)] = [(.bracket, "A-bracket"), (.outline, "B-outline"), (.dim, "C-dim"), (.outline, "final")]
        defer { WeeklyPaceBar.markerStyle = .outline }
        for (style, tag) in styles {
        WeeklyPaceBar.markerStyle = style
        for dark in [true, false] {
            let view = VStack(spacing: 10) {
                ForEach(Array(paces.enumerated()), id: \.offset) { _, p in WeeklyPaceBar(pace: p) }
                WeeklyPaceBar(pace: paces[0], compact: true)
            }
            .padding(14).frame(width: 340)
            .background(dark ? Color(white: 0.12) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tag)-bars-\(dark ? "dark" : "light").png"))
        }
        }
    }

    func testDetailCardShowsOneWeeklyRowUnderFiveHour() throws {
        let snap = UsageRingsDemoFixture.snapshot(now: now)
        let bars = CollapsedUsageBar.bars(for: snap, blockedPreview: nil)
        for prefix in ["codex", "claude", "gemini"] {
            let bar = try XCTUnwrap(bars.first { $0.id.hasPrefix(prefix) }, prefix)
            let m = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
            XCTAssertEqual(m.orderedRows(.five).count, 1, prefix)
            XCTAssertEqual(m.orderedRows(.week).count, 1, prefix)
            XCTAssertEqual(m.paces.map(\.label), ["5時間枠", "週の枠"], prefix)
            XCTAssertTrue(m.detailFallbackRows.isEmpty, "詳細 must not repeat 5h/weekly as plain rows: \(prefix)")
        }
    }

    func testBasisSwitchesNumbersPaceAndCaption() {
        let p = WeeklyPace(label: "週の枠", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.valueText(.left), "残り 59%")
        XCTAssertEqual(p.valueText(.used), "使用 41%")
        XCTAssertEqual(p.paceText(.left), "均等より残り12%少ない")
        XCTAssertEqual(p.paceText(.used), "均等より+12%使いすぎ")
        XCTAssertEqual(p.todayText(.used), "今日の目安：使用43%まで（あと 2%）")
        XCTAssertEqual(p.todayText(.left), "今日の目安：残り57%まで（あと 2%）")
        XCTAssertEqual(UsageBasis.left.shownPercent(leftPercent: 70), 70)
        XCTAssertEqual(UsageBasis.used.shownPercent(leftPercent: 70), 30)
    }

    func testDefaultsAreLeftAndDetail() {
        XCTAssertEqual(UsageBasis.defaultValue, .left)
        XCTAssertEqual(UsageStyle.defaultValue, .detail)
    }

    func testFiveHourDetailHasHourSlicesAndRecoveryText() {
        var five = UsageLimit(title: "5h", leftPercent: 60, resetText: ""); five.resetAt = now.addingTimeInterval(80 * 60)
        let p = WeeklyPace(label: "5時間枠", limit: five, now: now, period: WeeklyPace.fiveHours)
        XCTAssertEqual(p.slices, 5)
        XCTAssertNil(p.todayRange)
        XCTAssertNil(p.todayText(.left))
        XCTAssertEqual(p.elapsedPercent!, 220.0 / 300 * 100, accuracy: 0.01)
        XCTAssertTrue(p.recoverText!.hasPrefix("あと1時間20分で回復"), p.recoverText!)
    }

    func testPanelDetailPacesPutFiveHourFirst() {
        var five = UsageLimit(title: "5h", leftPercent: 50, resetText: ""); five.resetAt = now.addingTimeInterval(3600)
        let section = ProviderSection(provider: .codex, windows: [weekly(left: 59, resetIn: 5 * 86_400), five], stats: [], failureText: nil)
        let row = ServiceRowModel.rows(for: section)[0]
        XCTAssertEqual(row.detailPaces(now: now).map(\.label), ["5時間枠", "週の枠"])
    }

    @MainActor
    func testWriteToggleMatrixPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOGGLE_SHOTS_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let saved = (d.object(forKey: UsageBasis.key), d.object(forKey: UsageStyle.key))
        defer { d.set(saved.0, forKey: UsageBasis.key); d.set(saved.1, forKey: UsageStyle.key) }
        let snap = UsageRingsDemoFixture.snapshot(now: now)
        let bars = CollapsedUsageBar.bars(for: snap, blockedPreview: nil)
        for basis in UsageBasis.allCases { for style in UsageStyle.allCases {
            d.set(basis.rawValue, forKey: UsageBasis.key); d.set(style.rawValue, forKey: UsageStyle.key)
            for prefix in ["claude", "codex", "gemini"] {
                let bar = try XCTUnwrap(bars.first { $0.id.hasPrefix(prefix) })
                let m = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
                for dark in (basis == .left && style == .detail ? [true, false] : [true]) {
                    let view = RingDetailCardView(model: m).padding(14)
                        .background(dark ? Color(white: 0.12) : .white)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    try snapshotPNG(view, dark: dark, to: "\(dir)/card-\(basis.rawValue)-\(style.rawValue)-\(prefix)-\(dark ? "dark" : "light").png")
                }
            }
            let suite = "toggle.preview.\(UUID().uuidString)"
            let prefs = PanelPreferences(defaults: UserDefaults(suiteName: suite)!)
            let panel = MultiPanelContent(snapshot: snap, preferences: prefs).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
            try snapshotPNG(panel, dark: true, to: "\(dir)/panel-\(basis.rawValue)-\(style.rawValue)-dark.png")
            UserDefaults.standard.removePersistentDomain(forName: suite)
        } }
    }

    @MainActor
    private func snapshotPNG<V: View>(_ view: V, dark: Bool, to path: String) throws {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    func testWriteCardPreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["PACE_SHOTS_DIR"] else { return }
        let snap = UsageRingsDemoFixture.snapshot(now: now)
        let bars = CollapsedUsageBar.bars(for: snap, blockedPreview: nil)
        for prefix in ["claude", "codex", "gemini"] {
            let bar = try XCTUnwrap(bars.first { $0.id.hasPrefix(prefix) })
            let m = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
            for dark in [true, false] {
                let view = RingDetailCardView(model: m).padding(14)
                    .background(dark ? Color(white: 0.12) : .white)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                let size = host.fittingSize
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = size
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("card-\(prefix)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
