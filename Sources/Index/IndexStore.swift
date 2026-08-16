//
//  IndexStore.swift
//  Hourglass
//
//  Opens (or creates) the local FTS5 mirror at
//  `~/Library/Application Support/Hourglass/index.sqlite`. Owns the
//  schema and exposes a `DatabaseQueue` for the rest of the index pipeline.
//
//  The mirror file is OUR file — we own the schema, can migrate it, and can
//  blow it away on schema-version mismatch. It exists purely as an
//  optimization over chat.db; the rest of the app must continue to work if
//  this file is missing, corrupted, or behind.
//
//  Schema
//  ------
//  - `messages_fts` (FTS5 virtual table, trigram tokenizer) — the body index.
//    Trigram is chosen over unicode61 because the existing INSTR keyword path
//    that users rely on does byte-substring matching ("cactus" matches inside
//    "cactuscompute"). unicode61 tokenizes on word boundaries and silently
//    drops these. See `docs/search-design.md` § Q1 for the head-to-head
//    coverage numbers.
//  - `message_meta` — the denormalized side table for filter pushdown. We
//    mirror the date, sender, chat_id, and flags so we can run a date / chat
//    / sender filtered query without joining back to chat.db. Cross-DB joins
//    still work (chat.db is ATTACHed read-only) — but most queries are
//    answerable from the mirror alone.
//  - `index_state` — versioning + last-indexed ROWID bookkeeping.
//
//  The FTS5 rowid equals `message.ROWID` in chat.db. This lets us join the
//  index to chat.db rows by `messages_fts.rowid = chat_db.message.ROWID`.
//

import Foundation
import GRDB

public final class IndexStore: @unchecked Sendable {

    /// Bump this when the schema changes. On mismatch we blow the file away
    /// and reindex from scratch — cheap (~10s) and avoids ad-hoc migration
    /// bugs.
    public static let schemaVersion: Int = 2

    /// State bookkeeping keys stored in the `index_state` table.
    public enum StateKey: String {
        case schemaVersion = "schema_version"
        /// Highest source `message.ROWID` we've successfully indexed. The
        /// incremental sync polls `SELECT MAX(ROWID)` against chat.db and
        /// ingests anything strictly greater than this value.
        case lastIndexedROWID = "last_indexed_rowid"
        /// Wall-clock timestamp (ISO-8601) of the most recent full reindex.
        /// Diagnostic only.
        case lastFullReindexAt = "last_full_reindex_at"
        /// Highest source ROWID represented by the conversation-window
        /// index. This is intentionally separate from `lastIndexedROWID`:
        /// message FTS may be ready a few seconds before window construction
        /// finishes, and hybrid search must not read a half-built corpus.
        case lastWindowedROWID = "last_windowed_rowid"
    }

    public enum OpenError: Error, CustomStringConvertible {
        case storageDirectoryUnavailable(URL, underlying: Error)
        case openFailed(URL, underlying: Error)

        public var description: String {
            switch self {
            case .storageDirectoryUnavailable(let url, let err):
                return "Could not create index directory at \(url.path): \(err)"
            case .openFailed(let url, let err):
                return "Could not open index DB at \(url.path): \(err)"
            }
        }
    }

    public let dbQueue: DatabaseQueue
    public let url: URL

