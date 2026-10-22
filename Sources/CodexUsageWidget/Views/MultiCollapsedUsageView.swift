import AppKit
import SwiftUI

struct CollapsedUsageBar: Identifiable {
    let id: String
    let label: String
    let title: String
    let providerColor: Color
    let limit: UsageLimit?
    /// Every window the provider reports for this account; the ring's own arc is `limit`.
    /// Source of the hover card rows.
    var windows: [UsageLimit] = []
    /// Only the Codex ring carries these parsed, optional sidecar details.
    var codexExtras: CodexExtrasParser.Extras? = nil
    var zaiResetTickets: ZaiResetTickets? = nil
    var block: ClaudeBlock? = nil
    var blockedSymbolName: String = Self.blockedSymbol
    var isBlocked: Bool { block?.isActive(at: Date()) == true }
    static let blockedSymbol = "lock.fill"
    static let blockedPauseSymbol = "pause.circle.fill"
    private static let previewBlock = ClaudeBlock(kind: .session, resetAt: Date().addingTimeInterval(7200), timeZoneKnown: true)

    var fillColor: Color {
        if isBlocked { return .secondary }
        // Warning/critical replace the provider fill AND outline so every provider signals low quota clearly.
        switch limit?.tone {
        case .warning: return Self.warningColor
        case .critical: return Self.criticalColor
        default: return providerColor
        }
    }

    var isWarning: Bool { !isBlocked && (limit?.tone == .warning || limit?.tone == .critical) }

    static func detailText(for bar: Self) -> String {
        if let block = bar.block, bar.isBlocked { return ClaudeRateLimitParser.cardLine(block: block, now: Date()) }
        return bar.limit?.leftText ?? "No data"
    }

