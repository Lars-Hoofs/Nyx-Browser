// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation
import GRDB

/// SQLite-backed download history (M6 spec §5.7/§6/§7): one row per
/// `WKDownload`, upserted on every state transition so a crash or quit
/// loses nothing but the in-flight bytes (see `interruptInFlight`). A thin
/// store over the shared `NyxDatabase` connection (v5 migration owns the
/// `download` table).
public final class DownloadStore {
    private let dbQueue: DatabaseQueue

    public init(database: NyxDatabase) {
        dbQueue = database.dbQueue
    }

    /// Inserts a new row, or replaces the existing row with the same
    /// `id` in place (same primary key — never a second row for the same
    /// download).
    public func upsert(_ record: DownloadRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO download (
                        id, url, suggestedFilename, destinationPath, state,
                        bytesReceived, bytesExpected, resumeData, errorMessage,
                        startedAt, finishedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        url = excluded.url,
                        suggestedFilename = excluded.suggestedFilename,
                        destinationPath = excluded.destinationPath,
                        state = excluded.state,
                        bytesReceived = excluded.bytesReceived,
                        bytesExpected = excluded.bytesExpected,
                        resumeData = excluded.resumeData,
                        errorMessage = excluded.errorMessage,
                        startedAt = excluded.startedAt,
                        finishedAt = excluded.finishedAt
                    """,
                arguments: [
                    record.id, record.url, record.suggestedFilename, record.destinationPath,
                    record.state.rawValue, record.bytesReceived, record.bytesExpected,
                    record.resumeData, record.errorMessage, record.startedAt, record.finishedAt
                ])
        }
    }

    /// Every download, newest `startedAt` first.
    public func all() throws -> [DownloadRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, url, suggestedFilename, destinationPath, state,
                           bytesReceived, bytesExpected, resumeData, errorMessage,
                           startedAt, finishedAt
                    FROM download
                    ORDER BY startedAt DESC
                    """)
            return rows.map(Self.record(from:))
        }
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM download WHERE id = ?", arguments: [id])
        }
    }

    /// Removes every `finished` and `cancelled` row; `running`, `failed`,
    /// and `interrupted` rows are left untouched.
    public func clearFinished() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM download WHERE state IN (?, ?)",
                arguments: [DownloadRecord.State.finished.rawValue,
                            DownloadRecord.State.cancelled.rawValue])
        }
    }

    /// Flips every `running` row to `interrupted` (spec §5.7: in-flight
    /// downloads die with the app, so anything still marked `running` at
    /// the next launch was abandoned mid-transfer). Returns the number of
    /// rows flipped.
    public func interruptInFlight() throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE download SET state = ? WHERE state = ?",
                arguments: [DownloadRecord.State.interrupted.rawValue,
                            DownloadRecord.State.running.rawValue])
            return db.changesCount
        }
    }

    private static func record(from row: Row) -> DownloadRecord {
        DownloadRecord(
            id: row["id"],
            url: row["url"],
            suggestedFilename: row["suggestedFilename"],
            destinationPath: row["destinationPath"],
            state: DownloadRecord.State(rawValue: row["state"]) ?? .interrupted,
            bytesReceived: row["bytesReceived"],
            bytesExpected: row["bytesExpected"],
            resumeData: row["resumeData"],
            errorMessage: row["errorMessage"],
            startedAt: row["startedAt"],
            finishedAt: row["finishedAt"])
    }
}
