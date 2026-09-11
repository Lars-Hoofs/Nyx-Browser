import SwiftUI

/// The ⌘K launcher's content (spec §5.5): one input field over a results
/// list, hosted inside `LauncherPanelController`'s glass panel.
///
/// M4 Task 4 ships a STATIC shell only — a field with a placeholder and an
/// empty list area, no search, no keyboard navigation, nothing wired to
/// `TabManager`/`HistoryStore`. Task 5 replaces the body with a real
/// `LauncherViewModel`-backed result list (rows carry a11y id
/// "nyx.launcherRow" per the M4 constraints doc); this file's shape
/// (field on top, list area below, same paddings) is deliberately kept
/// close to what Task 5 will need so the swap is additive, not a rewrite.
struct LauncherView: View {
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search or enter address", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused($fieldFocused)
                .accessibilityIdentifier("nyx.launcherField")
                .onAppear { fieldFocused = true }

            Divider().opacity(0.1)

            // Placeholder for Task 5's ranked result rows. Fixed minHeight
            // (rather than a Spacer-filled layout) keeps this view's
            // intrinsic size finite and stable, which is what
            // LauncherPanelController's content-driven sizing measures.
            Text("Start typing to search tabs, history, and commands")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