    /// Claude icon orange (#D97757) and a slightly deeper shade (#C4623F).
    static let claudeAColor = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let claudeBColor = Color(red: 0xC4 / 255, green: 0x62 / 255, blue: 0x3F / 255)
    static let codexColor = Color(red: 0x19 / 255, green: 0xB6 / 255, blue: 0xE6 / 255)
    static let antigravityColor = Color(red: 0x34 / 255, green: 0xA8 / 255, blue: 0x53 / 255)
    static let criticalColor = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let warningColor = Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x20 / 255)

    /// Short display name for rings ("Claude A", "GLM", group names for Antigravity).
    var ringName: String {
        if id.hasPrefix("claude-") { return title.replacingOccurrences(of: " 5h", with: "") }
        if id == "zai" { return "GLM" }
        return title
    }

    /// "10/22 14:00 (2d3h)" without the "Resets " prefix.
    var resetShort: String {
        guard let text = limit?.resetText else { return "No data" }
        return text.hasPrefix("Resets ") ? String(text.dropFirst(7)) : text
    }
    /// GLM / Z.ai: indigo (#5B6CFF), distinct from Codex cyan, Antigravity green, Grok gray.
    static let glmColor = Color(red: 0x5B / 255, green: 0x6C / 255, blue: 0xFF / 255)

    static let grokColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.18, alpha: 1)
    })

    static func bars(for snapshot: MultiUsageSnapshot,
                     blockedPreview: String? = ProcessInfo.processInfo.environment["MULTIUSAGE_PREVIEW_BLOCKED"]) -> [Self] {
        func windows(_ provider: ProviderID) -> [UsageLimit] {
            snapshot.sections.filter { $0.provider == provider }.flatMap(\.windows)
        }
        func lowest(_ windows: [UsageLimit]) -> UsageLimit? {
            windows.min { $0.clampedLeftPercent < $1.clampedLeftPercent }
        }
        /// Prefer the 5h window; fall back to the lowest window if no 5h is reported.
        func fiveHour(_ windows: [UsageLimit]) -> UsageLimit? {
            let five = windows.filter { window in
                window.title.components(separatedBy: " · ").contains { $0.trimmingCharacters(in: .whitespaces) == "5h" }
            }
            return lowest(five.isEmpty ? windows : five)
        }
        // Order (left to right) matches the window (top to bottom):
        // Codex, Claude 5h, Grok, GLM 5h, Antigravity.
        let codexWindows = windows(.codex)
        let codexExtras = snapshot.sections.first { $0.provider == .codex }?.codexExtras
        var bars = [Self(id: "codex", label: "C", title: "Codex", providerColor: codexColor,
                         limit: lowest(codexWindows), windows: codexWindows, codexExtras: codexExtras)]
        let claude = windows(.claude)
        let blocks = snapshot.sections.first { $0.provider == .claude }?.claudeBlocks ?? [:]
        let accountCount = max(2, (claude.compactMap(\.accountIndex).max() ?? 0) + 1)
        for index in 0..<accountCount {
            let label = String(UnicodeScalar(65 + min(index, 25))!)
            let accountWindows = claude.filter { ($0.accountIndex ?? 0) == index }
            let preview = index == 1 && (blockedPreview == "lock" || blockedPreview == "pause")
            bars.append(Self(id: "claude-\(index)", label: label, title: "Claude \(label) 5h",
                             providerColor: index == 0 ? claudeAColor : claudeBColor,
                             limit: fiveHour(accountWindows), windows: accountWindows,
                             block: preview ? Self.previewBlock : blocks[index],
                             blockedSymbolName: preview && blockedPreview == "pause" ? Self.blockedPauseSymbol : Self.blockedSymbol))
        }
        let grokWindows = windows(.grok)
        bars.append(Self(id: "grok", label: "X", title: "Grok", providerColor: grokColor,
                         limit: lowest(grokWindows), windows: grokWindows))
        let zaiWindows = windows(.zai)
        bars.append(Self(id: "zai", label: "Z", title: "GLM 5h", providerColor: glmColor,
                         limit: fiveHour(zaiWindows), windows: zaiWindows,
                         zaiResetTickets: snapshot.sections.first { $0.provider == .zai }?.zaiResetTickets))
        let required = ["Gemini 4 Argon", "Gemini Models", "Claude and GPT models"]
        let antigravity = Dictionary(grouping: windows(.antigravity)) { window in
            let name = window.title.components(separatedBy: " · ")[0]
            if let exact = required.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
            // CLI-style titles ("Gemini weekly", "Claude/GPT 5-hour"): fold into the same group.
            let short = ServiceRowModel.antigravityName(ServiceRowModel.groupName(window.title))
            return required.first { ServiceRowModel.antigravityName($0) == short } ?? short
        }
        // Keep every returned group, including new groups, with Argon ahead of the main pools.
        let names = Set(antigravity.keys).union(required).sorted { lhs, rhs in
            func rank(_ name: String) -> Int {
                if name.localizedCaseInsensitiveContains("argon") { return 0 }
                if name == "Gemini Models" { return 1 }
                if name == "Claude and GPT models" { return 2 }
                return 3
            }
            return rank(lhs) == rank(rhs) ? lhs < rhs : rank(lhs) < rank(rhs)
        }
        bars += names.map { name in
            let groupWindows = antigravity[name] ?? []
            return Self(id: "antigravity-\(name)", label: "G", title: name, providerColor: antigravityColor,
                        limit: lowest(groupWindows), windows: groupWindows)
        }
        return bars
    }
}

struct MultiCollapsedUsageView: View {
    let snapshot: MultiUsageSnapshot
    var barZoom: Double = 1
    var menuBarHeight: CGFloat = NSStatusBar.system.thickness
    var orientation: PanelOrientation = .horizontal
    /// Ring under the cursor (hover card); nil = none.
    var highlightedBarID: String? = nil
    static let spacing: CGFloat = 5

    struct Layout {
        let tabHeight: CGFloat
        let ringDiameter: CGFloat
        let lineWidth: CGFloat
        let horizontalPadding: CGFloat
        let fontSize: CGFloat
    }

    static func layout(barZoom: Double, menuBarThickness: CGFloat) -> Layout {
        let zoom = scale(for: barZoom)
        let usableHeight = max(0, menuBarThickness - 1)
        // Zoom above 1 grows past the menu bar; TabPositioning anchors the top edge.
        let tabHeight = zoom <= 1
            ? usableHeight * (0.55 + (zoom - 0.75) * 0.80)
            : usableHeight * 0.75 * zoom
        let diameter = max(8, tabHeight - 4)
        return Layout(tabHeight: tabHeight, ringDiameter: diameter,
                      lineWidth: max(2, diameter * 0.16),
                      horizontalPadding: tabHeight * 0.45,
                      fontSize: max(5, diameter * 0.34))
    }

