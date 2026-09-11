import AppKit
import WebKit
import NyxCore

/// Hosts one WKWebView, frame-based (spec §5.1): autoresizing masks only —
/// no Auto Layout, no SwiftUI — so live resizes mutate frames directly.
@MainActor
final class WebViewHostController: NSViewController {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DesignTokens.baseSurface.cgColor

        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        view = container

        // Earliest point self is available as a fully-initialized instance
        // (loadView runs once, right after init) — set here rather than
        // viewWillAppear so the delegate is live before any navigation.
        webView.uiDelegate = self
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        webView.frame = view.bounds
    }
}

extension WebViewHostController: BrowserCommands {
    func navigate(to input: String) {
        guard let url = AddressParser.destinationURL(for: input) else { return }
        if url.isFileURL {
            // Sandbox: grant the WebContent process read access to the folder.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }
}

extension WebViewHostController: WKUIDelegate {
    /// M1 fallback: open target="_blank"/window.open requests in the same
    /// webview. Real tab creation (honoring the passed configuration,
    /// spec §5.3) arrives with tabs in M2.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
