import Foundation

/// 表示基準: show every bar and number as remaining (残り) or used (使用). Bars always progress left -> right.
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

/// Thin bar that always runs left→right (案A): 使用量 fills the used share from the left;
/// 残り greys the used share on the left and colours the remaining share on the right.
struct BasisBar: View {
    let basis: UsageBasis
    let leftPercent: Double
    let tint: Color
    var track: Color = Color.primary.opacity(0.12)

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let used = min(max(100 - leftPercent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if basis == .used {
                    Capsule().fill(tint).frame(width: max(2, w * used))
                } else {
                    Capsule().fill(Color.secondary.opacity(0.55)).frame(width: w * used)
                    Capsule().fill(tint).frame(width: max(2, w * (1 - used))).offset(x: w * used)
                }
            }.clipShape(Capsule())
        }
    }
}
