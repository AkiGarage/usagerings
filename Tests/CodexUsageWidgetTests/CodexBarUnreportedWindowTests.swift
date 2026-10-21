import XCTest
@testable import CodexUsageWidget

final class CodexBarUnreportedWindowTests: XCTestCase {
    func testLiveUnreportedSessionWindowParsesWeeklyOnly() throws {
        let snapshot = try parse(
            """
            [
              {
                "provider": "codex",
                "usage": {
                  "primary": { "usedPercent": null, "windowMinutes": null, "resetsAt": null },
                  "secondary": {
                    "usedPercent": 19,
                    "windowMinutes": 10080,
                    "resetsAt": "2026-10-22T06:38:56Z"
                  }
                }
              }
            ]
            """
        )

        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 81)
        XCTAssertEqual(snapshot.availableLimits.map(\.title), ["Weekly"])
    }

    func testAllWindowsUnreportedFailsClosed() {
        XCTAssertThrowsError(
            try parse(
                #"[{"provider":"codex","usage":{"primary":{"usedPercent":null,"windowMinutes":null,"resetsAt":null},"secondary":{"usedPercent":null,"windowMinutes":null,"resetsAt":null}}}]"#
            )
        )
    }

    func testUnreportedSessionDerivesWeeklyResetFromResetsAt() throws {
        let snapshot = try CodexUsageTextParser.parseJSON(
            Data(
                #"[{"provider":"codex","usage":{"primary":{"usedPercent":null},"secondary":{"usedPercent":19,"windowMinutes":10080,"resetsAt":"2026-10-22T06:38:56Z"}}}]"#.utf8
            ),
            now: ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(snapshot.weekly?.resetText, "Resets 10/22 06:38 (5d18h)")
    }

    private func parse(_ json: String) throws -> UsageSnapshot {
        try CodexUsageTextParser.parseJSON(Data(json.utf8))
    }
}
