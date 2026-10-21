import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class RingDetailCardTests: XCTestCase {
    private let jst = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-10-21 12:00 JST.
    private var noonJST: Date { ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")! }

    // MARK: - RingCardSeverity

    func testSeverityThresholds() {
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 0), .red)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: -5), .red)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 19.9), .red)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 20), .amber)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 35), .amber)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 50), .amber)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 50.1), .green)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 100), .green)
        XCTAssertEqual(RingCardSeverity.of(leftPercent: 150), .green)
    }

    // MARK: - RingCardLabel

    func testCardRowLabels() {
        XCTAssertEqual(RingCardLabel.label(for: "5h"), "5時間枠")
        XCTAssertEqual(RingCardLabel.label(for: "Session"), "5時間枠")
        XCTAssertEqual(RingCardLabel.label(for: "ali***@e*** · 5h"), "5時間枠")
        XCTAssertEqual(RingCardLabel.label(for: "Weekly"), "週の枠")
        XCTAssertEqual(RingCardLabel.label(for: "ali***@e*** · Weekly"), "週の枠")
        XCTAssertEqual(RingCardLabel.label(for: "ali***@e*** · Opus weekly"), "Opus 枠")
        XCTAssertEqual(RingCardLabel.label(for: "ali***@e*** · Sonnet weekly"), "Sonnet 枠")
        XCTAssertEqual(RingCardLabel.label(for: "ali***@e*** · OAuth apps weekly"), "OAuth apps 枠")
        XCTAssertEqual(RingCardLabel.label(for: "Monthly"), "月の枠")
        XCTAssertEqual(RingCardLabel.label(for: "grok1***@x*** · Monthly"), "月の枠")
        XCTAssertEqual(RingCardLabel.label(for: "Gemini 4 Argon · weekly"), "Gemini 4 Argon 枠")
        XCTAssertEqual(RingCardLabel.label(for: "Five Hour Limit Remaining"), "5時間枠")
    }

    // MARK: - RingResetFormat

    func testResetDateParsesInSourceTimeZone() {
        let now = noonJST
        XCTAssertEqual(RingResetFormat.date(fromResetText: "Resets 10/21 18:00 (6h)", now: now, sourceTimeZone: jst),
                       ISO8601DateFormatter().date(from: "2026-10-21T09:00:00Z"))
        // The same text produced in UTC parses to a different instant.
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RingResetFormat.date(fromResetText: "Resets 10/21 18:00 (6h)", now: now, sourceTimeZone: utc),
                       ISO8601DateFormatter().date(from: "2026-10-21T18:00:00Z"))
        // Without the "Resets " prefix (resetShort style).
        XCTAssertEqual(RingResetFormat.date(fromResetText: "10/21 14:05 (2h5m)", now: now, sourceTimeZone: jst),
                       ISO8601DateFormatter().date(from: "2026-10-21T05:05:00Z"))
    }

    func testResetDatePicksNearestYearAcrossNewYear() {
        // 2026-12-31 23:30 JST; "1/1 01:30" must resolve to 2027, not 2026.
        let now = ISO8601DateFormatter().date(from: "2026-12-31T14:30:00Z")!
        XCTAssertEqual(RingResetFormat.date(fromResetText: "Resets 1/1 01:30 (2h)", now: now, sourceTimeZone: jst),
                       ISO8601DateFormatter().date(from: "2026-12-31T16:30:00Z"))
    }

    func testResetDateRejectsUnparseableText() {
        let now = noonJST
        for text in ["Reset pending", "Refreshing", "No data", "", "Resets soon", "2 available · next expires Nov 3"] {
            XCTAssertNil(RingResetFormat.date(fromResetText: text, now: now, sourceTimeZone: jst), text)
        }
    }

    func testResetTextFormatsJstWithRemaining() {
        let now = noonJST
        func text(_ interval: TimeInterval) -> String {
            RingResetFormat.text(reset: now.addingTimeInterval(interval), now: now)
        }
        XCTAssertEqual(text(2 * 3600 + 10 * 60), "14:10 JST（あと2時間10分）")
        XCTAssertEqual(text(45 * 60), "12:45 JST（あと45分）")
        XCTAssertEqual(text(3 * 3600), "15:00 JST（あと3時間）")
        XCTAssertEqual(text((2 * 24 + 3) * 3600), "10/23 15:00 JST（あと2日3時間）")
        XCTAssertEqual(text((2 * 24) * 3600), "10/23 12:00 JST（あと2日）")
        XCTAssertEqual(text(-60), "11:59 JST（期限切れ）")
    }

    func testResetTextUsesDayPrefixAcrossMidnightJst() {
        // 2026-10-21 23:30 JST; the reset crosses midnight so the M/d prefix appears.
        let now = ISO8601DateFormatter().date(from: "2026-10-21T14:30:00Z")!
        XCTAssertEqual(RingResetFormat.text(reset: now.addingTimeInterval(2 * 3600), now: now),
                       "10/22 01:30 JST（あと2時間）")
    }

    // MARK: - RingDetailCardModel

    func testCardModelBuildsTitleResetAndRows() {
        let now = noonJST
        let fiveHour = UsageLimit(title: "ali***@e*** · 5h", leftPercent: 30,
                                  resetText: "Resets 10/21 18:00 (6h)")
        let opus = UsageLimit(title: "ali***@e*** · Opus weekly", leftPercent: 70,
                              resetText: "Resets 10/23 12:00 (2d)")
        let bar = CollapsedUsageBar(id: "claude-0", label: "A", title: "Claude A 5h",
                                    providerColor: .white, limit: fiveHour, windows: [fiveHour, opus])
        let model = RingDetailCardModel.make(bar: bar, now: now, sourceTimeZone: jst)
        XCTAssertEqual(model?.title, "Claude A の詳細")
        XCTAssertEqual(model?.resetText, "18:00 JST（あと6時間）")
        // The reset belongs to the binding window, which the label names.
        XCTAssertEqual(model?.resetLabel, "5時間枠")
        XCTAssertEqual(model?.rows.map(\.label), ["5時間枠", "Opus 枠"])
        XCTAssertEqual(model?.rows.map(\.severity), [.amber, .green])
        XCTAssertEqual(model?.rows.map(\.percentText), ["残り 30%", "残り 70%"])
    }

    func testCardModelHidesMissingResetAndReturnsNilWithoutWindows() {
        let now = noonJST
        let window = UsageLimit(title: "5h", leftPercent: 10, resetText: "Reset pending")
        let pendingBar = CollapsedUsageBar(id: "codex", label: "C", title: "Codex", providerColor: .white,
                                           limit: window, windows: [window])
        let pending = RingDetailCardModel.make(bar: pendingBar, now: now, sourceTimeZone: jst)
        XCTAssertNotNil(pending)
        XCTAssertNil(pending?.resetText)
        XCTAssertNil(pending?.resetLabel)
        XCTAssertEqual(pending?.rows.first?.severity, .red)
        XCTAssertNil(pending?.extras)

        let empty = CollapsedUsageBar(id: "grok", label: "X", title: "Grok", providerColor: .white,
                                      limit: nil, windows: [])
        XCTAssertNil(RingDetailCardModel.make(bar: empty, now: now, sourceTimeZone: jst))

        let codexWithEmptyExtras = CollapsedUsageBar(id: "codex", label: "C", title: "Codex",
                                                     providerColor: .white, limit: nil, windows: [],
                                                     codexExtras: CodexExtrasParser.Extras.none)
        XCTAssertNil(RingDetailCardModel.make(bar: codexWithEmptyExtras, now: now, sourceTimeZone: jst))
    }

    func testCardModelFormatsTypedCodexExtrasInStableExpiryOrder() throws {
        func date(_ text: String) -> Date {
            ISO8601DateFormatter().date(from: text)!
        }
        func ticket(_ title: String, _ status: String?, _ expiry: Date?) -> CodexExtrasParser.Ticket {
            CodexExtrasParser.Ticket(title: title, status: status, resetType: nil,
                                     grantedAt: nil, expiresAt: expiry)
        }

        let extras = CodexExtrasParser.Extras(
            creditsText: "61,003 credits",
            availableCount: 2,
            ticketExpiries: [],
            tickets: [
                ticket("No expiry first", "available", nil),
                ticket("Later available", "available", date("2026-10-23T00:00:00Z")),
                ticket("Same-time used", "used", date("2026-10-22T00:00:00Z")),
                ticket("Early available", "available", date("2026-10-21T03:30:00Z")),
                ticket("Same-time available", "available", date("2026-10-22T00:00:00Z")),
                ticket("No expiry second", nil, nil),
                ticket("Expired available", "available", date("2026-10-21T02:59:00Z")),
                ticket("Later used", "used", date("2026-10-23T00:00:00Z")),
            ]
        )
        let bar = CollapsedUsageBar(id: "codex", label: "C", title: "Codex", providerColor: .white,
                                    limit: nil, windows: [], codexExtras: extras)

        let model = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: noonJST))
        XCTAssertEqual(model.extras?.creditsText, "61,003 credits")
        XCTAssertEqual(model.extras?.availableCount, 2)
        XCTAssertEqual(model.extras?.tickets.compactMap(\.title), Optional([
            "Expired available", "Early available", "Same-time used", "Same-time available",
            "Later available", "Later used", "No expiry first", "No expiry second",
        ]))
        XCTAssertEqual(model.extras?.tickets[0].expiresText, "期限 11:59 JST")
        XCTAssertEqual(model.extras?.tickets[1].expiresText, "期限 12:30 JST")
        XCTAssertEqual(model.extras?.tickets[2].expiresText, "期限 10/22 09:00 JST")
        XCTAssertNil(model.extras?.tickets[6].expiresText)
        XCTAssertEqual(model.extras?.tickets.map(\.isGreyedOut),
                       Optional([true, false, true, false, false, true, false, true]))
        XCTAssertEqual(model.extras?.tickets[0].statusText, "期限切れ")
        XCTAssertEqual(model.extras?.tickets[1].statusText, "使用可")
    }

    // MARK: - CollapsedUsageBar windows plumbing

    func testBarsCarryPerAccountWindowsForTheCard() {
        func claudeWindow(_ title: String, percent: Double, account: Int) -> UsageLimit {
            var limit = UsageLimit(title: title, leftPercent: percent, resetText: "Resets 10/21 18:00 (6h)")
            limit.accountIndex = account
            return limit
        }
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .claude, windows: [
                claudeWindow("a***@x*** · 5h", percent: 30, account: 0),
                claudeWindow("a***@x*** · Weekly", percent: 60, account: 0),
                claudeWindow("b***@y*** · 5h", percent: 50, account: 1),
            ], stats: [], failureText: nil),
        ], codexSnapshot: nil, updatedAt: Date())
        let bars = CollapsedUsageBar.bars(for: snapshot)
        XCTAssertEqual(bars.first { $0.id == "claude-0" }?.windows.map(\.title),
                       ["a***@x*** · 5h", "a***@x*** · Weekly"])
        XCTAssertEqual(bars.first { $0.id == "claude-1" }?.windows.map(\.title),
                       ["b***@y*** · 5h"])
        XCTAssertEqual(bars.first { $0.id == "claude-1" }?.limit?.title, "b***@y*** · 5h")
    }

    func testOnlyCodexBarCarriesOptionalCodexExtras() {
        let extras = CodexExtrasParser.Extras(creditsText: "5 credits", availableCount: 1,
                                              ticketExpiries: [], tickets: [])
        let snapshot = MultiUsageSnapshot(sections: [
            ProviderSection(provider: .claude, windows: [], stats: [], failureText: nil),
            ProviderSection(provider: .codex, windows: [], stats: [], failureText: nil,
                            codexExtras: extras),
        ], codexSnapshot: nil, updatedAt: noonJST)

        let bars = CollapsedUsageBar.bars(for: snapshot)
        XCTAssertEqual(bars.first { $0.id == "codex" }?.codexExtras, extras)
        XCTAssertTrue(bars.filter { $0.id != "codex" }.allSatisfy { $0.codexExtras == nil })

        let claudeWindow = UsageLimit(title: "5h", leftPercent: 50, resetText: "Reset pending")
        let nonCodexBar = CollapsedUsageBar(id: "claude-0", label: "A", title: "Claude A 5h",
                                            providerColor: .white, limit: claudeWindow,
                                            windows: [claudeWindow], codexExtras: extras)
        XCTAssertNil(RingDetailCardModel.make(bar: nonCodexBar, now: noonJST)?.extras)
    }

    // MARK: - RingCardPlacement

    func testPlacementHorizontalOpensBelowAndFlipsAboveNearBottom() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let card = CGSize(width: 224, height: 120)
        let ring = CGRect(x: 700, y: 700, width: 20, height: 20)
        let below = RingCardPlacement.frame(ringRect: ring, cardSize: card, visibleFrame: visible,
                                            orientation: .horizontal, gap: 6)
        XCTAssertEqual(below.edge, .below)
        XCTAssertEqual(below.frame.maxY + 6, ring.minY)
        XCTAssertEqual(below.frame.midX, ring.midX)

        let lowRing = CGRect(x: 700, y: 150, width: 20, height: 20)
        let above = RingCardPlacement.frame(ringRect: lowRing, cardSize: card, visibleFrame: visible,
                                            orientation: .horizontal, gap: 6)
        XCTAssertEqual(above.edge, .above)
        XCTAssertEqual(above.frame.minY - 6, lowRing.maxY)
        XCTAssertEqual(above.frame.midX, lowRing.midX)
    }

    func testPlacementHorizontalShiftsSidewaysAtScreenEdges() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let card = CGSize(width: 224, height: 120)
        let leftRing = CGRect(x: 8, y: 700, width: 20, height: 20)
        let left = RingCardPlacement.frame(ringRect: leftRing, cardSize: card, visibleFrame: visible,
                                           orientation: .horizontal, gap: 6)
        XCTAssertEqual(left.edge, .below)
        XCTAssertEqual(left.frame.minX, visible.minX)

        let rightRing = CGRect(x: 1484, y: 700, width: 20, height: 20)
        let right = RingCardPlacement.frame(ringRect: rightRing, cardSize: card, visibleFrame: visible,
                                            orientation: .horizontal, gap: 6)
        XCTAssertEqual(right.frame.maxX, visible.maxX)
    }

    func testPlacementVerticalOpensRightAndFlipsLeftNearRightEdge() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let card = CGSize(width: 224, height: 120)
        let ring = CGRect(x: 200, y: 400, width: 24, height: 256)
        let right = RingCardPlacement.frame(ringRect: ring, cardSize: card, visibleFrame: visible,
                                            orientation: .vertical, gap: 6)
        XCTAssertEqual(right.edge, .right)
        XCTAssertEqual(right.frame.minX - 6, ring.maxX)
        XCTAssertEqual(right.frame.midY, ring.midY)

        let edgeRing = CGRect(x: 1470, y: 400, width: 24, height: 256)
        let left = RingCardPlacement.frame(ringRect: edgeRing, cardSize: card, visibleFrame: visible,
                                           orientation: .vertical, gap: 6)
        XCTAssertEqual(left.edge, .left)
        XCTAssertEqual(left.frame.maxX + 6, edgeRing.minX)
        XCTAssertEqual(left.frame.midY, edgeRing.midY)
    }

    // MARK: - RingHoverState

    func testHoverStateShowsSwitchesAndDelaysHide() {
        var state = RingHoverState()
        XCTAssertTrue(state.enter(0, now: 0))
        XCTAssertFalse(state.enter(0, now: 1)) // same ring: card already shown
        XCTAssertTrue(state.enter(1, now: 2)) // direct hop switches without flicker
        XCTAssertTrue(state.exit(now: 3))
        XCTAssertFalse(state.exit(now: 3.1)) // one pending hide at a time
        XCTAssertFalse(state.enter(1, now: 3.2)) // re-entering the same ring cancels the hide
        XCTAssertFalse(state.fire()) // cancelled timer: nothing to hide
        XCTAssertTrue(state.exit(now: 4))
        XCTAssertTrue(state.fire()) // still-pending timer hides
        XCTAssertFalse(state.fire()) // nothing pending anymore
        XCTAssertTrue(state.enter(2, now: 6)) // shows again after the hide
        state.reset()
        XCTAssertFalse(state.fire())
        XCTAssertTrue(state.enter(2, now: 8))
    }

    func testHoverStateFireHidesEvenWhenTimerWakesEarly() {
        var state = RingHoverState()
        XCTAssertTrue(state.enter(0, now: 0))
        XCTAssertTrue(state.exit(now: 1)) // deadline 1.25
        // Task.sleep runs on its own clock and can wake a few µs before Date()
        // reaches the deadline; any fire while a hide is pending must hide, or
        // the stale deadline strands the card on screen.
        XCTAssertTrue(state.fire())
        XCTAssertFalse(state.fire())
        XCTAssertTrue(state.enter(0, now: 2)) // recoverable afterwards
    }

    func testHoverStateRemembersNoCardRingWithoutChurn() {
        var state = RingHoverState()
        XCTAssertTrue(state.enter(2, now: 0))
        state.markNoCard(2)
        XCTAssertFalse(state.enter(2, now: 1)) // same data-less ring: no rebuild
        XCTAssertFalse(state.exit(now: 2)) // nothing visible to hide
        XCTAssertTrue(state.enter(0, now: 3)) // another ring still shows
        XCTAssertEqual(state.visibleIndex, 0)
        XCTAssertNil(state.noCardIndex)
        state.reset()
        XCTAssertTrue(state.enter(2, now: 4)) // data can arrive later
    }

    // MARK: - Ring hit-testing

    func testRingIndexHitTestingHorizontal() {
        // content = 3*20 + 2*5 = 70 centered in width 92; rings at x 11-31, 36-56, 61-81, y 2-22.
        let layout = MultiCollapsedUsageView.Layout(tabHeight: 24, ringDiameter: 20, lineWidth: 3,
                                                    horizontalPadding: 10.8, fontSize: 7)
        let size = CGSize(width: 92, height: 24)
        func index(_ x: CGFloat, _ y: CGFloat) -> Int? {
            MultiCollapsedUsageView.ringIndex(at: CGPoint(x: x, y: y), size: size, layout: layout,
                                              count: 3, orientation: .horizontal)
        }
        XCTAssertEqual(index(11, 12), 0)
        XCTAssertEqual(index(30.9, 12), 0)
        XCTAssertEqual(index(46, 12), 1)
        XCTAssertEqual(index(80.9, 12), 2)
        XCTAssertNil(index(31.1, 12)) // gap between rings
        XCTAssertNil(index(33, 12)) // gap between rings
        XCTAssertNil(index(10.9, 12)) // leading margin
        XCTAssertNil(index(81.1, 12)) // trailing margin
        XCTAssertNil(index(21, 1.9)) // above rings
        XCTAssertNil(index(21, 22.1)) // below rings
        XCTAssertNil(index(-1, 12))
    }

    func testRingIndexHitTestingVertical() {
        let layout = MultiCollapsedUsageView.Layout(tabHeight: 24, ringDiameter: 20, lineWidth: 3,
                                                    horizontalPadding: 10.8, fontSize: 7)
        let size = CGSize(width: 24, height: 92)
        func index(_ x: CGFloat, _ y: CGFloat) -> Int? {
            MultiCollapsedUsageView.ringIndex(at: CGPoint(x: x, y: y), size: size, layout: layout,
                                              count: 3, orientation: .vertical)
        }
        XCTAssertEqual(index(12, 21), 0)
        XCTAssertEqual(index(12, 46), 1)
        XCTAssertEqual(index(12, 80.9), 2)
        XCTAssertNil(index(12, 81.1)) // trailing margin
        XCTAssertNil(index(12, 33)) // gap between rings
        XCTAssertNil(index(1.9, 21)) // left of rings
        XCTAssertNil(index(22.1, 21)) // right of rings
        XCTAssertEqual(MultiCollapsedUsageView.ringIndex(at: CGPoint(x: 12, y: 21), size: size,
                                                         layout: layout, count: 0, orientation: .vertical), nil)
    }

    // MARK: - RingDetailCardController

    @MainActor
    func testControllerHandlesExitWithoutContext() {
        let controller = RingDetailCardController()
        controller.mouseMoved(to: nil, in: NSView())
        XCTAssertNil(controller.highlight.barID)
        controller.hide(immediately: true)
        XCTAssertNil(controller.highlight.barID)
    }

    @MainActor
    func testControllerWithPlaceholderSnapshotShowsNothing() throws {
        let name = "RingDetailCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let store = MultiUsageStore(snapshotURLs: [])
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 24
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: store.snapshot,
                                                                  barZoom: 1, menuBarHeight: 24)
        let controller = RingDetailCardController()
        controller.attach(store: store, preferences: preferences, presentation: presentation)
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation,
                                                            preferences: preferences))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: presentation.size)
        host.layoutSubtreeIfNeeded()
        // Placeholder rings carry no windows, so hovering must not invent a card.
        controller.mouseMoved(to: NSPoint(x: presentation.size.width / 2, y: presentation.size.height / 2), in: host)
        XCTAssertNil(controller.highlight.barID)
        presentation.mode = .expanded // hides without crashing
        presentation.mode = .collapsed
    }

    @MainActor
    func testMultiPersonaHoverKeepsTabCollapsedSoRingsStayHoverable() {
        let delegate = AppDelegate(persona: MultiProviderPersona())
        delegate.handleTabHoverChanged(true)
        XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
        delegate.handleTabHoverChanged(false)
        XCTAssertEqual(delegate.tabPresentationModeForTesting, .collapsed)
    }

    @MainActor
    func testSnapshotRefreshRetiresCardWhenHoveredRingLosesData() async throws {
        var codexHasData = true
        let fixture = try await makeHoveredFixture {
            codexHasData ? Self.codexWindow(usedPercent: 19) : Self.codexFailure
        }
        XCTAssertEqual(fixture.controller.highlight.barID, "codex")

        codexHasData = false
        fixture.store.refresh()
        // The subscription must retire the card instead of showing stale numbers.
        try await waitUntil("card retires after the hovered ring loses data") {
            fixture.controller.highlight.barID == nil
        }
    }

    @MainActor
    func testSnapshotRefreshUpdatesCardValuesWhileHovering() async throws {
        var usedPercent = 19
        let fixture = try await makeHoveredFixture { Self.codexWindow(usedPercent: usedPercent) }
        XCTAssertEqual(fixture.controller.highlight.barID, "codex")
        XCTAssertEqual(fixture.controller.currentModel?.rows.first?.leftPercent, 81)

        usedPercent = 85
        fixture.store.refresh()
        try await waitUntil("card rebuilds with the fresh percentage") {
            fixture.controller.currentModel?.rows.first?.leftPercent == 15
        }
        XCTAssertEqual(fixture.controller.highlight.barID, "codex")
        XCTAssertEqual(fixture.controller.currentModel?.rows.first?.severity, .red)
    }

    @MainActor
    func testSnapshotRefreshShowsCardWhenNoDataRingGainsData() async throws {
        var codexHasData = false
        // bars(for:) keeps a window-less ring for a failed provider, so ring 0
        // is still codex while it has no data.
        let fixture = try await makeHoveredFixture {
            codexHasData ? Self.codexWindow(usedPercent: 19) : Self.codexFailure
        }
        XCTAssertEqual(fixture.controller.highlight.barID, nil)
        XCTAssertNil(fixture.controller.currentModel)

        codexHasData = true
        fixture.store.refresh()
        try await waitUntil("card appears once the ring gains data") {
            fixture.controller.highlight.barID == "codex"
        }
        XCTAssertNotNil(fixture.controller.currentModel)
    }

    @MainActor
    func testSnapshotRefreshWithUnchangedDataKeepsSameHostingView() async throws {
        let fixture = try await makeHoveredFixture { Self.codexWindow(usedPercent: 19) }
        XCTAssertEqual(fixture.controller.highlight.barID, "codex")
        let before = fixture.controller.cardContentViewForTesting

        fixture.store.refresh()
        // apply() clears isRefreshing and reassigns the snapshot in the same
        // main-actor turn, so the flag back at false means the snapshot sink
        // (and any card rebuild it decided on) has already run.
        try await waitUntil("refresh with unchanged data completes") { !fixture.store.isRefreshing }

        XCTAssertTrue(fixture.controller.cardContentViewForTesting === before)
    }

    /// Shared setup for the snapshot-refresh tests: store with a switchable
    /// codex payload, card controller attached, and the pointer resting on the
    /// codex ring (leftmost) in a real window. Teardown clears the defaults
    /// suite after the test, not when the helper returns.
    @MainActor
    private func makeHoveredFixture(codexJSON: @escaping () -> String) async throws
        -> (store: MultiUsageStore, controller: RingDetailCardController,
            host: NSHostingView<MultiEdgeTabView>, window: NSWindow, ringPoint: NSPoint) {
        let runner: CodexUsageService.CommandRunner = { arguments in
            let json: String
            switch arguments[2] {
            case "codex": json = codexJSON()
            case "zai": json = Self.zaiWindow
            default: json = Self.claudeWindow
            }
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
        }
        let store = MultiUsageStore(service: MultiUsageService(commandRunner: runner,
                                                               cliProxyClient: CLIProxyFixtures.client()),
                                    snapshotURLs: [])
        let name = "RingDetailCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let preferences = PanelPreferences(defaults: defaults)
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 24
        let controller = RingDetailCardController()
        controller.attach(store: store, preferences: preferences, presentation: presentation)

        store.refresh()
        // Probe claude, not codex: codex may legitimately arrive as a failure.
        try await waitUntil("snapshot sections populate") {
            store.snapshot.sections.first { $0.provider == .claude }?.windows.isEmpty == false
        }
        presentation.collapsedSize = MultiCollapsedUsageView.size(for: store.snapshot,
                                                                  barZoom: 1, menuBarHeight: 24)
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation,
                                                            preferences: preferences))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: presentation.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Hover the codex ring (leftmost); with data present the card shows.
        let ring = try XCTUnwrap(MultiCollapsedUsageView.ringFrame(
            index: 0, size: presentation.size,
            layout: MultiCollapsedUsageView.layout(barZoom: 1, menuBarThickness: 24),
            count: CollapsedUsageBar.bars(for: store.snapshot).count, orientation: .horizontal))
        let ringPoint = NSPoint(x: ring.midX, y: ring.midY)
        controller.mouseMoved(to: ringPoint, in: host)
        return (store, controller, host, window, ringPoint)
    }

    private func waitUntil(_ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("waitUntil timed out: \(message)", file: file, line: line)
    }

    private static func codexWindow(usedPercent: Int) -> String {
        #"[{"provider":"codex","usage":{"primary":null,"secondary":{"usedPercent":\#(usedPercent),"windowMinutes":10080,"resetsAt":"2026-10-22T06:38:56Z"}},"credits":{"remaining":61003.32,"balanceReadSucceeded":true}}]"#
    }

    private static let codexFailure = #"[{"provider":"codex","error":{"code":1,"kind":"provider","message":"synthetic-sensitive-message"}}]"#

    private static let zaiWindow = #"[{"provider":"zai","usage":{"primary":{"usedPercent":10,"windowMinutes":300,"resetsAt":"2026-10-16T15:52:28Z"},"secondary":null,"tertiary":null}}"#

    private static let claudeWindow = #"[{"provider":"claude","usage":{"primary":{"usedPercent":21,"windowMinutes":300,"resetsAt":"2026-10-16T14:39:59Z"},"secondary":{"usedPercent":36,"windowMinutes":10080,"resetsAt":"2026-10-21T16:59:59Z"}}}]"#
}
