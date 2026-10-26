import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
@testable import CodexUsageWidget

final class AccountReconciliationTests: XCTestCase {
    private let salt = Data(repeating: 17, count: 32)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func identity(_ values: [String: String], provider: ProviderID = .codex) throws -> AccountID {
        try XCTUnwrap(AccountID.codexBar(["usage": ["identity": values]], provider: provider, salt: salt))
    }

    private func snapshot(_ ids: [AccountID], provider: ProviderID = .codex,
                          failure: String? = nil, accountFailure: Bool = false) -> MultiUsageSnapshot {
        MultiUsageSnapshot(sections: [ProviderSection(provider: provider, windows: [], stats: [], failureText: failure,
            accounts: ids.enumerated().map { ProviderAccount(index: $0.offset,
                failureText: accountFailure ? "Unavailable" : nil, id: $0.element) })],
            codexSnapshot: nil, updatedAt: start)
    }

    private func legacyID(source: String, value: String) throws -> AccountID {
        let data = Data("usagerings-account-v1\u{0}codex\u{0}\(source)\u{0}\(value)".utf8)
        return try XCTUnwrap(AccountID(digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    func testSaltPersistsAcrossLoadsAndDiffersBetweenInstalls() throws {
        let names = (0..<2).map { _ in "AccountSaltTests.\(UUID().uuidString)" }
        let stores = try names.map { try XCTUnwrap(UserDefaults(suiteName: $0)) }
        defer { zip(stores, names).forEach { $0.removePersistentDomain(forName: $1) } }
        let first = AccountIdentitySalt.load(defaults: stores[0])
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first == AccountIdentitySalt.load(defaults: try XCTUnwrap(UserDefaults(suiteName: names[0]))))
        let second = AccountIdentitySalt.load(defaults: stores[1])
        XCTAssertFalse(first == second)
        let a = AccountID(provider: .codex, source: "id", value: "fixture", salt: first)
        let b = AccountID(provider: .codex, source: "id", value: "fixture", salt: second)
        XCTAssertNotEqual(a, b)
    }

    @MainActor
    func testLegacyDigestMigratesOnSeenAccountAndSurvivesReload() throws {
        let suite = "AccountMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(salt, forKey: AccountIdentitySalt.defaultsKey)
        let old = try legacyID(source: "email", value: "fixture@example.test")
        var legacy = AccountPreferences()
        legacy.setLabel("Work", for: old)
        legacy.setVisible(false, for: old)
        legacy.setPrimary(old, for: .codex)
        defaults.set(try JSONEncoder().encode(legacy), forKey: PanelPreferences.accountPreferencesKey)
        let preferences = PanelPreferences(defaults: defaults)
        XCTAssertEqual(preferences.accountPreferences.label(for: old), "Work")
        let current = try identity(["email": "fixture@example.test"])
        preferences.reconcileAccounts(in: snapshot([current]), now: start)
        let loaded = PanelPreferences(defaults: defaults).accountPreferences
        XCTAssertEqual(loaded.label(for: current), "Work")
        XCTAssertFalse(loaded.isVisible(current))
        XCTAssertEqual(loaded.primaryAccounts["codex"], current.rawValue)
        XCTAssertNil(loaded.accounts[old.rawValue])
        let stored = try XCTUnwrap(defaults.data(forKey: PanelPreferences.accountPreferencesKey))
        let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
        XCTAssertFalse(text.contains(old.rawValue), "Unsalted migration probes must not become persistent aliases")
        XCTAssertFalse(text.contains("@"))
    }

    func testSingletonToEmailToIDRetainsAllChoicesIncludingAfterReload() throws {
        let slot = AccountID.singleton(.codex, salt: salt)
        let email = try identity(["email": "fixture@example.test"])
        let both = try identity(["email": "fixture@example.test", "accountId": "account-one"])
        let idOnly = try identity(["accountId": "account-one"])
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: slot)
        preferences.setVisible(false, for: slot)
        preferences.setPrimary(slot, for: .codex)
        for id in [slot, email, both, idOnly, email] {
            preferences.reconcile(snapshot([id]), now: start, salt: salt)
            preferences = try JSONDecoder().decode(AccountPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(preferences.label(for: id), "Work")
            XCTAssertFalse(preferences.isVisible(id))
            XCTAssertEqual(preferences.primaryAccounts["codex"], id.rawValue)
            XCTAssertEqual(preferences.accounts.count, 1)
        }
    }

    func testUnsaltedSingletonMigratesDirectlyToIdentifiedAccount() throws {
        let old = try legacyID(source: "slot", value: "default")
        let id = try identity(["accountID": "account-one"])
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: old)
        preferences.reconcile(snapshot([id]), now: start, salt: salt)
        XCTAssertEqual(preferences.label(for: id), "Work")
        XCTAssertNil(preferences.accounts[old.rawValue])
    }

    func testConflictingOlderChoicesPreferSpecificIdentityAndArchiveOtherChoice() throws {
        let slot = try legacyID(source: "slot", value: "default")
        let email = try legacyID(source: "email", value: "fixture@example.test")
        let current = try identity(["accountId": "one", "email": "fixture@example.test"])
        var preferences = AccountPreferences()
        preferences.setLabel("Slot choice", for: slot)
        preferences.setVisible(false, for: slot)
        preferences.setLabel("Email choice", for: email)
        preferences.setPrimary(slot, for: .codex)
        let archive = preferences.reconcile(snapshot([current]), now: start, salt: salt)
        XCTAssertEqual(preferences.label(for: current), "Email choice")
        XCTAssertEqual(preferences.primaryAccounts["codex"], current.rawValue)
        XCTAssertEqual(archive.accounts.values.first?.label, "Slot choice")
        XCTAssertEqual(archive.accounts.values.first?.hidden, true)
        XCTAssertEqual(archive.accounts.count, 1)
        XCTAssertNotNil(archive.primaryAccounts["codex"])
        XCTAssertNil(archive.accounts[slot.rawValue], "Recovery archive must also use salted keys")
    }

    func testReorderedAccountsMigrateByEmailNotPosition() throws {
        let first = try identity(["email": "one@example.test"])
        let second = try identity(["email": "two@example.test"])
        let nextFirst = try identity(["email": "one@example.test", "accountId": "one"])
        let nextSecond = try identity(["email": "two@example.test", "accountId": "two"])
        var preferences = AccountPreferences()
        preferences.setLabel("One", for: first)
        preferences.setVisible(false, for: first)
        preferences.setLabel("Two", for: second)
        preferences.setPrimary(second, for: .codex)
        preferences.reconcile(snapshot([nextSecond, nextFirst]), now: start, salt: salt)
        XCTAssertEqual(preferences.label(for: nextFirst), "One")
        XCTAssertFalse(preferences.isVisible(nextFirst))
        XCTAssertEqual(preferences.label(for: nextSecond), "Two")
        XCTAssertTrue(preferences.isVisible(nextSecond))
        XCTAssertEqual(preferences.primaryAccounts["codex"], nextSecond.rawValue)
    }

    func testAmbiguousAliasesAndSingletonNeverTransferBetweenAccounts() throws {
        let email = try identity(["email": "shared@example.test"])
        let first = try identity(["email": "shared@example.test", "accountId": "one"])
        let second = try identity(["email": "shared@example.test", "accountId": "two"])
        let slot = AccountID.singleton(.codex, salt: salt)
        var preferences = AccountPreferences()
        preferences.setLabel("Shared", for: email)
        preferences.setLabel("Slot", for: slot)
        preferences.reconcile(snapshot([first, second]), now: start, salt: salt)
        XCTAssertNil(preferences.label(for: first))
        XCTAssertNil(preferences.label(for: second))
        preferences = try JSONDecoder().decode(AccountPreferences.self, from: JSONEncoder().encode(preferences))
        preferences.reconcile(snapshot([first]), now: start, salt: salt)
        XCTAssertNil(preferences.label(for: first), "A formerly ambiguous alias/slot must stay unclaimed")
        XCTAssertEqual(preferences.label(for: email), "Shared")
        XCTAssertEqual(preferences.label(for: slot), "Slot")
        // A later unrelated singleton cannot claim a previously ambiguous slot.
        let unrelated = try identity(["accountId": "unrelated"])
        preferences.reconcile(snapshot([unrelated]), now: start, salt: salt)
        XCTAssertNil(preferences.label(for: unrelated))
    }

    func testUnsaltedAmbiguousAliasRemainsBlockedAfterReloadAndAccountDisappears() throws {
        let old = try legacyID(source: "email", value: "shared@example.test")
        let first = try identity(["email": "shared@example.test", "accountId": "one"])
        let second = try identity(["email": "shared@example.test", "accountId": "two"])
        var preferences = AccountPreferences()
        preferences.setLabel("Shared", for: old)
        preferences.setPrimary(old, for: .codex)
        preferences.reconcile(snapshot([first, second]), now: start, salt: salt)
        preferences = try JSONDecoder().decode(AccountPreferences.self, from: JSONEncoder().encode(preferences))
        preferences.reconcile(snapshot([first]), now: start, salt: salt)
        XCTAssertNil(preferences.label(for: first))
        XCTAssertEqual(preferences.label(for: old), "Shared")
        XCTAssertEqual(preferences.primaryAccounts["codex"], old.rawValue)
        XCTAssertFalse(preferences.ambiguousAliases.contains(old.rawValue))
    }

    func testDuplicateCurrentIdentitiesCannotClaimLegacyPreferences() throws {
        let old = try legacyID(source: "id", value: "duplicate")
        let current = try identity(["accountId": "duplicate"])
        var preferences = AccountPreferences()
        preferences.setLabel("Legacy", for: old)
        preferences.reconcile(snapshot([current, current]), now: start, salt: salt)
        XCTAssertNil(preferences.label(for: current))
        XCTAssertEqual(preferences.label(for: old), "Legacy")
    }

    func testExpiryDropsStaleOverrideAndPrimaryButKeepsSeenHiddenAccount() throws {
        let gone = try identity(["accountId": "gone"])
        let hidden = try identity(["accountId": "hidden"])
        var preferences = AccountPreferences()
        preferences.setLabel("Gone", for: gone)
        preferences.setVisible(false, for: hidden)
        preferences.setPrimary(gone, for: .codex)
        preferences.reconcile(snapshot([gone, hidden]), now: start, salt: salt)
        preferences.reconcile(snapshot([hidden]), now: start.addingTimeInterval(AccountPreferences.retentionInterval), salt: salt)
        XCTAssertNotNil(preferences.accounts[gone.rawValue], "Keep exactly 90 days")
        let archived = preferences.reconcile(snapshot([hidden]),
            now: start.addingTimeInterval(AccountPreferences.retentionInterval + 1), salt: salt)
        XCTAssertNil(preferences.accounts[gone.rawValue])
        XCTAssertNil(preferences.primaryAccounts["codex"])
        XCTAssertFalse(preferences.isVisible(hidden))
        XCTAssertEqual(archived.label(for: gone), "Gone")
        XCTAssertEqual(archived.primaryAccounts["codex"], gone.rawValue)
    }

    func testFailedPartialAndAbsentProviderFetchesNeverExpireItsPreferences() throws {
        let id = try identity(["accountId": "one"])
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: id)
        preferences.setPrimary(id, for: .codex)
        preferences.reconcile(snapshot([id]), now: start, salt: salt)
        let later = start.addingTimeInterval(AccountPreferences.retentionInterval + 1)
        for failed in [snapshot([], failure: "Offline"), snapshot([], provider: .grok)] {
            preferences.reconcile(failed, now: later, salt: salt)
            XCTAssertEqual(preferences.label(for: id), "Work")
            XCTAssertEqual(preferences.primaryAccounts["codex"], id.rawValue)
            XCTAssertEqual(preferences.observations[id.rawValue]?.lastSeen, start)
        }
        preferences.reconcile(snapshot([]), now: later, salt: salt)
        XCTAssertNil(preferences.label(for: id))
        XCTAssertNil(preferences.primaryAccounts["codex"])
    }

