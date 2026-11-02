import XCTest
@testable import CodexUsageWidget

final class GeminiDedicatedWindowNameTests: XCTestCase {
    func testFindsNewAndOldTitlesOnly() {
        XCTAssertTrue(GeminiDedicatedWindow.isOurs("UsageRings: Gemini残量読み取り用・閉じないで"))
        XCTAssertTrue(GeminiDedicatedWindow.isOurs("UsageRings Gemini（自動・閉じても可）"))
        XCTAssertFalse(GeminiDedicatedWindow.isOurs("Gemini"))
        XCTAssertFalse(GeminiDedicatedWindow.isOurs(nil))
        XCTAssertFalse(GeminiDedicatedWindow.name.contains("閉じても可"))
    }
    func testStatusText() {
        XCTAssertEqual(GeminiDedicatedWindow.statusText(true), "正常")
        XCTAssertEqual(GeminiDedicatedWindow.statusText(false), "ウィンドウなし")
        XCTAssertNil(GeminiDedicatedWindow.statusText(nil))
    }
    func testBannerNotReadBack() {
        // The banner text must not look like usage data to the parser.
        XCTAssertFalse(GeminiDedicatedWindow.bannerScript.contains("%"))
    }
}
