import AppKit
import XCTest
@testable import CodexUsageWidget

final class CodexBarRequirementTests: XCTestCase {
    private let states: [CodexBarGate] = [.checking, .ready, .guide, .deferred]
    private let events: [CodexBarGateEvent] = [.probed(installed: true), .probed(installed: false), .openDownload, .later]

    func testReadyOnlyAfterSuccessfulProbe() {
        for state in states {
            for event in events where CodexBarGateMachine.next(state, event) == .ready && state != .ready {
                XCTAssertEqual(event, .probed(installed: true))
            }
        }
    }

    func testGuideOnlyAfterFailedProbe() {
        for state in states {
            for event in events where CodexBarGateMachine.next(state, event) == .guide && state != .guide {
                XCTAssertEqual(event, .probed(installed: false))
            }
        }
    }

    func testDeferredIgnoresEverything() {
        for event in events {
            XCTAssertEqual(CodexBarGateMachine.next(.deferred, event), .deferred)
        }
    }

    func testReadyIsAbsorbing() {
        for event in events {
            XCTAssertEqual(CodexBarGateMachine.next(.ready, event), .ready)
        }
    }

    @MainActor
    func testInstalledShowsNoGuide() {
        var asked = 0
        let controller = CodexBarGuideController(probe: { true }, openURL: { _ in XCTFail() }, ask: { asked += 1; return .alertThirdButtonReturn })
        controller.start()
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(asked, 0)
    }

    @MainActor
    func testMissingShowsGuideAndLaterDefers() {
        var asked = 0
        let controller = CodexBarGuideController(probe: { false }, openURL: { _ in XCTFail() }, ask: { asked += 1; return .alertThirdButtonReturn })
        controller.start()
        XCTAssertEqual(controller.state, .deferred)
        XCTAssertEqual(asked, 1)
    }

    @MainActor
    func testDownloadOpensOfficialLinkOnceAndDefers() {
        var opened: [URL] = []
        let controller = CodexBarGuideController(probe: { false }, openURL: { opened.append($0) }, ask: { .alertFirstButtonReturn })
        controller.start()
        XCTAssertEqual(opened, [CodexBarRequirement.downloadURL])
        XCTAssertEqual(controller.state, .deferred)
    }

    @MainActor
    func testCheckAgainBecomesReadyAfterInstall() {
        var probes = [false, true]
        let controller = CodexBarGuideController(probe: { probes.removeFirst() }, openURL: { _ in }, ask: { .alertSecondButtonReturn })
        controller.start()
        XCTAssertEqual(controller.state, .ready)
    }

    func testMissingFileIsNotInstalled() {
        XCTAssertFalse(CodexBarRequirement.isInstalled(path: "/nonexistent/CodexBarCLI"))
    }

    func testGuideTextFollowsLanguage() {
        XCTAssertEqual(CodexBarGuideText.current(languages: ["ja-JP"]), .japanese)
        XCTAssertEqual(CodexBarGuideText.current(languages: ["en-US"]), .english)
        XCTAssertTrue(CodexBarRequirement.downloadURL.absoluteString.hasPrefix("https://github.com/steipete/CodexBar"))
    }
}
