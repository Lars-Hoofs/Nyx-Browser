import XCTest
import WebKit
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

/// M6 Task 5: `retryDownload(id:)`'s host-webview selection
/// (`retryHostWebView`), extracted per the same precedent above so it can
/// be pinned directly without constructing a full coordinator.
/// `WKWebView`, unlike `WKDownload`, has a public initializer, so real
/// instances stand in for "live" tabs here.
@MainActor
final class WindowCoordinatorDownloadRetryHostTests: XCTestCase {
    func testPrefersTheSelectedTabsWebViewWhenPresent() {
        let selected = WKWebView()
        let other = WKWebView()
        let result = NyxWindowCoordinator.retryHostWebView(selected: selected, tabs: [other])
        XCTAssertTrue(result === selected)
    }

    func testFallsBackToTheFirstLiveWebViewWhenNoneIsSelected() {
        let live = WKWebView()
        let result = NyxWindowCoordinator.retryHostWebView(selected: nil, tabs: [nil, live, nil])
        XCTAssertTrue(result === live)
    }

    func testReturnsNilWhenNoTabHasALiveWebView() {
        let result = NyxWindowCoordinator.retryHostWebView(selected: nil, tabs: [nil, nil])
        XCTAssertNil(result)
    }

    func testReturnsNilWhenThereAreNoTabsAtAll() {
        let result = NyxWindowCoordinator.retryHostWebView(selected: nil, tabs: [])
        XCTAssertNil(result)
    }
}