    /// Default location of the index file. Lives in Application Support so it
    /// survives app updates and isn't backed up to iCloud Documents.
    public static var defaultURL: URL {
        let fm = FileManager.default
        let appSupport: URL
        if let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = dir
        } else {
            appSupport = fm.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        }
        return appSupport
            .appending(path: "Hourglass", directoryHint: .isDirectory)
            .appending(path: "index.sqlite", directoryHint: .notDirectory)
    }

    /// Open the index DB at `url`, creating the parent directory and bootstrapping
    /// the schema if needed. If the on-disk schema version doesn't match
    /// `schemaVersion` we delete the file and rebuild — Phase 1 has no real
    /// migrations to write yet, so a forced rebuild is the simpler correct
    /// answer.
    public init(url: URL = IndexStore.defaultURL) throws {
        self.url = url

        // Ensure the parent dir exists. `Application Support/` itself is
        // created lazily by macOS for first-time apps.
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw OpenError.storageDirectoryUnavailable(parent, underlying: error)
        }

        // Open (or create) the DB.
        var config = Configuration()
        config.busyMode = .timeout(2.0)
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw OpenError.openFailed(url, underlying: error)
        }
        self.dbQueue = queue

        // Bootstrap: create tables if missing, check schema version, rebuild on
        // mismatch. We do this in a single write transaction so partial-create
        // crashes don't leave the file in an unusable state.
        do {
            try bootstrap()
        } catch {
            // If bootstrap fails (corrupt file, etc.), we leave the failure
            // visible — the caller will see a thrown error and fall back to
            // INSTR. We don't auto-delete here; the user might have a backup
            // expectation. The caller (IndexBuilder) handles the
            // delete-and-retry policy.
            throw OpenError.openFailed(url, underlying: error)
        }
    }

    // MARK: - Bootstrap

    /// Create the schema if missing. Throws if a schema mismatch is detected
    /// and we couldn't auto-recover.
    private func bootstrap() throws {
        try dbQueue.write { db in
            // index_state (always — used to check version).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS index_state (
                    key TEXT PRIMARY KEY,
                    value TEXT
                )
            """)

            let storedVersion: Int? = try Int.fetchOne(
                db,
                sql: "SELECT value FROM index_state WHERE key = ?",
                arguments: [StateKey.schemaVersion.rawValue]
            )

            if let v = storedVersion, v != IndexStore.schemaVersion {
                // Wipe everything and recreate.
                try db.execute(sql: "DROP TABLE IF EXISTS window_member")
                try db.execute(sql: "DROP TABLE IF EXISTS window_fts")
                try db.execute(sql: "DROP TABLE IF EXISTS conversation_window")
                try db.execute(sql: "DROP TABLE IF EXISTS messages_fts")
                try db.execute(sql: "DROP TABLE IF EXISTS message_meta")
                try db.execute(sql: "DELETE FROM index_state")
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                    body,
                    tokenize = 'trigram remove_diacritics 1'
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS message_meta (
                    rowid INTEGER PRIMARY KEY,
                    guid TEXT,
                    date INTEGER NOT NULL,
                    is_from_me INTEGER NOT NULL,
                    chat_id INTEGER,
                    handle_id INTEGER,
                    associated_message_type INTEGER NOT NULL DEFAULT 0,
                    has_attachment INTEGER NOT NULL DEFAULT 0,
                    balloon_bundle_id TEXT
                )
            """)
            // Indexes for the common filter pushdowns. date is the hot one
            // (every query is bounded by date one way or another).
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_date ON message_meta(date)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_chat ON message_meta(chat_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_handle ON message_meta(handle_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_meta_type ON message_meta(associated_message_type)")
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_meta_window_order
                ON message_meta(associated_message_type, chat_id, date, rowid)
            """)

            // Generic semantic retrieval unit. A window is a short,
            // session-bounded exchange (up to eight turns, overlapping by
            // four). Text lives in a trigram FTS table; exact scope metadata
            // and the normalized Float16 Apple word-embedding live beside it.
            // Float16 vectors stay as BLOBs beside compact sign-bit hashes.
            // Search streams only hashes, then decodes a bounded exact-cosine
            // shortlist, so the complete corpus is never resident in RAM.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_window (
                    id INTEGER PRIMARY KEY,
                    chat_id INTEGER NOT NULL,
                    start_date INTEGER NOT NULL,
                    end_date INTEGER NOT NULL,
                    anchor_rowid INTEGER NOT NULL,
                    message_count INTEGER NOT NULL,
                    has_from_me INTEGER NOT NULL DEFAULT 0,
                    has_from_other INTEGER NOT NULL DEFAULT 0,
                    embedding BLOB,
                    embedding_hash BLOB,
                    embedding_dimensions INTEGER NOT NULL DEFAULT 0
                )
            """)
            // Additive schema-v2 migration for early development builds that
            // created the dense-vector column before the compact binary ANN
            // signature was introduced. This does not invalidate message or
            // window FTS and therefore must not force a 544k-row rebuild.
            let windowColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(conversation_window)")
            let windowColumnNames = Set(windowColumns.compactMap { $0["name"] as String? })
            if !windowColumnNames.contains("embedding_hash") {
                try db.execute(sql: "ALTER TABLE conversation_window ADD COLUMN embedding_hash BLOB")
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS window_fts USING fts5(
                    body,
                    tokenize = 'trigram remove_diacritics 1'
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS window_member (
                    window_id INTEGER NOT NULL,
                    message_rowid INTEGER NOT NULL,
                    ordinal INTEGER NOT NULL,
                    is_from_me INTEGER NOT NULL,
                    handle_id INTEGER,
                    PRIMARY KEY(window_id, message_rowid)
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_window_chat ON conversation_window(chat_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_window_dates ON conversation_window(start_date, end_date)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_window_anchor ON conversation_window(anchor_rowid)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_window_member_message ON window_member(message_rowid)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_window_member_sender ON window_member(is_from_me, handle_id)")

            try setState(db: db, key: .schemaVersion, value: String(IndexStore.schemaVersion))
        }
    }

    // MARK: - State helpers

    /// Read a state value (returns nil if missing).
    public func state(_ key: StateKey) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM index_state WHERE key = ?",
                arguments: [key.rawValue]
            )
        }
    }

    /// Read the last-indexed ROWID. Returns 0 if no index has run yet.
    public func lastIndexedROWID() throws -> Int64 {
        guard let raw = try state(.lastIndexedROWID),
              let n = Int64(raw) else { return 0 }
        return n
    }

    /// Highest source ROWID fully represented by conversation windows.
    public func lastWindowedROWID() throws -> Int64 {
        guard let raw = try state(.lastWindowedROWID),
              let n = Int64(raw) else { return 0 }
        return n
    }

    /// Set a state value (helper used by builder / sync).
    public func setState(_ key: StateKey, value: String) throws {
        try dbQueue.write { db in
            try setState(db: db, key: key, value: value)
        }
    }

    /// Internal version that takes an explicit `Database` for use within an
    /// existing write transaction.
    static func setState(db: Database, key: StateKey, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO index_state(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key.rawValue, value]
        )
    }

    /// Instance shorthand used in non-tx contexts.
    private func setState(db: Database, key: StateKey, value: String) throws {
        try Self.setState(db: db, key: key, value: value)
    }

    // MARK: - Diagnostics

    /// Number of rows in the mirror (== distinct messages indexed). Cheap.
    public func indexedRowCount() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM message_meta") ?? 0
        }
    }


    /// Number of short conversation windows available to hybrid retrieval.
    public func conversationWindowCount() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_window") ?? 0
        }
    }

    /// True only when window construction has caught up to message FTS.
    public func conversationWindowsAreReady() throws -> Bool {
        let indexed = try lastIndexedROWID()
        let windowed = try lastWindowedROWID()
        let count = try conversationWindowCount()
        return indexed > 0 && windowed >= indexed && count > 0
    }

    /// Disk footprint of the index file in bytes.
    public func sizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}

extension IndexStore {

    /// Three-state freshness check against the live chat.db.
    public enum Freshness: Sendable, Equatable {
        /// Mirror is at parity with chat.db (every row we want is indexed).
        case ready
        /// Mirror is behind by `rowsToCatchUp` rows (incremental sync needed).
        case behind(rowsToCatchUp: Int64)
        /// Mirror has never been built (or has zero rows). Full-index needed.
        case missing
    }

    /// Compare the mirror's last-indexed ROWID against `chat.db`'s current
    /// MAX(ROWID). Cheap (microseconds) — both sides are PK lookups.
    public func freshness(against chatDB: ChatDatabase) throws -> Freshness {
        let last = try lastIndexedROWID()
        if last == 0 { return .missing }
        let live = try chatDB.maxMessageRowID()
        if last >= live { return .ready }
        return .behind(rowsToCatchUp: live - last)
    }
}
