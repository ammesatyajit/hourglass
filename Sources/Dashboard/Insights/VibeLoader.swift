//
//  VibeLoader.swift
//  Hourglass — Vernacular Analysis (VIBE / dialect clustering — impure layer)
//
//  Bridges chat.db → the pure `VibeClusterer`. A FOCUSED 1:1 query (the
//  prototype `/tmp/vibe/main.swift`'s exact shape): we only look at
//  `chat.style == 45` (one-on-one) conversations, accumulate a per-contact
//  `VibeAggregate` over the ORIGINAL-CASE message bodies (URL messages
//  excluded, matching the rest of the engine + the prototype), and key each
//  contact by their RESOLVED display name — the same string
//  `VernacularLoader.resolveWho` / `GraphNode.displayName` use, so the social
//  graph can color a node by matching its `displayName`. Sent messages
//  accumulate under "You".
//
//  chat.db gotchas respected (see plans.md "Critical Technical Knowledge"):
//    - READ-ONLY GRDB queue (`ChatDatabase` is opened RO).
//    - `m.text` is NULL for ~99.8% of modern messages → decode
//      `m.attributedBody` via the canonical typedstream decoder. Blob bound
//      as `Data` (never CAST/LIKE — silently fails on the blob).
//    - SENT messages have `handle_id = 0/NULL`; sender is keyed off
//      `is_from_me` first ("You"), else the joined `handle.id` resolved
//      through `ResolvedContacts`.
//    - Real messages have `associated_message_type = 0` (drops reactions) and
//      `item_type = 0` (drops group-event / system rows), matching the
//      prototype.
//    - `chat.style == 45` is the one-on-one DM style (43 = group). This is the
//      gate that makes a contact's fingerprint reflect how THEY text you,
//      uncontaminated by group dynamics.
//
//  PURE/IMPURE split: this is the ONLY I/O. The clustering math lives in
//  `VibeClusterer.cluster(messagesByContact:)`. Runs off the main actor via the
//  view model (same detached-task pattern as `VernacularLoader`).
//

import Foundation
import GRDB
import os

public enum VibeLoader {

    private static let logger = Logger(subsystem: "com.satyajit.hourglass", category: "Vibe")

    static let unknownLabel = VernacularAnalyzer.unknownLabel

    /// Load per-contact 1:1 aggregates from chat.db (call OFF the main actor).
    /// Returns a map of contact display name (incl. "You") → `VibeAggregate`.
    /// Contacts not in AddressBook are dropped (the prototype only fingerprints
    /// resolved contacts), so the unknown sentinel never appears.
    public static func loadAggregates(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [String: VibeAggregate] {

        // 1) one-on-one chat_id → resolved contact display name. `chat.style ==
        //    45` is the DM style. A 1:1 chat has exactly one handle in
        //    chat_handle_join; resolve it to a contact and key the chat by that
        //    name. Unresolved handles → chat dropped.
        let chatSQL = """
            SELECT chj.chat_id AS chat_id, h.id AS handle
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            JOIN chat ch ON ch.ROWID = chj.chat_id
            WHERE ch.style = 45
            """
        var chatContact: [Int64: String] = [:]
        let chatRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: chatSQL)
        }
        for row in chatRows {
            guard let chatID: Int64 = row["chat_id"] else { continue }
            let raw: String? = row["handle"]
            guard let raw, !raw.isEmpty,
                  let contact = contacts.byHandle[Handle(raw: raw)] else { continue }
            chatContact[chatID] = contact.displayName
        }

