import Foundation

enum CodexUsageError: LocalizedError, Equatable {
    case cliNotFound(String)
    case commandFailed(Int32, String)
    case invalidJSON
    case missingSection(String)
    case missingPercent(String)

    var errorDescription: String? {
        switch self {
        case let .cliNotFound(path):
            "CodexBarCLI not found at \(path)"
        case let .commandFailed(code, message):
            "CodexBarCLI exited \(code): \(message)"
        case .invalidJSON:
            "CodexBarCLI returned invalid JSON"
        case let .missingSection(name):
            "Missing \(name) usage"
        case let .missingPercent(line):
            "Missing percent in: \(line)"
        }
    }

    static func commandFailure(exitCode: Int32, stdout: Data, stderr: Data) -> Self {
        if let summary = CodexBarErrorTransport.sanitizedSummary(from: stdout) {
            return .commandFailed(exitCode, summary)
        }
        let summary = stderr.isEmpty
            ? "CodexBarCLI returned no structured error details"
            : "CodexBarCLI reported an error; details redacted"
        return .commandFailed(exitCode, summary)
    }
}

struct CodexUsageService: Sendable {
    typealias CommandRunner = @Sendable ([String]) throws -> CommandResult

    struct CommandResult: Sendable {
        let terminationStatus: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool

        init(terminationStatus: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
            self.terminationStatus = terminationStatus
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
        }
    }

    private let cliPath: String
    private let commandRunner: CommandRunner?

    init(
        cliPath: String = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        commandRunner: CommandRunner? = nil
    ) {
        self.cliPath = cliPath
        self.commandRunner = commandRunner
    }

    func fetch() throws -> UsageSnapshot {
        let result = try runCodexBar(arguments: ["usage", "--provider", "codex", "--format", "json"])
        guard result.terminationStatus == 0 else {
            throw CodexUsageError.commandFailure(
                exitCode: result.terminationStatus,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return try CodexUsageTextParser.parseJSON(result.stdout)
    }

    private func runCodexBar(arguments: [String]) throws -> CommandResult {
        if let commandRunner {
            return try commandRunner(arguments)
        }

        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: cliPath))
        return try runner.runSync(arguments)
    }
}

private enum CodexBarErrorTransport {
    private static let knownKinds: Set<String> = ["args", "config", "provider", "runtime"]

    static func sanitizedSummary(from data: Data) -> String? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let objects = decoded as? [Any]
        else { return nil }

        for case let object as [String: Any] in objects {
            guard object["provider"] as? String == "codex",
                  object["error"] != nil,
                  JSONSerialization.isValidJSONObject(object),
                  let entryData = try? JSONSerialization.data(withJSONObject: object),
                  let entry = try? JSONDecoder().decode(CodexBarErrorEntry.self, from: entryData),
                  let error = entry.error
            else { continue }

            var summary = "Codex provider error"
            var details: [String] = []
            if let kind = error.kind, knownKinds.contains(kind) {
                details.append(kind)
            }
            if let code = error.code {
                details.append("code \(code)")
            }
            if !details.isEmpty {
                summary += " (\(details.joined(separator: ", ")))"
            }
            return summary
        }
        return nil
    }
}

private struct CodexBarErrorEntry: Decodable {
    let provider: String?
    let error: CodexBarStructuredError?
}

private struct CodexBarStructuredError: Decodable {
    let code: Int?
    let kind: String?
}

struct CodexUsageTextParser {
    static func parseJSON(_ data: Data, now: Date = Date(), timeZone: TimeZone = .current) throws -> UsageSnapshot {
        let entries = try JSONDecoder().decode([CodexBarUsageEntry].self, from: data)
        guard !selectedCodexEntryContainsError(in: data) else {
            throw CodexUsageError.invalidJSON
        }
        guard let usage = entries.first(where: { $0.provider == "codex" })?.usage else {
            throw CodexUsageError.invalidJSON
        }

        // The live payload reports an unreported 5h window as an all-null
        // object; only a window carrying usedPercent participates.
        let session = try reportedWindow(usage.primary).map {
            try usageLimit(
                title: "Session",
                limit: $0,
                now: now,
                timeZone: timeZone,
                projectionPrefix: "Projected empty in"
            )
        }
        let weekly = try reportedWindow(usage.secondary).map {
            try usageLimit(
                title: "Weekly",
                limit: $0,
                now: now,
                timeZone: timeZone,
                projectionPrefix: "Runs out in"
            )
        }
        guard session != nil || weekly != nil else {
            throw CodexUsageError.invalidJSON
        }
        return UsageSnapshot(session: session, weekly: weekly, updatedAt: now)
    }

