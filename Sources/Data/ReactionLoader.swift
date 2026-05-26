//
//  ReactionLoader.swift
//  Hourglass
//
//  Batched loader for tapbacks ("reactions") against a set of target message
//  GUIDs.
//
//  Why batched? The naive approach — fetch reactions per-row as the UI scrolls
//  — is an N+1 query in the hot path. For a search result with 200 rows that
//  means 200 round-trips into the DB queue. We instead issue ONE query that
//  pulls every tapback for every target GUID in the result set, then group in
//  Swift.
//
//  Query shape
//  -----------
//  Tapbacks are rows where `associated_message_type` is in 2000-2999 (we drop
//  3000-3999, which are *removed* reactions — history, not current state).
//  The reference back to the target lives in `associated_message_guid`, which
//  may be prefixed (`p:0/<guid>`, `bp:<guid>`, etc.) — we strip in Swift after
//  fetching, because doing it in SQL would defeat the index on the column.
//
//  We pull more rows than strictly needed (any prefix variant of every target
//  GUID) and group by stripped GUID afterwards. SQLite handles this with a
//  single `WHERE associated_message_guid LIKE ?` per target — fine for ≤ a
//  few hundred targets which is the panel result-set ceiling.
//
//  Edge cases
//  ----------
//  - Empty input → returns empty dictionary, no SQL.
//  - Target GUID containing `'` or `%` — sanitized via parameter binding; we
//    use `LIKE` with explicit wildcard concatenation in SQL, parameter is just
//    the bare GUID.
//  - Reaction sender is the user (`handle_id IS NULL`) — `senderHandle` is nil
//    and `senderName` resolves to "You".
//

import Foundation
import GRDB

public enum ReactionLoader {

