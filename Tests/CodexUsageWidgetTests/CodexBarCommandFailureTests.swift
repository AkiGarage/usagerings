import XCTest
@testable import CodexUsageWidget

final class CodexBarCommandFailureTests: XCTestCase {
    func testKnownProviderMessagesUseFixedJapaneseSummaries() {
        let cases: [(ProviderID, String, String)] = [
            (.kimi, "Kimi auth token is invalid or expired. Please refresh your token.",
             "Kimi: 認証期限切れ。CodexBarで再ログインが必要"),
            (.kimi, "Kimi AUTH TOKEN IS INVALID OR EXPIRED. secret-abc123",
             "Kimi: 認証期限切れ。CodexBarで再ログインが必要"),
            (.minimax, "MiniMax API error: no active token plan subscription",
             "MiniMax: 有効なプランがありません"),
            (.kimi, "Kimi foo bar secret-abc123", "Kimi provider error (provider, code 1)"),
            (.kimi, "no active token plan subscription", "Kimi provider error (provider, code 1)"),
            (.minimax, "auth token is invalid or expired", "MiniMax provider error (provider, code 1)")
        ]
        for (provider, message, expected) in cases {
            let stdout = Data("""
            [{"provider":"\(provider.rawValue)","error":{"kind":"provider","code":1,"message":"\(message)"}}]
            """.utf8)
            let error = CodexUsageError.commandFailure(exitCode: 1, stdout: stdout, stderr: Data(), provider: provider)
            XCTAssertEqual(error, .commandFailed(1, expected))
            XCTAssertFalse(error.localizedDescription.contains(message))
            XCTAssertFalse(error.localizedDescription.contains("secret-abc123"))
        }
    }

    func testCodexBar0500UsageExitCodeRemainsAPlainSanitizedFailure() {
        let error = CodexUsageError.commandFailure(
            exitCode: 64,
            stdout: Data(),
            stderr: Data("synthetic-sensitive-usage-error".utf8)
        )

        XCTAssertEqual(error, .commandFailed(64, "CodexBarCLI reported an error; details redacted"))
        XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-usage-error"))
    }

    func testStructuredStdoutPreservesProcessExitAndRedactsSensitiveFields() {
        let stdout = Data(
            """
            [
              {
                "provider": "synthetic-other",
                "error": { "code": "E_SYNTHETIC", "message": "ignore me" }
              },
              {
                "provider": "codex",
                "source": "oauth"
              },
              {
                "provider": "codex",
                "source": "auto",
                "account": { "email": "redacted-account-marker" },
                "error": {
                  "code": 1,
                  "kind": "provider",
                  "message": "redacted-provider-message redacted-path-marker"
                }
              }
            ]
            """.utf8
        )

        let error = CodexUsageError.commandFailure(
            exitCode: 4,
            stdout: stdout,
            stderr: Data()
        )

        XCTAssertEqual(error, .commandFailed(4, "Codex provider error (provider, code 1)"))
        let description = error.localizedDescription
        XCTAssertFalse(description.contains("redacted-provider-message"))
        XCTAssertFalse(description.contains("redacted-account-marker"))
        XCTAssertFalse(description.contains("redacted-path-marker"))
        XCTAssertFalse(description.contains("auto"))
    }

    func testStructuredStdoutAllowsMissingOptionalSourceKindAndCode() {
        let stdout = Data(
            """
            [
              {
                "provider": "codex",
                "error": { "message": "synthetic-sensitive-message" }
              }
            ]
            """.utf8
        )

        let error = CodexUsageError.commandFailure(
            exitCode: 1,
            stdout: stdout,
            stderr: Data("redacted-stderr-marker".utf8)
        )

        XCTAssertEqual(error, .commandFailed(1, "Codex provider error"))
        XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-message"))
        XCTAssertFalse(error.localizedDescription.contains("redacted-stderr-marker"))
    }

    func testMalformedStdoutRedactsNonemptyStderr() {
        let error = CodexUsageError.commandFailure(
            exitCode: 3,
            stdout: Data("not json".utf8),
            stderr: Data("redacted-person-marker redacted-credential-marker".utf8)
        )

        XCTAssertEqual(error, .commandFailed(3, "CodexBarCLI reported an error; details redacted"))
        XCTAssertFalse(error.localizedDescription.contains("redacted-person-marker"))
        XCTAssertFalse(error.localizedDescription.contains("redacted-credential-marker"))
    }

    func testMalformedStdoutAndEmptyStderrUseGenericSummary() {
        let error = CodexUsageError.commandFailure(
            exitCode: 2,
            stdout: Data("[]".utf8),
            stderr: Data()
        )

        XCTAssertEqual(error, .commandFailed(2, "CodexBarCLI returned no structured error details"))
    }

    func testUnsafeSourceAndKindTokensAreOmitted() {
        let stdout = Data(
            """
            [
              {
                "provider": "codex",
                "source": "syntheticSecretSource",
                "error": {
                  "code": 7,
                  "kind": "syntheticSecretKind",
                  "message": "synthetic-sensitive-message"
                }
              }
            ]
            """.utf8
        )

        let error = CodexUsageError.commandFailure(
            exitCode: 1,
            stdout: stdout,
            stderr: Data()
        )

        XCTAssertEqual(error, .commandFailed(1, "Codex provider error (code 7)"))
        XCTAssertFalse(error.localizedDescription.contains("syntheticSecretSource"))
        XCTAssertFalse(error.localizedDescription.contains("syntheticSecretKind"))
    }

    func testFetchUsesStructuredStdoutAndRedactsStderrWhilePreservingExitCode() {
        let stdout = Data(
            """
            [
              {
                "provider": "codex",
                "source": "oauth",
                "account": { "email": "redacted-account-marker" },
                "error": {
                  "code": 9,
                  "kind": "provider",
                  "message": "redacted-provider-message"
                }
              }
            ]
            """.utf8
        )
        let stderr = Data("redacted-stderr-marker".utf8)
        let service = CodexUsageService(commandRunner: { _ in
            CodexUsageService.CommandResult(
                terminationStatus: 17,
                stdout: stdout,
                stderr: stderr
            )
        })

        XCTAssertThrowsError(try service.fetch()) { error in
            XCTAssertEqual(error as? CodexUsageError, .commandFailed(17, "Codex provider error (provider, code 9)"))
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("redacted-account-marker"))
            XCTAssertFalse(description.contains("redacted-provider-message"))
            XCTAssertFalse(description.contains("redacted-stderr-marker"))
            XCTAssertFalse(description.contains("oauth"))
        }
    }
}
