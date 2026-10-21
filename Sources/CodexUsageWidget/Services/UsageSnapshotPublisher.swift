import Foundation

enum UsageSnapshotPublisherError: LocalizedError, Equatable {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support directory is unavailable"
        }
    }
}

struct UsageSnapshotPublisher {
    private let fileManager: FileManager
    private let urls: [URL]

    init(fileManager: FileManager = .default, urls: [URL]? = nil) throws {
        self.fileManager = fileManager
        self.urls = try urls ?? Self.defaultURLs(fileManager: fileManager)
    }

    func publish(_ snapshot: UsageSnapshot) throws {
        let data = try Self.encodedData(for: snapshot)
        for url in urls {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    static func encodedData(for snapshot: UsageSnapshot) throws -> Data {
        let payload = PublishedUsageSnapshot(snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private static func defaultURLs(fileManager: FileManager) throws -> [URL] {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UsageSnapshotPublisherError.applicationSupportUnavailable
        }

        return [
            applicationSupport
                .appendingPathComponent("CodexUsageWidget", isDirectory: true)
                .appendingPathComponent("latest-usage-snapshot.json"),
            URL(fileURLWithPath: "/private/tmp/codex-usage-widget/latest-usage-snapshot.json")
        ]
    }
}

private struct PublishedUsageSnapshot: Encodable {
    let schemaVersion = 2
    let source = "CodexBarCLI"
    let updatedAt: Date
    let session: PublishedUsageLimit?
    let weekly: PublishedUsageLimit?

    init(snapshot: UsageSnapshot) {
        updatedAt = snapshot.updatedAt
        session = snapshot.session.map(PublishedUsageLimit.init)
        weekly = snapshot.weekly.map(PublishedUsageLimit.init)
    }
}

private struct PublishedUsageLimit: Encodable {
    let title: String
    let remainingPercent: Int
    let detailText: String
    let resetText: String
    let projectionText: String
    let markerPercent: Int
    let state: String

    init(limit: UsageLimit) {
        title = limit.title
        remainingPercent = Int(limit.clampedLeftPercent.rounded())
        detailText = limit.detailText ?? ""
        resetText = limit.resetText
        projectionText = limit.projectionText ?? ""
        markerPercent = Int((limit.markerPercent ?? limit.clampedLeftPercent).rounded())
        state = limit.tone.snapshotState
    }
}

private extension UsageTone {
    var snapshotState: String {
        switch self {
        case .healthy:
            "normal"
        case .warning:
            "warning"
        case .critical:
            "critical"
        }
    }
}
