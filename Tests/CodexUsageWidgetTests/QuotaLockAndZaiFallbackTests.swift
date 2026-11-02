import XCTest
@testable import CodexUsageWidget

final class QuotaLockAndZaiFallbackTests: XCTestCase {
    func testExhaustedFiveHourLocksUntilReset() {
        let now = Date()
        var w = UsageLimit(title: "5h", leftPercent: 0, resetText: "")
        w.resetAt = now.addingTimeInterval(7200)
        let block = CollapsedUsageBar.quotaBlock([w], now: now)
        XCTAssertEqual(block?.resetAt, w.resetAt)
        XCTAssertEqual(block?.kind, .session)
    }

    func testRemainingQuotaOrPastResetDoesNotLock() {
        let now = Date()
        var a = UsageLimit(title: "5h", leftPercent: 56, resetText: ""); a.resetAt = now.addingTimeInterval(3600)
        var b = UsageLimit(title: "5h", leftPercent: 0, resetText: ""); b.resetAt = now.addingTimeInterval(-60)
        XCTAssertNil(CollapsedUsageBar.quotaBlock([a, b], now: now))
    }

    func testNoTokenAccountsDetection() {
        let err = #"[{"provider":"zai","error":{"code":1,"message":"No token accounts configured for zai.","kind":"provider"},"source":"auto"}]"#
        XCTAssertTrue(MultiUsageService.isNoTokenAccounts(Data(err.utf8)))
        XCTAssertFalse(MultiUsageService.isNoTokenAccounts(Data(#"[{"provider":"zai","usage":{}}]"#.utf8)))
    }
}
