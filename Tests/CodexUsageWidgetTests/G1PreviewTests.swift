import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

/// Writes G1 previews when G1_PREVIEW_DIR or SNAPSHOT_DIR is set; always checks row grouping.
final class G1PreviewTests: XCTestCase {
    private func window(_ title: String, _ percent: Double, _ reset: String, account: Int? = nil) -> UsageLimit {
        var limit = UsageLimit(title: title, leftPercent: percent, resetText: reset)
        limit.accountIndex = account
        return limit
    }

    private var fixture: MultiUsageSnapshot {
        MultiUsageSnapshot(sections: [
            ProviderSection(provider: .codex, windows: [window("5h", 78, "Resets 15:10 (2h10m)"),
                                                        window("Weekly", 77, "Resets 10/25 07:03 (4d17h)")],
                            stats: [ProviderStat(title: "Credits", valueText: "1,240 credits"),
                                    ProviderStat(title: "Reset tickets", valueText: "3 available · next expires 10/23 05:56"),
                                    ProviderStat(title: "Reset ticket", valueText: "完全リセット · 使用可 · 期限 10/23 05:56 · 付与 09/23 05:56 · codex_rate_limits"),
                                    ProviderStat(title: "Reset ticket", valueText: "完全リセット · 使用可 · 期限 10/30 04:10 · 付与 09/30 04:10 · codex_rate_limits"),
                                    ProviderStat(title: "Reset ticket", valueText: "完全リセット · 使用可 · 期限 11/07 08:36 · 付与 10/08 08:36 · codex_rate_limits"),
                                    ProviderStat(title: "Reset tickets updated", valueText: "13:38"),
                                    ProviderStat(title: "Reset ticket expiry", valueText: "2026-11-06T23:36:12Z"),
                                    ProviderStat(title: "Reset ticket expiry", valueText: "2026-10-22T20:56:33Z"),
                                    ProviderStat(title: "Reset ticket expiry", valueText: "2026-10-29T19:10:09Z"),
                                    ProviderStat(title: "Account", valueText: "sam***@e***")], failureText: nil),
            ProviderSection(provider: .claude, windows: [window("ali***@e*** · 5h", 25, "Resets 14:40", account: 0),
                                                         window("ali***@e*** · Weekly", 58, "Resets 10/26 10:00", account: 0),
                                                         window("bob***@s*** · 5h", 10, "Resets 16:05", account: 1),
                                                         window("bob***@s*** · Weekly", 33, "Resets 10/22 14:00", account: 1)],
                            stats: [], failureText: nil),
            ProviderSection(provider: .grok, windows: [window("gro***@x*** · Weekly", 75, "Resets 10/24 12:00")],
                            stats: [ProviderStat(title: "gro***@x*** · Monthly", valueText: "No monthly cap")], failureText: nil),
            ProviderSection(provider: .zai, windows: [window("5h", 88, "Resets 17:20"), window("Monthly", 52, "Resets 11/01")],
                            stats: [], failureText: nil),
            ProviderSection(provider: .antigravity, windows: [window("Gemini 4 Argon · Gemini 4 Argon Weekly Limit", 77, "Resets 10/24 12:20"),
                                                              window("Gemini Models · Weekly Limit Remaining", 92, "Resets 10/24 13:26"),
                                                              window("Gemini Models · Five Hour Limit Remaining", 75, "Resets 15:42"),
                                                              window("Claude and GPT models · Weekly Limit Remaining", 50, "Resets 21:57"),
                                                              window("Claude and GPT models · Five Hour Limit Remaining", 100, "Resets 18:43")],
                            stats: [], failureText: nil)
        ], codexSnapshot: nil, updatedAt: Date())
    }

