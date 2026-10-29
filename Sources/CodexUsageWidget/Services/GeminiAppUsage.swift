import AppKit
import CoreGraphics
import Foundation

/// Reads the Gemini app quota only from a gemini.google.com/usage tab Aki already has open
/// in his signed-in Chrome. It never opens, reloads, focuses or navigates a tab, never
/// launches Chrome, never asks macOS for permission by itself, and sends no network request:
/// it reads the text Chrome already shows.
enum GeminiAppUsageParser {
    struct Reading: Equatable {
        var fiveHourUsed: Double?
        var weeklyUsed: Double?
        var fiveHourReset: String?
        var weeklyReset: String?
    }

    enum Outcome: Equatable {
        case reading(Reading)
        /// Sign-in, captcha, unusual-traffic or error page: stop reading.
        case blocked
        /// Page loaded but the numbers could not be found with certainty.
        case unknown
    }

    static let maxTextLength = 40_000

    /// Any of these anywhere on the page means "not the plain usage page": stop, show 不明, save nothing.
    static let blockMarkers = [
        "unusual traffic", "not a robot", "captcha", "verify it's you", "verify it’s you", "sign in", "couldn't sign you in",
        "something went wrong", "try again later", "ロボットではありません", "不審なトラフィック", "本人確認",
        "ログイン", "問題が発生しました", "しばらくしてから",
    ]
    /// Section labels must be a whole line (case-insensitive), not a substring of other text.
    static let fiveLabels: Set<String> = ["current usage", "5-hour limit", "5 hour limit", "現在の使用量", "現在の使用状況",
                                          "5 時間の上限", "5時間の上限"]
    static let weekLabels: Set<String> = ["weekly limit", "weekly usage", "週間の上限", "週の上限", "1 週間の上限", "1週間の上限"]
    private static let sectionLines = 4

    static func parse(_ text: String) -> Outcome {
        let text = String(text.prefix(maxTextLength))
        let lower = text.lowercased()
        if blockMarkers.contains(where: { lower.contains($0) }) { return .blocked }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let five = section(lines, labels: fiveLabels)
        let week = section(lines, labels: weekLabels)
        let reading = Reading(fiveHourUsed: five.flatMap(usedPercent), weeklyUsed: week.flatMap(usedPercent),
                              fiveHourReset: five.flatMap(resetLine), weeklyReset: week.flatMap(resetLine))
        guard reading.fiveHourUsed != nil || reading.weeklyUsed != nil else { return .unknown }
        return .reading(reading)
    }

    private static func isLabel(_ line: String) -> Bool {
        let l = line.lowercased()
        return fiveLabels.contains(l) || weekLabels.contains(l)
    }

    /// Lines after the exact label line, up to the next label line (max 4).
    private static func section(_ lines: [String], labels: Set<String>) -> [String]? {
        let hits = lines.indices.filter { labels.contains(lines[$0].lowercased()) }
        guard hits.count == 1, let start = hits.first else { return nil } // missing or repeated label = unknown
        var out: [String] = []
        var i = start + 1
        while i < lines.count, out.count < sectionLines, !isLabel(lines[i]) { out.append(lines[i]); i += 1 }
        return out
    }

