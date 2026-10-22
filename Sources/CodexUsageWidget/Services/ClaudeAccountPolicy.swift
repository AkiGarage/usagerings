import Foundation

/// Pure switching policy for two (or more) Claude accounts. See docs/claude-account-switching.md.
enum ClaudeAccountPolicy {
    static let recoveryBandPercent = 5.0
    static let tieWindow: TimeInterval = 30 * 60

    struct Account: Equatable, Sendable {
        /// Stable key, e.g. "a" / "b".
        let key: String
        var fiveLeft: Double? = nil
        var fiveResetAt: Date? = nil
        var weeklyLeft: Double? = nil
        var weeklyResetAt: Date? = nil
        /// Active log blocks (reset times), already filtered to the future.
        var sessionBlockUntil: Date? = nil
        var weeklyBlockUntil: Date? = nil

        var hasData: Bool { fiveLeft != nil || weeklyLeft != nil || sessionBlockUntil != nil || weeklyBlockUntil != nil }
    }

    enum State: String, Equatable, Sendable { case preferred, fallback, allLimited, noData }

    struct Decision: Equatable, Sendable {
        let selected: String?
        let preferred: String?
        let state: State
        let reason: String
        /// Keys that were 5h-limited at this decision (hysteresis memory).
        let fiveLimited: Set<String>
        /// Try order for claude-ab: selected first, then the rest.
        let order: [String]
    }

    static func isWeeklyLimited(_ a: Account, now: Date) -> Bool {
        if let until = a.weeklyBlockUntil, until > now { return true }
        if let left = a.weeklyLeft, left <= 0 { return !(a.weeklyResetAt.map { $0 <= now } ?? false) }
        return false
    }

    static func isFiveLimited(_ a: Account, now: Date) -> Bool {
        if let until = a.sessionBlockUntil, until > now { return true }
        if let left = a.fiveLeft, left <= 0 { return !(a.fiveResetAt.map { $0 <= now } ?? false) }
        return false
    }

    static func isLimited(_ a: Account, now: Date) -> Bool { isWeeklyLimited(a, now: now) || isFiveLimited(a, now: now) }

    /// Inside the hysteresis band right after a 5h limit (not limited, but not yet trusted).
    static func isRecovering(_ a: Account, previous: Decision?, now: Date) -> Bool {
        guard previous?.fiveLimited.contains(a.key) == true, !isLimited(a, now: now) else { return false }
        if let reset = a.fiveResetAt, reset <= now, a.fiveLeft.map({ $0 >= 99 }) ?? true { return false }
        guard let left = a.fiveLeft else { return false }
        return left < recoveryBandPercent
    }

    static func preferredKey(_ accounts: [Account], previous: Decision?, now: Date) -> String? {
        let eligible = accounts.filter { !isWeeklyLimited($0, now: now) }
        guard !eligible.isEmpty else { return nil }
        let prev = previous?.preferred.flatMap { key in eligible.first { $0.key == key } }
        // Earliest known weekly reset that is still in the future.
        let known = eligible.compactMap { a in a.weeklyResetAt.flatMap { $0 > now ? (a, $0) : nil } }
        guard let best = known.min(by: { $0.1 < $1.1 }) else { return prev?.key ?? eligible[0].key }
        guard let prev else {
            // Tie without history: account order.
            let tied = known.filter { $0.1.timeIntervalSince(best.1) <= tieWindow }.map(\.0.key)
            return eligible.first { tied.contains($0.key) }?.key ?? best.0.key
        }
        guard let prevReset = prev.weeklyResetAt, prevReset > now else { return best.0.key }
        return prevReset.timeIntervalSince(best.1) > tieWindow ? best.0.key : prev.key
    }

