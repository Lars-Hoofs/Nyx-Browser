import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// Bare-initialized WKNavigationAction happens to report a nil
/// targetFrame today, but nothing in the SDK documents that — this stub
/// pins the nil answer TabManager's popup path requires instead of
/// trusting an undocumented default.
private final class StubPopupNavigationAction: WKNavigationAction {
    override var targetFrame: WKFrameInfo? { nil }
}

/// M5 Task 5: per-tab content-rule application through the attach funnel.
/// Everything is exercised at the ContentRulePolicy closure seam — the
/// same three closures the coordinator injects — with a spy that models
/// controller state (how many list SETS are applied per controller), so
/// the T4-review "no double application" constraint is asserted directly
/// rather than inferred from call counts alone.
@MainActor
final class ContentRuleEvaluationTests: XCTestCase {
    private enum Event: Equatable { case apply, remove }
    private var events: [Event] = []
    /// Simulated per-controller state: apply(+1) / remove(=0) — mirrors
    /// RuleListManager.apply (adds all lists) / .remove
    /// (removeAllContentRuleLists). A value > 1 means stacked duplicates.
    private var appliedSets: [ObjectIdentifier: Int] = [:]
    private var overriddenHosts: Set<String> = []
    private var globallyEnabled = true

    override func setUpWithError() throws {
        events = []
        appliedSets = [:]
        overriddenHosts = []
        globallyEnabled = true
    }

    private func makePolicy() -> ContentRulePolicy {
        ContentRulePolicy(
            shouldBlock: { [weak self] host in
                guard let self, self.globallyEnabled else { return false }
                guard let host else { return true }
                return !self.overriddenHosts.contains(host)
            },
            apply: { [weak self] controller in
                self?.events.append(.apply)
                self?.appliedSets[ObjectIdentifier(controller), default: 0] += 1
            },
            remove: { [weak self] controller in
                self?.events.append(.remove)
                self?.appliedSets[ObjectIdentifier(controller)] = 0
            })
    }

    private func makeManager() -> TabManager {
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        manager.contentRulePolicy = makePolicy()
        return manager
    }

    private func appliedSetCount(for tab: BrowserTab) -> Int {
        guard let controller = tab.webView?.configuration.userContentController
        else { return -1 }
        return appliedSets[ObjectIdentifier(controller)] ?? 0
    }

    // MARK: - Attach-time evaluation

    func testAttachAppliesWhenGloballyOnAndNoOverride() {
        let manager = makeManager()
        let tab = manager.newTab()
        // Remove-then-apply: every evaluation starts from a clean slate.
        XCTAssertEqual(events, [.remove, .apply])
        XCTAssertEqual(appliedSetCount(for: tab), 1)
    }

    func testAttachRemovesWhenBlockingGloballyOff() {
        globallyEnabled = false
        let manager = makeManager()
        let tab = manager.newTab()
        XCTAssertEqual(events, [.remove])
        XCTAssertEqual(appliedSetCount(for: tab), 0)
    }

