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

    func record(provider: String, reason: UsageFailureReason, exitCode: Int32?, message: String, at date: Date = Date()) {
        guard let fileURL else { return }
        let line = [
            Self.iso8601.string(from: date),
            String(Self.redacted(Self.flattened(provider)).prefix(64)),
            Self.reasonText(reason),
            exitCode.map(String.init) ?? "-",
            String(Self.redacted(Self.flattened(message)).prefix(160))
        ].joined(separator: "\t") + "\n"
        Self.append(line, to: fileURL)
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

    static func append(_ line: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
