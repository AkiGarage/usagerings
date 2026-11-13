import Foundation

/// Shared wording for quota readouts; independent of display basis and wall-clock time.
enum UsageAccessibility {
    struct Reading: Equatable {
        let label: String
        let value: String
        var summary: String { "\(label): \(value)" }
    }

    static func statusText(_ tone: UsageTone) -> String? {
        switch tone {
        case .healthy: return nil
        case .warning: return "残量注意"
        case .critical: return "残量わずか"
        }
    }

    static func statusSymbol(_ tone: UsageTone) -> String? {
        switch tone {
        case .healthy: return nil
        case .warning: return "exclamationmark.circle"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    /// Reuse the quota model's thresholds for views that carry only a percentage.
    static func statusSymbol(leftPercent: Double) -> String? {
        statusSymbol(UsageLimit(title: "", leftPercent: leftPercent, resetText: "").tone)
    }

    static func window(provider: String, title: String, limit: UsageLimit?, blocked: Bool = false) -> Reading {
        let label = "\(provider), \(title)"
        guard let limit else { return Reading(label: label, value: "枠なし") }
        let parts = [blocked ? "使用不可" : "残り \(limit.percentInt)%", statusText(limit.tone).flatMap { blocked ? nil : $0 },
                     "リセット \(limit.shortReset)", limit.detailText, limit.projectionText]
        return Reading(label: label, value: parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "、"))
    }

    static func ring(bar: CollapsedUsageBar, rows: [ServiceRowModel], now: Date) -> Reading {
        let label = bar.ringName
        let stale = bar.isStale ? "\(bar.failureText ?? "Stale"); " : ""
        if let block = bar.block, block.isActive(at: now) {
            return Reading(label: label, value: stale + ClaudeRateLimitParser.cardLine(block: block, now: now))
        }
        let arcs = MultiCollapsedUsageView.g1(for: bar, rows: rows)
        let windows = [arcs.outer, arcs.inner].compactMap { $0 }
        guard !windows.isEmpty else {
            if let failure = bar.failureText { return Reading(label: label, value: failure) }
            let details = RingDetailCardModel.visibleStats(for: bar)
                .map { "\($0.title): \($0.valueText)" }.joined(separator: "; ")
            return Reading(label: label, value: details.isEmpty ? "No data" : details)
        }
        let values = windows.map { limit in
            let window: String
            switch ServiceRowModel.kind(limit.title) {
            case .five: window = "5h"
            case .week: window = "Weekly"
            case .other: window = ServiceRowModel.shortLabel(limit.title)
            }
            return "\(window): \(limit.leftText), \(limit.resetText)"
        }
        return Reading(label: label, value: stale + values.joined(separator: "; "))
    }
}
