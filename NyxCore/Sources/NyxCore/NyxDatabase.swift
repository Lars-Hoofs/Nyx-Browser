// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation
import GRDB

/// Owns the single GRDB connection (and its migrator) shared by every
/// NyxCore store. `SessionStore` and `HistoryStore` are thin facades over
/// one `NyxDatabase` so the app opens exactly one `nyx.sqlite` connection.
///
/// The v1/v2 migrations below were moved here verbatim from
/// `SessionStore` (never retyped) when `NyxDatabase` took over migration
/// ownership; v3 (history) was appended after them.
public final class NyxDatabase {
    let dbQueue: DatabaseQueue

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
        migrator.registerMigration("v2") { db in
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
        // v3 (M4): browsing history, with an FTS5 index kept in sync via
        // GRDB's external-content triggers.
        //
        // Adaptation: GRDB's `synchronize(withTable:)` derives its
        // `content_rowid` from the content table's primary key. A TEXT
        // primary key (`url`) is not a rowid alias, so GRDB falls back to
        // the table's implicit `rowid` — which works, since `history_entry`
        // is an ordinary (non-`WITHOUT ROWID`) table and always has one.
        // No autoincrement id column was needed; recorded here per the
        // brief's instruction to note the adaptation either way.
        //
        // Caveat: relying on the implicit rowid means anything that could
        // renumber it (e.g. a future VACUUM/"compact database" feature)
        // would need to re-verify this join — only HistoryStore.search()'s
        // history_fts.rowid == history_entry.rowid join depends on it
        // today; every other HistoryStore path is keyed by `url`, so it's
        // unaffected. Revisit this note before adding such a feature.
        migrator.registerMigration("v3") { db in
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
        return migrator
    }
}
