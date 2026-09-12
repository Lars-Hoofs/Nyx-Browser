import XCTest

final class NyxUITests: XCTestCase {
    private let fixtureHTML =
        "<html><head><title>Nyx Fixture</title></head><body>ok</body></html>"

    /// Names of every in-container UITest database used by this test
    /// instance, so `tearDownWithError` can best-effort clean them up.
    private var usedDatabaseNames: [String] = []

    private func freshDatabaseName() -> String {
        let name = "uitest-\(UUID().uuidString)"
        usedDatabaseNames.append(name)
        return name
    }

    private func launch(dbName: String, withFixture: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-nyx-db-name", dbName]
        if withFixture { arguments += ["-nyx-test-html", fixtureHTML] }
        arguments += extraArguments
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func tabRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.outlines.descendants(matching: .any).matching(identifier: "nyx.tabRow")
    }

    /// Absolute paths handed to `-nyx-dump-adblock-state`, so
    /// `tearDownWithError` can best-effort remove them even on a failed
    /// assertion (mirrors `usedDatabaseNames` below).
    private var usedDumpPaths: [URL] = []

    /// The REAL user home (/Users/<name>), resolved via getpwuid. The
    /// xctrunner has its own sandbox container on this SDK, so
    /// `FileManager.homeDirectoryForCurrentUser` returns the RUNNER's
    /// container — nesting any "Library/Containers/com.larshoofs.Nyx/…"
    /// path inside `…NyxUITests.xctrunner/Data/…`, where the app never
    /// writes (first live run of the adblock tests proved it: NSCocoaError
    /// 260, file written to the real container, read attempted in the
    /// nested one). getpwuid reports the true home regardless of sandbox.
    private static let realUserHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// A fresh path inside the app's OWN sandbox container (`Data/tmp`,
    /// the same directory `NSTemporaryDirectory()` resolves to for a
    /// sandboxed app), so the app process can write it under its default
    /// sandbox grant with no extra entitlement, and this runner can read
    /// it back directly afterwards — anchored at `realUserHome`, NOT
    /// `homeDirectoryForCurrentUser` (see above).
    private func adblockStateDumpURL() -> URL {
        let url = Self.realUserHome
            .appendingPathComponent(
                "Library/Containers/com.larshoofs.Nyx/Data/tmp/adblock-\(UUID().uuidString).txt")
        usedDumpPaths.append(url)
        return url
    }

    /// Polls for the DEBUG dump file (written once, synchronously, right
    /// after `applicationDidFinishLaunching` finishes its DEBUG setup —
    /// see `AppDelegate.dumpAdblockState`) and parses its `key=value`
    /// lines. Reads the coordinator's OWN state directly, deliberately
    /// bypassing `NSMenuItem` checkmark/enabled reads: those items only
    /// validate (and set `.state`/`.isEnabled`) while their menu is open,
    /// and XCUITest's read of menu-item state is documented elsewhere in
    /// this codebase (global-constraints.md's flake note) as unreliable
    /// on this SDK — this is the pre-authorized, deterministic fallback.
    private func readAdblockState(at url: URL, timeout: TimeInterval = 10) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup: the app writes its UITest databases inside
        // its own sandbox container, which the (unsandboxed) test runner
        // can still reach directly.
        let containerAppSupport = Self.realUserHome
            .appendingPathComponent("Library/Containers/com.larshoofs.Nyx/Data/Library/Application Support/Nyx/UITests", isDirectory: true)
        for name in usedDatabaseNames {
            for suffix in ["", "-wal", "-shm"] {
                let url = containerAppSupport.appendingPathComponent("\(name).sqlite\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        usedDatabaseNames.removeAll()
        for url in usedDumpPaths {
            try? FileManager.default.removeItem(at: url)
        }
        usedDumpPaths.removeAll()
        try super.tearDownWithError()
    }

    func testLaunchRendersPageAndChrome() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["nyx.addressField"].waitForExistence(timeout: 10))
    }

