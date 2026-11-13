import XCTest
@testable import CodexUsageWidget

@MainActor
final class StaleRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let idA = AccountID(digest: String(repeating: "a", count: 64))!
    private let idB = AccountID(digest: String(repeating: "b", count: 64))!

    private func limit(_ index: Int, reset: Date? = nil) -> UsageLimit {
        var value = UsageLimit(title: "5h", leftPercent: 42, resetText: "reset")
        value.accountIndex = index
        value.resetAt = reset
        return value
    }
    private func snapshot(_ sections: [ProviderSection], at time: Date) -> MultiUsageSnapshot {
        MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: time)
    }
    private func retain(_ fresh: [ProviderSection], previous: MultiUsageSnapshot, at time: Date) -> MultiUsageSnapshot {
        MultiUsageStore.retainingStaleValues(in: snapshot(fresh, at: time), previous: previous, now: time)
    }

    func testResetAndAgeExpireIndividuallyAcrossRepeatedFailures() {
        let original = snapshot([ProviderSection(provider: .zai, windows: [limit(0, reset: now.addingTimeInterval(10)), limit(0)], stats: [], failureText: nil)], at: now)
        let stamped = MultiUsageStore.retainingStaleValues(in: original, previous: nil, now: now)
        let failure = ProviderSection(provider: .zai, windows: [], stats: [], failureText: "timeout", failureReason: .timeout)
        let first = retain([failure], previous: stamped, at: now.addingTimeInterval(5))
        XCTAssertEqual(first.sections[0].windows.count, 2)
        let second = retain([failure], previous: first, at: now.addingTimeInterval(11))
        XCTAssertEqual(second.sections[0].windows.count, 1)
        let expired = retain([failure], previous: second, at: now.addingTimeInterval(UsageLimit.staleMaxAge))
        XCTAssertTrue(expired.sections[0].windows.isEmpty)
        XCTAssertFalse(expired.sections[0].isStale)
    }

    func testSharedFailuresKeepAntigravityFreshAndPreserveOtherStaleRules() {
        let providers: [ProviderID] = [.claude, .antigravity, .grok]
        let initial = snapshot(providers.map { ProviderSection(provider: $0, windows: [limit(0)], stats: [], failureText: nil) }, at: now)
        let stamped = MultiUsageStore.retainingStaleValues(in: initial, previous: nil, now: now)
        let transient = providers.map { ProviderSection(provider: $0, windows: [], stats: [], failureText: "transport error", failureReason: .transport) }
        let retained = retain(transient, previous: stamped, at: now.addingTimeInterval(1))
        XCTAssertTrue(retained.sections.filter { $0.provider != .antigravity }.allSatisfy { $0.isStale && $0.windows.count == 1 })
        XCTAssertEqual(retained.sections.first { $0.provider == .antigravity }, stamped.sections.first { $0.provider == .antigravity })
        for message in ["noQuota", "rejected key", "unverified peer", "missing project", "not installed", "parse fail", "logout"] {
            let failure = providers.map { ProviderSection(provider: $0, windows: [], stats: [], failureText: message, failureReason: message == "logout" ? .logout : .other) }
            let result = retain(failure, previous: stamped, at: now.addingTimeInterval(1))
            XCTAssertTrue(result.sections.filter { $0.provider != .antigravity || message == "logout" }.allSatisfy { $0.windows.isEmpty && !$0.isStale }, message)
            if message != "logout" {
                XCTAssertEqual(result.sections.first { $0.provider == .antigravity }, stamped.sections.first { $0.provider == .antigravity }, message)
            }
        }
    }

    func testAntigravityMixedAccountsDoNotHideStaleReadingInGroupedView() {
        let fresh = UsageLimit(title: "Gemini 4 Argon · 5h", leftPercent: 80, resetText: "reset")
        var old = UsageLimit(title: "Gemini 4 Argon · 5h", leftPercent: 42, resetText: "reset")
        old.accountIndex = 1
        let section = ProviderSection(provider: .antigravity, windows: [fresh, old], stats: [], failureText: "Some accounts unavailable",
                                      accounts: [ProviderAccount(index: 0, id: idA), ProviderAccount(index: 1, failureText: "network error", id: idB, isStale: true, failureReason: .transport)])
        let result = snapshot([section], at: now)
        let bars = CollapsedUsageBar.bars(for: result).filter { $0.provider == .antigravity && $0.limit != nil }
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.isStale), [false, true])
        XCTAssertTrue(bars[1].failureText?.contains("network error") == true)
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].failureText?.contains("Stale") ?? false)
        XCTAssertTrue(rows[1].failureText?.contains("network error") == true)
    }

    func testSharedFailureMarksEveryAntigravityAccountAndGroup() {
        var windows = [UsageLimit(title: "Gemini 4 Argon · 5h", leftPercent: 80, resetText: "reset"),
                       UsageLimit(title: "Gemini 3.8 Flash · 5h", leftPercent: 50, resetText: "reset")]
        var second = windows[0]; second.accountIndex = 1; windows.append(second)
        let section = ProviderSection(provider: .antigravity, windows: windows, stats: [], failureText: "transport error",
                                      accounts: [ProviderAccount(index: 0, id: idA), ProviderAccount(index: 1, id: idB)], isStale: true, failureReason: .transport)
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.failureText?.contains("Stale") == true && $0.failureText?.contains("transport error") == true })
        let bars = CollapsedUsageBar.bars(for: snapshot([section], at: now)).filter { $0.provider == .antigravity && $0.limit != nil }
        XCTAssertEqual(bars.count, 3)
        XCTAssertTrue(bars.allSatisfy { $0.isStale && $0.failureText?.contains("transport error") == true })
    }

    func testAccountRemappingLogoutAndDisplayIsolation() throws {
        let initial = ProviderSection(provider: .claude, windows: [limit(0), limit(1)], stats: [], failureText: nil,
                                      accounts: [ProviderAccount(index: 0, id: idA), ProviderAccount(index: 1, id: idB)])
        let stamped = MultiUsageStore.retainingStaleValues(in: snapshot([initial], at: now), previous: nil, now: now)
        let updated = ProviderSection(provider: .claude, windows: [limit(0)], stats: [], failureText: "Some accounts unavailable",
            accounts: [ProviderAccount(index: 0, id: idB), ProviderAccount(index: 1, failureText: "network error", id: idA, failureReason: .transport)])
        let result = retain([updated], previous: stamped, at: now.addingTimeInterval(1))
        XCTAssertEqual(result.sections[0].windows.map(\.accountIndex), [0, 1])
        XCTAssertEqual(result.sections[0].accounts.map(\.isStale), [false, true])
        let bars = CollapsedUsageBar.bars(for: result).filter { $0.provider == .claude }
        XCTAssertEqual(bars.map(\.isStale), [false, true])
        XCTAssertTrue(bars[1].failureText?.contains("network error") == true)
        let rows = ServiceRowModel.rows(for: result.sections[0])
        XCTAssertFalse(rows[0].failureText?.contains("Stale") ?? false)
        XCTAssertTrue(rows[1].failureText?.contains("network error") == true)
        XCTAssertTrue(rows[1].failureText?.contains("Stale") == true)
        var logout = updated
        logout.accounts[1].failureReason = .logout
        logout.accounts[1].failureText = "signed out"
        XCTAssertFalse(retain([logout], previous: stamped, at: now.addingTimeInterval(1)).sections[0].windows.contains { $0.accountIndex == 1 })
    }
}
