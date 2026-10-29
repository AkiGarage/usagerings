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

    private static let blockMarkers = [
        "unusual traffic", "not a robot", "captcha", "verify it's you", "verify it’s you", "sign in", "couldn't sign you in",
        "something went wrong", "try again later", "ロボットではありません", "不審なトラフィック", "本人確認",
        "ログイン", "問題が発生しました", "しばらくしてから",
    ]
    private static let fiveLabels = ["current usage", "5-hour", "5 hour", "現在の使用量", "現在の使用状況", "5 時間", "5時間"]
    private static let weekLabels = ["weekly limit", "weekly", "週間の上限", "週間", "週の上限", "1 週間", "1週間"]

    static func parse(_ text: String) -> Outcome {
        let text = String(text.prefix(maxTextLength))
        let lower = text.lowercased()
        let hasUsageHeading = lower.contains("usage limits") || text.contains("使用量の上限") || text.contains("利用上限")
            || lower.contains("current usage") || text.contains("現在の使用")
        if blockMarkers.contains(where: { lower.contains($0) }), !hasUsageHeading { return .blocked }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let five = section(lines, labels: fiveLabels, others: weekLabels)
        let week = section(lines, labels: weekLabels, others: fiveLabels)
        let reading = Reading(fiveHourUsed: five.flatMap(usedPercent), weeklyUsed: week.flatMap(usedPercent),
                              fiveHourReset: five.flatMap(resetLine), weeklyReset: week.flatMap(resetLine))
        guard reading.fiveHourUsed != nil || reading.weeklyUsed != nil else { return .unknown }
        return .reading(reading)
    }

    /// Lines from the first label hit up to (not including) the next section label (max 6 lines).
    private static func section(_ lines: [String], labels: [String], others: [String]) -> [String]? {
        guard let start = lines.firstIndex(where: { line in labels.contains { line.lowercased().contains($0) } }) else { return nil }
        var out = [lines[start]]
        var i = start + 1
        while i < lines.count, out.count < 6 {
            let l = lines[i].lowercased()
            if others.contains(where: { l.contains($0) }) && !labels.contains(where: { l.contains($0) }) { break }
            out.append(lines[i]); i += 1
        }
        return out
    }

    /// A percentage that is unambiguously "used". "% left/remaining" is converted; a bare
    /// percentage counts as used (the page shows percent used); two different numbers = unknown.
    static func usedPercent(_ lines: [String]) -> Double? {
        let regex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:[.,]\d+)?)\s*[%％]"#)
        var values: [Double] = []
        for line in lines {
            let ns = line as NSString
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let v = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")),
                      (0...100).contains(v) else { continue }
                let l = line.lowercased()
                let left = l.contains("left") || l.contains("remaining") || line.contains("残り")
                values.append(left ? 100 - v : v)
            }
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
    /// Gemini counts as "in use" for this long after it was last seen frontmost.
    static let recentUse: TimeInterval = 5 * 60
    /// A gap longer than this starts a new session (read once at the start).
    static let sessionGap: TimeInterval = 15 * 60
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
        var lastSeenGemini: Date?
        var lastRead: Date?
        var halted = false
    }

    /// Returns the updated state and whether to read now.
    static func step(_ state: State, _ s: Signals) -> (State, Bool) {
        var state = state
        guard !state.halted, !s.screenAsleep, s.idleSeconds < idleLimit, !quietHours.contains(s.hour) else { return (state, false) }
        let previousSeen = state.lastSeenGemini
        if s.geminiFrontmost { state.lastSeenGemini = s.now }
        guard let seen = state.lastSeenGemini, s.now.timeIntervalSince(seen) <= recentUse else { return (state, false) }
        let newSession = s.geminiFrontmost && (previousSeen == nil || s.now.timeIntervalSince(previousSeen!) > sessionGap)
        if newSession, state.lastRead.map({ s.now.timeIntervalSince($0) >= 60 }) ?? true { return (state, true) }
        guard let last = state.lastRead else { return (state, true) }
        return (state, s.now.timeIntervalSince(last) >= interval)
    }
}

enum ChromeAutomationStatus: Equatable { case granted, notDetermined, denied, chromeNotRunning, unavailable }

/// Everything that touches Chrome. Read-only AppleScript; nothing here activates or navigates.
protocol ChromeUsageBridge {
    var chromeRunning: Bool { get }
    var chromeFrontmost: Bool { get }
    /// `ask` must only be true from an explicit user action.
    func automationStatus(ask: Bool) -> ChromeAutomationStatus
    func activeTabURL() -> String?
    /// innerText of the first already-open gemini.google.com/usage tab, nil if none / not allowed.
    func usageTabText() -> Result<String, ChromeReadError>?
}

