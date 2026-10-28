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
        MultiUsageSnapshot(sections: [ProviderSection(provider: .codex,
            windows: [UsageLimit(title: "5h", leftPercent: value, resetText: "")],
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
        XCTAssertEqual(sent.readings.map(\.provider), ["claude"])
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
