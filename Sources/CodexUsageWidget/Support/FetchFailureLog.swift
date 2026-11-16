import Foundation

struct FetchFailureLog: Sendable {
    static let byteCap = 262_144
    let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static func live() -> FetchFailureLog {
        FetchFailureLog(fileURL: MultiAppPaths.fetchFailureLogURL())
    }

    private static let lock = NSLock()
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The same failure is kept at most once an hour, so a minute-by-minute retry cannot push
    /// older history out of the 256 KB log; one line per hour still shows the failure lasts.
    static let repeatInterval: TimeInterval = 60 * 60

    func record(provider: String, reason: UsageFailureReason, exitCode: Int32?, message: String, at date: Date = Date()) {
        guard let fileURL else { return }
        let fields = [
            Self.iso8601.string(from: date),
            String(Self.redacted(Self.flattened(provider)).prefix(64)),
            Self.reasonText(reason),
            exitCode.map(String.init) ?? "-",
            String(Self.redacted(Self.flattened(message)).prefix(160))
        ]
        Self.append(fields, to: fileURL)
    }

    /// Time, reason and message of this provider's last line, nil when it has none. Providers
    /// fail on the same poll, so their lines interleave: compare per provider, not the last line.
    static func lastRecord(of provider: String, in contents: String) -> (at: Date, reason: String, message: String)? {
        for line in contents.split(separator: "\n").reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[1] == provider else { continue }
            guard let at = iso8601.date(from: fields[0]) else { return nil }
            return (at, fields[2], fields[4])
        }
        return nil
    }

    /// True when this provider's last line has the same reason and message and is under an hour old.
    static func isRepeat(provider: String, reason: String, message: String, at date: Date, previous: String) -> Bool {
        guard let last = lastRecord(of: provider, in: previous), last.reason == reason,
              last.message == message else { return false }
        // A clock moved back also counts as recent: never write the same line twice in a row.
        return date.timeIntervalSince(last.at) < repeatInterval
    }

    static func flattened(_ text: String) -> String {
        String(text.map { "\n\r\t".contains($0) ? " " : $0 })
    }

    static func reasonText(_ reason: UsageFailureReason) -> String {
        switch reason {
        case .timeout: "timeout"
        case .launchFailure: "launchFailure"
        case .transport: "transport"
        case .logout: "logout"
        case .providerError: "providerError"
        case .other: "other"
        }
    }

    /// Appends one tab-separated record, unless it repeats the previous line within the hour.
    static func append(_ fields: [String], to url: URL) {
        guard fields.count == 5 else { return }
        let line = fields.joined(separator: "\t") + "\n"
        let date = iso8601.date(from: fields.first ?? "") ?? Date()
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if isRepeat(provider: fields[1], reason: fields[2], message: fields[4], at: date, previous: previous) { return }
        rotateIfOversized(at: url, fileManager: fileManager)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: Data(line.utf8))
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    static func rotateIfOversized(at url: URL, fileManager: FileManager) {
        let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > byteCap else { return }
        let rotated = url.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotated)
        try? fileManager.moveItem(at: url, to: rotated)
    }

    static func redacted(_ message: String) -> String {
        var text = message
        for pattern in [
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}",
            "Bearer[ \\t]+\\S+",
            "sk-[A-Za-z0-9_-]+",
            "eyJ[A-Za-z0-9.-]+",
            "[A-Za-z0-9_-]{24,}"
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
        }
        return text
    }
}
