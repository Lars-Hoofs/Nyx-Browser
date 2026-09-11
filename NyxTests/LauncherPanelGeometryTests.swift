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

    // MARK: - Screen-bounds clamp (M4 T5, carried over from the T4 review)

    func testTinyWindowAtScreenBottomLeftIsClampedOnScreen() {
        // Honest multi-display coordinates: a screen positioned left of
        // and below the main one has a NEGATIVE origin — the clamp must
        // respect the screen's own min edges, never an assumed (0, 0).
        let screen = CGRect(x: -1600, y: -200, width: 1600, height: 1000)
        let tiny = CGRect(x: -1595, y: -195, width: 140, height: 90)
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: tiny, rawContentHeight: 400, within: screen
        )
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.minX, screen.minX, accuracy: 0.001,
                       "a window narrower than the panel pins it to the screen's left edge")
        XCTAssertEqual(frame.minY, screen.minY, accuracy: 0.001,
                       "a tiny window near the screen bottom pins the panel to the bottom edge")
    }

    func testWindowHangingOffTopRightIsClampedOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let hanging = CGRect(x: 1400, y: 900, width: 800, height: 600)
        let frame = LauncherPanelController.panelFrame(
            overWindowFrame: hanging, rawContentHeight: 300, within: screen
        )
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.size, CGSize(width: LauncherPanelController.panelWidth,
                                          height: 300),
                       "clamping moves the panel, never resizes it")
    }
}
