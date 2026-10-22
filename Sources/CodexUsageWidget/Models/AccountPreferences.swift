import CryptoKit
import Foundation

/// Only a provider-scoped digest crosses the parser/preferences boundary.
struct AccountID: Hashable, Sendable {
    let rawValue: String

    init(provider: ProviderID, source: String, value: String) {
        let input = "usagerings-account-v1\u{0}\(provider.rawValue)\u{0}\(source)\u{0}\(value)"
        rawValue = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init?(digest: String) {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        rawValue = digest
    }

    /// A provider with one unnamed configured account has a stable source slot.
    static func singleton(_ provider: ProviderID) -> Self {
        Self(provider: provider, source: "slot", value: "default")
    }

    static func cliProxy(_ credential: CLIProxyCredential, provider: ProviderID) -> Self {
        for (source, value) in [("proxy-account-id", credential.accountID), ("proxy-user-id", credential.userID)] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return Self(provider: provider, source: source, value: value)
            }
        }
        return Self(provider: provider, source: "proxy-auth-index", value: credential.authIndex)
    }

    static func codexBar(_ entry: [String: Any], provider: ProviderID) -> Self? {
        let usage = entry["usage"] as? [String: Any] ?? [:]
        let identity = usage["identity"] as? [String: Any] ?? [:]
        let account = entry["account"] as? [String: Any] ?? [:]
        // Deliberate allowlist: never use token/key fields or serialize a payload as identity.
        for object in [identity, usage, account, entry] {
            for key in ["accountID", "accountId", "account_id"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return Self(provider: provider, source: "id", value: value)
                }
            }
        }
        for object in [identity, usage, account] {
            for key in ["accountEmail", "email"] {
                if let value = object[key] as? String, !value.isEmpty {
                    return Self(provider: provider, source: "email", value: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
            }
        }
        if let value = entry["account"] as? String, !value.isEmpty {
            return Self(provider: provider, source: "account", value: value)
        }
        return nil
    }
}

/// Persist only user-authored display choices, never a provider response or credential.
struct AccountPreferences: Equatable, Codable {
    struct Override: Equatable, Codable {
        var label: String? = nil
        var hidden = false
    }

    private(set) var accounts: [String: Override] = [:]
    private(set) var primaryAccounts: [String: String] = [:]

    func label(for id: AccountID?) -> String? {
        id.flatMap { accounts[$0.rawValue]?.label }
    }

    func isVisible(_ id: AccountID?) -> Bool {
        id.flatMap { accounts[$0.rawValue]?.hidden } != true
    }

    mutating func setLabel(_ label: String, for id: AccountID) {
        accounts[id.rawValue, default: Override()].label = Self.normalizedLabel(label)
        prune(id)
    }

    private static func normalizedLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    mutating func setVisible(_ visible: Bool, for id: AccountID) {
        accounts[id.rawValue, default: Override()].hidden = !visible
        prune(id)
    }

    mutating func setPrimary(_ id: AccountID?, for provider: ProviderID) {
        primaryAccounts[provider.rawValue] = id?.rawValue
    }

    /// Keep a temporarily missing/hidden primary selected in storage, but show a visible fallback.
    func primaryIndex(in section: ProviderSection) -> Int? {
        let visible = section.displayAccounts.filter { isVisible($0.id) }
        if let selected = primaryAccounts[section.provider.rawValue],
           let account = visible.first(where: { $0.id?.rawValue == selected }) { return account.index }
        return visible.first?.index
    }

    func visibleSection(_ section: ProviderSection) -> ProviderSection? {
        let visible = section.displayAccounts.filter { isVisible($0.id) }
        guard !visible.isEmpty else { return nil }
        let indices = Set(visible.map(\.index))
        var result = section
        result.windows = section.windows.filter { indices.contains($0.accountIndex ?? 0) }
        result.stats = section.stats.filter { indices.contains($0.accountIndex ?? 0) }
        result.accounts = visible
        if section.accounts.isEmpty, let index = result.accounts.firstIndex(where: { $0.index == 0 }) {
            result.accounts[index].codexExtras = section.codexExtras
        }
        result.codexExtras = nil
        if visible.count != section.displayAccounts.count, !section.accounts.isEmpty {
            result.failureText = visible.compactMap(\.failureText).first
        }
        if !indices.contains(0) { result.zaiResetTickets = nil }
        return result
    }

    private mutating func prune(_ id: AccountID) {
        if accounts[id.rawValue] == Override() { accounts[id.rawValue] = nil }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([String: Override].self, forKey: .accounts) ?? [:]
        accounts = accounts.filter { AccountID(digest: $0.key) != nil }.mapValues { value in
            var value = value
            value.label = value.label.flatMap(Self.normalizedLabel)
            return value
        }
        primaryAccounts = try container.decodeIfPresent([String: String].self, forKey: .primaryAccounts) ?? [:]
        primaryAccounts = primaryAccounts.filter { ProviderID(rawValue: $0.key) != nil && AccountID(digest: $0.value) != nil }
    }
}
