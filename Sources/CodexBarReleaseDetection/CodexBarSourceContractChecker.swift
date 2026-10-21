import Foundation

public enum CodexBarContractPaths {
    public static let all: [String] = [
        "Sources/CodexBarCLI/CLIErrorReporting.swift",
        "Sources/CodexBarCLI/CLIExitCode.swift",
        "Sources/CodexBarCLI/CLIPayloads.swift",
        "Sources/CodexBarCore/UsageFetcher.swift",
        "Tests/CodexBarTests/CLIOutputTests.swift",
        "docs/cli.md"
    ]
}

public struct CodexBarSourceContractChecker: Sendable {
    private static let requiredTokens: [String: [String]] = [
        "docs/cli.md": ["--version", "--provider codex", "--format json"],
        "Sources/CodexBarCLI/CLIPayloads.swift": ["let provider: String", "let usage:", "let error:"],
        "Sources/CodexBarCLI/CLIErrorReporting.swift": ["JSONEncoder", "encodeJSON([payload]", "printJSON([payload]"],
        "Sources/CodexBarCLI/CLIExitCode.swift": [
            "case success = 0", "case failure = 1", "case binaryNotFound = 2",
            "case parseError = 3", "case timeout = 4"
        ],
        "Sources/CodexBarCore/UsageFetcher.swift": ["usedPercent", "primary", "secondary"],
        "Tests/CodexBarTests/CLIOutputTests.swift": ["cli error payload is JSON array"]
    ]

    public init() {}

    public func validate(_ sources: [String: Data]) throws {
        guard Set(sources.keys) == Set(CodexBarContractPaths.all) else {
            throw ReleaseDetectionError.incompatibleContract
        }

        for path in CodexBarContractPaths.all {
            guard let data = sources[path], !data.isEmpty, data.count <= 2_097_152,
                  let text = String(data: data, encoding: .utf8),
                  let tokens = Self.requiredTokens[path],
                  tokens.allSatisfy(text.contains)
            else {
                throw ReleaseDetectionError.incompatibleContract
            }
        }
    }
}
