import Foundation

/// 表示基準: show every bar and number as remaining (残り) or used (使用). 案B: 残り shrinks right→left, 使用 grows left→right.
enum UsageBasis: String, CaseIterable {
    case left, used
    static let key = "usageDisplayBasis"
    static let defaultValue = UsageBasis.left
    var title: String { self == .left ? "残り" : "使用量" }
    /// "残り 72%" / "使用 28%" for a window whose remaining share is `leftPercent`.
    func valueText(leftPercent: Double) -> String {
        self == .left ? "残り \(Int(leftPercent.rounded()))%" : "使用 \(Int((100 - leftPercent).rounded()))%"
    }
    func shownPercent(leftPercent: Double) -> Double { self == .left ? leftPercent : 100 - leftPercent }
}

/// 表示形式: simple rows only, or detail bars only (5時間枠 and 週の枠 together, never both).
enum UsageStyle: String, CaseIterable {
    case simple, detail
    static let key = "usageDisplayStyle"
    static let defaultValue = UsageStyle.detail
    var title: String { self == .simple ? "シンプル" : "詳細" }
}

import SwiftUI

extension UsageBasis {
    /// One-line legend under the first detail bar.
    var directionText: String {
        self == .left ? "← 残りは右から減る／今日の枠も右→左へ" : "使用は左から増える →／今日の枠も左→右"
    }
    /// Bar position (0...100 from the left) of a point that is `usedShare` % into the window.
    /// 残り mirrors the axis so markers line up with the remaining fill's right edge.
    func position(usedShare: Double) -> Double { self == .left ? 100 - usedShare : usedShare }
    func fillPercent(leftPercent: Double) -> Double { min(max(shownPercent(leftPercent: leftPercent), 0), 100) }
}

/// Shared type and spacing so the hover card, panel and every provider row line up.
enum UsageLayout {
    static let labelFont = Font.system(size: 12)
    static let valueFont = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let captionFont = Font.system(size: 11).monospacedDigit()
    static let legendFont = Font.system(size: 10)
    static let detailBarHeight: CGFloat = 8
    static let simpleBarHeight: CGFloat = 5
    static let simpleBarWidth: CGFloat = 96
    static let rowSpacing: CGFloat = 4
    static let sectionSpacing: CGFloat = 12
    static let usedColor = CollapsedUsageBar.warningColor
}

/// Label on the left, value on the right; the bar goes directly underneath.
struct LimitHeader: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(UsageLayout.labelFont).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value).font(UsageLayout.valueFont).foregroundStyle(valueColor).lineLimit(1).fixedSize()
        }
    }
}

/// 案B bar: 残り fills `tint` from the left (shrinks toward the left as it is used);
/// 使用量 fills orange from the left (grows to the right).
struct BasisBar: View {
    static let blockedColor = Color.secondary.opacity(0.45)
    let basis: UsageBasis
    let leftPercent: Double
    let tint: Color
    var track: Color = Color.primary.opacity(0.12)
    /// Rate-limited: one plain full-width grey bar, nothing else.
    var blocked = false

    /// Fill width in points: 0 (no stub) when the share is 0, else at least 2pt so a tiny share stays visible.
    static func fillWidth(width: Double, share: Double) -> Double {
        (share.isFinite && share > 0) ? max(2, width * min(share, 1)) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let share = basis.fillPercent(leftPercent: leftPercent) / 100
            ZStack(alignment: .leading) {
                if blocked {
                    Capsule().fill(BasisBar.blockedColor)
                } else {
                    Capsule().fill(track)
                    if share > 0 {
                        Capsule().fill(basis == .used ? UsageLayout.usedColor : tint).frame(width: Self.fillWidth(width: w, share: share))
                    }
                }
            }.clipShape(Capsule())
        }
    }
}

/// Full-width detail row for windows without a pace (e.g. GLM MCP): same header, bar height and width as pace bars.
struct DetailLimitRow: View {
    let label: String
    let leftPercent: Double
    let tint: Color
    var caption: String? = nil
    var blocked = false
    @AppStorage(UsageBasis.key, store: .standard) private var basisRaw = UsageBasis.defaultValue.rawValue
    private var basis: UsageBasis { UsageBasis(rawValue: basisRaw) ?? .defaultValue }
    var body: some View {
        VStack(alignment: .leading, spacing: UsageLayout.rowSpacing) {
            HStack(spacing: 4) {
                if !blocked, let symbol = UsageAccessibility.statusSymbol(leftPercent: leftPercent) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                LimitHeader(label: label, value: basis.valueText(leftPercent: leftPercent))
            }
            BasisBar(basis: basis, leftPercent: leftPercent, tint: tint, blocked: blocked).frame(height: UsageLayout.detailBarHeight)
            if let caption {
                Text(caption).font(UsageLayout.captionFont).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(basis.valueText(leftPercent: leftPercent))")
    }
}

/// Visible switches: 表示 シンプル/詳細 and 基準 残り/使用量 (both persisted; 5h and weekly switch together).
struct UsageModeControls: View {
    /// Captions drawn beside the toggles; 基準 was dropped (Aki t1662u).
    static let captions = ["表示"]
    @AppStorage(UsageBasis.key, store: .standard) private var basisRaw = UsageBasis.defaultValue.rawValue
    @AppStorage(UsageStyle.key, store: .standard) private var styleRaw = UsageStyle.defaultValue.rawValue
    var body: some View {
        HStack(spacing: 10) {
            labeled(Self.captions[0], Picker("表示", selection: $styleRaw) {
                ForEach(UsageStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            })
            // No 基準 caption here: it wrapped vertically; a plain gap reads better (Aki t1662u).
            Picker("基準", selection: $basisRaw) {
                ForEach(UsageBasis.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .controlSize(.small)
    }
    private func labeled(_ title: String, _ picker: some View) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            picker.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

/// Current mode shown on the hover card (the card itself cannot be clicked).
struct UsageModeChip: View {
    @AppStorage(UsageBasis.key, store: .standard) private var basisRaw = UsageBasis.defaultValue.rawValue
    @AppStorage(UsageStyle.key, store: .standard) private var styleRaw = UsageStyle.defaultValue.rawValue
    var body: some View {
        let style = UsageStyle(rawValue: styleRaw) ?? .defaultValue
        let basis = UsageBasis(rawValue: basisRaw) ?? .defaultValue
        Text("\(style.title)・\(basis.title)")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// Direction legend next to the switches.
struct UsageDirectionHint: View {
    @AppStorage(UsageBasis.key, store: .standard) private var basisRaw = UsageBasis.defaultValue.rawValue
    var body: some View {
        Text((UsageBasis(rawValue: basisRaw) ?? .defaultValue).directionText)
            .font(UsageLayout.legendFont).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
    }
}
