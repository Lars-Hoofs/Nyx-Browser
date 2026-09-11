import XCTest
@testable import NyxCore

final class SessionStoreTests: XCTestCase {
    private var dbURL: URL!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-store-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func makeSnapshot() -> SessionSnapshot {
        let space = SpaceRecord(id: "s1", name: "Personal", orderIndex: 0)
        let tabA = TabRecord(id: "t1", spaceID: "s1", urlString: "https://example.com",
                             title: "Example", orderIndex: 0,
                             interactionState: Data([0x01, 0x02]),
                             lastActiveAt: Date(timeIntervalSince1970: 1000))
        let tabB = TabRecord(id: "t2", spaceID: "s1", urlString: "https://apple.com",
                             title: "Apple", orderIndex: 1,
                             interactionState: nil,
                             lastActiveAt: Date(timeIntervalSince1970: 2000))
        return SessionSnapshot(spaces: [space], tabs: [tabA, tabB],
                               selectedSpaceID: "s1", selectedTabID: "t2")
    }

    func testFreshDatabaseLoadsEmpty() throws {
        let store = try SessionStore(databaseURL: dbURL)
        let snapshot = try store.load()
        XCTAssertTrue(snapshot.spaces.isEmpty)
        XCTAssertTrue(snapshot.tabs.isEmpty)
        XCTAssertNil(snapshot.selectedTabID)
        XCTAssertNil(snapshot.selectedSpaceID)
    }

    func testSaveLoadRoundTrip() throws {
        let store = try SessionStore(databaseURL: dbURL)
        let original = makeSnapshot()
        try store.save(original)
        let loaded = try store.load()
        XCTAssertEqual(loaded.spaces, original.spaces)
        XCTAssertEqual(loaded.tabs, original.tabs)
        XCTAssertEqual(loaded.selectedSpaceID, "s1")
        XCTAssertEqual(loaded.selectedTabID, "t2")
    }

    func testPersistsAcrossReopen() throws {
        try SessionStore(databaseURL: dbURL).save(makeSnapshot())
        let reopened = try SessionStore(databaseURL: dbURL)
        XCTAssertEqual(try reopened.load().tabs.count, 2)
    }

    func testSaveReplacesRemovedTabs() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        try store.save(snapshot)
        snapshot.tabs.removeLast()          // close t2
        snapshot.selectedTabID = "t1"
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded.tabs.map(\.id), ["t1"])
        XCTAssertEqual(loaded.selectedTabID, "t1")
    }

    func testLoadOrdersByOrderIndex() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        snapshot.tabs[0].orderIndex = 5     // t1 now sorts after t2
        try store.save(snapshot)
        XCTAssertEqual(try store.load().tabs.map(\.id), ["t2", "t1"])
    }

    func testUpdateInteractionState() throws {
        let store = try SessionStore(databaseURL: dbURL)
        try store.save(makeSnapshot())
        try store.updateInteractionState(tabID: "t2", data: Data([0xAB]))
        let loaded = try store.load()
        XCTAssertEqual(loaded.tabs.first(where: { $0.id == "t2" })?.interactionState,
                       Data([0xAB]))
        try store.updateInteractionState(tabID: "t2", data: nil)
        XCTAssertNil(try store.load().tabs.first(where: { $0.id == "t2" })?.interactionState)
    }

    func testSaveThrowsWhenTabReferencesRemovedSpace() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        let space2 = SpaceRecord(id: "s2", name: "Work", orderIndex: 1)
        let tabC = TabRecord(id: "t3", spaceID: "s2", urlString: "https://work.example.com",
                             title: "Work", orderIndex: 0,
                             interactionState: nil,
                             lastActiveAt: Date(timeIntervalSince1970: 3000))
        snapshot.spaces.append(space2)
        snapshot.tabs.append(tabC)
        try store.save(snapshot)

        // Drop s2 from spaces but leave t3 (spaceID: "s2") in tabs: t3 becomes
        // an orphan reference on re-save, which must fail if (and only if)
        // foreign-key enforcement is active on this connection.
        snapshot.spaces.removeLast()
        XCTAssertThrowsError(try store.save(snapshot))
    }

    func testSaveClearsSelectionWhenSetToNil() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        try store.save(snapshot)
        snapshot.selectedSpaceID = nil
        snapshot.selectedTabID = nil
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertNil(loaded.selectedSpaceID)
        XCTAssertNil(loaded.selectedTabID)
    }

    func testSplitGroupRoundTrip() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        let group = SplitGroupRecord(
            id: "g1", spaceID: "s1", orderIndex: 0,
            weightsJSON: SplitGroupRecord.encodeWeights([0.5, 0.5]))
        snapshot.splitGroups = [group]
        snapshot.tabs[0].splitGroupID = "g1"
        snapshot.tabs[1].splitGroupID = "g1"
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertEqual(loaded.splitGroups, [group])
        XCTAssertEqual(loaded.splitGroups[0].weights, [0.5, 0.5])
        XCTAssertEqual(loaded.tabs.map(\.splitGroupID), ["g1", "g1"])
    }

    func testMigrationFromV1DataPreservesTabs() throws {
        // Simulate a v1 database: open once (runs all migrations on empty),
        // save v1-shaped data (no groups), reopen, confirm intact.
        try SessionStore(databaseURL: dbURL).save(makeSnapshot())
        let reopened = try SessionStore(databaseURL: dbURL)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.tabs.count, 2)
        XCTAssertTrue(loaded.splitGroups.isEmpty)
        XCTAssertNil(loaded.tabs[0].splitGroupID)
    }

    func testDeletingGroupNullsTabMembership() throws {
        let store = try SessionStore(databaseURL: dbURL)
        var snapshot = makeSnapshot()
        snapshot.splitGroups = [SplitGroupRecord(
            id: "g1", spaceID: "s1", orderIndex: 0,
            weightsJSON: SplitGroupRecord.encodeWeights([0.5, 0.5]))]
        snapshot.tabs[0].splitGroupID = "g1"
        snapshot.tabs[1].splitGroupID = "g1"
        try store.save(snapshot)
        // Save again without the group but with memberships cleared —
        // the normal dissolve path the manager emits.
        snapshot.splitGroups = []
        snapshot.tabs[0].splitGroupID = nil
        snapshot.tabs[1].splitGroupID = nil
        try store.save(snapshot)
        let loaded = try store.load()
        XCTAssertTrue(loaded.splitGroups.isEmpty)
        XCTAssertEqual(loaded.tabs.map(\.splitGroupID), [nil, nil])
    }

    func testWeightsParseFailureYieldsEmpty() {
        let record = SplitGroupRecord(id: "g", spaceID: "s", orderIndex: 0,
                                      weightsJSON: "not json")
        XCTAssertEqual(record.weights, [])
    }
}
