import Foundation
import SQLite3
import CryptoKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed snapshot store with FTS5 full-text search.
///
/// Dedup strategy: a snapshot is keyed by (app, window_title, content_hash).
/// Re-seeing identical content only bumps `last_seen_at`, so a window left
/// open for an hour is one row, not 720.
public final class Store {

    public struct Snapshot {
        public let id: Int64
        public let app: String
        public let bundleId: String
        public let windowTitle: String
        public let content: String
        public let url: String
        public let capturedAt: String
        public let lastSeenAt: String

        public var oneLineSummary: String {
            let preview = content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(120)
            let location = url.isEmpty ? "" : " <\(url)>"
            return "[\(lastSeenAt)] \(app) — \(windowTitle)\(location) :: \(preview)"
        }
    }

    public struct Stats {
        public let snapshotCount: Int
        public let distinctApps: Int
        public let oldest: String?
        public let newest: String?
    }

    private var db: OpaquePointer?

    public init(dbPath: String) throws {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.openFailed(dbPath)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS snapshots (
                id            INTEGER PRIMARY KEY,
                app           TEXT NOT NULL,
                bundle_id     TEXT NOT NULL,
                window_title  TEXT NOT NULL,
                content       TEXT NOT NULL,
                url           TEXT NOT NULL DEFAULT '',
                content_hash  TEXT NOT NULL,
                captured_at   TEXT NOT NULL,
                last_seen_at  TEXT NOT NULL
            );
            """)
        try exec("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_snapshots_dedup
            ON snapshots(bundle_id, window_title, content_hash);
            """)
        try migrateAddURLColumnIfNeeded()
        try exec("""
            CREATE TABLE IF NOT EXISTS chronicles (
                id             INTEGER PRIMARY KEY,
                day            TEXT NOT NULL UNIQUE,
                summary        TEXT NOT NULL,
                snapshot_count INTEGER NOT NULL,
                created_at     TEXT NOT NULL
            );
            """)
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS snapshots_fts USING fts5(
                content, window_title, app,
                content=snapshots, content_rowid=id
            );
            """)
        // Keep FTS in sync with the base table.
        try exec("""
            CREATE TRIGGER IF NOT EXISTS snapshots_ai AFTER INSERT ON snapshots BEGIN
                INSERT INTO snapshots_fts(rowid, content, window_title, app)
                VALUES (new.id, new.content, new.window_title, new.app);
            END;
            """)
        try exec("""
            CREATE TRIGGER IF NOT EXISTS snapshots_ad AFTER DELETE ON snapshots BEGIN
                INSERT INTO snapshots_fts(snapshots_fts, rowid, content, window_title, app)
                VALUES ('delete', old.id, old.content, old.window_title, old.app);
            END;
            """)
    }

    deinit { sqlite3_close(db) }

    /// v1 databases predate the url column; add it in place.
    private func migrateAddURLColumnIfNeeded() throws {
        let stmt = try prepare("PRAGMA table_info(snapshots);")
        defer { sqlite3_finalize(stmt) }
        var hasURL = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == "url" { hasURL = true }
        }
        if !hasURL {
            try exec("ALTER TABLE snapshots ADD COLUMN url TEXT NOT NULL DEFAULT '';")
        }
    }

    // MARK: - Writes

    /// Insert a new snapshot, or bump last_seen_at when identical content
    /// for the same window already exists.
    public func upsert(app: String, bundleId: String, windowTitle: String, content: String, url: String = "") throws {
        let hash = Store.sha256(content)
        let now = Store.timestamp()
        let sql = """
            INSERT INTO snapshots
                (app, bundle_id, window_title, content, url, content_hash, captured_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bundle_id, window_title, content_hash)
            DO UPDATE SET last_seen_at = excluded.last_seen_at, url = excluded.url;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, app, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, bundleId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, windowTitle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, hash, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, now, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
    }

    // MARK: - Reads

    public func recent(minutes: Int) throws -> [Snapshot] {
        let sql = """
            SELECT id, app, bundle_id, window_title, content, url, captured_at, last_seen_at
            FROM snapshots
            WHERE last_seen_at >= datetime('now', 'localtime', ?)
            ORDER BY last_seen_at DESC, id DESC
            LIMIT 50;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "-\(minutes) minutes", -1, SQLITE_TRANSIENT)
        return readSnapshots(stmt)
    }

    public func search(_ terms: String, limit: Int) throws -> [Snapshot] {
        let sql = """
            SELECT s.id, s.app, s.bundle_id, s.window_title, s.content, s.url,
                   s.captured_at, s.last_seen_at
            FROM snapshots_fts f
            JOIN snapshots s ON s.id = f.rowid
            WHERE snapshots_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        // Quote each term to keep FTS5 syntax characters from breaking queries.
        let quoted = terms
            .split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " ")
        sqlite3_bind_text(stmt, 1, quoted, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        return readSnapshots(stmt)
    }

    public func getSnapshot(id: Int64) throws -> Snapshot? {
        let sql = """
            SELECT id, app, bundle_id, window_title, content, url, captured_at, last_seen_at
            FROM snapshots
            WHERE id = ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return readSnapshots(stmt).first
    }

    /// All snapshots seen on a given local day (YYYY-MM-DD), oldest first —
    /// chronological order suits summarization.
    func snapshotsForDay(_ day: String) throws -> [Snapshot] {
        let sql = """
            SELECT id, app, bundle_id, window_title, content, url, captured_at, last_seen_at
            FROM snapshots
            WHERE date(last_seen_at) = ? OR date(captured_at) = ?
            ORDER BY last_seen_at ASC;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, day, -1, SQLITE_TRANSIENT)
        return readSnapshots(stmt)
    }

    /// Delete raw snapshots not seen for `olderThanDays` days. Chronicles
    /// live in their own table and survive pruning. Returns rows deleted.
    /// The FTS delete-trigger keeps the search index in sync.
    public func prune(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        let sql = """
            DELETE FROM snapshots
            WHERE last_seen_at < datetime('now', 'localtime', ?);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "-\(days) days", -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
        return Int(sqlite3_changes(db))
    }

    /// Snapshot count for one local day (YYYY-MM-DD) — cheap, for UI.
    public func countForDay(_ day: String) throws -> Int {
        let stmt = try prepare(
            "SELECT COUNT(*) FROM snapshots WHERE date(last_seen_at) = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Chronicles

    public struct Chronicle {
        public let day: String
        public let summary: String
        public let snapshotCount: Int
        public let createdAt: String
    }

    public func upsertChronicle(day: String, summary: String, snapshotCount: Int) throws {
        let sql = """
            INSERT INTO chronicles (day, summary, snapshot_count, created_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET
                summary = excluded.summary,
                snapshot_count = excluded.snapshot_count,
                created_at = excluded.created_at;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, summary, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(snapshotCount))
        sqlite3_bind_text(stmt, 4, Store.timestamp(), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
    }

    public func getChronicle(day: String) throws -> Chronicle? {
        let stmt = try prepare(
            "SELECT day, summary, snapshot_count, created_at FROM chronicles WHERE day = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, day, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Chronicle(
            day: columnText(stmt, 0) ?? "",
            summary: columnText(stmt, 1) ?? "",
            snapshotCount: Int(sqlite3_column_int(stmt, 2)),
            createdAt: columnText(stmt, 3) ?? ""
        )
    }

    public func listChronicles(limit: Int = 30) throws -> [Chronicle] {
        let stmt = try prepare("""
            SELECT day, summary, snapshot_count, created_at FROM chronicles
            ORDER BY day DESC LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [Chronicle] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Chronicle(
                day: columnText(stmt, 0) ?? "",
                summary: columnText(stmt, 1) ?? "",
                snapshotCount: Int(sqlite3_column_int(stmt, 2)),
                createdAt: columnText(stmt, 3) ?? ""
            ))
        }
        return rows
    }

    public func stats() throws -> Stats {
        let stmt = try prepare("""
            SELECT COUNT(*), COUNT(DISTINCT bundle_id), MIN(captured_at), MAX(last_seen_at)
            FROM snapshots;
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StoreError.stepFailed(message: lastErrorMessage())
        }
        return Stats(
            snapshotCount: Int(sqlite3_column_int(stmt, 0)),
            distinctApps: Int(sqlite3_column_int(stmt, 1)),
            oldest: columnText(stmt, 2),
            newest: columnText(stmt, 3)
        )
    }

    // MARK: - Helpers

    private func readSnapshots(_ stmt: OpaquePointer?) -> [Snapshot] {
        var rows: [Snapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Snapshot(
                id: sqlite3_column_int64(stmt, 0),
                app: columnText(stmt, 1) ?? "",
                bundleId: columnText(stmt, 2) ?? "",
                windowTitle: columnText(stmt, 3) ?? "",
                content: columnText(stmt, 4) ?? "",
                url: columnText(stmt, 5) ?? "",
                capturedAt: columnText(stmt, 6) ?? "",
                lastSeenAt: columnText(stmt, 7) ?? ""
            ))
        }
        return rows
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(sql: sql, message: lastErrorMessage())
        }
        return stmt
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.execFailed(sql: sql, message: lastErrorMessage())
        }
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

enum StoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(sql: String, message: String)
    case execFailed(sql: String, message: String)
    case stepFailed(message: String)

    var description: String {
        switch self {
        case .openFailed(let path): return "could not open database at \(path)"
        case .prepareFailed(_, let message): return "prepare failed: \(message)"
        case .execFailed(_, let message): return "exec failed: \(message)"
        case .stepFailed(let message): return "step failed: \(message)"
        }
    }
}
