import XCTest
import WebKit
@testable import Nyx
import NyxCore

/// Same spy pattern as TabManagerMediaTests (that file's spy is private
/// to it): records media-suspension calls so close-path tests can assert
/// survivors of a split are never suspended.
private final class CloseSpyWebView: WKWebView {
    var recordedSuspensions: [Bool] = []

    override func setAllMediaPlaybackSuspended(_ suspended: Bool,
                                               completionHandler: (() -> Void)?) {
        recordedSuspensions.append(suspended)
        super.setAllMediaPlaybackSuspended(suspended, completionHandler: completionHandler)
    }
}

@MainActor
private final class CloseSpyWebViewFactory: WebViewFactory {
    override func makeWebView(adopting configuration: WKWebViewConfiguration) -> WKWebView {
        CloseSpyWebView(frame: .zero, configuration: configuration)
    }
}

@MainActor
final class TabManagerSplitTests: XCTestCase {
    private func makeManager() -> TabManager {
        TabManager(policy: TabLifecyclePolicy(warmLimit: 2))
    }

    func testSplitCreatesGroupAndPinsBoth() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)
        XCTAssertEqual(manager.splitGroups.count, 1)
        XCTAssertEqual(Set(manager.visibleTabIDs), [a.id, b.id])
        XCTAssertEqual(manager.splitGroups[0].weights, [0.5, 0.5])
        XCTAssertNotNil(a.webView)   // both panes live
        XCTAssertNotNil(b.webView)
    }

    func testSplitCapAtFour() {
        let manager = makeManager()
        let tabs = (0..<5).map { _ in manager.newTab() }
        manager.split(tabs[0], with: tabs[1])
        manager.split(tabs[0], with: tabs[2])
        manager.split(tabs[0], with: tabs[3])
        manager.split(tabs[0], with: tabs[4])   // must no-op
        XCTAssertEqual(manager.splitGroup(containing: tabs[0].id)?.tabIDs.count, 4)
        XCTAssertNil(manager.splitGroup(containing: tabs[4].id))
    }

    func testRemoveFromSplitDissolvesAtOne() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)
        manager.removeFromSplit(b)
        XCTAssertTrue(manager.splitGroups.isEmpty)
        XCTAssertNil(manager.splitGroup(containing: a.id))
    }

    func testSelectingGroupMemberShowsWholeGroup() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.split(a, with: b)
        manager.select(c)
        XCTAssertEqual(manager.visibleTabIDs, [c.id])
        manager.select(a)
        XCTAssertEqual(Set(manager.visibleTabIDs), [a.id, b.id])
    }

    func testSplitPersistsThroughSnapshotRestore() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)
        manager.updateWeights(groupID: manager.splitGroups[0].id,
                              weights: [0.7, 0.3])
        let snapshot = manager.snapshotForSaving()
        let second = makeManager()
        second.restore(from: snapshot)
        XCTAssertEqual(second.splitGroups.count, 1)
        XCTAssertEqual(second.splitGroups[0].weights[0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(Set(second.visibleTabIDs), [a.id, b.id])
    }

    func testRestoreDropsDegenerateGroups() {
        let manager = makeManager()
        let space = SpaceRecord(id: "s1", name: "S", orderIndex: 0)
        let lonely = TabRecord(id: "t1", spaceID: "s1", urlString: "", title: "",
                               orderIndex: 0, interactionState: nil,
                               lastActiveAt: Date(), splitGroupID: "g1")
        let group = SplitGroupRecord(id: "g1", spaceID: "s1", orderIndex: 0,
                                     weightsJSON: SplitGroupRecord.encodeWeights([1.0]))
        manager.restore(from: SessionSnapshot(
            spaces: [space], tabs: [lonely], splitGroups: [group],
            selectedSpaceID: "s1", selectedTabID: "t1"))
        XCTAssertTrue(manager.splitGroups.isEmpty)
    }

    func testWeightsFollowTabsThroughRestoreWhenPaneOrderDiffers() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(b, with: a)      // pane order [b, a] ≠ sidebar order [a, b]
        manager.updateWeights(groupID: manager.splitGroups[0].id,
                              weights: [0.7, 0.3])   // b → 0.7, a → 0.3
        let before = weightsByTab(manager.splitGroups[0])
        XCTAssertEqual(before[b.id] ?? -1, 0.7, accuracy: 0.0001)
        let second = makeManager()
        second.restore(from: manager.snapshotForSaving())
        XCTAssertEqual(second.splitGroups.count, 1)
        let after = weightsByTab(second.splitGroups[0])
        XCTAssertEqual(after[a.id] ?? -1, before[a.id] ?? -2, accuracy: 0.0001)
        XCTAssertEqual(after[b.id] ?? -1, before[b.id] ?? -2, accuracy: 0.0001)
    }

    private func weightsByTab(_ group: TabManager.RuntimeSplitGroup) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(group.tabIDs, group.weights))
    }

    func testSplitAcrossSpacesRefused() {
        let manager = makeManager()
        let a = manager.newTab()
        manager.newSpace(named: "Two")
        let b = manager.newTab()       // lives in the new space
        manager.split(a, with: b)
        XCTAssertTrue(manager.splitGroups.isEmpty)
    }

    func testSplitWithAlreadyGroupedTabRefused() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.split(a, with: b)
        let groupsBefore = manager.splitGroups
        manager.split(c, with: b)      // `other` already grouped → no change
        XCTAssertEqual(manager.splitGroups, groupsBefore)
        XCTAssertNil(manager.splitGroup(containing: c.id))
    }

    func testUpdateWeightsWrongLengthResetsToEqual() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)
        let groupID = manager.splitGroups[0].id
        manager.updateWeights(groupID: groupID, weights: [0.7, 0.3])
        manager.updateWeights(groupID: groupID, weights: [0.2, 0.3, 0.5])   // wrong length
        XCTAssertEqual(manager.splitGroups[0].weights, [0.5, 0.5])
    }

    func testSplitCompactsNonAdjacentMembersContiguous() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        XCTAssertEqual(manager.tabs(in: a.spaceID).map(\.id), [a.id, b.id, c.id])
        manager.split(a, with: c)   // non-adjacent: c hops over b
        XCTAssertEqual(manager.tabs(in: a.spaceID).map(\.id), [a.id, c.id, b.id])
        // Pane order (group.tabIDs) is untouched — only sidebar/flat order moved.
        XCTAssertEqual(manager.splitGroup(containing: a.id)?.tabIDs, [a.id, c.id])
    }

    func testExtendingGroupWithNonAdjacentTabKeepsMembersContiguous() {
        let manager = makeManager()
        let a = manager.newTab()
        let c = manager.newTab()
        let b = manager.newTab()
        let d = manager.newTab()
        let e = manager.newTab()   // the fourth tab created (after a, c, b, d)
        manager.split(a, with: c)   // group {a, c}: [a, c, b, d, e]
        XCTAssertEqual(manager.tabs(in: a.spaceID).map(\.id), [a.id, c.id, b.id, d.id, e.id])
        manager.split(a, with: e)   // extend with e — non-adjacent, past b and d
        let order = manager.tabs(in: a.spaceID).map(\.id)
        // All three group members contiguous, in a single unbroken run.
        let memberIndices = order.indices.filter { [a.id, c.id, e.id].contains(order[$0]) }
        XCTAssertEqual(memberIndices, Array((memberIndices.min()!)...(memberIndices.max()!)))
        // Non-members (b, d) keep their relative order.
        XCTAssertLessThan(order.firstIndex(of: b.id)!, order.firstIndex(of: d.id)!)
        XCTAssertEqual(order, [a.id, c.id, e.id, b.id, d.id])
    }

    func testRemoveFromSplitKeepsRemainingMembersContiguous() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.split(a, with: b)
        manager.split(a, with: c)   // group {a, b, c}, contiguous: [a, b, c]
        XCTAssertEqual(manager.tabs(in: a.spaceID).map(\.id), [a.id, b.id, c.id])
        manager.removeFromSplit(b)  // b was the INTERIOR member of the block
        XCTAssertEqual(Set(manager.splitGroup(containing: a.id)?.tabIDs ?? []), [a.id, c.id])
        // a and c (still grouped) must stay adjacent; b (now plain) is
        // pushed out of the block rather than left wedged between them.
        XCTAssertEqual(manager.tabs(in: a.spaceID).map(\.id), [a.id, c.id, b.id])
    }

    /// Final-review Important #1: closing the SELECTED pane of a split
    /// must keep the survivors on screen — selection hops to the adjacent
    /// surviving pane (next in group order, else previous), NOT to
    /// `remaining.last` of the space, and no survivor gets its media
    /// suspended along the way.
    func testCloseSelectedPaneKeepsSurvivorsVisibleAndUnsuspended() throws {
        let manager = TabManager(factory: CloseSpyWebViewFactory(),
                                 policy: TabLifecyclePolicy(warmLimit: 2))
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        let d = manager.newTab()   // plain tab — the old `remaining.last` trap
        manager.split(a, with: b)
        manager.split(a, with: c)  // group [a, b, c]
        manager.select(b)
        manager.close(b)
        // Preference: next pane in group order after b → c.
        XCTAssertEqual(manager.selectedTabID, c.id)
        XCTAssertEqual(manager.splitGroup(containing: a.id)?.tabIDs, [a.id, c.id])
        XCTAssertEqual(Set(manager.visibleTabIDs), [a.id, c.id])
        let suspensions = { (tab: BrowserTab) throws -> [Bool] in
            try XCTUnwrap(tab.webView as? CloseSpyWebView).recordedSuspensions
        }
        XCTAssertEqual(try suspensions(a), [])   // survivors never suspended
        XCTAssertEqual(try suspensions(c), [])
        XCTAssertNotNil(manager.tabs.first { $0.id == d.id })   // untouched bystander
    }

    func testCloseSelectedLastPaneFallsBackToPreviousPane() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        let c = manager.newTab()
        manager.newTab()           // plain trailing tab
        manager.split(a, with: b)
        manager.split(a, with: c)  // group [a, b, c]
        manager.select(c)
        manager.close(c)           // no next pane — previous (b) takes over
        XCTAssertEqual(manager.selectedTabID, b.id)
        XCTAssertEqual(manager.splitGroup(containing: a.id)?.tabIDs, [a.id, b.id])
    }

    /// Final-review minor: persisted non-contiguous member order must not
    /// resurrect past the contiguity invariant on restore.
    func testRestoreCompactsPersistedNonContiguousGroupMembers() {
        let manager = makeManager()
        let space = SpaceRecord(id: "s1", name: "S", orderIndex: 0)
        func record(_ id: String, order: Int, group: String? = nil) -> TabRecord {
            TabRecord(id: id, spaceID: "s1", urlString: "", title: "",
                      orderIndex: order, interactionState: nil,
                      lastActiveAt: Date(), splitGroupID: group)
        }
        let group = SplitGroupRecord(id: "g1", spaceID: "s1", orderIndex: 0,
                                     weightsJSON: SplitGroupRecord.encodeWeights([0.5, 0.5]))
        manager.restore(from: SessionSnapshot(
            spaces: [space],
            tabs: [record("a", order: 0, group: "g1"),
                   record("x", order: 1),                 // wedged non-member
                   record("c", order: 2, group: "g1"),
                   record("y", order: 3)],
            splitGroups: [group],
            selectedSpaceID: "s1", selectedTabID: "a"))
        XCTAssertEqual(manager.splitGroup(containing: "a")?.tabIDs, ["a", "c"])
        // Members pulled into one block at the first member's position;
        // non-members keep their relative order.
        XCTAssertEqual(manager.tabs(in: "s1").map(\.id), ["a", "c", "x", "y"])
    }

    func testMoveTabToSpaceLeavesGroup() {
        let manager = makeManager()
        let a = manager.newTab()
        let b = manager.newTab()
        manager.split(a, with: b)
        manager.newSpace(named: "Two")
        let target = manager.selectedSpaceID!
        manager.moveTab(b, toSpace: target)
        XCTAssertTrue(manager.splitGroups.isEmpty)   // dissolved at 1 member
        XCTAssertEqual(manager.tabs(in: target).map(\.id).contains(b.id), true)
    }
}
