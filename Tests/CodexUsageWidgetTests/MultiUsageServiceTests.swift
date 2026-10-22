import XCTest
@testable import CodexUsageWidget

final class MultiUsageServiceTests: XCTestCase {
    private enum Fixture {
        case allSuccess
        case zaiFails
        case codexCarriesAccount
        case balanceReadFails
    }

    func testFetchAllAssemblesAllProvidersInOrder() async throws {
        let service = MultiUsageService(commandRunner: commandRunner(for: .allSuccess), cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll(now: fixedNow, timeZone: utc, calendar: utcCalendar)

        XCTAssertEqual(snapshot.sections.map(\.provider), [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .antigravity])

        let codex = snapshot.sections[0]
        XCTAssertEqual(codex.windows.map(\.title), ["Weekly"])
        XCTAssertEqual(codex.windows.map(\.leftPercent), [81])
        XCTAssertEqual(codex.codexExtras?.creditsText, "61,003 credits")
        XCTAssertEqual(codex.codexExtras?.availableCount, 2)
        XCTAssertEqual(codex.codexExtras?.tickets.compactMap(\.status),
                       Optional(["available", "used", "available"]))
        XCTAssertTrue(snapshot.sections.filter { $0.provider != .codex }.allSatisfy { $0.codexExtras == nil })
        XCTAssertEqual(
            codex.stats,
            [
                ProviderStat(title: "5h", valueText: "Not reported"),
                ProviderStat(title: "Credits", valueText: "61,003 credits"),
                ProviderStat(title: "Reset tickets", valueText: "2 available · next expires 10/22 20:56"),
                ProviderStat(title: "Reset ticket", valueText: "使用可 · 期限 10/22 20:56"),
                ProviderStat(title: "Reset ticket", valueText: "使用済み · 期限 11/1 00:00"),
                ProviderStat(title: "Reset ticket", valueText: "使用可 · 期限 11/19 20:56"),
                ProviderStat(title: "Reset ticket expiry", valueText: "2026-10-22T20:56:33Z"),
                ProviderStat(title: "Reset ticket expiry", valueText: "2026-11-19T20:56:33Z")
            ]
        )
        XCTAssertEqual(snapshot.codexSnapshot?.weekly?.leftPercent, 81)

        let zai = snapshot.sections[3]
        XCTAssertEqual(zai.windows.map(\.title), ["5h", "MCP"])
        XCTAssertEqual(zai.windows.map(\.leftPercent), [90, 99.6])

        let claude = snapshot.sections[1]
        XCTAssertEqual(claude.windows.map(\.title), ["ali***@e*** · 5h", "ali***@e*** · Weekly", "bob***@s*** · 5h", "bob***@s*** · Weekly"])
        XCTAssertEqual(claude.windows.map(\.leftPercent), [79, 64, 79, 64])
        XCTAssertEqual(snapshot.globalLowestWindow?.title, "ali***@e*** · Weekly")
        XCTAssertEqual(snapshot.globalLowestWindow?.clampedLeftPercent, 64)
    }

    func testOneProviderFailingLeavesOthersIntact() async throws {
        let service = MultiUsageService(commandRunner: commandRunner(for: .zaiFails), cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll(now: fixedNow, timeZone: utc, calendar: utcCalendar)

        XCTAssertEqual(snapshot.sections.map(\.provider), [.codex, .claude, .grok, .zai, .minimax, .kimi, .deepseek, .antigravity])
        XCTAssertNil(snapshot.sections[0].failureText)
        XCTAssertNotNil(snapshot.sections[3].failureText)
        XCTAssertFalse(snapshot.sections[3].failureText!.contains("synthetic-sensitive-message"))
        XCTAssertNil(snapshot.sections[1].failureText)
        XCTAssertEqual(snapshot.sections[1].windows.count, 4)
    }

    func testCodexAccountFieldsNeverReachSections() async throws {
        let service = MultiUsageService(commandRunner: commandRunner(for: .codexCarriesAccount), cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll(now: fixedNow, timeZone: utc, calendar: utcCalendar)

        let encoded = String(
            data: try JSONEncoder().encode(snapshot.sections.map(\.stats)),
            encoding: .utf8
        ) ?? ""
        let allTexts = snapshot.sections.flatMap { section -> [String] in
            section.stats.map(\.valueText) + (section.failureText.map { [$0] } ?? [])
        }.joined()
        XCTAssertFalse(allTexts.contains("synthetic-account@example.test"))
        XCTAssertFalse(encoded.contains("synthetic-account@example.test"))
    }

    func testBalanceReadFailureReportsNotReadable() async throws {
        let service = MultiUsageService(commandRunner: commandRunner(for: .balanceReadFails), cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll(now: fixedNow, timeZone: utc, calendar: utcCalendar)

        XCTAssertEqual(
            snapshot.sections[0].stats.first { $0.title == "Credits" }?.valueText,
            "Not readable"
        )
        XCTAssertEqual(
            snapshot.sections[0].stats.first { $0.title == "5h" }?.valueText,
            "Not reported"
        )
        XCTAssertNil(snapshot.sections[0].codexExtras)
    }

    private func commandRunner(for fixture: Fixture) -> CodexUsageService.CommandRunner {
        { arguments in
            XCTAssertTrue(["codex", "zai", "minimax", "kimi", "deepseek"].contains(arguments[2]))
            let provider = arguments[2]
            var json: String
            switch provider {
            case "codex":
                json = fixture == .balanceReadFails ? Self.codexBalanceFailed : Self.codex
                if fixture == .codexCarriesAccount {
                    json = Self.codexWithAccount
                }
            case "zai":
                guard fixture != .zaiFails else {
                    return CodexUsageService.CommandResult(
                        terminationStatus: 1,
                        stdout: Data(Self.zaiError.utf8),
                        stderr: Data()
                    )
                }
                json = Self.zai
            case "minimax", "kimi":
                json = AdditionalCodexBarFixtures.quota(provider)
            case "deepseek":
                json = AdditionalCodexBarFixtures.balance
            default:
                json = Self.claude
            }
            return CodexUsageService.CommandResult(
                terminationStatus: 0,
                stdout: Data(json.utf8),
                stderr: Data()
            )
        }
    }

    private static let codex = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": { "usedPercent": null, "windowMinutes": null, "resetsAt": null },
              "secondary": { "usedPercent": 19, "windowMinutes": 10080, "resetsAt": "2026-10-22T06:38:56Z" },
              "codexResetCredits": {
                "availableCount": 2,
                "credits": [
                  { "status": "available", "expires_at": "2026-10-22T20:56:33Z" },
                  { "status": "available", "expires_at": "2026-11-19T20:56:33Z" },
                  { "status": "used", "expires_at": "2026-11-01T00:00:00Z" }
                ]
              }
            },
            "credits": { "remaining": 61003.3201295, "balanceReadSucceeded": true }
          }
        ]
        """

    private static let codexWithAccount = """
        [
          {
            "provider": "codex",
            "account": { "email": "synthetic-account@example.test" },
            "usage": {
              "primary": { "usedPercent": null, "windowMinutes": null, "resetsAt": null },
              "secondary": { "usedPercent": 19, "windowMinutes": 10080, "resetsAt": "2026-10-22T06:38:56Z" },
              "codexResetCredits": {
                "availableCount": 1,
                "credits": [
                  { "status": "available", "expires_at": "2026-10-22T20:56:33Z", "title": "synthetic-marketing-title", "description": "synthetic-marketing-text" }
                ]
              }
            },
            "credits": { "remaining": 61003.3201295, "balanceReadSucceeded": true }
          }
        ]
        """

    private static let codexBalanceFailed = """
        [
          {
            "provider": "codex",
            "usage": {
              "primary": { "usedPercent": null, "windowMinutes": null, "resetsAt": null },
              "secondary": { "usedPercent": 19, "windowMinutes": 10080, "resetsAt": "2026-10-22T06:38:56Z" }
            },
            "credits": { "balanceReadSucceeded": false }
          }
        ]
        """

    private static let zai = """
        [
          {
            "provider": "zai",
            "usage": {
              "primary": { "usedPercent": 10, "windowMinutes": 300, "resetsAt": "2026-10-16T15:52:28Z" },
              "secondary": null,
              "tertiary": null,
              "extraRateWindows": [
                { "title": "MCP", "window": { "usedPercent": 0.4, "windowMinutes": 43200, "resetsAt": "2026-11-04T05:08:05Z" } }
              ]
            }
          }
        ]
        """

    private static let claude = """
        [
          {
            "provider": "claude",
            "usage": {
              "primary": { "usedPercent": 21, "windowMinutes": 300, "resetsAt": "2026-10-16T14:39:59Z" },
              "secondary": { "usedPercent": 36, "windowMinutes": 10080, "resetsAt": "2026-10-21T16:59:59Z" }
            }
          }
        ]
        """

    private static let zaiError = """
        [
          {
            "provider": "zai",
            "error": { "code": 1, "kind": "provider", "message": "synthetic-sensitive-message" }
          }
        ]
        """

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
    }

    private var utc: TimeZone {
        TimeZone(identifier: "UTC")!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
}
