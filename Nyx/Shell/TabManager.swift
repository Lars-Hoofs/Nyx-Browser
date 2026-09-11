import AppKit
import Observation
import WebKit
import NyxCore

/// The heart of M2 (spec §5.2/§5.3): owns all runtime tabs and spaces,
/// drives selection, hibernation (MRU policy), popup adoption, and is the
/// BrowserCommands target for chrome and menu.
@MainActor
@Observable
final class TabManager: NSObject {
    /// A runtime split group (spec §5.1): a flat column of 2–4 tabs in one
    /// space. `tabIDs` order is pane order; `weights` sum 1.0, each ≥ 0.15.
    /// A tab belongs to at most one group.
    struct RuntimeSplitGroup: Equatable {
        var id: String
        var tabIDs: [String]      // 2...4, order = pane order
        var weights: [Double]
    }

    private(set) var spaces: [SpaceRecord] = []
    private(set) var tabs: [BrowserTab] = []
    private(set) var splitGroups: [RuntimeSplitGroup] = []
    private(set) var selectedSpaceID: String?
    private(set) var selectedTabID: String?
    var addressFocusToken = 0

    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onSelectionChange: ((BrowserTab?) -> Void)?
    /// Fires immediately after a tab is hibernated by the manager (MRU
    /// eviction or memory pressure — the only two callers of
    /// `hibernateVictims`) with its captured interaction-state blob, so
    /// SessionPersistence can write that tab's row without waiting for the
    /// next debounced full-session save. Never fired from `close()`: the
    /// tab is being deleted outright, so there is no row left to target
    /// once it's gone (see close()'s own comment).
    @ObservationIgnored var onTabHibernated: ((String, Data?) -> Void)?
    /// Canvas re-layout trigger: fires only when a change actually altered
    /// the visible pane layout — the visible tab set or its weights.
    /// Mutations to non-visible groups and focus moves within a group fire
    /// `onStateChange`/`onSelectionChange` only. `onSelectionChange`
    /// semantics are unchanged.
    @ObservationIgnored var onVisibleSetChange: (() -> Void)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var policy: TabLifecyclePolicy
    /// Most-recently-used first; only ids of tabs holding live webviews.
    @ObservationIgnored private var mruLive: [String] = []
    /// Retained for the lifetime of this TabManager: a DispatchSourceMemoryPressure
    /// with no other owner suspends/cancels itself once deallocated, so
    /// this property's only job is to keep the source alive for as long as
    /// the manager is — there is no explicit cancel() on teardown, and none
    /// is needed since TabManager itself lives for the app's lifetime.
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(factory: WebViewFactory? = nil,
         policy: TabLifecyclePolicy = TabLifecyclePolicy()) {
        self.factory = factory ?? .shared
        self.policy = policy
        super.init()
        installMemoryPressureHandler()
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func splitGroup(containing tabID: String) -> RuntimeSplitGroup? {
        splitGroups.first { $0.tabIDs.contains(tabID) }
    }

    /// The selected tab's visible set: its whole group, or just itself.
    var visibleTabIDs: [String] {
        guard let selectedTabID else { return [] }
        if let group = splitGroup(containing: selectedTabID) { return group.tabIDs }
        return [selectedTabID]
    }

    /// All tabs that must stay live: every visible pane — the selected
    /// tab's whole split group (spec §5.2).
    var pinnedTabIDs: Set<String> { Set(visibleTabIDs) }

    /// What the pane canvas actually renders: the visible tab set plus its
    /// weights. Compared before/after mutations to keep onVisibleSetChange
    /// honest.
    private struct VisibleLayout: Equatable {
        var tabIDs: [String]
        var weights: [Double]
    }

    private var visibleLayout: VisibleLayout {
        guard let selectedTabID else { return VisibleLayout(tabIDs: [], weights: []) }
        if let group = splitGroup(containing: selectedTabID) {
            return VisibleLayout(tabIDs: group.tabIDs, weights: group.weights)
        }
        return VisibleLayout(tabIDs: [selectedTabID], weights: [1.0])
    }

    func tabs(in spaceID: String) -> [BrowserTab] {
        tabs.filter { $0.spaceID == spaceID }
    }

    // MARK: - Creation / closing / selection

    @discardableResult
    func newTab(select: Bool = true) -> BrowserTab {
        let spaceID = selectedSpaceID ?? ensureDefaultSpace()
        let tab = BrowserTab(spaceID: spaceID)
        registerCallbacks(on: tab)
        tabs.append(tab)
        if select {
            self.select(tab)
            addressFocusToken += 1
        }
        onStateChange?()
        return tab
    }

    func close(_ tab: BrowserTab) {
        removeFromSplit(tab)   // closing a pane unsplits (spec §5.1)
        // hibernate() (not just detach) tears the webview down AND leaves
        // the captured interactionState in tab.pendingInteractionState —
        // discarded along with `tab` right below today, but kept here
        // (rather than a bare webview teardown) for a future undo-close
        // that would want to reopen this tab with its state intact.
        tab.hibernate()
        mruLive.removeAll { $0 == tab.id }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            let remaining = tabs(in: tab.spaceID)
            if let next = remaining.last {
                select(next)
            } else {
                selectedTabID = nil
                onSelectionChange?(nil)
            }
        }
        onStateChange?()
    }

