import XCTest
@testable import CodexUsageWidget

final class CLIProxyClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_238_400)

    func testCredentialAliasesAndDisabledAccounts() throws {
        let entries = try CLIProxyParser.credentials(Data(CLIProxyFixtures.credentials.utf8))
        XCTAssertEqual(entries.map(\.authIndex), ["c1", "c2", "a1", "disabled"])
        XCTAssertEqual(entries[1].provider, "claude")
        XCTAssertEqual(entries[0].maskedEmail, "ali***@e***")
        XCTAssertEqual(entries[2].projectID, "fixture-project")
        XCTAssertTrue(entries[3].disabled)
        for root in [#"[{"type":"antigravity","authIndex":"a","attributes":{"project_id":"p"},"account_id":"id"}]"#,
                     #"{"credentials":[{"provider":"codex","auth_index":"a","project_id":"p","chatgpt_account_id":"id"}]}"#] {
            let credential = try XCTUnwrap(CLIProxyParser.credentials(Data(root.utf8)).first)
            XCTAssertEqual(credential.projectID, "p")
            XCTAssertEqual(credential.accountID, "id")
        }
    }

    func testArgon86PercentAndPriorityAndReset() throws {
        let windows = try CLIProxyParser.antigravity(Data(CLIProxyFixtures.antigravity.utf8), now: now)
        XCTAssertEqual(windows.map(\.title), ["Gemini 4 Argon · 5h", "Gemini 3.8 Flash · 5h", "Other · Daily"])
        XCTAssertEqual(windows.first?.leftPercent, 86)
        XCTAssertTrue(windows[0].resetText.hasPrefix("Resets "))
        let snapshot = MultiUsageSnapshot(sections: [ProviderSection(provider: .antigravity, windows: windows, stats: [], failureText: nil)], codexSnapshot: nil, updatedAt: now)
        XCTAssertEqual(snapshot.globalLowestWindow?.leftPercent, 86)
    }

    func testBothClaudeAccountsAllWindowsAndPrivacy() async throws {
        let sections = await CLIProxyFixtures.client().fetchSections(now: now)
        XCTAssertEqual(sections.map(\.provider), [.claude, .antigravity, .grok])
        XCTAssertEqual(sections[0].windows.map(\.title), ["ali***@e*** · 5h", "ali***@e*** · Weekly", "bob***@s*** · 5h", "bob***@s*** · Weekly"])
        XCTAssertEqual(sections[0].windows.map(\.leftPercent), [79, 64, 79, 64])
        XCTAssertFalse(String(describing: sections).contains("alice@example.test"))
        let extra = #"{"seven_day_opus":{"utilization":0},"seven_day_sonnet":{"utilization":100},"seven_day_oauth_apps":{"utilization":30}}"#
        let windows = try CLIProxyParser.claude(Data(extra.utf8), label: "Account", now: now)
        XCTAssertEqual(windows.map(\.leftPercent), [100, 0, 70])
    }

    func testMissingKeyDoesNotMakeAnyRequest() async {
        let transport = ScriptedTransport([])
        let client = CLIProxyClient(transport: transport, keyProvider: MutableKey(nil), peerVerifier: FixtureCLIProxyPeerVerifier())
        let sections = await client.fetchSections()
        XCTAssertEqual(sections.map(\.failureText), Array(repeating: CLIProxyClient.missingKeyText, count: 3))
        let count = await transport.count
        XCTAssertEqual(count, 0)
    }

    func testUnverifiedPeerDoesNotReadKeyOrSendAndShowsRowErrors() async {
        let transport = ScriptedTransport([])
        let key = MutableKey(UUID().uuidString)
        let client = CLIProxyClient(transport: transport, keyProvider: key,
                                    peerVerifier: FixtureCLIProxyPeerVerifier(trusted: false))
        let sections = await client.fetchSections()
        XCTAssertEqual(key.readCount, 0)
        let count = await transport.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sections.map(\.failureText), Array(repeating: CLIProxyClient.unverifiedPeerText, count: 3))
        let rows = sections.flatMap { ServiceRowModel.rows(for: $0) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.failureText == CLIProxyClient.unverifiedPeerText && $0.primary == nil })
    }

    func testVerifiedPeerPreservesExistingRequestsAndUsage() async {
        let transport = ScriptedTransport([credentials(), usage(), usage(), antigravity()])
        let key = MutableKey(UUID().uuidString)
        let verifier = ScriptedPeerVerifier([true, true, true, true, true])
        let sections = await CLIProxyClient(transport: transport, keyProvider: key,
                                            peerVerifier: verifier).fetchSections(now: now)
        XCTAssertEqual(key.readCount, 1)
        XCTAssertEqual(verifier.checkCount, 5)
        let count = await transport.count
        XCTAssertEqual(count, 4)
        XCTAssertEqual(sections.map(\.failureText), [nil, nil, "No enabled CLIProxyAPI credentials"])
        XCTAssertEqual(sections[0].windows.map(\.leftPercent), [79, 64, 79, 64])
        XCTAssertEqual(sections[1].windows.first?.leftPercent, 86)
    }

    func testPeerIsRecheckedBeforeFirstRequest() async {
        let transport = ScriptedTransport([])
        let key = MutableKey(UUID().uuidString)
        let verifier = ScriptedPeerVerifier([true, false])
        let sections = await CLIProxyClient(transport: transport, keyProvider: key,
                                            peerVerifier: verifier).fetchSections()
        XCTAssertEqual(key.readCount, 1)
        XCTAssertEqual(verifier.checkCount, 2)
        let count = await transport.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(sections.allSatisfy { $0.failureText == CLIProxyClient.unverifiedPeerText })
    }

    func testPeerChangeStopsEveryProvidersQuotaRequest() async {
        for provider in ["claude", "antigravity", "xai"] {
            let inventory = #"{"files":[{"provider":"\#(provider)","auth_index":"one","project_id":"fixture-project"}]}"#
            let transport = ScriptedTransport([(Data(inventory.utf8), 200)])
            let verifier = ScriptedPeerVerifier([true, true, false])
            let sections = await CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(),
                                                peerVerifier: verifier).fetchSections()
            let count = await transport.count
            XCTAssertEqual(count, 1, provider)
            XCTAssertEqual(verifier.checkCount, 3, provider)
            XCTAssertTrue(sections.allSatisfy { $0.failureText == CLIProxyClient.unverifiedPeerText }, provider)
        }
    }

    func testPeerIsRecheckedAfterQuotaRequestsBeforeFallbackOrSecondPeriod() async {
        for provider in ["antigravity", "xai"] {
            let inventory = #"{"files":[{"provider":"\#(provider)","auth_index":"one","project_id":"fixture-project"}]}"#
            let transport = ScriptedTransport([(Data(inventory.utf8), 200), (CLIProxyFixtures.envelope("{}", status: 503), 200)])
            let verifier = ScriptedPeerVerifier([true, true, true, false])
            let sections = await CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(),
                                                peerVerifier: verifier).fetchSections()
            let count = await transport.count
            XCTAssertEqual(count, 2, provider)
            XCTAssertEqual(verifier.checkCount, 4, provider)
            XCTAssertTrue(sections.allSatisfy { $0.failureText == CLIProxyClient.unverifiedPeerText }, provider)
        }
    }

    func testPeerVerificationRecoversOnNextRefresh() async {
        let transport = ScriptedTransport([credentials(), usage(), usage(), antigravity()])
        let key = MutableKey(UUID().uuidString)
        let verifier = ScriptedPeerVerifier([false, true, true, true, true, true])
        let client = CLIProxyClient(transport: transport, keyProvider: key, peerVerifier: verifier)
        let failed = await client.fetchSections()
        XCTAssertTrue(failed.allSatisfy { $0.failureText == CLIProxyClient.unverifiedPeerText })
        XCTAssertEqual(key.readCount, 0)
        let recovered = await client.fetchSections()
        XCTAssertEqual(recovered.map(\.failureText), [nil, nil, "No enabled CLIProxyAPI credentials"])
        XCTAssertEqual(key.readCount, 1)
    }

    func testStableAccountIDsKeepPreferencesAndUsageAcrossReorderingAndRenumbering() async throws {
        let initial = #"{"files":[{"provider":"claude","auth_index":"1","account_id":"stable-account","user_id":"old-user"},{"provider":"claude","auth_index":"2","user_id":"stable-user"}]}"#
        let reordered = #"{"files":[{"provider":"claude","auth_index":"1","user_id":"stable-user"},{"provider":"claude","auth_index":"2","account_id":"stable-account","user_id":"new-user"}]}"#
        let transport = ScriptedTransport([
            (Data(initial.utf8), 200), usage(),
            (CLIProxyFixtures.envelope(#"{"five_hour":{"utilization":63}}"#), 200),
            (Data(reordered.utf8), 200)
        ])
        let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier(), clock: { self.now })
        let firstSections = await client.fetchSections(now: now)
        let first = try XCTUnwrap(firstSections.first { $0.provider == .claude })
        let accountID = try XCTUnwrap(first.accountID(at: 0))
        let userID = try XCTUnwrap(first.accountID(at: 1))
        XCTAssertNotEqual(accountID, userID)
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: accountID)
        preferences.setVisible(false, for: userID)
        preferences.setPrimary(accountID, for: .claude)

        let nextSections = await client.fetchSections(now: now)
        let next = try XCTUnwrap(nextSections.first { $0.provider == .claude })
        XCTAssertEqual(next.accounts.compactMap(\.id), [userID, accountID])
        XCTAssertEqual(next.forAccount(0).windows.first?.leftPercent, 37)
        XCTAssertEqual(next.forAccount(1).windows.first?.leftPercent, 79)
        XCTAssertEqual(preferences.primaryIndex(in: next), 1)
        XCTAssertEqual(preferences.visibleSection(next)?.accounts.compactMap(\.id), [accountID])
        let rows = ServiceRowModel.rows(for: next, accountPreferences: preferences)
        XCTAssertEqual(rows.map(\.name), ["Claude B · Work"])
        XCTAssertEqual(rows.first?.five?.leftPercent, 79)
    }

    func testAccountIdentityFallsBackToAuthIndexWhenStableIDsAreEmpty() async throws {
        let credentials = #"{"files":[{"provider":"claude","auth_index":"legacy","account_id":"  ","user_id":""},{"provider":"claude","auth_index":"other"}]}"#
        let transport = ScriptedTransport([(Data(credentials.utf8), 200), usage(), usage()])
        let sections = await CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections(now: now)
        let section = try XCTUnwrap(sections.first { $0.provider == .claude })
        XCTAssertEqual(section.accountID(at: 0), AccountID(provider: .claude, source: "proxy-auth-index", value: "legacy"))
        XCTAssertEqual(section.accountID(at: 1), AccountID(provider: .claude, source: "proxy-auth-index", value: "other"))
        XCTAssertNotEqual(section.accountID(at: 0), section.accountID(at: 1))
    }

    func test401StopsRefreshAndBacksOffUntilThirtyMinutes() async {
        let clock = TestClock(now)
        let transport = ScriptedTransport([credentials(), (Data(), 401), credentials(), usage(), usage(), antigravity()])
        let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier(), clock: { clock.read() })
        let first = await client.fetchSections(now: now)
        XCTAssertEqual(first.map(\.failureText), Array(repeating: CLIProxyClient.rejectedKeyText, count: 3))
        clock.advance(1799)
        _ = await client.fetchSections(now: now)
        let blockedCount = await transport.count
        XCTAssertEqual(blockedCount, 2)
        clock.advance(1)
        let resumed = await client.fetchSections(now: now)
        XCTAssertEqual(resumed.map(\.failureText), [nil, nil, "No enabled CLIProxyAPI credentials"])
        let resumedCount = await transport.count
        XCTAssertEqual(resumedCount, 6)
    }

    func testCredentials401AndChangedKeyRecovery() async {
        let key = MutableKey(UUID().uuidString)
        let transport = ScriptedTransport([(Data(), 401), credentials(), usage(), usage(), antigravity()])
        let client = CLIProxyClient(transport: transport, keyProvider: key, peerVerifier: FixtureCLIProxyPeerVerifier())
        _ = await client.fetchSections()
        _ = await client.fetchSections()
        let blockedCount = await transport.count
        XCTAssertEqual(blockedCount, 1)
        key.set(UUID().uuidString)
        let sections = await client.fetchSections()
        XCTAssertEqual(sections.map(\.failureText), [nil, nil, "No enabled CLIProxyAPI credentials"])
        let count = await transport.count
        XCTAssertEqual(count, 5)
    }

    func testConcurrentRefreshesShare401Latch() async {
        let transport = ScriptedTransport([(Data(), 401)])
        let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = await client.fetchSections() } }
        }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testAntigravityFallbackAndExactRequestContract() async throws {
        let transport = ScriptedTransport([credentials(), usage(), usage(), (CLIProxyFixtures.envelope("{}", status: 503), 200), (CLIProxyFixtures.envelope(#"{"groups":[]}"#), 200), antigravity()])
        let sections = await CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections(now: now)
        XCTAssertEqual(sections[1].windows.first?.leftPercent, 86)
        XCTAssertEqual(sections[0].windows.map(\.accountIndex), [0, 0, 1, 1])
        let calls = await transport.calls
        XCTAssertEqual(calls.map { $0["authIndex"] as? String }, ["c1", "c2", "a1", "a1", "a1"])
        XCTAssertEqual(calls.suffix(3).compactMap { $0["url"] as? String }, [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        ])
        let headers = try XCTUnwrap(calls[0]["header"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer $TOKEN$")
        XCTAssertEqual(headers["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(headers["User-Agent"], "claude-cli/2.1.280 (external, cli)")
        let raw = try XCTUnwrap(calls[2]["data"] as? String)
        let project = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
        XCTAssertEqual(project, ["project": "fixture-project"])
    }

    func testAccountFailureDoesNotLoseOtherAccountsOrProvider() async {
        let transport = ScriptedTransport([credentials(), (Data(), 500), usage(), antigravity()])
        let sections = await CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections()
        XCTAssertEqual(sections[0].windows.count, 2)
        XCTAssertEqual(sections[0].windows.map(\.accountIndex), [1, 1])
        let bars = CollapsedUsageBar.bars(for: MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: now))
        XCTAssertNil(bars[1].limit)
        XCTAssertEqual(bars[2].limit?.leftPercent, 79) // Claude B 5h
        XCTAssertEqual(sections[0].stats.first?.title, "ali***@e***")
        XCTAssertNotNil(sections[0].failureText)
        XCTAssertNil(sections[1].failureText)
    }

    func testKeyEchoNeverAppearsInOutputOrErrors() async {
        let key = UUID().uuidString
        let echo = "{\"groups\":[{\"displayName\":\"\(key)\",\"buckets\":[{\"remainingFraction\":0.86}]}]}"
        let transport = ScriptedTransport([credentials(), usage(), usage(), (CLIProxyFixtures.envelope(echo), 200)])
        let sections = await CLIProxyClient(transport: transport, keyProvider: MutableKey(key), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections()
        XCTAssertFalse(String(describing: sections).contains(key))
        let failure = await CLIProxyClient(transport: ThrowingTransport(message: key), keyProvider: MutableKey(key), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections()
        XCTAssertFalse(String(describing: failure).contains(key))
        let malformed = ScriptedTransport([(Data(key.utf8), 200)])
        let malformedSections = await CLIProxyClient(transport: malformed, keyProvider: MutableKey(key), peerVerifier: FixtureCLIProxyPeerVerifier()).fetchSections()
        XCTAssertFalse(String(describing: malformedSections).contains(key))
    }

    func testMalformedQuotaNumbersAreNotDisplayed() throws {
        let data = Data(#"{"groups":[{"buckets":[{"remainingFraction":true},{"remainingFraction":-1},{"remainingFraction":2}]}]}"#.utf8)
        XCTAssertTrue(try CLIProxyParser.antigravity(data, now: now).isEmpty)
    }

    func testRedirectDoesNotForwardManagementAuthorization() {
        let transport = CLIProxyURLSessionTransport()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "http://127.0.0.1:8317/v8/management/credentials")!
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: [:])!
        let redirected = URLRequest(url: URL(string: "https://example.test/redirect")!)
        var completionCalled = false
        transport.urlSession(session, task: session.dataTask(with: original),
                             willPerformHTTPRedirection: response, newRequest: redirected) { request in
            completionCalled = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(completionCalled)
    }

    private func credentials() -> (Data, Int) { (Data(CLIProxyFixtures.credentials.utf8), 200) }
    private func usage() -> (Data, Int) { (CLIProxyFixtures.envelope(CLIProxyFixtures.claude), 200) }
    private func antigravity() -> (Data, Int) { (CLIProxyFixtures.envelope(CLIProxyFixtures.antigravity, stringBody: false), 200) }
}

private actor ScriptedTransport: CLIProxyTransport {
    private var responses: [(Data, Int)]
    private(set) var count = 0
    private(set) var calls: [[String: Any]] = []
    init(_ responses: [(Data, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        count += 1
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.port, 8317)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        if let body = request.httpBody {
            XCTAssertEqual(request.url?.path, "/v8/management/requests/api-call")
            XCTAssertEqual(request.httpMethod, "POST")
            calls.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        } else {
            XCTAssertEqual(request.url?.path, "/v8/management/credentials")
            XCTAssertEqual(request.httpMethod, "GET")
        }
        guard !responses.isEmpty else { XCTFail("Unexpected additional request"); return (Data(), 500) }
        return responses.removeFirst()
    }
}

private final class MutableKey: CLIProxyKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var reads = 0
    init(_ value: String?) { self.value = value }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func managementKey() -> String? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class ScriptedPeerVerifier: CLIProxyPeerVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private var checks = 0
    init(_ results: [Bool]) { self.results = results }
    var checkCount: Int { lock.lock(); defer { lock.unlock() }; return checks }
    func isTrustedListener() -> Bool {
        lock.lock(); defer { lock.unlock() }
        checks += 1
        guard !results.isEmpty else { XCTFail("Unexpected peer verification"); return false }
        return results.removeFirst()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

private struct ThrowingTransport: CLIProxyTransport {
    struct EchoError: LocalizedError { let errorDescription: String? }
    let message: String
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw EchoError(errorDescription: message) }
}
