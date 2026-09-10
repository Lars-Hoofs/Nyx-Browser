import AppKit
import SwiftUI
import NyxCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NyxWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let sidebar = NSHostingController(
            rootView: Text("Nyx")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        let content = NSViewController()
        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = DesignTokens.baseSurface.cgColor
        content.view = contentView

        let split = NyxSplitViewController(sidebar: sidebar, content: content)
        let controller = NyxWindowController(contentViewController: split)
        controller.showWindow(nil)
        windowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
