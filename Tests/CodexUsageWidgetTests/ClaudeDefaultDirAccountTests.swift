import XCTest
@testable import CodexUsageWidget

final class ClaudeDefaultDirAccountTests: XCTestCase {
    private func home(main: String?, a: String, b: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func write(_ path: String, _ email: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": email]]).write(to: url)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let main { try write(".claude.json", main) }
        try write(".claude-a/.claude.json", a)
        try write(".claude-b/.claude.json", b)
        return root
    }

    func testDefaultDirSignedInToBMapsToB() throws {
        let h = try home(main: "B@x.com", a: "a@x.com", b: "b@x.com")
        let acc = ClaudeRateLimitMonitor.accounts(home: h)
        XCTAssertEqual(acc[0]?.map(\.lastPathComponent), ["projects"])
        XCTAssertTrue(acc[1]!.contains(h.appendingPathComponent(".claude/projects")))
        XCTAssertFalse(acc[0]!.contains(h.appendingPathComponent(".claude/projects")))
    }

    func testDefaultDirSignedInToAMapsToA() throws {
        let h = try home(main: "a@x.com", a: "a@x.com", b: "b@x.com")
        XCTAssertEqual(ClaudeRateLimitMonitor.defaultDirSlot(home: h), 0)
    }

    func testUnknownDefaultDirIsIgnored() throws {
        let h = try home(main: nil, a: "a@x.com", b: "b@x.com")
        XCTAssertNil(ClaudeRateLimitMonitor.defaultDirSlot(home: h))
        XCTAssertEqual(ClaudeRateLimitMonitor.accounts(home: h).values.flatMap { $0 }.count, 2)
    }
}
