import SwiftUI

/// Weekly window vs. an even spend: used share of the week against elapsed share of the week.
struct WeeklyPace: Equatable {
    static let week: TimeInterval = 7 * 86_400
    static let fiveHours: TimeInterval = 5 * 3600
    let label: String
    /// Window length and how many equal slices (7 days, or 5 hours) the bar shows.
    let period: TimeInterval
    let slices: Int
    var isFiveHour: Bool { period == Self.fiveHours }
    let now: Date
    let usedPercent: Double
    /// Elapsed share of the week, 0...100; nil when the reset time is unknown.
    let elapsedPercent: Double?
    let start: Date?
    let reset: Date?
    /// Why there is no marker: reset unknown, already passed, or farther than a week away.
    let unknownReason: String?

    init(label: String, limit: UsageLimit, now rawNow: Date, period: TimeInterval = WeeklyPace.week) {
        // Minute precision: keeps the pace Equatable across quick refreshes with unchanged data,
        // so the hover card is not rebuilt every few seconds (captions show minutes anyway).
        let now = Date(timeIntervalSince1970: (rawNow.timeIntervalSince1970 / 60).rounded(.down) * 60)
        self.label = label
        self.period = period
        slices = period == Self.fiveHours ? 5 : 7
        self.now = now
        usedPercent = 100 - limit.clampedLeftPercent
        let reset = limit.resetAt ?? RingResetFormat.date(fromResetText: limit.resetText, now: now)
        if let reset, reset > now, reset.timeIntervalSince(now) <= period {
            let start = reset.addingTimeInterval(-period)
            self.reset = reset
            self.start = start
            elapsedPercent = min(max(now.timeIntervalSince(start) / period * 100, 0), 100)
            unknownReason = nil
        } else {
            self.reset = nil; start = nil; elapsedPercent = nil
            unknownReason = reset == nil ? "リセット 不明" : reset! <= now ? "リセット 不明/要更新（時刻を過ぎました）" : (period == Self.fiveHours ? "リセット 不明（5時間より先）" : "リセット 不明（1週間より先）")
        }
    }

    /// Day of the window that contains now (0...6): the 24h slices start at the last reset, not at midnight.
    var todayIndex: Int? {
        guard !isFiveHour, let e = elapsedPercent else { return nil }
        let i = Int(floor(e * 7 / 100 + 1e-9))
        return min(max(i, 0), 6)
    }
    /// Today's even-pace allowance as a share of the week: expected use at the start and at the end of today.
    var todayRange: ClosedRange<Double>? {
        todayIndex.map { Double($0) * 100 / 7 ... Double($0 + 1) * 100 / 7 }
    }
    /// Even-pace weekly total at the end of today's day slice: fixed for the day.
    var todayTarget: Int? { todayRange.map { Int($0.upperBound.rounded()) } }
    /// Target minus current use, in the same rounded % as "使用 N%"; negative = over today's target.
    /// Computed from the latest usage every time the pace is rebuilt (each refresh), never cached per day.
    var todayLeft: Int? { todayTarget.map { $0 - Int(usedPercent.rounded()) } }
    var todayOver: Bool { (todayLeft ?? 0) < 0 }
    var todayText: String? { todayText(.used) }
    /// Same target in the chosen basis: 使用T%まで, or 残り(100-T)%まで. あと/超過 are identical in both.
    func todayText(_ basis: UsageBasis) -> String? {
        guard let t = todayTarget, let left = todayLeft else { return nil }
        let goal = basis == .used ? "使用\(t)%まで" : "残り\(100 - t)%まで"
        return left < 0 ? "今日の目安：\(goal)（\(-left)% 超過）" : "今日の目安：\(goal)（あと \(left)%）"
    }
    /// 5h caption: "あと1時間20分で回復（20:00）".
    var recoverText: String? {
        guard isFiveHour, let reset else { return nil }
        let m = max(1, Int((reset.timeIntervalSince(now) / 60).rounded(.up)))
        let c = RingResetFormat.tokyoCalendar.dateComponents([.hour, .minute], from: reset)
        let at = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return "あと\(m >= 60 ? "\(m / 60)時間\(m % 60)分" : "\(m)分")で回復（\(at) JST）"
    }
    func valueText(_ basis: UsageBasis) -> String { basis.valueText(leftPercent: 100 - usedPercent) }
    /// "週の枠" -> "週の詳細"; other labels keep their name so several weekly sections stay distinguishable.
    var detailTitle: String { label.contains("週の枠") ? label.replacingOccurrences(of: "週の枠", with: "週の詳細") : "\(label)の詳細" }
    static let helpText = "今日の目安：毎日同じだけ使った場合に今日の終わり時点での週の合計の目安で、（あと/超過）は今の使用量からリアルタイムに計算します。今の期間：この週の制限が数えられる期間で、終わりの時刻にリセットされます。"

