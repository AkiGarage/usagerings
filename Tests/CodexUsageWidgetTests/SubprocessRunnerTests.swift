import XCTest
@testable import CodexUsageWidget

final class SubprocessRunnerTests: XCTestCase {
    func testLargeStdoutCompletesWhileChildIsStreaming() throws {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/head"), timeout: 10)

        let result = try runner.runSync(["-c", "5242880", "/dev/zero"])

        XCTAssertEqual(result.stdout.count, 5_242_880)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testHangingChildTimesOutAndReturnsQuickly() throws {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeout: 1)
        let start = Date()

        let result = try runner.runSync(["30"])

        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.terminationStatus, 0)
    }

    func testImmediateExitReturnsOutput() throws {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/bin/echo"))

        let result = try runner.runSync(["synthetic-payload"])

        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "synthetic-payload\n")
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testConcurrentHangingRunsEachTimeOut() async throws {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeout: 1)
        let start = Date()

        let results = try await withThrowingTaskGroup(of: CodexUsageService.CommandResult.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await runner.run(["30"])
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.timedOut))
    }

    func testCancelledTaskTerminatesTheChildPromptly() async throws {
        let runner = SubprocessRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"), timeout: 20)
        let start = Date()
        let task = Task {
            try await runner.run(["30"])
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = try await task.value

        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertFalse(result.timedOut)
        XCTAssertNotEqual(result.terminationStatus, 0)
    }
}
