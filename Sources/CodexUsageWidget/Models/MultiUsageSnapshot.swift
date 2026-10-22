import Foundation

enum ProviderID: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case grok
    case zai
    case minimax
    case kimi
    case deepseek
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
        case .minimax:
            "MiniMax"
        case .kimi:
            "Kimi"
        case .deepseek:
            "DeepSeek"
        }
    }
}

/// A panel row that cannot carry a percent: credits, reset tickets, and
/// explicitly-noted gaps such as an unreported window.
struct ProviderStat: Equatable, Codable, Sendable {
    let title: String
    let valueText: String
    var accountIndex: Int? = nil
}

/// Keeps accounts with missing quota visible without using masked labels as identity.
struct ProviderAccount: Equatable, Sendable {
    let index: Int
    var failureText: String? = nil
    var codexExtras: CodexExtrasParser.Extras? = nil
    var id: AccountID? = nil
}

struct ClaudeProfileNotice: Equatable, Sendable, Identifiable {
    let profile: Int
    let block: ClaudeBlock?
    let failureText: String?

    var id: String { "claude-profile-\(profile)" }
    var name: String { "Claude logs \(ProviderSection.accountSuffix(profile))" }
}

struct ProviderSection: Equatable, Sendable, Identifiable {
    let provider: ProviderID
    var windows: [UsageLimit]
    var stats: [ProviderStat]
    var failureText: String?
    /// Codex extras for legacy snapshots or a section projected by forAccount.
    /// Account-aware snapshots store extras on each ProviderAccount.
    var codexExtras: CodexExtrasParser.Extras? = nil
    var zaiResetTickets: ZaiResetTickets? = nil
    /// Log profile slots (A/B), with no verified link to a quota account.
    var claudeProfileBlocks: [Int: ClaudeBlock] = [:]
    var accounts: [ProviderAccount] = []
    var claudeRemoteFailureText: String? = nil

    var claudeProfileNotices: [ClaudeProfileNotice] {
        let profiles = Set(claudeProfileBlocks.keys).union(claudeRemoteFailureText == nil ? [] : [1])
        return profiles.sorted().map {
            ClaudeProfileNotice(profile: $0, block: claudeProfileBlocks[$0],
                                failureText: $0 == 1 ? claudeRemoteFailureText : nil)
        }
    }

    var id: String { provider.id }

    var accountIndices: [Int] {
        Set(accounts.map(\.index) + windows.compactMap(\.accountIndex)
            + stats.compactMap(\.accountIndex)).sorted()
    }

    var displayAccounts: [ProviderAccount] {
        let indices = accountIndices.isEmpty ? [0] : accountIndices
        return indices.map { index in
            accounts.first { $0.index == index }
                ?? ProviderAccount(index: index, id: indices.count == 1 && (!windows.isEmpty || !stats.isEmpty)
                    ? .singleton(provider) : nil)
        }
    }

    func accountID(at index: Int) -> AccountID? {
        displayAccounts.first { $0.index == index }?.id
    }

    func forAccount(_ index: Int) -> Self {
        var section = self
        section.windows = windows.filter { ($0.accountIndex ?? 0) == index }
        section.stats = stats.filter { ($0.accountIndex ?? 0) == index }
        let account = accounts.first { $0.index == index }
        section.failureText = account?.failureText
        section.codexExtras = accounts.isEmpty ? (index == 0 ? codexExtras : nil) : account?.codexExtras
        if index != 0 { section.zaiResetTickets = nil }
        section.accounts = account.map { [$0] } ?? []
        section.claudeProfileBlocks = [:]
        section.claudeRemoteFailureText = nil
        return section
    }

    static func accountSuffix(_ index: Int) -> String {
        index < 26 && index >= 0 ? String(UnicodeScalar(65 + index)!) : String(index + 1)
    }

    var lowestLeftWindow: UsageLimit? {
        windows.min { $0.clampedLeftPercent < $1.clampedLeftPercent }
    }
}

struct MultiUsageSnapshot: Equatable, Sendable {
    let sections: [ProviderSection]
    let codexSnapshot: UsageSnapshot?
    let updatedAt: Date

    /// Display order shared by the tablet (left to right) and the window (top to bottom).
    static let displayOrder: [ProviderID] = [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .antigravity]

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
