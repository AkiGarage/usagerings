import Foundation

enum MultiAppPaths {
    /// Published-snapshot paths owned by the multi app so the classic app's
    /// snapshot files are never shared.
    static func defaultSnapshotURLs(fileManager: FileManager = .default) throws -> [URL] {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw UsageSnapshotPublisherError.applicationSupportUnavailable
        }

        return [
            applicationSupport
                .appendingPathComponent("CodexUsageWidget-Multi", isDirectory: true)
                .appendingPathComponent("latest-usage-snapshot.json"),
            URL(fileURLWithPath: "/private/tmp/codex-usage-widget-multi/latest-usage-snapshot.json")
        ]
    }
}
