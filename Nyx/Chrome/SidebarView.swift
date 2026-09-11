import SwiftUI

/// M2 sidebar: space switcher + address field + drag-reorderable tab rows
/// for the selected space + new-tab button. Night-glass polish is M8 —
/// styling stays on DesignTokens-level restraint.
struct SidebarView: View {
    @Bindable var manager: TabManager

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var selectedSpaceTabs: [BrowserTab] {
        guard let spaceID = manager.selectedSpaceID else { return [] }
        return manager.tabs(in: spaceID)
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
            ForEach(selectedSpaceTabs) { tab in
                TabRow(tab: tab) { manager.close(tab) }
                    .tag(tab.id)
                    .accessibilityIdentifier("nyx.tabRow")
            }
            .onMove { offsets, destination in
                if let spaceID = manager.selectedSpaceID {
                    manager.moveTab(fromOffsets: offsets, toOffset: destination,
                                    in: spaceID)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
