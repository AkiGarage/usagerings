import Foundation

/// The opt-in boundary for remote Claude B quota monitoring.
struct ClaudeSSHSettings: Equatable, Sendable {
    static let enabledKey = "claudeRateLimitSSHEnabled"
    static let hostKey = "claudeRateLimitSSHHost"

    let host: String

    init?(enabled: Bool, host: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowed = alphanumeric.union(CharacterSet(charactersIn: "._-"))
        guard enabled, host.utf8.count <= 255, (1...2).contains(parts.count),
              parts.allSatisfy({ part in
                  guard let first = part.unicodeScalars.first, alphanumeric.contains(first) else { return false }
                  return part.unicodeScalars.allSatisfy(allowed.contains)
              }) else { return nil }
        self.host = host
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        Self(enabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
             host: defaults.string(forKey: hostKey) ?? "")
    }

    var arguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "StrictHostKeyChecking=yes", "--", host, ClaudeRateLimitSSH.command]
    }
}
