import SwiftUI
import NyxCore

/// Shared layout metrics for the launcher's results area. The area keeps
/// a CONSTANT height (`LauncherViewModel.resultLimit` rows exactly fill
/// it) instead of growing per keystroke: `LauncherPanelController` sizes
/// the panel ONCE at show from `fittingSize`, and letting Auto Layout
/// re-derive the window size afterwards would grow the panel UPWARD from
/// its fixed bottom-left origin — the wrong direction for a
/// Spotlight-style panel whose top edge should stay put. Total content
/// (field ≈ 49pt + divider + 350pt) stays under the 420pt panel cap.
private enum LauncherMetrics {
    static let rowHeight: CGFloat = 32
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    /// resultLimit (10) rows + 9 gaps + top/bottom padding:
    /// 10×32 + 9×2 + 2×6 = 350.
    static let resultsAreaHeight: CGFloat = 350
}

/// The ⌘K launcher's content (spec §5.5): one input field over the ranked
/// result list, hosted inside `LauncherPanelController`'s glass panel.
///
/// This view renders state and takes mouse input only — ↑/↓/Enter/⌘Enter
/// are handled by the coordinator through the panel controller's
/// `onKeyDown` NSEvent-monitor hook, NOT here: SwiftUI `onKeyPress` on
/// the field was tried first and never received Return (the NSTextField
/// field editor consumes arrows and Return before SwiftUI's KeyPress
/// dispatch sees them — verified end to end; see the task report). Esc
/// is not handled anywhere in this view either: it travels the responder
/// chain to `LauncherPanel.cancelOperation(_:)`, the panel's single Esc
/// close path from Task 4 (also verified end to end).
struct LauncherView: View {
    @Bindable var viewModel: LauncherViewModel
    /// The coordinator's execution hook — receives the resolved action;
    /// the coordinator dismisses the panel and performs it.
    let onExecute: (LauncherAction) -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search or enter address", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused($fieldFocused)
                .accessibilityIdentifier("nyx.launcherField")
                .onAppear { fieldFocused = true }

            Divider().opacity(0.1)

            resultsArea
                .frame(maxWidth: .infinity)
                .frame(height: LauncherMetrics.resultsAreaHeight)
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.results.isEmpty {
            // Reachable only before typing on a fresh profile (no other
            // tabs, no history): any non-empty query always yields at
            // least the trailing searchWeb row.
            Text("Start typing to search tabs, history, and commands")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: LauncherMetrics.rowSpacing) {
                // Identity by position: results are recomputed wholesale
                // on every keystroke and rows carry no internal state, so
                // offset identity is stable enough and avoids inventing a
                // synthetic key for LauncherResult.
                ForEach(Array(viewModel.results.enumerated()), id: \.offset) { index, result in
                    LauncherRowView(result: result,
                                    isSelected: index == viewModel.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            executeSelected(inNewTab: false)
                        }
                        // One a11y element per row (icon + texts combined)
                        // — without this the container identifier surfaces
                        // on every un-combined leaf, the multi-match
                        // gotcha SidebarView's TabRow documents.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("nyx.launcherRow")
                }
                Spacer(minLength: 0)
            }
            .padding(LauncherMetrics.listPadding)
        }
    }

    private func executeSelected(inNewTab: Bool) {
        guard let action = viewModel.executeSelected(inNewTab: inNewTab) else { return }
        onExecute(action)
    }
}

/// One result row: SF Symbol for the result kind, title, trailing detail,
/// white 8% rounded highlight when selected (same value the sidebar's
/// selected cluster rows use).
private struct LauncherRowView: View {
    let result: LauncherResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: LauncherMetrics.rowHeight)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var symbolName: String {
        switch result {
        case .switchToTab: return "arrow.right.square"
        case .openURL: return "globe"
        case .searchWeb: return "magnifyingglass"
        case .history: return "clock"
        case .command: return "command"
        }
    }

    private var title: String {
        switch result {
        case .switchToTab(let tab):
            if !tab.title.isEmpty { return tab.title }
            return URL(string: tab.url)?.host ?? "Untitled Tab"
        case .openURL(let url):
            return url.absoluteString
        case .searchWeb(let term):
            return "Search for \u{201C}\(term)\u{201D}"
        case .history(let entry):
            return entry.title.isEmpty ? entry.url : entry.title
        case .command(let command):
            return command.rawValue
        }
    }

    private var detail: String {
        switch result {
        case .switchToTab: return "Switch to Tab"
        case .openURL: return "Open"
        case .searchWeb: return "DuckDuckGo"
        case .history(let entry): return URL(string: entry.url)?.host ?? entry.url
        case .command: return "Command"
        }
    }
}
