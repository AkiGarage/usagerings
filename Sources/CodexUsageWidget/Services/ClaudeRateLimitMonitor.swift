import Foundation

protocol ClaudeRateLimitRemote: Sendable {
    func lines() async -> [String]
}

struct ClaudeRateLimitMonitor: Sendable {
    // Assumes CLIProxy accountIndex 0 = Claude A, 1 = Claude B, like the rings.
    static let defaultAccounts: [Int: [URL]] = [
        0: [".claude-a/projects", ".claude/projects"],
        1: [".claude-b/projects"]
    ].mapValues { paths in
        paths.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0) }
    }
    let accounts: [Int: [URL]]
    let remote: (any ClaudeRateLimitRemote)?
    private let files: ClaudeRateLimitFiles

    init(accounts: [Int: [URL]] = Self.defaultAccounts,
         remote: (any ClaudeRateLimitRemote)? = nil, fileManager: FileManager = .default) {
        self.accounts = accounts
        self.remote = remote
        self.files = ClaudeRateLimitFiles(fileManager: fileManager)
    }

    static func live() -> Self {
        Self(remote: ClaudeRateLimitSSH.shared)
    }

    func blocks(now: Date) async -> [Int: ClaudeBlock] {
        let remoteLines = await remote?.lines() ?? []
        var result: [Int: ClaudeBlock] = [:]
        for account in Set(accounts.keys).union(remote == nil ? [] : [1]) {
            var latest: (timestamp: Date, block: ClaudeBlock)?
            var normalTimestamp: Date?
            func consume(_ line: String) {
                guard line.contains("isApiErrorMessage") || line.contains("assistant") else { return }
                switch ClaudeRateLimitParser.classify(line: line) {
                case let .rateLimit(text, timestamp):
                    guard let block = ClaudeRateLimitParser.parse(text: text, eventTimestamp: timestamp),
                          latest == nil || timestamp > latest!.timestamp else { return }
                    latest = (timestamp, block)
                case let .normalAssistant(timestamp):
                    normalTimestamp = max(normalTimestamp ?? .distantPast, timestamp)
                case .other: break
                }
            }
            for line in await files.lines(roots: accounts[account] ?? [], now: now) { consume(line) }
            if account == 1 { remoteLines.forEach(consume) }
            if let latest, latest.block.isActive(at: now),
               normalTimestamp == nil || normalTimestamp! <= latest.timestamp {
                result[account] = latest.block
            }
        }
        return result
    }
}

/// Owns Foundation's non-Sendable FileManager and serializes its bounded reads.
private actor ClaudeRateLimitFiles {
    private let fileManager: FileManager

    init(fileManager: FileManager) { self.fileManager = fileManager }

    func lines(roots: [URL], now: Date) -> [String] {
        newestFiles(roots: roots, now: now).flatMap(Self.tailLines)
    }

    private func newestFiles(roots: [URL], now: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var files: [(url: URL, modified: Date)] = []
        for root in roots {
            guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      modified >= now.addingTimeInterval(-8 * 86400) else { continue }
                files.append((url, modified))
            }
        }
        return files.sorted {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
        }.prefix(5).map(\.url)
    }

    private static func tailLines(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let offset = end > 262144 ? end - 262144 : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: 262144) ?? Data()
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return [] }
                data = Data(data.suffix(from: data.index(after: newline)))
            }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        } catch { return [] }
    }
}