    /// Load reactions for the given target message GUIDs.
    ///
    /// Returns a dictionary keyed by the **bare** message GUID (no `p:0/` or
    /// `bp:` prefix). Reactions per message are sorted by date ascending
    /// (oldest first) — same order Messages.app shows them.
    ///
    /// Only the CURRENT reaction from each sender on each message is kept.
    /// If a sender added a love and later switched to a like, only the like
    /// is in the array (matches the visible Messages.app bubble: a sender
    /// can have at most one active tapback per message at a time).
    public static func reactions(
        forTargetGUIDs guids: [String],
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [String: [Reaction]] {
        guard !guids.isEmpty else { return [:] }

        // Build the IN list of candidate `associated_message_guid` values.
        // For each target GUID we precompute every known prefix variant
        // and stuff them all into one IN clause — SQLite can use the
        // implicit index on `associated_message_guid`, so the lookup is
        // O(log N) per variant instead of O(N) per row.
        //
        // We've verified on the user's real DB that the prefixes used are
        //   "" (bare GUID), "p:0/" … "p:9/", and "bp:". Beyond p:9/ is
        //   extraordinarily rare (multi-part messages with 10+ segments).
        //
        // A leading-wildcard LIKE — what an earlier draft used as a catch-all
        // — turns into a full scan over every tapback row PER target. With
        // ~200k messages and ~50k tapbacks that collapsed the query into
        // multi-minute territory. The IN approach keeps it sub-second.
        let uniqueGUIDs = Array(Set(guids.filter { !$0.isEmpty }))
        guard !uniqueGUIDs.isEmpty else { return [:] }

        let prefixes: [String] = [""] + (0...9).map { "p:\($0)/" } + ["bp:"]
        var inList: [String] = []
        inList.reserveCapacity(uniqueGUIDs.count * prefixes.count)
        for g in uniqueGUIDs {
            for p in prefixes {
                inList.append(p + g)
            }
        }
        var args: [DatabaseValueConvertible] = []
        for s in inList { args.append(s) }
        let placeholders = Array(repeating: "?", count: inList.count).joined(separator: ", ")

        // Pull BOTH adds (2000-2999) AND removals (3000-3999). Each user
        // can have at most one active reaction per message; the latest row
        // wins. If that latest row is a removal, the (target, sender) pair
        // drops out entirely — i.e. the user unreacted.
        //
        // Codex audit H4 (2026-05-25): the previous query gated on
        // `BETWEEN 2000 AND 2999` so removal rows (3000+) were invisible.
        // A removed heart would still appear in the UI because the loader
        // only ever saw the add row. Fix: include 3000-3999, then drop
        // the pair whose latest row is a removal.
        let sql = """
            SELECT
                m.associated_message_guid       AS target_guid,
                m.associated_message_type       AS type,
                m.associated_message_emoji      AS emoji,
                m.date                          AS date,
                m.is_from_me                    AS is_from_me,
                h.id                            AS sender_handle
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type BETWEEN 2000 AND 3999
              AND m.associated_message_guid IN (\(placeholders))
            ORDER BY m.date ASC
            """

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        // Group by stripped target GUID. Build a quick lookup for "is this GUID
        // one we asked for?" to avoid wasting work on incidental substring hits.
        let targetSet: Set<String> = Set(uniqueGUIDs)
        // Track the most recent reaction per (target, sender). `wasRemoval`
        // records whether that latest row was an unreact — we use it to
        // drop the entry after the scan finishes.
        struct Key: Hashable { let target: String; let sender: String? }
        struct Latest { let date: Int64; let reaction: Reaction; let wasRemoval: Bool }
        var latest: [Key: Latest] = [:]

        for row in rows {
            guard let rawTarget: String = row["target_guid"] else { continue }
            let stripped = Reaction.stripGUIDPrefix(rawTarget)
            guard targetSet.contains(stripped) else { continue }

            let type: Int = row["type"] ?? 0
            let isRemoval = type >= 3000 && type <= 3999
            let emoji: String? = row["emoji"]
            // For removal rows the type encodes WHICH reaction was removed
            // (e.g. 3001 = removed love). `Reaction.Kind.fromRaw` may not
            // know how to map a 3xxx type → kind; that's fine, we don't
            // need a kind for the removal — only the (target, sender) key.
            // Convert the removal type to the matching add type so kind
            // resolution still works for the *display* of the prior add.
            let kindLookupType = isRemoval ? (type - 1000) : type
            guard let kind = Reaction.Kind.fromRaw(type: kindLookupType, emoji: emoji) else { continue }

            let rawDate: Int64 = row["date"] ?? 0
            let date = MessageDate.date(fromRaw: rawDate)
            let isFromMe: Bool = (row["is_from_me"] as Int? ?? 0) == 1
            let senderHandle: String? = row["sender_handle"]

            let senderName: String
            if isFromMe {
                senderName = "You"
            } else if let raw = senderHandle {
                senderName = contacts.name(forRawHandle: raw)
            } else {
                senderName = "(unknown)"
            }

            let reaction = Reaction(
                kind: kind,
                senderName: senderName,
                senderHandle: senderHandle,
                date: date,
                isFromMe: isFromMe
            )

            let key = Key(target: stripped, sender: senderHandle)
            // Rows already arrive in date ASC order, so the last-seen row
            // for a given key is the latest. Record the removal flag too.
            latest[key] = Latest(date: rawDate, reaction: reaction, wasRemoval: isRemoval)
        }

        // Drop pairs whose latest row was a removal — i.e. the user
        // unreacted; nothing should appear in the UI.
        latest = latest.filter { !$0.value.wasRemoval }

        // Group into the output dictionary, preserving date-ascending order.
        var out: [String: [Reaction]] = [:]
        let sortedEntries = latest.values.sorted { $0.date < $1.date }
        for entry in sortedEntries {
            // Find target by re-stripping isn't necessary; we have it in the key.
            // Recover target by reverse-lookup from the latest dictionary.
            // Simpler: iterate over the dictionary keys.
        }
        for (key, entry) in latest {
            out[key.target, default: []].append(entry.reaction)
        }
        // Sort each per-message list by date ascending so UI rendering is stable.
        for (k, v) in out {
            out[k] = v.sorted { $0.date < $1.date }
        }
        return out
    }
}
