import Foundation
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class ZaiResetTicketsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")!
    private static let fixture = Data(#"""
    {"code":200,"success":true,"data":{
      "customerId":"synthetic-ignored",
      "fiveHourResets":[
        {"recordId":"synthetic-unused","available":true,"expireTime":"2026-10-24T00:00:00Z"},
        {"available":false,"expireTime":"2026-10-23T00:00:00Z"},
        {"available":true,"expireTime":"2026-10-20T00:00:00Z"}],
      "weekResets":[{"available":true,"expireTime":"2026-10-22T00:00:00.000Z"}]
    }}
    """#.utf8)

    private func card(_ inventory: ZaiResetTickets?) -> RingDetailCardModel? {
        let section = ProviderSection(provider: .zai, windows: [], stats: [], zaiResetTickets: inventory)
        let snapshot = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: now)
        let bar = CollapsedUsageBar.bars(for: snapshot).first { $0.id == "zai" }!
        return RingDetailCardModel.make(bar: bar, now: now)
    }

    func testAvailableCountExpiryOrderAndUnavailableStatesReachHoverCard() throws {
        let model = try XCTUnwrap(card(ZaiResetTickets.parse(Self.fixture)))
        let extras = try XCTUnwrap(model.extras)
        XCTAssertEqual(extras.availableCount, 2)
        XCTAssertEqual(extras.tickets.map(\.title), ["5時間リセット", "週リセット", "5時間リセット", "5時間リセット"])
        XCTAssertEqual(extras.tickets.map(\.statusText), ["期限切れ", "使用可", "使用不可", "使用可"])
        XCTAssertEqual(extras.tickets.map(\.isGreyedOut), [true, false, true, false])
        XCTAssertTrue(extras.tickets[1].expiresText?.contains("10/22 09:00") == true)
        XCTAssertNil(model.ticketFailureText)
    }

    func testEmptyInventoryIsZeroButFailureAndMissingInventoryAreNot() throws {
        let empty = Data(#"{"code":200,"success":true,"data":{"fiveHourResets":[],"weekResets":[]}}"#.utf8)
        XCTAssertEqual(try card(ZaiResetTickets.parse(empty))?.extras?.availableCount, 0)
        XCTAssertNil(card(.unavailable)?.extras)
        XCTAssertEqual(card(.unavailable)?.ticketFailureText, "リセット券を取得できません")
        XCTAssertNil(card(nil))
    }

    func testMissingMalformedAmbiguousAndBusinessErrorResponsesFailClosed() {
        for json in [
            #"{"code":200,"success":true,"data":{}}"#,
            #"{"code":200,"success":true,"data":{"fiveHourResets":[],"weekResets":null}}"#,
            #"{"code":200,"success":false,"data":{"fiveHourResets":[],"weekResets":[]}}"#,
            #"{"code":401,"success":true,"data":{"fiveHourResets":[],"weekResets":[]}}"#,
            #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true}],"weekResets":[]}}"#,
            #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2026-10-22 12:00"}],"weekResets":[]}}"#,
            #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2026/10/22 12:00:00"}],"weekResets":[]}}"#,
            #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":1,"expireTime":"2026-10-22T00:00:00Z"}],"weekResets":[]}}"#
        ] {
            XCTAssertThrowsError(try ZaiResetTickets.parse(Data(json.utf8)))
        }
    }

    func testZonelessLiveFormatIsChinaTimeShownInJST() throws {
        let json = #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2026-10-28 20:13:47"},{"available":false,"expireTime":"2026-10-18 18:48:30"}],"weekResets":[]}}"#
        guard case .loaded(let tickets) = try ZaiResetTickets.parse(Data(json.utf8)) else { return XCTFail() }
        XCTAssertEqual(tickets.map(\.expiresAt), ["2026-10-28T12:13:47Z", "2026-10-18T10:48:30Z"].map { ISO8601DateFormatter().date(from: $0)! })
        let model = try XCTUnwrap(card(.loaded(tickets)))
        XCTAssertEqual(model.extras?.availableCount, 1)
        let texts = model.extras?.tickets.compactMap(\.expiresText) ?? []
        XCTAssertTrue(texts.contains("期限 10/28 21:13 JST"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("時帯未確認") })
    }

    func testChinaExpiryInstantDrivesExpiredState() throws {
        // 20:13 CN == 21:13 JST. At 21:00 JST the ticket is still valid; at 21:14 JST it is expired.
        let json = #"{"code":200,"success":true,"data":{"fiveHourResets":[{"available":true,"expireTime":"2026-10-28 20:13:47"}],"weekResets":[]}}"#
        guard case .loaded(let tickets) = try ZaiResetTickets.parse(Data(json.utf8)) else { return XCTFail() }
        let ticket = try XCTUnwrap(tickets.first)
        XCTAssertGreaterThan(ticket.expiresAt, ISO8601DateFormatter().date(from: "2026-10-28T21:00:00+09:00")!)
        XCTAssertLessThan(ticket.expiresAt, ISO8601DateFormatter().date(from: "2026-10-28T21:14:00+09:00")!)
    }

    func testExpiryAtNowIsAlreadyUnavailable() {
        let model = card(.loaded([.init(title: "週リセット", available: true, expiresAt: now)]))
        XCTAssertEqual(model?.extras?.availableCount, 0)
        XCTAssertEqual(model?.extras?.tickets.first?.statusText, "期限切れ")
    }

    func testClientUsesOneFixedReadOnlyRequestAndReturnsParsedInventory() async throws {
        let client = ZaiResetTicketClient(loadKey: { "synthetic-key" }, transport: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertNil(request.httpBody)
            return (Self.fixture, 200)
        })
        let result = await client.fetch()
        XCTAssertEqual(result, try ZaiResetTickets.parse(Self.fixture))
    }

    func testClientFailureDoesNotBecomeZeroAndDoesNotRetry() async {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }
        let counter = Counter()
        let client = ZaiResetTicketClient(loadKey: { "synthetic-key" }, transport: { _ in
            await counter.increment()
            throw URLError(.timedOut)
        })
        let result = await client.fetch()
        let count = await counter.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(count, 1)
        XCTAssertNil(card(result)?.extras?.availableCount)
    }

    func testTicketFailurePreservesExistingQuotaThroughService() async throws {
        let client = ZaiResetTicketClient(loadKey: { "synthetic-key" }, transport: { _ in
            throw URLError(.timedOut)
        })
        let service = MultiUsageService(commandRunner: { arguments in
            let provider = arguments[2]
            let data = Data("[{\"provider\":\"\(provider)\",\"usage\":{\"primary\":{\"usedPercent\":25,\"windowMinutes\":300}}}]".utf8)
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: data, stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client(), zaiTicketClient: client)
        let snapshot = await service.fetchAll(now: now)
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .zai })
        XCTAssertNil(section.failureText)
        XCTAssertEqual(section.windows.first?.leftPercent, 75)
        XCTAssertEqual(section.zaiResetTickets, .unavailable)
        let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot).first { $0.id == "zai" })
        let model = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: now))
        XCTAssertEqual(model.rows.first?.leftPercent, 75)
        XCTAssertNotNil(model.ticketFailureText)
        XCTAssertNil(model.extras?.availableCount)
    }

    func testClientRejectsRedirectAndBusinessFailure() async {
        for status in [302, 401, 500] {
            let client = ZaiResetTicketClient(loadKey: { "synthetic-key" }, transport: { _ in (Self.fixture, status) })
            let result = await client.fetch()
            XCTAssertEqual(result, .unavailable)
        }
        let client = ZaiResetTicketClient(loadKey: { "synthetic-key" }, transport: { _ in
            (Data(#"{"code":401,"success":false,"msg":"synthetic-error"}"#.utf8), 200)
        })
        let result = await client.fetch()
        XCTAssertEqual(result, .unavailable)
    }

    func testInvalidKeyNeverReachesTransport() async {
        for key in ["", "synthetic\r\ninjected"] {
            let client = ZaiResetTicketClient(loadKey: { key }, transport: { _ in
                XCTFail("Invalid key reached transport")
                return (Self.fixture, 200)
            })
            let result = await client.fetch()
            XCTAssertEqual(result, .unavailable)
        }
    }
}
