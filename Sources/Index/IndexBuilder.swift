//
//  IndexBuilder.swift
//  Hourglass
//
//  Builds the FTS5 mirror from chat.db. Two entry points:
//    - `buildFullIndex` — first-launch pass over every message row.
//    - `catchUp` — incremental, picks up rows whose ROWID > last_indexed_rowid.
//
//  Both share the same row pipeline: decode body via `AttributedBodyDecoder`,
//  insert into FTS + denormalized meta in a single transaction batch.
//
//  Concurrency
//  -----------
//  Builder is `Sendable` so it can be handed to a detached background task.
//  We open a fresh read-only connection to chat.db here rather than reusing
//  the shared `ChatDatabase` queue, because GRDB's `DatabaseQueue` serializes
//  all access through a single internal queue — and the indexer's long scan
//  would block UI queries running on the same shared queue.
//
//  Progress reporting
//  ------------------
//  `progress` callback is called periodically (every `progressEvery` rows)
//  with cumulative count + the estimated total, so a UI banner can show a
//  determinate bar. Always called on a background thread; the SearchViewModel
//  marshals to MainActor.
//

import Foundation
import GRDB

public struct IndexProgress: Sendable {
    public let indexed: Int64
    public let total: Int64?
    public init(indexed: Int64, total: Int64?) {
        self.indexed = indexed
        self.total = total
    }
}

public enum IndexBuilder {

    /// How many rows go into a single INSERT transaction. Bigger = faster but
    /// more memory. 5000 keeps memory steady at <50MB even on a half-million
    /// row build.
    public static let batchSize: Int = 5000

    /// Emit progress every N rows. 5000 is roughly 1% of a 525k DB — good UX.
    public static let progressEvery: Int64 = 5000

