import XCTest
import GRDB
@testable import NyxCore

final class DownloadStoreTests: XCTestCase {
    private var dbURL: URL!
    private var database: NyxDatabase!
    private var store: DownloadStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-download-test-\(UUID().uuidString).sqlite")
        database = try NyxDatabase(databaseURL: dbURL)
        store = DownloadStore(database: database)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - round-trip

    func testUpsertThenAllRoundTripsFullRecord() throws {
        let record = DownloadRecord(
            id: "d1",
            url: "https://example.com/report.pdf",
            suggestedFilename: "report.pdf",
            destinationPath: "/tmp/report.pdf",
            state: .finished,
            bytesReceived: 1024,
            bytesExpected: 1024,
            resumeData: Data([0x01, 0x02, 0x03]),
            errorMessage: nil,
            startedAt: Date(timeIntervalSince1970: 1000),
            finishedAt: Date(timeIntervalSince1970: 1050))
        try store.upsert(record)
        let all = try store.all()
        XCTAssertEqual(all, [record])
    }

    func testUpsertThenAllRoundTripsWithoutOptionalFields() throws {
        let record = DownloadRecord(
            id: "d2",
            url: "https://example.com/file.zip",
            suggestedFilename: "file.zip",
            destinationPath: nil,
            state: .running,
            bytesReceived: 0,
            bytesExpected: -1,
            resumeData: nil,
            errorMessage: nil,
            startedAt: Date(timeIntervalSince1970: 2000),
            finishedAt: nil)
        try store.upsert(record)
        let all = try store.all()
        XCTAssertEqual(all, [record])
    }

    func testUpsertRoundTripsErrorMessageOnFailedRecord() throws {
        let record = DownloadRecord(
            id: "d3",
            url: "https://example.com/broken.zip",
            suggestedFilename: "broken.zip",
            destinationPath: nil,
            state: .failed,
            bytesReceived: 512,
            bytesExpected: 2048,
            resumeData: Data([0xAA]),
            errorMessage: "The network connection was lost.",
            startedAt: Date(timeIntervalSince1970: 3000),
            finishedAt: nil)
        try store.upsert(record)
        let all = try store.all()
        XCTAssertEqual(all, [record])
    }

    // MARK: - ordering

