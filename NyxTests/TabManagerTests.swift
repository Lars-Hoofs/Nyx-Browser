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

    // MARK: - newTab address-focus token (M4 launcher fix round)
    // Constructing a full NyxWindowCoordinator needs real window
    // machinery (see WindowCoordinatorFocusTests), so the launcher's two
    // paths are pinned at the seam the coordinator uses: `.run(.newTab)`
    // → newTab() (default bump), `.navigate(_, newTab: true)` →
    // newTab(focusAddress: false) (no bump).

    func testNewTabBumpsAddressFocusTokenByDefault() {
        let manager = makeManager()
        let before = manager.addressFocusToken
        manager.newTab()
        XCTAssertEqual(manager.addressFocusToken, before + 1,
                       "a NEW empty tab sends focus to the address field")
    }

    func testNewTabWithoutFocusAddressLeavesTokenUntouched() {
        let manager = makeManager()
        let before = manager.addressFocusToken
        let tab = manager.newTab(focusAddress: false)
        XCTAssertEqual(manager.addressFocusToken, before,
                       "a navigate-to-URL tab must not steal address focus")
        XCTAssertEqual(manager.selectedTabID, tab.id,
                       "focusAddress: false still selects the tab")
    }

    // MARK: - closeOtherTabs (M4 launcher command)

    func testCloseOtherTabsKeepsOnlySelectedTab() {
        let manager = makeManager()
        _ = manager.newTab()
        let keeper = manager.newTab()
        _ = manager.newTab()
        manager.select(keeper)
        manager.closeOtherTabs()
        XCTAssertEqual(manager.tabs.map(\.id), [keeper.id])
        XCTAssertEqual(manager.selectedTabID, keeper.id)
    }

    func testCloseOtherTabsKeepsSelectedTabsWholeGroup() {
        let manager = makeManager()
        let anchor = manager.newTab()
        let partner = manager.newTab()
        _ = manager.newTab()
        _ = manager.newTab()
        manager.select(anchor)
        manager.split(anchor, with: partner)
        manager.closeOtherTabs()
        // Survivors are the visible set: the selected tab's whole group.
        XCTAssertEqual(Set(manager.tabs.map(\.id)), Set([anchor.id, partner.id]))
        XCTAssertEqual(manager.splitGroup(containing: anchor.id)?.tabIDs.count, 2)
        XCTAssertEqual(manager.selectedTabID, anchor.id)
    }

    func testCloseOtherTabsDissolvesVictimGroups() {
        let manager = makeManager()
        let keeper = manager.newTab()
        let victimA = manager.newTab()
        let victimB = manager.newTab()
        manager.select(victimA)
        manager.split(victimA, with: victimB)   // a group the keeper is NOT in
        manager.select(keeper)
        manager.closeOtherTabs()
        XCTAssertEqual(manager.tabs.map(\.id), [keeper.id])
        XCTAssertTrue(manager.splitGroups.isEmpty,
                      "closing a whole victim group must dissolve it")
    }

    func testCloseOtherTabsLeavesOtherSpacesUntouched() {
        let manager = makeManager()
        let a1 = manager.newTab()
        let a2 = manager.newTab()
        manager.newSpace(named: "B")
        _ = manager.newTab()
        let b2 = manager.newTab()   // selected
        manager.closeOtherTabs()
        XCTAssertEqual(Set(manager.tabs.map(\.id)), Set([a1.id, a2.id, b2.id]))
        XCTAssertEqual(manager.selectedTabID, b2.id)
    }

    func testCloseOtherTabsWithoutSelectionIsANoOp() {
        let manager = makeManager()
        _ = manager.newTab()
        manager.newSpace(named: "Empty")   // nils the tab selection
        XCTAssertNil(manager.selectedTabID)
        manager.closeOtherTabs()
        XCTAssertEqual(manager.tabs.count, 1)
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
