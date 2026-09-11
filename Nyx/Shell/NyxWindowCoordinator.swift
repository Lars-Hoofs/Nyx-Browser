import AppKit
import SwiftUI
import WebKit
import NyxCore

/// Composition root (M1 final-review recommendation): owns the window,
/// the split, the pane, the manager, and persistence. AppDelegate only
/// bootstraps this and forwards menu actions.
///
/// Not an NSObject subclass: NSObject's designated `init()` cannot be
/// overridden by a throwing `init()`, and nothing here needs Obj-C
/// dispatch — menu actions land on AppDelegate and forward as Swift calls.
@MainActor
final class NyxWindowCoordinator {
    let manager: TabManager
    private let persistence: SessionPersistence
    private let pane = PaneViewController()
    private var splitViewController: NyxSplitViewController!
    private var windowController: NyxWindowController!

    init() throws {
        let store = try SessionStore(databaseURL: DatabaseLocation.url())
        manager = TabManager()
        persistence = SessionPersistence(store: store, manager: manager)

        let sidebar = NSHostingController(rootView: SidebarView(manager: manager))
        splitViewController = NyxSplitViewController(sidebar: sidebar, content: pane)
        windowController = NyxWindowController(contentViewController: splitViewController)

        manager.onSelectionChange = { [weak self] tab in
            self?.pane.present(tab?.webView)
            let title = tab?.title ?? ""
            self?.windowController.window?.title = title.isEmpty ? "Nyx" : title
        }
    }

    func start() {
        persistence.restoreOrBootstrap()
        windowController.showWindow(nil)
    }

    func flushSession() { persistence.flushNow() }

    // MARK: - Menu plumbing

    func newTab() { manager.newTab() }

    func closeTab() {
        guard let tab = manager.selectedTab else { return }
        manager.close(tab)
        if manager.tabs.isEmpty == false { return }
        windowController.window?.performClose(nil)
    }

    func reloadPage() { manager.reload() }
    func goBack() { manager.goBack() }
    func goForward() { manager.goForward() }

    func focusAddress() {
        // ⌘L with a collapsed sidebar must reveal it first (M1 review).
        if let item = splitViewController.splitViewItems.first, item.isCollapsed {
            item.animator().isCollapsed = false
        }
        manager.addressFocusToken += 1
    }

    func selectNextTab() { selectAdjacentTab(offset: 1) }
    func selectPreviousTab() { selectAdjacentTab(offset: -1) }

    var canGoBack: Bool { manager.selectedTab?.canGoBack ?? false }
    var canGoForward: Bool { manager.selectedTab?.canGoForward ?? false }
    var canCloseTab: Bool { manager.selectedTab != nil }

    private func selectAdjacentTab(offset: Int) {
        guard let spaceID = manager.selectedSpaceID else { return }
        let inSpace = manager.tabs(in: spaceID)
        guard !inSpace.isEmpty,
              let current = manager.selectedTab,
              let index = inSpace.firstIndex(where: { $0.id == current.id })
        else { return }
        let next = (index + offset + inSpace.count) % inSpace.count
        manager.select(inSpace[next])
    }

    #if DEBUG
    /// Test hook (offline UI tests): load inline HTML into the selected tab.
    func loadTestHTML(_ html: String) {
        guard let tab = manager.selectedTab else { return }
        if tab.webView == nil { manager.select(tab) }
        tab.webView?.loadHTMLString(html, baseURL: nil)
    }
    #endif
}
