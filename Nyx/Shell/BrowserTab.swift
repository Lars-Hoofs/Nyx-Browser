import Observation
import WebKit
import NyxCore

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
    /// Fired with the new title whenever it changes — a dedicated slot so
    /// HistoryRecorder's title enrichment never piggybacks persistence's
    /// onStateChange.
    @ObservationIgnored var onTitleChangedForHistory: ((String) -> Void)?

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
    func attach(_ webView: WKWebView, uiDelegate: WKUIDelegate?) {
        self.webView = webView
        webView.uiDelegate = uiDelegate
        let relay = NavigationRelay(tab: self)
        navigationRelay = relay
        webView.navigationDelegate = relay
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
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.webView === webView else { return }
                    guard self.title != value else { return }
                    self.title = value
                    self.onStateChange?()
                    self.onTitleChangedForHistory?(value)
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
/// onNavigationCommitted (M4 spec §7). Created per attach(), torn down in
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
        tab.onNavigationCommitted?(url)
    }
}
