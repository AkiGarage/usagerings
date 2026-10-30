import SwiftUI

/// Weekly window vs. an even spend: used share of the week against elapsed share of the week.
struct WeeklyPace: Equatable {
    static let week: TimeInterval = 7 * 86_400
    let label: String
    let usedPercent: Double
    /// Elapsed share of the week, 0...100; nil when the reset time is unknown.
    let elapsedPercent: Double?
    let start: Date?
    let reset: Date?
    /// Why there is no marker: reset unknown, already passed, or farther than a week away.
    let unknownReason: String?

    init(label: String, limit: UsageLimit, now: Date) {
        self.label = label
        usedPercent = 100 - limit.clampedLeftPercent
        let reset = limit.resetAt ?? RingResetFormat.date(fromResetText: limit.resetText, now: now)
        if let reset, reset > now, reset.timeIntervalSince(now) <= Self.week {
            let start = reset.addingTimeInterval(-Self.week)
            self.reset = reset
            self.start = start
            elapsedPercent = min(max(now.timeIntervalSince(start) / Self.week * 100, 0), 100)
            unknownReason = nil
        } else {
            self.reset = nil; start = nil; elapsedPercent = nil
            unknownReason = reset == nil ? "リセット 不明" : reset! <= now ? "リセット 不明/要更新（時刻を過ぎました）" : "リセット 不明（1週間より先）"
        }
    }

    /// Day of the window that contains now (0...6): the 24h slices start at the last reset, not at midnight.
    var todayIndex: Int? {
        guard let e = elapsedPercent else { return nil }
        let i = Int(floor(e * 7 / 100 + 1e-9))
        return min(max(i, 0), 6)
    }
    /// Today's even-pace allowance as a share of the week: expected use at the start and at the end of today.
    var todayRange: ClosedRange<Double>? {
        todayIndex.map { Double($0) * 100 / 7 ... Double($0 + 1) * 100 / 7 }
    }
    var todayText: String? {
        guard let i = todayIndex, let r = todayRange else { return nil }
        return "今日の枠 \(Int(r.lowerBound.rounded()))〜\(Int(r.upperBound.rounded()))%（\(i + 1)/7日目）"
    }

    /// used - even share, in percentage points; positive means ahead of pace.
    var delta: Int? { elapsedPercent.map { Int((usedPercent - $0).rounded()) } }

    var paceText: String {
        guard let delta else { return "リセット不明・均等ペース不明" }
        let d = delta
        if d >= 3 { return "均等より+\(d)%使いすぎ" }
        if d <= -3 { return "余裕 \(d)%" }
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
    var rangeText: String { start == nil ? (unknownReason ?? "リセット 不明") : "\(Self.day(start)) → \(Self.day(reset))" }
    /// Bottom line: reset range plus today's allowance when known.
    var footerText: String { todayText.map { "\(rangeText) ・ \($0)" } ?? rangeText }

    /// Every weekly window of a list.
    static func all(_ windows: [UsageLimit], now: Date, label: (UsageLimit) -> String) -> [WeeklyPace] {
        windows.filter { ServiceRowModel.kind($0.title) == .week }.map { WeeklyPace(label: label($0), limit: $0, now: now) }
    }
}

/// Used-share bar with a vertical even-pace tick (like CLIProxy's "Quota windows"), plus a short verdict.
struct WeeklyPaceBar: View {
    let pace: WeeklyPace
    var compact = false

    /// Fixed blue: never the warning orange, independent of the system accent colour.
    static let todayColor = Color(red: 0.16, green: 0.47, blue: 0.96)
    enum MarkerStyle { case bracket, outline, dim }
    /// Chosen today marker; the others stay for preview comparison.
    nonisolated(unsafe) static var markerStyle: MarkerStyle = .outline
    @Environment(\.colorScheme) private var scheme
    private var dimColor: Color { (scheme == .dark ? Color.black : Color.white).opacity(0.55) }

    private var fill: Color {
        switch pace.tone {
        case .over: CollapsedUsageBar.warningColor
        case .under, .even: CollapsedUsageBar.antigravityColor
        case .unknown: Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(pace.label).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text("使用 \(Int(pace.usedPercent.rounded()))%").fontWeight(.semibold).monospacedDigit()
                Text(pace.paceText).foregroundStyle(pace.tone == .over ? CollapsedUsageBar.warningColor : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                ZStack(alignment: .leading) {
                  ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let e = pace.elapsedPercent {
                        // Even-pace region: what an even spend would have used by now.
                        Capsule().fill(Color.primary.opacity(0.10)).frame(width: max(2, w * e / 100))
                    }
                    Capsule().fill(fill.opacity(0.85)).frame(width: max(2, w * pace.usedPercent / 100))
                    if pace.todayRange != nil {
                        // Faint day dividers: the week split into 7 equal days from the last reset.
                        ForEach(1..<7, id: \.self) { k in
                            Rectangle().fill(Color.primary.opacity(0.30))
                                .frame(width: 1, height: h)
                                .offset(x: w * Double(k) / 7 - 0.5)
                        }
                    }
                    if let r = pace.todayRange, Self.markerStyle == .dim {
                        // Dim everything outside today so today's slice stands out on any fill.
                        let x0 = w * r.lowerBound / 100, x1 = w * r.upperBound / 100
                        Rectangle().fill(dimColor).frame(width: x0, height: h)
                        Rectangle().fill(dimColor).frame(width: max(0, w - x1), height: h).offset(x: x1)
                    }
                  }
                  .clipShape(Capsule())
                    if let r = pace.todayRange, Self.markerStyle == .outline {
                        // Two-tone outline (light over dark) reads on green, orange, red and the empty track.
                        let x0 = w * r.lowerBound / 100, rw = w * (r.upperBound - r.lowerBound) / 100
                        RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.45), lineWidth: 3)
                            .frame(width: rw, height: h + 4).offset(x: x0, y: 0)
                        RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                            .frame(width: rw, height: h + 4).offset(x: x0, y: 0)
                    }
                    if let e = pace.elapsedPercent {
                        Rectangle().fill(Color.primary.opacity(0.85))
                            .frame(width: 1.5, height: h + 4)
                            .offset(x: min(max(w * e / 100 - 0.75, 0), w - 1.5), y: 0)
                    }
                }
            }
            .frame(height: compact ? 8 : 9)
            if let r = pace.todayRange, Self.markerStyle == .bracket {
                // Today's even-pace range as a bracket under the bar: never overlaps the fill colour.
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let x0 = w * r.lowerBound / 100, rw = w * (r.upperBound - r.lowerBound) / 100
                    Path { p in
                        p.move(to: CGPoint(x: x0 + 0.75, y: 0)); p.addLine(to: CGPoint(x: x0 + 0.75, y: 5))
                        p.addLine(to: CGPoint(x: x0 + rw - 0.75, y: 5)); p.addLine(to: CGPoint(x: x0 + rw - 0.75, y: 0))
                    }
                    .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 6)
                .padding(.top, -1)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let t = pace.todayText {
                    Text(t).foregroundStyle(.primary).fontWeight(.medium)
                }
                Text(pace.rangeText).foregroundStyle(.secondary)
            }
            .monospacedDigit().fixedSize(horizontal: false, vertical: true)
            .padding(.top, pace.todayRange != nil && Self.markerStyle == .outline ? 3 : 0)
        }
        .font(.system(size: compact ? 11 : 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pace.label) 使用 \(Int(pace.usedPercent.rounded()))%、\(pace.paceText)、\(pace.footerText)")
    }
}
