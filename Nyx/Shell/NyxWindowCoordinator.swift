import AppKit
import SwiftUI
import WebKit
import NyxCore

/// Composition root (M1 final-review recommendation): owns the window,
/// the split, the pane canvas, the manager, and persistence. AppDelegate
/// only bootstraps this and forwards menu actions.
///
/// Not an NSObject subclass: NSObject's designated `init()` cannot be
/// overridden by a throwing `init()`, and nothing here needs Obj-C
/// dispatch — menu actions land on AppDelegate and forward as Swift calls.
@MainActor
final class NyxWindowCoordinator {
    let manager: TabManager
    private let persistence: SessionPersistence
    private let canvas = PaneCanvasController()
    private var splitViewController: NyxSplitViewController!
    private var windowController: NyxWindowController!

    init() throws {
        let dbURL = DatabaseLocation.url()
        let store: SessionStore
        do {
            store = try SessionStore(databaseURL: dbURL)
        } catch {
            // Spec §6: the session DB must never be launch-fatal. Quarantine
            // the corrupt file and start fresh; the old data stays on disk.
            NSLog("Nyx session DB failed to open (%@); quarantining and retrying",
                  String(describing: error))
            let quarantine = dbURL.deletingLastPathComponent()
                .appendingPathComponent("nyx.sqlite.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dbURL, to: quarantine)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: dbURL.path + suffix)
                try? FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: quarantine.path + suffix))
            }
            store = try SessionStore(databaseURL: dbURL)
        }
        manager = TabManager()
        persistence = SessionPersistence(store: store, manager: manager)

        let sidebar = NSHostingController(rootView: SidebarView(manager: manager))
        splitViewController = NyxSplitViewController(sidebar: sidebar, content: canvas)
        windowController = NyxWindowController(contentViewController: splitViewController)

        // Both manager callbacks re-layout SYNCHRONOUSLY (T7 review): the
        // canvas's layoutGeneration guard depends on synchronous re-entry —
        // no Task {} / DispatchQueue.async here, ever.
        manager.onSelectionChange = { [weak self] tab in
            guard let self else { return }
            self.relayoutCanvas()
            let title = tab?.title ?? ""
            self.windowController.window?.title = title.isEmpty ? "Nyx" : title
        }
        manager.onVisibleSetChange = { [weak self] in self?.relayoutCanvas() }
        canvas.onPaneClicked = { [weak self] in self?.manager.select(tabID: $0) }
        canvas.onWeightsCommitted = { [weak self] in
            self?.manager.updateWeights(groupID: $0, weights: $1)
        }
    }

    /// Rebuilds the canvas from the manager's visible set. The canvas may
    /// deliver transient layouts mid-mutation; the manager's final callback
    /// state is authoritative, so this never dedupes or defers.
    private func relayoutCanvas() {
        let visible = manager.visibleTabIDs
        let entries: [(id: String, webView: WKWebView?)] = visible.compactMap { id in
            guard let tab = manager.tabs.first(where: { $0.id == id }) else { return nil }
            return (id: id, webView: tab.webView)
        }
        let group = manager.selectedTab.flatMap {
            manager.splitGroup(containing: $0.id)
        }
        canvas.layout(tabs: entries,
                      weights: group?.weights ?? [1.0],
                      groupID: group?.id,
                      focusedTabID: manager.selectedTabID)
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

    // MARK: - Split menu plumbing (Task 10 wires the menu items)

    /// Splits the current tab with the first splittable same-space tab
    /// (spec §5.1). TabManager enforces the cap and logs refusals.
    func splitWithNextTab() {
        guard let current = manager.selectedTab,
              let next = splitCandidate(for: current) else { return }
        manager.split(current, with: next)
    }

    func breakUpSplit() {
        guard let current = manager.selectedTab else { return }
        manager.dissolveSplit(containing: current)
    }

    /// Pane focus = selecting the adjacent tab in the group's pane order.
    func focusNextPane() { focusAdjacentPane(offset: 1) }
    func focusPreviousPane() { focusAdjacentPane(offset: -1) }

    var canSplit: Bool {
        guard let current = manager.selectedTab else { return false }
        let groupCount = manager.splitGroup(containing: current.id)?.tabIDs.count ?? 1
        return groupCount < 4 && splitCandidate(for: current) != nil
    }

    var isInSplit: Bool {
        manager.selectedTab.flatMap { manager.splitGroup(containing: $0.id) } != nil
    }

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

    /// The tab a split would pull in: first same-space tab that is neither
    /// the current tab nor in ANY split group — a member of another group
    /// would make TabManager refuse, so counting it would enable a menu
    /// item that silently no-ops.
    private func splitCandidate(for current: BrowserTab) -> BrowserTab? {
        manager.tabs(in: current.spaceID).first {
            $0.id != current.id && manager.splitGroup(containing: $0.id) == nil
        }
    }

    private func focusAdjacentPane(offset: Int) {
        guard let current = manager.selectedTab,
              let group = manager.splitGroup(containing: current.id),
              let index = group.tabIDs.firstIndex(of: current.id) else { return }
        let next = (index + offset + group.tabIDs.count) % group.tabIDs.count
        manager.select(tabID: group.tabIDs[next])
    }

    #if DEBUG
    /// Test hook (offline UI tests): load inline HTML into the selected tab.
    func loadTestHTML(_ html: String) {
        guard let tab = manager.selectedTab else { return }
        // Selection is always activated by restore/bootstrap before this runs.
        tab.webView?.loadHTMLString(html, baseURL: nil)
    }
    #endif
}
