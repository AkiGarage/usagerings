import XCTest
import SwiftUI
@testable import CodexUsageWidget

@MainActor
final class TicketCardRenderTests: XCTestCase {
    func testRenderZaiTicketCard() throws {
        guard let out = ProcessInfo.processInfo.environment["TICKET_CARD_PNG"] else { throw XCTSkip("render only on demand") }
        let now = ISO8601DateFormatter().date(from: "2026-10-21T13:25:00Z")!
        let json = #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2026-10-28 20:13:47"},{"available":false,"expireTime":"2026-10-18 18:48:30"},{"available":true,"expireTime":"2026-10-22 09:00:00"}],"weekResets":[{"available":true,"expireTime":"2026-11-04 20:13:47"}]}}"#
        let section = ProviderSection(provider: .zai, windows: [], stats: [], zaiResetTickets: try ZaiResetTickets.parse(Data(json.utf8)))
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now)
        let bar = CollapsedUsageBar.bars(for: snapshot).first { $0.id == "zai" }!
        let model = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
        print("TICKETLINES", model.extras?.tickets.map { [$0.statusText ?? "", $0.expiresText ?? ""].joined(separator: " · ") } ?? [])
        let renderer = ImageRenderer(content: RingDetailCardView(model: model).background(Color.white))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
