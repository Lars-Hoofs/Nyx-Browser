import AppKit
import WebKit

/// Hosts the selected tab's webview, frame-based (spec §5.1) — the
/// webview belongs to its BrowserTab; this controller only presents it.
/// In M3 the pane canvas will hold up to four of these side by side.
@MainActor
final class PaneViewController: NSViewController {
    private var currentWebView: WKWebView?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DesignTokens.baseSurface.cgColor
        // A bare NSView is NOT an accessibility element by default (unlike
        // control subclasses such as NSSplitView) — without this, the
        // "nyx.pane" identifier set on it by PaneCanvasController is never
        // published to the accessibility tree and UI tests can never find it.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        view = container
    }

    func present(_ webView: WKWebView?) {
        guard webView !== currentWebView else { return }
        // Detach only if the webview is still ours — during canvas
        // re-layout it may already have moved to another pane.
        if currentWebView?.superview === view {
            currentWebView?.removeFromSuperview()
        }
        currentWebView = webView
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = view.bounds
        view.addSubview(webView)
    }
}
