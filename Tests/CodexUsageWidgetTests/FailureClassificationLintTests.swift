import XCTest
@testable import CodexUsageWidget

final class FailureClassificationLintTests: XCTestCase {
    private let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private func sourceFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    private func sourceText() throws -> String {
        try sourceFiles().map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    func testCommandAndParseFailuresNeverMapToOther() throws {
        var mappingCount = 0
        for file in try sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for body in failureReasonMappingBodies(in: text) {
                mappingCount += 1
                assertNoClassifierToOther(body: body, file: file)
            }
        }
        XCTAssertGreaterThanOrEqual(mappingCount, 2, "expected at least the service and proxy mappings to be scanned")
    }

    private func failureReasonMappingBodies(in text: String) -> [String] {
        var bodies: [String] = []
        var searchStart = text.startIndex
        while let declarationEnd = text.range(of: "UsageFailureReason", range: searchStart..<text.endIndex)?.upperBound {
            defer { searchStart = declarationEnd }
            let lineStart = text[..<declarationEnd].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[lineStart..<text.endIndex].components(separatedBy: "\n").first ?? ""
            let isMappingDeclaration = !line.contains("?")
                && (line.contains("-> UsageFailureReason") || line.contains("var "))
            guard isMappingDeclaration else { continue }
            guard let openBrace = text[declarationEnd...].firstIndex(of: "{"),
                  let body = braceBody(of: openBrace, in: text) else { continue }
            bodies.append(body)
        }
        return bodies
    }

    private func braceBody(of openBrace: String.Index, in text: String) -> String? {
        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: openBrace)..<index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func assertNoClassifierToOther(body: String, file: URL) {
        let lines = body.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let mentionsClassifier = line.contains("commandFailed") || line.contains("ParseError")
            guard mentionsClassifier else { continue }
            if line.contains(".other") {
                XCTFail("\(file.lastPathComponent): a command/parser failure maps to .other: \(line.trimmingCharacters(in: .whitespaces))")
                continue
            }
            for following in lines[(index + 1)...] {
                let startsNewArm = following.contains("case ") || following.contains("default")
                    || following.contains("if case") || following.contains("guard") || following.contains("}")
                if startsNewArm { break }
                if following.contains(".other") {
                    XCTFail("\(file.lastPathComponent): a command/parser failure maps to .other near: \(line.trimmingCharacters(in: .whitespaces))")
                    break
                }
            }
        }
    }

    func testFailedAccountsAlwaysCarryAFailureReason() throws {
        let text = try sourceText()
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "ProviderAccount(", range: searchRange) {
            let arguments = balancedArguments(after: range.upperBound, in: text)
            if arguments.contains("failureText:"), !arguments.contains("failureText: nil"),
               !arguments.contains("failureReason:"), !arguments.contains("取得中") {
                XCTFail("ProviderAccount sets failureText without failureReason: \(arguments.prefix(120))")
            }
            searchRange = range.upperBound..<text.endIndex
        }
    }

    private func balancedArguments(after index: String.Index, in text: String) -> String {
        var depth = 1
        var cursor = index
        while cursor < text.endIndex, depth > 0 {
            if text[cursor] == "(" { depth += 1 }
            if text[cursor] == ")" { depth -= 1 }
            cursor = text.index(after: cursor)
        }
        return String(text[index..<text.index(before: cursor)])
    }

    func testFailureReasonBehaviorKeepsProviderErrorsTransient() {
        XCTAssertEqual(MultiUsageService.failureReason(for: CodexUsageError.commandFailed(1, "x")), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: CodexUsageError.commandFailed(64, "x")), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: CodexUsageError.commandFailed(17, "x")).isTransient, true)
        XCTAssertEqual(MultiUsageService.failureReason(for: CodexUsageError.invalidJSON), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: MultiProviderParser.ParseError.notAnArray), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: MultiProviderParser.ParseError.emptyPayload), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: MultiProviderParser.ParseError.providerError), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: MultiProviderParser.ParseError.noWindows), .providerError)
        XCTAssertEqual(MultiUsageService.failureReason(for: CodexUsageError.commandFailed(-1, "failed to launch")), .launchFailure)
        XCTAssertTrue(MultiUsageService.failureReason(for: CodexUsageError.commandFailed(-1, "failed to launch")).isTransient)
    }

    func testLogoutMarkerDetection() {
        XCTAssertTrue(MultiUsageService.isLogoutMessage("Error: Not Logged In"))
        XCTAssertTrue(MultiUsageService.isLogout(stdout: Data(#"{"error":{"message":"401 unauthorized"}}"#.utf8), stderr: Data()))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("please log in again"))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("No credentials configured"))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("login required"))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("not authenticated"))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("upstream responded with status 401"))
        XCTAssertTrue(MultiUsageService.isLogoutMessage("HTTP/1.1 401 Unauthorized"))
        XCTAssertFalse(MultiUsageService.isLogoutMessage("HTTP 503 service unavailable"))
        XCTAssertFalse(MultiUsageService.isLogoutMessage("rate limit exceeded"))
        XCTAssertFalse(MultiUsageService.isLogoutMessage(#"{"usedTokens": 401, "requests": 401}"#))
        XCTAssertFalse(MultiUsageService.isLogoutMessage("used 4019 tokens in 40128 seconds"))
        XCTAssertFalse(MultiUsageService.isLogoutMessage(#"{"status": 1401, "code": 4013}"#))
        XCTAssertFalse(MultiUsageService.isLogout(stdout: Data(), stderr: Data()))
    }
}
