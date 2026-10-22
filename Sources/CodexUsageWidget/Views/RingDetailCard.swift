import AppKit
import Combine
import SwiftUI

/// Severity color for one limit window: red below 20%, amber up to 50%, green above.
enum RingCardSeverity: Equatable {
    case red
    case amber
    case green

    static func of(leftPercent: Double) -> RingCardSeverity {
        let percent = min(max(leftPercent, 0), 100)
        if percent < 20 { return .red }
        if percent <= 50 { return .amber }
        return .green
    }
}

/// Row label for one limit window: "5h" -> "5時間枠", "Weekly" -> "週の枠",
/// "ali***@e*** · Opus weekly" -> "Opus 枠". The account prefix is dropped
/// because the card title already names the account.
enum RingCardLabel {
    static func label(for title: String) -> String {
        var parts = title.components(separatedBy: " · ")
        if parts.count > 1, ServiceRowModel.accountPrefix(title) != nil { parts.removeFirst() }
        let window = parts.joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        let name = window
            .replacingOccurrences(of: #"\s*(·\s*)?(5[- ]?hours?|5h|weekly|week|7[- ]?days?|7d|daily|monthly)\s*$"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        if name != window, !name.isEmpty { return "\(name) 枠" }
        switch ServiceRowModel.kind(window) {
        case .five: return "5時間枠"
        case .week: return "週の枠"
        case .other: return window.lowercased().contains("month") ? "月の枠" : "\(window.isEmpty ? "その他" : window) 枠"
        }
    }
}

/// Reset-time parsing and JST display for the card. Parsing inverts
/// `UsageDurationFormat.resetText`, which producers emit in `TimeZone.current`;
/// the zone is injectable so tests and TZ-shifted runs stay deterministic.
enum RingResetFormat {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current
    static var tokyoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = tokyo
        return calendar
    }

