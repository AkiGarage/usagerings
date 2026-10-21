import Foundation
import XCTest
@testable import CodexUsageWidget

final class ClaudeSSHSettingsTests: XCTestCase {
    func testDefaultsRequireExplicitOptInAndHost() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "UsageRingsSSHTests-\(UUID())"))
        XCTAssertNil(ClaudeSSHSettings.load(defaults: defaults))
        defaults.setVolatileDomain(["claudeRateLimitLinuxSSH": true], forName: UserDefaults.argumentDomain)
        XCTAssertNil(ClaudeSSHSettings.load(defaults: defaults))
        defaults.setVolatileDomain([ClaudeSSHSettings.enabledKey: true], forName: UserDefaults.argumentDomain)
        XCTAssertNil(ClaudeSSHSettings.load(defaults: defaults))
        defaults.setVolatileDomain([ClaudeSSHSettings.enabledKey: true,
                                   ClaudeSSHSettings.hostKey: "user@quota.example.invalid"],
                                  forName: UserDefaults.argumentDomain)
        XCTAssertEqual(ClaudeSSHSettings.load(defaults: defaults)?.host, "user@quota.example.invalid")
        defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
    }

    func testHostValidationRejectsOptionsAndShellSyntax() throws {
        for host in ["", " ", "-Fconfig", "-oProxyCommand=command", "host command", "host\ncommand",
                     "host;command", "$(command)", "`command`", "ssh://host", "host:22",
                     "user@", "@host", "user@@host", "user@-host", "../host", String(repeating: "a", count: 256)] {
            XCTAssertNil(ClaudeSSHSettings(enabled: true, host: host), host)
        }
        XCTAssertNil(ClaudeSSHSettings(enabled: false, host: "example.invalid"))
        for host in ["example.invalid", "192.0.2.1", "quota_host", "user@quota.example.invalid"] {
            let settings = try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "  \(host)  "))
            XCTAssertEqual(settings.host, host)
            XCTAssertEqual(Array(settings.arguments.suffix(3)), ["--", host, ClaudeRateLimitSSH.command])
            XCTAssertTrue(settings.arguments.contains("BatchMode=yes"))
            XCTAssertTrue(settings.arguments.contains("StrictHostKeyChecking=yes"))
        }
    }

    func testDisabledMakesNoRequestAndChangingHostInvalidatesCache() async throws {
        let settings = SettingsBox(nil)
        let calls = FetchRecorder()
        let ssh = ClaudeRateLimitSSH(settings: { settings.read() }, fetch: { await calls.fetch($0) })
        let disabled = await ssh.lines()
        XCTAssertTrue(disabled.isEmpty)
        let initialCount = await calls.count
        XCTAssertEqual(initialCount, 0)

        settings.set(try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "first.example.invalid")))
        let first = await ssh.lines()
        let cached = await ssh.lines()
        XCTAssertEqual(first, ["first.example.invalid"])
        XCTAssertEqual(cached, first)
        let cachedCount = await calls.count
        XCTAssertEqual(cachedCount, 1)

        settings.set(try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "second.example.invalid")))
        let second = await ssh.lines()
        XCTAssertEqual(second, ["second.example.invalid"])
        let changedCount = await calls.count
        XCTAssertEqual(changedCount, 2)
        settings.set(nil)
        let disabledAgain = await ssh.lines()
        XCTAssertTrue(disabledAgain.isEmpty)
        let disabledCount = await calls.count
        XCTAssertEqual(disabledCount, 2)
    }

    func testDisablingDuringRequestDiscardsReply() async throws {
        let settings = SettingsBox(try XCTUnwrap(ClaudeSSHSettings(enabled: true, host: "example.invalid")))
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let ssh = ClaudeRateLimitSSH(settings: { settings.read() }, fetch: { _ in
            entered.continuation.yield(())
            for await _ in resume.stream { break }
            return ["remote reply"]
        })
        let request = Task { await ssh.lines() }
        for await _ in entered.stream { break }
        settings.set(nil)
        resume.continuation.yield(())
        let result = await request.value
        XCTAssertTrue(result.isEmpty)
        entered.continuation.finish()
        resume.continuation.finish()
    }
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ClaudeSSHSettings?
    init(_ value: ClaudeSSHSettings?) { self.value = value }
    func read() -> ClaudeSSHSettings? { lock.withLock { value } }
    func set(_ value: ClaudeSSHSettings?) { lock.withLock { self.value = value } }
}

private actor FetchRecorder {
    private(set) var count = 0
    func fetch(_ settings: ClaudeSSHSettings) -> [String] {
        count += 1
        return [settings.host]
    }
}
