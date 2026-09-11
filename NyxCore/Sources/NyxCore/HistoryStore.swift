// NyxCore is a plain Swift/Foundation module: it never imports AppKit,
// SwiftUI, or WebKit. Keep UI- and WebKit-facing code in the app target.

import Foundation
import GRDB

/// A single browsing-history row (M4 spec). `id` mirrors `url` — the url
/// string is the natural unique key for a history entry, so there is no
/// separate synthetic identifier.
public struct HistoryEntry: Codable, Equatable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisitedAt: Date

    public init(url: String, title: String, visitCount: Int, lastVisitedAt: Date) {
        self.id = url
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }
}

/// SQLite-backed browsing history (M4 spec): upsert-on-visit, FTS5 prefix
/// search over url+title tokens, ranked by a frecency score that blends
/// text relevance with recency/frequency. A thin store over the shared
/// `NyxDatabase` connection (v3 migration owns `history_entry` and its
/// `history_fts` mirror).
public final class HistoryStore {
    private let dbQueue: DatabaseQueue

    /// Half-life (in days) of the recency decay: a visit this old counts
    /// for half the frecency weight of a visit "now" at the same
    /// visitCount. Tunable; the TDD contract only pins ordering
    /// properties (recent+frequent beats older-frequent and recent-rare),
    /// not this constant.
    private static let recencyHalfLifeDays = 7.0

    /// Weight given to the frecency term relative to text relevance
    /// (bm25) when both are folded into one ranking score. At this
    /// weight, a sufficiently frequent/recent row CAN outrank a rarer
    /// row with a stronger textual match — that's by design within the
    /// FTS-matched set (all candidates already matched the query; among
    /// them, frecency is meant to dominate so a site you visit
    /// constantly and recently surfaces first even when its text match
    /// is weaker than another candidate's).
    private static let frecencyWeight = 2.0

    public init(database: NyxDatabase) {
        dbQueue = database.dbQueue
    }

    public func recordVisit(url: String, title: String, at date: Date) throws {
        try dbQueue.write { db in
            let existingCount = try Int.fetchOne(
                db, sql: "SELECT visitCount FROM history_entry WHERE url = ?", arguments: [url])
            if let existingCount {
                if title.isEmpty {
                    try db.execute(
                        sql: "UPDATE history_entry SET visitCount = ?, lastVisitedAt = ? WHERE url = ?",
                        arguments: [existingCount + 1, date, url])
                } else {
                    try db.execute(
                        sql: """
                            UPDATE history_entry
                            SET visitCount = ?, lastVisitedAt = ?, title = ?
                            WHERE url = ?
                            """,
                        arguments: [existingCount + 1, date, title, url])
                }
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO history_entry (url, title, visitCount, lastVisitedAt)
                        VALUES (?, ?, 1, ?)
                        """,
                    arguments: [url, title, date])
            }
        }
    }

    public func updateTitle(url: String, title: String) throws {
        guard !title.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE history_entry SET title = ? WHERE url = ?",
                           arguments: [title, url])
        }
    }

    /// FTS5 prefix match over url+title tokens, ranked by bm25 blended
    /// with frecency (visitCount weighted by exponential decay on visit
    /// age). Both signals are normalized onto comparable scales before
    /// combining so neither one alone determines order: bm25 in SQLite is
    /// negative (more negative = more relevant), so `-rank` turns it into
    /// a positive relevance score; frecency is `visitCount * decay(age)`.
    /// `score = -bm25Rank + frecencyWeight * frecency`.
    public func search(_ query: String, limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        guard let pattern = Self.ftsPrefixPattern(for: query) else { return [] }
        return try dbQueue.read { db in
            let sql = """
                SELECT h.url AS url, h.title AS title, h.visitCount AS visitCount,
                       h.lastVisitedAt AS lastVisitedAt, bm25(history_fts) AS rank
                FROM history_fts
                JOIN history_entry h ON h.rowid = history_fts.rowid
                WHERE history_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            // Over-fetch so frecency re-ranking (below) can promote a
            // recent/frequent row that bm25 alone ranked past `limit`.
            let overFetchLimit = max(limit * 5, 50)
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern, overFetchLimit])
            let now = Date()
            let scored: [(entry: HistoryEntry, score: Double)] = rows.map { row in
                let entry = HistoryEntry(url: row["url"], title: row["title"],
                                         visitCount: row["visitCount"],
                                         lastVisitedAt: row["lastVisitedAt"])
                let bm25Rank: Double = row["rank"]
                let relevance = -bm25Rank
                let frecency = Self.frecency(visitCount: entry.visitCount,
                                             lastVisitedAt: entry.lastVisitedAt, now: now)
                return (entry, relevance + Self.frecencyWeight * frecency)
            }
            return scored
                .sorted { $0.score > $1.score }
                .prefix(limit)
                .map(\.entry)
        }
    }

    public func recent(limit: Int) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT url, title, visitCount, lastVisitedAt
                    FROM history_entry
                    ORDER BY lastVisitedAt DESC
                    LIMIT ?
                    """,
                arguments: [limit])
            return rows.map {
                HistoryEntry(url: $0["url"], title: $0["title"],
                            visitCount: $0["visitCount"], lastVisitedAt: $0["lastVisitedAt"])
            }
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM history_entry")
        }
    }

    /// visitCount weighted by an exponential decay on visit age, so a
    /// frequently visited page's frecency fades as it goes stale rather
    /// than accumulating unbounded relevance forever.
    private static func frecency(visitCount: Int, lastVisitedAt: Date, now: Date) -> Double {
        let ageInDays = max(0, now.timeIntervalSince(lastVisitedAt)) / 86400
        let decay = exp(-ageInDays / recencyHalfLifeDays)
        return Double(visitCount) * decay
    }

    /// Builds an FTS5 MATCH pattern that prefix-matches every
    /// whitespace-separated token in `query` (implicit AND between
    /// tokens), so "gith" finds "github.com" and "swift prog" finds
    /// "Swift Programming". Non-alphanumeric characters are stripped from
    /// each token before it's quoted, both to keep FTS5 query syntax from
    /// choking on stray punctuation and because the unicode61 tokenizer
    /// already splits on it (e.g. "github.com" tokenizes to "github", "com").
    ///
    /// Every token is double-quoted before the trailing `*` (`"token"*`
    /// rather than bare `token*`): FTS5 treats unquoted uppercase `AND`,
    /// `OR`, and `NOT` as query operators, not literal terms, so a search
    /// for e.g. "Terms AND Conditions" would otherwise throw `fts5: syntax
    /// error` on the bare `AND` token. Quoting forces every token to be
    /// treated as a literal string regardless of casing. Embedded double
    /// quotes are doubled (`"` -> `""`, FTS5's own escaping convention) so
    /// a token can't break out of its quoted string — the alphanumeric
    /// split above already makes this unreachable today, but it's cheap
    /// insurance against a future change to the tokenization.
    private static func ftsPrefixPattern(for query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        guard !tokens.isEmpty else { return nil }
        return tokens.joined(separator: " ")
    }
}
