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

    private func launch(dbName: String, withFixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-nyx-db-name", dbName]
        if withFixture { arguments += ["-nyx-test-html", fixtureHTML] }
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
