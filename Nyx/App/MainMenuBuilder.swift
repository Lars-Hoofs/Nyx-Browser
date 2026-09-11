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
        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nyx",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
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
        let closeTab = NSMenuItem(title: "Close Tab",
                                  action: #selector(AppDelegate.closeTab(_:)),
                                  keyEquivalent: "w")
        closeTab.target = delegate
        fileMenu.addItem(closeTab)
        let closeWindow = NSMenuItem(title: "Close Window",
                                     action: #selector(NSWindow.performClose(_:)),
                                     keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)
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
        viewMenu.addItem(.separator())
        let nextTab = NSMenuItem(title: "Show Next Tab",
                                 action: #selector(AppDelegate.selectNextTab(_:)),
                                 keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = delegate
        viewMenu.addItem(nextTab)
        let previousTab = NSMenuItem(title: "Show Previous Tab",
                                     action: #selector(AppDelegate.selectPreviousTab(_:)),
                                     keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        previousTab.target = delegate
        viewMenu.addItem(previousTab)
        viewMenu.addItem(.separator())
        let splitWithNextTab = NSMenuItem(title: "Split with Next Tab",
                                          action: #selector(AppDelegate.splitWithNextTab(_:)),
                                          keyEquivalent: "s")
        splitWithNextTab.keyEquivalentModifierMask = [.command, .option]
        splitWithNextTab.target = delegate
        viewMenu.addItem(splitWithNextTab)
        let breakUpSplit = NSMenuItem(title: "Break Up Split",
                                      action: #selector(AppDelegate.breakUpSplit(_:)),
                                      keyEquivalent: "s")
        breakUpSplit.keyEquivalentModifierMask = [.command, .option, .shift]
        breakUpSplit.target = delegate
        viewMenu.addItem(breakUpSplit)
        // Arrow-key equivalents: the NS*ArrowFunctionKey constants import into
        // Swift as Int (unnamed C enum), so UnicodeScalar's failable
        // BinaryInteger initializer converts them directly — no further cast.
        let focusNextPane = NSMenuItem(title: "Focus Next Pane",
                                       action: #selector(AppDelegate.focusNextPane(_:)),
                                       keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        focusNextPane.keyEquivalentModifierMask = [.command, .option]
        focusNextPane.target = delegate
        viewMenu.addItem(focusNextPane)
        let focusPreviousPane = NSMenuItem(title: "Focus Previous Pane",
                                           action: #selector(AppDelegate.focusPreviousPane(_:)),
                                           keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        focusPreviousPane.keyEquivalentModifierMask = [.command, .option]
        focusPreviousPane.target = delegate
        viewMenu.addItem(focusPreviousPane)
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

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