    private static func selectedCodexEntryContainsError(in data: Data) -> Bool {
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let objects = decoded as? [[String: Any]],
              let entry = objects.first(where: { $0["provider"] as? String == "codex" })
        else { return false }

        guard let error = entry["error"] else { return false }
        return !(error is NSNull)
    }

    static func parse(_ text: String) throws -> UsageSnapshot {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let session = try parseLimit(named: "Session", in: lines)
        let weeklyPace = parsePace(in: lines)
        let weekly = try parseLimit(named: "Weekly", in: lines, pace: weeklyPace)
        return UsageSnapshot(session: session, weekly: weekly, updatedAt: Date())
    }

    private static func parseLimit(named name: String, in lines: [String], pace: PaceLine? = nil) throws -> UsageLimit {
        guard let index = lines.firstIndex(where: { $0.hasPrefix("\(name):") }) else {
            throw CodexUsageError.missingSection(name)
        }

        let percent = try parsePercent(from: lines[index])
        let reset = parseReset(after: index, in: lines) ?? "Reset pending"
        return UsageLimit(
            title: name,
            leftPercent: percent,
            resetText: reset,
            detailText: pace?.detailText,
            projectionText: pace?.projectionText,
            markerPercent: pace?.markerPercent
        )
    }

    private static func parsePercent(from line: String) throws -> Double {
        let pattern = #":\s*([0-9]+(?:\.[0-9]+)?)%\s+left"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange])
        else {
            throw CodexUsageError.missingPercent(line)
        }
        return percent
    }

    private static func parseReset(after index: Int, in lines: [String]) -> String? {
        let nextSection = lines[(index + 1)...].firstIndex { line in
            line.hasPrefix("Session:") || line.hasPrefix("Weekly:") || line.hasPrefix("Credits:")
        } ?? lines.count
        guard index + 1 < nextSection else { return nil }
        return lines[(index + 1)..<nextSection].first { $0.hasPrefix("Resets") }
    }

    private static func parsePace(in lines: [String]) -> PaceLine? {
        guard let paceLine = lines.first(where: { $0.hasPrefix("Pace:") }) else { return nil }
        let values = paceLine
            .replacingOccurrences(of: "Pace:", with: "")
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !values.isEmpty else { return nil }
        return PaceLine(
            detailText: values.first,
            projectionText: values.first { $0.hasPrefix("Runs out") || $0.hasPrefix("Projected empty") },
            markerPercent: expectedLeftPercent(in: values)
        )
    }

    private static func reportedWindow(_ limit: CodexBarLimit?) -> CodexBarLimit? {
        guard let limit, limit.usedPercent != nil else { return nil }
        return limit
    }

    private static func usageLimit(
        title: String,
        limit: CodexBarLimit,
        now: Date,
        timeZone: TimeZone,
        projectionPrefix: String
    ) throws -> UsageLimit {
        guard let usedPercent = limit.usedPercent else {
            throw CodexUsageError.invalidJSON
        }
        let pace = paceContext(for: limit, now: now, timeZone: timeZone)
        var result = UsageLimit(
            title: title,
            leftPercent: leftPercent(fromUsedPercent: usedPercent),
            resetText: resetText(for: limit, now: now, timeZone: timeZone),
            detailText: detailText(for: pace),
            projectionText: projectionText(for: pace, prefix: projectionPrefix),
            markerPercent: pace?.markerPercent
        )
        result.resetAt = limit.resetsAt.flatMap(parseDate)
        return result
    }

    private static func resetText(for limit: CodexBarLimit, now: Date, timeZone: TimeZone) -> String {
        if let resetDate = resetDate(for: limit, now: now, timeZone: timeZone) {
            return UsageDurationFormat.resetText(for: resetDate, now: now, timeZone: timeZone)
        }
        if let resetDescription = limit.resetDescription {
            return resetDescription
        }
        guard let windowMinutes = limit.windowMinutes else { return "Reset pending" }
        return "Resets in \(UsageDurationFormat.text(for: windowMinutes * 60))"
    }

