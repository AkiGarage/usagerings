import Foundation

struct CLIProxyCredential: Equatable, Sendable {
    let provider: String
    let authIndex: String
    let maskedEmail: String
    let disabled: Bool
    let projectID: String?
    let accountID: String?
    let userID: String?
}

enum CLIProxyParser {
    private enum ParseError: Error { case invalid }

    enum GrokBillingResult: Equatable, Sendable {
        case quota(UsageLimit)
        case noMonthlyCap
        case noData
    }

    struct CredentialInventory {
        let credentials: [CLIProxyCredential]
        let isComplete: Bool
    }

    static func credentials(_ data: Data) throws -> [CLIProxyCredential] {
        try credentialInventory(data).credentials
    }

    static func credentialInventory(_ data: Data) throws -> CredentialInventory {
        let object = try JSONSerialization.jsonObject(with: data)
        let root = object as? [String: Any]
        guard let entries = (root?["files"] ?? root?["credentials"] ?? object) as? [[String: Any]] else {
            throw ParseError.invalid
        }
        let credentials: [CLIProxyCredential] = entries.compactMap { entry in
            guard let provider = (entry["provider"] ?? entry["type"]) as? String, !provider.isEmpty,
                  provider == provider.trimmingCharacters(in: .whitespacesAndNewlines),
                  let index = (entry["auth_index"] ?? entry["authIndex"]) as? String, !index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let metadata = entry["metadata"] as? [String: Any]
            let attributes = entry["attributes"] as? [String: Any]
            return CLIProxyCredential(
                provider: provider, authIndex: index,
                maskedEmail: mask(entry["email"] as? String), disabled: entry["disabled"] as? Bool ?? false,
                projectID: (entry["project_id"] ?? metadata?["project_id"] ?? attributes?["project_id"]) as? String,
                accountID: (entry["account_id"] ?? entry["chatgpt_account_id"]) as? String,
                userID: (entry["user_id"] ?? entry["userId"] ?? metadata?["user_id"]) as? String
            )
        }
        return CredentialInventory(credentials: credentials, isComplete: credentials.count == entries.count)
    }

    static func mask(_ email: String?) -> String {
        guard let email else { return "Account" }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return "Account" }
        return "\(parts[0].prefix(3))***@\(parts[1].prefix(1))***"
    }

    static func claude(_ data: Data, label: String, now: Date) throws -> [UsageLimit] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalid }
        return [("five_hour", "5h"), ("seven_day", "Weekly"), ("seven_day_opus", "Opus weekly"),
                ("seven_day_sonnet", "Sonnet weekly"), ("seven_day_oauth_apps", "OAuth apps weekly")].compactMap { key, title in
            guard let window = object[key] as? [String: Any], let used = number(window["utilization"]), (0...100).contains(used) else { return nil }
            return UsageLimit(title: "\(label) · \(title)", leftPercent: 100 - used,
                              resetText: reset(window["resets_at"] as? String, now: now))
        }
    }

    static func grok(_ data: Data, label: String, weekly: Bool, now: Date) throws -> GrokBillingResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any] else { throw ParseError.invalid }
        func amount(_ value: Any?) -> Double? {
            let raw = (value as? [String: Any])?["val"] ?? value
            if let text = raw as? String, let number = Double(text), number.isFinite { return number }
            return number(raw)
        }
        let period = (config["currentPeriod"] ?? config["current_period"]) as? [String: Any]
        let end = (period?["end"] as? String)
            ?? (config["billingPeriodEnd"] ?? config["billing_period_end"]) as? String
        let title = "\(label) · \(weekly ? "Weekly" : "Monthly")"
        let percentage = amount(config["creditUsagePercent"] ?? config["credit_usage_percent"])
        let monthlyLimit = amount(config["monthlyLimit"] ?? config["monthly_limit"])

        guard !weekly else {
            guard let usedPercent = percentage, usedPercent.isFinite, usedPercent >= 0 else {
                return .noData
            }
            return .quota(UsageLimit(title: title, leftPercent: max(0, 100 - usedPercent),
                                     resetText: reset(end, now: now)))
        }

        // An explicit zero monthly cap denotes an uncapped account. It wins even
        // when the service also reports a percentage for another billing shape.
        if let monthlyLimit, monthlyLimit.isFinite, monthlyLimit == 0 {
            return .noMonthlyCap
        }

        if let usedPercent = percentage, usedPercent.isFinite, usedPercent >= 0 {
            return .quota(UsageLimit(title: title, leftPercent: max(0, 100 - usedPercent),
                                     resetText: reset(end, now: now)))
        }

        if let spent = amount(config["used"]),
           spent.isFinite, spent >= 0,
           let monthlyLimit, monthlyLimit.isFinite, monthlyLimit > 0 {
            let usedPercent = spent / monthlyLimit * 100
            guard usedPercent.isFinite, usedPercent >= 0 else { return .noData }
            return .quota(UsageLimit(title: title, leftPercent: max(0, 100 - usedPercent),
                                     resetText: reset(end, now: now)))
        }
        return .noData
    }

    static func antigravity(_ data: Data, now: Date) throws -> [UsageLimit] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = object["groups"] as? [[String: Any]] else { throw ParseError.invalid }
        func priority(_ group: [String: Any]) -> Int {
            let name = (group["displayName"] as? String ?? "").lowercased()
            if name.contains("argon") { return 0 }
            if name.contains("flash") { return 1 }
            return 2
        }
        return groups.enumerated().sorted {
            let lhs = priority($0.element), rhs = priority($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.flatMap { _, group -> [UsageLimit] in
            let name = group["displayName"] as? String ?? "Quota"
            return (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket in
                guard let fraction = number(bucket["remainingFraction"]), (0...1).contains(fraction) else { return nil }
                let window = (bucket["displayName"] ?? bucket["window"]) as? String
                return UsageLimit(title: window.map { "\(name) · \($0)" } ?? name, leftPercent: fraction * 100,
                                  resetText: reset(bucket["resetTime"] as? String, now: now))
            }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func reset(_ value: String?, now: Date) -> String {
        guard let value else { return "Reset pending" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value) else { return "Reset pending" }
        return UsageDurationFormat.resetText(for: date, now: now)
    }
}