    private static let usedRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3}(?:\.\d+)?)\s*[%％]\s*(?:used|使用済み|使用)$"#, options: [.caseInsensitive])
    private static let leftRegexes = [
        try! NSRegularExpression(pattern: #"^(\d{1,3}(?:\.\d+)?)\s*[%％]\s*(?:left|remaining|残り)$"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^残り\s*(\d{1,3}(?:\.\d+)?)\s*[%％]$"#),
    ]

    /// Only whole lines like "23% used" / "70% left" / "残り 70%" count. Anything else
    /// ("40% off", "2 requests left", bare "23%") is ignored; two different values = unknown.
    static func usedPercent(_ lines: [String]) -> Double? {
        func value(_ regex: NSRegularExpression, _ line: String) -> Double? {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let v = Double(ns.substring(with: m.range(at: 1))), (0...100).contains(v) else { return nil }
            return v
        }
        var values: [Double] = []
        for line in lines {
            if let v = value(usedRegex, line) { values.append(v) }
            for r in leftRegexes { if let v = value(r, line) { values.append(100 - v) } }
        }
        let distinct = Set(values)
        return distinct.count == 1 ? distinct.first : nil
    }

    private static func resetLine(_ lines: [String]) -> String? {
        lines.first { $0.lowercased().contains("reset") || $0.contains("リセット") }.map { String($0.prefix(80)) }
    }

    static func section(from outcome: Outcome, observedAt: Date) -> ProviderSection? {
        guard case let .reading(r) = outcome else { return nil }
        var windows: [UsageLimit] = []
        if let used = r.fiveHourUsed {
            var w = UsageLimit(title: "Gemini · 5h", leftPercent: 100 - used, resetText: r.fiveHourReset ?? "")
            w.observedAt = observedAt
            windows.append(w)
        }
        if let used = r.weeklyUsed {
            var w = UsageLimit(title: "Gemini · Weekly", leftPercent: 100 - used, resetText: r.weeklyReset ?? "")
            w.observedAt = observedAt
            windows.append(w)
        }
        return ProviderSection(provider: .gemini, windows: windows, stats: [], failureText: nil)
    }
}

/// When to read. Pure so it can be tested.
enum GeminiReadPolicy {
    static let interval: TimeInterval = 5 * 60
    /// A shown value older than this (no reads because Gemini isn't in use) is marked stale.
    static let staleAfter: TimeInterval = 10 * 60
    static let idleLimit: TimeInterval = 120
    /// Local hours with no reads at all (01:00–05:59).
    static let quietHours = 1..<6

    struct Signals: Equatable {
        var now: Date
        var geminiFrontmost: Bool
        var idleSeconds: TimeInterval
        var screenAsleep: Bool
        var hour: Int
    }

    struct State: Equatable {
        /// Persisted across toggles and restarts.
        var lastRead: Date?
        var halted = false
    }

    /// Read only while a Gemini tab is frontmost and Aki is active, at most once per 5 minutes.
    /// The first frontmost tick after a break (>= 5 min since the last read) reads at once.
    static func shouldRead(_ state: State, _ s: Signals) -> Bool {
        guard !state.halted, s.geminiFrontmost, !s.screenAsleep, s.idleSeconds < idleLimit,
              !quietHours.contains(s.hour) else { return false }
        guard let last = state.lastRead else { return true }
        let since = s.now.timeIntervalSince(last)
        return since >= interval || since < -60 // clock moved backwards: allow once
    }
}

enum ChromeAutomationStatus: Equatable { case granted, notDetermined, denied, chromeNotRunning, unavailable }

/// Everything that touches Chrome. Read-only AppleScript; nothing here activates, navigates or launches.
protocol ChromeUsageBridge: Sendable {
    var chromeRunning: Bool { get }
    var chromeFrontmost: Bool { get }
    /// `ask` must only be true from an explicit user action.
    func automationStatus(ask: Bool) async -> ChromeAutomationStatus
    func activeTabURL() async -> String?
    /// innerText of an already-open https://gemini.google.com/usage tab, nil if none.
    func usageTabText() async -> Result<String, ChromeReadError>?
}

enum ChromeReadError: Error, Equatable { case notAllowed, javascriptDisabled, timedOut, failed }

enum GeminiUsageURL {
    static let base = "https://gemini.google.com/usage"
    /// Exact page only: the base URL, optionally with a query or fragment.
    static func isUsagePage(_ url: String) -> Bool {
        url == base || url.hasPrefix(base + "?") || url.hasPrefix(base + "#")
    }
    static func isGemini(_ url: String) -> Bool { url.hasPrefix("https://gemini.google.com/") }
}

struct LiveChromeBridge: ChromeUsageBridge {
    static let bundleID = "com.google.Chrome"
    /// NSAppleScript runs on one serial background queue, never on the main thread.
    private static let queue = DispatchQueue(label: "usagerings.gemini.applescript", qos: .utility)
    static let timeoutSeconds = 8

