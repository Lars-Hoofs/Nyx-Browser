import XCTest

final class NyxUITests: XCTestCase {
    private let fixtureHTML =
        "<html><head><title>Nyx Fixture</title></head><body>ok</body></html>"

    private func freshDatabasePath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-uitest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.sqlite").path
    }

    private func launch(dbPath: String, withFixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-nyx-db-path", dbPath]
        if withFixture { arguments += ["-nyx-test-html", fixtureHTML] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    private func tabRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "nyx.tabRow")
    }

    func testLaunchRendersPageAndChrome() {
        let app = launch(dbPath: freshDatabasePath())
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["nyx.addressField"].waitForExistence(timeout: 10))
    }

    func testNewTabAppearsInSidebar() {
        let app = launch(dbPath: freshDatabasePath())
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
        let dbPath = freshDatabasePath()
        var app = launch(dbPath: dbPath)
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

        app = launch(dbPath: dbPath, withFixture: false)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let restoredRows = tabRows(in: app)
        let restoreDeadline = Date().addingTimeInterval(10)
        while restoredRows.count < 3 && Date() < restoreDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(restoredRows.count, 3)
    }

    func testLaunchPerformanceBaseline() {
        // Spec §7: cold launch < 500 ms to first paint. This records the
        // baseline metric (visible in the xcresult); hard-assert once the
        // number is stable across runs.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-nyx-db-path", freshDatabasePath()]
            app.launch()
            app.terminate()
        }
    }
}
