import XCTest

final class ResetWindowSourceLintTests: XCTestCase {
    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [(String, String)] {
        let files = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testWindowLengthChecksNeverUseExactPeriodWithoutSlack() throws {
        let banned = try NSRegularExpression(pattern: #"timeIntervalSince\([^)]*\)\s*<=\s*(period|WeeklyPace\.week|WeeklyPace\.fiveHours|Self\.week|Self\.fiveHours)\s*[{,)]"#)
        for (name, text) in try swiftSources() {
            let hits = banned.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(hits, 0, "\(name): an untouched window resets exactly one period after the fetch; compare against period + WeeklyPace.freshWindowSlack")
        }
    }

    func testRetiredCurrentPeriodLabelStaysRetired() throws {
        for (name, text) in try swiftSources() {
            XCTAssertFalse(text.contains("今の期間"), "\(name): 今の期間 was replaced by the あと…で回復 line (Aki t1742u)")
        }
    }
}
