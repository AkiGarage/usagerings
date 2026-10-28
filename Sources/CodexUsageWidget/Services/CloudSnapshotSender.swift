import CloudKit
import Foundation
import Security

// These types mirror the iPhone RingsCore schema, without depending on another worktree.
struct CloudReading: Codable, Equatable {
    let provider: String
    let accountID: UUID
    let window: String
    let remainingPercent: Double?
    let resetAt: Date?
    let availability: String
}

struct CloudSnapshot: Codable {
    let schemaVersion: Int
    let sourceDeviceID: UUID
    let revision: Int64
    let observedAt: Date
    let publishedAt: Date
    let readings: [CloudReading]

    init(sourceDeviceID: UUID, revision: Int64, observedAt: Date, publishedAt: Date, readings: [CloudReading]) {
        schemaVersion = 1
        self.sourceDeviceID = sourceDeviceID
        self.revision = revision
        self.observedAt = observedAt
        self.publishedAt = publishedAt
        self.readings = readings
    }
}

struct CloudSenderState: Codable {
    var sourceDeviceID = UUID()
    var revision: Int64 = 0
    var accountIDs: [String: UUID] = [:]
    var lastReadings: [CloudReading]?
    var lastAttempt: Date?
    var retryAfter: Date?
    var quotaBlocked: Bool?
    var failureCount: Int?
}

protocol CloudSnapshotTransport {
    func accountAvailable() async throws -> Bool
    func save(_ snapshot: CloudSnapshot) async throws
}

struct CloudKitSnapshotTransport: CloudSnapshotTransport {
    static let containerID = "iCloud.com.sirailway.usagerings"
    static let recordType = "UsageSnapshot"
    private var container: CKContainer { CKContainer(identifier: Self.containerID) }

    func accountAvailable() async throws -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              containers.contains(Self.containerID),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit") else { return false }
        return try await container.accountStatus() == .available
    }

    static func record(_ snapshot: CloudSnapshot, existing: CKRecord? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let normalized = try decoder.decode(CloudSnapshot.self, from: data)
        let id = CKRecord.ID(recordName: "snapshot-\(snapshot.sourceDeviceID.uuidString.lowercased())")
        let record = existing ?? CKRecord(recordType: recordType, recordID: id)
        record["sourceDeviceID"] = normalized.sourceDeviceID.uuidString.lowercased()
        record["schemaVersion"] = NSNumber(value: normalized.schemaVersion)
        record["revision"] = NSNumber(value: normalized.revision)
        record["observedAt"] = normalized.observedAt
        record["publishedAt"] = normalized.publishedAt
        record["payload"] = data
        return record
    }

    func save(_ snapshot: CloudSnapshot) async throws {
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "snapshot-\(snapshot.sourceDeviceID.uuidString.lowercased())")
        let existing: CKRecord?
        do {
            let record = try await database.record(for: id)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard record.recordType == Self.recordType,
                  record["sourceDeviceID"] as? String == snapshot.sourceDeviceID.uuidString.lowercased(),
                  (record["schemaVersion"] as? NSNumber)?.intValue == 1,
                  let revision = (record["revision"] as? NSNumber)?.int64Value,
                  let data = record["payload"] as? Data, data.count <= 128_000,
                  let payload = try? decoder.decode(CloudSnapshot.self, from: data),
                  payload.schemaVersion == 1, payload.sourceDeviceID == snapshot.sourceDeviceID,
                  payload.revision == revision, record["observedAt"] as? Date == payload.observedAt,
                  record["publishedAt"] as? Date == payload.publishedAt,
                  revision < snapshot.revision else { throw CloudSenderError.conflict }
            existing = record
        } catch let error as CKError where error.code == .unknownItem {
            existing = nil
        }
        let record = try Self.record(snapshot, existing: existing)
        let result = try await database.modifyRecords(saving: [record], deleting: [],
                                                       savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let saved = result.saveResults[id] else { throw CloudSenderError.conflict }
        _ = try saved.get()
    }
}

enum CloudSenderError: Error { case conflict }

@MainActor
final class CloudSnapshotSender {
    static let stateKey = "cloudSnapshotSenderStateV1"
    static let interval: TimeInterval = 60
    private let defaults: UserDefaults
    private let transport: CloudSnapshotTransport
    private var state: CloudSenderState
    private var enabled: Bool
    private var pending: Task<Void, Never>?
    private var nextAttempt: Date = .distantPast