        // 2) all real, non-reaction, non-system messages in those 1:1 chats.
        //    Sent → "You"; received → the chat's resolved contact. We pull only
        //    the columns we fold into the aggregate (no date/recency needed —
        //    the fingerprint is order-independent).
        let msgSQL = """
            SELECT m.is_from_me AS is_from_me, m.text AS text,
                   m.attributedBody AS body, cmj.chat_id AS chat_id
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            WHERE ch.style = 45
              AND m.associated_message_type = 0
              AND m.item_type = 0
            """
        var agg: [String: VibeAggregate] = [:]
        var scanned = 0
        try database.dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: msgSQL)
            while let row = try cursor.next() {
                autoreleasepool {
                    guard let chatID: Int64 = row["chat_id"],
                          let contact = chatContact[chatID] else { return }
                    let body = VernacularLoader.decodedBody(text: row["text"], blob: row["body"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return }
                    // Exclude URL/link/promo messages (matches the prototype's
                    // `!body.lowercased().contains("http")`; we reuse the engine's
                    // broader URL predicate for consistency with the rest of the
                    // corpus filtering).
                    if VernacularLoader.containsURL(body.lowercased()) { return }
                    let fromMe = (row["is_from_me"] as Int64? ?? 0) == 1
                    let who = fromMe ? "You" : contact
                    scanned += 1
                    var a = agg[who] ?? VibeAggregate()
                    a.add(body: body)
                    agg[who] = a
                }
            }
        }
        logger.debug("VibeLoader: \(chatContact.count, privacy: .public) 1:1 chats → \(scanned, privacy: .public) msgs across \(agg.count, privacy: .public) contacts")
        return agg
    }

    /// Load + cluster in one synchronous call (call OFF the main actor). The
    /// chat.db read here is INDEPENDENT of `VernacularLoader`'s read (it's a
    /// narrower, 1:1-only scan with different columns), so the two run as
    /// separate queries in the same off-main pass.
    ///
    /// NOTE: prefer `clusterFromCorpus(messages:options:)` when you already have
    /// the decoded `[VernacularMessage]` corpus — it derives the SAME aggregates
    /// from the single in-memory corpus, avoiding this second chat.db
    /// read + re-decode (the SPEED win). This method remains for callers that
    /// only want vibe (no full corpus).
    public static func computeClustering(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        options: VibeClusterer.Options = .default
    ) throws -> VibeClustering {
        let aggregates = try loadAggregates(database: database, contacts: contacts)
        return VibeClusterer.cluster(messagesByContact: aggregates, options: options)
    }

    /// Derive the per-contact 1:1 aggregates from an ALREADY-DECODED corpus
    /// (`VernacularLoader.loadMessages`), so the VIBE clustering shares the
    /// single chat.db read + decode instead of doing its own (the SPEED win).
    /// PURE — no I/O.
    ///
    /// Reproduces `loadAggregates` EXACTLY so the clustering stays byte-identical
    /// to the validated `/tmp/vibe` ground truth (60 people, 6 clusters):
    ///   • only ONE-ON-ONE messages (`m.isOneOnOne`, i.e. `chat.style == 45`),
    ///   • only real text rows (`m.itemType == 0` — drops group-event/system),
    ///   • URL messages already excluded corpus-wide by the loader (Fix #4) so we
    ///     don't re-check,
    ///   • sent → "You"; received → the CHAT's resolved contact.
    ///
    /// `oneOnOneContact` maps a 1:1 chat id → its resolved contact display name
    /// (the SAME per-CHAT attribution `loadAggregates` uses). It matters because
    /// a contact can text a 1:1 from MULTIPLE handles (80 such chats in the real
    /// db), some of which aren't individually in AddressBook — the per-chat map
    /// credits ALL of them to the one contact, whereas per-message `who` would
    /// drop the secondary-handle messages as unknown. When the map is empty/nil
    /// we fall back to per-message `who` (still correct for the common case,
    /// just slightly under-counts those tail messages). Received messages that
    /// resolve to the unknown sentinel are dropped (the prototype only
    /// fingerprints resolved contacts).
    public static func aggregatesFromCorpus(
        messages: [VernacularMessage],
        oneOnOneContact: [Int64: String] = [:]
    ) -> [String: VibeAggregate] {
        // When a per-chat contact map is supplied we mirror `loadAggregates`
        // EXACTLY: a 1:1 chat counts (for BOTH "You" and the contact) ONLY if its
        // single handle resolved to a known contact — `loadAggregates` skips any
        // message whose chat isn't in the map (`guard let contact = ...`), so a
        // sent message in a 1:1 with an unknown contact must NOT inflate "You".
        let gateOnMap = !oneOnOneContact.isEmpty
        var agg: [String: VibeAggregate] = [:]
        for m in messages {
            guard m.isOneOnOne, m.itemType == 0 else { continue }
            let chatContact = oneOnOneContact[m.chat]
            if gateOnMap, chatContact == nil { continue }   // chat not resolved → skip (sent too)
            let who: String
            if m.fromMe {
                who = "You"
            } else if let chatContact {
                who = chatContact                 // per-CHAT attribution (exact)
            } else {
                who = m.who                       // per-message fallback (map-less mode)
            }
            guard who != unknownLabel else { continue }
            var a = agg[who] ?? VibeAggregate()
            a.add(body: m.body)
            agg[who] = a
        }
        return agg
    }

    /// Cluster directly from an already-decoded corpus (call OFF the main actor).
    /// Equivalent to `computeClustering` but with NO chat.db read — it derives
    /// the aggregates from `messages` via `aggregatesFromCorpus`. PURE.
    public static func clusterFromCorpus(
        messages: [VernacularMessage],
        oneOnOneContact: [Int64: String] = [:],
        options: VibeClusterer.Options = .default
    ) -> VibeClustering {
        VibeClusterer.cluster(
            messagesByContact: aggregatesFromCorpus(messages: messages,
                                                    oneOnOneContact: oneOnOneContact),
            options: options)
    }

    /// Build the 1:1 chat-id → resolved-contact map (the per-CHAT attribution
    /// `aggregatesFromCorpus` wants for an exact match to `loadAggregates`).
    /// This is a tiny, cheap query (one row per 1:1 chat) — the ONLY chat.db
    /// touch the corpus-derived vibe path needs, and it decodes NOTHING.
    public static func oneOnOneContactMap(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [Int64: String] {
        let sql = """
            SELECT chj.chat_id AS chat_id, h.id AS handle
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            JOIN chat ch ON ch.ROWID = chj.chat_id
            WHERE ch.style = 45
            """
        var map: [Int64: String] = [:]
        let rows: [Row] = try database.dbQueue.read { db in try Row.fetchAll(db, sql: sql) }
        for row in rows {
            guard let chatID: Int64 = row["chat_id"] else { continue }
            let raw: String? = row["handle"]
            guard let raw, !raw.isEmpty,
                  let contact = contacts.byHandle[Handle(raw: raw)] else { continue }
            map[chatID] = contact.displayName
        }
        return map
    }
}
