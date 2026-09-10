import AppKit

/// The Nyx browser window: hidden titlebar, full-size content,
/// traffic lights floating over the sidebar (spec §8).
final class NyxWindowController: NSWindowController {
    convenience init(contentViewController: NSViewController) {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DesignTokens.baseSurface
        window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        self.init(window: window)
        window.title = "Nyx"
    }
}
