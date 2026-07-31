import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryEvent: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date
    let eventType: String
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let position: Double
}

struct EditRule: Identifiable, Hashable {
    var id: Int64
    var artistMatch: String
    var trackMatch: String
    var albumMatch: String
    var artistTo: String
    var trackTo: String
    var albumTo: String

    /// A rule that replaces nothing — every target field empty. Saving an edit
    /// that matches the player's own metadata produces one, and storing it would
    /// only add a row that can never change anything.
    var isNoOp: Bool {
        artistTo.isEmpty && trackTo.isEmpty && albumTo.isEmpty
    }
}

struct PendingScrobble: Identifiable, Hashable {
    let id: Int64
    let artist: String
    let track: String
    let album: String
    let duration: Double
    let timestamp: Date
    var attempts: Int
    var lastError: String
}

actor HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Musique", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("history.db")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            NSLog("[HistoryStore] failed to open db at \(url.path)")
            db = nil
        }
        migrate()
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("[HistoryStore] exec error: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    private func migrate() {
        exec("""
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                event_type TEXT NOT NULL,
                track_name TEXT NOT NULL,
                artist_name TEXT NOT NULL,
                album_name TEXT,
                duration REAL,
                position REAL
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_time ON events(timestamp DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_events_track ON events(artist_name, track_name);")

        exec("""
            CREATE TABLE IF NOT EXISTS edit_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                artist_match TEXT NOT NULL,
                track_match TEXT NOT NULL DEFAULT '',
                album_match TEXT NOT NULL DEFAULT '',
                artist_to TEXT NOT NULL DEFAULT '',
                track_to TEXT NOT NULL DEFAULT '',
                album_to TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL
            );
            """)

        exec("""
            CREATE TABLE IF NOT EXISTS pending_scrobbles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                artist TEXT NOT NULL,
                track TEXT NOT NULL,
                album TEXT NOT NULL DEFAULT '',
                duration REAL NOT NULL DEFAULT 0,
                timestamp INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT NOT NULL DEFAULT ''
            );
            """)
    }

    // MARK: - Events

    func insertEvent(type: String, title: String, artist: String, album: String,
                     duration: Double, position: Double, at timestamp: Date = Date()) {
        guard let db else { return }
        let sql = "INSERT INTO events (timestamp, event_type, track_name, artist_name, album_name, duration, position) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(timestamp.timeIntervalSince1970))
        sqlite3_bind_text(stmt, 2, type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, artist, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, album, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 6, duration)
        sqlite3_bind_double(stmt, 7, position)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("[HistoryStore] insertEvent step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func recentEvents(limit: Int = 200) -> [HistoryEvent] {
        guard let db else { return [] }
        let sql = "SELECT id, timestamp, event_type, track_name, artist_name, album_name, duration, position FROM events ORDER BY timestamp DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [HistoryEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(HistoryEvent(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                eventType: readText(stmt, 2),
                trackName: readText(stmt, 3),
                artistName: readText(stmt, 4),
                albumName: readText(stmt, 5),
                duration: sqlite3_column_double(stmt, 6),
                position: sqlite3_column_double(stmt, 7)
            ))
        }
        return out
    }

    func eventsCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Edit rules

    func loadEditRules() -> [EditRule] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id, artist_match, track_match, album_match, artist_to, track_to, album_to FROM edit_history ORDER BY id ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [EditRule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(EditRule(
                id: sqlite3_column_int64(stmt, 0),
                artistMatch: readText(stmt, 1),
                trackMatch: readText(stmt, 2),
                albumMatch: readText(stmt, 3),
                artistTo: readText(stmt, 4),
                trackTo: readText(stmt, 5),
                albumTo: readText(stmt, 6)
            ))
        }
        return out
    }

    /// Drop every rule with the same match key, case-insensitively. Saving an
    /// edit for a track replaces its rule instead of stacking another one behind
    /// it: `loadEditRules` is ordered by id, `apply` takes the first match, so a
    /// duplicate left in place would shadow every later edit of that track.
    func deleteEditRules(artistMatch: String, trackMatch: String, albumMatch: String) {
        guard let db else { return }
        let sql = """
            DELETE FROM edit_history
            WHERE lower(artist_match) = lower(?)
              AND lower(track_match) = lower(?)
              AND lower(album_match) = lower(?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, artistMatch, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, trackMatch, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, albumMatch, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    @discardableResult
    func addEditRule(_ rule: EditRule) -> Int64 {
        guard let db else { return 0 }
        let sql = "INSERT INTO edit_history (artist_match, track_match, album_match, artist_to, track_to, album_to, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, rule.artistMatch, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, rule.trackMatch, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, rule.albumMatch, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, rule.artistTo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, rule.trackTo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, rule.albumTo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 7, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    func deleteEditRule(id: Int64) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM edit_history WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    // MARK: - Pending scrobbles

    @discardableResult
    func enqueuePendingScrobble(artist: String, track: String, album: String,
                                 duration: Double, timestamp: Date) -> Int64 {
        guard let db else { return 0 }
        let sql = "INSERT INTO pending_scrobbles (artist, track, album, duration, timestamp) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, artist, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, track, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, album, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, duration)
        sqlite3_bind_int64(stmt, 5, Int64(timestamp.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    func loadPendingScrobbles(limit: Int = 50) -> [PendingScrobble] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT id, artist, track, album, duration, timestamp, attempts, last_error FROM pending_scrobbles ORDER BY id ASC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [PendingScrobble] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PendingScrobble(
                id: sqlite3_column_int64(stmt, 0),
                artist: readText(stmt, 1),
                track: readText(stmt, 2),
                album: readText(stmt, 3),
                duration: sqlite3_column_double(stmt, 4),
                timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5))),
                attempts: Int(sqlite3_column_int64(stmt, 6)),
                lastError: readText(stmt, 7)
            ))
        }
        return out
    }

    func deletePendingScrobble(id: Int64) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM pending_scrobbles WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func markPendingFailure(id: Int64, error: String) {
        guard let db else { return }
        let sql = "UPDATE pending_scrobbles SET attempts = attempts + 1, last_error = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, error, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func pendingCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending_scrobbles;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - helpers

    private func readText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: raw)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
