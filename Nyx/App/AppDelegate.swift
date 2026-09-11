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
            // Task 8: applied BEFORE anything else touches the toggle, so
            // a leftover value from an earlier UITest run in this same
            // bundle's UserDefaults domain (per-bundle, NOT per-db-name —
            // see NyxSettings' doc) never leaks into a test that needs a
            // known starting state.
            if ProcessInfo.processInfo.arguments.contains("-nyx-reset-adblock-state") {
                coordinator.settings.adblockEnabled = true
            }
            if let testHTML = testHTMLLaunchArgument() {
                coordinator.loadTestHTML(testHTML)
            }
            if let seed = seedHistoryLaunchArgument() {
                coordinator.seedHistory(url: seed.url, title: seed.title)
            }
            if let dumpPath = dumpAdblockStateLaunchArgument() {
                dumpAdblockState(to: dumpPath, coordinator: coordinator)
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
    @objc func openLauncher(_ sender: Any?) { coordinator?.showLauncher() }
    @objc func toggleBlockAds(_ sender: Any?) { coordinator?.toggleGlobalAdblock() }
    @objc func toggleBlockAdsOnThisSite(_ sender: Any?) { coordinator?.toggleSiteAdblock() }

    #if DEBUG
    private func testHTMLLaunchArgument() -> String? {
        // ProcessInfo, not UserDefaults: UserDefaults drops values that
        // start with '<' (parsed as plist hex-data; see M1 Task 11).
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-nyx-test-html"),
              args.index(after: flagIndex) < args.count else { return nil }
        return args[args.index(after: flagIndex)]
    }

    /// Parses `-nyx-seed-history "<url>|<title>"` (ProcessInfo, per house
    /// rules — see testHTMLLaunchArgument above). One entry is enough for
    /// UI-test coverage; repeatable if a later test needs more than one.
    private func seedHistoryLaunchArgument() -> (url: String, title: String)? {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-nyx-seed-history"),
              args.index(after: flagIndex) < args.count else { return nil }
        let value = args[args.index(after: flagIndex)]
        guard let separatorIndex = value.firstIndex(of: "|") else { return nil }
        let url = String(value[value.startIndex..<separatorIndex])
        let title = String(value[value.index(after: separatorIndex)...])
        return (url, title)
    }

    /// Task 8: `-nyx-dump-adblock-state <path>` — pre-authorized fallback
    /// for reading adblock state in UI tests. XCUITest's read of an
    /// `NSMenuItem`'s checkmark `state` is documented (global-
    /// constraints.md's flake note; M3-T11's report) as flaky on this
    /// SDK for other AX surfaces, and the menu items here only validate
    /// (and thus set `.state`) while their menu is actually open — so
    /// rather than gamble on that path, this writes the coordinator's
    /// OWN state directly to a file inside the app's sandbox container,
    /// which the (unsandboxed) UI-test runner can read straight back,
    /// exactly like `tearDownWithError`'s direct container access.
    private func dumpAdblockStateLaunchArgument() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let flagIndex = args.firstIndex(of: "-nyx-dump-adblock-state"),
              args.index(after: flagIndex) < args.count else { return nil }
        return args[args.index(after: flagIndex)]
    }

    /// Writes `key=value` lines covering both the global toggle and the
    /// per-site gate/checkmark, so one dump mechanism serves both new UI
    /// tests. Best-effort (`try?`) — a failed dump fails the reading test
    /// via a missing file, never the app.
    private func dumpAdblockState(to path: String, coordinator: NyxWindowCoordinator) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = """
        global=\(coordinator.adblockEnabled)
        canToggleSite=\(coordinator.canToggleSiteAdblock)
        siteEnabled=\(coordinator.siteAdblockEnabled)

        """
        try? contents.write(to: url, atomically: true, encoding: .utf8)
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
        case #selector(toggleBlockAds(_:)):
            menuItem.state = (coordinator?.adblockEnabled ?? true) ? .on : .off
            return true
        case #selector(toggleBlockAdsOnThisSite(_:)):
            menuItem.state = (coordinator?.siteAdblockEnabled ?? true) ? .on : .off
            return coordinator?.canToggleSiteAdblock ?? false
        default: return true
        }
    }
}
