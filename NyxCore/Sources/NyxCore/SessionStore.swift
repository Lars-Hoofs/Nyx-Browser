import Foundation
import GRDB

/// SQLite-backed session persistence (spec §4): WAL mode for crash
/// safety; save() is a full transactional replace — session scale is
/// tens of rows, so simplicity beats delta updates.
///
/// A thin facade over `NyxDatabase`, which owns the connection and the
/// migrator (v1/v2/v3). `SessionStore(databaseURL:)` builds its own
/// private `NyxDatabase`; `SessionStore(database:)` shares one already
/// opened elsewhere (e.g. with a `HistoryStore`) — the path the app uses
/// from M4 on so session and history live on one connection.
public final class SessionStore {
    private let database: NyxDatabase
    private var dbQueue: DatabaseQueue { database.dbQueue }

    public init(databaseURL: URL) throws {
        database = try NyxDatabase(databaseURL: databaseURL)
    }

    public init(database: NyxDatabase) {
        self.database = database
    }

    public func load() throws -> SessionSnapshot {
        try dbQueue.read { db in
            let spaces = try SpaceRecord.order(Column("orderIndex")).fetchAll(db)
            let tabs = try TabRecord.order(Column("orderIndex")).fetchAll(db)
            let splitGroups = try SplitGroupRecord.order(Column("orderIndex")).fetchAll(db)
            let selectedSpaceID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedSpaceID'")
            let selectedTabID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedTabID'")
            return SessionSnapshot(spaces: spaces, tabs: tabs,
                                   splitGroups: splitGroups,
                                   selectedSpaceID: selectedSpaceID,
                                   selectedTabID: selectedTabID)
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tab")
            try db.execute(sql: "DELETE FROM split_group")
            try db.execute(sql: "DELETE FROM space")
            for space in snapshot.spaces { try space.insert(db) }
            for group in snapshot.splitGroups { try group.insert(db) }
            for tab in snapshot.tabs { try tab.insert(db) }
            try db.execute(sql: "DELETE FROM meta")
            if let id = snapshot.selectedSpaceID {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('selectedSpaceID', ?)",
                               arguments: [id])
            }
            if let id = snapshot.selectedTabID {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('selectedTabID', ?)",
                               arguments: [id])
            }
        }
    }

    public func updateInteractionState(tabID: String, data: Data?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tab SET interactionState = ? WHERE id = ?",
                           arguments: [data, tabID])
        }
    }
}
