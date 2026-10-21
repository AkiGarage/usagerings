import SwiftUI

/// One row per service (G1): open-bottom gauge (outer = 5h, inner = weekly) plus labelled values.
struct ServiceRowModel: Identifiable {
    let id: String
    let name: String
    let color: Color
    var five: UsageLimit?
    var week: UsageLimit?
    var extras: [UsageLimit] = []
    var chips: [String] = []
    /// Masked account label when the service reports one (shown only if enabled).
    var account: String?
    var tickets: [String] = []
    var ticketCount: Int?
    var ticketExpiries: [Date] = []

    /// "リセットチケット ×3 · 期限 10/23 05:56 · 10/30 04:10 · 11/07 08:36" — available tickets, sorted by expiry.
    func ticketLine(withTimes: Bool) -> String? {
        let expiries: [String] = tickets.filter { $0.contains("使用可") }.compactMap { text in
            guard let r = text.range(of: "期限 ") else { return nil }
            let value = text[r.upperBound...].components(separatedBy: " · ")[0]
            return withTimes ? value : value.components(separatedBy: " ")[0]
        }
        guard let count = ticketCount ?? (expiries.isEmpty ? nil : expiries.count) else { return nil }
        return expiries.isEmpty ? "リセットチケット ×\(count)"
            : "リセットチケット ×\(count) · 期限 " + expiries.joined(separator: " · ")
    }
    var notes: [String] = []
    var failureText: String?

    /// Outer arc: 5h, else the weekly window, else the first other window.
    var primary: UsageLimit? { five ?? week ?? extras.first }
    /// Inner arc only when a 5h window carries the outer one.
    var inner: UsageLimit? { five != nil ? week : nil }
    var remainingExtras: [UsageLimit] { five == nil && week == nil ? Array(extras.dropFirst()) : extras }

    enum Kind { case five, week, other }
    /// Real titles include "5h", "Session", "Weekly", and Antigravity's
    /// "Five Hour Limit Remaining" / "Weekly Limit Remaining" / "Gemini 4 Argon Weekly Limit".
    static func kind(_ title: String) -> Kind {
        let last = (title.components(separatedBy: " · ").last?.trimmingCharacters(in: .whitespaces) ?? title).lowercased()
        if last == "5h" || last == "session" || last.hasSuffix(" 5h") || last.contains("five hour")
            || last.contains("5-hour") || last.contains("5 hour") { return .five }
        if last.contains("week") || last.contains("7-day") || last.contains("7 day") || last.contains("seven day") { return .week }
        return .other
    }

    /// Antigravity group name with any trailing window word removed ("Gemini weekly" -> "Gemini").
    static func groupName(_ title: String) -> String {
        let parts = title.components(separatedBy: " · ")
        if parts.count > 1 { return parts.dropLast().joined(separator: " · ") }
        let stripped = title.replacingOccurrences(of: #"\s*(5[- ]?hours?|5h|weekly|week|7[- ]?days?|7d|daily|monthly)\s*$"#,
                                                  with: "", options: [.regularExpression, .caseInsensitive])
        return stripped.isEmpty ? title : stripped
    }
    static func shortLabel(_ title: String) -> String {
        let last = title.components(separatedBy: " · ").last?.trimmingCharacters(in: .whitespaces) ?? title
        switch last {
        case "Monthly": return "月"
        case "Weekly": return "週"
        default: return last
        }
    }

    static func color(for provider: ProviderID, account: Int) -> Color {
        switch provider {
        case .codex: CollapsedUsageBar.codexColor
        case .claude: account == 0 ? CollapsedUsageBar.claudeAColor : CollapsedUsageBar.claudeBColor
        case .antigravity: CollapsedUsageBar.antigravityColor
        case .zai: CollapsedUsageBar.glmColor
        case .grok: CollapsedUsageBar.grokColor
        }
    }

    static func rows(for snapshot: MultiUsageSnapshot, showAccounts: Bool = false) -> [Self] {
        snapshot.sections.flatMap { rows(for: $0, showAccounts: showAccounts) }
    }

    /// "ali***@e*** · 5h" -> "ali***@e***" (masked labels only carry "***").
    static func accountPrefix(_ title: String) -> String? {
        let parts = title.components(separatedBy: " · ")
        guard parts.count > 1, parts[0].contains("***") || parts[0] == "Account" else { return nil }
        return parts[0]
    }