    /// used - even share, in percentage points; positive means ahead of pace.
    var delta: Int? { elapsedPercent.map { Int((usedPercent - $0).rounded()) } }

    var paceText: String { paceText(.used) }
    func paceText(_ basis: UsageBasis) -> String {
        guard let d = delta else { return "リセット不明・均等ペース不明" }
        if basis == .left {
            if d >= 3 { return "均等より残り\(d)%少ない" }
            if d <= -3 { return "均等より残り\(-d)%多い" }
            return "ほぼ均等ペース"
        }
        if d >= 3 { return "均等より+\(d)%使いすぎ" }
        if d <= -3 { return "均等より使用\(-d)%少ない（余裕あり）" }
        return "ほぼ均等ペース"
    }
    enum Tone { case over, under, even, unknown }
    var tone: Tone {
        guard let delta else { return .unknown }
        return delta >= 3 ? .over : delta <= -3 ? .under : .even
    }

    static func day(_ date: Date?) -> String {
        guard let date else { return "不明" }
        let c = RingResetFormat.tokyoCalendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
    var rangeText: String { start == nil ? (unknownReason ?? "リセット 不明") : "今の期間：\(Self.day(start))〜\(Self.day(reset))" }
    /// Bottom line: reset range plus today's allowance when known.
    var footerText: String { todayText.map { "\(rangeText) ・ \($0)" } ?? rangeText }

    /// Every weekly window of a list.
    static func all(_ windows: [UsageLimit], now: Date, label: (UsageLimit) -> String) -> [WeeklyPace] {
        windows.filter { ServiceRowModel.kind($0.title) == .week }.map { WeeklyPace(label: label($0), limit: $0, now: now) }
    }
    /// Detail bars for every 5h window (first) and then every weekly window.
    static func details(_ windows: [UsageLimit], now: Date, label: (UsageLimit) -> String) -> [WeeklyPace] {
        windows.filter { ServiceRowModel.kind($0.title) == .five }.map { WeeklyPace(label: label($0), limit: $0, now: now, period: fiveHours) }
            + all(windows, now: now, label: label)
    }
}

/// 案B detail bar with even-pace tick and today's box. 残り: the remaining fill starts at the left and
/// shrinks right→left, and the elapsed tick and today's box are mirrored onto the same axis.
/// 使用量: orange fill grows left→right with unmirrored markers.
struct WeeklyPaceBar: View {
    let pace: WeeklyPace
    var compact = false
    var showLegend = false
    /// Rate-limited: the whole bar goes grey (no warning/critical colour, no pace markers).
    var blocked = false
    @AppStorage(UsageBasis.key, store: .standard) private var basisRaw = UsageBasis.defaultValue.rawValue
    private var basis: UsageBasis { UsageBasis(rawValue: basisRaw) ?? .defaultValue }

    /// Fixed blue: never the warning orange, independent of the system accent colour.
    static let todayColor = Color(red: 0.16, green: 0.47, blue: 0.96)
    enum MarkerStyle { case bracket, outline, dim }
    /// Chosen today marker; the others stay for preview comparison.
    nonisolated(unsafe) static var markerStyle: MarkerStyle = .outline
    @Environment(\.colorScheme) private var scheme
    private var dimColor: Color { (scheme == .dark ? Color.black : Color.white).opacity(0.55) }

