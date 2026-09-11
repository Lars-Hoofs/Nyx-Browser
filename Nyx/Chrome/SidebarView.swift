import SwiftUI

/// M1 sidebar: nav controls + address field. Tabs/spaces arrive in M2,
/// the ⌘K launcher in M4 (spec §5.4, §5.5).
struct SidebarView: View {
    @Bindable var model: BrowserViewModel
    let commands: BrowserCommands

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clear the floating traffic lights (hidden titlebar).
            Spacer().frame(height: 30)

            HStack(spacing: 10) {
                navButton("chevron.left", enabled: model.canGoBack) { commands.goBack() }
                navButton("chevron.right", enabled: model.canGoForward) { commands.goForward() }
                if model.isLoading {
                    navButton("xmark", enabled: true) { commands.stopLoading() }
                } else {
                    navButton("arrow.clockwise", enabled: true) { commands.reload() }
                }
            }

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
                    commands.navigate(to: addressText)
                    addressFocused = false
                }
                .accessibilityIdentifier("nyx.addressField")

            if model.isLoading {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .onChange(of: model.urlString) { _, newValue in
            if !addressFocused { addressText = newValue }
        }
        .onChange(of: model.addressFocusToken) { _, _ in
            addressFocused = true
        }
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
