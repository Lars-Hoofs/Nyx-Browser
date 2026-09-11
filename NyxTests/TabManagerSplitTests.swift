import XCTest
@testable import Nyx
import NyxCore

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
