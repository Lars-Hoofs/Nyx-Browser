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
    let spaceID: String
    var title: String
    var urlString: String
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    private(set) var webView: WKWebView?
    var pendingInteractionState: Data?
    var lastActiveAt: Date
    @ObservationIgnored var onStateChange: (() -> Void)?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

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
        webView = nil
        isLoading = false
        progress = 0
        canGoBack = false
        canGoForward = false
        return state
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
