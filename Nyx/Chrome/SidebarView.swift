import SwiftUI

/// M2 sidebar: space switcher + address field + drag-reorderable tab rows
/// for the selected space + new-tab button. Night-glass polish is M8 —
/// styling stays on DesignTokens-level restraint.
struct SidebarView: View {
    @Bindable var manager: TabManager

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    /// A row the sidebar list renders: either a plain tab or a whole split
    /// cluster (spec §5.4), collapsed to one entry per group so a grouped
    /// tab never also appears as a standalone row.
    private struct SidebarItem: Identifiable {
        enum Kind {
            case tab(BrowserTab)
            case cluster(groupID: String, tabs: [BrowserTab])
        }
        let id: String
        let kind: Kind
    }

    /// Walks the space's tabs in order, folding each split group into a
    /// single cluster item the first time one of its members is seen.
    private var sidebarItems: [SidebarItem] {
        guard let spaceID = manager.selectedSpaceID else { return [] }
        var seenGroups = Set<String>()
        var items: [SidebarItem] = []
        for tab in manager.tabs(in: spaceID) {
            if let group = manager.splitGroup(containing: tab.id) {
                guard !seenGroups.contains(group.id) else { continue }
                seenGroups.insert(group.id)
                let members = group.tabIDs.compactMap { id in
                    manager.tabs.first { $0.id == id }
                }
                items.append(SidebarItem(id: group.id,
                                         kind: .cluster(groupID: group.id, tabs: members)))
            } else {
                items.append(SidebarItem(id: tab.id, kind: .tab(tab)))
            }
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer().frame(height: 30)

            spaceSwitcher

            navigationControls

            addressField

            if manager.selectedTab?.isLoading == true {
                ProgressView(value: manager.selectedTab?.progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
            }

            tabList

            newTabButton
        }
        .padding(12)
        .onChange(of: manager.selectedTab?.urlString ?? "") { _, newValue in
            if !addressFocused { addressText = newValue }
        }
        .onChange(of: manager.selectedTabID) { _, _ in
            addressText = manager.selectedTab?.urlString ?? ""
        }
        .onChange(of: manager.addressFocusToken) { _, _ in
            addressFocused = true
        }
    }

    private var spaceSwitcher: some View {
        Menu {
            ForEach(manager.spaces) { space in
                Button {
                    guard space.id != manager.selectedSpaceID else { return }
                    manager.selectSpace(space.id)
                    if let first = manager.tabs(in: space.id).first {
                        manager.select(first)
                    } else {
                        // Empty space: newTab() both creates and selects,
                        // so the user is never stranded with a nil
                        // selection (Task 9 review — reachable via this
                        // switcher's switch-to-empty-space path).
                        manager.newTab()
                    }
                } label: {
                    if space.id == manager.selectedSpaceID {
                        Label(space.name, systemImage: "checkmark")
                    } else {
                        Text(space.name)
                    }
                }
            }
            Divider()
            Button("New Space") {
                manager.newSpace(named: "Space \(manager.spaces.count + 1)")
                manager.newTab()
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedSpaceName)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("nyx.spaceSwitcher")
    }

    private var selectedSpaceName: String {
        manager.spaces.first { $0.id == manager.selectedSpaceID }?.name ?? "Space"
    }

    private var navigationControls: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", enabled: manager.selectedTab?.canGoBack ?? false) {
                manager.goBack()
            }
            navButton("chevron.right", enabled: manager.selectedTab?.canGoForward ?? false) {
                manager.goForward()
            }
            if manager.selectedTab?.isLoading == true {
                navButton("xmark", enabled: true) { manager.stopLoading() }
            } else {
                navButton("arrow.clockwise", enabled: manager.selectedTab != nil) {
                    manager.reload()
                }
            }
        }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $addressText)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(addressFocused ? 0.18 : 0.07))
            )
            .focused($addressFocused)
            .onSubmit {
                manager.navigate(to: addressText)
                addressFocused = false
            }
            .accessibilityIdentifier("nyx.addressField")
    }

    private var tabList: some View {
        List(selection: Binding(
            get: { manager.selectedTabID },
            set: { id in if let id { manager.select(tabID: id) } }
        )) {
            ForEach(sidebarItems) { item in
                switch item.kind {
                case .tab(let tab):
                    TabRow(tab: tab) { manager.close(tab) }
                        .tag(tab.id)
                        .accessibilityIdentifier("nyx.tabRow")
                        .contextMenu { tabContextMenu(for: tab) }
                case .cluster(_, let tabs):
                    splitCluster(tabs: tabs)
                        // Clusters collapse N tabs into one row of the
                        // sidebar's flat order, so a raw index-for-index
                        // reorder (movePlainTabs below) can't treat them
                        // as a movable unit — see that function's comment.
                        .moveDisabled(true)
                }
            }
            .onMove(perform: movePlainTabs)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    /// Renders one split group (spec §5.4): an inset rounded box with a
    /// hairline border, members indented inside it. Members aren't List
    /// rows of their own (the cluster is the single ForEach row), so
    /// selection and taps are wired manually rather than via `.tag`.
    private func splitCluster(tabs: [BrowserTab]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs) { tab in
                TabRow(tab: tab, isSelected: tab.id == manager.selectedTabID) {
                    manager.close(tab)
                }
                .padding(.leading, 10)
                .accessibilityIdentifier("nyx.tabRow")
                .contentShape(Rectangle())
                .onTapGesture { manager.select(tab) }
                .contextMenu { tabContextMenu(for: tab) }
            }
        }
        .padding(6)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.07))
        )
        .accessibilityIdentifier("nyx.splitCluster")
    }

    /// Shared context menu for both plain tab rows and cluster member
    /// rows (spec §5.4 carry-over). "Split with Selected Tab" is hidden
    /// when there's no other selected tab, `tab` is already in a group
    /// (TabManager.split refuses a grouped `other`), or the selected
    /// tab's own group is already at the 4-pane cap (TabManager.split
    /// refuses growing a full group) — mirrors NyxWindowCoordinator's
    /// canSplit gate.
    @ViewBuilder
    private func tabContextMenu(for tab: BrowserTab) -> some View {
        if let selected = manager.selectedTab, selected.id != tab.id,
           manager.splitGroup(containing: tab.id) == nil,
           (manager.splitGroup(containing: selected.id)?.tabIDs.count ?? 1) < 4 {
            Button("Split with Selected Tab") { manager.split(selected, with: tab) }
        }
        if manager.splitGroup(containing: tab.id) != nil {
            Button("Remove from Split") { manager.removeFromSplit(tab) }
            Button("Break Up Split") { manager.dissolveSplit(containing: tab) }
        }
        if manager.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(manager.spaces.filter { $0.id != tab.spaceID }) { space in
                    Button(space.name) { manager.moveTab(tab, toSpace: space.id) }
                }
            }
        }
        Button("Close Tab") { manager.close(tab) }
    }

    /// Translates a reorder gesture on the collapsed `sidebarItems` list
    /// back onto the space's flat tab order. Clusters carry
    /// `.moveDisabled(true)` above, so they can never be a drag source —
    /// `offsets` only ever names `.tab` rows — but `destination` is still
    /// an index into the collapsed list, and a cluster there stands for
    /// several flat-array slots. `flatStart[i]` is the flat-array index
    /// the i-th sidebar item starts at (a cluster contributes its member
    /// count), so translating both offsets and destination through it
    /// keeps a plain tab's drop position correct even right before/after
    /// a cluster, without ever needing to reorder the cluster itself.
    private func movePlainTabs(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let spaceID = manager.selectedSpaceID else { return }
        let items = sidebarItems
        func flatSize(_ item: SidebarItem) -> Int {
            switch item.kind {
            case .tab: return 1
            case .cluster(_, let tabs): return tabs.count
            }
        }
        var flatStart: [Int] = [0]
        for item in items { flatStart.append(flatStart[flatStart.count - 1] + flatSize(item)) }

        let flatOffsets = IndexSet(offsets.compactMap { index -> Int? in
            guard case .tab = items[index].kind else { return nil }
            return flatStart[index]
        })
        guard !flatOffsets.isEmpty else { return }
        manager.moveTab(fromOffsets: flatOffsets, toOffset: flatStart[destination], in: spaceID)
    }

    private var newTabButton: some View {
        Button {
            manager.newTab()
        } label: {
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("nyx.newTabButton")
    }

    private func navButton(_ symbol: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// One sidebar tab row: globe placeholder (real favicons are a later
/// milestone), title or host, close button on hover.
private struct TabRow: View {
    let tab: BrowserTab
    /// Manual highlight for cluster member rows, which aren't List rows
    /// of their own and so get none of List's selection styling for
    /// free (spec §5.4 — see `SidebarView.splitCluster`). Plain rows
    /// leave this false and rely on List's own selection highlight.
    var isSelected: Bool = false
    let onClose: () -> Void

    @State private var hovering = false

    private var displayTitle: String {
        if !tab.title.isEmpty { return tab.title }
        if let host = URL(string: tab.urlString)?.host { return host }
        return "New Tab"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                // Decorative — without this, SwiftUI/AppKit's List
                // bridging surfaces the container-level accessibility
                // identifier ("nyx.tabRow") on EVERY un-combined leaf in
                // the row (this icon AND the title text), so UI tests
                // querying by identifier see two matches per tab instead
                // of one. Hiding the icon leaves the title as the sole
                // identified element per row.
                .accessibilityHidden(true)
            Text(displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