    func testNewTabAppearsInSidebar() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let initialCount = rows.count
        app.typeKey("t", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while rows.count < initialCount + 1 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(rows.count, initialCount + 1)
    }

    func testSessionRestoresAcrossRelaunch() {
        let dbName = freshDatabaseName()
        var app = launch(dbName: dbName)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while rows.count < 3 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(rows.count, 3)

        // Debounce is 2 s; give the save a beat, then quit cleanly
        // (applicationWillTerminate also flushes synchronously).
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        app.terminate()

        app = launch(dbName: dbName, withFixture: false)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restoredRows = tabRows(in: app)
        let restoreDeadline = Date().addingTimeInterval(10)
        while restoredRows.count < 3 && Date() < restoreDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(restoredRows.count, 3)
    }

    func testSplitShowsTwoPanes() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let initialCount = rows.count

        app.typeKey("t", modifierFlags: .command)              // 2nd tab
        let tabDeadline = Date().addingTimeInterval(5)
        while rows.count < initialCount + 1 && Date() < tabDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(
            rows.count, initialCount + 1,
            "expected \(initialCount + 1) tab row(s) after \u{2318}T, but \(rows.count) were delivered"
        )

        app.activate()
        app.typeKey("s", modifierFlags: [.command, .option])   // split with next
        let panes = app.descendants(matching: .any).matching(identifier: "nyx.pane")
        let deadline = Date().addingTimeInterval(10)
        while panes.count < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(panes.count, 2)

