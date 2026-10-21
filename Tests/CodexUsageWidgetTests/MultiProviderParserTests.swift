import XCTest
@testable import CodexUsageWidget

final class MultiProviderParserTests: XCTestCase {
    func testZaiShapeParsesWindowsWithExtras() throws {
        let section = try parse(
            """
            [
              {
                "provider": "zai",
                "usage": {
                  "primary": { "usedPercent": 10, "windowMinutes": 300, "resetsAt": "2026-10-16T15:52:28Z" },
                  "secondary": { "usedPercent": null, "windowMinutes": null, "resetsAt": null },
                  "tertiary": null,
                  "extraRateWindows": [
                    { "title": "MCP", "window": { "usedPercent": 0.4, "windowMinutes": 43200, "resetsAt": "2026-11-04T05:08:05Z" } }
                  ]
                }
              }
            ]
            """,
            provider: .zai,
            now: fixedNow,
            timeZone: utc
        )

        XCTAssertEqual(section.provider, .zai)
        XCTAssertEqual(section.windows.map(\.title), ["5h", "MCP"])
        XCTAssertEqual(section.windows.map(\.leftPercent), [90, 99.6])
        XCTAssertEqual(section.windows[0].resetText, "Resets 10/17 00:52 (3h52m)")
        XCTAssertNil(section.failureText)
        XCTAssertNil(section.windows[0].detailText)
        XCTAssertNil(section.windows[0].markerPercent)
    }

    func testClaudeShapeParsesFiveHourAndWeekly() throws {
        let section = try parse(
            """
            [
              {
                "provider": "claude",
                "usage": {
                  "primary": { "usedPercent": 21, "windowMinutes": 300, "resetsAt": "2026-10-16T14:39:59Z" },
                  "secondary": { "usedPercent": 36, "windowMinutes": 10080, "resetsAt": "2026-10-21T16:59:59Z" }
                }
              }
            ]
            """,
            provider: .claude,
            now: fixedNow,
            timeZone: utc
        )

        XCTAssertEqual(section.windows.map(\.title), ["5h", "Weekly"])
        XCTAssertEqual(section.windows.map(\.leftPercent), [79, 64])
        XCTAssertEqual(section.windows[0].resetText, "Resets 10/16 23:39 (2h39m)")
        XCTAssertEqual(section.windows[1].resetText, "Resets 10/22 01:59 (5d4h)")
    }

    func testEntryErrorFailsClosed() {
        XCTAssertThrowsError(
            try parse(
                #"[{"provider":"zai","error":{"code":1,"kind":"provider","message":"synthetic-sensitive-message"}}]"#,
                provider: .zai
            )
        )
    }

    func testNoUsableWindowThrows() {
        XCTAssertThrowsError(
            try parse(
                #"[{"provider":"claude","usage":{"primary":{"usedPercent":null},"secondary":null}}]"#,
                provider: .claude
            )
        )
    }

    func testUnreportedMiddleWindowIsSkipped() throws {
        let section = try parse(
            #"[{"provider":"zai","usage":{"primary":{"usedPercent":10,"windowMinutes":300},"secondary":{"usedPercent":null},"tertiary":{"usedPercent":5,"windowMinutes":43200}}}]"#,
            provider: .zai
        )

        XCTAssertEqual(section.windows.map(\.title), ["5h", "Monthly"])
    }

    func testUnknownWindowMinutesFallsBackToQuota() throws {
        let section = try parse(
            #"[{"provider":"claude","usage":{"primary":{"usedPercent":10,"windowMinutes":1337}}}]"#,
            provider: .claude
        )

        XCTAssertEqual(section.windows.map(\.title), ["Quota"])
    }

    func testResetDescriptionUsedWhenResetsAtMissing() throws {
        let section = try parse(
            #"[{"provider":"claude","usage":{"primary":{"usedPercent":10,"windowMinutes":300,"resetDescription":"Resets later"}}}]"#,
            provider: .claude
        )

        XCTAssertEqual(section.windows[0].resetText, "Resets later")
    }

    private func parse(
        _ json: String,
        provider: ProviderID,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> ProviderSection {
        try MultiProviderParser.parse(Data(json.utf8), provider: provider, now: now, timeZone: timeZone)
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
    }

    private var utc: TimeZone {
        TimeZone(identifier: "UTC")!
    }
}
