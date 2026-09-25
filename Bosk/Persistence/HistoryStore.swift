import BoskCore
import Foundation
import SQLite3

/// Visited pages in a SQLite file, for command bar suggestions and the History list. An actor, so database
/// work never runs on the main thread.
actor HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private var recordStatement: OpaquePointer?
    private var searchStatement: OpaquePointer?
    private var titleStatement: OpaquePointer?
    private var removeStatement: OpaquePointer?

    private init() {
        let directory = Defaults.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("Bosk: history database did not open: %@", String(cString: sqlite3_errmsg(db)))
            db = nil
            return
        }
        Self.exec(db, "PRAGMA journal_mode = WAL")
        // Safe with WAL, and one fsync less for each visit.
        Self.exec(db, "PRAGMA synchronous = NORMAL")
        // Deleted history is written over with zeros, so it cannot be read back from the file.
        Self.exec(db, "PRAGMA secure_delete = ON")
        Self.exec(db, """
            CREATE TABLE IF NOT EXISTS history (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL
            )
            """)
        // Searches read the newest pages first and stop at 200 matches.
        Self.exec(db, "CREATE INDEX IF NOT EXISTS history_last_visit ON history (last_visit)")
        recordStatement = Self.prepare(db, """
            INSERT INTO history (url, title, visit_count, last_visit) VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(url) DO UPDATE SET
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                visit_count = visit_count + 1,
                last_visit = excluded.last_visit
            """)
        titleStatement = Self.prepare(db, "UPDATE history SET title = ?2 WHERE url = ?1 AND title != ?2")
        removeStatement = Self.prepare(db, "DELETE FROM history WHERE url = ?1")
        searchStatement = Self.prepare(db, """
            SELECT url, title, visit_count, last_visit FROM history
            WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
            ORDER BY last_visit DESC LIMIT 200
            """)
    }

    /// Deletes all history (Settings > Privacy).
    func clear() {
        Self.exec(db, "DELETE FROM history")
        // The WAL file also keeps old pages until a checkpoint.
        Self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Removes one page (right-click in the History list).
    func remove(url: URL) {
        guard let statement = removeStatement else { return }
        sqlite3_reset(statement)
        bind(statement, 1, url.absoluteString)
        sqlite3_step(statement)
    }

    /// Records one visit. Only web pages (http and https) go in history.
    func recordVisit(url: URL, title: String) {
        guard let statement = recordStatement, ["http", "https"].contains(url.scheme ?? "") else { return }
        sqlite3_reset(statement)
        bind(statement, 1, url.absoluteString)
        bind(statement, 2, title)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    /// Pages often set their title after they load; history keeps the latest one.
    func updateTitle(url: URL, title: String) {
        guard let statement = titleStatement, !title.isEmpty else { return }
        sqlite3_reset(statement)
        bind(statement, 1, url.absoluteString)
        bind(statement, 2, title)
        sqlite3_step(statement)
    }

    /// Pages whose address or title contains the first word of `query`.
    /// SuggestionRanker filters and orders them.
    func candidates(for query: String) -> [SuggestionRanker.HistoryItem] {
        guard let word = query.lowercased().split(separator: " ").first else { return [] }
        return pages(containing: String(word))
    }

    /// Deletes the pages last visited between the two dates (chrome.history and chrome.browsingData).
    func remove(from start: Date, to end: Date) {
        guard let statement = Self.prepare(db, "DELETE FROM history WHERE last_visit BETWEEN ?1 AND ?2") else { return }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, min(end, .distantFuture).timeIntervalSince1970)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    /// The History list: pages that contain the first word of `query`, or with no text,
    /// the newest pages. SuggestionRanker.historyRows filters and orders them.
    func visits(for query: String) -> [SuggestionRanker.HistoryItem] {
        pages(containing: query.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
    }

    /// The newest 200 pages whose address or title contains `word` (all pages for "").
    private func pages(containing word: String) -> [SuggestionRanker.HistoryItem] {
        guard let statement = searchStatement else { return [] }
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        sqlite3_reset(statement)
        bind(statement, 1, "%\(escaped)%")
        var items: [SuggestionRanker.HistoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0),
                  let url = URL(string: String(cString: urlText)) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            items.append(.init(url: url, title: title,
                               visitCount: Int(sqlite3_column_int(statement, 2)),
                               lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return items
    }

    // MARK: SQLite helpers

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Bosk: history SQL failed: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("Bosk: history SQL did not prepare: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        // SQLITE_TRANSIENT: SQLite copies the string.
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
