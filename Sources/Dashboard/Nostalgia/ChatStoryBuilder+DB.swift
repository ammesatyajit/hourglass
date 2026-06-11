//
//  ChatStoryBuilder+DB.swift
//  Hourglass — Dashboard / Nostalgia (per-chat "notable moments")
//
//  The GRDB-backed loader that produces `ChatStoryBuilder.RawChat`s from
//  chat.db, then hands them to the PURE `ChatStoryBuilder` to assemble the
//  per-chat timelines. This is the ONLY part that touches the database.
//
//  Read-only, synchronous + throwing — call off the main thread (the VM does).
//
//  ──────────────────────────────────────────────────────────────────────────
//  METADATA-FIRST (Codex consult #4, step ④ — the BIG Nostalgia win).
//  ──────────────────────────────────────────────────────────────────────────
//  The pure `ChatStoryBuilder` reads a message's decoded `body` in EXACTLY two
//  places: the `origin` example (the chronologically-first message) and the
//  `peakReaction` path (the coordination/URL filters + the 15-char tie-break +
//  the winning example). Every OTHER moment — longestConversation, biggestDay,
//  membership — is computed from metadata alone (dates / reaction counts /
//  events). So decoding `attributedBody` for the FULL ~532k-message corpus (the
//  old behavior) wasted ~530k typedstream parses to surface ≈one example body
//  per chat plus a few reaction candidates.
//
//  This loader therefore runs in two phases:
//    PHASE 1 (metadata-only): stream the corpus selecting NO body columns
//      (`m.text` / `m.attributedBody` are NOT in the SELECT), building each
//      `RawMessage` with an EMPTY `body`. Row enumeration order, the CTE, the
//      filters, the ROWID-dedup, and the assemble/merge are byte-identical to
//      before — only the body is deferred. SQLite never even reads the blob
//      pages.
//    PHASE 2 (targeted hydration): after assemble+merge, compute the exact set
//      of ROWIDs whose bodies the pure builder will read (per merged chat: the
//      sorted-first origin row ∪ every row with `reactionCount >=
//      minPeakReactions`), decode JUST those in ONE `WHERE ROWID IN (...)`
//      query, and patch the bodies back into the RawChats before building.
//
//  WHY THIS IS PARITY-EXACT: the pure builder runs on the SAME RawChats it
//  always did, with the SAME decoded body for every message whose body it
//  actually reads, and an empty body for every message whose body it never
//  touches (guaranteed by `hydrationRowIDs`, which mirrors the builder's own
//  selection — see `ChatStoryBuilder.buildStory`). Tie-breaks are unchanged
//  because the builder code is unchanged. Decode count drops from ~532k to
//  (≈chats + reaction-candidates).
//
//  chat.db gotchas honored here (see plans.md → Critical Technical Knowledge):
//    • `m.text` is NULL for modern rows → decode `m.attributedBody` via
//      `AttributedBodyDecoder` (the canonical typedstream parser). Done ONLY in
//      the targeted PHASE-2 hydration now, never over the full corpus.
//    • `m.date` is Mac-absolute nanoseconds → `MessageDate.date(fromRaw:)`.
//    • `m.handle_id` is NULL for sent rows → `is_from_me` gates "You".
//    • Reactions are rows with `associated_message_type` 2000–2007, targeting
//      `associated_message_guid` with a `p:N/` / `bp:` prefix we strip
//      (`Reaction.stripGUIDPrefix` semantics; SQL strips after the first "/").
//      We only count GENUINE current reactions (2000–2007), never removed
//      (3000+).
//    • Membership events: `item_type = 1` (add/remove, `group_action_type`
//      0 = add / 1 = remove, person via `other_handle → handle.id`) and
//      `item_type = 3` (rename, `group_title`). Deduped by message ROWID.
//    • Recreated same-named group threads are MERGED into one story (their
//      messages + events unioned under the earliest thread's ROWID).
//

import Foundation
import GRDB

extension ChatStoryBuilder {

    /// Load + build every qualifying chat's story. Read-only.
    ///
    /// - Parameters:
    ///   - database: the open read-only chat.db handle.
    ///   - contacts: AddressBook resolution (handle → name / avatar).
    ///   - calendar: the app calendar (for biggest-day / formatting).
    ///   - config: activity floor + sessionization knobs.
    public static func loadStories(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        calendar: Calendar,
        config: Config = Config()
    ) throws -> [ChatStory] {
        let raw = try loadRawChats(database: database, contacts: contacts, config: config)
        return buildStories(from: raw, calendar: calendar, config: config)
    }

