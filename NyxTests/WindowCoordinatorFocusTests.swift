import XCTest
@testable import Nyx

/// Constructing a full NyxWindowCoordinator needs a session store and
/// real window machinery, so the focus-steal regression guard (final
/// re-review Important: onSelectionChange re-fires on the selected tab's
/// url/title mutations, and the responder hop must ignore those) is
/// tested through its extracted pure helper instead — the exact function
/// the onSelectionChange closure gates the hop with.
@MainActor
final class WindowCoordinatorFocusTests: XCTestCase {
    func testResponderMovesOnlyOnRealSelectionTransitions() {
        // App start / first selection → move.
        XCTAssertTrue(NyxWindowCoordinator.shouldMoveResponder(to: "a", from: nil))
        // Pane-focus hop to another tab → move.
        XCTAssertTrue(NyxWindowCoordinator.shouldMoveResponder(to: "b", from: "a"))
        // Same-tab re-fire (title-ticker page mutating its title while
        // the user types in the address field) → never steal focus.
        XCTAssertFalse(NyxWindowCoordinator.shouldMoveResponder(to: "a", from: "a"))
        // Deselection (last tab closed, fresh space) → nothing to focus.
        XCTAssertFalse(NyxWindowCoordinator.shouldMoveResponder(to: nil, from: "a"))
        XCTAssertFalse(NyxWindowCoordinator.shouldMoveResponder(to: nil, from: nil))
    }
}
