import AppKit
import WebKit

/// Hosts the selected tab's webview, frame-based (spec §5.1) — the
/// webview belongs to its BrowserTab; this controller only presents it.
/// In M3 the pane canvas holds up to four of these side by side.
@MainActor
final class PaneViewController: NSViewController {
    private var currentWebView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

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
        observations = []   // never observe a webview we no longer present
        currentWebView = webView
        guard let webView else {
            view.layer?.backgroundColor = DesignTokens.baseSurface.cgColor
            return
        }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = view.bounds
        view.addSubview(webView)
        bindBackgroundObservations(to: webView)
    }

    /// Divider-drag resize masking (spec §5.1): during a resize the
    /// container edge peeks out from behind the webview, so it must wear
    /// the page's own color — themeColor when the page declares one, else
    /// WebKit's under-page background, else the base surface token.
    /// Fallback resolution lives here so either key changing re-resolves
    /// the whole chain. Same KVO shape as BrowserTab's: value read
    /// synchronously OUTSIDE the Task (the observed webview is the source
    /// of truth, not a later snapshot), weak self, and a stale guard
    /// against a webview this pane has since stopped presenting.
    private func bindBackgroundObservations(to webView: WKWebView) {
        observations = [
            webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] webView, _ in
                // themeColor/underPageBackgroundColor are MainActor-isolated
                // in the SDK; the KVO handler itself is not statically
                // MainActor per its (NSObject, Change) -> Void signature,
                // but WebKit always fires these notifications on the main
                // thread — assumeIsolated documents and asserts that fact
                // to the compiler rather than hopping through a Task (which
                // would read a possibly-newer snapshot by the time it runs).
                let resolved = MainActor.assumeIsolated { Self.resolvedBackground(of: webView) }
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.currentWebView === webView else { return }
                    self.view.layer?.backgroundColor = resolved.cgColor
                }
            },
            webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] webView, _ in
                let resolved = MainActor.assumeIsolated { Self.resolvedBackground(of: webView) }
                Task { @MainActor [weak webView] in
                    guard let self, let webView, self.currentWebView === webView else { return }
                    self.view.layer?.backgroundColor = resolved.cgColor
                }
            }
        ]
    }

    private static func resolvedBackground(of webView: WKWebView) -> NSColor {
        webView.themeColor ?? webView.underPageBackgroundColor ?? DesignTokens.baseSurface
    }
}
