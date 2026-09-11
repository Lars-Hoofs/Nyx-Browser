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

    override func tearDownWithError() throws {
        // Best-effort cleanup: the app writes its UITest databases inside
        // its own sandbox container, which the (unsandboxed) test runner
        // can still reach directly.
        let containerAppSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.larshoofs.Nyx/Data/Library/Application Support/Nyx/UITests", isDirectory: true)
        for name in usedDatabaseNames {
            for suffix in ["", "-wal", "-shm"] {
                let url = containerAppSupport.appendingPathComponent("\(name).sqlite\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        usedDatabaseNames.removeAll()
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
}