    static func size(for snapshot: MultiUsageSnapshot, barZoom: Double = 1,
                     menuBarHeight: CGFloat = NSStatusBar.system.thickness,
                     orientation: PanelOrientation = .horizontal) -> CGSize {
        let count = CGFloat(CollapsedUsageBar.bars(for: snapshot).count)
        let layout = layout(barZoom: barZoom, menuBarThickness: menuBarHeight)
        let width = count * (layout.ringDiameter + spacing) - spacing + layout.horizontalPadding * 2
        return orientation == .horizontal
            ? CGSize(width: ceil(width), height: layout.tabHeight)
            : CGSize(width: layout.tabHeight, height: ceil(width))
    }

    /// Ring square for an index in top-left coordinates of the collapsed view,
    /// mirroring the centered stack layout (nil when out of range).
    static func ringFrame(index: Int, size: CGSize, layout: Layout, count: Int,
                          orientation: PanelOrientation) -> CGRect? {
        guard count > 0, index >= 0, index < count, layout.ringDiameter > 0 else { return nil }
        let diameter = layout.ringDiameter
        let length = CGFloat(count) * diameter + CGFloat(count - 1) * spacing
        let alongTotal = orientation == .horizontal ? size.width : size.height
        let crossTotal = orientation == .horizontal ? size.height : size.width
        guard alongTotal >= length, crossTotal >= diameter else { return nil }
        let along = (alongTotal - length) / 2 + CGFloat(index) * (diameter + spacing)
        let cross = (crossTotal - diameter) / 2
        return orientation == .horizontal
            ? CGRect(x: along, y: cross, width: diameter, height: diameter)
            : CGRect(x: cross, y: along, width: diameter, height: diameter)
    }

    /// Index of the ring under a top-left-origin point (nil in gaps and margins).
    static func ringIndex(at point: CGPoint, size: CGSize, layout: Layout, count: Int,
                          orientation: PanelOrientation) -> Int? {
        guard count > 0 else { return nil }
        for index in 0..<count {
            if let frame = ringFrame(index: index, size: size, layout: layout, count: count,
                                     orientation: orientation), frame.contains(point) {
                return index
            }
        }
        return nil
    }

    var body: some View {
        let layout = Self.layout(barZoom: barZoom, menuBarThickness: menuBarHeight)
        let size = Self.size(for: snapshot, barZoom: barZoom, menuBarHeight: menuBarHeight,
                             orientation: orientation)
        let stack = orientation == .horizontal
            ? AnyLayout(HStackLayout(spacing: Self.spacing))
            : AnyLayout(VStackLayout(spacing: Self.spacing))
        stack {
            let rows = ServiceRowModel.rows(for: snapshot)
            ForEach(CollapsedUsageBar.bars(for: snapshot)) { bar in
                let arcs = Self.g1(for: bar, rows: rows)
                // Small sizes drop only the inner arc; the weekly % stays in the gap (see TabG1Gauge).
                TabG1Gauge(bar: bar, outer: arcs.outer, weekly: arcs.inner,
                           diameter: layout.ringDiameter)
                .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                .overlay {
                    if highlightedBarID == bar.id {
                        // Hover highlight stays inside the ring frame (no layout shift).
                        Circle()
                            .strokeBorder((bar.isBlocked ? Color.secondary : bar.providerColor).opacity(bar.isBlocked ? 0.45 : 0.9),
                                          lineWidth: max(1, layout.lineWidth * 0.28))
                            .shadow(color: bar.isBlocked ? .clear : bar.providerColor.opacity(0.5), radius: 1.5)
                    }
                }
                .help(Self.accessibilitySummary(for: bar, rows: rows))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilitySummary(for: bar, rows: rows))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Inner arc source: the weekly window of the same service, only when the outer arc is 5h.
    static func weekly(for bar: CollapsedUsageBar, rows: [ServiceRowModel]) -> ServiceRowModel? {
        let key: String
        if bar.id.hasPrefix("claude-") { key = bar.id }
        else if bar.id.hasPrefix("antigravity-") { key = "antigravity-" + String(bar.id.dropFirst(12)) }
        else { key = bar.id + "-main" }
        if bar.id.hasPrefix("antigravity-") {
            let short = ServiceRowModel.antigravityName(String(bar.id.dropFirst(12)))
            return rows.first { $0.id.hasPrefix("antigravity-") && $0.name == short }
        }
        return rows.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame })
    }

