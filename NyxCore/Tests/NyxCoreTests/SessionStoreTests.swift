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
}
