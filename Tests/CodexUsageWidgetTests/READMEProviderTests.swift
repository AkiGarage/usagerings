import XCTest
@testable import CodexUsageWidget

final class READMEProviderTests: XCTestCase {
    func testBothREADMEsListExactlyTheCurrentProviderNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = ProviderID.allCases.map(\.displayName).sorted()
        for filename in ["README.md", "README.ja.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "<!-- provider-table:start -->"), filename)
            let end = try XCTUnwrap(text.range(of: "<!-- provider-table:end -->", range: start.upperBound..<text.endIndex), filename)
            let rows = text[start.upperBound..<end.lowerBound].split(separator: "\n")
                .filter { $0.hasPrefix("|") }
            XCTAssertGreaterThanOrEqual(rows.count, 2, filename)
            let names = rows.dropFirst(2).map { row in
                row.split(separator: "|", omittingEmptySubsequences: false)[1]
                    .trimmingCharacters(in: .whitespaces)
            }
            XCTAssertEqual(names.sorted(), expected, "\(filename): update both provider tables when ProviderID changes")
        }
    }
}
