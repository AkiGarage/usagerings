import Foundation

enum ProviderID: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case grok
    case zai
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .zai:
            "GLM Coding Plan"
        case .grok:
            "Grok"
        case .claude:
            "Claude Code"
        case .antigravity:
            "Antigravity"
        }
    }
}

/// A panel row that cannot carry a percent: credits, reset tickets, and
/// explicitly-noted gaps such as an unreported window.
struct ProviderStat: Equatable, Codable, Sendable {
    let title: String
    let valueText: String
}

struct ProviderSection: Equatable, Sendable, Identifiable {
    let provider: ProviderID
    var windows: [UsageLimit]
    var stats: [ProviderStat]
    var failureText: String?
    /// Parsed Codex credits and reset tickets for the ring hover card.
    /// Other providers and Codex responses without extras leave this nil.
    var codexExtras: CodexExtrasParser.Extras? = nil
    var zaiResetTickets: ZaiResetTickets? = nil
    var claudeBlocks: [Int: ClaudeBlock] = [:]

    var id: String { provider.id }

    var lowestLeftWindow: UsageLimit? {
        windows.min { $0.clampedLeftPercent < $1.clampedLeftPercent }
    }
}

struct MultiUsageSnapshot: Equatable, Sendable {
    let sections: [ProviderSection]
    let codexSnapshot: UsageSnapshot?
    let updatedAt: Date

    /// Display order shared by the tablet (left to right) and the window (top to bottom).
    static let displayOrder: [ProviderID] = [.codex, .claude, .grok, .zai, .antigravity]

    static func ordered(_ sections: [ProviderSection]) -> [ProviderSection] {
        sections.enumerated().sorted { lhs, rhs in
            let l = displayOrder.firstIndex(of: lhs.element.provider) ?? displayOrder.count
            let r = displayOrder.firstIndex(of: rhs.element.provider) ?? displayOrder.count
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    var globalLowestWindow: UsageLimit? {
        sections.compactMap(\.lowestLeftWindow).min {
            $0.clampedLeftPercent < $1.clampedLeftPercent
        }
    }

    static let placeholder = MultiUsageSnapshot(
        sections: ProviderID.allCases.map { provider in
            ProviderSection(
                provider: provider,
                windows: [],
                stats: [],
                failureText: "Refreshing"
            )
        },
        codexSnapshot: nil,
        updatedAt: Date()
    )
}
