import XCTest
import os
@testable import CodexUsageWidget

final class RetrySafetyTests: XCTestCase {
    func testLaunchFailureRetriesOnlyOnce() async {
        let calls = LaunchCalls()
        let service = MultiUsageService(commandRunner: { args in
            if args[2] == "zai" {
                calls.increment()
                throw CodexUsageError.commandFailed(-1, "failed to launch")
            }
            return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        })
        let result = await service.fetchAll()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.sections.first { $0.provider == .zai }?.failureReason, .launchFailure)
    }

    func testCliOnlyProvidersRetryLaunchFailureOnceWithCliSource() async {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let service = MultiUsageService(commandRunner: { args in
            if args[2] == "grok" || args[2] == "antigravity" {
                calls.withLock { $0.append(args) }
                throw CodexUsageError.commandFailed(-1, "failed to launch")
            }
            return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        })
        let result = await service.fetchAll()
        let recorded = calls.withLock { $0 }
        XCTAssertEqual(recorded.filter { $0[2] == "grok" }.count, 2)
        XCTAssertEqual(recorded.filter { $0[2] == "antigravity" }.count, 2)
        XCTAssertTrue(recorded.allSatisfy { $0.contains("--source") && $0[$0.firstIndex(of: "--source")! + 1] == "cli" })
        XCTAssertEqual(result.sections.first { $0.provider == .grok }?.failureReason, .launchFailure)
    }
}

private final class LaunchCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
