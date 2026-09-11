import XCTest
@testable import Nyx

/// `LauncherPanelController.toggle(over:)` needs a real NSWindow/NSScreen
/// to exercise end to end, so its placement math is pulled into a pure
/// static helper and tested directly here — same approach as
/// `WindowCoordinatorFocusTests` for the focus-transition guard.
@MainActor
final class LauncherPanelGeometryTests: XCTestCase {
    private let windowFrame = CGRect(x: 100, y: 200, width: 1280, height: 900)

    func testHorizontallyCenteredOverWindow() {
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: windowFrame, rawContentHeight: 200
        )
        XCTAssertEqual(frame.width, LauncherPanelController.panelWidth)
        XCTAssertEqual(frame.midX, windowFrame.midX, accuracy: 0.001)
    }

    func testTopEdgeSitsOneThirdDownFromWindowTop() {
        let height: CGFloat = 200
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: windowFrame, rawContentHeight: height
        )
        let expectedTopThird = windowFrame.maxY - windowFrame.height / 3
        XCTAssertEqual(frame.maxY, expectedTopThird, accuracy: 0.001)
        XCTAssertEqual(frame.height, height)
    }

    func testContentHeightBelowCapIsUsedAsIs() {
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: windowFrame, rawContentHeight: 120
        )
        XCTAssertEqual(frame.height, 120)
    }

    func testContentHeightAboveCapIsClamped() {
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: windowFrame, rawContentHeight: 900
        )
        XCTAssertEqual(frame.height, LauncherPanelController.maxPanelHeight)
    }

    func testDifferentWindowOriginsShiftThePanelButNotItsSize() {
        let shifted = windowFrame.offsetBy(dx: 500, dy: -300)
        let frameA = LauncherPanelController.panelFrame(
            overWindowFrame: windowFrame, rawContentHeight: 150
        )
        let frameB = LauncherPanelController.panelFrame(
            overWindowFrame: shifted, rawContentHeight: 150
        )
        XCTAssertEqual(frameB.origin.x - frameA.origin.x, 500, accuracy: 0.001)
        XCTAssertEqual(frameB.origin.y - frameA.origin.y, -300, accuracy: 0.001)
        XCTAssertEqual(frameA.size, frameB.size)
    }
}