    init(defaults: UserDefaults, transport: CloudSnapshotTransport = CloudKitSnapshotTransport(), enabled: Bool) {
        self.defaults = defaults
        self.transport = transport
        self.enabled = enabled
        if let data = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(CloudSenderState.self, from: data), saved.revision >= 0 {
            state = saved
        } else {
            // Missing/corrupt revision must never reuse the previous source identity.
            state = CloudSenderState()
        }
        if let lastAttempt = state.lastAttempt { nextAttempt = lastAttempt.addingTimeInterval(Self.interval) }
        if let retryAfter = state.retryAfter { nextAttempt = max(nextAttempt, retryAfter) }
    }

    func setEnabled(_ value: Bool) async {
        enabled = value
        if value {
            state.quotaBlocked = false
            _ = persist()
        } else {
            await pending?.value
        }
    }

    func waitForPending() async { await pending?.value }

    func offer(_ snapshot: MultiUsageSnapshot, now: Date = Date()) {
        guard enabled, state.quotaBlocked != true, pending == nil, now >= nextAttempt else { return }
        let (readings, observedAt) = makeReadings(snapshot, now: now)
        guard readings != state.lastReadings, state.revision < Int64.max,
              snapshot.updatedAt.timeIntervalSince1970 >= 0, snapshot.updatedAt <= now else { return }
        state.revision += 1
        state.lastAttempt = now
        guard persist() else { return }
        let cloud = CloudSnapshot(sourceDeviceID: state.sourceDeviceID, revision: state.revision,
                                  observedAt: observedAt, publishedAt: now, readings: readings)
        nextAttempt = now.addingTimeInterval(Self.interval)
        pending = Task { [weak self] in
            guard let self else { return }
            defer { self.pending = nil }
            do {
                guard try await self.transport.accountAvailable(), self.enabled else { return }
                try await self.transport.save(cloud)
                self.state.lastReadings = readings
                self.state.failureCount = nil
                self.state.retryAfter = nil
                _ = self.persist()
            } catch let error as CKError {
                if error.code == .quotaExceeded { self.state.quotaBlocked = true }
                self.recordFailure(retryAfter: error.retryAfterSeconds)
            } catch { self.recordFailure(retryAfter: nil) }
        }
    }

    private func recordFailure(retryAfter: TimeInterval?) {
        let failures = min(max(state.failureCount ?? 0, 0), 5) + 1
        state.failureCount = failures
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let delay = max(Self.interval, min(30 * pow(2, Double(failures - 1)), 900), serverDelay)
        nextAttempt = max(nextAttempt, Date().addingTimeInterval(delay))
        state.retryAfter = nextAttempt
        _ = persist()
    }

    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.stateKey)
        return true
    }

    private func makeReadings(_ snapshot: MultiUsageSnapshot, now: Date) -> ([CloudReading], Date) {
        var result: [CloudReading] = []
        var oldest = snapshot.updatedAt
        for section in snapshot.sections where [ProviderID.codex, .claude, .grok].contains(section.provider) {
            // Ambiguous multi-account data is omitted rather than assigning identities by position.
            guard section.accountIndices.count <= 1 else { continue }
            let key = section.provider.rawValue
            let id = state.accountIDs[key] ?? UUID()
            state.accountIDs[key] = id
            var seen = Set<String>()
            for limit in section.windows {
                let title = (limit.title.components(separatedBy: " · ").last ?? limit.title).lowercased()
                let window: String
                switch title {
                case "5h", "session": window = "session"
                case "daily": window = "daily"
                case "weekly", "grok weekly": window = "weekly"
                case "monthly", "grok monthly": window = "monthly"
                default: continue
                }
                guard !seen.contains(window), limit.leftPercent.isFinite,
                      (0...100).contains(limit.leftPercent) else { continue }
                if section.provider != .codex, limit.observedAt == nil { continue }
                if let observed = limit.observedAt {
                    guard observed.timeIntervalSince1970.isFinite, observed.timeIntervalSince1970 >= 0,
                          observed <= now else { continue }
                    oldest = min(oldest, observed)
                }
                seen.insert(window)
                let reset = limit.resetAt.flatMap { date in
                    date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= 0 &&
                        date <= Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)).addingTimeInterval(90 * 24 * 60 * 60) ? date : nil
                }
                result.append(CloudReading(provider: key, accountID: id, window: window,
                                           remainingPercent: limit.leftPercent, resetAt: reset, availability: "available"))
            }
        }
        return (result.sorted { "\($0.provider)/\($0.window)" < "\($1.provider)/\($1.window)" }, oldest)
    }
}
