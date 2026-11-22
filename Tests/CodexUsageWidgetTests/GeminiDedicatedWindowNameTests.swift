import XCTest
@testable import CodexUsageWidget

final class GeminiDedicatedWindowNameTests: XCTestCase {
    func testFindsCurrentAndLegacyTitlesOnly() {
        XCTAssertTrue(GeminiDedicatedWindow.isOurs("UsageRings Gemini（バックグラウンド）"))
        XCTAssertTrue(GeminiDedicatedWindow.isOurs("UsageRings: Gemini残量読み取り用・閉じないで"))
        XCTAssertTrue(GeminiDedicatedWindow.isOurs("UsageRings Gemini（自動・閉じても可）"))
        XCTAssertFalse(GeminiDedicatedWindow.isOurs("Gemini"))
        XCTAssertFalse(GeminiDedicatedWindow.isOurs(nil))
        XCTAssertFalse(GeminiDedicatedWindow.name.contains("閉じないで"))
        XCTAssertFalse(GeminiDedicatedWindow.name.contains("閉じても可"))
    }

    func testStatusTextIsQuietWhenHealthy() {
        XCTAssertNil(GeminiDedicatedWindow.statusText(true), "healthy background window needs no clutter in UI")
        XCTAssertEqual(GeminiDedicatedWindow.statusText(false), "自動復旧待ち")
        XCTAssertNil(GeminiDedicatedWindow.statusText(nil))
    }

    func testPageScriptNeverModifiesDOM() {
        // Pure read-only script: never appends elements or modifies Google's page DOM.
        XCTAssertFalse(LiveChromeBridge.pageScript.contains("createElement"))
        XCTAssertFalse(LiveChromeBridge.pageScript.contains("appendChild"))
    }
}
