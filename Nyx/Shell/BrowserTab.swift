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
    /// Fired by evaluateContentRules() whenever it ACTS on a controller
    /// — actually calls remove/apply, not merely re-confirms an already
    /// current decision. TabManager (registerCallbacks) uses this to
    /// invalidate every OTHER live tab whose webview shares that same
    /// WKUserContentController (see attach's shared-controller doc):
    /// this generalizes the old popup-adoption-only invalidation to
    /// EVERY act, so a mixed-decision force pass (Task 6's toggle
    /// paths, which iterate tabs in array order) can't leave the
    /// non-last-acting sharer's marker stale regardless of which
    /// sharer happens to act last.
    @ObservationIgnored var onContentRulesActed: ((WKUserContentController) -> Void)?
    /// Fired by NavigationRelay's two `didBecome` handlers the instant a
    /// `.download` policy decision materializes as a WKDownload (M6 spec
    /// §5.7). Wired by TabManager (registerCallbacks) — same closure-
    /// injection shape as onContentRulesActed above — up to the
    /// coordinator, whose DownloadManager.adopt(_:) assigns the
    /// download's delegate as its first statement. The whole chain is
    /// one synchronous hop: WebKit silently cancels a download that
    /// leaves didBecome without a delegate (spec §5.7).
    @ObservationIgnored var onDownloadStarted: ((WKDownload) -> Void)?
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
    /// either tab's site affects both, and the bleed lasts only until the
    /// affected side's marker is next invalidated — which happens
    /// automatically every time ANY sharer's evaluation ACTS on the
    /// shared controller, not just once at adoption: BrowserTab fires
    /// onContentRulesActed whenever evaluateContentRules actually
    /// removes/applies, and TabManager (registerCallbacks) invalidates
    /// every OTHER live tab whose controller is that same instance. So
    /// the affected side's very next evaluation — its next cross-host
    /// commit, a re-attach (fresh factory controller), or a forced
    /// re-evaluation, in WHICHEVER order the sharers happen to act —
    /// always acts instead of trusting a stale "already applied"/
    /// "already removed" answer. (This also covers a mixed-decision
    /// force pass where one sharer acts after the other: each act
    /// invalidates the other, so neither marker can end up describing a
    /// controller state the OTHER sharer has since overwritten.)
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
        // Just acted on `controller` — tell TabManager so it can
        // invalidate every OTHER live tab sharing this same controller
        // (shared-controller marker generalization; see attach's doc
        // and the property doc above). Fired after lastContentRuleEvaluation
        // is set, and only for THIS tab's own marker — TabManager is
        // responsible for never routing it back into the acting tab.
        onContentRulesActed?(controller)
    }

    /// Shared-controller marker invalidation: called by TabManager
    /// (the onContentRulesActed wiring in registerCallbacks) whenever
    /// ANOTHER live tab sharing this tab's user content controller just
    /// ACTED on it (removed/applied lists) — this tab's marker no longer
    /// reflects state it alone controls. Nil-ing it makes this tab's
    /// next evaluation (cross-host commit, re-attach, force) act instead
    /// of trusting a stale "already applied"/"already removed" answer.
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
///
/// M6 (spec §5.7) adds the two `decidePolicyFor` methods and the two
/// `didBecome` download handlers. Internal (not `private`) since M6:
/// the pure `shouldDownload` statics below are unit-tested via
/// `@testable import Nyx` (DownloadPolicyTests) — nothing else about
/// the type's ownership or lifetime changed.
@MainActor
final class NavigationRelay: NSObject, WKNavigationDelegate {
    private weak var tab: BrowserTab?

    init(tab: BrowserTab) {
        self.tab = tab
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab, tab.webView === webView, let url = webView.url else { return }
        tab.navigationDidCommit(url)
    }

    // MARK: - Download policy (M6 spec §5.7)

    /// HOT PATH — runs on EVERY navigation the browser ever makes (link
    /// clicks, redirects, form posts). The ONLY behavioral delta versus
    /// having no implementation at all: `shouldPerformDownload` (an
    /// explicit download gesture, e.g. an anchor's `download` attribute)
    /// turns into `.download`. Everything else is `.allow`, immediately
    /// and unconditionally — no logging, no other work here, ever.
    ///
    /// Deliberately the 2-arg overload, NOT the `preferences:` variant:
    /// WebKit calls the preferences overload INSTEAD of this one when
    /// both exist (WKNavigationDelegate.h: "if you implement this method,
    /// -webView:decidePolicyForNavigationAction:decisionHandler: will not
    /// be called"), and taking that variant would make us responsible for
    /// passing WKWebpagePreferences through on every navigation. We have
    /// no per-navigation preferences to set, so the 2-arg form keeps
    /// WebKit's own preferences handling untouched.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// HOT PATH (every main/subframe response). `.download` only when the
    /// response itself says so — un-renderable MIME type, or an explicit
    /// Content-Disposition attachment; the default stays `.allow`.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(Self.shouldDownload(navigationResponse) ? .download : .allow)
    }

    /// Spec §5.7 (binding, silent-cancel warning): WebKit cancels a
    /// download that leaves this method without a delegate — so the
    /// handoff is the FIRST statement. The chain is fully synchronous:
    /// tab.onDownloadStarted → TabManager.onDownloadStarted → the
    /// coordinator → DownloadManager.adopt(_:), whose own first statement
    /// is `download.delegate = self`. No stale-webview guard here, on
    /// purpose: the download is app-global the moment it exists, and
    /// dropping it because the tab re-attached in between would BE the
    /// silent cancel the spec warns about. (An unwired callback — tests
    /// that never install one — does lose the download; production
    /// wiring is unconditional in registerCallbacks.)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        tab?.onDownloadStarted?(download)
    }

    /// Same contract as the navigationAction variant above: handoff first,
    /// synchronously, nothing else.
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        tab?.onDownloadStarted?(download)
    }

    /// The response-policy decision (spec §5.7): download iff WebKit
    /// cannot render the MIME type, or an HTTP response explicitly
    /// declares itself an attachment. Thin WebKit-reading wrapper — the
    /// testable logic lives in the overload below (a non-HTTP response
    /// has no Content-Disposition, so it downloads only when
    /// !canShowMIMEType, which is exactly what passing nil encodes).
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        shouldDownload(
            canShowMIMEType: response.canShowMIMEType,
            contentDisposition: (response.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition"))
    }

    /// Pure header matrix (unit-tested without WebKit fakes —
    /// DownloadPolicyTests): an un-renderable type always downloads; a
    /// renderable one downloads only when the Content-Disposition value,
    /// after trimming leading whitespace, case-insensitively starts with
    /// "attachment" (RFC 6266 tokens are case-insensitive; parameters
    /// like `; filename=x` ride behind the prefix). "inline", absent, or
    /// anything else → allow.
    static func shouldDownload(canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        guard canShowMIMEType else { return true }
        guard let contentDisposition else { return false }
        return contentDisposition.drop(while: \.isWhitespace)
            .lowercased().hasPrefix("attachment")
    }
}
