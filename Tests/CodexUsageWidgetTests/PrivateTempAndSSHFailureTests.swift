import Foundation
import XCTest
@testable import CodexUsageWidget

final class PrivateTempAndSSHFailureTests: XCTestCase {
    func testPrivateTempDirectoryIsOwnerOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try XCTUnwrap(PrivateTempPaths.file("x.json", base: base))
        PrivateTempPaths.writePrivately(Data("{}".utf8), to: file)
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
    }

    func testDefaultSnapshotURLsAvoidSharedTmp() throws {
        for url in try MultiAppPaths.defaultSnapshotURLs() {
            XCTAssertFalse(url.path.hasPrefix("/private/tmp"), url.path)
            XCTAssertFalse(url.path.hasPrefix("/tmp/"), url.path)
        }
    }

    func testPublisherWritesOwnerOnlyFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("sub/latest.json")
        try UsageSnapshotPublisher(urls: [url]).publish(UsageSnapshot(session: nil, weekly: nil, updatedAt: Date()))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testDescribeFailureHidesHostDetails() {
        let text = ClaudeRateLimitSSH.describeFailure(
            status: 255, stderr: Data("user@secret-host: Permission denied (publickey).".utf8))
        XCTAssertEqual(text, "SSH authentication failed")
        XCTAssertFalse(text.contains("secret-host"))
        XCTAssertEqual(ClaudeRateLimitSSH.describeFailure(status: 7, stderr: Data()), "SSH failed (exit 7)")
    }

    func testSSHFailureIsReportedAndClearedOnSuccess() async throws {
        let settings = try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "example.invalid"))
        let outcomes = Outcomes([ClaudeRemoteFetch(lines: [], failure: "SSH timed out"),
                                 ClaudeRemoteFetch(lines: ["ok"], failure: nil)])
        let enabled = SettingsFlag()
        let ssh = ClaudeRateLimitSSH(settings: { enabled.value ? settings : nil },
                                     fetchResult: { _ in await outcomes.next() })
        _ = await ssh.lines()
        let failure = await ssh.failureText()
        XCTAssertEqual(failure, "SSH timed out")
        // Disabling clears the reason; re-enabling fetches again and success leaves no reason.
        enabled.value = false
        _ = await ssh.lines()
        let cleared = await ssh.failureText()
        XCTAssertNil(cleared)
        enabled.value = true
        let lines = await ssh.lines()
        XCTAssertEqual(lines, ["ok"])
        let afterSuccess = await ssh.failureText()
        XCTAssertNil(afterSuccess)
    }

    func testMonitorExposesRemoteFailure() async {
        struct Failing: ClaudeRateLimitRemote {
            func lines() async -> [String] { [] }
            func failureText() async -> String? { "SSH host unreachable" }
        }
        let monitor = ClaudeRateLimitMonitor(accounts: [:], remote: Failing())
        let text = await monitor.remoteFailureText()
        XCTAssertEqual(text, "SSH host unreachable")
    }
}

private actor Outcomes {
    private var items: [ClaudeRemoteFetch]
    init(_ items: [ClaudeRemoteFetch]) { self.items = items }
    func next() -> ClaudeRemoteFetch { items.isEmpty ? ClaudeRemoteFetch(lines: [], failure: nil) : items.removeFirst() }
}

private final class SettingsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
