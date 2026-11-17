import Foundation

struct AntigravityRefreshPolicy {
    enum Trigger {
        case periodic
        case manual
        case reset
    }

    static let minimumInterval: TimeInterval = 10 * 60
    static let hardFloor: TimeInterval = 60
    static let maximumInterval: TimeInterval = 60 * 60
    static let displayMaxAge: TimeInterval = 5 * 60 * 60

    private(set) var lastAttempt: Date?
    private(set) var lastSuccess: Date?
    private(set) var consecutiveFailures = 0

    var interval: TimeInterval {
        min(Self.maximumInterval, Self.minimumInterval * pow(2, Double(min(max(consecutiveFailures - 1, 0), 3))))
    }

    func nextFetchDate(trigger: Trigger) -> Date? {
        lastAttempt?.addingTimeInterval(trigger == .periodic ? interval : Self.hardFloor)
    }

    func shouldFetch(now: Date, trigger: Trigger) -> Bool {
        nextFetchDate(trigger: trigger).map { now >= $0 } ?? true
    }

    mutating func recordAttempt(at now: Date) {
        lastAttempt = now
    }

    mutating func recordResult(success: Bool, at now: Date) {
        if success {
            lastSuccess = now
            consecutiveFailures = 0
        } else {
            consecutiveFailures = min(consecutiveFailures + 1, 4)
        }
    }
}