    private static func detailText(for context: PaceContext?) -> String? {
        guard let context else { return nil }
        return context.deficitPercent > 0 ? "\(context.deficitPercent)% in deficit" : "On pace"
    }

    private static func projectionText(for context: PaceContext?, prefix: String) -> String? {
        guard let context, context.usedPercent > 0 else { return nil }
        return "\(prefix) \(UsageDurationFormat.text(for: context.projectedEmptySeconds))"
    }

    private static func paceContext(for limit: CodexBarLimit, now: Date, timeZone: TimeZone) -> PaceContext? {
        guard let used = limit.usedPercent,
              let windowMinutes = limit.windowMinutes,
              let resetsAt = resetDate(for: limit, now: now, timeZone: timeZone)
        else {
            return nil
        }
        let windowSeconds = windowMinutes * 60
        let startedAt = resetsAt.addingTimeInterval(-windowSeconds)
        let elapsed = min(max(now.timeIntervalSince(startedAt), 1), windowSeconds)
        let expected = elapsed / windowSeconds * 100
        let roundedExpected = expected.rounded()
        let remaining = max(0, 100 - used)
        return PaceContext(
            usedPercent: used,
            deficitPercent: Int(max(0, used - roundedExpected).rounded()),
            markerPercent: min(max(100 - roundedExpected, 0), 100),
            projectedEmptySeconds: elapsed * remaining / max(used, 0.01)
        )
    }

    private static func leftPercent(fromUsedPercent usedPercent: Double) -> Double {
        min(max(100 - usedPercent, 0), 100)
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func resetDate(for limit: CodexBarLimit, now: Date, timeZone: TimeZone) -> Date? {
        if let resetsAt = limit.resetsAt.flatMap(parseDate) {
            return resetsAt
        }
        guard let resetDescription = limit.resetDescription else { return nil }
        return parseResetDescription(resetDescription, now: now, timeZone: timeZone)
    }

    private static func parseResetDescription(_ value: String, now: Date, timeZone: TimeZone) -> Date? {
        let description = value
            .replacingOccurrences(of: "Resets", with: "", options: [.anchored])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let absoluteDate = parseResetDescriptionDate(description, timeZone: timeZone) {
            return absoluteDate
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"

        guard let timeOnly = formatter.date(from: description) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let timeParts = calendar.dateComponents([.hour, .minute], from: timeOnly)
        var dayParts = calendar.dateComponents([.year, .month, .day], from: now)
        dayParts.hour = timeParts.hour
        dayParts.minute = timeParts.minute
        dayParts.second = 0

        guard var candidate = calendar.date(from: dayParts) else { return nil }
        if candidate <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) {
            candidate = tomorrow
        }
        return candidate
    }

    private static func parseResetDescriptionDate(_ value: String, timeZone: TimeZone) -> Date? {
        let formats = [
            "MMM d, yyyy h:mm a",
            "MMMM d, yyyy h:mm a"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func expectedLeftPercent(in values: [String]) -> Double? {
        guard let expected = values.first(where: { $0.hasPrefix("Expected") }) else { return nil }
        let pattern = #"Expected\s+([0-9]+(?:\.[0-9]+)?)%\s+used"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(expected.startIndex..<expected.endIndex, in: expected)
        guard let match = regex.firstMatch(in: expected, range: range),
              let valueRange = Range(match.range(at: 1), in: expected),
              let used = Double(expected[valueRange])
        else {
            return nil
        }
        return min(max(100 - used, 0), 100)
    }
}

private struct CodexBarUsageEntry: Decodable {
    let provider: String?
    let usage: CodexBarUsage?
}

private struct CodexBarUsage: Decodable {
    let primary: CodexBarLimit?
    let secondary: CodexBarLimit?
}

private struct CodexBarLimit: Decodable {
    let usedPercent: Double?
    let windowMinutes: Double?
    let resetsAt: String?
    let resetDescription: String?
}

private struct PaceLine {
    let detailText: String?
    let projectionText: String?
    let markerPercent: Double?
}

private struct PaceContext {
    let usedPercent: Double
    let deficitPercent: Int
    let markerPercent: Double
    let projectedEmptySeconds: TimeInterval
}
