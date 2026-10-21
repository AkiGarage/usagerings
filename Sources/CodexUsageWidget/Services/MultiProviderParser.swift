import Foundation

/// Parses CodexBarCLI usage JSON for non-codex providers into window rows.
///
/// The decoder declares only structural fields, so account and identity
/// strings in the payload are never materialized.
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
        guard try !firstEntryReportsError(data) else { throw ParseError.providerError }

        let entry = try decodeEntry(data)
        let usage = entry.usage

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
