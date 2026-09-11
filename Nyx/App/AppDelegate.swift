import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var coordinator: NyxWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build(delegate: self)
        NSApp.appearance = NSAppearance(named: .darkAqua)

        do {
            let coordinator = try NyxWindowCoordinator()
            self.coordinator = coordinator
            coordinator.start()

            #if DEBUG
            if let testHTML = testHTMLLaunchArgument() {
                coordinator.loadTestHTML(testHTML)
            }
            #endif
        } catch {
            NSLog("Nyx failed to start: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.flushSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions (Task 10 extends the menu itself)

    @objc func newTab(_ sender: Any?) { coordinator?.newTab() }
    @objc func closeTab(_ sender: Any?) { coordinator?.closeTab() }
    @objc func focusAddressField(_ sender: Any?) { coordinator?.focusAddress() }
    @objc func reloadPage(_ sender: Any?) { coordinator?.reloadPage() }
    @objc func goBack(_ sender: Any?) { coordinator?.goBack() }
    @objc func goForward(_ sender: Any?) { coordinator?.goForward() }
    @objc func selectNextTab(_ sender: Any?) { coordinator?.selectNextTab() }
    @objc func selectPreviousTab(_ sender: Any?) { coordinator?.selectPreviousTab() }
    @objc func splitWithNextTab(_ sender: Any?) { coordinator?.splitWithNextTab() }
    @objc func breakUpSplit(_ sender: Any?) { coordinator?.breakUpSplit() }
    @objc func focusNextPane(_ sender: Any?) { coordinator?.focusNextPane() }
    @objc func focusPreviousPane(_ sender: Any?) { coordinator?.focusPreviousPane() }

    #if DEBUG
    private func testHTMLLaunchArgument() -> String? {
        // ProcessInfo, not UserDefaults: UserDefaults drops values that
        // start with '<' (parsed as plist hex-data; see M1 Task 11).
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-nyx-test-html"),
              args.index(after: flagIndex) < args.count else { return nil }
        return args[args.index(after: flagIndex)]
    }
    #endif
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return coordinator?.canGoBack ?? false
        case #selector(goForward(_:)): return coordinator?.canGoForward ?? false
        case #selector(closeTab(_:)): return coordinator?.canCloseTab ?? false
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return (coordinator?.manager.tabs.count ?? 0) > 1
        case #selector(splitWithNextTab(_:)): return coordinator?.canSplit ?? false
        case #selector(breakUpSplit(_:)), #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
            return coordinator?.isInSplit ?? false
        default: return true
        }
    }
}
