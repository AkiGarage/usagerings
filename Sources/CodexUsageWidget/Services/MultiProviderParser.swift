import Foundation

/// Parses CodexBarCLI usage JSON for non-codex providers into window rows.
///
/// Account metadata is reduced to a digest; credentials never enter the display model.
enum MultiProviderParser {
    enum ParseError: LocalizedError, Equatable {
        case emptyPayload
        case notAnArray
        case providerError
        case noWindows

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                "CodexBarCLI returned no usage payload"
            case .notAnArray:
                "CodexBarCLI returned an unreadable payload"
            case .providerError:
                "provider reported an error"
            case .noWindows:
                "no usage data"
            }
        }
    }

    private struct RawWindow: Decodable {
        var usedPercent: Double?
        var windowMinutes: Double?
        var resetsAt: Date?
        var resetDescription: String?
    }

    private struct ExtraRateWindow: Decodable {
        var title: String?
        var window: RawWindow?
    }

    private struct Usage: Decodable {
        var primary: RawWindow?
        var secondary: RawWindow?
        var tertiary: RawWindow?
        var extraRateWindows: [ExtraRateWindow]?
        var details: [DetailSection]?
    }

    private struct DetailSection: Decodable {
        struct Row: Decodable {
            var label: String
            var value: String
        }
        var title: String?
        var rows: [Row]
    }

    private struct Entry: Decodable {
        var usage: Usage?
    }

    static func windowTitle(windowMinutes: Double?, fallback: String?) -> String {
        switch windowMinutes {
        case 300:
            "5h"
        case 10_080:
            "Weekly"
        case 43_200:
            "Monthly"
        default:
            if let fallback, !fallback.isEmpty { fallback } else { "Quota" }
        }
    }

    static func parse(
        _ data: Data,
        provider: ProviderID,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> ProviderSection {
        guard !data.isEmpty else { throw ParseError.emptyPayload }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ParseError.notAnArray
        }
        let entries = objects.filter { ($0["provider"] as? String).map { $0 == provider.rawValue } ?? true }
        guard !entries.isEmpty else { throw ParseError.notAnArray }
        var section = ProviderSection(provider: provider, windows: [], stats: [], failureText: nil)
        for (index, entry) in entries.enumerated() {
            let id = AccountID.codexBar(entry, provider: provider)
                ?? (entries.count == 1 ? .singleton(provider) : nil)
            do {
                let payload = try JSONSerialization.data(withJSONObject: [entry])
                let parsed = try parseSingle(payload, provider: provider, now: now, timeZone: timeZone)
                section.windows += parsed.windows.map { window in
                    var window = window
                    if entries.count > 1 { window.accountIndex = index }
                    return window
                }
                section.stats += parsed.stats.map { stat in
                    var stat = stat
                    if entries.count > 1 { stat.accountIndex = index }
                    return stat
                }
                section.accounts.append(ProviderAccount(index: index, id: id))
            } catch {
                if entries.count == 1 { throw error }
                section.accounts.append(ProviderAccount(index: index, failureText: "Usage unavailable", id: id))
                section.failureText = "Some accounts unavailable"
            }
        }
        return section
    }

    private static func parseSingle(
        _ data: Data,
        provider: ProviderID,
        now: Date,
        timeZone: TimeZone
    ) throws -> ProviderSection {
        guard !data.isEmpty else { throw ParseError.emptyPayload }
        guard try !firstEntryReportsError(data) else { throw ParseError.providerError }

        let entry = try decodeEntry(data)
        let usage = entry.usage

        // CodexBar encodes DeepSeek's balance availability as a 0/100 primary
        // window. It is not a quota percentage and must never become a ring.
        if provider == .deepseek {
            var stats: [ProviderStat] = []
            if let balance = usage?.primary?.resetDescription, !balance.isEmpty {
                stats.append(ProviderStat(title: "Balance", valueText: balance))
            }
            let labels: Set<String> = ["Today", "This month", "Last 30 days", "Requests"]
            for detail in usage?.details ?? [] where detail.title == "Usage" {
                for row in detail.rows where labels.contains(row.label) && !row.value.isEmpty {
                    stats.append(ProviderStat(title: row.label, valueText: row.value))
                }
            }
            guard !stats.isEmpty else { throw ParseError.noWindows }
            return ProviderSection(provider: provider, windows: [], stats: stats, failureText: nil)
        }

        var limits: [UsageLimit] = []

        func append(_ raw: RawWindow?, titleOverride: String? = nil) {
            guard let raw, let usedPercent = raw.usedPercent else { return }
            let title: String
            if let titleOverride, !titleOverride.isEmpty {
                title = titleOverride
            } else {
                title = windowTitle(windowMinutes: raw.windowMinutes, fallback: nil)
            }
            limits.append(
                UsageLimit(
                    title: title,
                    leftPercent: min(max(100 - usedPercent, 0), 100),
                    resetText: resetText(for: raw, now: now)
                )
            )
        }

        append(usage?.primary)
        append(usage?.secondary)
        append(usage?.tertiary)
        for extra in usage?.extraRateWindows ?? [] {
            append(extra.window, titleOverride: extra.title)
        }

        guard !limits.isEmpty else { throw ParseError.noWindows }
        return ProviderSection(
            provider: provider,
            windows: limits,
            stats: [],
            failureText: nil
        )
    }

    private static func resetText(for raw: RawWindow, now: Date) -> String {
        if let resetsAt = raw.resetsAt {
            return UsageDurationFormat.resetText(for: resetsAt, now: now)
        }
        if let resetDescription = raw.resetDescription {
            return resetDescription
        }
        return "Reset pending"
    }

    private static func decodeEntry(_ data: Data) throws -> Entry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let first = try? decoder.decode([Entry].self, from: data).first else {
            throw ParseError.notAnArray
        }
        return first
    }

    private static func firstEntryReportsError(_ data: Data) throws -> Bool {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let objects = decoded as? [[String: Any]],
              let first = objects.first
        else {
            return false
        }
        guard let error = first["error"] else { return false }
        return !(error is NSNull)
    }
}
