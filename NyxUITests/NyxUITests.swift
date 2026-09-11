import XCTest

final class NyxUITests: XCTestCase {
    func testLaunchRendersPageAndChrome() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-nyx-test-html",
            "<html><head><title>Nyx Fixture</title></head><body>ok</body></html>"
        ]
        app.launch()

        // Window appears and picks up the page title (Task 8 mirroring).
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.windows["Nyx Fixture"].waitForExistence(timeout: 15))

        // Chrome is present.
        let addressField = app.textFields["nyx.addressField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 10))
    }
}
