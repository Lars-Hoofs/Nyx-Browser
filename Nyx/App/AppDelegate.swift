import AppKit
import SwiftUI
import NyxCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NyxWindowController?
    private var webViewHost: WebViewHostController?
    let viewModel = BrowserViewModel()
    private var titleObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let sidebar = NSHostingController(
            rootView: Text("Nyx")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        let webView = WebViewFactory.shared.makeWebView()
        viewModel.bind(to: webView)
        let content = WebViewHostController(webView: webView)

        let split = NyxSplitViewController(sidebar: sidebar, content: content)
        let controller = NyxWindowController(contentViewController: split)
        webViewHost = content
        controller.showWindow(nil)
        titleObservation = webView.observe(\.title, options: [.new]) { [weak controller] webView, _ in
            let title = webView.title ?? ""
            Task { @MainActor in
                controller?.window?.title = title.isEmpty ? "Nyx" : title
            }
        }
        windowController = controller
        content.navigate(to: "https://example.com")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