    static func decide(_ accounts: [Account], previous: Decision?, now: Date,
                       name: (String) -> String = { $0.uppercased() },
                       time: (Date) -> String = Self.defaultTime) -> Decision {
        let limitedNow = Set(accounts.filter { isFiveLimited($0, now: now) }.map(\.key))
        guard accounts.contains(where: \.hasData) else {
            return Decision(selected: nil, preferred: nil, state: .noData,
                            reason: "使用量がまだ取れていないため、切り替えの判断を保留しています",
                            fiveLimited: [], order: [])
        }
        let pref = preferredKey(accounts, previous: previous, now: now)
        let free = accounts.filter { $0.hasData && !isLimited($0, now: now) && !isRecovering($0, previous: previous, now: now) }
        let soft = accounts.filter { !isLimited($0, now: now) }
        let fiveMemory = limitedNow.union(accounts.filter { isRecovering($0, previous: previous, now: now) }.map(\.key))
        func order(_ first: String) -> [String] { [first] + accounts.map(\.key).filter { $0 != first } }
        func weeklyNote(_ key: String) -> String {
            guard let r = accounts.first(where: { $0.key == key })?.weeklyResetAt, r > now else { return "" }
            return "（\(time(r))）"
        }

        if let pref, free.contains(where: { $0.key == pref }) {
            let others = accounts.filter { $0.key != pref }
            let reason: String
            if others.isEmpty { reason = "使えるアカウントが\(name(pref))だけのため" }
            else if others.allSatisfy({ isWeeklyLimited($0, now: now) }) {
                reason = "\(others.map { name($0.key) }.joined(separator: "・"))は週の上限に達しているため"
            } else { reason = "週の制限が先にリセットされるため\(weeklyNote(pref))" }
            return Decision(selected: pref, preferred: pref, state: .preferred, reason: reason,
                            fiveLimited: fiveMemory, order: order(pref))
        }
        let pick = free.first ?? soft.first(where: { $0.key == pref }) ?? soft.first
        if let pick {
            let why: String
            if let pref, let p = accounts.first(where: { $0.key == pref }) {
                if isFiveLimited(p, now: now) {
                    let until = [p.sessionBlockUntil, p.fiveResetAt].compactMap { $0 }.filter { $0 > now }.max()
                    why = "\(name(pref))が5時間制限中のため" + (until.map { "（\(time($0))に解除→\(name(pref))に戻します）" } ?? "")
                } else if isRecovering(p, previous: previous, now: now) {
                    why = "\(name(pref))は5時間制限が解けたばかりで残りが少ないため"
                } else { why = "\(name(pref))の使用量が不明なため" }
            } else {
                why = "どのアカウントも週の上限に近いため、使える方を使います"
            }
            return Decision(selected: pick.key, preferred: pref, state: pick.key == pref ? .preferred : .fallback,
                            reason: why, fiveLimited: fiveMemory, order: order(pick.key))
        }
        // Everything limited: wait for the soonest clear.
        func clearsAt(_ a: Account) -> Date {
            var dates: [Date] = []
            if isFiveLimited(a, now: now) { dates += [a.sessionBlockUntil, a.fiveResetAt].compactMap { $0 }.filter { $0 > now } }
            if isWeeklyLimited(a, now: now) { dates += [a.weeklyBlockUntil, a.weeklyResetAt].compactMap { $0 }.filter { $0 > now } }
            return dates.max() ?? .distantFuture
        }
        let soonest = accounts.min { clearsAt($0) < clearsAt($1) }!
        let at = clearsAt(soonest)
        let reason = "すべて制限中です。先に解除される\(name(soonest.key))を待ちます" + (at == .distantFuture ? "（解除時刻は不明）" : "（\(time(at))）")
        return Decision(selected: soonest.key, preferred: pref, state: .allLimited, reason: reason,
                        fiveLimited: fiveMemory, order: order(soonest.key))
    }

    static func defaultTime(_ date: Date) -> String {
        var style = Date.VerbatimFormatStyle(
            format: "\(month: .defaultDigits)/\(day: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian))
        style.locale = Locale(identifier: "en_US_POSIX")
        return style.format(date)
    }
}
