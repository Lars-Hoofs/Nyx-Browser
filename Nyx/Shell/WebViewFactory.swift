import WebKit

/// Builds WKWebViews per spec §5.3: one shared website data store,
/// a per-tab WKUserContentController (required for per-tab adblock in M5),
/// Safari-identical UA.
@MainActor
final class WebViewFactory {
    static let shared = WebViewFactory()

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = WKUserContentController()
        configuration.applicationNameForUserAgent = NyxUserAgent.applicationName

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }
}
