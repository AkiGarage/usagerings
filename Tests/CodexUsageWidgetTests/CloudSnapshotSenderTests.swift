import CloudKit
import XCTest
@testable import CodexUsageWidget

@MainActor
final class CloudSnapshotSenderTests: XCTestCase {
    final class MockTransport: CloudSnapshotTransport {
        var available = true
        var checks = 0
        var sent: [CloudSnapshot] = []
        var error: Error?
        func accountAvailable() async throws -> Bool { checks += 1; return available }
        func save(_ snapshot: CloudSnapshot) async throws {
            if let error { throw error }
            sent.append(snapshot)
        }
    }

    final class DelayedTransport: CloudSnapshotTransport {
        var continuation: CheckedContinuation<Bool, Never>?
        var saves = 0
        func accountAvailable() async throws -> Bool {
            await withCheckedContinuation { continuation = $0 }
        }
        func save(_ snapshot: CloudSnapshot) async throws { saves += 1 }
    }

    func testOptOutWaitsForPendingCheckAndPreventsSend() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = DelayedTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(fixture(80, at: now), now: now)
        while mock.continuation == nil { await Task.yield() }
        let stopping = Task { await sender.setEnabled(false) }
        await Task.yield()
        mock.continuation?.resume(returning: true)
        await stopping.value
        XCTAssertEqual(mock.saves, 0)
    }

    func testPreferenceDefaultsOffAndPersistsOffBeforeWaiting() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let preferences = PanelPreferences(defaults: defaults)
        XCTAssertFalse(preferences.cloudSyncEnabled)
        preferences.setCloudSyncEnabled(true)
        await Task.yield()
        var continuation: CheckedContinuation<Void, Never>?
        preferences.onCloudSyncChange = { enabled in
            if !enabled { await withCheckedContinuation { continuation = $0 } }
        }
        preferences.setCloudSyncEnabled(false)
        XCTAssertTrue(preferences.cloudSyncStopping)
        XCTAssertFalse(defaults.bool(forKey: PanelPreferences.cloudSyncKey))
        while continuation == nil { await Task.yield() }
        continuation?.resume()
        while preferences.cloudSyncStopping { await Task.yield() }
        XCTAssertFalse(preferences.cloudSyncEnabled)
    }

    private func fixture(_ value: Double, at date: Date) -> MultiUsageSnapshot {
        var limit = UsageLimit(title: "5h", leftPercent: value, resetText: "")
        limit.observedAt = date
        return MultiUsageSnapshot(sections: [ProviderSection(provider: .codex,
            windows: [limit],
            stats: [], failureText: nil)], codexSnapshot: nil, updatedAt: date)
    }

    func testChangeThrottleAndRevisionAcrossRestart() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(fixture(80, at: start), now: start)
        await sender.waitForPending()
        sender.offer(fixture(80, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
        await sender.waitForPending()
        sender.offer(fixture(70, at: start.addingTimeInterval(61)), now: start.addingTimeInterval(61))
        await sender.waitForPending()
        sender.offer(fixture(60, at: start.addingTimeInterval(62)), now: start.addingTimeInterval(62))
        await sender.waitForPending()
        XCTAssertEqual(mock.sent.map(\.revision), [1, 2])
        sender.offer(fixture(60, at: start.addingTimeInterval(121)), now: start.addingTimeInterval(121))
        await sender.waitForPending()
        let restarted = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        restarted.offer(fixture(50, at: start.addingTimeInterval(122)), now: start.addingTimeInterval(122))
        await restarted.waitForPending()
        XCTAssertEqual(mock.sent.count, 3)
        restarted.offer(fixture(50, at: start.addingTimeInterval(181)), now: start.addingTimeInterval(181))
        await restarted.waitForPending()
        XCTAssertEqual(mock.sent.map(\.revision), [1, 2, 3, 4])
        XCTAssertEqual(Set(mock.sent.map(\.sourceDeviceID)).count, 1)
        XCTAssertEqual(Set(mock.sent.flatMap { $0.readings.map(\.accountID) }).count, 1)
    }

    func testCachedAgeAndAmbiguousAccounts() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var cached = UsageLimit(title: "Anonymous · Weekly", leftPercent: 50, resetText: "")
        cached.observedAt = now.addingTimeInterval(-600)
        let sections = [
            ProviderSection(provider: .claude, windows: [cached], stats: [], failureText: nil),
            ProviderSection(provider: .grok, windows: [cached], stats: [], failureText: nil,
                            accounts: [ProviderAccount(index: 0), ProviderAccount(index: 1)])
        ]
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: now), now: now)
        await sender.waitForPending()
        let sent = try XCTUnwrap(mock.sent.first)
        XCTAssertEqual(sent.observedAt, cached.observedAt)
        XCTAssertEqual(sent.readings.map(\.provider), ["claude", "grok"])
        XCTAssertEqual(sent.readings.last?.availability, "unavailable")
        XCTAssertNil(sent.readings.last?.remainingPercent)
    }

    func testDisabledAndUnavailableDoNotSendAndRetryLater() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: false)
        sender.offer(fixture(80, at: start), now: start)
        XCTAssertEqual(mock.checks, 0)
        await sender.setEnabled(true)
        mock.available = false
        sender.offer(fixture(80, at: start), now: start)
        await sender.waitForPending()
        XCTAssertTrue(mock.sent.isEmpty)
        mock.available = true
        sender.offer(fixture(80, at: start.addingTimeInterval(10)), now: start.addingTimeInterval(10))
        await sender.waitForPending()
        XCTAssertEqual(mock.checks, 1)
        sender.offer(fixture(80, at: start.addingTimeInterval(60)), now: start.addingTimeInterval(60))
        await sender.waitForPending()
        XCTAssertEqual(mock.sent.map(\.revision), [2])
        await sender.setEnabled(false)
        sender.offer(fixture(70, at: start.addingTimeInterval(120)), now: start.addingTimeInterval(120))
        XCTAssertEqual(mock.sent.count, 1)
    }

    func testServerBackoffAndQuotaSurviveRestart() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date()
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        mock.error = NSError(domain: CKErrorDomain, code: CKError.Code.requestRateLimited.rawValue,
                             userInfo: [CKErrorRetryAfterKey: 300.0])
        sender.offer(fixture(80, at: now), now: now)
        await sender.waitForPending()
        mock.error = nil
        let restarted = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        restarted.offer(fixture(80, at: now.addingTimeInterval(120)), now: now.addingTimeInterval(120))
        await restarted.waitForPending()
        XCTAssertTrue(mock.sent.isEmpty)
        restarted.offer(fixture(80, at: now.addingTimeInterval(301)), now: now.addingTimeInterval(301))
        await restarted.waitForPending()
        XCTAssertEqual(mock.sent.count, 1)

        mock.error = NSError(domain: CKErrorDomain, code: CKError.Code.quotaExceeded.rawValue, userInfo: [:])
        restarted.offer(fixture(70, at: now.addingTimeInterval(361)), now: now.addingTimeInterval(361))
        await restarted.waitForPending()
        mock.error = nil
        let quotaRestart = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        quotaRestart.offer(fixture(70, at: now.addingTimeInterval(900)), now: now.addingTimeInterval(900))
        await quotaRestart.waitForPending()
        XCTAssertEqual(mock.sent.count, 1)
    }

    func testRecordSchemaMatchesPhoneContract() throws {
        let source = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let account = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let observed = Date(timeIntervalSince1970: 1_700_000_000.75)
        let snapshot = CloudSnapshot(sourceDeviceID: source, revision: 42, observedAt: observed,
            publishedAt: observed.addingTimeInterval(1), readings: [CloudReading(provider: "codex", accountID: account,
                window: "session", remainingPercent: 42.5, resetAt: nil, availability: "available")])
        let record = try CloudKitSnapshotTransport.record(snapshot)
        XCTAssertEqual(CloudKitSnapshotTransport.containerID, "iCloud.com.sirailway.usagerings")
        XCTAssertEqual(record.recordType, "UsageSnapshot")
        XCTAssertEqual(record.recordID.recordName, "snapshot-11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(Set(record.allKeys()), Set(["sourceDeviceID", "schemaVersion", "revision", "observedAt", "publishedAt", "payload"]))
        XCTAssertEqual(record["sourceDeviceID"] as? String, source.uuidString.lowercased())
        XCTAssertEqual((record["schemaVersion"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((record["revision"] as? NSNumber)?.int64Value, 42)
        let data = try XCTUnwrap(record["payload"] as? Data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["schemaVersion", "sourceDeviceID", "revision", "observedAt", "publishedAt", "readings"]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CloudSnapshot.self, from: data)
        XCTAssertEqual(record["observedAt"] as? Date, decoded.observedAt)
        XCTAssertEqual(record["publishedAt"] as? Date, decoded.publishedAt)
        XCTAssertEqual(decoded.readings, snapshot.readings)
    }
}

@MainActor
extension CloudSnapshotSenderTests {
    func testEmptyAndUnknownObservationNeverPublish() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        let unknown = UsageLimit(title: "5h", leftPercent: 80, resetText: "")
        let snapshot = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [unknown], stats: [], failureText: nil)], codexSnapshot: nil, updatedAt: now)
        sender.offer(snapshot, now: now)
        sender.offer(MultiUsageSnapshot(sections: [], codexSnapshot: nil, updatedAt: now), now: now)
        await sender.waitForPending()
        XCTAssertTrue(mock.sent.isEmpty)
        XCTAssertEqual(mock.checks, 0)
    }

    func testFailurePublishesUnavailableWithPreviousObservationAndIdentity() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(fixture(80, at: now), now: now)
        await sender.waitForPending()
        let failed = MultiUsageSnapshot(sections: [ProviderSection(provider: .codex, windows: [], stats: [], failureText: "failed")], codexSnapshot: nil, updatedAt: now.addingTimeInterval(60))
        sender.offer(failed, now: now.addingTimeInterval(60))
        await sender.waitForPending()
        let sent = try XCTUnwrap(mock.sent.last)
        XCTAssertEqual(mock.sent.count, 2)
        XCTAssertEqual(sent.observedAt, now)
        XCTAssertEqual(sent.readings.first?.accountID, mock.sent.first?.readings.first?.accountID)
        XCTAssertEqual(sent.readings.first?.availability, "unavailable")
        XCTAssertNil(sent.readings.first?.remainingPercent)
    }

    func testAmbiguousAccountsEmitAnonymousUnavailable() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var first = UsageLimit(title: "5h", leftPercent: 80, resetText: "")
        first.observedAt = now
        var second = first; second.accountIndex = 1
        let section = ProviderSection(provider: .claude, windows: [first, second], stats: [], failureText: nil,
                                      accounts: [ProviderAccount(index: 0), ProviderAccount(index: 1)])
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now), now: now)
        await sender.waitForPending()
        let reading = try XCTUnwrap(mock.sent.first?.readings.first)
        XCTAssertEqual(mock.sent.first?.readings.count, 1)
        XCTAssertEqual(reading.availability, "unavailable")
        XCTAssertNil(reading.remainingPercent)
    }

    func testRetryJitterAndServerMinimum() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var low = RetryPolicy(failures: 0, quotaBlocked: false, nextAttempt: nil)
        var high = low
        low.failed(quotaExceeded: false, retryAfter: nil, now: now, jitter: 0)
        high.failed(quotaExceeded: false, retryAfter: nil, now: now, jitter: 1)
        XCTAssertEqual(low.nextAttempt, now.addingTimeInterval(30))
        XCTAssertEqual(high.nextAttempt, now.addingTimeInterval(40))
        var server = RetryPolicy(failures: 0, quotaBlocked: false, nextAttempt: nil)
        server.failed(quotaExceeded: false, retryAfter: 300, now: now, jitter: 1)
        XCTAssertEqual(server.nextAttempt, now.addingTimeInterval(300))
    }

    func testPreferenceSerializesRapidOnOff() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let preferences = PanelPreferences(defaults: defaults)
        var events: [Bool] = []
        var resume: CheckedContinuation<Void, Never>?
        preferences.onCloudSyncChange = { enabled in
            XCTAssertTrue(Thread.isMainThread)
            events.append(enabled)
            if enabled { await withCheckedContinuation { resume = $0 } }
        }
        preferences.setCloudSyncEnabled(true)
        preferences.setCloudSyncEnabled(false)
        while resume == nil { await Task.yield() }
        XCTAssertEqual(events, [true])
        resume?.resume()
        while preferences.cloudSyncStopping { await Task.yield() }
        XCTAssertEqual(events, [true, false])
        XCTAssertFalse(preferences.cloudSyncEnabled)
    }

    final class FakeDatabase: CloudSnapshotDatabase {
        var existing: CKRecord?
        var saves = 0
        var saveError: Error?
        func record(for id: CKRecord.ID) async throws -> CKRecord {
            guard let existing else { throw CKError(.unknownItem) }
            return existing
        }
        func saveIfUnchanged(_ record: CKRecord) async throws {
            saves += 1
            if let saveError { throw saveError }
            existing = record
        }
    }

    func testGoldenJSONMatchesPhoneSnapshotCodec() throws {
        let snapshot = CloudSnapshot(sourceDeviceID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            revision: 42, observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_001), readings: [CloudReading(
                provider: "codex", accountID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
                window: "session", remainingPercent: 42.5, resetAt: nil, availability: "available")])
        let record = try CloudKitSnapshotTransport.record(snapshot)
        let payload = try XCTUnwrap(record["payload"] as? Data)
        let golden = #"{"observedAt":"2023-11-14T22:13:20Z","publishedAt":"2023-11-14T22:13:21Z","readings":[{"accountID":"AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE","availability":"available","provider":"codex","remainingPercent":42.5,"window":"session"}],"revision":42,"schemaVersion":1,"sourceDeviceID":"11111111-2222-4333-8444-555555555555"}"#
        XCTAssertEqual(payload, Data(golden.utf8))
    }

    func testConflictNeverFallsBackToUnconditionalSave() async throws {
        let db = FakeDatabase()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = CloudSnapshot(sourceDeviceID: id, revision: 2, observedAt: now, publishedAt: now, readings: [])
        db.existing = try CloudKitSnapshotTransport.record(snapshot)
        let transport = CloudKitSnapshotTransport(database: db)
        try await transport.save(snapshot)
        XCTAssertEqual(db.saves, 0)
        let older = CloudSnapshot(sourceDeviceID: id, revision: 1, observedAt: now, publishedAt: now, readings: [])
        try await transport.save(older)
        XCTAssertEqual(db.saves, 0)
        db.existing?["observedAt"] = now.addingTimeInterval(0.5)
        let newer = CloudSnapshot(sourceDeviceID: id, revision: 3, observedAt: now, publishedAt: now, readings: [])
        try await transport.save(newer)
        XCTAssertEqual(db.saves, 1)
        db.existing = nil
        db.saveError = CKError(.serverRecordChanged)
        do { try await transport.save(snapshot); XCTFail("Expected server conflict") } catch {}
        XCTAssertEqual(db.saves, 2)
    }

    func testRealProviderMappingStableAccountsAndNoSecrets() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let salt = Data(repeating: 1, count: 32)
        let a = AccountID(provider: .claude, source: "id", value: "private-a", salt: salt)
        let b = AccountID(provider: .claude, source: "id", value: "private-b", salt: salt)
        var aLimit = UsageLimit(title: "secret label · 5h", leftPercent: 42.5, resetText: "")
        aLimit.accountIndex = 0; aLimit.observedAt = now.addingTimeInterval(-300)
        var bLimit = UsageLimit(title: "other label · Weekly", leftPercent: 13, resetText: "")
        bLimit.accountIndex = 1; bLimit.observedAt = now.addingTimeInterval(-600)
        var grok = UsageLimit(title: "label · Monthly", leftPercent: 30, resetText: "")
        grok.observedAt = now.addingTimeInterval(-100); grok.resetAt = now.addingTimeInterval(1000)
        let sections = [ProviderSection(provider: .claude, windows: [aLimit, bLimit], stats: [], failureText: nil,
                            accounts: [ProviderAccount(index: 0, id: a), ProviderAccount(index: 1, id: b)]),
                        ProviderSection(provider: .grok, windows: [grok], stats: [], failureText: nil),
                        ProviderSection(provider: .antigravity, windows: [grok], stats: [], failureText: nil)]
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: now), now: now)
        await sender.waitForPending()
        let sent = try XCTUnwrap(mock.sent.first)
        XCTAssertEqual(sent.readings.count, 3)
        XCTAssertEqual(Set(sent.readings.map(\.provider)), ["claude", "grok"])
        XCTAssertEqual(Set(sent.readings.filter { $0.provider == "claude" }.map(\.accountID)).count, 2)
        XCTAssertEqual(sent.observedAt, bLimit.observedAt)
        XCTAssertEqual(sent.readings.first(where: { $0.provider == "grok" })?.resetAt, grok.resetAt)
        let payload = try XCTUnwrap(try CloudKitSnapshotTransport.record(sent)["payload"] as? Data)
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("label"))
    }

    func testLostRevisionCreatesNewSource() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport(); let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        first.offer(fixture(80, at: now), now: now); await first.waitForPending()
        let source = try XCTUnwrap(mock.sent.first?.sourceDeviceID)
        defaults.set(Data("{\"sourceDeviceID\":\"\(source.uuidString)\"}".utf8), forKey: CloudSnapshotSender.stateKey)
        let second = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        second.offer(fixture(80, at: now), now: now); await second.waitForPending()
        XCTAssertNotEqual(mock.sent.last?.sourceDeviceID, source)
        XCTAssertEqual(mock.sent.last?.revision, 1)
    }

    func testUnchangedFreshObservationRepublishedBeforeRemainingStale() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport(); let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(fixture(80, at: now), now: now); await sender.waitForPending()
        let later = now.addingTimeInterval(600)
        sender.offer(fixture(80, at: later), now: later); await sender.waitForPending()
        XCTAssertEqual(mock.sent.count, 2)
        XCTAssertEqual(mock.sent.last?.observedAt, later)
    }
}

