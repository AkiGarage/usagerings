import Foundation
import XCTest
@testable import CodexUsageWidget

/// An app started from a T3 Codex session inherited its shadow CODEX_HOME (no auth.json), and every
/// CodexBarCLI Codex run failed with "authentication required" (ring "?"). Only that shadow home is
/// unset; a usable or deliberate CODEX_HOME must reach CodexBar unchanged.
final class CodexHomeEnvironmentTests: XCTestCase {
    private let shadow = "/Users/someone/.t3/userdata/providers/codex/codex_8505e43f/shadow"

    func testT3ShadowHomeWithoutLoginIsUnsetForTheCodexRun() {
        let override = CodexUsageService.codexEnvironmentOverride(
            environment: ["CODEX_HOME": shadow, "HOME": "/Users/someone"], fileExists: { _ in false })
        XCTAssertEqual(override, ["CODEX_HOME": ""])
        XCTAssertNotNil(CodexUsageService.codexEnvironmentOverride(
            environment: ["CODEX_HOME": shadow + "/"], fileExists: { _ in false }))
    }

    func testShadowHomeThatHoldsALoginIsKept() {
        var checked: [String] = []
        let override = CodexUsageService.codexEnvironmentOverride(
            environment: ["CODEX_HOME": shadow], fileExists: { checked.append($0); return true })
        XCTAssertNil(override)
        XCTAssertEqual(checked, [shadow + "/auth.json"])
    }

    func testCustomOrKeychainBackedHomesAreNeverTouched() {
        for home in ["/Users/someone/.codex", "/Users/someone/work/codex-home", "/opt/codex",
                     "/Users/someone/.t3/userdata/providers/codex/x/shadow-copy",
                     "/Users/someone/.t3/userdata/providers/claude/x/shadow",
                     "/Users/someone/t3/userdata/providers/codex/x/shadow",
                     "/Users/someone/.t3/userdata/providers/codex/shadow",
                     ".t3/userdata/providers/codex/x/shadow/nested"] {
            XCTAssertNil(CodexUsageService.codexEnvironmentOverride(
                environment: ["CODEX_HOME": home], fileExists: { _ in false }), home)
        }
        XCTAssertNil(CodexUsageService.codexEnvironmentOverride(environment: [:], fileExists: { _ in false }))
        XCTAssertNil(CodexUsageService.codexEnvironmentOverride(environment: ["HOME": "/Users/someone"],
                                                                fileExists: { _ in false }))
    }

    /// The override really removes the variable from the child while the rest of the environment stays.
    func testOverrideRemovesOnlyCodexHomeFromTheChildProcess() throws {
        let key = "CODEX_HOME", marker = "USAGERINGS_TEST_MARKER"
        let saved = ProcessInfo.processInfo.environment[key]
        setenv(key, shadow, 1)
        setenv(marker, "kept", 1)
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
            unsetenv(marker)
        }
        let override = CodexUsageService.codexEnvironmentOverride(fileExists: { _ in false })
        let result = try SubprocessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/env"), timeout: 10,
                                          environment: override).runSync([])
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertFalse(lines.contains { $0.hasPrefix("CODEX_HOME=") })
        XCTAssertTrue(lines.contains("USAGERINGS_TEST_MARKER=kept"))
    }
}
