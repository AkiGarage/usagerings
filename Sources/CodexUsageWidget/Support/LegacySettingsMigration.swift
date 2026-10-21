import Foundation

/// One-time copy of saved settings from the pre-release bundle id
/// (`local.codex.CodexUsageWidgetMulti`) into the UsageRings domain.
///
/// - Runs only when the current bundle id is the UsageRings id.
/// - Never overwrites a key that already exists in the new domain.
/// - Never deletes or edits the legacy domain (the old app keeps working).
/// - Marks itself done so it runs at most once.
enum LegacySettingsMigration {
    static let doneKey = "usageRings.legacySettingsMigrated"
    static let legacyDomains = [AppVariant.multiBundleIdentifier]

    /// - Returns: the keys copied (empty if nothing to do).
    @discardableResult
    static func runIfNeeded(
        bundleIdentifier: String?,
        defaults: UserDefaults = .standard,
        legacyDomain: (String) -> [String: Any]? = { UserDefaults.standard.persistentDomain(forName: $0) }
    ) -> [String] {
        guard bundleIdentifier == AppVariant.usageRingsBundleIdentifier,
              !defaults.bool(forKey: doneKey) else { return [] }

        var copied: [String] = []
        for domain in legacyDomains {
            guard let values = legacyDomain(domain) else { continue }
            for (key, value) in values.sorted(by: { $0.key < $1.key })
            where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("SU") {
                defaults.set(value, forKey: key)
                copied.append(key)
            }
        }
        defaults.set(true, forKey: doneKey)
        return copied
    }
}
