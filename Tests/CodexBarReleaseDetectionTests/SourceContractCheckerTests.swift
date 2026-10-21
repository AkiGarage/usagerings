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

    static let validSources: [String: Data] = [
        "docs/cli.md": Data("codexbar --version\ncodexbar --provider codex --format json".utf8),
        "Sources/CodexBarCLI/CLIPayloads.swift": Data("let provider: String; let usage: UsageSnapshot?; let error: ProviderErrorPayload?".utf8),
        "Sources/CodexBarCLI/CLIErrorReporting.swift": Data("JSONEncoder(); encodeJSON([payload]); printJSON([payload])".utf8),
        "Sources/CodexBarCLI/CLIExitCode.swift": Data("case success = 0; case failure = 1; case binaryNotFound = 2; case parseError = 3; case timeout = 4".utf8),
        "Sources/CodexBarCore/UsageFetcher.swift": Data("usedPercent primary secondary".utf8),
        "Tests/CodexBarTests/CLIOutputTests.swift": Data("cli error payload is JSON array".utf8)
    ]
}