    func testAllOrdersNewestStartedAtFirst() throws {
        let oldest = DownloadRecord(id: "old", url: "https://example.com/a", suggestedFilename: "a",
                                     destinationPath: nil, state: .running, bytesReceived: 0,
                                     bytesExpected: -1, resumeData: nil, errorMessage: nil,
                                     startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let middle = DownloadRecord(id: "mid", url: "https://example.com/b", suggestedFilename: "b",
                                     destinationPath: nil, state: .running, bytesReceived: 0,
                                     bytesExpected: -1, resumeData: nil, errorMessage: nil,
                                     startedAt: Date(timeIntervalSince1970: 2000), finishedAt: nil)
        let newest = DownloadRecord(id: "new", url: "https://example.com/c", suggestedFilename: "c",
                                     destinationPath: nil, state: .running, bytesReceived: 0,
                                     bytesExpected: -1, resumeData: nil, errorMessage: nil,
                                     startedAt: Date(timeIntervalSince1970: 3000), finishedAt: nil)
        // Insert out of order to make the ORDER BY meaningful.
        try store.upsert(middle)
        try store.upsert(newest)
        try store.upsert(oldest)

        let all = try store.all()
        XCTAssertEqual(all.map(\.id), ["new", "mid", "old"])
    }

    // MARK: - upsert updates in place

    func testUpsertWithSameIDUpdatesInPlaceRatherThanInserting() throws {
        let running = DownloadRecord(id: "d1", url: "https://example.com/file", suggestedFilename: "file",
                                      destinationPath: nil, state: .running, bytesReceived: 100,
                                      bytesExpected: 1000, resumeData: nil, errorMessage: nil,
                                      startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        try store.upsert(running)

        var finished = running
        finished.state = .finished
        finished.bytesReceived = 1000
        finished.finishedAt = Date(timeIntervalSince1970: 1100)
        try store.upsert(finished)

        let all = try store.all()
        XCTAssertEqual(all.count, 1, "same id must update in place, not insert a second row")
        XCTAssertEqual(all, [finished])
    }

    // MARK: - delete

    func testDeleteRemovesRow() throws {
        let record = DownloadRecord(id: "d1", url: "https://example.com/file", suggestedFilename: "file",
                                     destinationPath: nil, state: .finished, bytesReceived: 10,
                                     bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                     startedAt: Date(timeIntervalSince1970: 1000),
                                     finishedAt: Date(timeIntervalSince1970: 1010))
        try store.upsert(record)
        try store.delete(id: "d1")
        XCTAssertTrue(try store.all().isEmpty)
    }

    func testDeleteOfUnknownIDIsNoOp() throws {
        XCTAssertNoThrow(try store.delete(id: "does-not-exist"))
        XCTAssertTrue(try store.all().isEmpty)
    }

    // MARK: - clearFinished

    func testClearFinishedRemovesFinishedAndCancelledOnly() throws {
        let finished = DownloadRecord(id: "finished", url: "https://example.com/a", suggestedFilename: "a",
                                       destinationPath: nil, state: .finished, bytesReceived: 1,
                                       bytesExpected: 1, resumeData: nil, errorMessage: nil,
                                       startedAt: Date(timeIntervalSince1970: 1000),
                                       finishedAt: Date(timeIntervalSince1970: 1001))
        let cancelled = DownloadRecord(id: "cancelled", url: "https://example.com/b", suggestedFilename: "b",
                                        destinationPath: nil, state: .cancelled, bytesReceived: 1,
                                        bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                        startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let running = DownloadRecord(id: "running", url: "https://example.com/c", suggestedFilename: "c",
                                      destinationPath: nil, state: .running, bytesReceived: 1,
                                      bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                      startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let failed = DownloadRecord(id: "failed", url: "https://example.com/d", suggestedFilename: "d",
                                     destinationPath: nil, state: .failed, bytesReceived: 1,
                                     bytesExpected: 10, resumeData: nil, errorMessage: "oops",
                                     startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let interrupted = DownloadRecord(id: "interrupted", url: "https://example.com/e", suggestedFilename: "e",
                                          destinationPath: nil, state: .interrupted, bytesReceived: 1,
                                          bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                          startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        for record in [finished, cancelled, running, failed, interrupted] {
            try store.upsert(record)
        }

        try store.clearFinished()

        let remainingIDs = Set(try store.all().map(\.id))
        XCTAssertEqual(remainingIDs, ["running", "failed", "interrupted"])
    }

    func testClearFinishedWithNoFinishedOrCancelledRowsIsNoOp() throws {
        let running = DownloadRecord(id: "running", url: "https://example.com/c", suggestedFilename: "c",
                                      destinationPath: nil, state: .running, bytesReceived: 1,
                                      bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                      startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        try store.upsert(running)
        try store.clearFinished()
        XCTAssertEqual(try store.all().map(\.id), ["running"])
    }

    // MARK: - interruptInFlight

    func testInterruptInFlightFlipsOnlyRunningRowsAndReturnsCount() throws {
        let running1 = DownloadRecord(id: "r1", url: "https://example.com/a", suggestedFilename: "a",
                                       destinationPath: nil, state: .running, bytesReceived: 1,
                                       bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                       startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let running2 = DownloadRecord(id: "r2", url: "https://example.com/b", suggestedFilename: "b",
                                       destinationPath: nil, state: .running, bytesReceived: 1,
                                       bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                       startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        let finished = DownloadRecord(id: "f1", url: "https://example.com/c", suggestedFilename: "c",
                                       destinationPath: nil, state: .finished, bytesReceived: 10,
                                       bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                       startedAt: Date(timeIntervalSince1970: 1000),
                                       finishedAt: Date(timeIntervalSince1970: 1010))
        let failed = DownloadRecord(id: "fa1", url: "https://example.com/d", suggestedFilename: "d",
                                     destinationPath: nil, state: .failed, bytesReceived: 1,
                                     bytesExpected: 10, resumeData: nil, errorMessage: "oops",
                                     startedAt: Date(timeIntervalSince1970: 1000), finishedAt: nil)
        for record in [running1, running2, finished, failed] {
            try store.upsert(record)
        }

        let count = try store.interruptInFlight()
        XCTAssertEqual(count, 2)

        let all = try store.all()
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.state) })
        XCTAssertEqual(byID["r1"], .interrupted)
        XCTAssertEqual(byID["r2"], .interrupted)
        XCTAssertEqual(byID["f1"], .finished)
        XCTAssertEqual(byID["fa1"], .failed)
    }

    func testInterruptInFlightReturnsZeroWhenNoRunningRows() throws {
        let finished = DownloadRecord(id: "f1", url: "https://example.com/c", suggestedFilename: "c",
                                       destinationPath: nil, state: .finished, bytesReceived: 10,
                                       bytesExpected: 10, resumeData: nil, errorMessage: nil,
                                       startedAt: Date(timeIntervalSince1970: 1000),
                                       finishedAt: Date(timeIntervalSince1970: 1010))
        try store.upsert(finished)
        XCTAssertEqual(try store.interruptInFlight(), 0)
        XCTAssertEqual(try store.all().map(\.state), [.finished])
    }

    // MARK: - v4 -> v5 populated migration

    func testV5MigrationPreservesHistorySessionAndSiteOverrideRowsAndDownloadTableWorks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-v4-to-v5-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build a v1-v4-only database by hand, mirroring NyxDatabase's own
        // migrations verbatim, and seed one row per pre-existing table —
        // exactly what a real install would have on disk before v5 ships.
        let legacyQueue = try DatabaseQueue(path: url.path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("v1") { db in
            try db.create(table: "space") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("orderIndex", .integer).notNull()
            }
            try db.create(table: "tab") { t in
                t.column("id", .text).primaryKey()
                t.column("spaceID", .text).notNull().indexed()
                    .references("space", onDelete: .cascade)
                t.column("urlString", .text).notNull()
                t.column("title", .text).notNull()
                t.column("orderIndex", .integer).notNull()
                t.column("interactionState", .blob)
                t.column("lastActiveAt", .datetime).notNull()
            }
            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
            }
        }
        legacyMigrator.registerMigration("v2") { db in
            try db.create(table: "split_group") { t in
                t.column("id", .text).primaryKey()
                t.column("spaceID", .text).notNull().indexed()
                    .references("space", onDelete: .cascade)
                t.column("orderIndex", .integer).notNull()
                t.column("weightsJSON", .text).notNull()
            }
            try db.alter(table: "tab") { t in
                t.add(column: "splitGroupID", .text)
                    .references("split_group", onDelete: .setNull)
            }
        }
        legacyMigrator.registerMigration("v3") { db in
            try db.create(table: "history_entry") { t in
                t.column("url", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("visitCount", .integer).notNull()
                t.column("lastVisitedAt", .datetime).notNull().indexed()
            }
            try db.create(virtualTable: "history_fts", using: FTS5()) { t in
                t.synchronize(withTable: "history_entry")
                t.column("url")
                t.column("title")
                t.tokenizer = .unicode61()
            }
        }
        legacyMigrator.registerMigration("v4") { db in
            try db.create(table: "site_override") { t in
                t.column("host", .text).primaryKey()
                t.column("adblockDisabled", .integer).notNull()
            }
            try db.drop(table: "history_fts")
            try db.dropFTS5SynchronizationTriggers(forTable: "history_fts")
            try db.create(virtualTable: "history_fts", using: FTS5()) { t in
                t.synchronize(withTable: "history_entry")
                t.column("url")
                t.column("title")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
            }
        }
        try legacyMigrator.migrate(legacyQueue)

        try legacyQueue.write { db in
            try db.execute(
                sql: "INSERT INTO space (id, name, orderIndex) VALUES (?, ?, ?)",
                arguments: ["s1", "Personal", 0])
            try db.execute(
                sql: """
                    INSERT INTO tab (id, spaceID, urlString, title, orderIndex, interactionState, lastActiveAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["t1", "s1", "https://example.com", "Example", 0, nil, Date(timeIntervalSince1970: 500)])
            try db.execute(
                sql: """
                    INSERT INTO history_entry (url, title, visitCount, lastVisitedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: ["https://github.com", "GitHub", 3, Date(timeIntervalSince1970: 12_345)])
            try db.execute(
                sql: "INSERT INTO site_override (host, adblockDisabled) VALUES (?, ?)",
                arguments: ["example.com", 1])
        }

        // Migrate-simulate: opening through the real NyxDatabase finds
        // v1-v4 already applied, so its migrator runs v5 (and only v5)
        // against this pre-existing data — the exact upgrade path a real
        // install takes.
        let database = try NyxDatabase(databaseURL: url)

        let historyStore = HistoryStore(database: database)
        XCTAssertEqual(try historyStore.recent(limit: 10).map(\.url), ["https://github.com"])

        let siteOverrideStore = SiteOverrideStore(database: database)
        XCTAssertTrue(try siteOverrideStore.isBlockingDisabled(host: "example.com"))

        try database.dbQueue.read { db in
            let title = try String.fetchOne(db, sql: "SELECT title FROM tab WHERE id = 't1'")
            XCTAssertEqual(title, "Example")
        }

        // The new download table must be usable immediately after this
        // migration path, on the same connection.
        let downloadStore = DownloadStore(database: database)
        let record = DownloadRecord(id: "d1", url: "https://example.com/file.zip",
                                     suggestedFilename: "file.zip", destinationPath: nil,
                                     state: .running, bytesReceived: 0, bytesExpected: -1,
                                     resumeData: nil, errorMessage: nil,
                                     startedAt: Date(timeIntervalSince1970: 99_999), finishedAt: nil)
        try downloadStore.upsert(record)
        XCTAssertEqual(try downloadStore.all(), [record])
    }
}
