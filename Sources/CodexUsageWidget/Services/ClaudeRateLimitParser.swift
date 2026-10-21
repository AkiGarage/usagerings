import Foundation

struct ClaudeBlock: Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable { case session, weekly }
    let kind: Kind
    let resetAt: Date
    let timeZoneKnown: Bool

    func isActive(at date: Date) -> Bool { resetAt > date }
}

enum ClaudeRateLimitParser {
    enum LineKind: Equatable, Sendable {
        case rateLimit(text: String, timestamp: Date)
        case normalAssistant(timestamp: Date)
        case other
    }

    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let pattern = #"^You(?:'|’)ve hit your (session|weekly) limit\s*·\s*resets\s+(?:([A-Z][a-z]{2})\s+(\d{1,2})(?:,|\s+at)?\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?\s*$"#

    static func parse(text: String, eventTimestamp: Date) -> ClaudeBlock? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let kind = group(1).flatMap(ClaudeBlock.Kind.init(rawValue:)),
              let hour = group(4).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = group(5).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        let zone = group(7).flatMap(TimeZone.init(identifier:))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? tokyo
        var parts = calendar.dateComponents([.year, .month, .day], from: eventTimestamp)
        parts.hour = hour % 12 + (group(6) == "pm" ? 12 : 0)
        parts.minute = minute
        parts.second = 0
        if let monthName = group(2) {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            guard let month = months.firstIndex(of: monthName), let day = group(3).flatMap(Int.init) else { return nil }
            parts.month = month + 1
            parts.day = day
        }
        guard var reset = calendar.date(from: parts),
              calendar.component(.month, from: reset) == parts.month,
              calendar.component(.day, from: reset) == parts.day else { return nil }
        if group(2) == nil {
            guard let next = calendar.nextDate(after: eventTimestamp,
                matching: DateComponents(hour: parts.hour, minute: minute, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            reset = next
        } else if reset.timeIntervalSince(eventTimestamp) < -86400 {
            guard let next = calendar.date(byAdding: .year, value: 1, to: reset) else { return nil }
            reset = next
        }
        return ClaudeBlock(kind: kind, resetAt: reset, timeZoneKnown: zone != nil)
    }

    static func classify(line: String) -> LineKind {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "assistant",
              let rawTimestamp = json["timestamp"] as? String,
              let message = json["message"] as? [String: Any] else { return .other }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var timestamp = formatter.date(from: rawTimestamp)
        if timestamp == nil {
            formatter.formatOptions = [.withInternetDateTime]
            timestamp = formatter.date(from: rawTimestamp)
        }
        guard let timestamp else { return .other }
        if json["isApiErrorMessage"] as? Bool == true {
            guard json["error"] as? String == "rate_limit",
                  let content = message["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { return .other }
            return .rateLimit(text: text, timestamp: timestamp)
        }
        guard json["error"] == nil || json["error"] is NSNull,
              let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>" else { return .other }
        return .normalAssistant(timestamp: timestamp)
    }

    static func recoveryShort(resetAt: Date, now: Date) -> String {
        format(resetAt, includeDate: resetAt.timeIntervalSince(now) > 86400)
    }

    /// Always-dated recovery label for the locked ring: ("10/22", "02:00") in Asia/Tokyo.
    static func recoveryLines(resetAt: Date) -> (date: String, time: String) {
        let parts = format(resetAt, includeDate: true).split(separator: " ")
        return (String(parts.first ?? ""), String(parts.last ?? ""))
    }

    static func cardLine(block: ClaudeBlock, now: Date) -> String {
        let label = block.kind == .session ? "5時間枠" : "週"
        let time = format(block.resetAt, includeDate: block.kind == .weekly || block.resetAt.timeIntervalSince(now) > 86400)
        return "\(label)の制限中・\(time)に復帰" + (block.timeZoneKnown ? "" : "（時帯未確認）")
    }

    private static func format(_ date: Date, includeDate: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = tokyo
        formatter.dateFormat = includeDate ? "M/d HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }
}
