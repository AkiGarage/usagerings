import CryptoKit
import Foundation

/// Shared by concurrent provider parsers. The salt never leaves local defaults/hash input.
enum AccountIdentitySalt {
    static let defaultsKey = "multiAccountIdentitySaltV1"
    private static let lock = NSLock()

    static func load(defaults: UserDefaults = .standard) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let salt = defaults.data(forKey: defaultsKey), salt.count == 32 { return salt }
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        defaults.set(salt, forKey: defaultsKey)
        return salt
    }
}

/// Only provider-scoped digests cross the parser/preferences boundary.
struct AccountID: Hashable, Sendable {
    let rawValue: String
    private(set) var aliases: [String] = []
    // Migration probes only: unsalted digests are never persisted as aliases.
    private(set) var legacyAliases: [String: String] = [:]
    var legacyDigests: [String] { legacyAliases.keys.sorted() }

    init(provider: ProviderID, source: String, value: String, salt: Data = AccountIdentitySalt.load()) {
        let legacyInput = "usagerings-account-v1\u{0}\(provider.rawValue)\u{0}\(source)\u{0}\(value)"
        var input = Data("usagerings-account-v2\u{0}".utf8)
        input.append(salt)
        input.append(Data("\u{0}\(provider.rawValue)\u{0}\(source)\u{0}\(value)".utf8))
        rawValue = Self.digest(input)
        legacyAliases = [Self.digest(Data(legacyInput.utf8)): rawValue]
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init?(digest: String) {
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        rawValue = digest
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    static func singleton(_ provider: ProviderID, salt: Data = AccountIdentitySalt.load()) -> Self {
        Self(provider: provider, source: "slot", value: "default", salt: salt)
    }

    private static func candidates(_ sources: [(String, String)], provider: ProviderID, salt: Data) -> Self? {
        let ids = sources.map { Self(provider: provider, source: $0.0, value: $0.1, salt: salt) }
        guard var first = ids.first else { return nil }
        first.aliases = Array(Set(ids.dropFirst().map(\.rawValue))).sorted()
        first.legacyAliases = ids.reduce(into: [:]) { $0.merge($1.legacyAliases) { existing, _ in existing } }
        return first
    }

    static func cliProxy(_ credential: CLIProxyCredential, provider: ProviderID,
                         salt: Data = AccountIdentitySalt.load()) -> Self {
        var sources: [(String, String)] = []
        for (source, value) in [("proxy-account-id", credential.accountID), ("proxy-user-id", credential.userID)] {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                sources.append((source, value))
            }
        }
        // auth_index may be renumbered: use it only when no stable identity exists.
        if sources.isEmpty { sources.append(("proxy-auth-index", credential.authIndex)) }
        return candidates(sources, provider: provider, salt: salt)!
    }

    static func codexBar(_ entry: [String: Any], provider: ProviderID,
                         salt: Data = AccountIdentitySalt.load()) -> Self? {
        let usage = entry["usage"] as? [String: Any] ?? [:]
        let identity = usage["identity"] as? [String: Any] ?? [:]
        let account = entry["account"] as? [String: Any] ?? [:]
        var sources: [(String, String)] = []
        // Deliberate allowlist: never use token/key fields or serialize a payload as identity.
        for object in [identity, usage, account, entry] {
            for key in ["accountID", "accountId", "account_id"] {
                if let value = object[key] as? String, !value.isEmpty { sources.append(("id", value)) }
            }
        }
        for object in [identity, usage, account] {
            for key in ["accountEmail", "email"] {
                if let value = object[key] as? String, !value.isEmpty {
                    sources.append(("email", value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
                }
            }
        }
        if let value = entry["account"] as? String, !value.isEmpty { sources.append(("account", value)) }
        return candidates(sources, provider: provider, salt: salt)
    }
}

/// Persist only user-authored display choices, never a provider response or credential.
struct AccountPreferences: Equatable, Codable {
    struct Override: Equatable, Codable {
        var label: String? = nil
        var hidden = false
    }

    struct Observation: Equatable, Codable {
        var provider: String?
        var lastSeen: Date
        var aliases: [String] = []
    }

    static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60
    private(set) var observations: [String: Observation] = [:]
    // Salted tombstones prevent a formerly ambiguous identity becoming a guessed match
    // when other accounts disappear. These contain no preferences or raw identities.
    private(set) var ambiguousAliases: Set<String> = []

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

    /// A successful provider response is the only authority for expiry. Legacy entries
    /// with no provider association require a complete successful inventory before expiry.
    @discardableResult
    mutating func reconcile(_ snapshot: MultiUsageSnapshot, now: Date = Date(),
                            salt: Data = AccountIdentitySalt.load()) -> AccountPreferences {
        let successful = snapshot.sections.filter {
            $0.accountInventoryComplete ?? ($0.failureText == nil && $0.accounts.allSatisfy { $0.failureText == nil })
        }
        let successfulProviders = Set(successful.map { $0.provider.rawValue })
        let completeInventory = successfulProviders == Set(ProviderID.allCases.map(\.rawValue))
        // Give pre-timestamp entries a full grace period; loading alone never expires them.
        for digest in Set(accounts.keys).union(primaryAccounts.values) where observations[digest] == nil {
            observations[digest] = Observation(
                provider: primaryAccounts.first { $0.value == digest }?.key, lastSeen: now)
        }
        var archived = AccountPreferences()
        // Quota failure does not erase an explicitly reported account identity.
        for section in snapshot.sections {
            let ids = section.displayAccounts.compactMap(\.id)
            let currentKeys = Set(ids.map(\.rawValue))
            let slot = AccountID.singleton(section.provider, salt: salt)
            let slotProbes = Set([slot.rawValue] + slot.legacyDigests)
            // Shared aliases are ambiguous and must never transfer another account's settings.
            var owners: [String: Int] = [:]
            for id in ids {
                for digest in Set([id.rawValue] + id.aliases + id.legacyDigests) {
                    owners[digest, default: 0] += 1
                }
            }
            ambiguousAliases.formUnion(owners.filter { $0.value > 1 }.keys.filter { digest in
                ids.contains { $0.rawValue == digest || $0.aliases.contains(digest) }
            })
            if section.displayAccounts.count > 1 { ambiguousAliases.insert(slot.rawValue) }
            for id in ids {
                var probes = Set([id.rawValue] + id.aliases + id.legacyDigests)
                if section.displayAccounts.count == 1, successfulProviders.contains(section.provider.rawValue) {
                    probes.formUnion(slotProbes)
                }
                var blockedProbes = ambiguousAliases
                for (legacy, salted) in id.legacyAliases.merging(slot.legacyAliases, uniquingKeysWith: { a, _ in a })
                    where ambiguousAliases.contains(salted) {
                    blockedProbes.insert(legacy)
                }
                probes.subtract(blockedProbes)
                probes = probes.filter { (owners[$0] ?? 0) <= 1 }
                let oldKeys = Set(accounts.keys).union(primaryAccounts.values).union(observations.keys)
                    .filter { key in
                        guard key != id.rawValue, !currentKeys.contains(key) else { return false }
                        if let provider = observations[key]?.provider, provider != section.provider.rawValue { return false }
                        return probes.contains(key) || !(Set(observations[key]?.aliases ?? []).intersection(probes).isEmpty)
                    }.sorted { left, right in
                        // A specific source is stronger than the old unnamed slot.
                        if slotProbes.contains(left) != slotProbes.contains(right) { return !slotProbes.contains(left) }
                        return left < right
                    }
                var aliases = Set(id.aliases + [id.rawValue])
                aliases.formUnion(observations[id.rawValue]?.aliases ?? [])
                for key in oldKeys {
                    // Already-saved current choices win over an older-source entry.
                    if accounts[id.rawValue] == nil { accounts[id.rawValue] = accounts[key] }
                    if let old = accounts[key], old != accounts[id.rawValue] {
                        // Preserve conflicting choices, rekeying even legacy digests with the salt.
                        let archiveKey = AccountID(provider: section.provider, source: "migration-conflict",
                                                   value: key, salt: salt).rawValue
                        archived.accounts[archiveKey] = old
                        archived.observations[archiveKey] = Observation(provider: section.provider.rawValue, lastSeen: now)
                        if primaryAccounts[section.provider.rawValue] == key {
                            archived.primaryAccounts[section.provider.rawValue] = archiveKey
                        }
                    }
                    if primaryAccounts[section.provider.rawValue] == key {
                        primaryAccounts[section.provider.rawValue] = id.rawValue
                    }
                    aliases.formUnion(observations[key]?.aliases ?? [])
                    accounts[key] = nil
                    observations[key] = nil
                }
                // A singleton slot is a one-time migration bridge, never a durable alias.
                aliases.subtract(slotProbes)
                aliases.subtract(id.legacyDigests)
                aliases.subtract(ambiguousAliases)
                aliases = aliases.filter { (owners[$0] ?? 0) <= 1 }
                observations[id.rawValue] = Observation(provider: section.provider.rawValue,
                    lastSeen: now, aliases: aliases.sorted())
            }
        }
        let expired = observations.filter { _, observation in
            let canExpire = observation.provider.map { successfulProviders.contains($0) } ?? completeInventory
            return canExpire && now.timeIntervalSince(observation.lastSeen) > Self.retentionInterval
        }.map(\.key)
        for key in expired {
            archived.accounts[key] = accounts.removeValue(forKey: key)
            archived.observations[key] = observations.removeValue(forKey: key)
            for provider in primaryAccounts.keys.filter({ primaryAccounts[$0] == key }) {
                archived.primaryAccounts[provider] = primaryAccounts.removeValue(forKey: provider)
            }
        }
        return archived
    }

    func hasSameDisplayChoices(as other: Self) -> Bool {
        accounts == other.accounts && primaryAccounts == other.primaryAccounts
    }

    /// Match the account selection used by collapsed rings, including hidden/missing fallback.
    func collapsedSection(_ section: ProviderSection) -> ProviderSection? {
        guard let visible = visibleSection(section) else { return nil }
        guard primaryAccounts[section.provider.rawValue] != nil else { return visible }
        guard let index = primaryIndex(in: section) else { return nil }
        return visible.forAccount(index)
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
        ambiguousAliases = try container.decodeIfPresent(Set<String>.self, forKey: .ambiguousAliases) ?? []
        ambiguousAliases = ambiguousAliases.filter { AccountID(digest: $0) != nil }
        observations = try container.decodeIfPresent([String: Observation].self, forKey: .observations) ?? [:]
        observations = observations.filter { AccountID(digest: $0.key) != nil }.mapValues { value in
            var value = value
            if value.provider.flatMap(ProviderID.init(rawValue:)) == nil { value.provider = nil }
            value.aliases = Array(Set(value.aliases.filter { AccountID(digest: $0) != nil })).sorted()
            return value
        }
        primaryAccounts = try container.decodeIfPresent([String: String].self, forKey: .primaryAccounts) ?? [:]
        primaryAccounts = primaryAccounts.filter { ProviderID(rawValue: $0.key) != nil && AccountID(digest: $0.value) != nil }
    }
}
