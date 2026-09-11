import Observation
import WebKit
import NyxCore

/// Per-tab content-rule (adblock) decisions, injected as closures so the
/// tab layer never sees RuleListManager or SiteOverrideStore directly —
/// the same closure-injection idiom as TabManager's other callbacks
/// (M5 spec §5.6). `shouldBlock` answers one question — "should blocking
/// be active for this host?" — collapsing the global toggle AND the
/// per-site override behind it, so the tab never learns which of the two
/// said no. `nil` host (no committed navigation yet) means "no override
/// can exist": the global default decides.
struct ContentRulePolicy {
    let shouldBlock: @MainActor (String?) -> Bool
    let apply: @MainActor (WKUserContentController) -> Void
    let remove: @MainActor (WKUserContentController) -> Void
}

/// Runtime tab. Owns its WKWebView (spec §5.3: webviews belong to the
/// model, never the view layer); a hibernated tab has webView == nil and
/// carries pendingInteractionState for the next activation.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: String
    private(set) var spaceID: String
    var title: String
    var urlString: String
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    private(set) var webView: WKWebView?
    private(set) var isMediaSuspended = false
    var pendingInteractionState: Data?
    var lastActiveAt: Date
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Fired with the committed URL on every WKNavigationDelegate
    /// didCommit (M4 spec §7: navigation-committed history recording).
    /// Wired by HistoryRecorder, not persistence.
    @ObservationIgnored var onNavigationCommitted: ((URL) -> Void)?
    /// Fired with the URL the new title belongs to and the title itself,
    /// whenever it changes — a dedicated slot so HistoryRecorder's title
    /// enrichment never piggybacks persistence's onStateChange. The URL is
    /// captured synchronously alongside the title read (see
    /// bindObservations) rather than read back from `urlString` inside the
    /// callback: `urlString` is updated by its own independently-scheduled
    /// Task, so a title event racing a same-tab renavigation could
    /// otherwise deliver a title against whatever URL happens to have
    /// landed by the time the callback runs — misattributing it to the
    /// wrong history row.
    @ObservationIgnored var onTitleChangedForHistory: ((URL, String) -> Void)?
    /// Lowercased host of the last COMMITTED navigation (M5 spec §5.6) —
    /// the key SiteOverrideStore rows are stored under. Derived on
    /// didCommit; seeded from `urlString` at attach when still nil (a
    /// record-restored tab knows its URL but has never committed in this
    /// process — without the seed its first load would be evaluated
    /// against a nil host and run BLOCKED even on an overridden site).
    /// Deliberately survives hibernate(): it describes where the tab IS,
    /// so a re-attach evaluates against the right host BEFORE the
    /// interaction-state restore starts its load.
    private(set) var currentHost: String?
    /// Injected by TabManager (which gets it from the coordinator);
    /// nil (e.g. in tests that don't wire adblock) disables evaluation
    /// entirely.
    @ObservationIgnored var contentRulePolicy: ContentRulePolicy?
    /// The decision last acted on for the CURRENT webview's controller —
    /// the "override state differs" guard for didCommit re-evaluation.
    /// Reset to nil on attach/hibernate: a fresh factory webview has a
    /// fresh controller, and a popup's shared controller carries state
    /// this tab didn't put there (see attach's inherit flag).
    @ObservationIgnored private(set) var lastContentRuleEvaluation: Bool?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var navigationRelay: NavigationRelay?

    init(record: TabRecord) {
        id = record.id
        spaceID = record.spaceID
        title = record.title
        urlString = record.urlString
        pendingInteractionState = record.interactionState
        lastActiveAt = record.lastActiveAt
    }

    init(id: String = UUID().uuidString, spaceID: String) {
        self.id = id
        self.spaceID = spaceID
        title = ""
        urlString = ""
        pendingInteractionState = nil
        lastActiveAt = Date()
    }

    /// Wires an owned webview: KVO bridging, UI delegate, and interaction
    /// state restore. `webView` may be freshly made (activation) or handed
    /// to us by WebKit (popup adoption) — in the popup case WebKit does
    /// the loading, so we only restore state when we have some pending.
    ///
    /// Content rules are evaluated here, after the delegates and BEFORE
    /// the restore/load below kicks anything off, so the load runs under
    /// the right blocking state from its first request (M5 spec §5.6) —
    /// this is also why a hibernated tab always re-evaluates on
    /// re-activation (the M4-review caveat).
    ///
    /// `inheritingContentRules` (popup adoption only): a popup's webview
    /// shares its OPENER's WKUserContentController — WebKit hands us the
    /// opener's configuration so window.opener works — so the popup
    /// inherits whatever evaluation the opener last applied, and
    /// evaluating here against the popup's (still-nil) host would clobber
    /// the opener's state mid-page. The popup re-evaluates independently
    /// on its own first didCommit (and any later attach, which gets a
    /// fresh factory webview and therefore a private controller).
    /// Accepted consequence of the shared controller: an apply/remove for
    /// either tab's site affects both, and the bleed lasts until the
    /// affected side next evaluates AND ACTS — its next cross-host
    /// commit, a re-attach (fresh factory controller), or a forced
    /// re-evaluation — never merely its next commit. Adoption therefore
    /// also invalidates the OPENER's evaluation marker (TabManager calls
    /// invalidateContentRuleEvaluation): a stale "already applied" marker
    /// would otherwise skip every future same-decision commit and leave
    /// the opener unblocked indefinitely after the popup strips the
    /// shared controller.
    func attach(_ webView: WKWebView, uiDelegate: WKUIDelegate?,
                inheritingContentRules: Bool = false) {
        self.webView = webView
        webView.uiDelegate = uiDelegate
        let relay = NavigationRelay(tab: self)
        navigationRelay = relay
        webView.navigationDelegate = relay
        lastContentRuleEvaluation = nil
        if !inheritingContentRules {
            if currentHost == nil, !urlString.isEmpty {
                // Same parser the load below uses, so a scheme-less
                // persisted urlString still yields its host.
                currentHost = AddressParser.destinationURL(for: urlString)?
                    .host?.lowercased()
            }
            evaluateContentRules()
        }
        if let state = pendingInteractionState {
            webView.interactionState = state
            pendingInteractionState = nil
        } else if !urlString.isEmpty,
                  webView.url == nil,
                  let url = AddressParser.destinationURL(for: urlString) {
            webView.load(URLRequest(url: url))
        }
        bindObservations(to: webView)
    }

    /// Captures interaction state, tears the webview down, and returns the
    /// captured state (also kept in pendingInteractionState).
    @discardableResult
    func hibernate() -> Data? {
        let state = currentInteractionState()
        pendingInteractionState = state
        observations = []
        webView?.uiDelegate = nil
        webView?.navigationDelegate = nil
        navigationRelay = nil
        webView = nil
        // currentHost deliberately survives (see its doc); the evaluation
        // marker doesn't — it described the just-discarded controller.
        lastContentRuleEvaluation = nil
        isMediaSuspended = false   // a freshly attached webview starts unsuspended
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
        return state
    }

    /// Space membership changes only through TabManager.moveTab(_:toSpace:),
    /// which removes the tab from any split group first (groups never span
    /// spaces, spec §5.1).
    func reassign(toSpace spaceID: String) { self.spaceID = spaceID }

    /// Media suspension for panes leaving a visible split (spec §5.2) —
    /// never triggered by plain tab switches. State-guarded: the webview
    /// only hears actual transitions, so re-activating a never-suspended
    /// pane is a no-op.
    func setMediaSuspended(_ suspended: Bool) {
        guard suspended != isMediaSuspended else { return }
        isMediaSuspended = suspended
        webView?.setAllMediaPlaybackSuspended(suspended)
    }

    /// Applies the content-rule decision for `currentHost` to the live
    /// webview's controller (M5 spec §5.6): blocking on → remove-then-add
    /// every compiled list; blocking off → remove them all. The
    /// remove-before-apply makes every evaluation idempotent — a popup's
    /// shared controller (unknown inherited state) and an onReady forced
    /// re-application (lists were applied while `compiledLists` was still
    /// empty) both land on the same clean slate instead of accumulating
    /// duplicates. No-op without a policy or a webview.
    ///
    /// `force` bypasses the unchanged-decision guard — the two callers
    /// that need it are RuleListManager.onReady (the decision "block" was
    /// already recorded pre-readiness, but zero lists actually landed) and
    /// Task 6's toggle path (a same-host override flip changes the answer
    /// for an unchanged host).
    func evaluateContentRules(force: Bool = false) {
        guard let contentRulePolicy, let webView else { return }
        let decision = contentRulePolicy.shouldBlock(currentHost)
        guard force || decision != lastContentRuleEvaluation else { return }
        let controller = webView.configuration.userContentController
        contentRulePolicy.remove(controller)
        if decision { contentRulePolicy.apply(controller) }
        lastContentRuleEvaluation = decision
    }

    /// Popup-adoption support (TabManager's createWebViewWith path): the
    /// popup shares this tab's user content controller, so this tab's
    /// marker no longer reflects state it alone controls — future popup
    /// evaluations can change the controller behind this tab's back.
    /// Nil-ing the marker makes this tab's next evaluation (cross-host
    /// commit, re-attach, force) act instead of trusting a stale
    /// "already applied"/"already removed" answer.
    func invalidateContentRuleEvaluation() {
        lastContentRuleEvaluation = nil
    }

    /// The single committed-navigation funnel (called by NavigationRelay):
    /// tracks `currentHost` and re-evaluates content rules on a host
    /// CHANGE — the unchanged-decision guard inside evaluateContentRules
    /// turns that into "different host whose override state differs", per
    /// the plan — then forwards to the history callback. Ordering is
    /// deliberate: rules first (they gate the page still loading), history
    /// second. No auto-reload here: subresources fetched before this
    /// commit ran under the previous state; the toggle path (Task 6) is
    /// the one that reloads, and a cross-override navigation accepts the
    /// one-load imprecision (documented plan trade-off).
    func navigationDidCommit(_ url: URL) {
        let host = url.host?.lowercased()
        if host != currentHost {
            currentHost = host
            evaluateContentRules()
        }
        onNavigationCommitted?(url)
    }

    func currentInteractionState() -> Data? {
        if let webView { return webView.interactionState as? Data }
        return pendingInteractionState
    }

    func record(orderIndex: Int) -> TabRecord {
        TabRecord(id: id, spaceID: spaceID, urlString: urlString, title: title,
                  orderIndex: orderIndex,
                  interactionState: currentInteractionState(),
                  lastActiveAt: lastActiveAt)
    }

    private func bindObservations(to webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.url?.absoluteString ?? ""
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    guard self.urlString != value, !value.isEmpty else { return }
                    self.urlString = value
                    self.onStateChange?()
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.title ?? ""
                // Read alongside the title, synchronously, OUTSIDE the
                // Task — same discipline as the value read above: the URL
                // this title belongs to is a property of THIS KVO
                // notification, not whatever `urlString` reads later.
                let titleURL = webView.url
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    guard self.title != value else { return }
                    self.title = value
                    self.onStateChange?()
                    if let titleURL {
                        self.onTitleChangedForHistory?(titleURL, value)
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    self.canGoBack = value
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    self.canGoForward = value
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.isLoading
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    self.isLoading = value
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    self.progress = value
                }
            }
        ]
    }
}

/// Forwards WKNavigationDelegate's didCommit into the owning tab's
/// navigationDidCommit funnel (M4 spec §7 history + M5 §5.6 host
/// tracking). Created per attach(), torn down in
/// hibernate() alongside the KVO observations — same stale-delivery
/// discipline as bindObservations' closures: holds `tab` weakly and
/// verifies `tab.webView === webView` before forwarding, so a relay whose
/// tab has since hibernated or re-attached a different webview is a no-op
/// rather than delivering a stale navigation event.
@MainActor
private final class NavigationRelay: NSObject, WKNavigationDelegate {
    private weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab, tab.webView === webView, let url = webView.url else { return }
        tab.navigationDidCommit(url)
    }
}
