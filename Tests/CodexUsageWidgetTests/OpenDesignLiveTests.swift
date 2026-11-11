import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

/// Explicit opt-in: reads the official local login and makes two read-only API
/// requests. The normal test suite never reads credentials or uses the network.
final class OpenDesignLiveTests: XCTestCase {
    @MainActor
    func testLiveQuotaRendersInAnIsolatedPanel() async throws {
        guard let output = ProcessInfo.processInfo.environment["USAGERINGS_OPENDESIGN_LIVE_OUTPUT"] else {
            throw XCTSkip("Set USAGERINGS_OPENDESIGN_LIVE_OUTPUT to an absolute evidence directory on a logged-in Mac")
        }
        guard output.hasPrefix("/") else { return XCTFail("Evidence directory must be absolute") }
        _ = NSApplication.shared
        let outcome = await OpenDesignUsageClient.live().fetch()
        guard case .loaded(_, let windows) = outcome else {
            // Only the public UI error is printed, never the credential or API body.
            return XCTFail(MultiUsageService.openDesignSection(outcome, now: Date()).failureText ?? "No quota")
        }
        XCTAssertFalse(windows.isEmpty)
        let section = MultiUsageService.openDesignSection(outcome, now: Date())
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: Date())
        let suite = "com.akigarage.usagerings.verify.opendesign.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let panel = MultiPanelContent(snapshot: snapshot, preferences: preferences)
            .padding(12).background(Color(white: 0.10)).environment(\.colorScheme, .dark)
        let png = try DemoSnapshotExporter.renderHostedPNG(panel, appearance: .dark)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("opendesign-live-panel.png"), options: .atomic)
        for window in windows {
            print("OpenDesign \(window.kind.title): \(window.leftPercent)% remaining; reset known: \(window.resetsAt != nil)")
        }
        XCTAssertNil(section.failureText)
        XCTAssertEqual(CollapsedUsageBar.bars(for: snapshot).first { $0.provider == .opendesign }?.label, "OD")
        XCTAssertEqual(ServiceRowModel.rows(for: section).first?.name, "OpenDesign")
    }
}
