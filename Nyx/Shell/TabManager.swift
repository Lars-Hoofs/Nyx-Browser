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
    private(set) var spaces: [SpaceRecord] = []
    private(set) var tabs: [BrowserTab] = []
    var selectedSpaceID: String?
    private(set) var selectedTabID: String?
    var addressFocusToken = 0

    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onSelectionChange: ((BrowserTab?) -> Void)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var policy: TabLifecyclePolicy
    /// Most-recently-used first; only ids of tabs holding live webviews.
    @ObservationIgnored private var mruLive: [String] = []
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(factory: WebViewFactory = .shared,
         policy: TabLifecyclePolicy = TabLifecyclePolicy()) {
        self.factory = factory
        self.policy = policy
        super.init()
        installMemoryPressureHandler()
    }

    var selectedTab: BrowserTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
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
        selectedTabID = tab.id
        selectedSpaceID = tab.spaceID
        tab.lastActiveAt = Date()
        activateIfNeeded(tab)
        touchMRU(tab.id)
        enforcePolicy()
        onSelectionChange?(tab)
        onStateChange?()
    }

    func moveTab(fromOffsets: IndexSet, toOffset: Int, in spaceID: String) {
        var inSpace = tabs(in: spaceID)
        inSpace.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tabs.removeAll { $0.spaceID == spaceID }
        tabs.append(contentsOf: inSpace)
        onStateChange?()
    }

    func newSpace(named name: String) {
        let space = SpaceRecord(id: UUID().uuidString, name: name,
                                orderIndex: (spaces.map(\.orderIndex).max() ?? -1) + 1)
        spaces.append(space)
        selectedSpaceID = space.id
        onStateChange?()
    }

    // MARK: - Persistence bridging

    func restore(from snapshot: SessionSnapshot) {
        spaces = snapshot.spaces
        tabs = snapshot.tabs.map { record in
            let tab = BrowserTab(record: record)
            registerCallbacks(on: tab)
            return tab
        }
        selectedSpaceID = snapshot.selectedSpaceID ?? spaces.first?.id
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
        var ordered: [TabRecord] = []
        for (index, tab) in tabs.enumerated() {
            ordered.append(tab.record(orderIndex: index))
        }
        return SessionSnapshot(spaces: spaces, tabs: ordered,
                               selectedSpaceID: selectedSpaceID,
                               selectedTabID: selectedTabID)
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
    }

    private func touchMRU(_ id: String) {
        mruLive.removeAll { $0 == id }
        mruLive.insert(id, at: 0)
    }

    private func enforcePolicy() {
        let victims = policy.evictionCandidates(mruLiveTabs: mruLive,
                                                selected: selectedTabID)
        for id in victims {
            tabs.first { $0.id == id }?.hibernate()
            mruLive.removeAll { $0 == id }
        }
        if !victims.isEmpty { onStateChange?() }
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
            let squeezed = TabLifecyclePolicy(warmLimit: 1)
            let victims = squeezed.evictionCandidates(
                mruLiveTabs: self.mruLive, selected: self.selectedTabID)
            for id in victims {
                self.tabs.first { $0.id == id }?.hibernate()
                self.mruLive.removeAll { $0 == id }
            }
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
        let popup = WKWebView(frame: .zero, configuration: configuration)
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
