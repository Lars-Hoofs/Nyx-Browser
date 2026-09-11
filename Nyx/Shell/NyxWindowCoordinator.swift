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
    private let recorder: HistoryRecorder
    private let historyStore: HistoryStore
    /// M5 adblock (spec §5.6). Internal (not private) because Task 6's
    /// menu-toggle plumbing acts on both from the coordinator's surface.
    let ruleListManager: RuleListManager
    let siteOverrides: SiteOverrideStore
    private let canvas = PaneCanvasController()
    private var splitViewController: NyxSplitViewController!
    private var windowController: NyxWindowController!
    private var launcherPanel: LauncherPanelController!
    /// The view model behind the CURRENTLY VISIBLE launcher — the target
    /// of the panel's onKeyDown hook. Set by makeLauncherView() on each
    /// show, cleared on dismiss; nil whenever the panel is hidden.
    private var launcherViewModel: LauncherViewModel?
    /// Last selection id seen by onSelectionChange — distinguishes real
    /// selection transitions from same-tab re-fires (see closure comment).
    private var lastFocusedTabID: String?

    init() throws {
        let dbURL = DatabaseLocation.url()
        // One NyxDatabase connection backs both SessionStore and
        // HistoryStore (M4: they used to each open their own). Quarantine/
        // retry now wraps the NyxDatabase open itself rather than
        // SessionStore's — same spec §6 guarantee (never launch-fatal),
        // just moved down one layer so history shares the salvage path.
        let database: NyxDatabase
        do {
            database = try NyxDatabase(databaseURL: dbURL)
        } catch {
            NSLog("Nyx database failed to open (%@); quarantining and retrying",
                  String(describing: error))
            let quarantine = dbURL.deletingLastPathComponent()
                .appendingPathComponent("nyx.sqlite.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dbURL, to: quarantine)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: dbURL.path + suffix)
                try? FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: quarantine.path + suffix))
            }
            database = try NyxDatabase(databaseURL: dbURL)
        }
        let store = SessionStore(database: database)
        historyStore = HistoryStore(database: database)
        recorder = HistoryRecorder(store: historyStore)
        manager = TabManager()
        persistence = SessionPersistence(store: store, manager: manager)
        siteOverrides = SiteOverrideStore(database: database)
        ruleListManager = RuleListManager()

        // Adblock wiring (M5 spec §5.6): TabManager sees only closures —
        // never the store or the rule-list manager. Locals (not self)
        // are captured so the policy held by `manager` never retains the
        // coordinator.
        let overrides = siteOverrides
        let ruleLists = ruleListManager
        manager.contentRulePolicy = ContentRulePolicy(
            shouldBlock: { host in
                // Global toggle lands in Task 6 (NyxSettings.adblockEnabled);
                // until then blocking is globally ON — the spec default.
                // A nil host (nothing committed yet) has no override row
                // by definition, and a failed store read falls back to
                // the spec default too (blocking ON — spec §6's
                // "failure → unblocked" is about COMPILE failures, not a
                // transient DB read).
                guard let host else { return true }
                do {
                    return try !overrides.isBlockingDisabled(host: host)
                } catch {
                    NSLog("Nyx: site-override read failed for %@ (%@); blocking stays ON",
                          host, String(describing: error))
                    return true
                }
            },
            apply: { ruleLists.apply(to: $0) },
            remove: { ruleLists.remove(from: $0) })
        // Tabs attached before the (possibly ~19s first-run, spec §6)
        // compile finishes recorded a "block" decision against zero
        // compiled lists — force-re-evaluate them all once readiness
        // lands. Remove-then-apply inside the evaluation keeps this from
        // ever stacking duplicates.
        ruleListManager.onReady = { [weak manager] in
            manager?.reevaluateContentRules(force: true)
        }

        let sidebar = NSHostingController(rootView: SidebarView(manager: manager))
        splitViewController = NyxSplitViewController(sidebar: sidebar, content: canvas)
        windowController = NyxWindowController(contentViewController: splitViewController)

        // The provider runs on EVERY show and builds a fresh
        // LauncherViewModel each time — the Spotlight-style reset the
        // panel's contentProvider design anticipates (no stale query or
        // selection can survive a dismiss). `unowned` is deliberate: the
        // panel controller is solely owned by this coordinator and never
        // escapes it, so the closure cannot outlive `self`; a weak-self
        // fallback would have to fabricate a dummy view model against a
        // dead coordinator, which is worse than documenting the ownership.
        launcherPanel = LauncherPanelController(contentProvider: { [unowned self] in
            self.makeLauncherView()
        })
        // Keyboard nav (see LauncherPanelController.onKeyDown's doc for
        // why this is an event-monitor hook and not view-level handling).
        launcherPanel.onKeyDown = { [unowned self] event in
            self.handleLauncherKeyDown(event)
        }
        launcherPanel.onDismiss = { [unowned self] in
            self.launcherViewModel = nil
        }

        // Wired before start() ever runs persistence.restoreOrBootstrap(),
        // so restored tabs get recorded into history too — TabManager
        // fires onTabCreated exactly once per tab from every creation
        // site (newTab, popup adoption, restore's rebuild loop).
        manager.onTabCreated = { [weak self] tab in self?.recorder.wire(tab) }

        // Both manager callbacks re-layout SYNCHRONOUSLY (T7 review): the
        // canvas's layoutGeneration guard depends on synchronous re-entry —
        // no Task {} / DispatchQueue.async here, ever.
        manager.onSelectionChange = { [weak self] tab in
            guard let self else { return }
            self.relayoutCanvas()
            let title = tab?.title ?? ""
            self.windowController.window?.title = title.isEmpty ? "Nyx" : title
            // onSelectionChange also RE-fires for the selected tab's own
            // url/title mutations (TabManager.registerCallbacks keeps the
            // window title fresh through it) — moving the first responder
            // on those steals focus from the address field mid-typing
            // whenever the page ticks its title. So the responder hop runs
            // only on a real selection TRANSITION (id change), and still
            // AFTER relayoutCanvas: the webview must already sit in the
            // window's view hierarchy for makeFirstResponder to stick.
            if Self.shouldMoveResponder(to: tab?.id, from: self.lastFocusedTabID) {
                self.moveFirstResponderToFocusedPane(tab)
            }
            self.lastFocusedTabID = tab?.id
        }
        manager.onVisibleSetChange = { [weak self] in self?.relayoutCanvas() }
        canvas.onPaneClicked = { [weak self] in self?.manager.select(tabID: $0) }
        canvas.onWeightsCommitted = { [weak self] in
            self?.manager.updateWeights(groupID: $0, weights: $1)
        }
    }

    /// Pure transition guard for the responder hop, extracted so the
    /// regression above stays unit-tested without any window machinery:
    /// move only when the selection actually changed to a tab — never on
    /// same-tab re-fires, never on deselection.
    static func shouldMoveResponder(to newID: String?, from lastID: String?) -> Bool {
        newID != nil && newID != lastID
    }

    /// Keyboard focus follows pane focus (final review): switching panes
    /// inside a visible split (⌥⌘←/→, pane click) must route key events to
    /// the newly focused pane's webview, not leave them with the old one.
    /// Scoped to splits only — a selected tab's group is always the
    /// visible one, so a non-nil group means "in a visible split". Plain
    /// tab switches keep AppKit's own focus behavior (e.g. an address
    /// field focus in flight must not be stolen). Skips when the current
    /// first responder already is (or sits inside) the target webview —
    /// WebKit parks focus on an internal content view, so an identity
    /// check alone would re-steal focus on every callback.
    private func moveFirstResponderToFocusedPane(_ tab: BrowserTab?) {
        guard let tab,
              manager.splitGroup(containing: tab.id) != nil,
              let webView = tab.webView,
              let window = windowController.window else { return }
        if let responder = window.firstResponder as? NSView,
           responder === webView || responder.isDescendant(of: webView) { return }
        window.makeFirstResponder(webView)
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
        // PRECONDITION (T4 review): bootstrap() must be called EXACTLY
        // ONCE per RuleListManager — it has no mid-flight cancellation
        // checkpoints, so a second call during an in-flight run can
        // double-fire onReady and duplicate compiles. This is the single
        // call site; Task 6's toggles re-evaluate tabs but NEVER
        // re-bootstrap.
        ruleListManager.bootstrap()
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

    // MARK: - Launcher (spec §5.5 — Task 6 wires the ⌘K menu item)

    /// Toggles the launcher over the browser window: ⌘K opens it, ⌘K
    /// again (or Esc / click-outside / execute) closes it. Every show
    /// builds a fresh LauncherViewModel via the panel's contentProvider.
    ///
    /// M3-interaction note (preflight-flagged): opening the panel makes
    /// IT key, but that path never touches TabManager, so
    /// onSelectionChange doesn't fire and the responder-follow transition
    /// gate (`shouldMoveResponder`, selection CHANGES only) is never
    /// consulted — the panel and the gate cannot fight.
    func showLauncher() {
        launcherPanel.toggle(over: windowController.window)
    }

    private func makeLauncherView() -> LauncherView {
        let viewModel = LauncherViewModel(
            manager: manager,
            history: historyStore,
            ranker: LauncherRanker(),
            availableCommands: { [weak self] in self?.availableLauncherCommands() ?? [] })
        launcherViewModel = viewModel
        return LauncherView(viewModel: viewModel) { [weak self] action in
            self?.executeLauncherAction(action)
        }
    }

    /// ↑/↓/Enter/⌘Enter for the visible launcher, delivered by the panel
    /// controller's window-gated key monitor. Returns true to consume.
    /// Esc never arrives here — it keeps its responder-chain path into
    /// the panel's cancelOperation.
    private func handleLauncherKeyDown(_ event: NSEvent) -> Bool {
        guard let viewModel = launcherViewModel else { return false }
        switch event.keyCode {
        case 126:   // ↑
            viewModel.moveSelection(-1)
            return true
        case 125:   // ↓
            viewModel.moveSelection(1)
            return true
        case 36, 76, 52:   // Return, keypad Enter, legacy Enter (also what
                           // XCUITest's XCUIKeyboardKey.enter synthesizes —
                           // discovered by T5's end-to-end verification)
            let inNewTab = event.modifierFlags.contains(.command)
            if let action = viewModel.executeSelected(inNewTab: inNewTab) {
                executeLauncherAction(action)
            }
            return true
        default:
            return false
        }
    }

    /// The commands the launcher offers RIGHT NOW — mirrors
    /// AppDelegate.validateMenuItem's gates, so the launcher never lists
    /// a command that would silently no-op. Re-evaluated by the view
    /// model on every recompute.
    private func availableLauncherCommands() -> [LauncherCommand] {
        LauncherCommand.allCases.filter { command in
            switch command {
            case .newTab, .newSpace: return true
            case .splitWithNextTab: return canSplit
            case .breakUpSplit: return isInSplit
            case .closeOtherTabs: return canCloseOtherTabs
            }
        }
    }

    /// Executes a chosen launcher result. Dismisses FIRST, then acts —
    /// the ordering the M3 responder-follow check wants: `hide()` orders
    /// the panel out (key status returns to the main window, whose first
    /// responder was left untouched by the panel), and only THEN does
    /// select()/navigate() fire onSelectionChange — so when the
    /// transition gate does move the first responder (real id change into
    /// a split), `makeFirstResponder` runs against the main window while
    /// it is key again, never against a live panel.
    private func executeLauncherAction(_ action: LauncherAction) {
        launcherPanel.hide()
        switch action {
        case .switchToTab(let tabID):
            manager.select(tabID: tabID)
        case .navigate(let url, let newTab):
            if newTab || manager.selectedTab == nil {
                // focusAddress: false — this tab exists to show `url`,
                // not to be typed into; bumping the token would strand
                // focus in an empty address field AND suppress the URL
                // sync when the navigation commits (SidebarView's
                // !addressFocused guard). The launcher's `.run(.newTab)`
                // COMMAND keeps the default bump via newTab() below.
                manager.newTab(focusAddress: false)
            }
            // Absolute http/https/file URLs pass through AddressParser
            // unchanged, and navigate(to:) already handles webview
            // activation and the file-URL read-access dance.
            manager.navigate(to: url.absoluteString)
        case .run(let command):
            runLauncherCommand(command)
        }
    }

    private func runLauncherCommand(_ command: LauncherCommand) {
        switch command {
        case .newTab: newTab()
        case .splitWithNextTab: splitWithNextTab()
        case .breakUpSplit: breakUpSplit()
        case .closeOtherTabs: manager.closeOtherTabs()
        case .newSpace:
            // Mirrors SidebarView's "New Space" button: create AND open a
            // tab in it, so the user is never stranded on a nil selection.
            manager.newSpace(named: "Space \(manager.spaces.count + 1)")
            manager.newTab()
        }
    }

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

    /// True when Close Other Tabs would actually close something: the
    /// selected space holds at least one tab outside the visible set
    /// (the selected tab's whole group — closeOtherTabs' survivors).
    var canCloseOtherTabs: Bool {
        guard manager.selectedTab != nil, let spaceID = manager.selectedSpaceID
        else { return false }
        return manager.tabs(in: spaceID).count > manager.visibleTabIDs.count
    }

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

    /// Test hook (UI tests): seeds one history entry via the real
    /// HistoryStore so the launcher's history results have something
    /// deterministic to surface, without navigating a webview at all.
    func seedHistory(url: String, title: String) {
        try? historyStore.recordVisit(url: url, title: title, at: Date())
    }
    #endif
}
