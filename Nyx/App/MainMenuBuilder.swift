import AppKit

@MainActor
enum MainMenuBuilder {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nyx",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nyx",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Nyx"))

        // File
        let fileMenu = NSMenu(title: "File")
        let newTab = NSMenuItem(title: "New Tab",
                                action: #selector(AppDelegate.newTab(_:)),
                                keyEquivalent: "t")
        newTab.target = delegate
        fileMenu.addItem(newTab)
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        // Edit (standard responder-chain selectors — required for
        // copy/paste in the address field)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu, title: "Edit"))

        // View
        let viewMenu = NSMenu(title: "View")
        let focusAddress = NSMenuItem(title: "Open Location…",
                                      action: #selector(AppDelegate.focusAddressField(_:)),
                                      keyEquivalent: "l")
        focusAddress.target = delegate
        viewMenu.addItem(focusAddress)
        let reload = NSMenuItem(title: "Reload Page",
                                action: #selector(AppDelegate.reloadPage(_:)),
                                keyEquivalent: "r")
        reload.target = delegate
        viewMenu.addItem(reload)
        viewMenu.addItem(.separator())
        let toggleSidebar = NSMenuItem(title: "Toggle Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(toggleSidebar)
        main.addItem(submenu(viewMenu, title: "View"))

        // History
        let historyMenu = NSMenu(title: "History")
        let back = NSMenuItem(title: "Back",
                              action: #selector(AppDelegate.goBack(_:)),
                              keyEquivalent: "[")
        back.target = delegate
        historyMenu.addItem(back)
        let forward = NSMenuItem(title: "Forward",
                                 action: #selector(AppDelegate.goForward(_:)),
                                 keyEquivalent: "]")
        forward.target = delegate
        historyMenu.addItem(forward)
        main.addItem(submenu(historyMenu, title: "History"))

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