    /// G1 arcs: outer = 5h when reported (else the bar's own window), inner = weekly beside a 5h.
    static func g1(for bar: CollapsedUsageBar, rows: [ServiceRowModel]) -> (outer: UsageLimit?, inner: UsageLimit?) {
        guard let row = weekly(for: bar, rows: rows), let five = row.five else { return (bar.limit, nil) }
        return (five, row.week)
    }

    static func accessibilitySummary(for bar: CollapsedUsageBar, rows: [ServiceRowModel]) -> String {
        if bar.isBlocked { return "\(bar.ringName): \(CollapsedUsageBar.detailText(for: bar))" }
        let arcs = g1(for: bar, rows: rows)
        let windows = [arcs.outer, arcs.inner].compactMap { $0 }
        guard !windows.isEmpty else { return "\(bar.ringName): No data" }
        let values = windows.map { limit in
            let label: String
            switch ServiceRowModel.kind(limit.title) {
            case .five: label = "5h"
            case .week: label = "Weekly"
            case .other: label = ServiceRowModel.shortLabel(limit.title)
            }
            return "\(label): \(limit.leftText), \(limit.resetText)"
        }
        return "\(bar.ringName): " + values.joined(separator: "; ")
    }

    private static func scale(for value: Double) -> CGFloat {
        guard value.isFinite else { return 1 }
        return CGFloat(min(max(value, PanelPreferences.barZoomRange.lowerBound),
                           PanelPreferences.barZoomRange.upperBound))
    }
}

/// Aurora ring: provider-tinted track + rounded arc with a subtle light→base gradient.
/// No glow; <20% shows a small red dot. No images, no blur.
struct UsageRing<Label: View>: View {
    /// Brighter red for digits on dark glass (#FF6B61) so low quota stays legible.
    static var criticalTextDark: Color { Color(red: 1.0, green: 0x6B / 255, blue: 0x61 / 255) }
    let bar: CollapsedUsageBar
    let lineWidth: CGFloat
    @ViewBuilder var label: () -> Label
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fraction = (bar.limit?.clampedLeftPercent ?? 0) / 100
        let dark = colorScheme == .dark
        let base = bar.fillColor
        let isGrok = bar.id == "grok"
        let track = isGrok ? Color.primary.opacity(dark ? 0.16 : 0.12) : bar.providerColor.opacity(dark ? 0.22 : 0.18)
        let gradient = AngularGradient(colors: [base.lighter(dark ? 0.30 : 0.22), base],
                                       center: .center, startAngle: .degrees(0),
                                       endAngle: .degrees(360 * max(0.01, fraction)))
        ZStack {
            if dark { Circle().fill(Color.white.opacity(0.04)).padding(lineWidth / 2) }
            Circle().stroke(track, lineWidth: lineWidth)
            if bar.limit != nil, fraction > 0 {
                Circle()
                    .trim(from: 0, to: max(0.01, fraction))
                    .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // no glow (G1)
            }
            label()
                .foregroundStyle(bar.limit?.tone == .critical ? AnyShapeStyle(dark ? Self.criticalTextDark : bar.fillColor)
                                 : bar.limit == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.primary))
        }
        .shadow(color: dark ? .black.opacity(0.6) : .clear, radius: 1, y: 1)
        .padding(lineWidth / 2)
        .overlay(alignment: .topTrailing) {
            if let limit = bar.limit, limit.clampedLeftPercent < 20 {
                Circle().fill(CollapsedUsageBar.criticalColor)
                    .overlay(Circle().stroke(dark ? Color.black : Color.white, lineWidth: max(0.8, lineWidth * 0.3)))
                    .frame(width: max(4, lineWidth * 1.4), height: max(4, lineWidth * 1.4))
            }
        }
    }
}