actor ClaudeRateLimitSSH: ClaudeRateLimitRemote {
    static let shared = ClaudeRateLimitSSH()
    private let settings: @Sendable () -> ClaudeSSHSettings?
    private let fetch: @Sendable (ClaudeSSHSettings) async -> [String]
    private var cachedLines: [String] = []
    private var cachedSettings: ClaudeSSHSettings?
    private var lastAttempt: Date?
    private var pending: (id: UUID, settings: ClaudeSSHSettings, task: Task<[String], Never>)?

    init(settings: @escaping @Sendable () -> ClaudeSSHSettings? = {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        return ClaudeSSHSettings.load()
    }, fetch: @escaping @Sendable (ClaudeSSHSettings) async -> [String] = {
        await ClaudeRateLimitSSH.fetchLines($0)
    }) {
        self.settings = settings
        self.fetch = fetch
    }

    private static func fetchLines(_ settings: ClaudeSSHSettings) async -> [String] {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), timeout: 10)
        guard let result = try? await runner.run(settings.arguments),
              !result.timedOut, result.terminationStatus == 0 else { return [] }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // Fixed, read-only command. Only B's project transcripts are eligible. The
    // final filter emits quota text or a normal timestamp/model, never reply text.
    static let command = #"""
    bash -c 'find "$HOME/.claude-b/projects" -type f -name "*.jsonl" -mmin -11520 -printf "%T@ %p\0" 2>/dev/null | sort -z -nr | head -z -n 5 | while IFS= read -r -d "" entry; do
    file="${entry#* }"
    tail -c 262144 -- "$file" | grep -E "\"isApiErrorMessage\"[[:space:]]*:[[:space:]]*true" | tail -3
    tail -c 262144 -- "$file" | grep -E "\"type\"[[:space:]]*:[[:space:]]*\"assistant\"" | python3 -c "import sys,json
    rows=[]
    for line in sys.stdin:
     try:
      d=json.loads(line); m=d.get(\"message\",{})
      if d.get(\"type\")==\"assistant\" and not d.get(\"isApiErrorMessage\",False) and not d.get(\"error\") and m.get(\"model\") not in (None,\"\",\"<synthetic>\"):
       rows.append({\"type\":\"assistant\",\"timestamp\":d.get(\"timestamp\",\"\"),\"message\":{\"model\":m[\"model\"]}})
     except (ValueError,TypeError,AttributeError): pass
    if rows: print(json.dumps(max(rows,key=lambda d:d[\"timestamp\"])))"
    done' | python3 -c 'import sys,json
    for line in sys.stdin:
     try:
      d=json.loads(line); m=d.get("message",{})
      if d.get("type")!="assistant": continue
      out={"type":"assistant","timestamp":d.get("timestamp","")}
      if d.get("isApiErrorMessage") is True and d.get("error")=="rate_limit":
       text=m.get("content",[{}])[0].get("text","")
       if not text.startswith(("You\u0027ve hit your session limit", "You\u0027ve hit your weekly limit", "You’ve hit your session limit", "You’ve hit your weekly limit")): continue
       out.update({"isApiErrorMessage":True,"error":"rate_limit","message":{"content":[{"text":text}]}})
      elif not d.get("isApiErrorMessage",False) and not d.get("error") and m.get("model") not in (None,"","<synthetic>"):
       out["message"]={"model":m["model"]}
      else: continue
      print(json.dumps(out))
     except (ValueError,TypeError,AttributeError,IndexError): pass'
    """#

    func lines() async -> [String] {
        guard let current = settings() else {
            pending?.task.cancel()
            pending = nil
            cachedLines = []
            cachedSettings = nil
            lastAttempt = nil
            return []
        }
        if let pending, pending.settings == current {
            let lines = await pending.task.value
            return settings() == current ? lines : []
        }
        if cachedSettings != current {
            pending?.task.cancel()
            pending = nil
            cachedLines = []
            lastAttempt = nil
            cachedSettings = current
        }
        let now = Date()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 300 { return cachedLines }
        lastAttempt = now
        let id = UUID()
        let task = Task { await fetch(current) }
        pending = (id, current, task)
        let lines = await task.value
        guard pending?.id == id else { return [] }
        pending = nil
        guard settings() == current else {
            cachedLines = []
            cachedSettings = nil
            lastAttempt = nil
            return []
        }
        cachedLines = lines
        return cachedLines
    }
}
