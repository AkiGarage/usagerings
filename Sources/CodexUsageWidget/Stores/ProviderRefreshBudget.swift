import Foundation

/// Admission policy only: display retention and reset retries stay with the store.
struct ProviderRefreshBudget {
    enum Reason { case automatic, userInitiated, reset }
    private struct Entry {
        var next: Date
        var failures: Int
    }
    private let intervals: [ProviderID: TimeInterval]
    private var entries: [ProviderID: Entry] = [:]

    /// Local preferences are validated once here. Unconfigured providers remain unbudgeted.
    static func intervals(defaults: UserDefaults) -> [ProviderID: TimeInterval] {
        var result: [ProviderID: TimeInterval] = [.antigravity: 15 * 60]
        for provider in ProviderID.allCases {
            let key = "providerRefreshIntervalSeconds.\(provider.rawValue)"
            guard let number = defaults.object(forKey: key) as? NSNumber else { continue }
            let seconds = number.doubleValue
            if seconds.isFinite, seconds >= 60, seconds <= 86_400 { result[provider] = seconds }
        }
        return result
    }

    init(intervals: [ProviderID: TimeInterval]) {
        self.intervals = intervals
    }

    func contains(_ provider: ProviderID) -> Bool { intervals[provider] != nil }

    func deferred(at now: Date, reason: Reason) -> Set<ProviderID> {
        guard reason == .automatic else { return [] }
        return Set(entries.filter { now < $0.value.next }.keys)
    }

    mutating func record(_ section: ProviderSection, at now: Date) {
        guard let interval = intervals[section.provider] else { return }
        let failed = section.failureText != nil || section.failureReason != nil || section.isStale
            || section.accounts.contains { $0.failureText != nil || $0.failureReason != nil || $0.isStale }
        // First failure waits 2 intervals, then 4, then 8. Success clears the backoff.
        let failures = failed ? min((entries[section.provider]?.failures ?? 0) + 1, 3) : 0
        entries[section.provider] = Entry(next: now.addingTimeInterval(interval * pow(2, Double(failures))),
                                          failures: failures)
    }
}