enum ChromeReadError: Error, Equatable { case notAllowed, javascriptDisabled, failed }

struct LiveChromeBridge: ChromeUsageBridge {
    static let bundleID = "com.google.Chrome"

    var chromeRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }
    var chromeFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID }

    func automationStatus(ask: Bool) -> ChromeAutomationStatus {
        guard chromeRunning else { return .chromeNotRunning }
        var target = AEAddressDesc()
        let id = Self.bundleID
        let made = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &target) }
        guard made == noErr else { return .unavailable }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unavailable
        }
    }

    private func run(_ source: String) -> (String?, Int?) {
        // Never let AppleScript launch Chrome: `tell application` would start it.
        guard chromeRunning, automationStatus(ask: false) == .granted else { return (nil, -1743) }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { return (nil, error[NSAppleScript.errorNumber] as? Int ?? -1) }
        return (result?.stringValue, nil)
    }

    func activeTabURL() -> String? {
        run(#"tell application id "com.google.Chrome" to if (count of windows) > 0 then return URL of active tab of front window"#).0
    }

    func usageTabText() -> Result<String, ChromeReadError>? {
        // Look for an existing usage tab without touching window order, selection or URL.
        let script = #"""
        tell application id "com.google.Chrome"
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u starts with "https://gemini.google.com/usage" then
                return execute t javascript "(document.body && document.body.innerText || '').slice(0, 40000)"
              end if
            end repeat
          end repeat
          return "__NO_USAGE_TAB__"
        end tell
        """#
        let (text, error) = run(script)
        if let error {
            if error == -1743 { return .failure(.notAllowed) }
            // Chrome: "Executing JavaScript through AppleScript is turned off" (View > Developer).
            return .failure(error == 12 ? .javascriptDisabled : .failed)
        }
        guard let text, text != "__NO_USAGE_TAB__" else { return nil }
        return .success(text)
    }
}

@MainActor
final class GeminiAppUsageMonitor {
    static let enabledKey = "geminiAppReadingEnabled"
    static let cacheKey = "geminiAppLastReading"

    private let bridge: ChromeUsageBridge
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
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
        section = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        section = cachedOrUnknown("不明（Gemini の使用量タブを開くと読みます）")
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func start() {
        publish(isEnabled ? cachedOrUnknown("不明（Gemini の使用量タブを開くと読みます）")
                          : cachedOrUnknown("オフ（メニューで「Gemini の使用量を読む」をオン）"))
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
            }
        }
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Explicit user action from the menu. The only path that may show the macOS dialog, once.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        state.halted = false
        guard on else { publish(cachedOrUnknown("オフ")); return }
        let status = bridge.automationStatus(ask: bridge.automationStatus(ask: false) == .notDetermined)
        if status != .granted { publish(cachedOrUnknown(Self.text(for: status))) }
        state.lastRead = nil
        tick()
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

    func tick() {
        guard isEnabled, bridge.chromeRunning else { return }
        let now = clock()
        let hour = Calendar.current.component(.hour, from: now)
        let asleep = screenAsleep(), idle = idleSeconds()
        // Cheap checks first: only ask Chrome for its URL while Chrome is frontmost and Aki is active.
        var geminiFront = false
        if bridge.chromeFrontmost, !asleep, idle < GeminiReadPolicy.idleLimit, !GeminiReadPolicy.quietHours.contains(hour),
           bridge.automationStatus(ask: false) == .granted {
            geminiFront = bridge.activeTabURL()?.hasPrefix("https://gemini.google.com/") ?? false
        }
        let (next, read) = GeminiReadPolicy.step(state, .init(now: now, geminiFrontmost: geminiFront, idleSeconds: idle,
                                                              screenAsleep: asleep, hour: hour))
        state = next
        guard read else { return }
        guard bridge.automationStatus(ask: false) == .granted else {
            publish(cachedOrUnknown(Self.text(for: bridge.automationStatus(ask: false)))); return
        }
        state.lastRead = now
        readCount += 1
        switch bridge.usageTabText() {
        case nil:
            publish(cachedOrUnknown("不明（gemini.google.com/usage のタブが開いていません）"))
        case .failure(.javascriptDisabled):
            state.halted = true
            publish(cachedOrUnknown("不明（Chrome の「Apple Events からの JavaScript を許可」がオフ）"))
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
