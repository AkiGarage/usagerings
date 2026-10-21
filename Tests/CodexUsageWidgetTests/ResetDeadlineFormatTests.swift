import XCTest
@testable import CodexUsageWidget

final class ResetDeadlineFormatTests: XCTestCase {
    func testAbsoluteTokyoDeadlineWithRemaining() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T02:00:00Z")! // 10/20 11:00 JST
        let reset = now.addingTimeInterval((2 * 24 + 3) * 3600)
        XCTAssertEqual(UsageDurationFormat.resetText(for: reset, now: now, timeZone: tokyo), "Resets 10/22 14:00 (2d3h)")
        XCTAssertEqual(UsageDurationFormat.resetText(for: now.addingTimeInterval(45 * 60), now: now, timeZone: tokyo),
                       "Resets 10/20 11:45 (45m)")
    }

    func testSectionsFollowTabletOrder() {
        let sections = [ProviderID.antigravity, .zai, .grok, .claude, .codex].map {
            ProviderSection(provider: $0, windows: [], stats: [], failureText: nil)
        }
        XCTAssertEqual(MultiUsageSnapshot.ordered(sections).map(\.provider), [.codex, .claude, .grok, .zai, .antigravity])
    }
}
