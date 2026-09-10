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
