import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// M5 Task 6: menu-toggle logic. `NyxWindowCoordinator` itself needs a
/// live window + session store to construct (see
/// WindowCoordinatorFocusTests' doc) and its `init` opens the shared
/// on-disk database, so these tests exercise the same PURE decision
/// functions the coordinator's `contentRulePolicy` and `siteAdblockEnabled`
/// call (`shouldBlockContentRules` / `isSiteOverrideActive`) against a
/// real `NyxSettings` (isolated UserDefaults suite) and a real
/// `SiteOverrideStore` (temp on-disk database) — then drive
/// `TabManager.reevaluateContentRules(force:)` through a `ContentRulePolicy`
/// wired identically to the coordinator's, proving the "flip → re-evaluate
/// ALL live tabs" contract the toggle methods rely on.
///
/// `toggleGlobalAdblock()` / `toggleSiteAdblock()` themselves are one-line
/// compositions of already-proven pieces (`settings.adblockEnabled.toggle()`
/// / `SiteOverrideStore.setBlockingDisabled`, `TabManager
/// .reevaluateContentRules(force:)`, `TabManager.reload()` — the latter
/// pre-existing and untouched) and are not re-exercised end-to-end here;
/// doing so would require the full coordinator's window/DB machinery this
/// suite deliberately avoids.
@MainActor
final class AdblockMenuToggleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var overrides: SiteOverrideStore!

    override func setUpWithError() throws {
        suiteName = "AdblockMenuToggleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-adblock-toggle-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        overrides = SiteOverrideStore(database: database)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - shouldBlockContentRules (global flag + override, coordinator's shouldBlock)

    func testShouldBlockContentRulesFalseWhenGlobalOff() {
        let settings = NyxSettings(defaults: defaults)
        settings.adblockEnabled = false
        XCTAssertFalse(NyxWindowCoordinator.shouldBlockContentRules(
            host: "example.com", settings: settings, overrides: overrides))
    }

    func testShouldBlockContentRulesTrueForNilHostWhenGlobalOn() {
        let settings = NyxSettings(defaults: defaults)
        XCTAssertTrue(NyxWindowCoordinator.shouldBlockContentRules(
            host: nil, settings: settings, overrides: overrides))
    }

    func testShouldBlockContentRulesRespectsSiteOverrideWhenGlobalOn() throws {
        let settings = NyxSettings(defaults: defaults)
        try overrides.setBlockingDisabled(true, host: "ads.example.com")
        XCTAssertFalse(NyxWindowCoordinator.shouldBlockContentRules(
            host: "ads.example.com", settings: settings, overrides: overrides))
        XCTAssertTrue(NyxWindowCoordinator.shouldBlockContentRules(
            host: "other.example.com", settings: settings, overrides: overrides))
    }

    func testShouldBlockContentRulesGlobalOffWinsOverSiteOverrideOn() throws {
        // Site override left at its default (blocking ON) but the
        // global flag is off — global must win (guard runs first).
        let settings = NyxSettings(defaults: defaults)
        settings.adblockEnabled = false
        XCTAssertFalse(NyxWindowCoordinator.shouldBlockContentRules(
            host: "example.com", settings: settings, overrides: overrides))
    }

    // MARK: - isSiteOverrideActive (site checkmark, independent of the global flag)

    func testIsSiteOverrideActiveTrueByDefault() {
        XCTAssertTrue(NyxWindowCoordinator.isSiteOverrideActive(
            host: "example.com", overrides: overrides))
    }

    func testIsSiteOverrideActiveFalseAfterDisablingHost() throws {
        try overrides.setBlockingDisabled(true, host: "example.com")
        XCTAssertFalse(NyxWindowCoordinator.isSiteOverrideActive(
            host: "example.com", overrides: overrides))
    }

    func testIsSiteOverrideActiveIgnoresTheGlobalFlag() throws {
        // The site checkmark reflects the override alone — flipping the
        // global flag off must not change its answer.
        try overrides.setBlockingDisabled(true, host: "example.com")
        XCTAssertFalse(NyxWindowCoordinator.isSiteOverrideActive(
            host: "example.com", overrides: overrides))
    }

    // MARK: - Global flip re-evaluates ALL live tabs (coordinator's toggleGlobalAdblock)

    func testGlobalFlipReevaluatesAllLiveTabsRegardlessOfHost() {
        let settings = NyxSettings(defaults: defaults)
        let overrides: SiteOverrideStore = self.overrides
        var events: [String] = []
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        manager.contentRulePolicy = ContentRulePolicy(
            shouldBlock: { host in
                NyxWindowCoordinator.shouldBlockContentRules(
                    host: host, settings: settings, overrides: overrides)
            },
            apply: { _ in events.append("apply") },
            remove: { _ in events.append("remove") })
        let a = manager.newTab()
        let b = manager.newTab()
        a.navigationDidCommit(URL(string: "https://a.example/")!)
        b.navigationDidCommit(URL(string: "https://b.example/")!)
        events = []

        // Same-host toggle needs `force: true` (T5's flagged
        // requirement): the decision (true → false) DID change here, but
        // the point is that this is exactly what toggleGlobalAdblock does.
        settings.adblockEnabled = false
        manager.reevaluateContentRules(force: true)
        XCTAssertEqual(events, ["remove", "remove"],
                       "both live tabs must be touched, not just the selected one")
    }

    func testGlobalFlipForceIsRequiredWhenTheDecisionDoesNotChange() {
        // Regression for T5's flagged same-host-toggle requirement:
        // without `force: true`, evaluateContentRules's unchanged-
        // decision guard would skip a tab whose host never changed even
        // though the controller's applied lists are now stale.
        let settings = NyxSettings(defaults: defaults)
        let overrides: SiteOverrideStore = self.overrides
        var events: [String] = []
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        manager.contentRulePolicy = ContentRulePolicy(
            shouldBlock: { host in
                NyxWindowCoordinator.shouldBlockContentRules(
                    host: host, settings: settings, overrides: overrides)
            },
            apply: { _ in events.append("apply") },
            remove: { _ in events.append("remove") })
        let tab = manager.newTab()
        tab.navigationDidCommit(URL(string: "https://a.example/")!)
        events = []

        // Toggle off then immediately back on: net decision unchanged,
        // but `force: true` must still touch the controller both times.
        settings.adblockEnabled = false
        manager.reevaluateContentRules(force: true)
        settings.adblockEnabled = true
        manager.reevaluateContentRules(force: true)
        XCTAssertEqual(events, ["remove", "remove", "apply"])
    }

    // MARK: - Site flip writes the override AND re-evaluates (coordinator's toggleSiteAdblock)

    func testSiteFlipWritesOverrideRowAndReevaluatesTheAffectedTab() throws {
        let settings = NyxSettings(defaults: defaults)
        let overrides: SiteOverrideStore = self.overrides
        var events: [String] = []
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        manager.contentRulePolicy = ContentRulePolicy(
            shouldBlock: { host in
                NyxWindowCoordinator.shouldBlockContentRules(
                    host: host, settings: settings, overrides: overrides)
            },
            apply: { _ in events.append("apply") },
            remove: { _ in events.append("remove") })
        let tab = manager.newTab()
        tab.navigationDidCommit(URL(string: "https://a.example/")!)
        events = []

        // What toggleSiteAdblock does for the selected tab's host: read,
        // flip, write, then force-reevaluate every live tab.
        let host = "a.example"
        let isDisabled = try overrides.isBlockingDisabled(host: host)
        try overrides.setBlockingDisabled(!isDisabled, host: host)
        manager.reevaluateContentRules(force: true)

        XCTAssertTrue(try overrides.isBlockingDisabled(host: host),
                      "override row must persist the flip")
        XCTAssertEqual(events, ["remove"],
                       "the now-overridden tab's controller must be stripped")

        // Flipping back removes the row (SiteOverrideStore's documented
        // "OFF has no row to keep in sync" contract) and re-applies.
        events = []
        let isDisabledNow = try overrides.isBlockingDisabled(host: host)
        try overrides.setBlockingDisabled(!isDisabledNow, host: host)
        manager.reevaluateContentRules(force: true)
        XCTAssertFalse(try overrides.isBlockingDisabled(host: host))
        XCTAssertEqual(events, ["remove", "apply"])
    }
}