    /// "Resets 10/22 14:00 (2d3h)" -> Date. The year is not in the text, so the
    /// candidate year closest to now wins (handles the new-year wrap).
    static func date(fromResetText text: String, now: Date, sourceTimeZone: TimeZone = .current) -> Date? {
        var payload = text.hasPrefix("Resets ") ? String(text.dropFirst("Resets ".count)) : text
        if let open = payload.firstIndex(of: "(") {
            payload = String(payload[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = sourceTimeZone
        formatter.dateFormat = "y/M/d HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceTimeZone
        let year = calendar.component(.year, from: now)
        var best: Date?
        var bestDistance = TimeInterval.greatestFiniteMagnitude
        for candidate in [year - 1, year, year + 1] {
            guard let date = formatter.date(from: "\(candidate)/\(payload)") else { continue }
            let distance = abs(date.timeIntervalSince(now))
            if distance < bestDistance {
                bestDistance = distance
                best = date
            }
        }
        return best
    }

    /// "14:30 JST（あと2時間10分）"; the M/d prefix appears once the reset
    /// crosses midnight in JST, and an elapsed reset reads 期限切れ.
    static func text(reset: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = tokyo
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tokyo
        formatter.dateFormat = calendar.isDate(reset, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return "\(formatter.string(from: reset)) JST（\(remaining(reset: reset, now: now))）"
    }

    private static func remaining(reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "期限切れ" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "あと\(days)日" + (hours > 0 ? "\(hours)時間" : "") }
        if hours > 0 { return "あと\(hours)時間" + (minutes > 0 ? "\(minutes)分" : "") }
        return "あと\(minutes)分"
    }
}

/// Pure card contents for one ring, including only fields the provider reported.
struct RingDetailCardModel: Equatable {
    struct Row: Equatable {
        let label: String
        let leftPercent: Double
        var severity: RingCardSeverity { RingCardSeverity.of(leftPercent: leftPercent) }
        var percentText: String { "残り \(Int(leftPercent.rounded()))%" }
    }

    /// "2026-10-28 20:13:47" -> "期限 10/28 20:13（時帯未確認）". Wall clock as sent; zone unknown.
    static func zoneUnverifiedText(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return "期限 \(raw)（時帯未確認）" }
        let d = parts[0].split(separator: "-"), t = parts[1].split(separator: ":")
        guard d.count == 3, t.count == 3, let m = Int(d[1]), let day = Int(d[2]) else { return "期限 \(raw)（時帯未確認）" }
        return "期限 \(m)/\(day) \(t[0]):\(t[1])（時帯未確認）"
    }

    struct TicketRow: Equatable, Identifiable {
        let id: Int
        let title: String?
        let status: String?
        let expiresText: String?
        let isGreyedOut: Bool

        var statusText: String? {
            switch status {
            case "available": isGreyedOut ? "期限切れ" : "使用可"
            case "used", "redeemed", "consumed": "使用済み"
            case "expired": "期限切れ"
            case let other?: other
            case nil: nil
            }
        }
    }

    struct Extras: Equatable {
        let creditsText: String?
        let availableCount: Int?
        let tickets: [TicketRow]
    }

    let title: String
    /// "14:30 JST（あと2時間10分）"; nil hides the reset line.
    let resetText: String?
    /// Which window the reset line belongs to ("5時間枠" etc.); the ring's own
    /// arc is the lowest window, which is not always the first row.
    let resetLabel: String?
    let rows: [Row]
    let extras: Extras?
    var ticketFailureText: String? = nil
    var blockText: String? = nil
    var stats: [ProviderStat] = []
    var failureText: String? = nil

    static func make(bar: CollapsedUsageBar, now: Date, sourceTimeZone: TimeZone = .current) -> RingDetailCardModel? {
        func windowLabel(_ window: UsageLimit) -> String {
            if let account = window.accountIndex, bar.id.hasPrefix("antigravity-\(account)-") {
                switch ServiceRowModel.kind(window.title) {
                case .five: return "5時間枠"
                case .week: return "週の枠"
                case .other: break
                }
            }
            return RingCardLabel.label(for: window.title)
        }
        let rows = bar.windows.map { Row(label: windowLabel($0), leftPercent: $0.clampedLeftPercent) }
        let codexExtras = bar.id == "codex" || bar.id.hasPrefix("codex-") ? bar.codexExtras : nil
        let tickets = sortedTicketRows(codexExtras?.tickets ?? [], now: now)
        let hasExtras = codexExtras?.creditsText != nil || codexExtras?.availableCount != nil || !tickets.isEmpty
        var extras = hasExtras
            ? Extras(creditsText: codexExtras?.creditsText, availableCount: codexExtras?.availableCount,
                     tickets: tickets)
            : nil
        var ticketFailureText: String?
        if bar.provider == .zai || bar.id == "zai", let inventory = bar.zaiResetTickets {
            switch inventory {
            case .unavailable:
                ticketFailureText = "リセット券を取得できません"
            case .loaded(let records):
                let sorted = records.enumerated().sorted {
                    $0.element.expiresAt == $1.element.expiresAt
                        ? $0.offset < $1.offset : $0.element.expiresAt < $1.element.expiresAt
                }
                let ticketRows = sorted.map { index, ticket in
                    TicketRow(id: index, title: ticket.title,
                              status: ticket.expiresAt <= now ? "expired" : (ticket.available ? "available" : "使用不可"),
                              expiresText: "期限 \(UsageDurationFormat.timestamp(ticket.expiresAt, now: now, calendar: RingResetFormat.tokyoCalendar)) JST",
                              isGreyedOut: !ticket.available || ticket.expiresAt <= now)
                }
                extras = Extras(creditsText: nil,
                                availableCount: records.filter { $0.available && $0.expiresAt > now }.count,
                                tickets: ticketRows)
            }
        }
        let blockText = bar.block.flatMap {
            $0.isActive(at: now) ? ClaudeRateLimitParser.cardLine(block: $0, now: now) : nil
        }
        guard !rows.isEmpty || extras != nil || ticketFailureText != nil || blockText != nil
            || !bar.stats.isEmpty || bar.failureText != nil else { return nil }
        let reset = bar.limit.flatMap { limit -> (label: String, text: String)? in
            guard let date = RingResetFormat.date(fromResetText: limit.resetText, now: now,
                                                  sourceTimeZone: sourceTimeZone) else { return nil }
            return (windowLabel(limit), RingResetFormat.text(reset: date, now: now))
        }
        return RingDetailCardModel(title: "\(bar.ringName) の詳細",
                                   resetText: reset?.text, resetLabel: reset?.label, rows: rows, extras: extras,
                                   ticketFailureText: ticketFailureText, blockText: blockText, stats: bar.stats,
                                   failureText: bar.failureText)
    }

    private static func sortedTicketRows(_ tickets: [CodexExtrasParser.Ticket], now: Date) -> [TicketRow] {
        tickets.enumerated().filter { _, ticket in
            ticket.title?.isEmpty == false || ticket.status != nil || ticket.expiresAt != nil
        }.sorted { lhs, rhs in
            switch (lhs.element.expiresAt, rhs.element.expiresAt) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map { index, ticket in
            return TicketRow(
                id: index,
                title: ticket.title,
                status: ticket.status,
                expiresText: ticket.expiresAt.map {
                    "期限 \(UsageDurationFormat.timestamp($0, now: now, calendar: RingResetFormat.tokyoCalendar)) JST"
                },
                isGreyedOut: ticket.status != "available" || (ticket.expiresAt.map { $0 < now } ?? false)
            )
        }
    }
}

/// Where the card landed relative to the ring (screen coordinates, origin bottom-left).
struct RingCardPlacement: Equatable {
    enum Edge: Equatable {
        case above
        case below
        case left
        case right
    }

    let frame: CGRect
    let edge: Edge

    /// Horizontal tabs open below the ring and flip above near the screen
    /// bottom; vertical tabs open to the right and flip left near the right
    /// edge. The cross axis clamps into visibleFrame.
    static func frame(ringRect: CGRect, cardSize: CGSize, visibleFrame: CGRect,
                      orientation: PanelOrientation, gap: CGFloat) -> RingCardPlacement {
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            min(max(value, lower), max(lower, upper))
        }
        let size = CGSize(width: max(0, cardSize.width), height: max(0, cardSize.height))
        if orientation == .vertical {
            let y = clamp(ringRect.midY - size.height / 2, visibleFrame.minY, visibleFrame.maxY - size.height)
            let right = ringRect.maxX + gap
            if right + size.width <= visibleFrame.maxX {
                return RingCardPlacement(frame: CGRect(x: right, y: y, width: size.width, height: size.height), edge: .right)
            }
            let left = ringRect.minX - gap - size.width
            return RingCardPlacement(frame: CGRect(x: left, y: y, width: size.width, height: size.height), edge: .left)
        }
        let x = clamp(ringRect.midX - size.width / 2, visibleFrame.minX, visibleFrame.maxX - size.width)
        let below = ringRect.minY - gap - size.height
        if below >= visibleFrame.minY {
            return RingCardPlacement(frame: CGRect(x: x, y: below, width: size.width, height: size.height), edge: .below)
        }
        let above = ringRect.maxY + gap
        return RingCardPlacement(frame: CGRect(x: x, y: above, width: size.width, height: size.height), edge: .above)
    }
}

/// Hover bookkeeping with injected time: enter shows and cancels a pending
/// hide, exit schedules one, fire performs the pending hide, so a direct hop
/// between rings switches cards without flicker.
struct RingHoverState: Equatable {
    /// Grace before the card hides after the pointer leaves the rings.
    static let hideDelay: TimeInterval = 0.25

    private(set) var visibleIndex: Int?
    private(set) var hideDeadline: TimeInterval?
    /// Ring under the cursor that yields no card; remembered so hovering the
    /// same data-less ring doesn't rebuild on every mouse move.
    private(set) var noCardIndex: Int?

    /// true when the card must appear for a new index.
    @discardableResult
    mutating func enter(_ index: Int, now: TimeInterval) -> Bool {
        hideDeadline = nil
        guard noCardIndex != index else { return false }
        noCardIndex = nil
        guard visibleIndex != index else { return false }
        visibleIndex = index
        return true
    }

    /// true when a delayed hide must be scheduled.
    mutating func exit(now: TimeInterval) -> Bool {
        guard visibleIndex != nil, hideDeadline == nil else { return false }
        hideDeadline = now + Self.hideDelay
        return true
    }

    /// true when the scheduled hide is due. Only the controller's timer calls
    /// this, and Task.sleep runs on its own clock that can sit a hair behind
    /// Date(), so a pending deadline always hides — comparing clocks here once
    /// stranded the card on screen when the timer woke a few µs early.
    mutating func fire() -> Bool {
        guard hideDeadline != nil else { return false }
        hideDeadline = nil
        visibleIndex = nil
        noCardIndex = nil
        return true
    }

    /// The ring under the cursor has no card to show: tear down but remember
    /// the ring so repeated moves over it stay cheap.
    mutating func markNoCard(_ index: Int) {
        noCardIndex = index
        visibleIndex = nil
        hideDeadline = nil
    }

    /// Immediate teardown (expanded mode, drag, panel teardown).
    mutating func reset() {
        visibleIndex = nil
        hideDeadline = nil
        noCardIndex = nil
    }
}

/// SwiftUI-visible highlight of the ring under the cursor (nil = none).
final class RingHighlightState: ObservableObject {
    @Published var barID: String?
}

/// Hover detail card: title, JST reset line, one severity bar per limit window.
struct RingDetailCardView: View {
    let model: RingDetailCardModel
    static let cardWidth: CGFloat = 224

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.title)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if let blockText = model.blockText {
                Text(blockText).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if let resetText = model.resetText {
                // The reset belongs to the ring's binding window, which the label names.
                Text("リセット" + (model.resetLabel.map { "（\($0)）" } ?? "") + " \(resetText)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(row.percentText).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.12))
                            Capsule().fill(color(for: row.severity))
                                .frame(width: max(2, proxy.size.width * row.leftPercent / 100))
                        }
                    }
                    .frame(width: 52, height: 4)
                }
            }
            if let failure = model.ticketFailureText {
                Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let failure = model.failureText {
                Text(failure).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.stats.enumerated()), id: \.offset) { _, stat in
                Text("\(stat.title): \(stat.valueText)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let extras = model.extras {
                Divider().opacity(0.35)
                if let creditsText = extras.creditsText {
                    extraLine(label: "クレジット", value: creditsText)
                }
                if let availableCount = extras.availableCount {
                    extraLine(label: "リセットチケット", value: "利用可能 \(availableCount)件")
                }
                ForEach(extras.tickets) { ticket in
                    VStack(alignment: .leading, spacing: 1) {
                        if let title = ticket.title, !title.isEmpty {
                            Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        }
                        let details = [ticket.statusText, ticket.expiresText].compactMap { $0 }.filter { !$0.isEmpty }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · "))
                                .font(.system(size: 10)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(ticket.isGreyedOut ? Color.secondary : Color.primary)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(width: Self.cardWidth, alignment: .topLeading)
        .background(AdaptiveGlass(
            shape: RoundedRectangle(cornerRadius: 11, style: .continuous),
            intensity: .hud
        ))
        .accessibilityElement(children: .combine)
    }

    private func extraLine(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.system(size: 10))
    }

    private func color(for severity: RingCardSeverity) -> Color {
        switch severity {
        case .red: CollapsedUsageBar.criticalColor
        case .amber: CollapsedUsageBar.warningColor
        case .green: CollapsedUsageBar.antigravityColor
        }
    }
}

/// Presents the hover card in its own pass-through panel so it can extend past
/// the small tab panel. Input stays with the tab; the card never takes events.
@MainActor
final class RingDetailCardController {
    /// Space between the ring and the card.
    static let placementGap: CGFloat = 6

    private struct Context {
        let bars: [CollapsedUsageBar]
        let layout: MultiCollapsedUsageView.Layout
        let orientation: PanelOrientation
        let size: CGSize
    }

    let highlight = RingHighlightState()
    /// The model currently on screen; nil while the card is hidden.
    private(set) var currentModel: RingDetailCardModel?
    /// Card panel content for tests; its identity survives a skipped rebuild.
    var cardContentViewForTesting: NSView? { cardPanel.contentView }
    private var state = RingHoverState()
    private var hideTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private weak var store: MultiUsageStore?
    private weak var preferences: PanelPreferences?
    private weak var presentation: EdgeTabPresentationState?
    /// Last hover sample, kept so a snapshot refresh can re-resolve the ring
    /// under the (stationary) pointer.
    private var lastPoint: NSPoint?
    private weak var lastHostingView: NSView?
    private let cardPanel: NSPanel

    init() {
        cardPanel = Self.makeCardPanel()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Bind the data sources; re-attaching just refreshes the observers.
    func attach(store: MultiUsageStore, preferences: PanelPreferences, presentation: EdgeTabPresentationState) {
        self.store = store
        self.preferences = preferences
        self.presentation = presentation
        cancellables.removeAll()
        presentation.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    if mode != .collapsed { self?.hide(immediately: true) }
                }
            }
            .store(in: &cancellables)
        store.$opacityHUDPercent
            .sink { [weak self] percent in
                MainActor.assumeIsolated {
                    if percent != nil { self?.hide(immediately: true) }
                }
            }
            .store(in: &cancellables)
        // Fresh data while the pointer rests on a ring: rebuild so the numbers
        // stay live and the card keeps pointing at the right account (rings can
        // appear, reorder, or lose their data between snapshots).
        store.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.refreshForDataChange(snapshot: snapshot) }
            }
            .store(in: &cancellables)
        // Ring geometry moves under the pointer: the computed placement is stale.
        // dropFirst: the current value arrives on subscribe and would hide a
        // card that is not even on screen yet.
        preferences.$orientation
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(immediately: true) }
            }
            .store(in: &cancellables)
        preferences.$barZoom
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(immediately: true) }
            }
            .store(in: &cancellables)
        preferences.$splitAntigravityAccounts
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(immediately: true) }
            }
            .store(in: &cancellables)
        preferences.$accountPreferences
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hide(immediately: true) }
            }
            .store(in: &cancellables)
    }

    /// The card must not outlive the tab panel leaving the screen.
    func watchTabPanel(_ panel: NSPanel) {
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: panel, queue: .main
            ) { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    if panel?.isVisible != true { self?.hide(immediately: true) }
                }
            })
        }
    }

    /// Point is in hosting-view coordinates (nil = pointer left the view).
    func mouseMoved(to point: NSPoint?, in hostingView: NSView) {
        lastPoint = point
        lastHostingView = hostingView
        guard let (context, index) = resolveRing(at: point, in: hostingView) else {
            scheduleHide()
            return
        }
        if state.enter(index, now: Date().timeIntervalSinceReferenceDate) {
            showCard(bar: context.bars[index], context: context, index: index, hostingView: hostingView)
        }
    }

    /// Demo-only (README screenshots): behave as if the pointer rests on `ring`.
    func showDemoCard(ring: Int, in hostingView: NSView) {
        guard let context = context(hostingView: hostingView),
              let frame = MultiCollapsedUsageView.ringFrame(index: ring, size: context.size, layout: context.layout,
                                                           count: context.bars.count,
                                                           orientation: context.orientation) else { return }
        let y = hostingView.isFlipped ? frame.midY : hostingView.bounds.height - frame.midY
        mouseMoved(to: NSPoint(x: frame.midX, y: y), in: hostingView)
    }

    /// Ring under a view-coordinate point with fresh bars (nil when the tab is
    /// not in its ring-showing state or the point misses every ring). Pass
    /// `snapshot` when reacting to `$snapshot`, which emits in willSet — the
    /// property itself still holds the previous value there.
    private func resolveRing(at point: NSPoint?, in hostingView: NSView,
                             snapshot: MultiUsageSnapshot? = nil) -> (Context, Int)? {
        guard let point, let context = context(hostingView: hostingView, snapshot: snapshot) else { return nil }
        // NSView points are bottom-left origin unless the view is flipped; ring hit-testing uses top-left.
        let y = hostingView.isFlipped ? point.y : hostingView.bounds.height - point.y
        guard let index = MultiCollapsedUsageView.ringIndex(at: CGPoint(x: point.x, y: y),
                                                            size: context.size,
                                                            layout: context.layout,
                                                            count: context.bars.count,
                                                            orientation: context.orientation) else { return nil }
        return (context, index)
    }

    /// Snapshot changed under the pointer: rebuild the card from the fresh bars
    /// at the pointer's ring, or hide when that ring no longer resolves. A ring
    /// that just gained data starts showing its card here too.
    private func refreshForDataChange(snapshot: MultiUsageSnapshot) {
        guard state.visibleIndex != nil || state.noCardIndex != nil else { return }
        guard let hostingView = lastHostingView,
              let (context, index) = resolveRing(at: lastPoint, in: hostingView, snapshot: snapshot) else {
            hide(immediately: true)
            return
        }
        state.reset()
        state.enter(index, now: Date().timeIntervalSinceReferenceDate)
        showCard(bar: context.bars[index], context: context, index: index, hostingView: hostingView)
    }

    /// Immediate teardown or delayed hide, depending on `immediately`.
    func hide(immediately: Bool) {
        guard immediately else {
            scheduleHide()
            return
        }
        hideTask?.cancel()
        hideTask = nil
        state.reset()
        currentModel = nil
        highlight.barID = nil
        cardPanel.orderOut(nil)
    }

    /// Leave the rings: hide after the grace delay (a direct hop to the next ring cancels it).
    private func scheduleHide() {
        guard state.exit(now: Date().timeIntervalSinceReferenceDate) else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RingHoverState.hideDelay))
            guard !Task.isCancelled else { return }
            self?.fireHide()
        }
    }

    private func fireHide() {
        guard state.fire() else { return }
        currentModel = nil
        highlight.barID = nil
        cardPanel.orderOut(nil)
    }

    private func context(hostingView: NSView, snapshot: MultiUsageSnapshot? = nil) -> Context? {
        guard let store, let presentation, let preferences,
              presentation.mode == .collapsed,
              store.opacityHUDPercent == nil,
              hostingView.bounds.width > 0 else { return nil }
        let bars = CollapsedUsageBar.bars(for: snapshot ?? store.snapshot,
                                         splitAntigravityAccounts: preferences.splitAntigravityAccounts,
                                         accountPreferences: preferences.accountPreferences)
        guard !bars.isEmpty else { return nil }
        return Context(bars: bars,
                       layout: MultiCollapsedUsageView.layout(barZoom: preferences.barZoom,
                                                              menuBarThickness: presentation.menuBarHeight),
                       orientation: preferences.orientation,
                       size: hostingView.bounds.size)
    }

    private func showCard(bar: CollapsedUsageBar, context: Context, index: Int, hostingView: NSView) {
        guard let model = RingDetailCardModel.make(bar: bar, now: Date()) else {
            // No data for this ring: remember it so hover churn here stays cheap.
            state.markNoCard(index)
            hideTask?.cancel()
            hideTask = nil
            currentModel = nil
            highlight.barID = nil
            cardPanel.orderOut(nil)
            return
        }
        if model == currentModel, highlight.barID == bar.id, state.visibleIndex == index, cardPanel.isVisible {
            // Same card already on screen: skip the rebuild (no panel flicker on refresh).
            return
        }
        let host = NSHostingView(rootView: RingDetailCardView(model: model))
        // Unlike the tab host, the card measures itself: with sizingOptions []
        // fittingSize is .zero and the card could never be placed or shown.
        cardPanel.appearance = preferences?.appearance.nsAppearance
        cardPanel.contentView = host
        let cardSize = host.fittingSize
        guard cardSize.width > 0, cardSize.height > 0,
              let ringFrame = MultiCollapsedUsageView.ringFrame(index: index, size: context.size,
                                                                 layout: context.layout, count: context.bars.count,
                                                                 orientation: context.orientation),
              let window = hostingView.window else {
            hide(immediately: true)
            return
        }
        let viewRect = hostingView.isFlipped
            ? ringFrame
            : CGRect(x: ringFrame.minX, y: hostingView.bounds.height - ringFrame.maxY,
                     width: ringFrame.width, height: ringFrame.height)
        let screenRingRect = window.convertToScreen(hostingView.convert(viewRect, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screenRingRect
        let placement = RingCardPlacement.frame(ringRect: screenRingRect, cardSize: cardSize,
                                                visibleFrame: visibleFrame, orientation: context.orientation,
                                                gap: Self.placementGap)
        cardPanel.setFrame(placement.frame, display: false)
        cardPanel.orderFrontRegardless()
        highlight.barID = bar.id
        currentModel = model
    }

    private static func makeCardPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = TabPositioning.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        return panel
    }
}