    /// Check whether `message_attachment_join` exists in the source DB.
    /// Old fixtures and pathologically pruned chat.db files may not have it.
    /// In that case we skip the `has_attachment` denormalization (it just
    /// stays 0 for every row); attachment-based filters still work at query
    /// time via the actual join on chat.db.
    private static func sourceHasAttachmentJoin(_ srcQueue: DatabaseQueue) -> Bool {
        (try? srcQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = 'message_attachment_join'
                """) ?? false
        }) ?? false
    }

    /// Check whether `message.balloon_bundle_id` exists in the source DB.
    /// Modern macOS chat.db files have it; very old or fixture DBs may not.
    /// When missing, we substitute a NULL literal so the same SELECT works.
    private static func sourceHasBalloonBundle(_ srcQueue: DatabaseQueue) -> Bool {
        (try? srcQueue.read { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA table_info(message)")
            _ = row
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(message)")
            for r in rows {
                let name: String? = r["name"]
                if name == "balloon_bundle_id" { return true }
            }
            return false
        }) ?? false
    }

    /// Full reindex. Wipes any existing rows and starts from scratch.
    ///
    /// Returns the total number of rows indexed. Throws on any DB error;
    /// caller decides whether to delete the file and retry or fall back to
    /// the INSTR path. The transaction is per-batch so a partial failure
    /// halfway through still produces a usable (but incomplete) index.
    public static func buildFullIndex(
        chatDBURL: URL,
        store: IndexStore,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) throws -> Int64 {
        // Wipe and recreate so we get a clean ROWID match between source and
        // mirror. Use DELETE instead of DROP to keep schema/state.
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages_fts")
            try db.execute(sql: "DELETE FROM message_meta")
        }

        // Open a private read-only connection to the source. Sharing the
        // main app's `ChatDatabase.dbQueue` here would serialize every UI
        // search against the indexer, defeating the point of running in the
        // background.
        var srcConfig = Configuration()
        srcConfig.readonly = true
        srcConfig.busyMode = .timeout(2.0)
        let src = try DatabaseQueue(path: chatDBURL.path, configuration: srcConfig)
        let hasAttachJoin = sourceHasAttachmentJoin(src)
        let hasBalloonBundle = sourceHasBalloonBundle(src)

        // Total — quick scan to size the progress bar. The query takes ~2s
        // on the full DB; we tolerate that for the user-visible "indexing
        // 525,000 of 525,000" rather than the indeterminate spinner.
        let total: Int64 = (try? src.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM message"
            )
        }) ?? 0

        progress?(IndexProgress(indexed: 0, total: total))

        var indexed: Int64 = 0
        var maxROWIDSeen: Int64 = 0

        let hasAttachExpr = hasAttachJoin
            ? """
              COALESCE((
                  SELECT 1 FROM message_attachment_join mj
                  WHERE mj.message_id = m.ROWID
                  LIMIT 1
              ), 0)
              """
            : "0"
        let balloonExpr = hasBalloonBundle ? "m.balloon_bundle_id" : "NULL"

        // Stream the source rows in ROWID order so we can checkpoint
        // `last_indexed_rowid` incrementally. Use a cursor with batch fetch
        // to keep memory bounded.
        try src.read { srcDB in
            let cursor = try Row.fetchCursor(
                srcDB,
                sql: """
                SELECT
                    m.ROWID                    AS message_id,
                    m.guid                     AS guid,
                    m.text                     AS text,
                    m.attributedBody           AS attributedBody,
                    m.date                     AS date,
                    m.is_from_me               AS is_from_me,
                    m.handle_id                AS handle_id,
                    m.associated_message_type  AS associated_message_type,
                    \(balloonExpr)             AS balloon_bundle_id,
                    cmj.chat_id                AS chat_id,
                    \(hasAttachExpr)           AS has_attachment
                FROM message m
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                ORDER BY m.ROWID ASC
                """
            )

            // GRDB's `Row.fetchCursor` reuses internal buffers between
            // iterations — values from a previous row are invalidated when
            // we advance. We snapshot each row into a pure-Swift struct
            // (`PendingRow`) right at fetch time, then batch-write those.
            var batch: [PendingRow] = []
            batch.reserveCapacity(batchSize)
            while let row = try cursor.next() {
                guard let pr = PendingRow(from: row) else { continue }
                batch.append(pr)
                if batch.count >= batchSize {
                    let (n, maxR) = try writeBatch(batch, store: store)
                    indexed += n
                    maxROWIDSeen = max(maxROWIDSeen, maxR)
                    batch.removeAll(keepingCapacity: true)
                    progress?(IndexProgress(indexed: indexed, total: total))
                    try store.setState(.lastIndexedROWID, value: String(maxROWIDSeen))
                }
            }
            if !batch.isEmpty {
                let (n, maxR) = try writeBatch(batch, store: store)
                indexed += n
                maxROWIDSeen = max(maxROWIDSeen, maxR)
                progress?(IndexProgress(indexed: indexed, total: total))
                try store.setState(.lastIndexedROWID, value: String(maxROWIDSeen))
            }
        }

        // Stamp the wall-clock as a diagnostic.
        let iso = ISO8601DateFormatter().string(from: Date())
        try store.setState(.lastFullReindexAt, value: iso)

        return indexed
    }

    /// Incremental catch-up. Ingests rows whose `ROWID > lastIndexedROWID`.
    /// Cheap when nothing has changed (just a `SELECT MAX(ROWID)`).
    public static func catchUp(
        chatDBURL: URL,
        store: IndexStore,
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) throws -> Int64 {
        let last = try store.lastIndexedROWID()

        var srcConfig = Configuration()
        srcConfig.readonly = true
        srcConfig.busyMode = .timeout(2.0)
        let src = try DatabaseQueue(path: chatDBURL.path, configuration: srcConfig)
        let hasAttachJoin = sourceHasAttachmentJoin(src)
        let hasBalloonBundle = sourceHasBalloonBundle(src)

        let liveMax: Int64 = try src.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(ROWID) FROM message") ?? 0
        }
        if liveMax <= last {
            return 0   // Nothing new.
        }

        let toCatchUp = liveMax - last
        progress?(IndexProgress(indexed: 0, total: toCatchUp))

        var indexed: Int64 = 0
        var maxROWIDSeen: Int64 = last

        let hasAttachExpr = hasAttachJoin
            ? """
              COALESCE((
                  SELECT 1 FROM message_attachment_join mj
                  WHERE mj.message_id = m.ROWID
                  LIMIT 1
              ), 0)
              """
            : "0"
        let balloonExpr = hasBalloonBundle ? "m.balloon_bundle_id" : "NULL"

        try src.read { srcDB in
            let cursor = try Row.fetchCursor(
                srcDB,
                sql: """
                SELECT
                    m.ROWID                    AS message_id,
                    m.guid                     AS guid,
                    m.text                     AS text,
                    m.attributedBody           AS attributedBody,
                    m.date                     AS date,
                    m.is_from_me               AS is_from_me,
                    m.handle_id                AS handle_id,
                    m.associated_message_type  AS associated_message_type,
                    \(balloonExpr)             AS balloon_bundle_id,
                    cmj.chat_id                AS chat_id,
                    \(hasAttachExpr)           AS has_attachment
                FROM message m
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.ROWID > ?
                ORDER BY m.ROWID ASC
                """,
                arguments: [last]
            )

            var batch: [PendingRow] = []
            batch.reserveCapacity(batchSize)
            while let row = try cursor.next() {
                guard let pr = PendingRow(from: row) else { continue }
                batch.append(pr)
                if batch.count >= batchSize {
                    let (n, maxR) = try writeBatch(batch, store: store)
                    indexed += n
                    maxROWIDSeen = max(maxROWIDSeen, maxR)
                    batch.removeAll(keepingCapacity: true)
                    progress?(IndexProgress(indexed: indexed, total: toCatchUp))
                    try store.setState(.lastIndexedROWID, value: String(maxROWIDSeen))
                }
            }
            if !batch.isEmpty {
                let (n, maxR) = try writeBatch(batch, store: store)
                indexed += n
                maxROWIDSeen = max(maxROWIDSeen, maxR)
                progress?(IndexProgress(indexed: indexed, total: toCatchUp))
                try store.setState(.lastIndexedROWID, value: String(maxROWIDSeen))
            }
        }
        return indexed
    }

    /// Re-emit the mirror rows for the past `days` of messages, in case
    /// chat.db mutated existing rows. Codex audit M3 (2026-05-25): the
    /// pure-rowid catch-up path only sees NEW rows. Edits to recent
    /// messages (e.g. iMessage's edit-message feature, attachment
    /// metadata updates, reaction state changes) won't be reflected in
    /// the FTS body / type / attachment metadata until something blows
    /// the index away. This method re-snapshots the last `days` of
    /// rows via `INSERT OR REPLACE`, overwriting any stale mirror
    /// entries with the current source values.
    ///
    /// Cheap: ~30 days of messages is small relative to all-time, and
    /// the rest of the mirror is untouched. Callers can run it on a
    /// timer (e.g. once per launch / every N minutes).
    public static func refreshRecentWindow(
        chatDBURL: URL,
        store: IndexStore,
        days: Int = 30
    ) throws -> Int64 {
        var srcConfig = Configuration()
        srcConfig.readonly = true
        srcConfig.busyMode = .timeout(2.0)
        let src = try DatabaseQueue(path: chatDBURL.path, configuration: srcConfig)
        let hasAttachJoin = sourceHasAttachmentJoin(src)
        let hasBalloonBundle = sourceHasBalloonBundle(src)

        // Mac-epoch nanoseconds threshold = (now - days) in ns since
        // 2001-01-01 UTC. We use the broad nanosecond form; the dual-
        // format guard inside the SELECT handles legacy seconds rows.
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let cutoffNS = MessageDate.nanosecondsSinceMacEpoch(from: cutoff)
        let cutoffS = MessageDate.secondsSinceMacEpoch(from: cutoff)

        let hasAttachExpr = hasAttachJoin
            ? """
              COALESCE((
                  SELECT 1 FROM message_attachment_join mj
                  WHERE mj.message_id = m.ROWID
                  LIMIT 1
              ), 0)
              """
            : "0"
        let balloonExpr = hasBalloonBundle ? "m.balloon_bundle_id" : "NULL"

        var refreshed: Int64 = 0
        try src.read { srcDB in
            let cursor = try Row.fetchCursor(
                srcDB,
                sql: """
                SELECT
                    m.ROWID                    AS message_id,
                    m.guid                     AS guid,
                    m.text                     AS text,
                    m.attributedBody           AS attributedBody,
                    m.date                     AS date,
                    m.is_from_me               AS is_from_me,
                    m.handle_id                AS handle_id,
                    m.associated_message_type  AS associated_message_type,
                    \(balloonExpr)             AS balloon_bundle_id,
                    cmj.chat_id                AS chat_id,
                    \(hasAttachExpr)           AS has_attachment
                FROM message m
                LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE (m.date > 1000000000000 AND m.date >= ?)
                   OR (m.date <= 1000000000000 AND m.date >= ?)
                """,
                arguments: [cutoffNS, cutoffS]
            )
            var batch: [PendingRow] = []
            batch.reserveCapacity(batchSize)
            while let row = try cursor.next() {
                guard let pr = PendingRow(from: row) else { continue }
                batch.append(pr)
                if batch.count >= batchSize {
                    let (n, _) = try writeBatch(batch, store: store)
                    refreshed += n
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                let (n, _) = try writeBatch(batch, store: store)
                refreshed += n
            }
        }
        return refreshed
    }

    // MARK: - Per-row snapshot

    /// Materialized copy of a single message row, decoupled from any GRDB
    /// cursor buffer. Snapshotting at fetch time is essential — `Row.fetchCursor`
    /// reuses an internal buffer across iterations, so any Row instance becomes
    /// invalid the moment the cursor advances. Holding onto Rows in an `Array`
    /// and reading their columns later silently yields NULL.
    struct PendingRow {
        let rowid: Int64
        let guid: String?
        let body: String        // already decoded
        let date: Int64
        let isFromMe: Int
        let chatID: Int64?
        let handleID: Int64?
        let amt: Int
        let balloonID: String?
        let hasAttachment: Int

        init?(from row: Row) {
            // Eagerly copy every field. Use optional subscripts so a NULL
            // column produces nil rather than crashing.
            guard let rowid: Int64 = row["message_id"],
                  let date: Int64 = row["date"] else {
                return nil
            }
            self.rowid = rowid
            self.date = date
            self.guid = row["guid"]
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            self.body = decodeBody(text: text, blob: blob)
            self.isFromMe = (row["is_from_me"] as Int?) ?? 0
            self.chatID = row["chat_id"]
            self.handleID = row["handle_id"]
            self.amt = (row["associated_message_type"] as Int?) ?? 0
            self.balloonID = row["balloon_bundle_id"]
            self.hasAttachment = (row["has_attachment"] as Int?) ?? 0
        }
    }

    // MARK: - Per-batch write

    /// Insert one batch worth of snapshotted rows into the mirror. Returns
    /// the number indexed and the highest ROWID seen in the batch.
    private static func writeBatch(
        _ rows: [PendingRow],
        store: IndexStore
    ) throws -> (count: Int64, maxROWID: Int64) {
        var count: Int64 = 0
        var maxROWID: Int64 = 0
        try store.dbQueue.write { db in
            let ftsStmt = try db.makeStatement(
                sql: "INSERT OR REPLACE INTO messages_fts(rowid, body) VALUES(?, ?)"
            )
            let metaStmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO message_meta(
                    rowid, guid, date, is_from_me, chat_id, handle_id,
                    associated_message_type, has_attachment, balloon_bundle_id
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)

            for r in rows {
                try ftsStmt.execute(arguments: [r.rowid, r.body])
                try metaStmt.execute(arguments: [
                    r.rowid, r.guid, r.date, r.isFromMe, r.chatID,
                    r.handleID, r.amt, r.hasAttachment, r.balloonID
                ])
                count += 1
                if r.rowid > maxROWID { maxROWID = r.rowid }
            }
        }
        return (count, maxROWID)
    }

    /// Decode the body for indexing. Same pipeline as `MessageSearch.search`
    /// — text column wins if non-empty, otherwise pass the blob through
    /// `AttributedBodyDecoder`.
    ///
    /// Indexing the empty string for body-less rows (image-only / sticker /
    /// removed messages) is correct: the FTS row still exists so the rowid
    /// is queryable for type-only filters, and any `MATCH` query on text
    /// will naturally miss it.
    static func decodeBody(text: String?, blob: Data?) -> String {
        if let text, !text.isEmpty { return text }
        return AttributedBodyDecoder.decode(blob)
    }
}
