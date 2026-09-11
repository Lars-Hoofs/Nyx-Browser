import XCTest
@testable import NyxCore

final class TabLifecyclePolicyTests: XCTestCase {
    func testUnderLimitEvictsNothing() {
        let policy = TabLifecyclePolicy(warmLimit: 6)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], selected: "a"), [])
    }

    func testOverLimitEvictsLeastRecentlyUsed() {
        let policy = TabLifecyclePolicy(warmLimit: 2)
        // selected "a" is exempt; of the rest, keep the 2 most recent (b, c)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "d", "e"], selected: "a"), ["d", "e"])
    }

    func testSelectedNeverEvictedEvenAtTail() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c", "sel"], selected: "sel"), ["b", "c"])
    }

    func testZeroLimitEvictsAllButSelected() {
        let policy = TabLifecyclePolicy(warmLimit: 0)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "sel"], selected: "sel"), ["a", "b"])
    }

    func testNilSelectedTreatsAllAsEvictable() {
        let policy = TabLifecyclePolicy(warmLimit: 1)
        XCTAssertEqual(policy.evictionCandidates(
            mruLiveTabs: ["a", "b", "c"], selected: nil), ["b", "c"])
    }
}
