import XCTest
@testable import CodexBarReleaseDetection

final class SourceContractCheckerTests: XCTestCase {
    func testAcceptsPinnedCommandEnvelopeErrorAndLaneContracts() throws {
        XCTAssertNoThrow(try CodexBarSourceContractChecker().validate(Self.validSources))
    }

    func testMissingRequiredFileOrTokenFailsClosed() {
        var missingFile = Self.validSources
        missingFile.removeValue(forKey: "Sources/CodexBarCLI/CLIExitCode.swift")
        XCTAssertThrowsError(try CodexBarSourceContractChecker().validate(missingFile))

        var missingToken = Self.validSources
        missingToken["Sources/CodexBarCore/UsageFetcher.swift"] = Data("primary secondary".utf8)
        XCTAssertThrowsError(try CodexBarSourceContractChecker().validate(missingToken))
    }

    func testTokenOnlyInsideALineCommentIsRejected() {
        var commentedOut = Self.validSources
        let path = "Sources/CodexBarCore/UsageFetcher.swift"
        let source = String(decoding: Self.validSources[path]!, as: UTF8.self)
        commentedOut[path] = Data(
            """
            // removed: \(source)
            """.utf8
        )

        XCTAssertThrowsError(
            try CodexBarSourceContractChecker().validate(commentedOut),
            "A token that only survives in a // comment must not satisfy the contract"
        )
    }

    func testTokenOnlyInsideABlockCommentIsRejected() {
        var commentedOut = Self.validSources
        let path = "Sources/CodexBarCLI/CLIPayloads.swift"
        let source = String(decoding: Self.validSources[path]!, as: UTF8.self)
        commentedOut[path] = Data(
            """
            /* \(source) */
            """.utf8
        )

        XCTAssertThrowsError(
            try CodexBarSourceContractChecker().validate(commentedOut),
            "A token that only survives in a /* */ comment must not satisfy the contract"
        )
    }

    func testCommentedOutCLIExitCodeCasesAreRejected() {
        var commentedOut = Self.validSources
        commentedOut["Sources/CodexBarCLI/CLIExitCode.swift"] = Data(
            """
            enum CLIExitCode: Int32 {
                // case success = 0
                case failure = 1; case binaryNotFound = 2; case parseError = 3; case timeout = 4
            }
            """.utf8
        )

        XCTAssertThrowsError(try CodexBarSourceContractChecker().validate(commentedOut))
    }

    func testCommentMarkersInsideStringLiteralsDoNotHideCode() {
        var withURLs = Self.validSources
        withURLs["Sources/CodexBarCLI/CLIErrorReporting.swift"] = Data(
            """
            let base = "https://api.github.com/repos/steipete/CodexBar"
            let block = "/* not a comment */" + "// still code"
            JSONEncoder(); encodeJSON([payload]); printJSON([payload])
            """.utf8
        )

        XCTAssertNoThrow(try CodexBarSourceContractChecker().validate(withURLs))

        let source = #"let url = "https://example.com" // gone"# + "\nlet x = 1"
        let stripped = CodexBarSourceContractChecker.strippingComments(from: source)
        XCTAssertTrue(stripped.contains("https://example.com"))
        XCTAssertFalse(stripped.contains("gone"))
        XCTAssertTrue(stripped.contains("let x = 1"))
    }

    func testDocsContractIsNotCommentStripped() {
        var docs = Self.validSources
        // Markdown prose may legitimately contain comment syntax; only `.swift` paths
        // are stripped, so these tokens must still count for docs/cli.md.
        docs["docs/cli.md"] = Data(
            """
            /*
            codexbar --version --provider codex --format json
            """.utf8
        )

        XCTAssertNoThrow(
            try CodexBarSourceContractChecker().validate(docs),
            "Only .swift paths are comment stripped; docs keep their literal text"
        )
    }

    func testNormalSourceWithCommentsAroundCodeIsAccepted() {
        var commented = Self.validSources
        commented["Sources/CodexBarCLI/CLIErrorReporting.swift"] = Data(
            """
            /* Encodes the envelope. */
            // Kept stable for the contract check.
            JSONEncoder() // encodeJSON([payload]) stays below
            encodeJSON([payload]); printJSON([payload])
            """.utf8
        )
        commented["Sources/CodexBarCore/UsageFetcher.swift"] = Data(
            """
            // primary/secondary lane names must not change
            struct Usage { let primary: Double; let secondary: Double; let usedPercent: Double }
            """.utf8
        )

        XCTAssertNoThrow(try CodexBarSourceContractChecker().validate(commented))
    }

    func testCRLFSourcesWithLineCommentsAreAccepted() {
        // "\r\n" is one Swift Character; a line comment must still end at a CRLF.
        var crlf = Self.validSources
        crlf["Sources/CodexBarCLI/CLIErrorReporting.swift"] = Data(
            "// Encodes the envelope.\r\nJSONEncoder()\r\nencodeJSON([payload]) // stays\r\nprintJSON([payload])\r\n".utf8
        )
        crlf["Sources/CodexBarCore/UsageFetcher.swift"] = Data(
            "/* lanes\r\n */ // keep\r\nlet primary = 1; let secondary = 2; let usedPercent = 3\r\nlet s = \"a\"\r\n".utf8
        )

        XCTAssertNoThrow(try CodexBarSourceContractChecker().validate(crlf))
        XCTAssertEqual(
            CodexBarSourceContractChecker.strippingComments(from: "// c\r\ncode"),
            "\ncode"
        )
    }

    static let validSources: [String: Data] = [
        "docs/cli.md": Data("codexbar --version\ncodexbar --provider codex --format json".utf8),
        "Sources/CodexBarCLI/CLIPayloads.swift": Data("let provider: String; let usage: UsageSnapshot?; let error: ProviderErrorPayload?".utf8),
        "Sources/CodexBarCLI/CLIErrorReporting.swift": Data("JSONEncoder(); encodeJSON([payload]); printJSON([payload])".utf8),
        "Sources/CodexBarCLI/CLIExitCode.swift": Data("case success = 0; case failure = 1; case binaryNotFound = 2; case parseError = 3; case timeout = 4".utf8),
        "Sources/CodexBarCore/UsageFetcher.swift": Data("usedPercent primary secondary".utf8),
        "Tests/CodexBarTests/CLIOutputTests.swift": Data("cli error payload is JSON array".utf8)
    ]
}
