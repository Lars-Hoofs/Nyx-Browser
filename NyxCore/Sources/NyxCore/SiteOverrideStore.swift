// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation
import GRDB

/// Per-site adblock overrides (M5 spec): blocking defaults to ON for
/// every host, so `site_override` only ever holds a row for a host where
/// the user has explicitly switched blocking OFF — there is no "enabled"
/// row to keep in sync with the default. Host keys are always lowercased
/// on write and on lookup so callers never have to normalize case
/// themselves (`Example.COM` and `example.com` refer to the same row).
/// A thin store over the shared `NyxDatabase` connection (v4 migration
/// owns the `site_override` table).
public final class SiteOverrideStore {
    private let dbQueue: DatabaseQueue

    public init(database: NyxDatabase) {
        dbQueue = database.dbQueue
    }

    /// Whether adblocking is disabled for `host`. Defaults to `false`
    /// (blocking ON) when no override row exists.
    public func isBlockingDisabled(host: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT adblockDisabled FROM site_override WHERE host = ?",
                arguments: [Self.normalize(host)]) ?? false
        }
    }

    /// Sets whether adblocking is disabled for `host`. Since blocking ON
    /// is the default, re-enabling (`disabled == false`) deletes the
    /// override row instead of writing a redundant "enabled" marker.
    public func setBlockingDisabled(_ disabled: Bool, host: String) throws {
        let normalizedHost = Self.normalize(host)
        try dbQueue.write { db in
            if disabled {
                try db.execute(
                    sql: """
                        INSERT INTO site_override (host, adblockDisabled) VALUES (?, 1)
                        ON CONFLICT(host) DO UPDATE SET adblockDisabled = 1
                        """,
                    arguments: [normalizedHost])
            } else {
                try db.execute(sql: "DELETE FROM site_override WHERE host = ?",
                               arguments: [normalizedHost])
            }
        }
    }

    /// Every host currently overridden to blocking-OFF.
    public func disabledHosts() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT host FROM site_override ORDER BY host")
        }
    }

    private static func normalize(_ host: String) -> String {
        host.lowercased()
    }
}