    func testAttachWithoutPolicyIsANoOp() {
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        let tab = manager.newTab()
        XCTAssertNotNil(tab.webView)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Committed-navigation re-evaluation

    func testCommitToOverriddenHostRemovesAndLowercasesHost() {
        overriddenHosts = ["ads.example.com"]
        let manager = makeManager()
        let tab = manager.newTab()
        events = []
        tab.navigationDidCommit(URL(string: "https://Ads.EXAMPLE.com/page")!)
        XCTAssertEqual(tab.currentHost, "ads.example.com",
                       "host key must be lowercased (SiteOverrideStore key contract)")
        XCTAssertEqual(events, [.remove])
        XCTAssertEqual(appliedSetCount(for: tab), 0)
    }

    func testCommitAcrossHostsWithSameOverrideStateLeavesControllerUntouched() {
        let manager = makeManager()
        let tab = manager.newTab()
        events = []
        tab.navigationDidCommit(URL(string: "https://a.example/")!)
        tab.navigationDidCommit(URL(string: "https://b.example/")!)
        XCTAssertTrue(events.isEmpty,
                      "same decision on a new host must not churn the controller")
        XCTAssertEqual(appliedSetCount(for: tab), 1)
        XCTAssertEqual(tab.currentHost, "b.example")
    }

    func testSameHostRecommitDoesNotReevaluate() {
        overriddenHosts = ["a.example"]
        let manager = makeManager()
        let tab = manager.newTab()
        tab.navigationDidCommit(URL(string: "https://a.example/one")!)
        events = []
        // Override flips between two same-host commits: still no
        // re-evaluation — same-host changes are the TOGGLE path's job
        // (Task 6), which re-evaluates and reloads explicitly.
        overriddenHosts = []
        tab.navigationDidCommit(URL(string: "https://a.example/two")!)
        XCTAssertTrue(events.isEmpty)
    }

    func testCommitStillForwardsToHistoryCallback() {
        let manager = makeManager()
        let tab = manager.newTab()
        var recorded: [URL] = []
        tab.onNavigationCommitted = { recorded.append($0) }
        let url = URL(string: "https://a.example/")!
        tab.navigationDidCommit(url)
        XCTAssertEqual(recorded, [url])
    }

    // MARK: - Hibernate → re-attach (the M4-review caveat)

    func testHibernateReattachReevaluatesAgainstKeptHost() {
        overriddenHosts = ["quiet.example"]
        let manager = makeManager()
        let tab = manager.newTab()
        tab.navigationDidCommit(URL(string: "https://quiet.example/")!)
        tab.hibernate()
        XCTAssertEqual(tab.currentHost, "quiet.example",
                       "currentHost survives hibernation so re-attach evaluates the right host")
        events = []
        tab.attach(WKWebView(), uiDelegate: nil)
        XCTAssertEqual(events, [.remove],
                       "re-attach on an overridden host must not apply")
        XCTAssertEqual(appliedSetCount(for: tab), 0)

        // Override lifted while hibernated → next attach applies again.
        tab.hibernate()
        overriddenHosts = []
        events = []
        tab.attach(WKWebView(), uiDelegate: nil)
        XCTAssertEqual(events, [.remove, .apply])
        XCTAssertEqual(appliedSetCount(for: tab), 1)
    }

    func testRestoredTabSeedsHostFromURLStringAtAttach() {
        overriddenHosts = ["saved.example"]
        let record = TabRecord(id: "t1", spaceID: "s1",
                               urlString: "https://saved.example/deep/page",
                               title: "Saved", orderIndex: 0,
                               interactionState: nil, lastActiveAt: Date())
        let tab = BrowserTab(record: record)
        tab.contentRulePolicy = makePolicy()
        tab.attach(WKWebView(), uiDelegate: nil)
        XCTAssertEqual(tab.currentHost, "saved.example",
                       "a record-restored tab evaluates against its URL's host, not nil")
        XCTAssertEqual(events.first, .remove)
        XCTAssertFalse(events.contains(.apply),
                       "restored tab on an overridden site must start its load unblocked")
    }

    // MARK: - onReady retro-application

    func testForcedReevaluationRetroAppliesToLiveTabsOnly() {
        let manager = makeManager()
        let sleeper = manager.newTab()
        let live = manager.newTab()
        sleeper.hibernate()
        events = []
        // What ruleListManager.onReady runs (coordinator wiring): lists
        // finished compiling AFTER these tabs attached.
        manager.reevaluateContentRules(force: true)
        XCTAssertEqual(events, [.remove, .apply],
                       "exactly the one live tab re-applies; hibernated tabs wait for attach")
        XCTAssertEqual(appliedSetCount(for: live), 1)
        XCTAssertNil(sleeper.webView)
    }

    func testRepeatedEvaluationNeverStacksDuplicateLists() {
        // T4-review constraint: apply(to:) has no double-application
        // guard, so the evaluation itself must be remove-then-apply
        // shaped. Force twice + attach evaluation = three evaluations on
        // one controller → still exactly one applied set.
        let manager = makeManager()
        let tab = manager.newTab()
        tab.evaluateContentRules(force: true)
        tab.evaluateContentRules(force: true)
        XCTAssertEqual(appliedSetCount(for: tab), 1)
    }

    func testUnforcedReevaluationWithUnchangedDecisionIsSkipped() {
        let manager = makeManager()
        let tab = manager.newTab()
        events = []
        tab.evaluateContentRules()
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Popup adoption (shared-controller semantics)

    func testPopupAdoptionInheritsOpenerEvaluationWithoutTouchingController() {
        let manager = makeManager()
        let opener = manager.newTab()
        guard let openerWebView = opener.webView else {
            return XCTFail("opener must be live")
        }
        events = []
        let popupWebView = manager.webView(
            openerWebView,
            createWebViewWith: openerWebView.configuration,
            for: StubPopupNavigationAction(),   // pinned nil targetFrame → popup path
            windowFeatures: WKWindowFeatures())
        XCTAssertNotNil(popupWebView)
        XCTAssertTrue(events.isEmpty,
                      "adoption inherits the opener's evaluation — no apply/remove")
        let popupTab = manager.tabs.first { $0.webView === popupWebView }
        XCTAssertNotNil(popupTab)
        // The opener's controller still carries its one applied set.
        XCTAssertEqual(appliedSetCount(for: opener), 1)

        // The popup re-evaluates independently on ITS first commit — and
        // because the controller is SHARED, an overridden popup host
        // strips the opener's lists too until the opener re-evaluates
        // (accepted + documented consequence).
        overriddenHosts = ["popup.example"]
        popupTab?.navigationDidCommit(URL(string: "https://popup.example/")!)
        XCTAssertEqual(events, [.remove])
        XCTAssertEqual(appliedSetCount(for: opener), 0,
                       "shared controller: the popup's removal affects the opener")
    }

    func testOpenerReappliesAfterPopupStripsSharedController() {
        // Review regression: the opener's marker goes stale against the
        // SHARED controller. Opener blocks on a.example (marker=true) →
        // popup commits to an overridden host, stripping the shared
        // controller → opener commits to c.example, ALSO decision true.
        // Without adoption invalidating the opener's marker, true ==
        // stale true would skip the evaluation and the opener would stay
        // unblocked across every future same-decision commit.
        let manager = makeManager()
        let opener = manager.newTab()
        opener.navigationDidCommit(URL(string: "https://a.example/")!)
        guard let openerWebView = opener.webView else {
            return XCTFail("opener must be live")
        }
        let popupWebView = manager.webView(
            openerWebView,
            createWebViewWith: openerWebView.configuration,
            for: StubPopupNavigationAction(),
            windowFeatures: WKWindowFeatures())
        let popupTab = manager.tabs.first { $0.webView === popupWebView }
        overriddenHosts = ["popup.example"]
        popupTab?.navigationDidCommit(URL(string: "https://popup.example/")!)
        XCTAssertEqual(appliedSetCount(for: opener), 0,
                       "popup's overridden commit strips the shared controller")
        events = []
        opener.navigationDidCommit(URL(string: "https://c.example/")!)
        XCTAssertEqual(events, [.remove, .apply],
                       "opener's next same-decision commit must re-apply, not skip")
        XCTAssertEqual(appliedSetCount(for: opener), 1)
    }

    func testMixedDecisionForcedReevaluationDoesNotRepoisonOpenerMarkerWhenPopupActsLast() {
        // Second-round review regression (final-review Important I-1):
        // reevaluateContentRules(force:true) — the toggle paths — iterates
        // `tabs` in ARRAY order, opener first, popup last, so the LAST
        // sharer to act leaves the shared controller in ITS state while
        // the OTHER sharer's marker stays stale. Adoption-time
        // invalidation (one-shot, already spent before this force pass
        // ever runs) can't catch this; only act-time invalidation
        // (onContentRulesActed, fired on every act, not just adoption)
        // keeps every sharer's marker honest.
        let manager = makeManager()
        let opener = manager.newTab()
        opener.navigationDidCommit(URL(string: "https://a.example/")!)
        guard let openerWebView = opener.webView else {
            return XCTFail("opener must be live")
        }
        let popupWebView = manager.webView(
            openerWebView,
            createWebViewWith: openerWebView.configuration,
            for: StubPopupNavigationAction(),
            windowFeatures: WKWindowFeatures())
        let popupTab = manager.tabs.first { $0.webView === popupWebView }
        overriddenHosts = ["popup.example"]
        popupTab?.navigationDidCommit(URL(string: "https://popup.example/")!)

        // Mixed decision across the shared controller: opener wants
        // blocked (not overridden), popup wants unblocked (overridden).
        // `tabs` order is [opener, popupTab] — opener acts first (applies),
        // popup acts LAST (removes), leaving the shared controller in
        // popup's state even though opener's marker just recorded `true`.
        manager.reevaluateContentRules(force: true)
        XCTAssertEqual(appliedSetCount(for: opener), 0,
                       "popup, acting last in the force pass, leaves the shared controller removed")

        // Opener's own marker is stale the instant popup acted afterward.
        // Its next same-decision commit must still ACT, not skip.
        events = []
        opener.navigationDidCommit(URL(string: "https://c.example/")!)
        XCTAssertEqual(events, [.remove, .apply],
                       "opener must re-apply, not skip, after popup left the shared controller removed")
        XCTAssertEqual(appliedSetCount(for: opener), 1)
    }

    // MARK: - Late policy injection

    func testLatePolicyInjectionPropagatesToExistingTabs() {
        let manager = TabManager(policy: TabLifecyclePolicy(warmLimit: 4))
        let tab = manager.newTab()   // attached with no policy — no events
        manager.contentRulePolicy = makePolicy()
        manager.reevaluateContentRules(force: true)
        XCTAssertEqual(events, [.remove, .apply])
        XCTAssertEqual(appliedSetCount(for: tab), 1)
    }
}
