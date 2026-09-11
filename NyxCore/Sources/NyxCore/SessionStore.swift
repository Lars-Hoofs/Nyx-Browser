import Foundation
import GRDB

/// SQLite-backed session persistence (spec §4): WAL mode for crash
/// safety; save() is a full transactional replace — session scale is
/// tens of rows, so simplicity beats delta updates.
public final class SessionStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
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
        return migrator
    }

    public func load() throws -> SessionSnapshot {
        try dbQueue.read { db in
            let spaces = try SpaceRecord.order(Column("orderIndex")).fetchAll(db)
            let tabs = try TabRecord.order(Column("orderIndex")).fetchAll(db)
            let selectedSpaceID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedSpaceID'")
            let selectedTabID = try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'selectedTabID'")
            return SessionSnapshot(spaces: spaces, tabs: tabs,
                                   selectedSpaceID: selectedSpaceID,
                                   selectedTabID: selectedTabID)
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tab")
            try db.execute(sql: "DELETE FROM space")
            for space in snapshot.spaces { try space.insert(db) }
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
