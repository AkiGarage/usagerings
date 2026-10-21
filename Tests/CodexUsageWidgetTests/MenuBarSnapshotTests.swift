import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class MenuBarSnapshotTests: XCTestCase {
    func testOrderedGroupsUseLowestWindowAndKeepAccountsSeparate() {
        let bars = CollapsedUsageBar.bars(for: fixture())
        XCTAssertEqual(bars.map(\.title), ["Codex", "Claude A 5h", "Claude B 5h", "Grok", "GLM 5h",
                                           "Gemini 4 Argon", "Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(bars.compactMap { $0.limit?.leftPercent }, [78, 90, 95, 75, 88, 86, 76, 66])
        XCTAssertEqual(Set(bars.map(\.id)).count, 8)
        XCTAssertEqual(Set(bars.map { String(describing: $0.providerColor) }).count, 6)
    }

    func testGroupCasingDoesNotDuplicateOrReorderPools() {
        let snapshot = fixture()
        var sections = snapshot.sections
        sections[0].windows = sections[0].windows.map {
            UsageLimit(title: $0.title.uppercased(), leftPercent: $0.leftPercent, resetText: $0.resetText)
        }
        let normalized = MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: snapshot.updatedAt)
        XCTAssertEqual(CollapsedUsageBar.bars(for: normalized).map(\.title),
                       CollapsedUsageBar.bars(for: snapshot).map(\.title))
        XCTAssertEqual(CollapsedUsageBar.bars(for: normalized).map { $0.limit?.leftPercent },
                       CollapsedUsageBar.bars(for: snapshot).map { $0.limit?.leftPercent })
    }

    func testThresholdsAndUnavailableSlots() {
        for (percent, tone) in [(35.0, UsageTone.healthy), (34, .warning), (20, .warning), (19, .critical), (0, .critical)] {
            let bar = CollapsedUsageBar.bars(for: fixture(claudeB: percent))[2]
            XCTAssertEqual(bar.limit?.tone, tone)
            XCTAssertEqual(bar.isWarning, percent < 35)
            XCTAssertEqual(bar.fillColor == bar.providerColor, percent >= 35)
        }
        let empty = CollapsedUsageBar.bars(for: .placeholder)
        XCTAssertEqual(empty.count, 8)
        XCTAssertTrue(empty.allSatisfy { $0.limit == nil && !$0.isWarning })
        XCTAssertEqual(CollapsedUsageBar.detailText(for: try XCTUnwrap(empty.last)), "No data")
    }

    @MainActor
    func testRingTabGeometryGrowsWithGroupsAndZoom() {
        var snapshot = fixture()
        var sections = snapshot.sections
        sections[0].windows.append(UsageLimit(title: "Additional group · Daily", leftPercent: 40, resetText: ""))
        snapshot = MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: snapshot.updatedAt)
        XCTAssertEqual(CollapsedUsageBar.bars(for: snapshot).count, 9)
        let base = MultiCollapsedUsageView.size(for: fixture(), menuBarHeight: 37)
        let layout = MultiCollapsedUsageView.layout(barZoom: 1, menuBarThickness: 37)
        XCTAssertEqual(MultiCollapsedUsageView.size(for: snapshot, menuBarHeight: 37).width,
                       base.width + layout.ringDiameter + MultiCollapsedUsageView.spacing, accuracy: 1)
        XCTAssertLessThanOrEqual(base.height, 36)
        XCTAssertLessThan(layout.ringDiameter, base.height)
        let zoomed = MultiCollapsedUsageView.size(for: fixture(), barZoom: 1.5, menuBarHeight: 37)
        XCTAssertGreaterThan(zoomed.width, base.width)
        XCTAssertGreaterThan(zoomed.height, base.height)
        let small = MultiCollapsedUsageView.size(for: fixture(), barZoom: 0.75, menuBarHeight: 37)
        XCTAssertLessThan(small.height, base.height)
    }


    @MainActor
    func testPresentationResizesCollapsedDraggingAndExpanded() {
        let presentation = EdgeTabPresentationState()
        var changes = 0
        presentation.onSizeChange = { changes += 1 }
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: fixture())
        XCTAssertEqual(changes, 1)
        let collapsedSize = MultiCollapsedUsageView.size(for: fixture())
        for mode in [EdgeTabPresentationMode.collapsed, .dragging, .expanded] {
            presentation.mode = mode
            let expectedHeight = mode == .expanded ? max(30, collapsedSize.height) : collapsedSize.height
            XCTAssertEqual(presentation.size,
                           CGSize(width: collapsedSize.width, height: expectedHeight))
        }
    }


    private var writesLegacySnapshots: Bool {
        ProcessInfo.processInfo.environment["CODEX_USAGE_WIDGET_WRITE_LEGACY_SNAPSHOTS"] == "1"
    }

    private var writesRequestedBarSnapshots: Bool {
        ProcessInfo.processInfo.environment["CODEX_USAGE_WIDGET_WRITE_LEGACY_SNAPSHOTS"] == "1"
    }

    private func nsColor(for color: Color, environment: EnvironmentValues) -> NSColor {
        let resolved = color.resolve(in: environment)
        return NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green),
                       blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity))
    }

    private func columnBounds(in bitmap: NSBitmapImageRep, matching expected: NSColor) -> ClosedRange<Int>? {
        var columns: [Int] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let pixel = bitmap.colorAt(x: x, y: y),
                      abs(pixel.redComponent - expected.redComponent) < 0.04,
                      abs(pixel.greenComponent - expected.greenComponent) < 0.04,
                      abs(pixel.blueComponent - expected.blueComponent) < 0.04 else { continue }
                columns.append(x)
                break
            }
        }
        guard let first = columns.min(), let last = columns.max() else { return nil }
        return first...last
    }

    private func assertColor(_ actual: NSColor, matches expected: NSColor,
                             message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.04, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.04, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.04, message, file: file, line: line)
    }

    private func fixture(claudeB: Double = 95) -> MultiUsageSnapshot {
        func window(_ title: String, _ percent: Double, account: Int? = nil) -> UsageLimit {
            var limit = UsageLimit(title: title, leftPercent: percent, resetText: "Fixture")
            limit.accountIndex = account
            return limit
        }
        // Intentionally shuffle providers and windows, and give both accounts identical masked labels.
        return MultiUsageSnapshot(sections: [
            ProviderSection(provider: .antigravity, windows: [
                window("Claude and GPT models · Weekly", 66), window("Gemini Models · Daily", 96),
                window("Gemini 4 Argon · 5h", 86), window("Gemini Models · Weekly", 76),
                window("Claude and GPT models · Daily", 98)
            ], stats: [], failureText: nil),
            ProviderSection(provider: .grok, windows: [window("Weekly", 75)], stats: [], failureText: nil),
            ProviderSection(provider: .zai, windows: [window("5h", 88)], stats: [], failureText: nil),
            ProviderSection(provider: .claude, windows: [
                window("Account · 5h", 90, account: 0), window("Account · Weekly", 68, account: 0),
                window("Account · 5h", claudeB, account: 1), window("Account · Weekly", 58, account: 1)
            ], stats: [], failureText: nil),
            ProviderSection(provider: .codex, windows: [window("Session", 92), window("Weekly", 78)], stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }
}