    var chromeRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }
    var chromeFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: work()) } }
    }

    private static func status(ask: Bool) -> ChromeAutomationStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return .chromeNotRunning }
        var target = AEAddressDesc()
        let made = bundleID.withCString { AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &target) }
        guard made == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unavailable
        }
    }

    func automationStatus(ask: Bool) async -> ChromeAutomationStatus {
        await Self.onQueue { Self.status(ask: ask) }
    }

    /// Wraps the body so the script itself checks Chrome is running (never launches it)
    /// and every Apple event gives up after `timeoutSeconds`.
    static func wrapped(_ body: String) -> String {
        """
        if application id "\(bundleID)" is running then
          with timeout of \(timeoutSeconds) seconds
            tell application id "\(bundleID)"
        \(body)
            end tell
          end timeout
        end if
        return "__NOT_RUNNING__"
        """
    }

    private static func run(_ body: String) async -> (String?, Int?) {
        await onQueue {
            guard status(ask: false) == .granted else { return (nil, -1743) }
            var error: NSDictionary?
            let result = NSAppleScript(source: wrapped(body))?.executeAndReturnError(&error)
            if let error { return (nil, error[NSAppleScript.errorNumber] as? Int ?? -1) }
            let text = result?.stringValue
            return text == "__NOT_RUNNING__" ? (nil, nil) : (text, nil)
        }
    }

    func activeTabURL() async -> String? {
        await Self.run(#"if (count of windows) > 0 then return URL of active tab of front window"#).0
    }

    func usageTabText() async -> Result<String, ChromeReadError>? {
        // Look for an existing usage tab without touching window order, selection or URL.
        let body = #"""
        repeat with w in windows
          repeat with t in tabs of w
            set u to URL of t
            if u is "\#(GeminiUsageURL.base)" or u starts with "\#(GeminiUsageURL.base)?" or u starts with "\#(GeminiUsageURL.base)#" then
              return execute t javascript "(document.body && document.body.innerText || '').slice(0, 40000)"
            end if
          end repeat
        end repeat
        return "__NO_USAGE_TAB__"
        """#
        let (text, error) = await Self.run(body)
        if let error {
            switch error {
            case -1743: return .failure(.notAllowed)
            case -1712: return .failure(.timedOut)
            case 12: return .failure(.javascriptDisabled) // "Executing JavaScript through AppleScript is turned off"
            default: return .failure(.failed)
            }
        }
        guard let text, text != "__NO_USAGE_TAB__" else { return nil }
        return .success(text)
    }
}

@MainActor
final class GeminiAppUsageMonitor {
    static let enabledKey = "geminiAppReadingEnabled"
    static let cacheKey = "geminiAppLastReading"
    static let lastReadKey = "geminiAppLastReadAt"

    private let bridge: ChromeUsageBridge
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var inFlight = false
    private(set) var state = GeminiReadPolicy.State()
    private(set) var section: ProviderSection
    var onChange: ((ProviderSection) -> Void)?
    var clock: () -> Date = { Date() }
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    var screenAsleep: () -> Bool = { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    /// Number of times Chrome was actually asked for page text (tests).
    private(set) var readCount = 0

    init(bridge: ChromeUsageBridge = LiveChromeBridge(), defaults: UserDefaults = .standard) {
        self.bridge = bridge
        self.defaults = defaults
        let at = defaults.double(forKey: Self.lastReadKey)
        state.lastRead = at > 0 ? Date(timeIntervalSince1970: at) : nil
        section = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        section = cachedOrUnknown(Self.startText(enabled: isEnabled))
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    static func startText(enabled: Bool) -> String {
        enabled ? "不明（Gemini を使うと読みます）" : "オフ（メニューで「Gemini の使用量を読む」をオン）"
    }

    func start() {
        publish(cachedOrUnknown(Self.startText(enabled: isEnabled)))
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Explicit user action from the menu. The only path that may show the macOS dialog, once.
    /// The last-read time is kept, so toggling never causes an extra read.
    func setEnabled(_ on: Bool) async {
        defaults.set(on, forKey: Self.enabledKey)
        state.halted = false
        guard on else { publish(cachedOrUnknown("オフ")); return }
        let current = await bridge.automationStatus(ask: false)
        let status = current == .notDetermined ? await bridge.automationStatus(ask: true) : current
        if status != .granted { publish(cachedOrUnknown(Self.text(for: status))); return }
        publish(cachedOrUnknown(Self.startText(enabled: true)))
        await tick()
    }

    static func text(for status: ChromeAutomationStatus) -> String {
        switch status {
        case .granted: "不明"
        case .notDetermined: "不明（Chrome の操作許可が未設定。メニューから一度だけ許可）"
        case .denied: "不明（Chrome の操作が許可されていません：システム設定 > プライバシー > オートメーション）"
        case .chromeNotRunning: "不明（Chrome が起動していません）"
        case .unavailable: "不明（Chrome の状態を確認できません）"
        }
    }

    func tick() async {
        guard isEnabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let now = clock()
        markStaleIfOld(now)
        guard bridge.chromeRunning else { return }
        let hour = Calendar.current.component(.hour, from: now)
        let asleep = screenAsleep(), idle = idleSeconds()
        let base = GeminiReadPolicy.Signals(now: now, geminiFrontmost: true, idleSeconds: idle, screenAsleep: asleep, hour: hour)
        // Cheap local checks first; only then ask Chrome for its front tab URL.
        guard bridge.chromeFrontmost, GeminiReadPolicy.shouldRead(state, base) else { return }
        guard await bridge.automationStatus(ask: false) == .granted else { return }
        let front = await bridge.activeTabURL().map(GeminiUsageURL.isGemini) ?? false
        var signals = base; signals.geminiFrontmost = front && bridge.chromeFrontmost
        guard GeminiReadPolicy.shouldRead(state, signals) else { return }
        state.lastRead = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastReadKey)
        readCount += 1
        switch await bridge.usageTabText() {
        case nil:
            publish(cachedOrUnknown("不明（gemini.google.com/usage のタブが開いていません）"))
        case .failure(.javascriptDisabled):
            state.halted = true
            publish(cachedOrUnknown("不明（Chrome の「Apple Events からの JavaScript を許可」がオフ）"))
        case .failure(.timedOut):
            publish(cachedOrUnknown("不明（Chrome の応答がありません）"))
        case .failure:
            state.halted = true
            publish(cachedOrUnknown("不明（Chrome から読めませんでした。読み取りを停止）"))
        case let .success(text):
            switch GeminiAppUsageParser.parse(text) {
            case .blocked:
                state.halted = true
                publish(cachedOrUnknown("不明（確認ページかエラー表示のため停止。メニューで再開）"))
            case .unknown:
                publish(cachedOrUnknown("不明（使用量の数字を読み取れませんでした）"))
            case let outcome:
                if let fresh = GeminiAppUsageParser.section(from: outcome, observedAt: now) {
                    save(fresh, at: now)
                    publish(fresh)
                }
            }
        }
    }

    /// A fresh value that has not been re-read for a while is shown as stale with its time.
    private func markStaleIfOld(_ now: Date) {
        guard !section.isStale, let observed = section.windows.first?.observedAt,
              now.timeIntervalSince(observed) > GeminiReadPolicy.staleAfter else { return }
        publish(cachedOrUnknown("使用中でないため更新停止"))
    }

    private func publish(_ s: ProviderSection) { section = s; onChange?(s) }

    private func save(_ s: ProviderSection, at date: Date) {
        let rows = s.windows.map { ["title": $0.title, "left": $0.leftPercent, "reset": $0.resetText] as [String: Any] }
        defaults.set(["at": date.timeIntervalSince1970, "windows": rows], forKey: Self.cacheKey)
    }

    /// Last real reading, marked stale with its time; otherwise 不明 with the reason.
    func cachedOrUnknown(_ reason: String) -> ProviderSection {
        guard let dict = defaults.dictionary(forKey: Self.cacheKey), let at = dict["at"] as? Double,
              let rows = dict["windows"] as? [[String: Any]], !rows.isEmpty else {
            return ProviderSection(provider: .gemini, windows: [], stats: [], failureText: reason)
        }
        let observed = Date(timeIntervalSince1970: at)
        let windows: [UsageLimit] = rows.compactMap { row in
            guard let title = row["title"] as? String, let left = row["left"] as? Double else { return nil }
            var w = UsageLimit(title: title, leftPercent: left, resetText: row["reset"] as? String ?? "")
            w.observedAt = observed
            return w
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d HH:mm"
        var s = ProviderSection(provider: .gemini, windows: windows, stats: [],
                                failureText: "\(reason) · 最後に読んだ値 \(f.string(from: observed))")
        s.isStale = true
        return s
    }
}
