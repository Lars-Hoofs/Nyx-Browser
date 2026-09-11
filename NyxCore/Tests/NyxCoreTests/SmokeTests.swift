import XCTest
@testable import NyxCore

final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(NyxCore.version, "0.1.0")
    }
}