    func testQuotaFailureStillMigratesSeenIdentityWithoutExpiringMissingAccounts() throws {
        let old = try legacyID(source: "email", value: "fixture@example.test")
        let current = try identity(["email": "fixture@example.test", "accountId": "one"])
        let missing = try identity(["accountId": "missing"])
        var preferences = AccountPreferences()
        preferences.setLabel("Work", for: old)
        preferences.setVisible(false, for: old)
        preferences.setPrimary(old, for: .codex)
        preferences.setLabel("Missing", for: missing)
        preferences.reconcile(snapshot([missing]), now: start, salt: salt)
        let later = start.addingTimeInterval(AccountPreferences.retentionInterval + 1)
        preferences.reconcile(snapshot([current], failure: "Partial failure", accountFailure: true), now: later, salt: salt)
        XCTAssertEqual(preferences.label(for: current), "Work")
        XCTAssertFalse(preferences.isVisible(current))
        XCTAssertEqual(preferences.primaryAccounts["codex"], current.rawValue)
        XCTAssertEqual(preferences.observations[current.rawValue]?.lastSeen, later)
        XCTAssertEqual(preferences.label(for: missing), "Missing")
        XCTAssertEqual(preferences.observations[missing.rawValue]?.lastSeen, start)
        XCTAssertNil(preferences.accounts[old.rawValue])
    }

