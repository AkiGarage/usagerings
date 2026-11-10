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
                  let tokens = Self.requiredTokens[path]
            else {
                throw ReleaseDetectionError.incompatibleContract
            }

            let searchable = path.hasSuffix(".swift")
                ? Self.strippingComments(from: text)
                : text
            guard tokens.allSatisfy(searchable.contains) else {
                throw ReleaseDetectionError.incompatibleContract
            }
        }
    }

    /// Removes `//` line comments and `/* ... */` block comments from Swift source so
    /// required tokens must survive in code, not only in prose. String literals are
    /// copied through untouched so a `//` inside a URL does not start a comment.
    /// This is a small scanner, not a full Swift lexer; it is aimed at ordinary
    /// compilable source and deliberately errs toward stripping too much.
    static func strippingComments(from text: String) -> String {
        let characters = Array(text)
        var stripped = String()
        stripped.reserveCapacity(characters.count)
        var index = 0

        while index < characters.count {
            let current = characters[index]

            if current == "/", Self.character(characters, at: index + 1) == "/" {
                while index < characters.count, !characters[index].isNewline {
                    index += 1
                }
                // Preserve a separator so tokens on either side cannot fuse together.
                // isNewline: "\r\n" is one Character, so CRLF files must not be compared to "\n".
                if index < characters.count {
                    stripped.append("\n")
                    index += 1
                } else {
                    stripped.append(" ")
                }
                continue
            }

            if current == "/", Self.character(characters, at: index + 1) == "*" {
                index += 2
                var depth = 1
                while index < characters.count, depth > 0 {
                    if characters[index] == "/", Self.character(characters, at: index + 1) == "*" {
                        depth += 1
                        index += 2
                    } else if characters[index] == "*", Self.character(characters, at: index + 1) == "/" {
                        depth -= 1
                        index += 2
                    } else {
                        if characters[index].isNewline {
                            stripped.append("\n")
                        }
                        index += 1
                    }
                }
                stripped.append(" ")
                continue
            }

            if current == "\"" {
                let isMultiline = Self.character(characters, at: index + 1) == "\""
                    && Self.character(characters, at: index + 2) == "\""
                let terminator = isMultiline ? "\"\"\"" : "\""
                stripped.append(contentsOf: terminator)
                index += terminator.count

                var escaped = false
                while index < characters.count {
                    let literalCharacter = characters[index]
                    stripped.append(literalCharacter)
                    index += 1
                    if escaped {
                        escaped = false
                    } else if literalCharacter == "\\" {
                        escaped = true
                    } else if !isMultiline, literalCharacter.isNewline {
                        break
                    } else if isMultiline,
                              literalCharacter == "\"",
                              Self.character(characters, at: index) == "\"",
                              Self.character(characters, at: index + 1) == "\""
                    {
                        stripped.append(contentsOf: "\"\"")
                        index += 2
                        break
                    } else if !isMultiline, literalCharacter == "\"" {
                        break
                    }
                }
                continue
            }

            stripped.append(current)
            index += 1
        }

        return stripped
    }

    private static func character(_ characters: [Character], at index: Int) -> Character? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }
}
