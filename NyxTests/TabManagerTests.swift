import XCTest
@testable import Nyx
import NyxCore

@MainActor
final class TabManagerTests: XCTestCase {
    private func makeManager() -> TabManager {
        TabManager(policy: TabLifecyclePolicy(warmLimit: 2))
    }

    func testNewTabCreatesDefaultSpaceAndSelects() {
        let manager = makeManager()
        let tab = manager.newTab()
        XCTAssertEqual(manager.spaces.count, 1)
        XCTAssertEqual(manager.selectedTabID, tab.id)
        XCTAssertEqual(manager.selectedSpaceID, tab.spaceID)
        XCTAssertNotNil(tab.webView)
    }

    func testCloseSelectsLastRemainingInSpace() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()
        manager.close(second)
        XCTAssertEqual(manager.selectedTabID, first.id)
    }

    func testCloseLastTabLeavesNilSelection() {
        let manager = makeManager()
        let only = manager.newTab()
        manager.close(only)
        XCTAssertNil(manager.selectedTabID)
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testRestoreFallsBackWhenSelectedTabMissing() {
        let manager = makeManager()
        let space = SpaceRecord(id: "s1", name: "Space", orderIndex: 0)
        let tab = TabRecord(id: "t1", spaceID: "s1", urlString: "", title: "",
                            orderIndex: 0, interactionState: nil, lastActiveAt: Date())
        manager.restore(from: SessionSnapshot(
            spaces: [space], tabs: [tab],
            selectedSpaceID: "s1", selectedTabID: "ghost"))
        XCTAssertEqual(manager.selectedTabID, "t1")
    }

    func testRestoreValidatesStaleSpaceID() {
        let manager = makeManager()
        let space = SpaceRecord(id: "s1", name: "Space", orderIndex: 0)
        let tab = TabRecord(id: "t1", spaceID: "s1", urlString: "", title: "",
                            orderIndex: 0, interactionState: nil, lastActiveAt: Date())
        manager.restore(from: SessionSnapshot(
            spaces: [space], tabs: [tab],
            selectedSpaceID: "ghost-space", selectedTabID: "t1"))
        XCTAssertEqual(manager.selectedSpaceID, "s1")
    }

    func testEvictionHibernatesBeyondWarmLimit() {
        let manager = makeManager()   // warmLimit 2
        let first = manager.newTab()
        _ = manager.newTab()
        _ = manager.newTab()
        let fourth = manager.newTab()
        // selected (fourth) pinned + 2 warm → first should be hibernated
        XCTAssertNil(first.webView)
        XCTAssertNotNil(fourth.webView)
    }

    func testSnapshotRoundTripThroughRestore() {
        let manager = makeManager()
        _ = manager.newTab()
        _ = manager.newTab()
        let snapshot = manager.snapshotForSaving()
        let second = makeManager()
        second.restore(from: snapshot)
        XCTAssertEqual(second.tabs.count, 2)
        XCTAssertEqual(second.selectedTabID, snapshot.selectedTabID)
    }
}
