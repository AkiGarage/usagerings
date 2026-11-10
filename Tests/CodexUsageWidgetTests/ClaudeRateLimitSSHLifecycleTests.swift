import Foundation
import XCTest
@testable import CodexUsageWidget

/// Pending/dedup lifecycle of ClaudeRateLimitSSH.lines(): a concurrent call
/// with unchanged settings must share the in-flight fetch, and an immediate
/// repeat after completion must be served from the cache inside the debounce
/// window — never a second fetch.
final class ClaudeRateLimitSSHLifecycleTests: XCTestCase {
    func testConcurrentLinesShareOneFetchAndRepeatReturnsCache() async throws {
        let settings = try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "example.invalid"))
        let gate = FetchGate()
        await gate.holdNextCall()
        let ssh = ClaudeRateLimitSSH(settings: { settings },
                                     fetchResult: { _ in
                                         await gate.recordAndHold()
                                         return ClaudeRemoteFetch(lines: ["rate-limit-line"], failure: nil)
                                     })

        let first = Task { await ssh.lines() }
        // Wait (bounded) until the first fetch is recorded and held inside the gate.
        let deadline = Date().addingTimeInterval(5)
        while await gate.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Settle so the first call has stored its pending entry before the second starts.
        try await Task.sleep(nanoseconds: 200_000_000)

        let second = Task { await ssh.lines() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let countWhilePending = await gate.count

        await gate.openGate()
        let firstLines = await first.value
        let secondLines = await second.value

        XCTAssertEqual(countWhilePending, 1, "a concurrent call must reuse the pending fetch")
        XCTAssertEqual(firstLines, ["rate-limit-line"])
        XCTAssertEqual(secondLines, ["rate-limit-line"])

        // Immediate repeat within the 300 s debounce window: cached, no refetch.
        let again = await ssh.lines()
        XCTAssertEqual(again, ["rate-limit-line"])
        let finalCount = await gate.count
        XCTAssertEqual(finalCount, 1)
    }
}

/// Counts fetch invocations; the first call parks until the test opens the
/// gate so a second lines() call is guaranteed to land while the fetch is
/// still pending.
private actor FetchGate {
    private(set) var count = 0
    private var open = false
    private var holdNext = false

    func holdNextCall() { holdNext = true }

    func recordAndHold() async {
        count += 1
        let held = holdNext
        holdNext = false
        while held && !open {
            await Task.yield()
        }
    }

    func openGate() { open = true }
}
