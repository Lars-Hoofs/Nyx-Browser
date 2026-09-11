import XCTest
@testable import NyxCore

final class HistoryStoreTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-history-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = HistoryStore(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - recordVisit round-trip

    func testRecordVisitInsertsNewEntry() throws {
        let date = Date(timeIntervalSince1970: 1000)
        try store.recordVisit(url: "https://example.com", title: "Example", at: date)
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].url, "https://example.com")
        XCTAssertEqual(recent[0].id, "https://example.com")
        XCTAssertEqual(recent[0].title, "Example")
        XCTAssertEqual(recent[0].visitCount, 1)
        XCTAssertEqual(recent[0].lastVisitedAt, date)
    }

    func testRecordVisitTwiceIncrementsCountAndRefreshesDate() throws {
        let first = Date(timeIntervalSince1970: 1000)
        let second = Date(timeIntervalSince1970: 2000)
        try store.recordVisit(url: "https://example.com", title: "Example", at: first)
        try store.recordVisit(url: "https://example.com", title: "Example", at: second)
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].visitCount, 2)
        XCTAssertEqual(recent[0].lastVisitedAt, second)
    }

    func testRecordVisitUpdatesTitleWhenNonEmpty() throws {
        try store.recordVisit(url: "https://example.com", title: "First Title",
                               at: Date(timeIntervalSince1970: 1000))
        try store.recordVisit(url: "https://example.com", title: "Second Title",
                               at: Date(timeIntervalSince1970: 2000))
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent[0].title, "Second Title")
    }

    func testRecordVisitKeepsExistingTitleWhenEmpty() throws {
        try store.recordVisit(url: "https://example.com", title: "Example",
                               at: Date(timeIntervalSince1970: 1000))
        try store.recordVisit(url: "https://example.com", title: "",
                               at: Date(timeIntervalSince1970: 2000))
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent[0].title, "Example")
        XCTAssertEqual(recent[0].visitCount, 2)
    }

    // MARK: - updateTitle semantics

    func testUpdateTitleUpdatesExistingEntry() throws {
        try store.recordVisit(url: "https://example.com", title: "Old",
                               at: Date(timeIntervalSince1970: 1000))
        try store.updateTitle(url: "https://example.com", title: "New")
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent[0].title, "New")
    }

    func testUpdateTitleNoOpWhenRowAbsent() throws {
        XCTAssertNoThrow(try store.updateTitle(url: "https://missing.com", title: "New"))
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }

    func testUpdateTitleNoOpWhenTitleEmpty() throws {
        try store.recordVisit(url: "https://example.com", title: "Old",
                               at: Date(timeIntervalSince1970: 1000))
        try store.updateTitle(url: "https://example.com", title: "")
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent[0].title, "Old")
    }

    // MARK: - search

    func testSearchMatchesTitleWord() throws {
        try store.recordVisit(url: "https://example.com", title: "Swift Programming", at: Date())
        try store.recordVisit(url: "https://other.com", title: "Unrelated", at: Date())
        let results = try store.search("Swift", limit: 10)
        XCTAssertEqual(results.map(\.url), ["https://example.com"])
    }

    func testSearchMatchesURLFragmentWithPrefix() throws {
        try store.recordVisit(url: "https://github.com", title: "GitHub", at: Date())
        try store.recordVisit(url: "https://gitlab.com", title: "GitLab", at: Date())
        let results = try store.search("gith", limit: 10)
        XCTAssertEqual(results.map(\.url), ["https://github.com"])
    }

    func testFrecencyRankingPrefersRecentFrequentEntry() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-60 * 60 * 24 * 365)   // 1 year ago
        let justNow = now.addingTimeInterval(-60)                    // 1 minute ago

        // Older but frequent: 20 visits, all a year ago.
        for _ in 0..<20 {
            try store.recordVisit(url: "https://old-frequent.com", title: "Widget", at: longAgo)
        }
        // Recent but rare: a single visit, one minute ago.
        try store.recordVisit(url: "https://new-rare.com", title: "Widget", at: justNow)
        // Recent AND frequent: 20 visits, all one minute ago.
        for _ in 0..<20 {
            try store.recordVisit(url: "https://new-frequent.com", title: "Widget", at: justNow)
        }

        let results = try store.search("Widget", limit: 10)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?.url, "https://new-frequent.com",
                       "a recent, frequently visited entry should outrank both an older-but-frequent " +
                       "and a recent-but-rare entry when text relevance is tied")
    }

    func testSearchAdversarialTokensDoNotThrow() throws {
        try store.recordVisit(url: "https://legal.example.com/terms",
                               title: "Terms and Conditions", at: Date())
        try store.recordVisit(url: "https://github.com", title: "GitHub", at: Date())
        try store.recordVisit(url: "https://gitlab.com", title: "GitLab", at: Date())

        // A bare reserved-keyword token, alone, must not crash the MATCH
        // query — before quoting, FTS5 parses uppercase AND as an
        // operator and throws `fts5: syntax error`.
        XCTAssertNoThrow(try store.search("AND", limit: 10))

        // The same keyword embedded in a phrase must still find the
        // seeded "Terms and Conditions" entry, case-insensitively (FTS5
        // tokenizes case-insensitively regardless of quoting).
        let phraseResults = try store.search("Terms AND Conditions", limit: 10)
        XCTAssertEqual(phraseResults.map(\.url), ["https://legal.example.com/terms"])

        // A second reserved keyword (OR) must not crash either. Quoting
        // neutralizes it into a literal token rather than honoring it as
        // a boolean-or operator, so an AND-of-three-literal-tokens query
        // matches nothing here — that's fine, the point is no throw.
        let orResults = try store.search("gith OR gitl", limit: 10)
        XCTAssertEqual(orResults, [])

        // A token containing a literal double quote must not let the
        // quote break out of its quoted FTS5 pattern.
        XCTAssertNoThrow(try store.search("say \"hi\"", limit: 10))

        // A lone '*' strips to nothing alphanumeric and must degrade to
        // an empty result rather than a malformed MATCH pattern.
        XCTAssertEqual(try store.search("*", limit: 10), [])

        // A punctuation-only query likewise leaves no tokens after
        // stripping.
        XCTAssertEqual(try store.search("!!!", limit: 10), [])
    }

    func testSearchRespectsLimitWithBestRankedFirst() throws {
        // 15 entries sharing identical text relevance ("Widget" matches
        // each equally) but distinct recency, so frecency alone decides
        // order and truncation is unambiguous to assert on.
        let now = Date()
        for i in 0..<15 {
            let visitedAt = now.addingTimeInterval(-Double(i) * 60)   // i minutes ago
            try store.recordVisit(url: "https://site\(i).com", title: "Widget", at: visitedAt)
        }

        let results = try store.search("Widget", limit: 5)
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.map(\.url), (0..<5).map { "https://site\($0).com" },
                       "the 5 most recently visited entries should win, most recent first")
    }

    // MARK: - recent()

    func testRecentOrdersByLastVisitedDescending() throws {
        try store.recordVisit(url: "https://a.com", title: "A", at: Date(timeIntervalSince1970: 1000))
        try store.recordVisit(url: "https://b.com", title: "B", at: Date(timeIntervalSince1970: 3000))
        try store.recordVisit(url: "https://c.com", title: "C", at: Date(timeIntervalSince1970: 2000))
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.url), ["https://b.com", "https://c.com", "https://a.com"])
    }

    func testRecentRespectsLimit() throws {
        for i in 0..<5 {
            try store.recordVisit(url: "https://site\(i).com", title: "Site \(i)",
                                   at: Date(timeIntervalSince1970: Double(i)))
        }
        let recent = try store.recent(limit: 2)
        XCTAssertEqual(recent.count, 2)
    }

    // MARK: - deleteAll

    func testDeleteAllRemovesEntries() throws {
        try store.recordVisit(url: "https://example.com", title: "Example", at: Date())
        try store.deleteAll()
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
        XCTAssertTrue(try store.search("Example", limit: 10).isEmpty)
    }

    // MARK: - migration / SessionStore facade interplay

    func testMigrationFromV2DataPreservedAndSessionStoreFacadeStillWorks() throws {
        // SessionStore(databaseURL:) must keep applying v1/v2 (session) AND
        // the new v3 (history) migration via the shared NyxDatabase, with
        // existing session data round-tripping unaffected by the new table.
        let sessionDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-session-v2-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: sessionDBURL) }

        let space = SpaceRecord(id: "s1", name: "Personal", orderIndex: 0)
        let tab = TabRecord(id: "t1", spaceID: "s1", urlString: "https://example.com",
                             title: "Example", orderIndex: 0, interactionState: nil,
                             lastActiveAt: Date(timeIntervalSince1970: 1000))
        let snapshot = SessionSnapshot(spaces: [space], tabs: [tab],
                                       selectedSpaceID: "s1", selectedTabID: "t1")
        try SessionStore(databaseURL: sessionDBURL).save(snapshot)

        // Reopen: v3 history migration must apply cleanly on top of existing v1/v2 data.
        let reopened = try SessionStore(databaseURL: sessionDBURL)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.tabs.map(\.id), ["t1"])

        // The database backing that facade also serves history via NyxDatabase(databaseURL:).
        let sharedDatabase = try NyxDatabase(databaseURL: sessionDBURL)
        let historyStore = HistoryStore(database: sharedDatabase)
        try historyStore.recordVisit(url: "https://example.com", title: "Example",
                                      at: Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(try historyStore.recent(limit: 10).count, 1)
    }

    func testSessionStoreDatabaseInitSharesUnderlyingDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-shared-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let sharedDatabase = try NyxDatabase(databaseURL: url)
        let sessionStore = SessionStore(database: sharedDatabase)
        let historyStore = HistoryStore(database: sharedDatabase)

        let snapshot = SessionSnapshot(spaces: [], tabs: [], selectedSpaceID: nil, selectedTabID: nil)
        try sessionStore.save(snapshot)
        try historyStore.recordVisit(url: "https://example.com", title: "Example", at: Date())

        XCTAssertEqual(try sessionStore.load().tabs.count, 0)
        XCTAssertEqual(try historyStore.recent(limit: 10).count, 1)
    }
}