    func testSuccessfulEmptyProxyInventoryExpiresButFailedInventoryDoesNot() async throws {
        let id = try identity(["accountId": "gone"], provider: .claude)
        var preferences = AccountPreferences()
        preferences.setLabel("Gone", for: id)
        preferences.setPrimary(id, for: .claude)
        preferences.reconcile(snapshot([id], provider: .claude), now: start, salt: salt)
        let later = start.addingTimeInterval(AccountPreferences.retentionInterval + 1)
        let failedClient = CLIProxyClient(transport: EmptyAccountInventoryTransport(status: 503), keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
        let failed = await failedClient.fetchSections(now: later)
        preferences.reconcile(MultiUsageSnapshot(sections: failed, codexSnapshot: nil, updatedAt: later), now: later, salt: salt)
        XCTAssertEqual(preferences.label(for: id), "Gone")
        let emptyClient = CLIProxyClient(transport: EmptyAccountInventoryTransport(status: 200), keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
        let empty = await emptyClient.fetchSections(now: later)
        XCTAssertTrue(empty.allSatisfy { $0.accountInventoryComplete == true && $0.accounts.isEmpty })
        preferences.reconcile(MultiUsageSnapshot(sections: empty, codexSnapshot: nil, updatedAt: later), now: later, salt: salt)
        XCTAssertNil(preferences.label(for: id))
        XCTAssertNil(preferences.primaryAccounts["claude"])
    }

    func testMalformedProxyInventoryPreservesExpiredPreferences() async throws {
        let id = try identity(["accountId": "missing-row"], provider: .claude)
        var preferences = AccountPreferences()
        preferences.setLabel("Retained", for: id)
        preferences.setPrimary(id, for: .claude)
        preferences.reconcile(snapshot([id], provider: .claude), now: start, salt: salt)
        let later = start.addingTimeInterval(AccountPreferences.retentionInterval + 1)
        let payloads = [
            #"{"files":[{"provider":"claude"}]}"#,
            #"{"files":[{"provider":"claude ","auth_index":"fixture"}]}"#
        ]
        for payload in payloads {
            let transport = EmptyAccountInventoryTransport(status: 200, payload: payload)
            let client = CLIProxyClient(transport: transport, keyProvider: FixtureCLIProxyKey(), peerVerifier: FixtureCLIProxyPeerVerifier())
            let sections = await client.fetchSections(now: later)
            XCTAssertTrue(sections.allSatisfy { $0.accountInventoryComplete == false })
            let archived = preferences.reconcile(MultiUsageSnapshot(sections: sections, codexSnapshot: nil, updatedAt: later), now: later, salt: salt)
            XCTAssertEqual(preferences.label(for: id), "Retained")
            XCTAssertEqual(preferences.primaryAccounts["claude"], id.rawValue)
            XCTAssertTrue(archived.accounts.isEmpty)
        }
    }

    func testLegacyUnknownEntriesGetGraceAndRequireCompleteSuccessfulInventory() throws {
        let id = try legacyID(source: "id", value: "unknown")
        var preferences = AccountPreferences()
        preferences.setLabel("Legacy", for: id)
        preferences.reconcile(snapshot([]), now: start, salt: salt)
        let later = start.addingTimeInterval(AccountPreferences.retentionInterval + 1)
        preferences.reconcile(snapshot([]), now: later, salt: salt)
        XCTAssertEqual(preferences.label(for: id), "Legacy")
        let all = MultiUsageSnapshot(sections: ProviderID.allCases.map {
            ProviderSection(provider: $0, windows: [], stats: [], failureText: nil)
        }, codexSnapshot: nil, updatedAt: later)
        preferences.reconcile(all, now: later, salt: salt)
        XCTAssertNil(preferences.label(for: id))
    }

    @MainActor
    func testPrunedPreferencesAreArchivedAndRemainPrunedAfterReload() throws {
        let suite = "AccountExpiryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(salt, forKey: AccountIdentitySalt.defaultsKey)
        let id = try identity(["accountId": "gone"])
        let settings = PanelPreferences(defaults: defaults)
        settings.setAccountLabel("Gone", for: id)
        settings.setPrimaryAccount(id, for: .codex)
        settings.reconcileAccounts(in: snapshot([id]), now: start)
        settings.reconcileAccounts(in: snapshot([]), now: start.addingTimeInterval(AccountPreferences.retentionInterval + 1))
        XCTAssertNil(PanelPreferences(defaults: defaults).accountPreferences.label(for: id))
        let archive = try XCTUnwrap(defaults.array(forKey: PanelPreferences.accountPreferencesArchiveKey) as? [Data])
        XCTAssertEqual(archive.count, 1)
        let restored = try JSONDecoder().decode(AccountPreferences.self, from: archive[0])
        XCTAssertEqual(restored.label(for: id), "Gone")
        XCTAssertEqual(restored.primaryAccounts["codex"], id.rawValue)
    }

    @MainActor
    func testLiveStoreReconcilesLoadedLegacyPreferencesBeforeSnapshotDelivery() async throws {
        let suite = "AccountStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = try legacyID(source: "id", value: "account-one")
        var legacy = AccountPreferences()
        legacy.setLabel("Work", for: old)
        legacy.setVisible(false, for: old)
        legacy.setPrimary(old, for: .codex)
        defaults.set(try JSONEncoder().encode(legacy), forKey: PanelPreferences.accountPreferencesKey)
        let preferences = PanelPreferences(defaults: defaults)
        let service = MultiUsageService(commandRunner: { arguments in
            let data = try JSONSerialization.data(withJSONObject: [["provider": arguments[2],
                "usage": ["identity": ["accountId": "account-one"], "primary": ["usedPercent": 20]]]])
            return CodexUsageService.CommandResult(terminationStatus: 0, stdout: data, stderr: Data())
        }, cliProxyClient: CLIProxyFixtures.client())
        let store = MultiUsageStore(service: service, snapshotURLs: [], preferences: preferences)
        var migratedAtDelivery = false
        let subscription = store.$snapshot.dropFirst().sink { data in
            guard let id = data.sections.first(where: { $0.provider == .codex })?.accounts.first?.id else { return }
            migratedAtDelivery = preferences.accountPreferences.label(for: id) == "Work"
                && preferences.accountPreferences.primaryAccounts["codex"] == id.rawValue
                && !preferences.accountPreferences.isVisible(id)
        }
        store.refresh()
        for _ in 0..<200 {
            if !store.isRefreshing { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(migratedAtDelivery)
        XCTAssertNil(PanelPreferences(defaults: defaults).accountPreferences.accounts[old.rawValue])
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    func testTabPercentAndToneUsePrimaryAndVisibleFallback() throws {
        let suite = "AccountTabTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try identity(["accountId": "one"])
        let second = try identity(["accountId": "two"])
        var section = try XCTUnwrap(snapshot([first, second]).sections.first)
        section.windows = [UsageLimit(title: "5h", leftPercent: 80, resetText: ""),
                           UsageLimit(title: "5h", leftPercent: 5, resetText: "")]
        section.windows[0].accountIndex = 0
        section.windows[1].accountIndex = 1
        let data = MultiUsageSnapshot(sections: [section], codexSnapshot: nil, updatedAt: start)
        let preferences = PanelPreferences(defaults: defaults)
        let view = MultiEdgeTabView(store: MultiUsageStore(demoSnapshot: data),
            presentation: EdgeTabPresentationState(), preferences: preferences)
        XCTAssertEqual(view.displayPercent, 5)
        XCTAssertEqual(view.displayTone, .critical)
        preferences.setPrimaryAccount(first, for: .codex)
        XCTAssertEqual(view.displayPercent, 80)
        XCTAssertEqual(view.displayTone, .healthy)
        preferences.setAccountVisible(false, for: first)
        XCTAssertEqual(view.displayPercent, 5)
        XCTAssertEqual(view.displayTone, .critical)
        preferences.setPrimaryAccount(try identity(["accountId": "missing"]), for: .codex)
        preferences.setAccountVisible(true, for: first)
        XCTAssertEqual(view.displayPercent, 80)
        XCTAssertEqual(view.displayTone, .healthy)
    }

    @MainActor
    func testLabelFieldDefersSavingAndShowsNormalizedValueOnSubmit() throws {
        let suite = "AccountLabelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let id = try identity(["accountId": "one"])
        preferences.setAccountLabel("Original", for: id)
        let host = NSHostingView(rootView: AccountSettingsRow(id: id, name: "Fixture", preferences: preferences))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        host.frame = panel.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(host).first { $0.isEditable })
        XCTAssertEqual(field.stringValue, "Original")
        var changes = 0
        let subscription = preferences.$accountPreferences.dropFirst().sink { _ in changes += 1 }
        field.stringValue = "  " + String(repeating: "x", count: 90) + "  "
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(preferences.accountPreferences.label(for: id), "Original")
        XCTAssertNotNil(field.action)
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(preferences.accountPreferences.label(for: id), String(repeating: "x", count: 80))
        XCTAssertEqual(field.stringValue, String(repeating: "x", count: 80))
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(panel.isVisible)
        withExtendedLifetime((panel, subscription)) { }
    }
}

private struct EmptyAccountInventoryTransport: CLIProxyTransport {
    let status: Int
    var payload = #"{"files":[]}"#
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        (Data(payload.utf8), status)
    }
}