    static func rows(for section: ProviderSection, showAccounts: Bool = false) -> [Self] {
        let provider = section.provider
        // Group key: Claude per account, Antigravity per quota group, others one row.
        func key(_ limit: UsageLimit) -> String {
            switch provider {
            case .claude: return "\(limit.accountIndex ?? 0)"
            case .antigravity:
                return groupName(limit.title)
            default: return "main"
            }
        }
        var order: [String] = []
        var groups: [String: [UsageLimit]] = [:]
        for window in section.windows {
            let k = key(window)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(window)
        }
        if order.isEmpty { order = ["main"] }
        var rows: [Self] = order.map { k in
            let account = provider == .claude ? (Int(k) ?? 0) : 0
            let name: String
            switch provider {
            case .claude: name = "Claude \(String(UnicodeScalar(65 + min(account, 25))!))"
            case .antigravity: name = antigravityName(k)
            case .zai: name = "GLM"
            default: name = provider.displayName
            }
            var row = Self(id: "\(provider.rawValue)-\(k)", name: name, color: color(for: provider, account: account))
            row.account = (groups[k] ?? []).lazy.compactMap { accountPrefix($0.title) }.first
            for limit in groups[k] ?? [] {
                switch kind(limit.title) {
                case .five where row.five == nil: row.five = limit
                case .week where row.week == nil: row.week = limit
                default: row.extras.append(limit)
                }
            }
            return row
        }
        // Stats -> chips (Codex tickets / credits) or small notes; skip per-ticket expiry lines.
        for stat in section.stats {
            if stat.title.isEmpty || stat.title == "5h" { continue }
            if stat.title == "Account" { rows[0].account = rows[0].account ?? stat.valueText; continue }
            if stat.title == "Reset ticket" { rows[0].tickets.append(stat.valueText); continue }
            if stat.title == "Reset tickets updated" { continue }
            if stat.title == "Reset ticket expiry" {
                if let date = ISO8601DateFormatter().date(from: stat.valueText) { rows[0].ticketExpiries.append(date) }
                continue
            }
            if let prefix = accountPrefix(stat.title) {
                rows[0].account = rows[0].account ?? prefix
                let rest = stat.title.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                rows[0].notes.append("\(rest): \(stat.valueText)")
                continue
            }
            if stat.title == "Reset tickets" {
                rows[0].ticketCount = Int(stat.valueText.split(separator: " ").first ?? "")
            } else if stat.title == "Credits" {
                if stat.valueText != "Not readable" { rows[0].chips.append(stat.valueText.capitalizedFirst) }
            } else {
                rows[0].notes.append("\(stat.title): \(stat.valueText)")
            }
        }
        rows[0].ticketExpiries.sort()
        rows[0].failureText = section.failureText
        if !showAccounts { for i in rows.indices { rows[i].account = nil } }
        return rows
    }

    /// "2 available · next expires Nov 3" -> "リセットチケット ×2 · 期限 Nov 3"
    static func ticketChip(_ text: String) -> String {
        let count = text.split(separator: " ").first.map(String.init) ?? text
        if let range = text.range(of: "next expires ") {
            return "リセットチケット ×\(count) · 期限 \(text[range.upperBound...])"
        }
        return "リセットチケット ×\(count)"
    }

    static func antigravityName(_ name: String) -> String {
        if name.localizedCaseInsensitiveContains("argon") { return "Argon" }
        if name.caseInsensitiveCompare("Gemini Models") == .orderedSame { return "Gemini" }
        if name.caseInsensitiveCompare("Claude and GPT models") == .orderedSame { return "Claude/GPT" }
        if name.localizedCaseInsensitiveContains("claude") && name.localizedCaseInsensitiveContains("gpt") { return "Claude/GPT" }
        return name
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension UsageLimit {
    var percentInt: Int { Int(clampedLeftPercent.rounded()) }
    var shortReset: String { resetText.hasPrefix("Resets ") ? String(resetText.dropFirst(7)) : resetText }
}

enum GaugeStyle {
    static let lowColor = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x61 / 255)
    static func tint(_ base: Color, _ limit: UsageLimit?) -> Color {
        switch limit?.tone {
        case .warning: return CollapsedUsageBar.warningColor
        case .critical: return CollapsedUsageBar.criticalColor
        default: return base
        }
    }
}

/// ~230° arc open at the bottom (wide opening leaves room for the gap text).
struct GaugeArc: Shape {
    static let sweep: Double = 230
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(90 + (360 - Self.sweep) / 2),
                 endAngle: .degrees(90 + (360 - Self.sweep) / 2 + Self.sweep * max(0, min(1, fraction))), clockwise: false)
        return p
    }
}

