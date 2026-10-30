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
        XCTAssertEqual(p.paceText, "余裕 -8%")
        XCTAssertEqual(p.tone, .under)
    }

    func testUnknownResetHasNoMarker() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: nil), now: now)
        XCTAssertNil(p.elapsedPercent)
        XCTAssertEqual(p.rangeText, "リセット 不明")
        XCTAssertTrue(p.paceText.contains("不明"))
    }

    func testPassedResetIsUnknown() {
        let p = WeeklyPace(label: "週", limit: weekly(left: 40, resetIn: -60), now: now)
        XCTAssertNil(p.elapsedPercent)
        XCTAssertTrue(p.rangeText.contains("要更新"))
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
        XCTAssertEqual(model.paces.count, 1)
        XCTAssertEqual(model.paces.first?.paceText, "均等より+12%使いすぎ")
    }

    func testTodaySliceIsTheDayContainingNow() {
        // 2 days in (5 to reset): day 3 of 7, even use should go from 28.6% to 42.9% today.
        let p = WeeklyPace(label: "週", limit: weekly(left: 59, resetIn: 5 * 86_400), now: now)
        XCTAssertEqual(p.todayIndex, 2)
        XCTAssertEqual(p.todayRange!.lowerBound, 200.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.todayRange!.upperBound, 300.0 / 7, accuracy: 0.01)
        XCTAssertEqual(p.todayText, "今日の枠 29〜43%（3/7日目）")
        XCTAssertTrue(p.footerText.hasSuffix("今日の枠 29〜43%（3/7日目）"))
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
            WeeklyPace(label: "Z.ai 週", limit: weekly(left: 40, resetIn: nil), now: now),
        ]
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
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("bars-\(dark ? "dark" : "light").png"))
        }
    }
}
