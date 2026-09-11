import XCTest
@testable import NyxCore

final class TabLifecyclePolicyTests: XCTestCase {
    func testUnderLimitEvictsNothing() {
        let policy = TabLifecyclePolicy(warmLimit: 6)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], pinned: ["a"]), [])
    }

    func testOverLimitEvictsLeastRecentlyUsed() {
        let policy = TabLifecyclePolicy(warmLimit: 2)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "d", "e"], pinned: ["a"]), ["d", "e"])
    }

    func testPinnedNeverEvictedEvenAtTail() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "sel"], pinned: ["sel"]), ["b", "c"])
    }

    func testZeroLimitEvictsAllButPinned() {
        let policy = TabLifecyclePolicy(warmLimit: 0)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "sel"], pinned: ["sel"]), ["a", "b"])
    }

    func testEmptyPinnedTreatsAllAsEvictable() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], pinned: []), ["b", "c"])
    }

    func testWholeSplitGroupIsPinned() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        // Four visible panes + two background tabs; only the tail beyond
        // the warm limit among NON-pinned tabs is evicted.
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["p1", "p2", "bg1", "p3", "p4", "bg2"],
            pinned: ["p1", "p2", "p3", "p4"]), ["bg2"])
    }

    func testPinnedLargerThanWarmLimitStillAllKept() {
        let policy = TabLifecyclePolicy(warmLimit: 2)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["p1", "p2", "p3", "p4"],
            pinned: ["p1", "p2", "p3", "p4"]), [])
    }
}
