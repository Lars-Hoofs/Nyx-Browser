import Observation
import WebKit

/// Bridges WKWebView KVO into observable state for the SwiftUI chrome.
@MainActor
@Observable
final class BrowserViewModel {
    var urlString = ""
    var pageTitle = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    /// Incremented by menu/shortcuts to request address-field focus (⌘L).
    var addressFocusToken = 0

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    func bind(to webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.url?.absoluteString ?? ""
                Task { @MainActor in self?.urlString = value }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.title ?? ""
                Task { @MainActor in self?.pageTitle = value }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.isLoading
                Task { @MainActor in self?.isLoading = value }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor in self?.progress = value }
            }
        ]
    }
}
