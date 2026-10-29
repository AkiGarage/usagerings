import AppKit
import CoreGraphics
import Foundation
import os

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

    static let maxTextLength = 300_000

    /// Any of these anywhere on the page means "not the plain usage page": stop, show 不明, save nothing.
    static let blockMarkers = [
        "unusual traffic", "not a robot", "captcha", "verify it's you", "verify it’s you", "sign in", "couldn't sign you in",
        "something went wrong", "try again later", "ロボットではありません", "不審なトラフィック", "本人確認",
        "ログイン", "問題が発生しました", "しばらくしてから",
    ]
    /// A section label is a short line that STARTS with one of these (case-insensitive, after
    /// full-width → half-width folding). A value may follow on the same line ("Current usage 23% used").
    static let fivePrefixes = ["current usage", "5-hour", "5 hour", "five-hour", "現在の使用", "現在の利用",
                               "5時間", "5 時間", "5時間ごと"]
    static let weekPrefixes = ["weekly", "week ", "週", "1週間", "1 週間", "毎週の", "今週の"]
    private static let sectionLines = 4
    private static let maxLabelLength = 40

    /// Full-width digits, ％ and spaces become ASCII; NBSP becomes a space.
    static func normalize(_ text: String) -> String {
        // Only the full-width ASCII block (U+FF01–FF5E) and the ideographic space; kana stay as they are.
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if (0xFF01...0xFF5E).contains(u.value), let a = Unicode.Scalar(u.value - 0xFEE0) { scalars.append(a) }
            else if u.value == 0x3000 { scalars.append(" ") } else { scalars.append(u) }
        }
        return String(scalars).replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func parse(_ raw: String) -> Outcome {
        let text = normalize(raw)
        let lower = text.lowercased()
        // The whole page is checked for verification text first, never a truncated prefix.
        if blockMarkers.contains(where: { lower.contains($0) }) { return .blocked }
        guard text.count <= maxTextLength else { return .unknown }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let five = sections(lines, prefixes: fivePrefixes)
        let week = sections(lines, prefixes: weekPrefixes)
        let bars = progressBars(lines)
        // Body text first; progress bars (reported separately by the page script) only when the
        // body has no value at all. Conflicting body values stay unknown, never overridden.
        func pick(_ secs: [[String]], _ prefixes: [String]) -> Double? {
            let vals = Set(secs.compactMap(usedPercent))
            let conflict = secs.contains { usedPercent($0) == nil && hasPercent($0) }
            if vals.count > 1 || conflict { return nil }
            return vals.first ?? barValue(bars, prefixes: prefixes)
        }
        let reading = Reading(fiveHourUsed: pick(five, fivePrefixes), weeklyUsed: pick(week, weekPrefixes),
                              fiveHourReset: five.lazy.compactMap(resetLine).first, weeklyReset: week.lazy.compactMap(resetLine).first)
        guard reading.fiveHourUsed != nil || reading.weeklyUsed != nil else { return .unknown }
        return .reading(reading)
    }

    static let barMarker = "@@bar "
    static let leftWords = ["remaining", "left", "available", "残り", "残量", "利用可能"]

    private static func progressBars(_ lines: [String]) -> [(context: String, value: Double)] {
        lines.compactMap { line in
            guard line.hasPrefix(barMarker), let eq = line.range(of: " = ", options: .backwards),
                  eq.lowerBound >= line.index(line.startIndex, offsetBy: barMarker.count), let v = Double(line[eq.upperBound...]), (0...100).contains(v) else { return nil }
            return (String(line[line.index(line.startIndex, offsetBy: barMarker.count)..<eq.lowerBound]).lowercased(), v)
        }
    }

    private static func barValue(_ bars: [(context: String, value: Double)], prefixes: [String]) -> Double? {
        let other = prefixes == fivePrefixes ? weekPrefixes : fivePrefixes
        func has(_ c: String, _ ps: [String]) -> Bool { ps.contains { c.hasPrefix($0) || c.contains(" " + $0) || c.contains("\n" + $0) } }
        // A bar whose label speaks of "remaining/left" has an unclear direction: never used.
        let values = Set(bars.filter { b in has(b.context, prefixes) && !has(b.context, other) && !leftWords.contains { b.context.contains($0) } }.map(\.value))
        return values.count == 1 ? values.first : nil
    }

    /// Returns the label prefix if this line is a section label of that kind.
    private static func labelRest(_ line: String, _ prefixes: [String]) -> String? {
        guard !line.hasPrefix(barMarker), line.count <= maxLabelLength else { return nil }
        let l = line.lowercased()
        guard !l.contains("reset"), !l.contains("リセット"), let p = prefixes.first(where: { l.hasPrefix($0) }) else { return nil }
        // The rest of the line after the label words (e.g. "Current usage 23% used" -> "23% used").
        let rest = String(line.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        guard let pctStart = rest.firstIndex(where: \.isNumber) else {
            // "Current usage remaining" + value on the next line: keep the direction word as a line.
            return leftWords.contains { rest.lowercased().contains($0) } ? rest : ""
        }
        // Keep the direction word between label and number ("Current usage remaining 70%").
        let lead = rest[..<pctStart].lowercased()
        let value = String(rest[pctStart...])
        if leftWords.contains(where: { lead.contains($0) }) { return "残り " + value }
        return value
    }

    private static func isLabel(_ line: String) -> Bool {
        labelRest(line, fivePrefixes) != nil || labelRest(line, weekPrefixes) != nil
    }

    /// Any other heading-like line ("Monthly limit", "Daily usage") ends a section.
    private static func isHeading(_ line: String) -> Bool {
        let l = line.lowercased()
        guard !l.contains("%") else { return false } // a value line, not a heading
        return ["limit", "usage", "quota", "上限", "使用量", "利用枠"].contains { l.contains($0) }
    }

    /// For every label line: the lines after it, up to the next label/heading line (max 4).
    private static func sections(_ lines: [String], prefixes: [String]) -> [[String]] {
        lines.indices.compactMap { start in
            guard let rest = labelRest(lines[start], prefixes) else { return nil }
            var out: [String] = rest.isEmpty ? [] : [rest]
            var i = start + 1
            while i < lines.count, out.count < sectionLines, !isLabel(lines[i]), !isHeading(lines[i]), !lines[i].hasPrefix(barMarker) {
                out.append(lines[i]); i += 1
            }
            return out
        }
    }

    /// Any percentage at all in the section: if none parses cleanly, the section is ambiguous.
    private static func hasPercent(_ lines: [String]) -> Bool {
        lines.contains { $0.range(of: #"\d\s*%"#, options: .regularExpression) != nil }
    }

    private static let num = #"(\d{1,3}(?:\.\d+)?)\s*%"#
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let usedRegexes = [
        rx("^" + num + #"$"#), // the bar's own figure, shown as used
        rx("^" + num + #"\s*(?:used|使用済み|使用|を使用|を使用済み|使用中)$"#),
        rx(#"^(?:used|usage|使用済み|使用率|使用量|使用)\s*[:：]?\s*"# + num + "$"),
    ]
    private static let leftRegexes = [
        rx("^" + num + #"\s*(?:left|remaining|available|残り|残っています)$"#),
        rx(#"^(?:残り|left|remaining)\s*[:：]?\s*"# + num + "$"),
    ]

    /// Only whole lines like "23% used" / "23%" / "70% left" / "残り 70%" / "使用率 23%" count.
    /// Anything else ("40% off", "2 requests left", "20% 40%") is ignored; two different values = unknown.
    static func usedPercent(_ lines: [String]) -> Double? {
        func value(_ regex: NSRegularExpression, _ line: String) -> Double? {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let v = Double(ns.substring(with: m.range(at: 1))), (0...100).contains(v) else { return nil }
            return v
        }
        var values: [Double] = []
        // A bare "70%" under a separate "Remaining" line is a remaining value.
        let directionLines: Set<String> = ["remaining", "left", "available", "remaining usage", "usage remaining", "残り", "残量", "利用可能", "残りの使用量"]
        let leftContext = lines.contains { directionLines.contains($0.lowercased()) }
        // Any other percentage on a line ("40% off") makes the section ambiguous.
        var stray = false
        for line in lines {
            if leftContext, let v = value(usedRegexes[0], line) { values.append(100 - v) }
            else if let v = usedRegexes.lazy.compactMap({ value($0, line) }).first { values.append(v) }
            else if let v = leftRegexes.lazy.compactMap({ value($0, line) }).first { values.append(100 - v) }
            else if line.range(of: #"\d\s*%"#, options: .regularExpression) != nil { stray = true }
        }
        if stray { return nil }
        let distinct = Set(values)
        return distinct.count == 1 ? distinct.first : nil
    }

    /// Short, redacted lines for diagnosing an unreadable page: only lines with a digit, % or a
    /// usage word, never e-mail addresses, max 40 lines of 80 chars. Kept only on this Mac.
    /// Only usage words, percentages, times and dates survive; every other word becomes "…".
    static func shapeOnly(_ line: String) -> String {
        let words = (fivePrefixes + weekPrefixes + leftWords + ["usage", "limits", "limit", "used", "resets", "reset", "at", "in", "on",
            "上限", "使用済み", "使用率", "使用量", "使用", "利用状況", "リセット", "時間", "ごと", "週間", "現在", "毎週", "に", "の", "まで", "で", "され", "ます", "量", "状況", "率", "済み"])
            .sorted { $0.count > $1.count }
            .map { w in w.unicodeScalars.allSatisfy(\.isASCII) ? #"\b"# + NSRegularExpression.escapedPattern(for: w.trimmingCharacters(in: .whitespaces)) + #"\b"#
                                                               : NSRegularExpression.escapedPattern(for: w) }
            .joined(separator: "|")
        let rx = try! NSRegularExpression(pattern: #"\d{1,3}(?:\.\d+)?\s*%|\b\d{1,2}:\d{2}\b|\d{1,2}(?:月|日|時|分)|(?i:"# + words + ")")
        let ns = line as NSString
        var out = "", last = 0
        for m in rx.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += gap.trimmingCharacters(in: .whitespaces).isEmpty ? gap : (gap.hasPrefix(" ") ? " … " : "…")
            out += ns.substring(with: m.range); last = m.range.location + m.range.length
        }
        if last < ns.length { out += "…" }
        return out
    }

    /// Every digit becomes "#" except percentages, hh:mm times and 月/日/時/分 dates.
    static func maskNumbers(_ line: String) -> String {
        let keep = try! NSRegularExpression(pattern: #"\d{1,3}(?:\.\d+)?\s*%|\b\d{1,2}:\d{2}\b|\d{1,2}(?:月|日|時|分)"#)
        let ns = line as NSString
        var out = "", last = 0
        for m in keep.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                .replacingOccurrences(of: #"\p{N}"#, with: "#", options: .regularExpression)
            out += ns.substring(with: m.range); last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last).replacingOccurrences(of: #"\p{N}"#, with: "#", options: .regularExpression)
    }

    static func redactedSample(_ raw: String) -> String {
        let keep = ["%", "limit", "usage", "reset", "used", "left", "上限", "使用", "利用", "リセット", "残り", "週", "時間", "@@bar"]
        let lines = normalize(raw).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { l in !l.isEmpty && l.count <= 80 && (l.contains(where: \.isNumber) || keep.contains { l.lowercased().contains($0) }) }
            .filter { l in keep.contains { l.lowercased().contains($0) } }
            .map { $0.replacingOccurrences(of: #"\S+@\S+"#, with: "<email>", options: .regularExpression) }
            // Only percentages, times and dates keep their digits; any other number becomes "#".
            .map(maskNumbers).map(shapeOnly)
        return lines.prefix(40).joined(separator: "\n")
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
        return since >= interval // clock moved back (since < 0): the monitor rebases lastRead
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
    /// Drop every queued, not yet started Chrome request (menu toggle-off).
    func invalidatePending()
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

/// Talks to Chrome with raw Apple events addressed to the running Chrome *process ID*, not
/// its bundle ID: if Chrome has quit, the event fails (procNotFound) instead of launching it.
/// Events are sent with "never interact" + "do not prompt for user consent", so a tick can
/// never raise the macOS Automation dialog, and with an 8 s timeout on a background queue.
struct LiveChromeBridge: ChromeUsageBridge {
    static let bundleID = "com.google.Chrome"
    private static let queue = DispatchQueue(label: "usagerings.gemini.appleevents", qos: .utility)
    static let timeoutSeconds: TimeInterval = 8
    /// kAEDoNotPromptForUserConsent (AE/AppleEvents.h, macOS 10.14+).
    static let doNotPrompt = NSAppleEventDescriptor.SendOptions(rawValue: 0x0002_0000)
    static let sendOptions: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, doNotPrompt]

    var chromeRunning: Bool { Self.pid() != nil }
    var chromeFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID }

    /// Skips background instances of the same bundle id (e.g. an orphaned `--headless` test Chrome
    /// with its own empty profile), which otherwise received our Apple Events. A visible GUI
    /// automation Chrome is still `.regular`; reads only run while Chrome is frontmost, so the
    /// frontmost regular instance wins, then the oldest.
    static func pid() -> pid_t? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { ChromeInstance(pid: $0.processIdentifier, regular: $0.activationPolicy == .regular,
                                  terminated: $0.isTerminated, active: $0.isActive, launched: $0.launchDate) }
        return ChromeInstance.pick(apps)
    }

    private static let epoch = OSAllocatedUnfairLock(initialState: 0)

    /// Runs on the serial queue; returns `cancelled` if invalidated while waiting in line.
    private static func onQueue<T: Sendable>(cancelled: T, _ work: @escaping @Sendable () -> T) async -> T {
        await onQueue(cancelled: cancelled) { (_: () -> Bool) in work() }
    }

    /// Variant whose work gets an `alive()` check, so long steps can re-check invalidation mid-way.
    private static func onQueue<T: Sendable>(cancelled: T, _ work: @escaping @Sendable (() -> Bool) -> T) async -> T {
        let started = epoch.withLock { $0 }
        let alive = { epoch.withLock { $0 } == started }
        return await withCheckedContinuation { c in
            queue.async { c.resume(returning: alive() ? work(alive) : cancelled) }
        }
    }

    private static func geminiInFront() -> Bool {
        // In use right now: awake screen and recent input, not just the front app.
        let anyInput = CGEventType(rawValue: ~0)!
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < GeminiReadPolicy.idleLimit,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              case let .success(front) = send("core", "getd", direct: property("URL ", of: property("acTa", of: window(1)))) else { return false }
        return GeminiUsageURL.isGemini(front.stringValue ?? "")
    }

    func invalidatePending() { Self.epoch.withLock { $0 += 1 } }

    private static func status(ask: Bool) -> ChromeAutomationStatus {
        guard pid() != nil else { return .chromeNotRunning }
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
        await Self.onQueue(cancelled: .unavailable) { Self.status(ask: ask) }
    }

    static func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    private static func spec(_ want: String, form: String, _ data: NSAppleEventDescriptor,
                             in container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        r.setDescriptor(data, forKeyword: code("seld"))
        r.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: code("from"))
        return r.coerce(toDescriptorType: code("obj "))
    }
    private static func property(_ p: String, of c: NSAppleEventDescriptor?) -> NSAppleEventDescriptor? {
        spec("prop", form: "prop", NSAppleEventDescriptor(typeCode: code(p)), in: c)
    }
    private static var every: NSAppleEventDescriptor {
        var all = code("all ")
        return NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!
    }
    private static func window(_ i: Int32?) -> NSAppleEventDescriptor? {
        spec("cwin", form: "indx", i.map { NSAppleEventDescriptor(int32: $0) } ?? every, in: nil)
    }

    enum SendFailure: Error { case code(Int) }

    /// Synchronous; call only on `queue`.
    private static func send(_ cls: String, _ id: String, direct: NSAppleEventDescriptor?,
                             params: [String: NSAppleEventDescriptor] = [:]) -> Result<NSAppleEventDescriptor, SendFailure> {
        guard let pid = pid() else { return .failure(.code(-600)) }
        guard let direct else { return .failure(.code(-1)) }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: code(cls), eventID: code(id), targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: keyDirectObject)
        for (k, v) in params { event.setParam(v, forKeyword: code(k)) }
        do {
            let reply = try event.sendEvent(options: sendOptions, timeout: timeoutSeconds)
            if let err = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, err != 0 { return .failure(.code(Int(err))) }
            return .success(reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null())
        } catch {
            return .failure(.code((error as NSError).code))
        }
    }

    private static func strings(_ d: NSAppleEventDescriptor) -> [[String]] {
        guard d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).map { i in
            guard let w = d.atIndex(i), w.numberOfItems > 0 else { return [] }
            return (1...w.numberOfItems).map { w.atIndex($0)?.stringValue ?? "" }
        }
    }

    /// The page checks its own URL; any other page returns only its URL, never its text.
    static let pageScript = """
    (function(){var b='\(GeminiUsageURL.base)',u=location.href;\
    var ok=u===b||u.indexOf(b+'?')===0||u.indexOf(b+'#')===0;\
    if(!ok)return JSON.stringify({u:u});var t=(document.body&&document.body.innerText)||'',bars=[];\
    document.querySelectorAll('[role=progressbar],progress[value]').forEach(function(e){\
    var pr=e.tagName==='PROGRESS',v=parseFloat(pr?e.getAttribute('value'):e.getAttribute('aria-valuenow'));\
    var mn=pr?0:parseFloat(e.getAttribute('aria-valuemin')||'0'),mx=parseFloat(pr?(e.getAttribute('max')||'1'):(e.getAttribute('aria-valuemax')||'100'));\
    if(!isFinite(v)||!isFinite(mn)||!isFinite(mx)||mx<=mn||v<mn||v>mx)return;var c=e.getAttribute('aria-label')||'',p=e.parentElement,n=0;\
    for(var i=0;i<4&&p&&!n;i++,p=p.parentElement){var x=(p.innerText||'').trim();if(x){c=c+' '+x.slice(0,80);n=1;}}\
    bars.push({c:c.replace(/\\s+/g,' ').slice(0,60),v:Math.round((v-mn)/(mx-mn)*1000)/10});});\
    return JSON.stringify({u:u,t:t,b:bars});})()
    """

    /// Text only when the page itself says it is exactly the usage page.
    static func usageText(fromJSON json: String?) -> Result<String, ChromeReadError>? {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["u"] as? String else { return .failure(.failed) }
        guard GeminiUsageURL.isUsagePage(url) else { return nil }
        guard let body = obj["t"] as? String else { return .failure(.failed) }
        // Page text can never pose as a progress bar: the marker is only added for real bars.
        var text = GeminiAppUsageParser.normalize(body).replacingOccurrences(of: GeminiAppUsageParser.barMarker.trimmingCharacters(in: .whitespaces), with: "@ @bar")
        for bar in obj["b"] as? [[String: Any]] ?? [] {
            guard let c = bar["c"] as? String, let v = (bar["v"] as? NSNumber)?.doubleValue else { continue }
            text += "\n" + GeminiAppUsageParser.barMarker + c.replacingOccurrences(of: "\n", with: " ") + " = " + String(v)
        }
        return .success(text)
    }

    func activeTabURL() async -> String? {
        await Self.onQueue(cancelled: nil) {
            guard Self.status(ask: false) == .granted,
                  case let .success(d) = Self.send("core", "getd", direct: Self.property("URL ", of: Self.property("acTa", of: Self.window(1))))
            else { return nil }
            return d.stringValue
        }
    }

    func usageTabText() async -> Result<String, ChromeReadError>? {
        await Self.onQueue(cancelled: nil) { (alive: () -> Bool) -> Result<String, ChromeReadError>? in
            guard Self.status(ask: false) == .granted else { return .failure(.notAllowed) }
            // Same queue slot: Gemini must still be the front app and front tab right now.
            guard Self.geminiInFront() else { return nil }
            let tabs = Self.spec("CrTb", form: "indx", Self.every, in: Self.window(nil))
            guard case let .success(urlDesc) = Self.send("core", "getd", direct: Self.property("URL ", of: tabs)),
                  case let .success(idDesc) = Self.send("core", "getd", direct: Self.property("ID  ", of: tabs)) else { return .failure(.failed) }
            let urls = Self.strings(urlDesc), ids = Self.strings(idDesc)
            guard urls.count == ids.count else { return .failure(.failed) }
            for (w, row) in urls.enumerated() {
                guard row.count == ids[w].count,
                      let t = row.firstIndex(where: GeminiUsageURL.isUsagePage) else { continue }
                // Address the tab by its unique ID so a reordered window cannot redirect the read.
                let tab = Self.spec("CrTb", form: "ID  ", NSAppleEventDescriptor(string: ids[w][t]), in: Self.window(Int32(w + 1)))
                // The page reports its own URL in the same call, so a tab that moved or navigated is never read.
                let js = NSAppleEventDescriptor(string:
                    Self.pageScript)
                // Listing tabs can take seconds: re-check toggle and front tab right before executing.
                guard alive(), Self.geminiInFront() else { return nil }
                switch Self.send("CrSu", "ExJa", direct: tab, params: ["JvSc": js]) {
                case let .success(d): return Self.usageText(fromJSON: d.stringValue)
                case .failure(.code(-1743)), .failure(.code(-1744)): return .failure(.notAllowed)
                case .failure(.code(-1712)): return .failure(.timedOut)
                case .failure(.code(-600)): return nil
                case .failure(.code(12)): return .failure(.javascriptDisabled)
                case .failure: return .failure(.failed)
                }
            }
            return nil
        }
    }
}

@MainActor
final class GeminiAppUsageMonitor {
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastReadUptime: TimeInterval?
    static let enabledKey = "geminiAppReadingEnabled"
    static let cacheKey = "geminiAppLastReading"
    static let lastReadKey = "geminiAppLastReadAt"
    static let haltedKey = "geminiAppHalted"

    private let bridge: ChromeUsageBridge
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var inFlight = false
    /// Bumped on every menu toggle; work started under an older generation is discarded.
    private var generation = 0
    var isVisible: () -> Bool = { true }
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
        state.halted = defaults.bool(forKey: Self.haltedKey)
        section = ProviderSection(provider: .gemini, windows: [], stats: [], failureText: "不明")
        section = cachedOrUnknown(startText)
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    private var active: Bool { isEnabled && isVisible() }

    var startText: String {
        if !isEnabled { return "オフ（メニューで「Gemini の使用量を読む」をオン）" }
        if state.halted { return "不明（確認ページかエラーのため停止中。メニューでオフ→オンで再開）" }
        return "不明（Gemini を使うと読みます）"
    }

    func start() {
        publish(cachedOrUnknown(startText))
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
        generation += 1
        let gen = generation
        setHalted(false)
        guard on else { bridge.invalidatePending(); publish(cachedOrUnknown("オフ")); return }
        let current = await bridge.automationStatus(ask: false)
        guard gen == generation, isEnabled else { return } // toggled again meanwhile: never ask
        let status = current == .notDetermined ? await bridge.automationStatus(ask: true) : current
        guard gen == generation, isEnabled else { return }
        if status != .granted { publish(cachedOrUnknown(Self.text(for: status))); return }
        publish(cachedOrUnknown(startText))
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
        guard active, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let gen = generation
        func current() -> Bool { gen == generation && active && !state.halted }
        let now = clock()
        if let last = state.lastRead, now < last { // clock moved back: rebase, read again 5 min from now
            state.lastRead = now; defaults.set(now.timeIntervalSince1970, forKey: Self.lastReadKey)
        }
        markStaleIfOld(now)
        guard bridge.chromeRunning else { return }
        let hour = Calendar.current.component(.hour, from: now)
        let asleep = screenAsleep(), idle = idleSeconds()
        let base = GeminiReadPolicy.Signals(now: now, geminiFrontmost: true, idleSeconds: idle, screenAsleep: asleep, hour: hour)
        // Cheap local checks first; only then ask Chrome for its front tab URL.
        guard bridge.chromeFrontmost, GeminiReadPolicy.shouldRead(state, base) else { return }
        guard await bridge.automationStatus(ask: false) == .granted, current() else { return }
        let front = await bridge.activeTabURL().map(GeminiUsageURL.isGemini) ?? false
        guard current() else { return }
        var signals = base; signals.geminiFrontmost = front && bridge.chromeFrontmost
        guard GeminiReadPolicy.shouldRead(state, signals) else { return }
        state.lastRead = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastReadKey)
        // Re-check right before reading the body: Aki may have switched app or tab meanwhile.
        guard bridge.chromeFrontmost, await bridge.activeTabURL().map(GeminiUsageURL.isGemini) ?? false,
              bridge.chromeFrontmost, current() else { return }
        // Monotonic guard: a wall-clock jump forward can never shorten spacing within this run.
        let up = uptime()
        if let last = lastReadUptime, up - last < GeminiReadPolicy.interval { return }
        lastReadUptime = up
        let readAt = clock() // spacing counts from the actual read, not the tick start
        state.lastRead = readAt
        defaults.set(readAt.timeIntervalSince1970, forKey: Self.lastReadKey)
        readCount += 1
        let result = await bridge.usageTabText()
        lastReadUptime = uptime()
        let doneAt = clock() // stamp again after the read so spacing never shrinks below 5 minutes
        if doneAt > readAt { state.lastRead = doneAt; defaults.set(doneAt.timeIntervalSince1970, forKey: Self.lastReadKey) }
        guard current() else { return } // toggled, hidden or halted during the read: discard
        switch result {
        case nil:
            publish(cachedOrUnknown("不明（gemini.google.com/usage のタブが開いていません）"))
        case .failure(.javascriptDisabled):
            setHalted(true)
            publish(cachedOrUnknown("不明（Chrome の「Apple Events からの JavaScript を許可」がオフ）"))
        case .failure(.timedOut):
            publish(cachedOrUnknown("不明（Chrome の応答がありません）"))
        case .failure:
            setHalted(true)
            publish(cachedOrUnknown("不明（Chrome から読めませんでした。読み取りを停止）"))
        case let .success(text):
            switch GeminiAppUsageParser.parse(text) {
            case .blocked:
                setHalted(true)
                publish(cachedOrUnknown("不明（確認ページかエラー表示のため停止。メニューで再開）"))
            case .unknown:
                Self.saveDiagnostic(GeminiAppUsageParser.redactedSample(text))
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

    /// Redacted lines of the last unreadable page, local only (~/Library/Application Support/UsageRings).
    static func saveDiagnostic(_ sample: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UsageRings", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? sample.write(to: dir.appendingPathComponent("gemini-unreadable-sample.txt"), atomically: true, encoding: .utf8)
    }

    private func setHalted(_ on: Bool) { state.halted = on; defaults.set(on, forKey: Self.haltedKey) }

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

/// One running process with Chrome's bundle id. Pure, so the choice can be tested.
struct ChromeInstance: Equatable {
    var pid: pid_t
    var regular: Bool
    var terminated: Bool
    var active: Bool
    var launched: Date?

    static func pick(_ all: [ChromeInstance]) -> pid_t? {
        let real = all.filter { $0.regular && !$0.terminated }
        if let front = real.first(where: \.active) { return front.pid }
        return real.min { ($0.launched ?? .distantFuture) < ($1.launched ?? .distantFuture) }?.pid
    }
}