    // MARK: - Chat metadata

    /// One chat's identity row, before messages/events are attached.
    struct ChatMeta {
        let rowID: Int64
        let style: Int            // 45 = 1:1, 43 = group
        let displayName: String   // may be ""
        let avatarData: Data?
        var participantHandles: [String]   // resolved handle.id strings
    }

    static func loadRawChats(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        config: Config
    ) throws -> [RawChat] {
        try database.dbQueue.read { db in
            // 1) Chat metadata — style + display name. (Avatar bytes for chats
            //    aren't in chat.db's `chat` table in a directly-usable form; we
            //    derive a 1:1 chat's avatar from the resolved contact below and
            //    leave group avatars nil — the view falls back to a montage.)
            let chatRows = try Row.fetchAll(db, sql: """
                SELECT ROWID, style, COALESCE(display_name, '') AS display_name
                FROM chat
                """)
            var metaByID: [Int64: ChatMeta] = [:]
            for r in chatRows {
                let id: Int64 = r["ROWID"]
                metaByID[id] = ChatMeta(
                    rowID: id,
                    style: r["style"] ?? 0,
                    displayName: r["display_name"] ?? "",
                    avatarData: nil,
                    participantHandles: []
                )
            }

            // 2) Participants per chat (chat_handle_join → handle.id).
            let partRows = try Row.fetchAll(db, sql: """
                SELECT chj.chat_id AS chat_id, h.id AS handle
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                """)
            for r in partRows {
                let cid: Int64 = r["chat_id"]
                guard let handle: String = r["handle"] else { continue }
                metaByID[cid]?.participantHandles.append(handle)
            }

            // 3) Real messages with per-message reaction count + warmest glyph —
            //    METADATA ONLY (no body). Reactions are folded in a sub-aggregate
            //    keyed by the stripped target guid. We compute the "warmest" type
            //    per target via a priority: love > laugh > emphasize > like >
            //    question > sticker > custom; dislike never wins. min(priority) =
            //    warmest.
            //
            //    THE SELECT CARRIES NO `m.text` / `m.attributedBody`. Every
            //    `RawMessage` is built with an empty `body` here; the bodies the
            //    pure builder actually reads (origin + peak candidates) are
            //    decoded in PHASE 2 (`hydrateExampleBodies`) by ROWID. The CTE,
            //    the remaining column list, the filters, the ROWID-dedup, and the
            //    per-row mapping are otherwise unchanged → `messagesByChat` is
            //    identical to the old loop except every `body` is "" until
            //    hydration patches the chosen rows. (We still stream with a cursor
            //    so even the metadata pass holds one row at a time.)
            // Reactions: aggregate the (relatively few) reaction rows ONCE into a
            // guid → (count, warmRank) map, then look it up per message in Swift.
            //
            // PERF (the Nostalgia-load fix): the old query folded reactions in via
            // `LEFT JOIN reaction_agg ra ON ra.target_guid = m.guid`, but
            // `target_guid` is a COMPUTED column (CASE/substr), so SQLite cannot
            // index it — the EXPLAIN plan was `SCAN ra LEFT-JOIN`, i.e. a FULL scan
            // of the reaction aggregate for EVERY one of the ~533k messages
            // (≈ 533k × 45k ≈ 24B comparisons → ~9 min on the dev corpus). Folding
            // the same `GROUP BY` into an in-memory dictionary makes the per-message
            // cost O(1), so the whole pass is O(N + R). The aggregate is the SAME
            // query, so rx_count + warm_rank are byte-identical — only the join
            // site moved from SQLite to Swift.
            let reactionSQL = """
                SELECT
                    CASE
                        WHEN instr(r.associated_message_guid, '/') > 0
                        THEN substr(r.associated_message_guid,
                                    instr(r.associated_message_guid, '/') + 1)
                        ELSE r.associated_message_guid
                    END AS target_guid,
                    COUNT(*) AS rx_count,
                    MIN(
                        CASE r.associated_message_type
                            WHEN 2000 THEN 1   -- love
                            WHEN 2003 THEN 2   -- laugh
                            WHEN 2004 THEN 3   -- emphasize
                            WHEN 2001 THEN 4   -- like
                            WHEN 2005 THEN 5   -- question
                            WHEN 2007 THEN 6   -- sticker
                            WHEN 2006 THEN 7   -- custom emoji
                            ELSE 9
                        END
                    ) AS warm_rank
                FROM message r
                WHERE r.associated_message_type BETWEEN 2000 AND 2007
                  AND r.associated_message_guid IS NOT NULL
                GROUP BY target_guid
                """
            var reactionByGuid: [String: (count: Int, warm: Int)] = [:]
            let rxCursor = try Row.fetchCursor(db, sql: reactionSQL)
            while let r = try rxCursor.next() {
                guard let g: String = r["target_guid"] else { continue }
                reactionByGuid[g] = (r["rx_count"] ?? 0, r["warm_rank"] ?? 9)
            }

            // Real messages — METADATA ONLY (no body). Reaction count + warmest
            // glyph come from `reactionByGuid` (built above) by O(1) lookup on
            // `m.guid`. THE SELECT CARRIES NO `m.text` / `m.attributedBody`; every
            // `RawMessage` is built with an empty `body`, hydrated in PHASE 2 by
            // ROWID. Still streamed with a cursor (one row resident at a time).
            let messageSQL = """
                SELECT
                    m.ROWID            AS rowid,
                    m.date             AS date,
                    m.is_from_me       AS is_from_me,
                    h.id               AS sender_handle,
                    cmj.chat_id        AS chat_id,
                    m.guid             AS guid
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle h ON h.ROWID = m.handle_id
                WHERE m.associated_message_type = 0
                  AND m.item_type = 0
                """

            var messagesByChat: [Int64: [RawMessage]] = [:]
            var seenMsgRow = Set<Int64>()
            let messageCursor = try Row.fetchCursor(db, sql: messageSQL)
            while let r = try messageCursor.next() {
                let rowID: Int64 = r["rowid"]
                // chat_message_join can list a message once per chat; a real
                // message belongs to one chat, but guard anyway so a row never
                // double-counts.
                if seenMsgRow.contains(rowID) { continue }
                seenMsgRow.insert(rowID)

                let chatID: Int64 = r["chat_id"]
                let rawDate: Int64 = r["date"] ?? 0
                let isFromMe = (r["is_from_me"] as Int? ?? 0) == 1
                let senderName: String = isFromMe
                    ? "You"
                    : contacts.name(forRawHandle: r["sender_handle"])
                let rxCount: Int = r["rx_count"] ?? 0
                let warmRank: Int? = r["warm_rank"]

                // Body is decoded later (PHASE 2) only for the rows the builder
                // reads — origin + peak candidates. Everything else stays "".
                messagesByChat[chatID, default: []].append(RawMessage(
                    rowID: rowID,
                    date: MessageDate.date(fromRaw: rawDate),
                    isFromMe: isFromMe,
                    senderName: senderName,
                    body: "",
                    reactionCount: rxCount,
                    topReactionEmoji: rxCount > 0 ? glyph(forWarmRank: warmRank) : nil,
                    guid: r["guid"]
                ))
            }

            // 4) Membership + rename events for group chats. Deduped by ROWID.
            let eventRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    m.ROWID             AS rowid,
                    m.date              AS date,
                    m.item_type         AS item_type,
                    m.group_action_type AS group_action_type,
                    m.group_title       AS group_title,
                    m.is_from_me        AS is_from_me,
                    actor.id            AS actor_handle,
                    other.id            AS other_handle,
                    cmj.chat_id         AS chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                LEFT JOIN handle actor ON actor.ROWID = m.handle_id
                LEFT JOIN handle other ON other.ROWID = m.other_handle
                WHERE m.item_type IN (1, 3)
                ORDER BY m.date ASC
                """)

            var eventsByChat: [Int64: [RawEvent]] = [:]
            var seenEventRow = Set<Int64>()
            for r in eventRows {
                let rowID: Int64 = r["rowid"]
                if seenEventRow.contains(rowID) { continue }
                seenEventRow.insert(rowID)

                let chatID: Int64 = r["chat_id"]
                let rawDate: Int64 = r["date"] ?? 0
                let date = MessageDate.date(fromRaw: rawDate)
                let itemType: Int = r["item_type"] ?? 0
                let isFromMe = (r["is_from_me"] as Int? ?? 0) == 1
                let actor = isFromMe ? "You" : contacts.name(forRawHandle: r["actor_handle"])
                let otherRaw: String? = r["other_handle"]
                let other = otherRaw.map { contacts.name(forRawHandle: $0) } ?? "?"

                if itemType == 3 {
                    let title: String = r["group_title"] ?? ""
                    guard !title.isEmpty else { continue }
                    eventsByChat[chatID, default: []].append(
                        RawEvent(rowID: rowID, date: date, actor: actor,
                                 kind: .renamed(title: title)))
                } else { // item_type == 1
                    let gat: Int = r["group_action_type"] ?? 0
                    if gat == 1 {
                        eventsByChat[chatID, default: []].append(
                            RawEvent(rowID: rowID, date: date, actor: actor,
                                     kind: .removed(person: other)))
                    } else {
                        // Add. Skip a self-referential add (actor == other) and
                        // unresolved others — matches the `/tmp/haotl` filter.
                        guard other != "?" && other != actor else { continue }
                        eventsByChat[chatID, default: []].append(
                            RawEvent(rowID: rowID, date: date, actor: actor,
                                     kind: .added(person: other)))
                    }
                }
            }

            // 5) Assemble RawChats, MERGING recreated same-named group threads.
            let assembled = assembleRawChats(
                metaByID: metaByID,
                messagesByChat: messagesByChat,
                eventsByChat: eventsByChat,
                contacts: contacts,
                config: config
            )

            // 6) PHASE 2 — hydrate ONLY the example bodies the builder reads.
            return hydrateExampleBodies(into: assembled, db: db, config: config)
        }
    }

    // MARK: - Targeted body hydration (PHASE 2)

    /// Decode `attributedBody` for ONLY the messages whose body the pure builder
    /// will read — per merged chat, the chronologically-first (origin) row plus
    /// every row with `reactionCount >= config.minPeakReactions` (the peak
    /// candidates the filters + tie-break + example inspect). Mirrors exactly
    /// which messages `ChatStoryBuilder.buildStory` touches the body of, so the
    /// produced stories are byte-identical to decoding the whole corpus.
    ///
    /// One `WHERE ROWID IN (...)` decode for the union of all chats' needed
    /// ROWIDs (chunked under SQLite's variable limit), then the bodies are
    /// patched back into the RawChats. Chats that don't clear `minMessages`
    /// were already dropped by `assembleRawChats`, so we never decode bodies for
    /// a chat that won't produce a story.
    static func hydrateExampleBodies(
        into chats: [RawChat],
        db: Database,
        config: Config
    ) -> [RawChat] {
        // 1) Which ROWIDs need a body? Mirror the builder's own selection.
        var needed = Set<Int64>()
        for chat in chats {
            // Below the floor → no story → no body read. (assembleRawChats
            // already pre-filtered, but re-check so the set matches the builder
            // exactly even if the floor logic ever changes.)
            guard chat.messages.count >= config.minMessages else { continue }
            // origin = sorted-by-date first (the builder's `msgs.sorted { $0.date
            // < $1.date }.first`). For date ties Swift's sort is unstable, so we
            // hydrate ALL rows sharing the minimum date — a superset that always
            // includes whichever row the builder picks (extra hydrated bodies on
            // non-chosen rows are harmless: the builder only quotes `first`).
            if let minDate = chat.messages.map(\.date).min() {
                for m in chat.messages where m.date == minDate {
                    needed.insert(m.rowID)
                }
            }
            // peak candidates: every row the peak filter inspects the body of.
            for m in chat.messages where m.reactionCount >= config.minPeakReactions {
                needed.insert(m.rowID)
            }
        }
        guard !needed.isEmpty else { return chats }

        // 2) Decode those bodies — ONE query (chunked under SQLITE_MAX_VARIABLE).
        let bodyByRowID = decodeBodies(rowIDs: needed, db: db)

        // 3) Patch bodies back in. Rebuild each RawChat's message array with the
        //    hydrated body where we have one; untouched rows keep "". This is the
        //    SAME RawMessage values the old full-decode produced for every row
        //    the builder reads, and "" for rows it never reads.
        return chats.map { chat in
            let patched = chat.messages.map { m -> RawMessage in
                guard let body = bodyByRowID[m.rowID] else { return m }
                return RawMessage(
                    rowID: m.rowID,
                    date: m.date,
                    isFromMe: m.isFromMe,
                    senderName: m.senderName,
                    body: body,
                    reactionCount: m.reactionCount,
                    topReactionEmoji: m.topReactionEmoji,
                    guid: m.guid
                )
            }
            return RawChat(
                chatRowID: chat.chatRowID,
                title: chat.title,
                isGroup: chat.isGroup,
                participantCount: chat.participantCount,
                avatarData: chat.avatarData,
                messages: patched,
                events: chat.events
            )
        }
    }

    /// Decode the `attributedBody` (falling back to `text`) for a set of message
    /// ROWIDs, returning a `rowID → trimmed body` map. Chunks the IN-list to
    /// stay under SQLite's bound-variable limit, and applies the SAME
    /// text-then-blob decode + whitespace trim the old per-row loop used, so the
    /// hydrated bodies are byte-identical.
    static func decodeBodies(rowIDs: Set<Int64>, db: Database) -> [Int64: String] {
        var out: [Int64: String] = [:]
        out.reserveCapacity(rowIDs.count)
        // SQLITE_MAX_VARIABLE_NUMBER defaults to 999 on older builds; keep well
        // under it to be safe across SQLite versions.
        let chunkSize = 900
        let ids = Array(rowIDs)
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + chunkSize, ids.count)])
            i += chunkSize
            let placeholders = databaseQuestionMarks(count: chunk.count)
            let sql = """
                SELECT ROWID AS rowid, text AS text, attributedBody AS attributedBody
                FROM message
                WHERE ROWID IN (\(placeholders))
                """
            // A cursor keeps only one blob resident at a time even within the
            // chunk; defensive against a chunk that happens to contain large
            // rich-text blobs.
            guard let cursor = try? Row.fetchCursor(db, sql: sql, arguments: StatementArguments(chunk)) else {
                continue
            }
            while let row = (try? cursor.next()) ?? nil {
                let rowID: Int64 = row["rowid"]
                let text: String? = row["text"]
                let blob: Data? = row["attributedBody"]
                let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
                out[rowID] = body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// "?, ?, ?" for `count` bound variables.
    private static func databaseQuestionMarks(count: Int) -> String {
        guard count > 0 else { return "" }
        return Array(repeating: "?", count: count).joined(separator: ", ")
    }

    // MARK: - Assembly + merge (mostly pure; uses contacts only for labels)

    /// Group chats into stories, folding recreated same-named GROUP threads into
    /// one. 1:1 chats are never merged (each is its own story keyed by the
    /// resolved contact). Returns one `RawChat` per logical conversation.
    ///
    /// Takes `messagesByChat` / `eventsByChat` `consuming` and DRAINS them with
    /// `removeValue` as it buckets, so we never hold two full copies of the
    /// decoded corpus (the per-chat arrays move into their bucket rather than
    /// being copied). Behavior is identical to reading them by value — the same
    /// arrays land in the same buckets — but peak memory no longer doubles at
    /// assembly time. The caller (`loadRawChats`) hands its locals straight in.
    static func assembleRawChats(
        metaByID: [Int64: ChatMeta],
        messagesByChat: consuming [Int64: [RawMessage]],
        eventsByChat: consuming [Int64: [RawEvent]],
        contacts: ResolvedContacts,
        config: Config
    ) -> [RawChat] {
        // Merge key:
        //   • named group  → "g:<display_name>"  (folds recreated threads)
        //   • 1:1          → "p:<resolved name or handle>" (folds phone+email
        //                     chats with the same person, like FirstMessage)
        //   • unnamed group→ "u:<chatRowID>"     (never merged — no stable key)
        struct Bucket {
            var primaryRowID: Int64
            var firstDate: Date
            var isGroup: Bool
            var title: String
            var participants: Set<String>
            var messages: [RawMessage]
            var events: [RawEvent]
            var avatarData: Data?
        }
        var buckets: [String: Bucket] = [:]

        // Deterministic iteration: by chat ROWID ascending, so the earliest
        // thread becomes the primary on ties and merges are reproducible.
        for id in metaByID.keys.sorted() {
            guard let meta = metaByID[id] else { continue }
            // DRAIN (don't copy): take ownership of this chat's arrays out of the
            // dictionaries. Removing the dictionary's reference leaves `msgs`/`evs`
            // uniquely referenced, so handing them to a new Bucket below is a move,
            // not a CoW copy — we never duplicate the corpus.
            let msgs = messagesByChat.removeValue(forKey: id) ?? []
            // A thread with no real messages can still contribute events to a
            // merged group, but on its own it's nothing — skip empties that
            // aren't part of a named group.
            let isGroup = meta.style == 43
            let mergeKey: String
            var title: String
            var avatar: Data?

            if isGroup {
                if !meta.displayName.isEmpty {
                    mergeKey = "g:\(meta.displayName)"
                    title = meta.displayName
                } else {
                    mergeKey = "u:\(id)"
                    title = participantListTitle(meta.participantHandles, contacts: contacts)
                }
                avatar = nil
            } else {
                // 1:1 — resolve the single participant to a name/avatar.
                let handle = meta.participantHandles.first
                let name = contacts.name(forRawHandle: handle)
                mergeKey = "p:\(name)"
                title = name
                avatar = contacts.avatarData(forRawHandle: handle)
            }

            let firstMsgDate = msgs.map(\.date).min() ?? Date.distantFuture
            let evs = eventsByChat.removeValue(forKey: id) ?? []

            // Pull the existing bucket OUT of the dictionary before mutating it,
            // so its `messages`/`events` arrays are uniquely referenced and the
            // appends below mutate in place instead of triggering a CoW copy of
            // an already-merged corpus. (Merges only fire for same-named groups /
            // multi-handle 1:1s, but the in-place rule keeps even those cheap.)
            if var existing = buckets.removeValue(forKey: mergeKey) {
                existing.messages.append(contentsOf: msgs)
                existing.events.append(contentsOf: evs)
                existing.participants.formUnion(meta.participantHandles)
                if firstMsgDate < existing.firstDate {
                    existing.firstDate = firstMsgDate
                    existing.primaryRowID = id
                }
                if existing.avatarData == nil { existing.avatarData = avatar }
                if existing.title.isEmpty { existing.title = title }
                buckets[mergeKey] = existing
            } else {
                buckets[mergeKey] = Bucket(
                    primaryRowID: id,
                    firstDate: firstMsgDate,
                    isGroup: isGroup,
                    title: title,
                    participants: Set(meta.participantHandles),
                    messages: msgs,
                    events: evs,
                    avatarData: avatar
                )
            }
        }

        var out: [RawChat] = []
        out.reserveCapacity(buckets.count)
        for (_, b) in buckets {
            // Drop merged buckets that still fall short of the floor (cheap
            // pre-filter; the pure builder re-checks). Saves building stories
            // we'll discard.
            guard b.messages.count >= config.minMessages else { continue }
            // Dedup events that merged across recreated threads by ROWID.
            var seen = Set<Int64>()
            let dedupEvents = b.events.filter { seen.insert($0.rowID).inserted }
            out.append(RawChat(
                chatRowID: b.primaryRowID,
                title: b.title,
                isGroup: b.isGroup,
                participantCount: max(b.participants.count, b.isGroup ? b.participants.count : 1),
                avatarData: b.avatarData,
                messages: b.messages,
                events: dedupEvents
            ))
        }
        return out
    }

    /// Title for an unnamed group: the first few participant names joined.
    static func participantListTitle(_ handles: [String], contacts: ResolvedContacts) -> String {
        let names = handles
            .map { contacts.name(forRawHandle: $0) }
            .filter { !$0.isEmpty && $0 != "(unknown)" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return "Group chat" }
        let shown = names.prefix(3).map { $0.components(separatedBy: " ").first ?? $0 }
        if names.count > 3 {
            return shown.joined(separator: ", ") + " +\(names.count - 3)"
        }
        return shown.joined(separator: ", ")
    }

    // MARK: - Reaction glyph

    /// Map the SQL `warm_rank` (the MIN priority of the reaction types on a
    /// message) back to a display glyph for the peak-reaction headline.
    static func glyph(forWarmRank rank: Int?) -> String {
        switch rank {
        case 1: return "❤️"   // love
        case 2: return "😂"   // laugh
        case 3: return "‼️"   // emphasize
        case 4: return "👍"   // like
        case 5: return "❓"   // question
        case 6: return "🏷️"   // sticker
        case 7: return "❤️"   // custom emoji — glyph not carried in agg; neutral
        default: return "❤️"
        }
    }
}
