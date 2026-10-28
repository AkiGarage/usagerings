import XCTest
@testable import CodexUsageWidget

final class RetrySafetyTests: XCTestCase {
    func testInventoryRetriesTransportOnceButPostIsNeverRetried() async {
        let inventory = #"{"files":[{"provider":"claude","auth_index":"one"}]}"#
        let transport = RetryTransport(inventory: Data(inventory.utf8))
        let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
        let sections = await client.fetchSections()
        let counts = await transport.counts()
        XCTAssertEqual(counts.get, 2)
        XCTAssertEqual(counts.post, 1)
        XCTAssertEqual(sections[0].accounts.first?.failureReason, .transport)
        XCTAssertTrue(sections[0].windows.isEmpty)
    }

    func testAntigravityPostTimeoutDoesNotTryAnotherHost() async {
        let inventory = #"{"files":[{"provider":"antigravity","auth_index":"one","project_id":"fixture"}]}"#
        let transport = RetryTransport(inventory: Data(inventory.utf8))
        let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
        let sections = await client.fetchSections()
        let counts = await transport.counts()
        XCTAssertEqual(counts.post, 1)
        XCTAssertEqual(sections[1].accounts.first?.failureReason, .transport)
    }

    func testLaunchFailureRetriesOnlyOnce() async {
        let calls = LaunchCalls()
        let service = MultiUsageService(commandRunner: { args in
            if args[2] == "zai" {
                calls.increment()
                throw CodexUsageError.commandFailed(-1, "failed to launch")
            }
            return CodexUsageService.CommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        let result = await service.fetchAll()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.sections.first { $0.provider == .zai }?.failureReason, .launchFailure)
    }
}

private actor RetryTransport: CLIProxyTransport {
    let inventory: Data
    var gets = 0
    var posts = 0
    init(inventory: Data) { self.inventory = inventory }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.httpMethod == "POST" { posts += 1; throw URLError(.timedOut) }
        gets += 1
        if gets == 1 { throw URLError(.networkConnectionLost) }
        return (inventory, 200)
    }
    func counts() -> (get: Int, post: Int) { (gets, posts) }
}

private final class LaunchCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
}
