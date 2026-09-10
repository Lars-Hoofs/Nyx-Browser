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
        NSApp.mainMenu = MainMenuBuilder.build(delegate: self)

        NSApp.appearance = NSAppearance(named: .darkAqua)

        let webView = WebViewFactory.shared.makeWebView()
        viewModel.bind(to: webView)
        let content = WebViewHostController(webView: webView)

        let sidebar = NSHostingController(
            rootView: SidebarView(model: viewModel, commands: content)
        )

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

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) {
        // M2 gives Nyx real tabs; until then ⌘T focuses the address field.
        viewModel.addressFocusToken += 1
    }

    @objc func focusAddressField(_ sender: Any?) {
        viewModel.addressFocusToken += 1
    }

    @objc func reloadPage(_ sender: Any?) {
        webViewHost?.reload()
    }

    @objc func goBack(_ sender: Any?) {
        webViewHost?.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        webViewHost?.goForward()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return viewModel.canGoBack
        case #selector(goForward(_:)): return viewModel.canGoForward
        default: return true
        }
    }
}
