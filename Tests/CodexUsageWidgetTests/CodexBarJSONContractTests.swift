import XCTest
@testable import CodexUsageWidget

final class CodexBarJSONContractTests: XCTestCase {
    func testCodexBar0500AdditiveUsageShapeRemainsCompatible() throws {
        // Contract fields checked against steipete/CodexBar v0.50.0 at
        // commit 0e453c4a5b2a13ce69f5400190e62a630e3b4240.
        let snapshot = try parse(
            """
            [
              {
                "provider": "codex",
                "account": "synthetic-account",
                "version": "0.50.0",
                "source": "oauth",
                "status": null,
                "usage": {
                  "primary": {
                    "usedPercent": 24,
                    "windowMinutes": 300,
                    "nextRegenPercent": 5,
                    "isSyntheticPlaceholder": false
                  },
                  "secondary": {
                    "usedPercent": 31,
                    "windowMinutes": 10080,
                    "resetDescription": "Resets later"
                  },
                  "tertiary": {
                    "usedPercent": 7,
                    "windowMinutes": 43200
                  },
                  "extraRateWindows": [],
                  "details": [],
                  "dataConfidence": "unknown"
                },
                "credits": null,
                "error": null,
                "pace": null
              }
            ]
            """
        )

        XCTAssertEqual(snapshot.session?.leftPercent, 76)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 69)
        XCTAssertEqual(snapshot.availableLimits.map(\.title), ["Session", "Weekly"])
    }

    func testMinimalWeeklyOnlyShapeNeedsOnlyUsedPercent() throws {
        let snapshot = try parse(
            """
            [
              {
                "provider": "codex",
                "usage": {
                  "primary": null,
                  "secondary": {
                    "usedPercent": 13
                  }
                }
              }
            ]
            """
        )

        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 87)
        XCTAssertEqual(snapshot.weekly?.resetText, "Reset pending")
        XCTAssertNil(snapshot.weekly?.detailText)
        XCTAssertNil(snapshot.weekly?.projectionText)
        XCTAssertNil(snapshot.weekly?.markerPercent)
    }

    func testWeeklyOnlyShapeUsesResetDescriptionWithoutWindowMetadata() throws {
        let snapshot = try parse(
            """
            [
              {
                "provider": "codex",
                "usage": {
                  "secondary": {
                    "usedPercent": 67,
                    "resetDescription": "Resets later"
                  }
                }
              }
            ]
            """
        )

        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 33)
        XCTAssertEqual(snapshot.weekly?.resetText, "Resets later")
        XCTAssertNil(snapshot.weekly?.detailText)
    }

    func testWeeklyOnlyShapeIgnoresAdditiveFieldsAndFindsCodexEntry() throws {
        let snapshot = try parse(
            """
            [
              {
                "provider": "synthetic-other",
                "usage": {
                  "primary": { "usedPercent": 99 }
                }
              },
              {
                "provider": "codex",
                "source": "synthetic",
                "futureEnvelopeField": { "enabled": true },
                "usage": {
                  "primary": null,
                  "secondary": {
                    "usedPercent": 21,
                    "futureWindowField": "ignored"
                  },
                  "futureUsageField": [1, 2, 3]
                }
              }
            ]
            """
        )

        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 79)
        XCTAssertEqual(snapshot.availableLimits.map(\.title), ["Weekly"])
    }

    func testMalformedOrUnusableEnvelopesFailClosed() {
        let invalidPayloads = [
            ("empty array", "[]"),
            ("non-array envelope", #"{"provider":"codex"}"#),
            ("missing Codex entry", #"[{"provider":"synthetic-other","usage":{"secondary":{"usedPercent":13}}}]"#),
            ("missing usage", #"[{"provider":"codex"}]"#),
            ("no usable window", #"[{"provider":"codex","usage":{"primary":null,"secondary":null}}]"#),
            ("wrong usedPercent type", #"[{"provider":"codex","usage":{"secondary":{"usedPercent":"13"}}}]"#)
        ]

        for (name, json) in invalidPayloads {
            XCTAssertThrowsError(try parse(json), name)
        }
    }

    func testCodexEntryWithUsageAndErrorFailsClosed() {
        XCTAssertThrowsError(
            try parse(
                """
                [
                  {
                    "provider": "codex",
                    "usage": {
                      "primary": { "usedPercent": 12 }
                    },
                    "error": {
                      "code": 1,
                      "kind": "provider",
                      "message": "redacted-provider-message"
                    }
                  }
                ]
                """
            )
        ) { error in
            XCTAssertEqual(error as? CodexUsageError, .invalidJSON)
        }
    }

    func testCodexEntryWithUsageAndNullErrorIsAccepted() throws {
        let snapshot = try parse(
            """
            [
              {
                "provider": "codex",
                "usage": {
                  "primary": { "usedPercent": 12 }
                },
                "error": null
              }
            ]
            """
        )

        XCTAssertEqual(snapshot.session?.leftPercent, 88)
        XCTAssertNil(snapshot.weekly)
    }

    private func parse(_ json: String) throws -> UsageSnapshot {
        try CodexUsageTextParser.parseJSON(Data(json.utf8))
    }
}