        let clusters = app.descendants(matching: .any).matching(identifier: "nyx.splitCluster")
        XCTAssertTrue(clusters.firstMatch.waitForExistence(timeout: 10))
    }

    func testSplitPersistsAcrossRelaunch() {
        let dbName = freshDatabaseName()
        var app = launch(dbName: dbName)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let initialCount = rows.count

        app.typeKey("t", modifierFlags: .command)
        let tabDeadline = Date().addingTimeInterval(5)
        while rows.count < initialCount + 1 && Date() < tabDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(
            rows.count, initialCount + 1,
            "expected \(initialCount + 1) tab row(s) after \u{2318}T, but \(rows.count) were delivered"
        )

        app.activate()
        app.typeKey("s", modifierFlags: [.command, .option])
        let panes = app.descendants(matching: .any).matching(identifier: "nyx.pane")
        let deadline = Date().addingTimeInterval(10)
        while panes.count < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(panes.count, 2)

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))  // debounce
        app.terminate()

        app = launch(dbName: dbName, withFixture: false)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restored = app.descendants(matching: .any).matching(identifier: "nyx.pane")
        let restoreDeadline = Date().addingTimeInterval(10)
        while restored.count < 2 && Date() < restoreDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(restored.count, 2)
    }

    // MARK: - Launcher (M4 Task 7)

    func testLauncherOpensAndFilters() {
        let app = launch(
            dbName: freshDatabaseName(),
            extraArguments: ["-nyx-seed-history", "https://example.org/docs|Nyx Example Docs"]
        )
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["nyx.launcherField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))

        // No explicit click before typing: on macOS, XCUIElement.typeText
        // delivers keystrokes to whatever currently holds keyboard focus,
        // not to `field` directly — so the typed text landing in the
        // field's value IS the proof it had keyboard focus the moment
        // ⌘K opened it.
        field.typeText("docs")
        XCTAssertEqual(field.value as? String, "docs")

        // Each row surfaces as a StaticText whose accessibility VALUE is
        // the row's title text (not `label`) — confirmed via the element
        // tree during development.
        let seededRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value CONTAINS %@",
                        "nyx.launcherRow", "Nyx Example Docs")
        ).firstMatch
        XCTAssertTrue(seededRow.waitForExistence(timeout: 5))
    }

    func testLauncherSwitchesTabs() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))

        let rows = tabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let initialCount = rows.count
        app.typeKey("t", modifierFlags: .command)
        let tabDeadline = Date().addingTimeInterval(10)
        while rows.count < initialCount + 1 && Date() < tabDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(
            rows.count, initialCount + 1,
            "expected \(initialCount + 1) tab row(s) after \u{2318}T, but \(rows.count) were delivered"
        )

        app.activate()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["nyx.launcherField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("fixture")
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 10))
    }

    /// T4-review mandate: ⌘K opens (field exists + has keyboard focus), Esc
    /// dismisses (field gone), ⌘K reopens and the field accepts typing
    /// again — covers the re-show-focus unknown flagged by the T5 review.
    ///
    /// Keyboard focus is proven behaviorally rather than via
    /// `XCUIElement.hasFocus` (not exposed through macOS's `XCTest` module
    /// on this SDK): typing with no preceding click and seeing the text
    /// land in the field's value is only possible if the field already
    /// held keyboard focus the moment it appeared.
    ///
    /// No `XCUIElement` reference is ever reused across an Esc/⌘K boundary:
    /// each phase re-queries `app.textFields["nyx.launcherField"]` fresh.
    /// Holding a resolved reference across the resign-key dismiss (the
    /// panel's by-design close-on-resign-key behavior) hits XCUITest's
    /// interruption handling and invalidates it — "Targeted element ...
    /// is no longer valid after interruption handling", observed when this
    /// test first held `field` across the reopen. Typing after the reopen
    /// goes through `app.typeText`, which delivers to the key window's
    /// current first responder directly with no element re-resolution at
    /// all.
    func testLauncherLifecycle() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["nyx.launcherField"].waitForExistence(timeout: 10))
        app.typeText("probe")
        XCTAssertEqual(app.textFields["nyx.launcherField"].value as? String, "probe")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["nyx.launcherField"].waitForNonExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["nyx.launcherField"].waitForExistence(timeout: 10))
        app.typeText("test")
        XCTAssertEqual(app.textFields["nyx.launcherField"].value as? String, "test")
    }

    /// Binding review mandate: clicking outside the launcher panel
    /// resigns its key status, which closes it via `windowDidResignKey`
    /// (`LauncherPanelController`'s single close funnel — same path Esc
    /// and app-deactivate both drive). The address field lives in the
    /// main window, clear of the floating panel's frame, so clicking it
    /// is a real click-outside rather than a click inside the panel.
    ///
    /// Same query-freshness discipline as `testLauncherLifecycle`: the
    /// resign-key close is an XCUITest interruption boundary, so the
    /// post-click assertion re-queries `nyx.launcherField` fresh rather
    /// than reusing any element resolved before the click.
    func testLauncherDismissesOnClickOutside() {
        let app = launch(dbName: freshDatabaseName())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["nyx.launcherField"].waitForExistence(timeout: 10))

        // Outside the panel, in the main window.
        app.textFields["nyx.addressField"].click()

        // Bounded poll on a fresh query — waitForNonExistence resolves
        // the query itself on each poll, so no stale reference crosses
        // the resign-key boundary.
        XCTAssertTrue(app.textFields["nyx.launcherField"].waitForNonExistence(timeout: 5))
    }

    func testLaunchPerformanceBaseline() {
        // Spec §7: cold launch < 500 ms to first paint. This records the
        // baseline metric (visible in the xcresult); hard-assert once the
        // number is stable across runs.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-nyx-db-name", freshDatabaseName()]
            app.launch()
            app.terminate()
        }
    }

    // MARK: - Adblock (M5 Task 8)

    /// Design decision (recorded per the task-8 brief's pre-authorized
    /// fallback): asserts the "Block Ads" toggle's PERSISTED state via
    /// the `-nyx-dump-adblock-state` file dump, not via an
    /// `app.menuItems["Block Ads"]` state/checkmark read. The toggle
    /// itself IS still driven through the real menu (`.click()` on the
    /// real `NSMenuItem`, exercising `MainMenuBuilder`'s wiring end to
    /// end) — only the READ side of the assertion goes through the file,
    /// because that's the half XCUITest is documented to be unreliable
    /// at on this SDK (see `readAdblockState`'s doc).
    ///
    /// Test isolation: `NyxSettings`' backing UserDefaults key is
    /// per-BUNDLE, not per-db-name (its own doc), so a value left over
    /// from ANY earlier test/run in this bundle would otherwise leak in.
    /// `-nyx-reset-adblock-state` (first launch only) pins a known
    /// starting point; the second launch omits it deliberately, because
    /// that omission is exactly what's under test — does the flip
    /// survive an app relaunch with nothing re-asserting it?
    func testAdblockMenuTogglePersists() throws {
        let dbName = freshDatabaseName()
        let firstDump = adblockStateDumpURL()
        var app = launch(dbName: dbName, extraArguments: [
            "-nyx-reset-adblock-state",
            "-nyx-dump-adblock-state", firstDump.path
        ])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try readAdblockState(at: firstDump)["global"], "true",
                       "reset arg must pin the known default (blocking ON) before any toggle")

        // Drive the real menu end to end: View > Block Ads. Top-level
        // menu-bar entries and their submenu's items are lazily
        // published, so the submenu must actually be opened before
        // `menuItems["Block Ads"]` resolves to anything. Menu-bar clicks
        // need the app frontmost (macOS shows only the active app's menu
        // bar) — precedent elsewhere in this file for menu-driven actions.
        app.activate()
        app.menuBarItems["View"].click()
        let blockAds = app.menuItems["Block Ads"]
        XCTAssertTrue(blockAds.waitForExistence(timeout: 5))
        blockAds.click()

        // toggleGlobalAdblock() writes synchronously (NyxSettings'
        // nonmutating UserDefaults set) before this returns, but give the
        // menu's dismiss animation a beat before terminating.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.terminate()

        let secondDump = adblockStateDumpURL()
        app = launch(dbName: dbName, withFixture: false, extraArguments: [
            "-nyx-dump-adblock-state", secondDump.path
        ])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try readAdblockState(at: secondDump)["global"], "false",
                       "the OFF flip must survive a relaunch with no reset arg present")
    }

    /// Design decision (recorded per the task-8 brief's discussion of the
    /// offline constraint): the fixture page loads via
    /// `WKWebView.loadHTMLString(_:baseURL:)` (see
    /// `NyxWindowCoordinator.loadTestHTML`) — there is no real navigation,
    /// so `BrowserTab.currentHost` is and stays `nil`. Seeding a fake host
    /// without a real navigation would misrepresent what the app actually
    /// observed, so this test does NOT fake one.
    ///
    /// Instead it pins the strongest claim that's true OFFLINE: with a
    /// nil-host tab selected, "Block Ads on This Site" must be GATED OFF
    /// (`canToggleSiteAdblock == false`) — exactly the guard
    /// `NyxWindowCoordinator.canToggleSiteAdblock` documents, and exactly
    /// what a user would see (a disabled menu item) for any tab that
    /// hasn't committed a navigation yet. The override-FLIP behavior for
    /// a real host is already pinned at the unit level against
    /// `NyxWindowCoordinator`'s static decision functions directly
    /// (`AdblockMenuToggleTests`), with a real on-disk `SiteOverrideStore`
    /// — this UI test's job is only to confirm the live app wires that
    /// same gate through to the coordinator surface the menu reads,
    /// which is exactly what the dump's `canToggleSite` line reports.
    func testPerSiteToggleReflectsInMenu() throws {
        let dump = adblockStateDumpURL()
        let app = launch(dbName: freshDatabaseName(), extraArguments: [
            "-nyx-dump-adblock-state", dump.path
        ])
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))

        let state = try readAdblockState(at: dump)
        XCTAssertEqual(state["canToggleSite"], "false",
                       "a fixture tab has no committed navigation (nil host) — " +
                       "the per-site toggle must stay gated off, matching what " +
                       "the disabled menu item shows the user")
    }
}
