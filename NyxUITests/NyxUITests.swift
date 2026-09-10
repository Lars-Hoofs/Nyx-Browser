import XCTest

final class NyxUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