@MainActor
extension CloudSnapshotSenderTests {
    final class SavingTransport: CloudSnapshotTransport {
        var continuation: CheckedContinuation<Void, Never>?
        var saves = 0
        func accountAvailable() async throws -> Bool { true }
        func save(_ snapshot: CloudSnapshot) async throws {
            saves += 1
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func testOptOutAwaitsAlreadyStartedSave() async {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = SavingTransport(); let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(fixture(80, at: now), now: now)
        while mock.continuation == nil { await Task.yield() }
        var stopped = false
        let stop = Task { await sender.setEnabled(false); stopped = true }
        await Task.yield()
        XCTAssertFalse(stopped)
        sender.offer(fixture(60, at: now.addingTimeInterval(60)), now: now.addingTimeInterval(60))
        mock.continuation?.resume()
        await stop.value
        XCTAssertTrue(stopped)
        sender.offer(fixture(50, at: now.addingTimeInterval(120)), now: now.addingTimeInterval(120))
        XCTAssertEqual(mock.saves, 1)
    }
}

@MainActor
extension CloudSnapshotSenderTests {
}

@MainActor
extension CloudSnapshotSenderTests {
    func testMissingWindowsAreOmittedAndOldestIsTakenFromReadings() async throws {
        let defaults = UserDefaults(suiteName: "CloudSenderTests-\(UUID())")!
        let mock = MockTransport()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var actual = UsageLimit(title: "Weekly", leftPercent: 25, resetText: "")
        actual.observedAt = start.addingTimeInterval(10)
        let sections = [ProviderSection(provider: .claude, windows: [actual], stats: [], failureText: nil),
                        ProviderSection(provider: .codex, windows: [], stats: [ProviderStat(title: "5h", valueText: "Not reported")], failureText: nil)]
        let sender = CloudSnapshotSender(defaults: defaults, transport: mock, enabled: true)
        sender.offer(MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: start), now: start.addingTimeInterval(20))
        await sender.waitForPending()
        let sent = try XCTUnwrap(mock.sent.first)
        XCTAssertEqual(sent.observedAt, actual.observedAt)
        XCTAssertEqual(sent.readings.count, 1)
        XCTAssertEqual(sent.readings.first?.remainingPercent, 25)
        XCTAssertFalse(sent.readings.contains { $0.provider == "codex" })
    }

    func testProviderParsersRetainObservationAndResetTimes() throws {
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let codex = Data(#"[{"provider":"codex","usage":{"updatedAt":"2023-11-14T22:13:20.000Z","primary":{"usedPercent":20},"secondary":null}}]"#.utf8)
        let parsed = try CodexUsageTextParser.parseJSON(codex, now: now)
        XCTAssertEqual(parsed.session?.observedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