    func select(tabID: String) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        select(tab)
    }

    func select(_ tab: BrowserTab) {
        guard selectedTabID != tab.id else { return }
        let before = visibleLayout
        selectedTabID = tab.id
        selectedSpaceID = tab.spaceID
        tab.lastActiveAt = Date()
        activateVisibleSet()
        enforcePolicy()
        // A plain switch never suspends media (spec §5.2 suspends only on
        // panes leaving a visible split — see removeFromSplit/dissolveSplit).
        if before != visibleLayout { onVisibleSetChange?() }
        onSelectionChange?(tab)
        onStateChange?()
    }

    func moveTab(fromOffsets: IndexSet, toOffset: Int, in spaceID: String) {
        var inSpace = tabs(in: spaceID)
        inSpace.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let slots = tabs.indices.filter { tabs[$0].spaceID == spaceID }
        for (slot, tab) in zip(slots, inSpace) { tabs[slot] = tab }
        onStateChange?()
    }

    func newSpace(named name: String) {
        let space = SpaceRecord(id: UUID().uuidString, name: name,
                                orderIndex: (spaces.map(\.orderIndex).max() ?? -1) + 1)
        spaces.append(space)
        selectedSpaceID = space.id
        selectedTabID = nil
        onSelectionChange?(nil)
        onStateChange?()
    }

    /// Validating selected-space setter (M2 seam carry-over): the sidebar
    /// switcher and moveTab(_:toSpace:) route through it. Callers reconcile
    /// tab selection themselves.
    func selectSpace(_ spaceID: String) {
        guard spaces.contains(where: { $0.id == spaceID }) else {
            NSLog("Nyx: selectSpace ignored unknown space %@", spaceID)
            return
        }
        guard selectedSpaceID != spaceID else { return }
        selectedSpaceID = spaceID
        onStateChange?()
    }

    /// Moves a tab to another space (spec §5.4). Groups never span spaces,
    /// so the tab leaves its split group first. Moving does not switch the
    /// user's space unless the moved tab was selected (selection follows
    /// its tab, matching select(_:)'s invariant).
    func moveTab(_ tab: BrowserTab, toSpace spaceID: String) {
        guard spaces.contains(where: { $0.id == spaceID }) else {
            NSLog("Nyx: moveTab ignored unknown space %@", spaceID)
            return
        }
        guard tab.spaceID != spaceID else { return }
        removeFromSplit(tab)
        tab.reassign(toSpace: spaceID)
        if selectedTabID == tab.id { selectSpace(spaceID) }
        onStateChange?()
    }

    // MARK: - Split groups (spec §5.1)

    /// Groups `anchor` and `other` (max 4 panes; joining an existing group
    /// appends). No-op with a log if the cap would be exceeded or the tabs
    /// are in different spaces.
    func split(_ anchor: BrowserTab, with other: BrowserTab) {
        guard anchor.id != other.id else { return }
        guard anchor.spaceID == other.spaceID else {
            NSLog("Nyx: split refused — tabs in different spaces")
            return
        }
        guard splitGroup(containing: other.id) == nil else {
            NSLog("Nyx: split refused — tab already in a group")
            return
        }
        let before = visibleLayout
        if var group = splitGroup(containing: anchor.id) {
            guard group.tabIDs.count < 4 else {
                NSLog("Nyx: split cap (4) reached")
                return
            }
            group.tabIDs.append(other.id)
            group.weights = SplitWeights.appending(to: group.weights)
            replaceGroup(group)
        } else {
            splitGroups.append(RuntimeSplitGroup(
                id: UUID().uuidString,
                tabIDs: [anchor.id, other.id],
                weights: SplitWeights.equal(count: 2)))
        }
        finishGroupMutation(before: before)
    }

    /// Removes a tab from its group, redistributing weights; a group left
    /// with one member dissolves. Panes that thereby leave the visible
    /// split get their media suspended (spec §5.2).
    func removeFromSplit(_ tab: BrowserTab) {
        guard var group = splitGroup(containing: tab.id),
              let index = group.tabIDs.firstIndex(of: tab.id) else { return }
        let before = visibleLayout
        group.tabIDs.remove(at: index)
        group.weights = SplitWeights.removing(index: index, from: group.weights)
        if group.tabIDs.count < 2 {
            splitGroups.removeAll { $0.id == group.id }
        } else {
            replaceGroup(group)
        }
        finishGroupMutation(before: before)
    }

    /// Dissolves a whole group; every non-surviving pane (member that is
    /// no longer visible afterwards) gets its media suspended.
    func dissolveSplit(containing tab: BrowserTab) {
        guard let group = splitGroup(containing: tab.id) else { return }
        let before = visibleLayout
        splitGroups.removeAll { $0.id == group.id }
        finishGroupMutation(before: before)
    }

    /// Commits divider weights (once, on drag end — spec §5.1). Input is
    /// sanitized (sum 1.0, each ≥ 0.15) before storing.
    func updateWeights(groupID: String, weights: [Double]) {
        guard let index = splitGroups.firstIndex(where: { $0.id == groupID }) else {
            NSLog("Nyx: updateWeights ignored unknown group %@", groupID)
            return
        }
        let paneCount = splitGroups[index].tabIDs.count
        if weights.count != paneCount
            || !weights.allSatisfy({ $0.isFinite && $0 > 0 }) {
            NSLog("Nyx: updateWeights rejected invalid input (%ld values for %ld panes) — resetting to equal",
                  weights.count, paneCount)
        }
        let sanitized = SplitWeights.sanitized(weights, count: paneCount)
        guard splitGroups[index].weights != sanitized else { return }
        let before = visibleLayout
        splitGroups[index].weights = sanitized
        if before != visibleLayout { onVisibleSetChange?() }
        onStateChange?()
    }

    private func replaceGroup(_ group: RuntimeSplitGroup) {
        guard let index = splitGroups.firstIndex(where: { $0.id == group.id })
        else { return }
        splitGroups[index] = group
    }

    /// Shared tail of the group mutations (split/remove/dissolve):
    /// suspends media on panes that left the visible split — the ONLY
    /// place media suspension happens, never on plain tab switches — then
    /// reconciles webview lifecycle and fires the change callbacks.
    /// `onVisibleSetChange` fires only when the visible layout (tab set or
    /// weights) actually changed; `onStateChange` always fires.
    private func finishGroupMutation(before: VisibleLayout) {
        let after = visibleLayout
        for id in Set(before.tabIDs).subtracting(after.tabIDs) {
            tabs.first { $0.id == id }?.setMediaSuspended(true)
        }
        activateVisibleSet()
        enforcePolicy()
        if before != after { onVisibleSetChange?() }
        onStateChange?()
    }

    /// Attaches webviews for every visible pane, lifts any media
    /// suspension (a pane rejoining the visible set must be able to play
    /// again), and marks each as recently used.
    private func activateVisibleSet() {
        for id in visibleTabIDs {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            activateIfNeeded(tab)
            tab.setMediaSuspended(false)
            touchMRU(id)
        }
    }

    // MARK: - Persistence bridging

    func restore(from snapshot: SessionSnapshot) {
        mruLive = []
        spaces = snapshot.spaces
        tabs = snapshot.tabs.map { record in
            let tab = BrowserTab(record: record)
            registerCallbacks(on: tab)
            return tab
        }
        restoreSplitGroups(from: snapshot)
        if let storedSpaceID = snapshot.selectedSpaceID,
           spaces.contains(where: { $0.id == storedSpaceID }) {
            selectedSpaceID = storedSpaceID
        } else {
            selectedSpaceID = spaces.first?.id
        }
        if tabs.isEmpty {
            newTab(select: true)
        } else if let id = snapshot.selectedTabID,
                  tabs.contains(where: { $0.id == id }) {
            select(tabID: id)
        } else if let spaceID = selectedSpaceID,
                  let first = tabs(in: spaceID).first {
            select(first)
        } else if let first = tabs.first {
            select(first)
        }
    }

    func snapshotForSaving() -> SessionSnapshot {
        var groupRecords: [SplitGroupRecord] = []
        var membership: [String: String] = [:]   // tabID → groupID
        for (index, group) in splitGroups.enumerated() {
            let members = tabs.filter { group.tabIDs.contains($0.id) }
            guard let spaceID = members.first?.spaceID else { continue }
            // Weights are positional, and restore rebuilds membership in
            // sidebar (tab orderIndex) order — so persist the weights
            // permuted into that same order, or a group whose pane order
            // differs from sidebar order would swap weights on relaunch.
            let sidebarOrderedWeights = members.map(\.id).compactMap { id in
                group.tabIDs.firstIndex(of: id).map { group.weights[$0] }
            }
            groupRecords.append(SplitGroupRecord(
                id: group.id, spaceID: spaceID, orderIndex: index,
                weightsJSON: SplitGroupRecord.encodeWeights(sidebarOrderedWeights)))
            for tabID in group.tabIDs { membership[tabID] = group.id }
        }
        var ordered: [TabRecord] = []
        for (index, tab) in tabs.enumerated() {
            var record = tab.record(orderIndex: index)
            record.splitGroupID = membership[tab.id]
            ordered.append(record)
        }
        return SessionSnapshot(spaces: spaces, tabs: ordered,
                               splitGroups: groupRecords,
                               selectedSpaceID: selectedSpaceID,
                               selectedTabID: selectedTabID)
    }

    /// Rebuilds runtime groups from persisted records. Member pane order =
    /// tab orderIndex order; weights are sanitized for the surviving
    /// member count; groups with fewer than 2 surviving same-space members
    /// are dropped (their memberships are thereby nulled — runtime
    /// membership derives from `splitGroups`, and the next snapshot writes
    /// splitGroupID from it).
    private func restoreSplitGroups(from snapshot: SessionSnapshot) {
        splitGroups = snapshot.splitGroups
            .sorted { $0.orderIndex < $1.orderIndex }
            .compactMap { record in
                let members = tabs.filter {
                    $0.spaceID == record.spaceID
                }.map(\.id).filter { id in
                    snapshot.tabs.first { $0.id == id }?.splitGroupID == record.id
                }
                guard members.count >= 2 else { return nil }
                let panes = Array(members.prefix(4))   // hard cap, spec §5.1
                return RuntimeSplitGroup(
                    id: record.id,
                    tabIDs: panes,
                    weights: SplitWeights.sanitized(record.weights,
                                                    count: panes.count))
            }
    }

    // MARK: - Lifecycle internals

    private func registerCallbacks(on tab: BrowserTab) {
        tab.onStateChange = { [weak self, weak tab] in
            self?.onStateChange?()
            if let self, let tab, tab.id == self.selectedTabID {
                self.onSelectionChange?(tab)   // keeps window title fresh
            }
        }
    }

    private func activateIfNeeded(_ tab: BrowserTab) {
        guard tab.webView == nil else { return }
        tab.attach(factory.makeWebView(), uiDelegate: self)
        touchMRU(tab.id)
    }

    private func touchMRU(_ id: String) {
        mruLive.removeAll { $0 == id }
        mruLive.insert(id, at: 0)
    }

    private func enforcePolicy() {
        hibernateVictims(using: policy)
    }

    private func hibernateVictims(using policy: TabLifecyclePolicy) {
        let victims = policy.evictionCandidates(mruLiveTabs: mruLive,
                                                pinned: pinnedTabIDs)
        guard !victims.isEmpty else { return }
        for id in victims {
            let state = tabs.first { $0.id == id }?.hibernate()
            onTabHibernated?(id, state)
            mruLive.removeAll { $0 == id }
        }
        onStateChange?()
    }

    @discardableResult
    private func ensureDefaultSpace() -> String {
        if let id = selectedSpaceID { return id }
        if let first = spaces.first { selectedSpaceID = first.id; return first.id }
        let space = SpaceRecord(id: UUID().uuidString, name: "Space", orderIndex: 0)
        spaces.append(space)
        selectedSpaceID = space.id
        return space.id
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.hibernateVictims(using: TabLifecyclePolicy(warmLimit: 1))
        }
        source.resume()
        memoryPressureSource = source
    }
}

// MARK: - BrowserCommands (chrome + menu route here)

extension TabManager: BrowserCommands {
    func navigate(to input: String) {
        guard let tab = selectedTab else { return }
        activateIfNeeded(tab)
        guard let url = AddressParser.destinationURL(for: input),
              let webView = tab.webView else { return }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { selectedTab?.webView?.goBack() }
    func goForward() { selectedTab?.webView?.goForward() }
    func reload() { selectedTab?.webView?.reload() }
    func stopLoading() { selectedTab?.webView?.stopLoading() }
}

// MARK: - WKUIDelegate (real popup adoption, spec §5.3 — replaces the M1
// same-webview fallback: target=_blank and window.open become new tabs,
// created from the configuration WebKit hands us so window.opener works)

extension TabManager: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = factory.makeWebView(adopting: configuration)
        let sourceTab = tabs.first { $0.webView === webView }
        let spaceID = sourceTab?.spaceID ?? selectedSpaceID ?? ensureDefaultSpace()
        let tab = BrowserTab(spaceID: spaceID)
        registerCallbacks(on: tab)
        tab.attach(popup, uiDelegate: self)
        tabs.append(tab)
        select(tab)
        onStateChange?()
        return popup
    }
}
