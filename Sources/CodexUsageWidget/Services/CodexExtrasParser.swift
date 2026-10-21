import Foundation

/// Best-effort decode of the codex credits balance and reset tickets.
///
/// Never throws: any absence or decode gap yields whatever it could read.
/// Only these fields are declared, so account, identity, and ticket
/// marketing strings are never materialized.
enum CodexExtrasParser {
    struct Extras: Equatable, Sendable {
        var creditsText: String?
        var availableCount: Int?
        var ticketExpiries: [Date]
        /// Every ticket (any status), for the detailed Codex card.
        var tickets: [Ticket] = []
        var ticketsUpdatedAt: Date?
        /// Masked like the other providers' account labels; never the raw address.
        var maskedAccount: String?

        static let none = Extras(creditsText: nil, availableCount: nil, ticketExpiries: [])
    }

    struct Ticket: Equatable, Sendable {
        var title: String?
        var status: String?
        var resetType: String?
        var grantedAt: Date?
        var expiresAt: Date?
    }

    private struct Credits: Decodable {
        var remaining: Double?
        var balanceReadSucceeded: Bool?
    }

    private struct ResetTicket: Decodable {
        var status: String?
        var expiresAt: Date?
        var grantedAt: Date?
        var title: String?
        var resetType: String?

        enum CodingKeys: String, CodingKey {
            case status, title
            case expiresAt = "expires_at"
            case grantedAt = "granted_at"
            case resetType = "reset_type"
        }
    }

    private struct ResetCredits: Decodable {
        var availableCount: Int?
        var credits: [ResetTicket]?
        var updatedAt: Date?
    }

    private struct Usage: Decodable {
        var codexResetCredits: ResetCredits?
        var accountEmail: String?
    }

    private struct Entry: Decodable {
        var credits: Credits?
        var usage: Usage?
    }

    static func parse(_ data: Data) -> Extras {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode([Entry].self, from: data).first else {
            return .none
        }

        var extras = Extras.none
        if let credits = entry.credits,
           credits.balanceReadSucceeded != false,
           let remaining = credits.remaining {
            extras.creditsText = formatCredits(remaining)
        }
        if let reset = entry.usage?.codexResetCredits {
            extras.availableCount = reset.availableCount
            extras.ticketExpiries = (reset.credits ?? [])
                .filter { $0.status == "available" }
                .compactMap(\.expiresAt)
                .sorted()
            extras.tickets = (reset.credits ?? []).map {
                Ticket(title: $0.title, status: $0.status, resetType: $0.resetType,
                       grantedAt: $0.grantedAt, expiresAt: $0.expiresAt)
            }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            extras.ticketsUpdatedAt = reset.updatedAt
        }
        if let email = entry.usage?.accountEmail, !email.isEmpty {
            extras.maskedAccount = CLIProxyParser.mask(email)
        }
        return extras
    }

    private static func formatCredits(_ remaining: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        let value = Int(remaining.rounded(.towardZero))
        let formatted = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(formatted) credits"
    }
}
