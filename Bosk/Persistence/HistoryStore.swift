import BoskCore
import Foundation
import SQLite3

/// Visited pages in a SQLite file, for command bar suggestions. An actor, so database
/// work never runs on the main thread.
actor HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private var recordStatement: OpaquePointer?
    private var searchStatement: OpaquePointer?
    private var titleStatement: OpaquePointer?

    private init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Bosk", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            NSLog("Bosk: history database did not open: %@", String(cString: sqlite3_errmsg(db)))
            db = nil
            return
        }
        Self.exec(db, "PRAGMA journal_mode = WAL")
        Self.exec(db, """
            CREATE TABLE IF NOT EXISTS history (
                url TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                visit_count INTEGER NOT NULL DEFAULT 0,
                last_visit REAL NOT NULL
            )
            """)
        recordStatement = Self.prepare(db, """
            INSERT INTO history (url, title, visit_count, last_visit) VALUES (?1, ?2, 1, ?3)
            ON CONFLICT(url) DO UPDATE SET
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                visit_count = visit_count + 1,
                last_visit = excluded.last_visit
            """)
        titleStatement = Self.prepare(db, "UPDATE history SET title = ?2 WHERE url = ?1")
        searchStatement = Self.prepare(db, """
            SELECT url, title, visit_count, last_visit FROM history
            WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
            ORDER BY last_visit DESC LIMIT 200
            """)
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
        guard let statement = searchStatement,
              let word = query.lowercased().split(separator: " ").first else { return [] }
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
