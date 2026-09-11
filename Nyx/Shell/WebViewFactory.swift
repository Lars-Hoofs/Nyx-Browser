import WebKit

/// Builds WKWebViews per spec §5.3: one shared website data store,
/// a per-tab WKUserContentController (required for per-tab adblock in M5),
/// Safari-identical UA. Not final: NyxTests subclasses it to inject spy
/// webviews (the media-suspension seam).
@MainActor
class WebViewFactory {
    static let shared = WebViewFactory()

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = WKUserContentController()
        configuration.applicationNameForUserAgent = NyxUserAgent.applicationName
        return makeWebView(adopting: configuration)
    }

    /// Builds a webview from an externally supplied configuration (popup
    /// adoption hands us WebKit's) and applies Nyx's per-webview settings.
    func makeWebView(adopting configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }
}
