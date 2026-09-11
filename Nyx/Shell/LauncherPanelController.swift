import AppKit
import SwiftUI

/// Backing NSPanel for the ⌘K launcher (spec §5.5). Must be a *key-able*
/// borderless panel: AppKit's default borderless window/panel refuses key
/// status, which would leave `LauncherView`'s text field unable to ever
/// receive keystrokes. `cancelOperation(_:)` is the standard AppKit path
/// Esc travels down the responder chain to when nothing else claims it —
/// used here instead of an extra local keyDown event monitor, since the
/// panel already sits in the responder chain the moment it's key.
private final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Borderless, key-able floating panel that hosts the launcher (spec
/// §5.5). Owns the panel's whole lifecycle: chrome (glass material,
/// rounded corners, hairline border per §8), positioning, and every way
/// it can close (Esc, resign-key/click-outside, explicit hide/toggle).
///
/// M4 Task 4 ships the shell only — `LauncherView` is a static field +
/// placeholder list, and nothing calls `toggle(over:)` yet (Task 6 wires
/// ⌘K). `contentProvider` matches the brief's interface literally: no
/// generics were needed since `LauncherView` is already a concrete type,
/// so there was nothing to simplify away to `init(rootView:)`.
@MainActor
final class LauncherPanelController: NSObject {
    static let panelWidth: CGFloat = 640
    static let maxPanelHeight: CGFloat = 420

    private let contentProvider: () -> LauncherView
    private var panel: LauncherPanel?
    private var hostingView: NSHostingView<LauncherView>?
    /// Reentrancy guard: `panel.orderOut(nil)` on a key panel makes AppKit
    /// resign key first, which synchronously calls back into
    /// `windowDidResignKey` → `closePanel()` before the outer call
    /// returns. Without this flag that inner call would see
    /// `panel.isVisible` still true (order-out hasn't completed yet), run
    /// the whole body again, and fire `onDismiss` twice for one
    /// user-visible close.
    private var isClosing = false

    /// Fires every time the panel goes from visible to hidden, regardless
    /// of cause (Esc, resign-key/click-outside, or an explicit
    /// `hide()`/`toggle(over:)` call) — Task 5's coordinator can use this
    /// one hook to reset launcher state instead of needing a case per
    /// cause.
    var onDismiss: (() -> Void)?

    init(contentProvider: @escaping () -> LauncherView) {
        self.contentProvider = contentProvider
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the panel centered over the top third of `window` (spec
    /// §5.5's Spotlight-like placement), or hides it if already visible.
    /// `window` is optional so a caller with no key window yet still gets
    /// a sane placement, falling back to the main screen's visible frame.
    func toggle(over window: NSWindow?) {
        if isVisible {
            hide()
        } else {
            show(over: window)
        }
    }

    func hide() {
        closePanel()
    }

    private func show(over window: NSWindow?) {
        let panel = ensurePanel()
        // Fresh content every open (Spotlight-style reset): Task 5's
        // provider closure is expected to hand back a view bound to a
        // freshly-reset LauncherViewModel each time, not one that
        // remembers the previous query.
        hostingView?.rootView = contentProvider()
        panel.setFrame(frame(over: window), display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        guard !isClosing, let panel, panel.isVisible else { return }
        isClosing = true
        defer { isClosing = false }
        panel.orderOut(nil)
        onDismiss?()
    }

    private func frame(over window: NSWindow?) -> NSRect {
        let windowFrame = window?.frame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // NSHostingView's width is pinned to the chrome view (constant
        // panelWidth — only height ever changes), so `fittingSize` here
        // reports the SwiftUI content's ideal height at that fixed width.
        let contentHeight = hostingView?.fittingSize.height ?? Self.maxPanelHeight
        return Self.panelFrame(overWindowFrame: windowFrame, rawContentHeight: contentHeight)
    }

    /// Pure geometry, unit-tested directly: horizontally centered over
    /// `windowFrame`; vertically, the panel's TOP edge sits on the line
    /// one third of the way down from the window's top edge ("centered at
    /// the top third" — Spotlight-style, not vertically centered in the
    /// window). Height is content-driven but never exceeds
    /// `maxPanelHeight`.
    static func panelFrame(overWindowFrame windowFrame: CGRect,
                           rawContentHeight: CGFloat) -> CGRect {
        let height = min(rawContentHeight, maxPanelHeight)
        let x = windowFrame.midX - panelWidth / 2
        let topThird = windowFrame.maxY - windowFrame.height / 3
        let y = topThird - height
        return CGRect(x: x, y: y, width: panelWidth, height: height)
    }

    private func ensurePanel() -> LauncherPanel {
        if let panel { return panel }

        let hostingView = NSHostingView(rootView: contentProvider())
        self.hostingView = hostingView

        let chrome = NSVisualEffectView()
        chrome.material = .hudWindow
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 16
        chrome.layer?.cornerCurve = .continuous
        chrome.layer?.masksToBounds = true
        // Hairline border, white 6–8% opacity (spec §8's glass-panel rule).
        chrome.layer?.borderWidth = 1
        chrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        // A bare-ish NSVisualEffectView isn't guaranteed to publish itself
        // to the a11y tree as a distinct element (same gotcha
        // PaneViewController documents for a plain NSView) — declare it
        // explicitly so "nyx.launcher" is actually queryable by UI tests.
        chrome.setAccessibilityElement(true)
        chrome.setAccessibilityRole(.group)
        chrome.setAccessibilityIdentifier("nyx.launcher")

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: chrome.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: chrome.bottomAnchor)
        ])

        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.maxPanelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // AppKit's automatic hidesOnDeactivate would order the panel out
        // WITHOUT going through closePanel(), so onDismiss would silently
        // never fire when the app deactivates. windowDidResignKey below
        // already covers that case too (deactivating the app resigns the
        // key window with no new key window in this app), so this is
        // turned off to keep exactly one close path.
        panel.hidesOnDeactivate = false
        // Not owned by an NSWindowController; we only ever call
        // orderOut(nil), never close(), but this is the standard
        // defensive setting for a manually-retained NSWindow/NSPanel.
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.contentView = chrome

        self.panel = panel
        return panel
    }
}

extension LauncherPanelController: NSWindowDelegate {
    /// Covers both brief-mandated close paths that aren't Esc: clicking
    /// outside (the panel resigns key to whatever was clicked) and the
    /// app deactivating entirely (the key window resigns with no new key
    /// window in this app).
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }
}