    func testRealAntigravityTitles() {
        let section = ProviderSection(provider: .antigravity, windows: [
            window("Gemini 4 Argon · Gemini 4 Argon Weekly Limit", 77, "Resets 10/24 12:20"),
            window("Gemini Models · Weekly Limit Remaining", 92, "Resets 10/24 13:26"),
            window("Gemini Models · Five Hour Limit Remaining", 75, "Resets 15:42"),
            window("Claude and GPT models · Weekly Limit Remaining", 50, "Resets 21:57"),
            window("Claude and GPT models · Five Hour Limit Remaining", 100, "Resets 18:43")
        ], stats: [], failureText: nil)
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.map(\.name), ["Argon", "Gemini", "Claude/GPT"])
        XCTAssertNil(rows[0].five); XCTAssertEqual(rows[0].week?.percentInt, 77)
        XCTAssertEqual(rows[1].five?.percentInt, 75); XCTAssertEqual(rows[1].week?.percentInt, 92)
        XCTAssertEqual(rows[2].five?.percentInt, 100); XCTAssertEqual(rows[2].week?.percentInt, 50)
        let snap = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: Date())
        let bars = CollapsedUsageBar.bars(for: snap)
        let gemini = bars.first { $0.id == "antigravity-Gemini Models" }!
        XCTAssertEqual(MultiCollapsedUsageView.g1(for: gemini, rows: ServiceRowModel.rows(for: snap)).inner?.percentInt, 92)
    }

    func testRowGrouping() {
        let rows = ServiceRowModel.rows(for: fixture)
        XCTAssertEqual(rows.map(\.name), ["Codex", "Claude A", "Claude B", "Grok", "GLM", "Argon", "Gemini", "Claude/GPT"])
        XCTAssertEqual(rows[0].ticketLine(withTimes: true), "リセットチケット ×3 · 期限 10/23 05:56 · 10/30 04:10 · 11/07 08:36")
        XCTAssertEqual(rows[0].ticketLine(withTimes: false), "リセットチケット ×3 · 期限 10/23 · 10/30 · 11/07")
        XCTAssertNil(rows[3].inner)                 // Grok: weekly only
        XCTAssertEqual(rows[3].primary?.percentInt, 75)
        XCTAssertEqual(rows[4].extras.count, 1)     // GLM monthly bar
        XCTAssertEqual(rows[6].week?.percentInt, 92) // Antigravity weekly paired with 5h
        XCTAssertEqual(rows[7].week?.percentInt, 50)
        XCTAssertEqual(rows[0].tickets.count, 3)
        XCTAssertEqual(rows[0].ticketExpiries.count, 3)
        XCTAssertTrue(rows[0].ticketExpiries == rows[0].ticketExpiries.sorted())
        let base = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TicketList.relative(base.addingTimeInterval(2.7 * 86_400), now: base), "あと2日")
        XCTAssertEqual(TicketList.relative(base.addingTimeInterval(5 * 3600 + 10), now: base), "あと5時間")
        XCTAssertTrue(rows.allSatisfy { $0.account == nil })
        let named = ServiceRowModel.rows(for: fixture, showAccounts: true)
        XCTAssertEqual(named.map(\.account), ["sam***@e***", "ali***@e***", "bob***@s***", "gro***@x***", nil, nil, nil, nil])
        XCTAssertEqual(named[3].notes, ["Monthly: No monthly cap"])
    }

    @MainActor
    func testWritePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["G1_PREVIEW_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let name = "G1PreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        for (appearance, named) in [(PanelAppearance.dark, false), (.light, false), (.dark, true)] {
            preferences.appearance = appearance
            preferences.showAccountNames = named
            let host = NSHostingView(rootView: MultiPanelContent(snapshot: fixture, preferences: preferences)
                .background(PanelBackground())
                .background(appearance == .dark ? Color(white: 0.10) : .white)
                .environment(\.colorScheme, appearance.colorScheme ?? .light))
            let size = host.fittingSize
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = appearance.nsAppearance
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-\(appearance.rawValue)\(named ? "-accounts" : "").png"))
        }
    }

    @MainActor
    func testWriteTabPreviews() throws {
        let rows = ServiceRowModel.rows(for: fixture)
        let bars = CollapsedUsageBar.bars(for: fixture)
        XCTAssertEqual(MultiCollapsedUsageView.g1(for: bars[0], rows: rows).outer?.percentInt, 78)
        XCTAssertEqual(MultiCollapsedUsageView.g1(for: bars[0], rows: rows).inner?.percentInt, 77)
        XCTAssertNil(MultiCollapsedUsageView.g1(for: bars.first { $0.id == "grok" }!, rows: rows).inner)
        guard let dir = ProcessInfo.processInfo.environment["G1_PREVIEW_DIR"] else { return }
        for appearance in [PanelAppearance.dark, .light] {
            for height: CGFloat in [24, 37] {
                let size = MultiCollapsedUsageView.size(for: fixture, menuBarHeight: height)
                let view = MultiCollapsedUsageView(snapshot: fixture, menuBarHeight: height)
                    .background(MultiCollapsedTabSurface())
                    .padding(6)
                    .background(appearance == .dark ? Color(white: 0.12) : Color(red: 0.93, green: 0.95, blue: 0.98))
                    .environment(\.colorScheme, appearance.colorScheme ?? .light)
                let host = NSHostingView(rootView: view)
                let fit = CGSize(width: size.width + 12, height: size.height + 12)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: fit), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.appearance = appearance.nsAppearance
                window.contentView = host
                host.frame = CGRect(origin: .zero, size: fit)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(ceil(fit.width * 4)), pixelsHigh: Int(ceil(fit.height * 4)),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = fit
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tab-\(appearance.rawValue)-\(Int(height))pt.png"))
            }
        }
    }

    @MainActor
    func testWriteOrientationSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let menuBarHeight: CGFloat = 37
        let zooms: [(percent: Int, value: Double)] = [(100, 1.0), (60, 0.6), (250, 2.5)]
        for zoom in zooms {
            let horizontal = MultiCollapsedUsageView.size(
                for: fixture, barZoom: zoom.value, menuBarHeight: menuBarHeight, orientation: .horizontal)
            let vertical = MultiCollapsedUsageView.size(
                for: fixture, barZoom: zoom.value, menuBarHeight: menuBarHeight, orientation: .vertical)
            XCTAssertGreaterThan(horizontal.width, horizontal.height)
            XCTAssertGreaterThan(vertical.height, vertical.width)
            XCTAssertEqual(horizontal.width, vertical.height)
            XCTAssertEqual(horizontal.height, vertical.width)
        }

        for orientation in [PanelOrientation.horizontal, .vertical] {
            for zoom in zooms {
                let tabSize = MultiCollapsedUsageView.size(
                    for: fixture, barZoom: zoom.value, menuBarHeight: menuBarHeight, orientation: orientation)
                let view = MultiCollapsedUsageView(snapshot: fixture, barZoom: zoom.value,
                                                   menuBarHeight: menuBarHeight, orientation: orientation)
                    .background(MultiCollapsedTabSurface())
                    .padding(6)
                    .background(Color(white: 0.12))
                    .environment(\.colorScheme, .dark)
                let renderedSize = CGSize(width: tabSize.width + 12, height: tabSize.height + 12)
                let filename = zoom.percent == 100
                    ? "\(orientation.rawValue).png"
                    : "\(orientation.rawValue)-\(zoom.percent).png"
                try writeSnapshotPNG(view, size: renderedSize, directory: directory, filename: filename)
            }
        }

        let name = "OrientationSnapshots.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        preferences.appearance = .dark
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        for orientation in PanelOrientation.allCases {
            preferences.orientation = orientation
            let panel = MultiPanelContent(snapshot: fixture, preferences: preferences)
                .background(PanelBackground())
            let panelSize = NSHostingView(rootView: panel).fittingSize
            let tabSize = MultiCollapsedUsageView.size(for: fixture, menuBarHeight: menuBarHeight,
                                                      orientation: orientation)
            let tabFrame = CGRect(x: 32, y: screen.maxY - tabSize.height - 8,
                                  width: tabSize.width, height: tabSize.height)
            let panelFrame = CGRect(origin: TabPositioning.panelOrigin(size: panelSize, anchor: tabFrame,
                visibleFrame: visible, screenFrame: screen, orientation: orientation), size: panelSize)
            let bounds = tabFrame.union(panelFrame)
            let view = ZStack(alignment: .topLeading) {
                MultiCollapsedUsageView(snapshot: fixture, menuBarHeight: menuBarHeight, orientation: orientation)
                    .background(MultiCollapsedTabSurface())
                    .offset(x: tabFrame.minX - bounds.minX, y: bounds.maxY - tabFrame.maxY)
                panel
                    .frame(width: panelSize.width, height: panelSize.height)
                    .offset(x: panelFrame.minX - bounds.minX, y: bounds.maxY - panelFrame.maxY)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .padding(6)
            .background(Color(white: 0.12))
            .environment(\.colorScheme, .dark)
            try writeSnapshotPNG(view, size: CGSize(width: bounds.width + 12, height: bounds.height + 12),
                                 directory: directory, filename: "expanded-\(orientation.rawValue).png")
        }
    }

    @MainActor
    func testWriteHoverGlassPreviews() throws {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        var sections = fixture.sections
        sections[0].codexExtras = CodexExtrasParser.Extras(
            creditsText: "1,240 credits", availableCount: 2, ticketExpiries: [], tickets: [
                .init(title: "完全リセット", status: "available", expiresAt: now.addingTimeInterval(86_400)),
                .init(title: "完全リセット", status: "available", expiresAt: now.addingTimeInterval(172_800)),
                .init(title: "完全リセット", status: "expired", expiresAt: now.addingTimeInterval(-86_400))
            ])
        let snapshot = MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: now)
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "codex" })
        let model = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
        for appearance in [PanelAppearance.light, .dark] {
            let view = RingDetailCardView(model: model)
                .background(appearance == .dark ? Color(white: 0.10) : .white,
                            in: RoundedRectangle(cornerRadius: 11))
                .padding(12)
                .background(LinearGradient(colors: [.blue.opacity(0.3), .orange.opacity(0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, appearance.colorScheme ?? .light)
            let size = NSHostingView(rootView: view).fittingSize
            try writeSnapshotPNG(view, size: size, directory: directory,
                filename: "hover-\(appearance.rawValue)-glass.png",
                appearance: appearance)
        }
    }

    @MainActor
    private func writeSnapshotPNG<Content: View>(_ view: Content, size: CGSize,
                                                  directory: URL, filename: String,
                                                  appearance: PanelAppearance = .dark) throws {
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)

        let pixelsPerPoint: CGFloat = 4
        let pixelWidth = Int(ceil(size.width * pixelsPerPoint))
        let pixelHeight = Int(ceil(size.height * pixelsPerPoint))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = directory.appendingPathComponent(filename)
        try png.write(to: output, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, pixelWidth)
        XCTAssertEqual(decoded.pixelsHigh, pixelHeight)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

}