struct G1Gauge: View {
    let row: ServiceRowModel
    var size: CGFloat = 60
    var body: some View {
        let outerW: CGFloat = 5.5, innerW: CGFloat = 3, gap: CGFloat = 2.2
        let p = row.primary
        ZStack {
            GaugeArc(fraction: 1).stroke(row.color.opacity(0.20), style: .init(lineWidth: outerW, lineCap: .round))
                .padding(outerW / 2)
            if let p {
                GaugeArc(fraction: p.clampedLeftPercent / 100)
                    .stroke(GaugeStyle.tint(row.color, p), style: .init(lineWidth: outerW, lineCap: .round))
                    .padding(outerW / 2)
            }
            if let w = row.inner {
                let inset = outerW + gap + innerW / 2
                GaugeArc(fraction: 1).stroke(Color.white.opacity(0.08), style: .init(lineWidth: innerW, lineCap: .round))
                    .padding(inset)
                GaugeArc(fraction: w.clampedLeftPercent / 100)
                    .stroke(GaugeStyle.tint(row.color, w).opacity(0.62), style: .init(lineWidth: innerW, lineCap: .round))
                    .padding(inset)
            }
            Text(p.map { "\($0.percentInt)" } ?? "–")
                .font(.system(size: size * 0.31, weight: .semibold)).monospacedDigit()
                .foregroundStyle(p.map { $0.clampedLeftPercent < 20 } == true ? GaugeStyle.lowColor : Color.primary)
                .offset(y: -size * 0.03)
            if let w = row.inner {
                Text("週\(w.percentInt)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ServiceRowView: View {
    let row: ServiceRowModel
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            G1Gauge(row: row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let account = row.account {
                        Text(account).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    ForEach(row.chips, id: \.self) { chip in
                        Text(chip).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if let five = row.five { valueLine(label: "5h", limit: five, outer: true) }
                else if row.week != nil { notReported("5h") }
                if let week = row.week { valueLine(label: "週", limit: week, outer: row.five == nil) }
                if row.five == nil && row.week == nil, let first = row.extras.first {
                    valueLine(label: ServiceRowModel.shortLabel(first.title), limit: first, outer: true)
                }
                ForEach(Array(row.remainingExtras.enumerated()), id: \.offset) { _, extra in extraBar(extra) }
                if !row.ticketExpiries.isEmpty {
                    TicketList(expiries: row.ticketExpiries)
                        .padding(.top, 4)
                        .help(row.tickets.joined(separator: "\n"))
                } else if let line = row.ticketLine(withTimes: true) {
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .minimumScaleFactor(0.7).help(row.tickets.joined(separator: "\n"))
                }
                ForEach(row.notes, id: \.self) { note in
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = row.failureText {
                    Text(failure).font(.system(size: 11)).foregroundStyle(GaugeStyle.lowColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
        .accessibilityElement(children: .combine)
    }

    private func valueLine(label: String, limit: UsageLimit, outer: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().strokeBorder(row.color.opacity(outer ? 1 : 0.6), lineWidth: outer ? 3 : 1.8)
                .frame(width: outer ? 10 : 8, height: outer ? 10 : 8).frame(width: 12)
            Text(label).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            Text("\(limit.percentInt)%").fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(limit.clampedLeftPercent < 20 ? GaugeStyle.lowColor : Color.primary)
                .frame(width: 40, alignment: .trailing)
            Text("リセット \(limit.shortReset)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private func notReported(_ label: String) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            Text(label).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            Text("枠なし").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.font(.system(size: 12))
    }

    private func extraBar(_ limit: UsageLimit) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 1)
            Text(ServiceRowModel.shortLabel(limit.title)).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 22, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(GaugeStyle.tint(row.color, limit))
                        .frame(width: proxy.size.width * limit.clampedLeftPercent / 100)
                }
            }.frame(height: 3)
            Text("\(limit.percentInt)% · \(limit.shortReset)").foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.system(size: 11))
    }
}

/// One calm rounded row per usable reset ticket: 「リセット 1」 … 「10/23 05:56 · あと2日」 (JST, sorted).
struct TicketList: View {
    let expiries: [Date]
    var now: Date = Date()

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "期限切れ" }
        if seconds < 3600 { return "あと\(max(1, Int(seconds / 60)))分" }
        if seconds < 86_400 { return "あと\(Int(seconds / 3600))時間" }
        return "あと\(Int(seconds / 86_400))日"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(expiries.enumerated()), id: \.offset) { index, date in
                HStack(spacing: 6) {
                    Text("リセット \(index + 1)").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(Self.stamp(date)).foregroundStyle(.secondary).monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(Self.relative(date, now: now)).fontWeight(.semibold).foregroundStyle(.primary).monospacedDigit()
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
        }
    }
}
