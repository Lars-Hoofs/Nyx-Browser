import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// Records every media-suspension call WebKit would receive, so the tests
/// can assert the spec §5.2 rule: suspend ONLY panes leaving a visible
/// split, never on plain tab switches.
@MainActor
private final class SpyWebView: WKWebView {
    var recordedSuspensions: [Bool] = []

    override func setAllMediaPlaybackSuspended(_ suspended: Bool,
                                               completionHandler: (() -> Void)?) {
        recordedSuspensions.append(suspended)
        super.setAllMediaPlaybackSuspended(suspended, completionHandler: completionHandler)
    }
}

private final class SpyWebViewFactory: WebViewFactory {
    override func makeWebView(adopting configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = SpyWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }
}

@MainActor
final class TabManagerMediaTests: XCTestCase {
    private func makeManager() -> TabManager {
        TabManager(factory: SpyWebViewFactory(),
                   policy: TabLifecyclePolicy(warmLimit: 2))
    }

    private func recorded(_ tab: BrowserTab) throws -> [Bool] {
        try XCTUnwrap(tab.webView as? SpyWebView).recordedSuspensions
    }

    func testRemoveFromVisibleSplitSuspendsOnlyRemovedTab() throws {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.split(a, with: b)
        manager.split(a, with: c)      // group [a, b, c], selected c → visible
        manager.removeFromSplit(a)     // non-selected member; [b, c] stays visible
        XCTAssertEqual(try recorded(a), [true])
        XCTAssertEqual(try recorded(b), [])
        XCTAssertEqual(try recorded(c), [])
    }

    func testPlainTabSwitchNeverTouchesMediaSuspension() throws {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.select(a)
        manager.select(b)
        XCTAssertEqual(try recorded(a), [])
        XCTAssertEqual(try recorded(b), [])
    }

    func testDissolveSuspendsNonSurvivingPanes() throws {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.split(a, with: b)
        manager.split(a, with: c)      // group [a, b, c], selected c → visible
        manager.dissolveSplit(containing: a)
        XCTAssertEqual(try recorded(a), [true])
        XCTAssertEqual(try recorded(b), [true])
        XCTAssertEqual(try recorded(c), [])    // surviving selected pane
    }

    func testReselectingSuspendedTabLiftsSuspension() throws {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)      // selected b, visible [a, b]
        manager.removeFromSplit(a)     // dissolves; a leaves the visible split
        XCTAssertEqual(try recorded(a), [true])
        manager.select(a)              // activateVisibleSet lifts the suspension
        XCTAssertEqual(try recorded(a), [true, false])
        XCTAssertEqual(try recorded(b), [])
    }
}