extension Color {
    /// macOS 14-safe blend (Color.mix is macOS 15+). Resolves per appearance.
    func lighter(_ amount: CGFloat) -> Color {
        let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var out = base
            appearance.performAsCurrentDrawingAppearance {
                out = base.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: .white) ?? base
            }
            return out
        })
    }
}

/// G1 at tab size: open-bottom gauge, outer thick = 5h (or the only window), inner thin = weekly,
/// weekly % in the gap only when the gauge is big enough to read it. No glow, no haze.
struct TabG1Gauge: View {
    let bar: CollapsedUsageBar
    let outer: UsageLimit?
    let weekly: UsageLimit?
    let diameter: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let blocked = bar.isBlocked
        let outerW = max(1.5, diameter * 0.095)
        let innerW = max(1.4, diameter * 0.08)
        let gap = max(0.7, diameter * 0.045)
        let showInner = weekly != nil && diameter >= 18
        let isGrok = bar.id == "grok"
        let track = blocked ? Color.secondary.opacity(0.45) : isGrok ? Color.primary.opacity(dark ? 0.16 : 0.12) : bar.providerColor.opacity(dark ? 0.24 : 0.20)
        let showGapText = weekly != nil && diameter >= 12
        let primaryText = outer.map { "\($0.percentInt)" } ?? "?"
        let textWidth = max(1, diameter - 2 * (showInner ? outerW + gap + innerW : outerW))
        let preferredFontSize = max(6, diameter * (showInner ? 0.36 : showGapText ? 0.38 : 0.42))
        let measuredWidth = (primaryText as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: preferredFontSize, weight: .bold)
        ]).width
        let fontSize = preferredFontSize * min(1, textWidth / (measuredWidth + 0.5))
        ZStack {
            GaugeArc(fraction: 1).stroke(track, style: .init(lineWidth: outerW, lineCap: .round)).padding(outerW / 2)
            if let limit = outer {
                GaugeArc(fraction: limit.clampedLeftPercent / 100)
                    .stroke(blocked ? Color.secondary.opacity(0.45) : GaugeStyle.tint(bar.providerColor, limit), style: .init(lineWidth: outerW, lineCap: .round)).padding(outerW / 2)
            }
            if showInner, let weekly {
                let inset = outerW + gap + innerW / 2
                GaugeArc(fraction: 1).stroke(blocked ? Color.secondary.opacity(0.2) : Color.primary.opacity(0.10), style: .init(lineWidth: innerW, lineCap: .round))
                    .padding(inset)
                GaugeArc(fraction: weekly.clampedLeftPercent / 100)
                    .stroke(blocked ? Color.secondary.opacity(0.45) : GaugeStyle.tint(bar.providerColor, weekly).opacity(dark ? 0.80 : 0.85),
                            style: .init(lineWidth: innerW, lineCap: .round)).padding(inset)
            }
            if blocked {
                Image(systemName: bar.blockedSymbolName)
                    .font(.system(size: diameter * 0.26, weight: .semibold))
                    .foregroundStyle(.secondary).opacity(0.65)
                    .offset(y: -diameter * 0.2)
            } else {
                Text(primaryText)
                    .font(.system(size: fontSize, weight: .bold))
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .frame(width: textWidth)
                    .foregroundStyle(outer?.tone == .critical ? AnyShapeStyle(dark ? UsageRing<EmptyView>.criticalTextDark : CollapsedUsageBar.criticalColor)
                                     : outer == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.primary))
                    .offset(y: -diameter * (showInner ? 0.06 : showGapText ? 0.14 : 0.02))
            }
            if blocked, let block = bar.block {
                let lines = ClaudeRateLimitParser.recoveryLines(resetAt: block.resetAt)
                VStack(spacing: -diameter * 0.05) {
                    Text(lines.date)
                    Text(lines.time)
                }
                .font(.system(size: max(5, diameter * 0.22), weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(.secondary)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: -diameter * 0.03)
            } else if showGapText, let weekly {
                Text("\(weekly.percentInt)")
                    .font(.system(size: max(5.5, diameter * 0.27), weight: .bold)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(weekly.tone == .critical ? AnyShapeStyle(dark ? UsageRing<EmptyView>.criticalTextDark : CollapsedUsageBar.criticalColor) : AnyShapeStyle(Color.secondary))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: diameter * (showInner ? 0.03 : 0.12))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
