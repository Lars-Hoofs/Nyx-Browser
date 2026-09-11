import AppKit
import WebKit

/// The split canvas (spec §5.1): an NSSplitView of 1–4 side-by-side
/// PaneViewControllers, one per visible tab. Weights arrive sanitized
/// (sum 1.0, each ≥ 0.15) and are applied as divider positions; user
/// divider drags are debounced and committed back as RAW fractions —
/// TabManager sanitizes. Reuses pane controllers by position so rapid
/// transient re-layouts (e.g. closing a visible grouped tab) never
/// leak panes or webviews.
@MainActor
final class PaneCanvasController: NSViewController, NSSplitViewDelegate {
    var onPaneClicked: ((String) -> Void)?          // tabID; coordinator selects
    var onWeightsCommitted: ((String, [Double]) -> Void)? // groupID, raw fractions

    private let splitView = NSSplitView()
    private var panes: [PaneViewController] = []
    private var paneTabIDs: [String] = []
    private var currentGroupID: String?
    private var suppressCommit = false
    private var commitTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    /// Weights that arrived while the split view had zero width; applied
    /// in viewDidLayout once real geometry exists.
    private var pendingWeights: [Double]?
    /// Bumped on every layout() entry; a flushed drag commit may re-enter
    /// layout() via the coordinator, making the interrupted call stale.
    private var layoutGeneration = 0

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.setAccessibilityIdentifier("nyx.paneCanvas")
        view = splitView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            self?.routeClick(event)
            return event // never swallow — panes still need the click
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeMouseMonitor()
    }

    deinit {
        // Backstop for teardown paths that skip viewWillDisappear.
        // deinit may read stored properties of a @MainActor class;
        // NSEvent.removeMonitor is not main-actor-isolated.
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// Rebuilds panes for the visible set. tabs.count 1...4; groupID nil
    /// for a single pane. Reuses existing pane controllers by position.
    func layout(tabs: [(id: String, webView: WKWebView?)],
                weights: [Double], groupID: String?,
                focusedTabID: String?) {
        loadViewIfNeeded()
        layoutGeneration &+= 1
        let generation = layoutGeneration
        var tabs = tabs
        if tabs.count > 4 {
            NSLog("Nyx: layout clamped %ld tabs to the 4-pane maximum", tabs.count)
            tabs = Array(tabs.prefix(4))
        }
        // An in-flight debounced drag commit: flush it when this re-layout
        // stays within the same group and pane count (e.g. a focus click —
        // otherwise the drag would be lost and dividers snapped back to
        // stale weights); cancel it only when the group or pane count
        // actually changed, making its fractions meaningless.
        if commitTask != nil {
            commitTask?.cancel()
            commitTask = nil
            if let groupID, groupID == currentGroupID, tabs.count == panes.count {
                commitWeights(groupID: groupID)
                // The commit may synchronously re-enter layout() via the
                // coordinator; that nested call is newer — abandon this one.
                guard layoutGeneration == generation else { return }
            }
        }
        currentGroupID = groupID
        paneTabIDs = tabs.map(\.id)
        let previousSuppress = suppressCommit
        suppressCommit = true
        defer { suppressCommit = previousSuppress }

        // Shrink first, detaching webviews explicitly, so a webview that
        // moves to a surviving pane is never yanked out by a dying one.
        while panes.count > tabs.count {
            let pane = panes.removeLast()
            pane.present(nil)
            splitView.removeArrangedSubview(pane.view)
            pane.view.removeFromSuperview()
            pane.removeFromParent()
        }
        while panes.count < tabs.count {
            let pane = PaneViewController()
            panes.append(pane)
            addChild(pane)
            splitView.addArrangedSubview(pane.view)
            pane.view.setAccessibilityIdentifier("nyx.pane")
        }
        for (index, entry) in tabs.enumerated() {
            panes[index].present(entry.webView)
            // Accent focus ring (spec §5.1) — only meaningful with 2+ panes.
            let focused = entry.id == focusedTabID && tabs.count > 1
            panes[index].view.layer?.borderWidth = focused ? 2 : 0
            panes[index].view.layer?.borderColor = DesignTokens.silverDeep.cgColor
        }
        applyWeights(weights)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let weights = pendingWeights, splitView.bounds.width > 0 else { return }
        // Take the pending weights out first: applyWeights →
        // layoutSubtreeIfNeeded can re-enter viewDidLayout, and the
        // nested pass must not double-apply them.
        pendingWeights = nil
        let previousSuppress = suppressCommit
        suppressCommit = true
        defer { suppressCommit = previousSuppress }
        applyWeights(weights)
    }

    private func applyWeights(_ weights: [Double]) {
        guard panes.count > 1, weights.count == panes.count else {
            pendingWeights = nil
            return
        }
        splitView.layoutSubtreeIfNeeded()
        let total = splitView.bounds.width
        guard total > 0 else {
            // No geometry yet (first layout before the window sizes us) —
            // divider positions would be meaningless. Retry in viewDidLayout.
            pendingWeights = weights
            return
        }
        pendingWeights = nil
        var offset: CGFloat = 0
        for (index, weight) in weights.dropLast().enumerated() {
            offset += total * CGFloat(weight)
            splitView.setPosition(offset, ofDividerAt: index)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !suppressCommit, let groupID = currentGroupID, panes.count > 1 else { return }
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.commitWeights(groupID: groupID)
        }
    }

    // Per-divider constraints relative to the *adjacent* panes, so the
    // ≥ 0.15 minimum holds for middle panes of 3–4 way splits too.
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let arranged = splitView.arrangedSubviews
        guard arranged.indices.contains(dividerIndex) else { return proposedMinimumPosition }
        let minPane = splitView.bounds.width * 0.15
        return max(proposedMinimumPosition, arranged[dividerIndex].frame.minX + minPane)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let arranged = splitView.arrangedSubviews
        guard arranged.indices.contains(dividerIndex + 1) else { return proposedMaximumPosition }
        let minPane = splitView.bounds.width * 0.15
        return min(proposedMaximumPosition, arranged[dividerIndex + 1].frame.maxX - minPane)
    }

    private func commitWeights(groupID: String) {
        guard groupID == currentGroupID else { return } // stale after re-layout
        let total = splitView.bounds.width
        guard total > 0 else { return }
        let fractions = panes.map { Double($0.view.frame.width / total) }
        onWeightsCommitted?(groupID, fractions)
    }

    private func routeClick(_ event: NSEvent) {
        guard event.window === view.window, panes.count > 1 else { return }
        // view IS the split view, so window→view lands directly in the
        // coordinate space the pane frames live in.
        let point = splitView.convert(event.locationInWindow, from: nil)
        guard splitView.bounds.contains(point) else { return }
        for (index, pane) in panes.enumerated()
        where pane.view.frame.contains(point) {
            onPaneClicked?(paneTabIDs[index])
            return
        }
    }
}
