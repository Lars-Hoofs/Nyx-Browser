import AppKit
import SwiftUI
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NyxWindowController?
    private var webViewHost: WebViewHostController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let sidebar = NSHostingController(
            rootView: Text("Nyx")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        let webView = WebViewFactory.shared.makeWebView()
        let content = WebViewHostController(webView: webView)

        let split = NyxSplitViewController(sidebar: sidebar, content: content)
        let controller = NyxWindowController(contentViewController: split)
        webViewHost = content
        controller.showWindow(nil)
        windowController = controller
        content.navigate(to: "https://example.com")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
