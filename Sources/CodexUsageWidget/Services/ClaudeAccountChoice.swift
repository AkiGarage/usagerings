import Foundation

/// Builds policy inputs from a Claude section and publishes the decision for claude-ab.
enum ClaudeAccountChoice {
    static let profileKeys = ["a", "b"]

    /// Masked e-mail of each local Claude profile (~/.claude-a, ~/.claude-b). Reads only oauthAccount.emailAddress.
    static func localProfileMasks(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: String] {
        var result: [String: String] = [:]
        for key in profileKeys {
            let url = home.appendingPathComponent(".claude-\(key)/.claude.json")
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = (root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String else { continue }
            result[key] = CLIProxyParser.mask(email)
        }
        return result
    }

    /// Account label (masked e-mail) reported in a window title "label · 5h".
    static func label(of window: UsageLimit) -> String? {
        let parts = window.title.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropLast().joined(separator: " · ") : nil
    }

    /// Map account index → profile key. Only unique, unambiguous mask matches are used.
    static func profileMap(section: ProviderSection, masks: [String: String]) -> [Int: String] {
        var labels: [Int: String] = [:]
        for window in section.windows { if let i = window.accountIndex, let l = label(of: window) { labels[i] = l } }
        var map: [Int: String] = [:]
        for (key, mask) in masks {
            let hits = labels.filter { $0.value == mask }.map(\.key)
            guard hits.count == 1, masks.values.filter({ $0 == mask }).count == 1 else { continue }
            map[hits[0]] = key
        }
        return map
    }

    /// Policy inputs. Keys are profile keys when mapped ("a"/"b"), otherwise display suffixes ("A"/"B").
    static func accounts(section: ProviderSection, map: [Int: String], now: Date) -> [ClaudeAccountPolicy.Account] {
        let indices = section.accountIndices
        let complete = indices.count >= 2 && indices.allSatisfy { map[$0] != nil }
        let ordered = complete ? indices.sorted { map[$0]! < map[$1]! } : indices
        return ordered.map { index in
            let key = complete ? map[index]! : ProviderSection.accountSuffix(index)
            var a = ClaudeAccountPolicy.Account(key: key)
            for w in section.windows where (w.accountIndex ?? 0) == index {
                let last = w.title.components(separatedBy: " · ").last ?? w.title
                if last == "5h" { a.fiveLeft = w.leftPercent; a.fiveResetAt = w.resetAt }
                if last == "Weekly" { a.weeklyLeft = w.leftPercent; a.weeklyResetAt = w.resetAt }
            }
            if complete, let slot = profileKeys.firstIndex(of: key), let block = section.claudeProfileBlocks[slot], block.isActive(at: now) {
                switch block.kind {
                case .session: a.sessionBlockUntil = block.resetAt
                case .weekly: a.weeklyBlockUntil = block.resetAt
                }
            }
            return a
        }
    }

    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/state/usagerings/claude-account-choice.json")
    }

    static let validity: TimeInterval = 600

    static func payload(_ d: ClaudeAccountPolicy.Decision, now: Date) -> Data? {
        guard let selected = d.selected, profileKeys.contains(selected),
              d.order.allSatisfy(profileKeys.contains) else { return nil }
        let object: [String: Any] = ["order": d.order, "selected": selected, "state": d.state.rawValue,
                                     "reason": d.reason, "decidedAt": Int(now.timeIntervalSince1970),
                                     "expiresAt": Int(now.timeIntervalSince1970 + validity)]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Atomic, owner-only write. Returns false when there is nothing valid to publish.
    @discardableResult
    static func publish(_ d: ClaudeAccountPolicy.Decision, now: Date, url: URL = fileURL()) -> Bool {
        guard let data = payload(d, now: now) else { return false }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