    private var fill: Color {
        if blocked { return Color.secondary.opacity(0.45) }
        if basis == .used { return UsageLayout.usedColor }
        switch pace.tone {
        case .over: return CollapsedUsageBar.warningColor
        case .under, .even: return CollapsedUsageBar.antigravityColor
        case .unknown: return Color.secondary
        }
    }
    /// Today's box on the bar axis (mirrored in 残り).
    private var todayBox: ClosedRange<Double>? {
        pace.todayRange.map { r in
            let a = basis.position(usedShare: r.lowerBound), b = basis.position(usedShare: r.upperBound)
            return min(a, b)...max(a, b)
        }
    }
    private var tick: Double? { pace.elapsedPercent.map { basis.position(usedShare: $0) } }
    private var fillShare: Double { basis == .used ? pace.usedPercent : 100 - pace.usedPercent }

    var body: some View {
        VStack(alignment: .leading, spacing: UsageLayout.rowSpacing) {
            LimitHeader(label: pace.label, value: pace.valueText(basis))
            bar
                .frame(height: UsageLayout.detailBarHeight)
                .padding(.vertical, pace.elapsedPercent != nil && Self.markerStyle == .outline ? 2 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(pace.paceText(basis))
                    .foregroundStyle(pace.tone == .over && !blocked ? CollapsedUsageBar.warningColor : .secondary)
                if let t = pace.recoverText {
                    Text(t).foregroundStyle(.primary)
                }
                if let t = pace.todayText(basis) {
                    Text(t).foregroundStyle(pace.todayOver && !blocked ? CollapsedUsageBar.warningColor : .primary)
                }
                Text(pace.rangeText).foregroundStyle(.secondary)
                if showLegend {
                    Text(basis.directionText).font(UsageLayout.legendFont).foregroundStyle(.tertiary)
                }
            }
            .font(UsageLayout.captionFont)
            .lineLimit(1).minimumScaleFactor(0.85)
            .help(WeeklyPace.helpText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pace.label) \(pace.valueText(basis))、\(pace.paceText(basis))、\(pace.recoverText ?? pace.footerText)")
    }

    private var bar: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let t = tick, !blocked {
                        // Even-pace region: what an even spend would show now, on the same axis as the fill.
                        Capsule().fill(Color.primary.opacity(0.10)).frame(width: max(2, w * t / 100))
                    }
                    Capsule().fill(fill.opacity(0.85)).frame(width: max(2, w * fillShare / 100))
                    if pace.elapsedPercent != nil, !blocked {
                        ForEach(1..<pace.slices, id: \.self) { k in
                            Rectangle().fill(Color.primary.opacity(0.30))
                                .frame(width: 1, height: h)
                                .offset(x: w * Double(k) / Double(pace.slices) - 0.5)
                        }
                    }
                    if let r = todayBox, Self.markerStyle == .dim, !blocked {
                        let x0 = w * r.lowerBound / 100, x1 = w * r.upperBound / 100
                        Rectangle().fill(dimColor).frame(width: x0, height: h)
                        Rectangle().fill(dimColor).frame(width: max(0, w - x1), height: h).offset(x: x1)
                    }
                }
                .clipShape(Capsule())
                if let r = todayBox, Self.markerStyle != .dim, !blocked {
                    // Two-tone outline (light over dark) reads on green, orange, red and the empty track.
                    let x0 = w * r.lowerBound / 100, rw = w * (r.upperBound - r.lowerBound) / 100
                    RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.45), lineWidth: 3)
                        .frame(width: rw, height: h + 4).offset(x: x0)
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                        .frame(width: rw, height: h + 4).offset(x: x0)
                }
                if let t = tick, !blocked {
                    Rectangle().fill(Color.primary.opacity(0.85))
                        .frame(width: 1.5, height: h + 4)
                        .offset(x: min(max(w * t / 100 - 0.75, 0), w - 1.5))
                }
            }
        }
    }
}
