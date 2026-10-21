import XCTest
@testable import CodexUsageWidget

final class CodexUsageTextParserTests: XCTestCase {
    func testSessionOnlyJSONKeepsWeeklyLaneAbsentAcrossConsumers() throws {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": {
                "usedPercent": 23,
                "windowMinutes": 300,
                "resetsAt": "2026-06-05T06:00:00Z"
              },
              "secondary": null
            }
          }
        ]
        """
        let now = ISO8601DateFormatter().date(from: "2026-06-05T01:00:00Z")!

        let snapshot = try CodexUsageTextParser.parseJSON(Data(json.utf8), now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertEqual(snapshot.session?.leftPercent, 77)
        XCTAssertEqual(snapshot.session?.resetText, "Resets 6/5 15:00 (5h0m)")
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.availableLimits.map(\.title), ["Session"])
        XCTAssertEqual(snapshot.primaryLimit?.title, "Session")

        let data = try UsageSnapshotPublisher.encodedData(for: snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["session"])
        XCTAssertNil(object["weekly"])
    }

    func testWeeklyOnlyJSONUsesWeeklyAsPrimaryWithoutInventingSession() throws {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": null,
              "secondary": {
                "usedPercent": 13,
                "windowMinutes": 10080,
                "resetsAt": "2026-06-11T03:00:00Z"
              }
            }
          }
        ]
        """
        let now = ISO8601DateFormatter().date(from: "2026-06-05T03:00:00Z")!

        let snapshot = try CodexUsageTextParser.parseJSON(Data(json.utf8), now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)

        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weekly?.leftPercent, 87)
        XCTAssertEqual(snapshot.availableLimits.map(\.title), ["Weekly"])
        XCTAssertEqual(snapshot.primaryLimit?.title, "Weekly")

        let data = try UsageSnapshotPublisher.encodedData(for: snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["session"])
        XCTAssertNotNil(object["weekly"])
    }

    func testPresentLaneWithoutUsedPercentIsRejected() {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": {
                "windowMinutes": 300
              },
              "secondary": null
            }
          }
        ]
        """

        XCTAssertThrowsError(try CodexUsageTextParser.parseJSON(Data(json.utf8))) { error in
            XCTAssertEqual(error as? CodexUsageError, .invalidJSON)
        }
    }

    func testParsesCodexBarJSONLimitsAndWeeklyPace() throws {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": {
                "usedPercent": 0,
                "windowMinutes": 300
              },
              "secondary": {
                "usedPercent": 13,
                "windowMinutes": 10080,
                "resetsAt": "2026-06-11T03:50:05Z"
              }
            }
          }
        ]
        """
        let now = ISO8601DateFormatter().date(from: "2026-06-05T01:00:05Z")!

        let snapshot = try CodexUsageTextParser.parseJSON(Data(json.utf8), now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let session = try XCTUnwrap(snapshot.session)
        let weekly = try XCTUnwrap(snapshot.weekly)

        XCTAssertEqual(session.leftPercent, 100)
        XCTAssertEqual(session.resetText, "Resets in 5h")
        XCTAssertNil(session.detailText)
        XCTAssertNil(session.projectionText)
        XCTAssertNil(session.markerPercent)
        XCTAssertEqual(weekly.leftPercent, 87)
        XCTAssertEqual(weekly.resetText, "Resets 6/11 12:50 (6d2h)")
        XCTAssertEqual(weekly.detailText, "On pace")
        XCTAssertEqual(weekly.projectionText, "Runs out in 5d 21h")
        XCTAssertEqual(weekly.markerPercent, 87)
    }

    func testJSONUsesResetDescriptionTimeWhenResetsAtIsMissing() throws {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": {
                "resetDescription": "Resets 3:19 PM",
                "usedPercent": 77,
                "windowMinutes": 300
              },
              "secondary": {
                "resetDescription": "Resets Jun 11, 2026 12:50 PM",
                "usedPercent": 67,
                "windowMinutes": 10080,
                "resetsAt": "2026-06-11T03:50:43Z"
              }
            }
          }
        ]
        """
        let now = ISO8601DateFormatter().date(from: "2026-06-06T05:25:00Z")!
        let timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!

        let snapshot = try CodexUsageTextParser.parseJSON(Data(json.utf8), now: now, timeZone: timeZone)
        let session = try XCTUnwrap(snapshot.session)
        let weekly = try XCTUnwrap(snapshot.weekly)

        XCTAssertEqual(session.leftPercent, 23)
        XCTAssertEqual(session.resetText, "Resets 6/6 15:19 (54m)")
        XCTAssertEqual(session.detailText, "On pace")
        XCTAssertEqual(session.projectionText, "Projected empty in 1h 13m")
        XCTAssertEqual(session.markerPercent, 18)
        XCTAssertEqual(weekly.leftPercent, 33)
        XCTAssertEqual(weekly.resetText, "Resets 6/11 12:50 (4d22h)")
    }

    func testParsesSessionAndWeeklyLimits() throws {
        let text = """
        == Codex (openai-web) ==
        Session: 94% left [===========-]
        Resets 5:50 PM
        Weekly: 99% left [===========-]
        Resets in 6d 23h
        Credits: 0 left
        """

        let snapshot = try CodexUsageTextParser.parse(text)
        let session = try XCTUnwrap(snapshot.session)
        let weekly = try XCTUnwrap(snapshot.weekly)

        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.leftPercent, 94)
        XCTAssertEqual(session.resetText, "Resets 5:50 PM")
        XCTAssertEqual(weekly.title, "Weekly")
        XCTAssertEqual(weekly.leftPercent, 99)
        XCTAssertEqual(weekly.resetText, "Resets in 6d 23h")
    }

    func testTextParserDoesNotApplyWeeklyResetToSession() throws {
        let text = """
        == Codex (openai-web) ==
        Session: 100% left [============]
        Weekly: 87% left [==========--]
        Pace: On pace | Expected 13% used | Runs out in 5d 21h
        Resets in 6d 2h
        Credits: 0 left
        """

        let snapshot = try CodexUsageTextParser.parse(text)
        let session = try XCTUnwrap(snapshot.session)
        let weekly = try XCTUnwrap(snapshot.weekly)

        XCTAssertEqual(session.resetText, "Reset pending")
        XCTAssertNil(session.detailText)
        XCTAssertEqual(weekly.resetText, "Resets in 6d 2h")
        XCTAssertEqual(weekly.detailText, "On pace")
        XCTAssertEqual(weekly.projectionText, "Runs out in 5d 21h")
        XCTAssertEqual(weekly.markerPercent, 87)
    }

    func testJSONDeficitProjectionAndMarker() throws {
        let json = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": {
                "usedPercent": 14,
                "windowMinutes": 300,
                "resetsAt": "2026-06-05T05:58:00Z"
              },
              "secondary": {
                "usedPercent": 14,
                "windowMinutes": 10080,
                "resetsAt": "2026-06-11T03:50:26Z"
              }
            }
          }
        ]
        """
        let now = ISO8601DateFormatter().date(from: "2026-06-05T01:31:00Z")!

        let snapshot = try CodexUsageTextParser.parseJSON(Data(json.utf8), now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let session = try XCTUnwrap(snapshot.session)

        XCTAssertEqual(session.leftPercent, 86)
        XCTAssertEqual(session.detailText, "3% in deficit")
        XCTAssertEqual(session.projectionText, "Projected empty in 3h 22m")
        XCTAssertEqual(session.markerPercent, 89)
    }

    func testUsageToneThresholds() {
        XCTAssertEqual(limit(35).tone, .healthy)
        XCTAssertEqual(limit(34).tone, .warning)
        XCTAssertEqual(limit(20).tone, .warning)
        XCTAssertEqual(limit(19).tone, .critical)
    }

    func testPublishedSnapshotUsesLocalContract() throws {
        let snapshot = UsageSnapshot(
            session: UsageLimit(
                title: "Session",
                leftPercent: 23.4,
                resetText: "Resets in 54m",
                detailText: "On pace",
                projectionText: "Projected empty in 1h 13m",
                markerPercent: 18.2
            ),
            weekly: UsageLimit(
                title: "Weekly",
                leftPercent: 77,
                resetText: "Resets in 5d 23h",
                detailText: "8% in deficit",
                projectionText: "Runs out in 3d 11h",
                markerPercent: 85
            ),
            updatedAt: ISO8601DateFormatter().date(from: "2026-06-07T06:00:00Z")!
        )

        let data = try UsageSnapshotPublisher.encodedData(for: snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let session = object?["session"] as? [String: Any]

        XCTAssertEqual(object?["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object?["source"] as? String, "CodexBarCLI")
        XCTAssertEqual(object?["updatedAt"] as? String, "2026-06-07T06:00:00Z")
        XCTAssertEqual(session?["remainingPercent"] as? Int, 23)
        XCTAssertEqual(session?["state"] as? String, "warning")
        XCTAssertEqual(session?["markerPercent"] as? Int, 18)
    }

    private func limit(_ leftPercent: Double) -> UsageLimit {
        UsageLimit(title: "Session", leftPercent: leftPercent, resetText: "Resets soon")
    }
}
