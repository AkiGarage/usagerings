import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class AccountPreferencesTests: XCTestCase {
    private func section(_ provider: ProviderID, order: [String] = ["one", "two"]) -> ProviderSection {
        let windows = order.enumerated().flatMap { index, name -> [UsageLimit] in
            ["5h", "Weekly"].enumerated().map { windowIndex, title in
                var window = UsageLimit(title: provider == .antigravity ? "Gemini Models · \(title)" : title,
                    leftPercent: (name == "one" ? 80 : 40) - Double(windowIndex * 10), resetText: "Reset pending")
                window.accountIndex = index
                return window
            }
        }
        return ProviderSection(provider: provider, windows: windows, stats: [], failureText: nil,
            accounts: order.enumerated().map { index, value in
                ProviderAccount(index: index, id: AccountID(provider: provider, source: "id", value: value))
            })
    }

    private func snapshot(_ sections: [ProviderSection]) -> MultiUsageSnapshot {
        MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: Date())
    }

    func testIdentityIsStableNamespacedSHA256AndIgnoresSecretFields() throws {
        let entry: [String: Any] = ["usage": ["accountEmail": "synthetic@example.test"],
                                   "access_token": "synthetic-secret", "api_key": "synthetic-key"]
        let id = try XCTUnwrap(AccountID.codexBar(entry, provider: .codex))
        XCTAssertEqual(id.rawValue.count, 64)
        XCTAssertNotNil(AccountID(digest: id.rawValue))
        XCTAssertEqual(id, AccountID.codexBar(["usage": ["accountEmail": "SYNTHETIC@example.test"]], provider: .codex))
        XCTAssertNotEqual(id, AccountID.codexBar(entry, provider: .grok))
        XCTAssertNil(AccountID.codexBar(["token": "synthetic-secret", "key": "synthetic-key"], provider: .codex))
        XCTAssertNil(AccountID(digest: "synthetic@example.test"))
        XCTAssertNil(AccountID(digest: String(repeating: "z", count: 64)))
    }

    func testDiagnosticOutputNeverWritesProviderSuppliedText() throws {
        let section = ProviderSection(provider: .codex,
            windows: [UsageLimit(title: "synthetic@example.test · 5h", leftPercent: 75,
                                 resetText: "synthetic-secret", detailText: "synthetic-key")],
            stats: [ProviderStat(title: "synthetic-secret", valueText: "synthetic@example.test")],
            failureText: "synthetic-key")
        let data = try XCTUnwrap(MultiUsageService.windowDumpData([section]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["@", "synthetic-secret", "synthetic-key", "token", "apiKey", "accountEmail"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["provider", "window", "left"])
        XCTAssertEqual(rows[0]["window"] as? String, "5h")
        XCTAssertEqual(rows[0]["left"] as? Double, 75)
    }

    @MainActor
    func testLabelsVisibilityPrimaryPersistenceAndClearUseOnlyHashes() throws {
        let suite = "AccountPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PanelPreferences(defaults: defaults)
        let entry: [String: Any] = ["usage": ["accountEmail": "synthetic@example.test"],
                                   "token": "synthetic-secret", "apiKey": "synthetic-key"]
        let id = try XCTUnwrap(AccountID.codexBar(entry, provider: .codex))
        settings.setAccountLabel("  Work account  ", for: id)
        settings.setAccountVisible(false, for: id)
        settings.setPrimaryAccount(id, for: .codex)
        let data = try XCTUnwrap(defaults.data(forKey: PanelPreferences.accountPreferencesKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(object["accounts"] as? [String: [String: Any]])
        XCTAssertEqual(Set(accounts.keys), [id.rawValue])
        XCTAssertTrue(accounts.keys.allSatisfy { AccountID(digest: $0) != nil })
        XCTAssertEqual(Set(try XCTUnwrap(accounts[id.rawValue]).keys), ["label", "hidden"])
        let persisted = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["synthetic@example.test", "synthetic-secret", "synthetic-key", "token", "apiKey", "accountEmail"] {
            XCTAssertFalse(persisted.contains(forbidden))
        }
        let restored = PanelPreferences(defaults: defaults)
        XCTAssertEqual(restored.accountPreferences, settings.accountPreferences)
        XCTAssertEqual(restored.accountPreferences.label(for: id), "Work account")
        XCTAssertFalse(restored.accountPreferences.isVisible(id))
        XCTAssertEqual(restored.accountPreferences.primaryAccounts["codex"], id.rawValue)
        restored.setAccountLabel(" \n ", for: id)
        restored.setAccountVisible(true, for: id)
        restored.setPrimaryAccount(nil, for: .codex)
        let cleared = PanelPreferences(defaults: defaults).accountPreferences
        XCTAssertTrue(cleared.accounts.isEmpty)
        XCTAssertTrue(cleared.primaryAccounts.isEmpty)
        XCTAssertTrue(cleared.isVisible(id))
    }

    @MainActor
    func testMalformedStoredIDsAreNotLoadedOrWrittenBack() throws {
        let suite = "AccountPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = #"{"accounts":{"synthetic@example.test":{"label":"Work","hidden":true}},"primaryAccounts":{"codex":"synthetic@example.test"},"token":"synthetic-secret"}"#
        defaults.set(Data(invalid.utf8), forKey: PanelPreferences.accountPreferencesKey)
        let settings = PanelPreferences(defaults: defaults)
        XCTAssertTrue(settings.accountPreferences.accounts.isEmpty)
        XCTAssertTrue(settings.accountPreferences.primaryAccounts.isEmpty)
        settings.setAccountLabel("Personal", for: .singleton(.grok))
        let stored = try XCTUnwrap(defaults.data(forKey: PanelPreferences.accountPreferencesKey))
        let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
        XCTAssertFalse(text.contains("@"))
        XCTAssertFalse(text.contains("synthetic-secret"))
        XCTAssertFalse(text.contains("token"))
        defaults.set(Data("invalid".utf8), forKey: PanelPreferences.accountPreferencesKey)
        XCTAssertEqual(PanelPreferences(defaults: defaults).accountPreferences, AccountPreferences())
    }

    func testEveryProviderLabelsRowsRingsAndCardsWithoutExposingMaskedNames() throws {
        for provider in ProviderID.allCases {
            let section = section(provider)
            let id = try XCTUnwrap(section.accounts[1].id)
            var preferences = AccountPreferences()
            preferences.setLabel("Work account", for: id)
            let rows = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true, accountPreferences: preferences)
            let row = try XCTUnwrap(rows.first { $0.accountID == id })
            XCTAssertTrue(row.name.contains("Work account"))
            XCTAssertNil(row.account)
            XCTAssertEqual(row.five?.leftPercent, 40)
            XCTAssertEqual(row.week?.leftPercent, 30)
            let bars = CollapsedUsageBar.bars(for: snapshot([section]), splitAntigravityAccounts: true, accountPreferences: preferences)
            let bar = try XCTUnwrap(bars.first { $0.accountID == id && !$0.windows.isEmpty })
            XCTAssertTrue(bar.ringName.contains("Work account"))
            let card = try XCTUnwrap(RingDetailCardModel.make(bar: bar, now: Date()))
            XCTAssertTrue(card.title.contains("Work account"))
            XCTAssertEqual(card.rows.map(\.leftPercent), [40, 30])
            let arcs = MultiCollapsedUsageView.g1(for: bar, rows: rows)
            XCTAssertEqual(arcs.outer?.leftPercent, 40)
            XCTAssertEqual(arcs.inner?.leftPercent, 30)
        }
    }

    @MainActor
    func testUndecodablePreferencesAreBackedUpAndNeverOverwritten() throws {
        let suite = "AccountPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("invalid preferences".utf8)
        defaults.set(corrupt, forKey: PanelPreferences.accountPreferencesKey)
        let id = AccountID.singleton(.codex)
        let settings = PanelPreferences(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesBackupKey), corrupt)
        settings.setAccountLabel("Work", for: id)
        settings.setAccountVisible(false, for: id)
        settings.setPrimaryAccount(id, for: .codex)
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesKey), corrupt)
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesBackupKey), corrupt)

        let future = Data(#"{"accounts":[{"future":"schema"}],"primaryAccounts":{}}"#.utf8)
        defaults.set(future, forKey: PanelPreferences.accountPreferencesKey)
        PanelPreferences(defaults: defaults).setAccountLabel("Personal", for: id)
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesKey), future)
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesBackupKey), corrupt)

        var recovered = AccountPreferences()
        recovered.setLabel("Recovered", for: id)
        defaults.set(try JSONEncoder().encode(recovered), forKey: PanelPreferences.accountPreferencesKey)
        PanelPreferences(defaults: defaults).setAccountLabel("Updated", for: id)
        XCTAssertEqual(PanelPreferences(defaults: defaults).accountPreferences.label(for: id), "Updated")
        XCTAssertEqual(defaults.data(forKey: PanelPreferences.accountPreferencesBackupKey), corrupt)
    }

    @MainActor
    func testLoadedLabelsAreTrimmedAndClampedToEightyCharacters() throws {
        let suite = "AccountPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = AccountID.singleton(.codex)
        let emptyID = AccountID.singleton(.grok)
        let label = String(repeating: "👩🏽‍💻", count: 85)
        let data = try JSONSerialization.data(withJSONObject: [
            "accounts": [id.rawValue: ["label": "  \(label)\n", "hidden": true],
                         emptyID.rawValue: ["label": " \n ", "hidden": false]],
            "primaryAccounts": ["codex": id.rawValue]
        ])
        defaults.set(data, forKey: PanelPreferences.accountPreferencesKey)
        let settings = PanelPreferences(defaults: defaults)
        XCTAssertEqual(settings.accountPreferences.label(for: id), String(repeating: "👩🏽‍💻", count: 80))
        XCTAssertNil(settings.accountPreferences.label(for: emptyID))
        XCTAssertFalse(settings.accountPreferences.isVisible(id))
        XCTAssertEqual(settings.accountPreferences.primaryAccounts["codex"], id.rawValue)
        settings.setAccountVisible(true, for: id)
        let saved = PanelPreferences(defaults: defaults)
        XCTAssertEqual(saved.accountPreferences.label(for: id)?.count, 80)
        XCTAssertNil(defaults.object(forKey: PanelPreferences.accountPreferencesBackupKey))
    }

    func testRingNamesStripProviderSuffixBeforeAddingCustomLabel() throws {
        for provider in [ProviderID.claude, .zai] {
            let section = section(provider, order: ["one"])
            let id = try XCTUnwrap(section.accounts.first?.id)
            for label in ["Work 5h team", "Work 5h", "Work · 5h team"] {
                var preferences = AccountPreferences()
                preferences.setLabel(label, for: id)
                let bar = try XCTUnwrap(CollapsedUsageBar.bars(for: snapshot([section]),
                    accountPreferences: preferences).first { $0.provider == provider })
                let expected = "\(provider == .claude ? "Claude A" : "GLM") · \(label)"
                XCTAssertEqual(bar.ringName, expected)
                XCTAssertEqual(RingDetailCardModel.make(bar: bar, now: Date())?.title, "\(expected) の詳細")
            }
        }
    }

    func testPrimaryOnlyFiltersCollapsedRingsAndFollowsIdentityAcrossReordering() throws {
        for provider in ProviderID.allCases {
            let section = section(provider)
            let selected = try XCTUnwrap(section.accounts[1].id)
            var preferences = AccountPreferences()
            preferences.setPrimary(selected, for: provider)
            preferences.setLabel("Work", for: selected)
            for current in [section, self.section(provider, order: ["two", "one"])] {
                let rows = ServiceRowModel.rows(for: current, splitAntigravityAccounts: true, accountPreferences: preferences)
                XCTAssertEqual(rows.count, 2)
                let bars = CollapsedUsageBar.bars(for: snapshot([current]), accountPreferences: preferences).filter { $0.provider == provider }
                XCTAssertFalse(bars.isEmpty)
                XCTAssertTrue(bars.allSatisfy { $0.accountID == selected })
                XCTAssertTrue(bars.allSatisfy { $0.ringName.contains("Work") })
                XCTAssertEqual(bars.flatMap(\.windows).map(\.leftPercent), [40, 30])
                XCTAssertEqual(rows.first { $0.accountID == selected }?.five?.leftPercent, 40)
            }
        }
    }

    func testHideShowAndPrimaryFallbackRetainSelectionAndRecover() throws {
        for provider in ProviderID.allCases {
            let section = section(provider)
            let first = try XCTUnwrap(section.accounts[0].id), second = try XCTUnwrap(section.accounts[1].id)
            var preferences = AccountPreferences()
            preferences.setPrimary(second, for: provider)
            preferences.setVisible(false, for: second)
            XCTAssertEqual(preferences.primaryIndex(in: section), 0)
            let rows = ServiceRowModel.rows(for: section, splitAntigravityAccounts: true, accountPreferences: preferences)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.accountID, first)
            XCTAssertEqual(preferences.primaryAccounts[provider.rawValue], second.rawValue)
            var bars = CollapsedUsageBar.bars(for: snapshot([section]), accountPreferences: preferences).filter { $0.provider == provider }
            XCTAssertTrue(bars.allSatisfy { $0.accountID == first })
            preferences.setVisible(false, for: first)
            XCTAssertTrue(ServiceRowModel.rows(for: section, accountPreferences: preferences).isEmpty)
            bars = CollapsedUsageBar.bars(for: snapshot([section]), accountPreferences: preferences).filter { $0.provider == provider }
            XCTAssertTrue(bars.isEmpty)
            preferences.setVisible(true, for: second)
            XCTAssertEqual(preferences.primaryIndex(in: section), 1)
            XCTAssertEqual(preferences.primaryIndex(in: self.section(provider, order: ["one"])), nil)
            preferences.setVisible(true, for: first)
            XCTAssertEqual(preferences.primaryIndex(in: self.section(provider, order: ["one"])), 0)
            XCTAssertEqual(preferences.primaryIndex(in: section), 1)
        }
    }

    func testMergedAntigravityRespectsHiddenAccountsAndLabels() throws {
        var section = section(.antigravity)
        var preferences = AccountPreferences()
        preferences.setLabel("Personal", for: try XCTUnwrap(section.accounts[0].id))
        preferences.setLabel("Work", for: try XCTUnwrap(section.accounts[1].id))
        var rows = ServiceRowModel.rows(for: section, accountPreferences: preferences)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].name.contains("Personal / Work"))
        preferences.setVisible(false, for: try XCTUnwrap(section.accounts[0].id))
        rows = ServiceRowModel.rows(for: section, accountPreferences: preferences)
        XCTAssertEqual(rows[0].five?.leftPercent, 40)
        XCTAssertEqual(rows[0].week?.leftPercent, 30)
        let bars = CollapsedUsageBar.bars(for: snapshot([section]), accountPreferences: preferences).filter { $0.provider == .antigravity }
        XCTAssertEqual(bars.flatMap(\.windows).map(\.leftPercent), [40, 30])
        XCTAssertTrue(bars.allSatisfy { $0.title.contains("Work") && !$0.title.contains("Personal") })

        section.windows = section.windows.filter { $0.accountIndex == 0 }
        section.accounts[1].failureText = "Usage unavailable"
        let failed = try XCTUnwrap(ServiceRowModel.rows(for: section, splitAntigravityAccounts: true,
                                                       accountPreferences: preferences).first)
        XCTAssertEqual(failed.name, "Antigravity B · Work")
        XCTAssertNotNil(failed.failureText)
    }

    func testCodexBarParsesAllAccountsIncludingErrorsAndBalanceOnlyData() throws {
        for provider in [ProviderID.zai, .minimax, .kimi, .deepseek] {
            let payload = """
            [{"provider":"\(provider.rawValue)","account":"failed","error":{"message":"synthetic-secret"}},
             {"provider":"\(provider.rawValue)","usage":{"accountEmail":"synthetic@example.test",
               "primary":{"usedPercent":25,"windowMinutes":300,"resetDescription":"Balance available"}}}]
            """
            let section = try MultiProviderParser.parse(Data(payload.utf8), provider: provider)
            XCTAssertEqual(section.accounts.count, 2)
            XCTAssertNotEqual(section.accounts[0].id, section.accounts[1].id)
            XCTAssertNotNil(section.accounts[0].failureText)
            let rows = ServiceRowModel.rows(for: section)
            XCTAssertEqual(rows.count, 2)
            XCTAssertNotNil(rows[0].failureText)
            XCTAssertNil(rows[1].failureText)
            XCTAssertFalse(String(describing: section).contains("synthetic-secret"))
            XCTAssertFalse(String(describing: section).contains("synthetic@example.test"))
            if provider == .deepseek {
                XCTAssertTrue(section.windows.isEmpty)
                XCTAssertEqual(section.forAccount(1).stats.first?.title, "Balance")
            } else { XCTAssertEqual(rows[1].five?.leftPercent, 75) }
        }
    }

    func testClaudeRetainsFailedAccountsWithAccountScopedNotices() async throws {
        let client = CLIProxyClient(transport: AccountFailureTransport(), keyProvider: FixtureCLIProxyKey())
        let sections = await client.fetchSections()
        let section = try XCTUnwrap(sections.first { $0.provider == .claude })
        XCTAssertEqual(section.accounts.count, 2)
        XCTAssertTrue(section.accounts.allSatisfy { $0.id != nil })
        let rows = ServiceRowModel.rows(for: section)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].failureText)
        XCTAssertNotNil(rows[1].failureText)
        XCTAssertEqual(rows[0].five?.leftPercent, 79)
        XCTAssertNil(rows[1].primary)
        XCTAssertEqual(section.stats.compactMap(\.accountIndex), [1])
        let bars = CollapsedUsageBar.bars(for: snapshot([section])).filter { $0.provider == .claude }
        XCTAssertEqual(bars.count, 2)
        XCTAssertNotNil(RingDetailCardModel.make(bar: bars[1], now: Date()))
    }

    func testClaudeProfileWarningsNeverBindToQuotaAccountOrderOrPreferences() throws {
        let block = ClaudeBlock(kind: .session, resetAt: Date().addingTimeInterval(3600), timeZoneKnown: true)
        let first = AccountID(provider: .claude, source: "id", value: "one")
        let second = AccountID(provider: .claude, source: "id", value: "two")
        var preferences = AccountPreferences()
        preferences.setLabel("Personal", for: first)
        preferences.setLabel("Work", for: second)
        preferences.setPrimary(second, for: .claude)
        preferences.setVisible(false, for: first)
        for order in [["one"], ["one", "two"], ["two", "one"]] {
            var section = section(.claude, order: order)
            section.claudeProfileBlocks = [1: block]
            for choices in [AccountPreferences(), preferences] {
                let bars = CollapsedUsageBar.bars(for: snapshot([section]), blockedPreview: nil,
                                                 accountPreferences: choices).filter { $0.provider == .claude }
                let profile = try XCTUnwrap(bars.first { $0.id == "claude-profile-1" })
                XCTAssertEqual(profile.title, "Claude logs B")
                XCTAssertEqual(profile.block, block)
                XCTAssertNil(profile.accountID)
                XCTAssertNil(profile.accountIndex)
                XCTAssertTrue(bars.filter { $0.accountID != nil }.allSatisfy { $0.block == nil })
                let card = try XCTUnwrap(RingDetailCardModel.make(bar: profile, now: Date()))
                XCTAssertNotNil(card.blockText)
                XCTAssertEqual(card.title, "Claude logs B の詳細")
                let rows = ServiceRowModel.rows(for: section, accountPreferences: choices)
                let profileRow = try XCTUnwrap(rows.first { $0.id == profile.id })
                XCTAssertEqual(profileRow.name, profile.title)
                XCTAssertNil(profileRow.accountID)
                XCTAssertTrue(section.forAccount(1).claudeProfileBlocks.isEmpty)
                if let visible = choices.visibleSection(section) {
                    XCTAssertEqual(visible.claudeProfileBlocks[1], block)
                }
            }
        }
        let monitorOnly = ProviderSection(provider: .claude, windows: [], stats: [], failureText: nil,
                                          claudeProfileBlocks: [1: block])
        XCTAssertTrue(monitorOnly.accountIndices.isEmpty)
        XCTAssertTrue(monitorOnly.displayAccounts.allSatisfy { $0.id == nil })
        let bars = CollapsedUsageBar.bars(for: snapshot([monitorOnly]), blockedPreview: nil)
            .filter { $0.provider == .claude }
        XCTAssertTrue(bars.allSatisfy { $0.accountID == nil })
        XCTAssertEqual(bars.filter { $0.block != nil }.map(\.id), ["claude-profile-1"])
    }

    func testClaudeRemoteFailureStaysIndependentWhenAccountsAreHiddenOrPrimary() async throws {
        struct Unreachable: ClaudeRateLimitRemote {
            func lines() async -> [String] { [] }
            func failureText() async -> String? { "SSH host unreachable" }
        }
        let service = MultiUsageService(commandRunner: { _ in
            .init(terminationStatus: 1, stdout: Data(), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client(),
           claudeRateLimitMonitor: ClaudeRateLimitMonitor(accounts: [:], remote: Unreachable()))
        let snapshot = await service.fetchAll()
        let section = try XCTUnwrap(snapshot.sections.first { $0.provider == .claude })
        let first = try XCTUnwrap(section.accounts.first?.id)
        var preferences = AccountPreferences()
        preferences.setLabel("Personal", for: first)
        preferences.setPrimary(first, for: .claude)
        preferences.setVisible(false, for: first)
        for choices in [AccountPreferences(), preferences] {
            let bars = CollapsedUsageBar.bars(for: snapshot, blockedPreview: nil, accountPreferences: choices)
            let notice = try XCTUnwrap(bars.first { $0.id == "claude-profile-1" })
            XCTAssertNil(notice.accountID)
            XCTAssertNil(notice.accountIndex)
            XCTAssertEqual(RingDetailCardModel.make(bar: notice, now: Date())?.failureText, "SSH host unreachable")
            for accountBar in bars.filter({ $0.provider == .claude && $0.accountID != nil }) {
                XCTAssertFalse(accountBar.stats.contains { $0.valueText == "SSH host unreachable" })
                XCTAssertNotEqual(accountBar.failureText, "SSH host unreachable")
            }
            let rows = ServiceRowModel.rows(for: section, accountPreferences: choices)
            XCTAssertEqual(rows.first { $0.id == notice.id }?.failureText, "SSH host unreachable")
            XCTAssertEqual(choices.visibleSection(section)?.claudeRemoteFailureText, "SSH host unreachable")
            XCTAssertNil(section.forAccount(0).claudeRemoteFailureText)
        }
    }

    func testCodexParserIdentitySurvivesReorderAndNeverCopiesCredentialsToPreferences() async throws {
        let first = #"{"provider":"codex","usage":{"accountEmail":"first@example.test","primary":{"usedPercent":20}},"token":"synthetic-secret"}"#
        let second = #"{"provider":"codex","usage":{"accountEmail":"second@example.test","primary":{"usedPercent":60}},"apiKey":"synthetic-key"}"#
        func fetch(_ entries: [String]) async -> ProviderSection? {
            let payload = "[" + entries.joined(separator: ",") + "]"
            let service = MultiUsageService(commandRunner: { arguments in
                XCTAssertTrue(arguments.contains("--all-accounts"))
                let json = arguments[2] == "codex" ? payload : "[]"
                return .init(terminationStatus: 0, stdout: Data(json.utf8), stderr: Data())
            }, cliProxyClient: CLIProxyFixtures.client())
            return await service.fetchAll().sections.first { $0.provider == .codex }
        }
        let initialResult = await fetch([first, second])
        let initial = try XCTUnwrap(initialResult)
        let id = try XCTUnwrap(initial.accounts[1].id)
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: id)
        preferences.setPrimary(id, for: .codex)
        let stored = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(AccountPreferences.self, from: stored)
        let reorderedResult = await fetch([second, first])
        let reordered = try XCTUnwrap(reorderedResult)
        XCTAssertEqual(reordered.accounts[0].id, id)
        let bars = CollapsedUsageBar.bars(for: snapshot([reordered]), accountPreferences: restored).filter { $0.provider == .codex }
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars.first?.limit?.leftPercent, 40)
        XCTAssertTrue(bars.first?.title.contains("Work") == true)
        let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
        for forbidden in ["@", "synthetic-secret", "synthetic-key", "token", "apiKey"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testCodexBarPartialFailureRetainsOtherAccountsOnNonzeroExit() async throws {
        let service = MultiUsageService(commandRunner: { arguments in
            XCTAssertTrue(arguments.contains("--all-accounts"))
            let provider = arguments[2]
            let payload = """
            [{"provider":"\(provider)","account":"failed","error":{"message":"synthetic-secret"}},
             {"provider":"\(provider)","account":"healthy","usage":{
                 "primary":{"usedPercent":25,"windowMinutes":300,"resetDescription":"Balance available"}}}]
            """
            return .init(terminationStatus: 1, stdout: Data(payload.utf8), stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        let snapshot = await service.fetchAll()
        for provider in [ProviderID.codex, .zai, .minimax, .kimi, .deepseek] {
            let section = try XCTUnwrap(snapshot.sections.first { $0.provider == provider })
            XCTAssertEqual(section.accounts.count, 2)
            XCTAssertNotNil(section.accounts[0].failureText)
            XCTAssertNil(section.accounts[1].failureText)
            XCTAssertFalse(section.forAccount(1).windows.isEmpty && section.forAccount(1).stats.isEmpty)
        }
    }

    @MainActor
    func testHiddenAccountsStayEditableAndNativeGeometryUpdates() async throws {
        let suite = "AccountPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let section = section(.codex)
        let snapshot = snapshot([section])
        let store = MultiUsageStore(demoSnapshot: snapshot)
        let presentation = EdgeTabPresentationState()
        presentation.menuBarHeight = 24
        let host = NSHostingView(rootView: MultiEdgeTabView(store: store, presentation: presentation, preferences: preferences))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 30),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        func render() throws {
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
        }
        try render()
        let initial = presentation.collapsedSize
        let selected = try XCTUnwrap(section.accounts[1].id)
        preferences.setAccountLabel("Work account", for: selected)
        preferences.setPrimaryAccount(selected, for: .codex)
        try render()
        let expected = MultiCollapsedUsageView.size(for: snapshot, menuBarHeight: 24, accountPreferences: preferences.accountPreferences)
        XCTAssertEqual(presentation.collapsedSize, expected)
        XCTAssertLessThan(expected.width, initial.width)
        preferences.setAccountVisible(false, for: selected)
        let settings = NSHostingView(rootView: PanelSettingsView(preferences: preferences, snapshot: snapshot)
            .defaultAppStorage(defaults).background(Color.white).environment(\.colorScheme, .light))
        XCTAssertGreaterThan(settings.fittingSize.height, 100)
        let settingsWindow = NSPanel(contentRect: CGRect(origin: .zero, size: settings.fittingSize),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        settingsWindow.contentView = settings
        settings.frame = CGRect(origin: .zero, size: settings.fittingSize)
        settings.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
        settings.cacheDisplay(in: settings.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["USAGERINGS_ACCOUNT_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("account-settings.png"))
        }
        XCTAssertEqual(section.displayAccounts.count, 2)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(settingsWindow.isVisible)
        withExtendedLifetime((window, settingsWindow)) { }
    }
}

private struct AccountFailureTransport: CLIProxyTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.lastPathComponent == "credentials" {
            return (Data(#"{"files":[{"provider":"claude","auth_index":"one"},{"provider":"claude","auth_index":"two"}]}"#.utf8), 200)
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        if body?["authIndex"] as? String == "two" { return (Data(), 500) }
        return (CLIProxyFixtures.envelope(CLIProxyFixtures.claude), 200)
    }
}
