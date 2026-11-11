import Foundation
import os
import XCTest
@testable import CodexUsageWidget

/// OpenDesign Go Design Plan readings, parsed from the control API shape the
/// official app itself reads. All ids here are synthetic.
final class OpenDesignUsageTests: XCTestCase {
    private let now = OpenDesignUsageTests.timestamp("2026-11-11T01:09:13Z")!

    /// The API writes fractional seconds; the default ISO8601 options reject them.
    private static func timestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Fixtures

    /// The live response shape (minus the real ids), with the extra fields the
    /// control API adds today: an unknown-key test rides along.
    static let directory = Data(#"""
    {"items":[
      {"memberCount":3,"isDefault":false,"workspaceId":"ws-team","workspaceName":"Team",
       "workspaceIconKey":"team","workspaceType":"team","workspaceMemberId":"member-team",
       "role":"admin","memberStatus":"active","lifecycleState":"active"},
      {"memberCount":1,"isDefault":true,"workspaceId":"ws-personal","workspaceName":"Me",
       "workspaceIconKey":"person","workspaceType":"personal","workspaceMemberId":"member-personal",
       "role":"owner","memberStatus":"active","lifecycleState":"active"}
    ]}
    """#.utf8)

    static let funding = Data(#"""
    {
      "schemaVersion": 1,
      "workspaceId": "ws-personal",
      "workspaceMemberId": "member-personal",
      "modelId": null,
      "generatedAt": "2026-11-11T01:09:12.944Z",
      "balanceUsd": "1.5000",
      "codingPlan": {
        "workspaceId": "ws-personal",
        "generatedAt": "2026-11-11T01:09:12.999Z",
        "eligible": true,
        "tier": "go",
        "windows": [
          {"policyId": "od-go-5h", "durationSeconds": 18000, "resetMode": "anchored_recurring",
           "usedCredits": "8336", "limitCredits": "50000", "remainingCredits": "41664",
           "windowStart": "2026-11-10T21:44:08.067Z", "resetsAt": "2026-11-11T02:44:08.067Z"},
          {"policyId": "od-go-7d", "durationSeconds": 604800, "resetMode": "anchored_recurring",
           "usedCredits": "31828", "limitCredits": "150000", "remainingCredits": "118172",
           "windowStart": "2026-11-10T11:44:08.067Z", "resetsAt": "2026-11-17T11:44:08.067Z"}
        ]
      },
      "modelCovered": true,
      "funding": "coding_plan",
      "fundingCheck": "available",
      "billingMode": "shared",
      "taskCheck": "ready",
      "unknownFutureField": {"nested": [1, 2, 3]}
    }
    """#.utf8)

    private var workspace: OpenDesignUsage.Workspace {
        OpenDesignUsage.Workspace(id: "ws-personal", memberID: "member-personal")
    }

    private func fundingJSON(_ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.funding) as? [String: Any])
        try mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func plan(_ object: inout [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(object["codingPlan"] as? [String: Any])
    }

    private func windows(_ object: inout [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(try plan(&object)["windows"] as? [[String: Any]])
    }

    private func setWindows(_ value: [[String: Any]], in object: inout [String: Any]) throws {
        var codingPlan = try plan(&object)
        codingPlan["windows"] = value
        object["codingPlan"] = codingPlan
    }

    // MARK: Parsing the live shape

    func testLiveShapeParsesBothDesignPlanWindows() throws {
        let planWindows = try OpenDesignUsageParser.funding(Self.funding, workspace: workspace)
        XCTAssertEqual(planWindows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(planWindows[0].leftPercent, 83.328, accuracy: 0.001)
        XCTAssertEqual(planWindows[1].leftPercent, 78.781, accuracy: 0.001)
        XCTAssertEqual(planWindows[0].resetsAt, Self.timestamp("2026-11-11T02:44:08.067Z"))
        XCTAssertEqual(planWindows[1].resetsAt, Self.timestamp("2026-11-17T11:44:08.067Z"))
    }

    func testParsedWindowsBecomeThePanelRowsAndRingTitles() throws {
        let outcome = OpenDesignUsage.loaded(
            workspace: workspace,
            windows: try OpenDesignUsageParser.funding(Self.funding, workspace: workspace)
        )
        let section = MultiUsageService.openDesignSection(outcome, now: now)
        XCTAssertEqual(section.provider, .opendesign)
        XCTAssertNil(section.failureText)
        XCTAssertEqual(section.windows.map(\.title), ["5h", "Weekly"])
        XCTAssertEqual(section.windows[0].leftPercent, 83.328, accuracy: 0.001)
        XCTAssertEqual(section.windows[1].leftPercent, 78.781, accuracy: 0.001)
        XCTAssertEqual(section.windows[0].resetAt, Self.timestamp("2026-11-11T02:44:08.067Z"))
        XCTAssertTrue(section.windows[0].resetText.hasPrefix("Resets "))

        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.first?.name, "OpenDesign")
        XCTAssertEqual(rows.first?.five?.title, "5h")
        XCTAssertEqual(rows.first?.week?.title, "Weekly")

        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now)
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.provider == .opendesign })
        XCTAssertEqual(bar.label, "OD")
        XCTAssertEqual(bar.limit?.title, "5h")
        XCTAssertEqual(bar.windows.map(\.title), ["5h", "Weekly"])
        XCTAssertEqual(RingDetailCardModel.make(bar: bar, now: now)?.rows.map(\.label), ["5時間枠", "週の枠"])
    }

    func testMissingResetTimeStaysUnknownInsteadOfInventingOne() throws {
        let data = try fundingJSON { object in
            var entryWindows = try self.windows(&object)
            entryWindows[0]["resetsAt"] = NSNull()
            try setWindows(entryWindows, in: &object)
        }
        let windows = try OpenDesignUsageParser.funding(data, workspace: workspace)
        XCTAssertNil(windows[0].resetsAt)
        let section = MultiUsageService.openDesignSection(.loaded(workspace: workspace, windows: windows), now: now)
        XCTAssertEqual(section.windows[0].resetText, MultiUsageService.openDesignUnknownReset)
        XCTAssertNil(section.windows[0].resetAt)
    }

    // MARK: Fail-closed validation

    func testSchemaVersionOtherThanOneIsRejected() throws {
        let data = try fundingJSON { $0["schemaVersion"] = 2 }
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(data, workspace: workspace))
    }

    func testRemainingAboveLimitIsRejectedNotClamped() throws {
        let data = try fundingJSON { object in
            var entryWindows = try windows(&object)
            entryWindows[0]["remainingCredits"] = "50001"
            try setWindows(entryWindows, in: &object)
        }
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(data, workspace: workspace)) {
            XCTAssertEqual($0 as? OpenDesignUsageParser.Failure, .malformed)
        }
    }

    func testNonStringCreditCountsAreRejected() throws {
        for key in ["usedCredits", "limitCredits", "remainingCredits"] {
            let data = try fundingJSON { object in
                var entryWindows = try windows(&object)
                entryWindows[0][key] = 41664
                try setWindows(entryWindows, in: &object)
            }
            XCTAssertThrowsError(try OpenDesignUsageParser.funding(data, workspace: workspace), key)
        }
    }

    func testWorkspaceMismatchIsRejected() throws {
        let data = try fundingJSON { $0["workspaceId"] = "ws-other" }
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(data, workspace: workspace))
        let planMismatch = try fundingJSON { object in
            var codingPlan = try plan(&object)
            codingPlan["workspaceId"] = "ws-other"
            object["codingPlan"] = codingPlan
        }
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(planMismatch, workspace: workspace))
    }

    func testMalformedFundingIsAFailureRowNeverFullQuota() throws {
        for data in [
            Data(),
            Data(#"{"schemaVersion":1}"#.utf8),
            try fundingJSON { $0["balanceUsd"] = NSNull() },
            try fundingJSON { $0["funding"] = "free_lunch" }
        ] as [Data] {
            let outcome = Self.outcome(for: data)
            let section = MultiUsageService.openDesignSection(outcome, now: now)
            XCTAssertTrue(section.windows.isEmpty, String(decoding: data, as: UTF8.self))
            XCTAssertNotNil(section.failureText)
            XCTAssertNotEqual(section.windows.first?.leftPercent, 100)
        }
    }

    func testIneligiblePlanOrNoWindowsIsUnavailableNotFull() throws {
        let ineligible = try fundingJSON { object in
            var codingPlan = try plan(&object)
            codingPlan["eligible"] = false
            object["codingPlan"] = codingPlan
        }
        let empty = try fundingJSON { object in
            var codingPlan = try plan(&object)
            codingPlan["windows"] = [[String: Any]]()
            object["codingPlan"] = codingPlan
        }
        for data in [ineligible, empty] {
            XCTAssertEqual(Self.outcome(for: data), .noPlan)
            let section = MultiUsageService.openDesignSection(.noPlan, now: now)
            XCTAssertTrue(section.windows.isEmpty)
            XCTAssertEqual(section.failureText, MultiUsageService.openDesignUnavailableText)
            XCTAssertNil(section.lowestLeftWindow)
        }
        // The parser reports "no plan" rather than an all-zero pool.
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(ineligible, workspace: workspace)) {
            XCTAssertEqual($0 as? OpenDesignUsageParser.Failure, .noPlan)
        }
        XCTAssertThrowsError(try OpenDesignUsageParser.funding(empty, workspace: workspace)) {
            XCTAssertEqual($0 as? OpenDesignUsageParser.Failure, .noPlan)
        }
    }

    private static func outcome(for data: Data) -> OpenDesignUsage {
        do {
            let platform = OpenDesignUsage.Workspace(id: "ws-personal", memberID: "member-personal")
            return .loaded(workspace: platform, windows: try OpenDesignUsageParser.funding(data, workspace: platform))
        } catch OpenDesignUsageParser.Failure.noPlan {
            return .noPlan
        } catch {
            return .malformed
        }
    }

    // MARK: Workspace selection

    func testPersonalWorkspaceWinsOverATeamWorkspace() throws {
        XCTAssertEqual(try OpenDesignUsageParser.personalWorkspace(Self.directory), workspace)
    }

    func testPersonalWorkspaceSelectionPrefersTheDefaultAndFallsBackToOrder() throws {
        let data = Data(#"""
        {"items":[
          {"workspaceId":"ws-a","workspaceMemberId":"m-a","workspaceType":"personal",
           "memberStatus":"active","lifecycleState":"active"},
          {"workspaceId":"ws-b","workspaceMemberId":"m-b","workspaceType":"personal",
           "memberStatus":"active","lifecycleState":"active","isDefault":true}
        ]}
        """#.utf8)
        XCTAssertEqual(try OpenDesignUsageParser.personalWorkspace(data),
                       .init(id: "ws-b", memberID: "m-b"))
    }

    func testTeamOnlyDirectoryHasNoPersonalWorkspaceToRead() {
        let data = Data(#"{"items":[{"workspaceId":"ws-team","workspaceMemberId":"m","workspaceType":"team","memberStatus":"active","lifecycleState":"active"}]}"#.utf8)
        XCTAssertThrowsError(try OpenDesignUsageParser.personalWorkspace(data)) {
            XCTAssertEqual($0 as? OpenDesignUsageParser.Failure, .noPersonalWorkspace)
        }
        let section = MultiUsageService.openDesignSection(.noPersonalWorkspace, now: now)
        XCTAssertTrue(section.windows.isEmpty)
        XCTAssertEqual(section.failureText, MultiUsageService.openDesignUnavailableText)
    }

    // MARK: Credential

    private func configFile(_ profile: [String: Any]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["profiles": ["prod": profile]])
            .write(to: url)
        return url
    }

    func testConfigFileUnderAMRHomeIsTheOnlyCredentialRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = try configFile(["controlKey": "  synthetic-control-key\n"])
        XCTAssertEqual(
            OpenDesignCredential.configURL(environment: ["AMR_HOME": "~/.amr"], home: home),
            home.appendingPathComponent(".amr/config.json")
        )
        XCTAssertEqual(OpenDesignCredential.configURL(environment: [:], home: home),
                       home.appendingPathComponent(".amr/config.json"))
        XCTAssertEqual(OpenDesignCredential.configURL(environment: ["AMR_HOME": "/tmp/elsewhere"], home: home),
                       URL(fileURLWithPath: "/tmp/elsewhere/config.json"))
        XCTAssertEqual(try OpenDesignCredential.controlKey(at: url), "synthetic-control-key")
    }

    func testMissingOrPendingConfigIsALoginRequestNotAPercent() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try OpenDesignCredential.controlKey(at: missing)) {
            XCTAssertEqual($0 as? OpenDesignCredential.LoadError, .missing)
        }
        let pending = try configFile(["pendingLogin": true, "controlKey": "synthetic-control-key"])
        XCTAssertThrowsError(try OpenDesignCredential.controlKey(at: pending)) {
            XCTAssertEqual($0 as? OpenDesignCredential.LoadError, .pendingLogin)
        }
        let section = MultiUsageService.openDesignSection(.notLoggedIn, now: now)
        XCTAssertEqual(section.failureText, "OpenDesignアプリでログインしてください")
        XCTAssertEqual(section.failureReason, .logout)
        XCTAssertTrue(section.windows.isEmpty)
    }

    // MARK: Client

    private func client(key: String = "synthetic-control-key",
                        directory: Data = OpenDesignUsageTests.directory,
                        funding: Data = OpenDesignUsageTests.funding,
                        directoryStatus: Int = 200,
                        fundingStatus: Int = 200,
                        requests: (@Sendable (URLRequest) -> Void)? = nil) -> OpenDesignUsageClient {
        OpenDesignUsageClient(loadControlKey: { key }, transport: { request in
            requests?(request)
            if request.url?.path == "/api/v1/workspaces" { return (directory, directoryStatus) }
            return (funding, fundingStatus)
        }, userAgent: "UsageRings/1.2.3")
    }

    func testClientSendsTheTwoGetRequestsWithBearerAndUserAgent() async throws {
        let records = OSAllocatedUnfairLock<[String]>(initialState: [])
        let client = client(requests: { request in
            let line = [
                request.url?.absoluteString ?? "",
                request.value(forHTTPHeaderField: "Authorization") ?? "",
                request.value(forHTTPHeaderField: "User-Agent") ?? ""
            ].joined(separator: "|")
            records.withLock { $0.append(line) }
        })
        let outcome = await client.fetch()
        guard case let .loaded(loadedWorkspace, planWindows) = outcome else {
            return XCTFail("expected a loaded reading, got \(outcome)")
        }
        XCTAssertEqual(loadedWorkspace, self.workspace)
        let kinds: [OpenDesignUsage.WindowKind] = planWindows.map { $0.kind }
        XCTAssertEqual(kinds, [.fiveHour, .weekly])
        XCTAssertEqual(records.withLock { $0 }, [
            "https://amr-api.open-design.ai/api/v1/workspaces|Bearer synthetic-control-key|UsageRings/1.2.3",
            "https://amr-api.open-design.ai/api/v1/workspaces/ws-personal/billing/funding-check"
                + "|Bearer synthetic-control-key|UsageRings/1.2.3"
        ])
    }

    func testUnauthorizedKeyIsALogoutFailure() async {
        let outcome = await client(directoryStatus: 401).fetch()
        XCTAssertEqual(outcome, .unauthorized)
        let section = MultiUsageService.openDesignSection(outcome, now: now)
        XCTAssertEqual(section.failureReason, .logout)
        XCTAssertEqual(section.failureText, "OpenDesignアプリでログインしてください")
    }

    func testForbiddenResponseIsAnUpstreamFailureNotALogout() async {
        let outcome = await client(directoryStatus: 403).fetch()
        XCTAssertEqual(outcome, .httpFailure(403))
        let section = MultiUsageService.openDesignSection(outcome, now: now)
        XCTAssertEqual(section.failureText, "OpenDesignの使用量を取得できません (403)")
        XCTAssertEqual(section.failureReason, .providerError)
        XCTAssertNotEqual(section.failureReason, .logout)
    }

    func testServerErrorAndTransportFailureNeverProducePercentages() async {
        let server = await client(fundingStatus: 503).fetch()
        XCTAssertEqual(server, .httpFailure(503))
        let broken = OpenDesignUsageClient(loadControlKey: { "synthetic-control-key" }, transport: { _ in
            throw URLError(.timedOut)
        }).fetch
        let transport = await broken()
        XCTAssertEqual(transport, .transportFailure)
        for outcome in [server, transport] {
            let section = MultiUsageService.openDesignSection(outcome, now: now)
            XCTAssertTrue(section.windows.isEmpty)
            XCTAssertNotNil(section.failureText)
        }
    }

    func testMalformedFundingResponseIsAFailure() async {
        let outcome = await client(funding: Data("not json".utf8)).fetch()
        XCTAssertEqual(outcome, .malformed)
    }

    func testControlKeyNeverAppearsInAnyFailureText() async {
        let secret = "synthetic-control-key-do-not-print"
        let failures: [OpenDesignUsageClient] = [
            client(key: secret, directoryStatus: 401),
            client(key: secret, directoryStatus: 403),
            client(key: secret, funding: Data("{}".utf8)),
            OpenDesignUsageClient(loadControlKey: { throw OpenDesignCredential.LoadError.pendingLogin },
                                  transport: { _ in (Data(), 500) })
        ]
        for client in failures {
            let section = MultiUsageService.openDesignSection(await client.fetch(), now: now)
            let texts = [section.failureText ?? ""] + section.stats.map(\.valueText) + section.windows.map(\.resetText)
            for text in texts {
                XCTAssertFalse(text.contains(secret), text)
                XCTAssertFalse(text.lowercased().contains("bearer"), text)
            }
        }
    }

    // MARK: Wiring

    func testFetchAllShowsOpenDesignWithoutAskingCodexBar() async {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let service = MultiUsageService(commandRunner: { arguments in
            calls.withLock { $0.append(arguments) }
            return .init(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, openDesignClient: client(), retryDelay: 0)
        let snapshot = await service.fetchAll(now: now)
        XCTAssertEqual(snapshot.sections.map(\.provider),
                       [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .opendesign, .antigravity])
        let section = try? XCTUnwrap(snapshot.sections.first { $0.provider == .opendesign })
        XCTAssertNil(section?.failureText)
        XCTAssertEqual(section?.windows.map(\.title), ["5h", "Weekly"])
        XCTAssertFalse(calls.withLock { $0 }.contains { $0.contains("opendesign") })
    }

    func testDisabledOpenDesignIsNeitherFetchedNorShownAsPercentages() async {
        let fetched = OSAllocatedUnfairLock<Bool>(initialState: false)
        let credentialRead = OSAllocatedUnfairLock<Bool>(initialState: false)
        let transport: OpenDesignUsageClient.Transport = { _ in
            fetched.withLock { $0 = true }
            return (OpenDesignUsageTests.directory, 200)
        }
        let service = MultiUsageService(commandRunner: { _ in
            .init(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, openDesignClient: OpenDesignUsageClient(loadControlKey: {
            credentialRead.withLock { $0 = true }
            return "synthetic-control-key"
        }, transport: transport),
           retryDelay: 0)
        let snapshot = await service.fetchAll(disabled: [.opendesign])
        let section = snapshot.sections.first { $0.provider == .opendesign }
        XCTAssertEqual(section?.failureText, MultiUsageService.hiddenText)
        XCTAssertTrue(section?.windows.isEmpty ?? false)
        XCTAssertFalse(fetched.withLock { $0 })
        XCTAssertFalse(credentialRead.withLock { $0 })
    }
}
