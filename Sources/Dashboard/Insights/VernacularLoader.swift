//
//  VernacularLoader.swift
//  Hourglass — Vernacular Analysis (the only impure layer)
//
//  Bridges chat.db → the pure `VernacularAnalyzer`. Unlike the sent-only
//  `LinguisticInsightsLoader`, this reads BOTH sent AND received messages —
//  Layer 3 attribution needs to see who used a term before you, and social
//  uptake needs the whole thread to detect downstream amusement.
//
//  chat.db gotchas respected (see plans.md "Critical Technical Knowledge"):
//    - READ-ONLY GRDB queue (the shared `ChatDatabase` is opened RO).
//    - `m.text` is NULL for ~99.8% of modern messages → decode
//      `m.attributedBody` via the canonical typedstream decoder. Blob bound
//      as `Data` (never CAST/LIKE — silently fails on the blob).
//    - `message.date` is Mac-absolute NANOSECONDS (post-10.13): / 1e9 +
//      978307200 → Unix epoch seconds. (Matches every reference script.)
//    - SENT messages have `handle_id = 0/NULL`; we key sender off
//      `is_from_me` first, then the joined `handle.id`.
//    - Reactions live as separate rows with `associated_message_type` in
//      2000–2007 and `associated_message_guid` pointing at the target
//      message's guid (sometimes prefixed `p:0/<guid>` or `bp:<guid>`).
//      "Amused/approval" reactions = love/like/laugh/emphasize (2000–2004).
//    - Real messages have `associated_message_type = 0`.
//
//  Performance: one ascending in-memory pass decoding all real messages
//  (compiled -O the prototype did ~517k rows in 60–90s; in-app we cap with
//  `maxMessages` most-recent and reverse to ascending). Runs off the main
//  actor via the view model.
//

import Foundation
import GRDB
import Observation
import os

// MARK: - Loaded message value type

/// One decoded message, with everything the pure analyzer needs. `Sendable`
/// value type so the loaded corpus can cross to a detached analysis task.
public struct VernacularMessage: Sendable, Equatable {
    /// Stable corpus ordinal — a per-load occurrence identity for the SENSE
    /// layer (Codex upgrade #3). Assigned in place once the corpus is sorted
    /// ascending (`VernacularAnalyzer.assignMessageIDs`), so `messageID` == the
    /// message's index in the final ascending corpus. The occurrence index keys
    /// per-occurrence records by (messageID, span) so syntax features / sense
    /// clusters / attribution all reference the SAME stable unit. `internal(set)`
    /// so only the in-place assignment pass mutates it (no token recompute).
    /// Defaults -1 (un-assigned) so the pure harness/tests that build messages
    /// directly are unaffected until they opt in. PURE — never read from chat.db.
    public internal(set) var messageID: Int
    public let date: Double          // Unix epoch seconds
    public let chat: Int64
    /// True iff this message lives in a one-on-one chat (`chat.style == 45`).
    /// Carried on the message so the VIBE / dialect clustering can be derived
    /// from this SINGLE already-decoded corpus instead of VibeLoader doing a
    /// second 1:1-only chat.db read + re-decode (the perf win). Defaults false.
    public let isOneOnOne: Bool
    /// `message.item_type` (0 = a real text message; non-zero = group-event /
    /// system rows like name/participant changes). The VIBE derivation applies
    /// the same `item_type == 0` gate VibeLoader used, so clustering stays
    /// byte-identical to the validated ground truth. Defaults 0.
    public let itemType: Int64
    public let fromMe: Bool
    /// Resolved display name ("You" / contact name / unknown sentinel).
    public let who: String
    public let body: String
    public let bodyLow: String
    /// Lowercased letter/apostrophe word tokens (precomputed once).
    public let words: [String]
    public let wordSet: Set<String>
    /// Social-uptake weight: amused reactions ×1.5 + downstream amusement.
    public var uptake: Double
    /// True for poll/logistics messages whose reactions hijack uptake.
    public let isPoll: Bool
    /// True iff this is a SENT message that received an amused reaction
    /// (associated_message_type 2000/2003/2004 = love/laugh/emphasize) from
    /// someone else. Distinct from `uptake`, which blends the reaction weight
    /// with downstream-laughter signal.
    ///
    /// NOTE: `amused` includes ❤️ (love, 2000) and ‼️ (emphasize, 2004), which
    /// mean *agree/important*, NOT funny — so it is the WRONG signal for the
    /// "funny" / reacted-gems section. Use `laughed` for that.
    public let amused: Bool
    /// True iff this is a SENT message that received a *laugh* reaction
    /// (associated_message_type **2003** only = 😂 "Haha") from someone else.
    /// The honest "this was funny" signal: love (2000) means agree, emphasize
    /// (2004) means important — neither is humor. The reacted-gems / "funny"
    /// section keys on THIS, not `amused`. (See plans.md FUNNY fix.)
    public let laughed: Bool

    public init(date: Double, chat: Int64, fromMe: Bool, who: String, body: String,
                uptake: Double, amused: Bool = false, laughed: Bool = false,
                isOneOnOne: Bool = false, itemType: Int64 = 0, messageID: Int = -1) {
        self.messageID = messageID
        self.date = date
        self.chat = chat
        self.isOneOnOne = isOneOnOne
        self.itemType = itemType
        self.fromMe = fromMe
        self.who = who
        self.body = body
        let low = body.lowercased()
        self.bodyLow = low
        let w = VernTokens.words(body)
        self.words = w
        self.wordSet = Set(w)
        self.uptake = uptake
        self.isPoll = VernacularLoader.isPoll(low)
        self.amused = amused
        self.laughed = laughed
    }
}

public enum VernacularLoader {

    private static let logger = Logger(subsystem: "com.satyajit.hourglass", category: "Vernacular")

    static let unknownLabel = VernacularAnalyzer.unknownLabel

    // MARK: - amusement / poll detectors (ported from /tmp/slang3)

    /// Laughter / approval signal in a downstream message.
    static func isAmusement(_ low: String) -> Bool {
        let keys = ["lmao","lmfao","lmaoo","haha","hahah","\u{1F480}","\u{1F62D}","\u{1F602}","\u{1F923}",
                    " lol","lol ","crying","im dead","so real","deadass","cooked","fr fr","\u{1F4AF}"]
        for k in keys where low.contains(k) { return true }
        if low == "lol" || low == "real" || low == "facts" || low == "w" || low == "\u{1F480}" || low == "\u{1F62D}" { return true }
        return false
    }

    /// Poll/logistics messages ("react if coming") whose reactions are not
    /// amusement signal — excluded from phrase mining.
    static func isPoll(_ low: String) -> Bool {
        let keys = ["this message","like this","react to","react if","headcount","rsvp",
                    "love the message","if you can make it","like the message","comment if",
                    "react with","tap the","\u{1F44D} if","like if"]
        for k in keys where low.contains(k) { return true }
        return false
    }

    /// A message body that contains a URL / link / promo (matching the
    /// validated `/tmp/meme` prototype, which dropped these from the corpus so
    /// "try this on ur mac rn www.messageswrapped.com" never leaks into phrases
    /// or gems). Links pollute every downstream builder, so we filter
    /// ONCE here at load time. Takes a LOWERCASED body. (See plans.md fix #4.)
    static func containsURL(_ low: String) -> Bool {
        low.contains("http") || low.contains("://") || low.contains("www.")
            || low.contains(".com") || low.contains(".net") || low.contains(".org")
    }

    // MARK: - load

    /// Load both sent + received decoded messages with uptake computed.
    /// `maxMessages` caps to the most-recent N (then reordered ascending so
    /// thread-order / attribution / recency math are correct).
    ///
    /// PERFORMANCE (see plans.md SPEED/OOM entries): `m.attributedBody` blob
    /// decode is the dominant CPU cost — ~99% of rows have NULL `m.text` so nearly
    /// every row decodes a typedstream blob. We stream raw rows into bounded
    /// batches, decode each batch CONCURRENTLY (`DispatchQueue.concurrentPerform`)
    /// with a per-item `autoreleasepool`, append decoded messages, then release the
    /// batch before reading more rows. NO truncation: every non-empty, non-URL
    /// message of ANY length is analyzed (the old `body.count < 300` filter
    /// silently dropped every long message).
    public static func loadMessages(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        maxMessages: Int = 1_000_000
    ) throws -> [VernacularMessage] {

        // 1) amused-reaction counts per target message guid.
        //    associated_message_type 2000–2004 = love/like(thumbs)/laugh/
        //    emphasize/question; we use the amused/approval band 2000–2004
        //    minus 2002 (dislike) per the prototype's IN (2000,2001,2003,2004).
        let reactionSQL = """
            SELECT
              CASE
                WHEN instr(associated_message_guid, '/') > 0
                  THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
                ELSE associated_message_guid
              END AS g,
              COUNT(*) AS c
            FROM message
            WHERE associated_message_type IN (2000, 2001, 2003, 2004)
              AND associated_message_guid IS NOT NULL
            GROUP BY g
            """
        var amused: [String: Int] = [:]
        let reactionRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: reactionSQL)
        }
        for row in reactionRows {
            if let g: String = row["g"] { amused[g] = row["c"] }
        }

        // 1b) AMUSED-FROM-OTHERS per target guid — the clean per-message flag
        //     older style sections can use. Reactions of type
        //     2000/2003/2004 (love/laugh/emphasize) from SOMEONE ELSE
        //     (is_from_me = 0), keyed by the same guid-suffix-after-"/".
        //     Matches the prototype's `amusedOn` exactly (note: it drops the
        //     thumbs-up "like" 2001 that the uptake query above keeps, and it
        //     excludes my own reactions).
        let amusedSQL = """
            SELECT
              CASE
                WHEN instr(associated_message_guid, '/') > 0
                  THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
                ELSE associated_message_guid
              END AS g,
              COUNT(*) AS c
            FROM message
            WHERE associated_message_type IN (2000, 2003, 2004)
              AND is_from_me = 0
              AND associated_message_guid IS NOT NULL
            GROUP BY g
            """
        var amusedFromOthers: [String: Int] = [:]
        let amusedRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: amusedSQL)
        }
        for row in amusedRows {
            if let g: String = row["g"] { amusedFromOthers[g] = row["c"] }
        }

        // 1c) LAUGHED-FROM-OTHERS per target guid — the honest "this was funny"
        //     flag the reacted-gems / "funny" section uses. ONLY the 😂 laugh
        //     reaction (associated_message_type == 2003) from SOMEONE ELSE
        //     (is_from_me = 0). Critically EXCLUDES love (2000) and emphasize
        //     (2004) which mean *agree/important*, not funny. Keyed by the same
        //     guid-suffix-after-"/". (See plans.md FUNNY fix.)
        let laughedSQL = """
            SELECT
              CASE
                WHEN instr(associated_message_guid, '/') > 0
                  THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
                ELSE associated_message_guid
              END AS g,
              COUNT(*) AS c
            FROM message
            WHERE associated_message_type = 2003
              AND is_from_me = 0
              AND associated_message_guid IS NOT NULL
            GROUP BY g
            """
        var laughedFromOthers: [String: Int] = [:]
        let laughedRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: laughedSQL)
        }
        for row in laughedRows {
            if let g: String = row["g"] { laughedFromOthers[g] = row["c"] }
        }

        // 1d) one-on-one chat ids (`chat.style == 45`) — so each message can
        //     carry `isOneOnOne`, letting the VIBE clustering be derived from
        //     this SINGLE decoded corpus (no second 1:1-only read).
        let oneOnOneSQL = "SELECT ROWID AS id FROM chat WHERE style = 45"
        var oneOnOne: Set<Int64> = []
        let oooRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: oneOnOneSQL)
        }
        for row in oooRows { if let id: Int64 = row["id"] { oneOnOne.insert(id) } }

        // 2) all real messages, most-recent first, capped. We pull RAW columns
        //    into plain Sendable structs only for one bounded batch at a time
        //    (GRDB `Row` is not Sendable), decode that batch CONCURRENTLY, append
        //    the non-nil messages, and immediately drop the batch's blobs.
        let msgSQL = """
            SELECT m.date AS date, cmj.chat_id AS chat_id, m.is_from_me AS is_from_me,
                   h.id AS handle, m.text AS text, m.attributedBody AS body,
                   m.guid AS guid, m.item_type AS item_type
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
            ORDER BY m.date DESC
            LIMIT ?
            """
        let batchSize = 8_192
        var fetchedRows = 0
        var msgs: [VernacularMessage] = []
        // This is the final returned corpus (not transient blob storage), so
        // reserving here avoids repeated value-array growth without reintroducing
        // the old all-raw-blobs residency.
        msgs.reserveCapacity(max(0, min(maxMessages, 600_000)))

        func drain(_ batch: [RawMessageRow]) {
            guard !batch.isEmpty else { return }
            let built = decodeConcurrently(batch, contacts: contacts, oneOnOne: oneOnOne,
                                           amused: amused, amusedFromOthers: amusedFromOthers,
                                           laughedFromOthers: laughedFromOthers)
            for case let msg? in built {
                msgs.append(msg)
            }
        }

        try database.dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: msgSQL, arguments: [maxMessages])
            var batch: [RawMessageRow] = []
            batch.reserveCapacity(batchSize)
            while let row = try cursor.next() {
                fetchedRows += 1
                batch.append(RawMessageRow(
                    date: (row["date"] as Int64?) ?? 0,
                    chat: (row["chat_id"] as Int64?) ?? 0,
                    fromMe: ((row["is_from_me"] as Int64?) ?? 0) == 1,
                    handle: row["handle"],
                    text: row["text"],
                    blob: row["body"],
                    guid: (row["guid"] as String?) ?? "",
                    itemType: (row["item_type"] as Int64?) ?? 0))
                if batch.count >= batchSize {
                    drain(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            drain(batch)
        }

        // reorder ascending (we pulled DESC for the LIMIT)
        msgs.sort { $0.date < $1.date }
        // Assign the stable corpus ordinal IN PLACE (no token recompute) — the
        // per-occurrence identity the SENSE layer keys on. After this, a
        // message's `messageID` == its index in the ascending corpus.
        for i in msgs.indices { msgs[i].messageID = i }

        // 3) downstream amusement: laughter/approval in the NEXT ≤3 msgs of the
        //    same chat within 15 min, from a DIFFERENT person.
        addDownstreamAmusement(&msgs)

        logger.debug("VernacularLoader: \(fetchedRows, privacy: .public) rows → \(msgs.count, privacy: .public) decoded messages")
        return msgs
    }

    /// Raw row data extracted from chat.db on the DB queue, decoded later off
    /// the queue. `Sendable` (all fields are) so it crosses to the concurrent
    /// decode workers.
    struct RawMessageRow: Sendable {
        let date: Int64
        let chat: Int64
        let fromMe: Bool
        let handle: String?
        let text: String?
        let blob: Data?
        let guid: String
        let itemType: Int64
    }

    /// Decode one bounded raw batch into `VernacularMessage`s CONCURRENTLY (the
    /// typedstream blob decode is the dominant cost). Returns a parallel array of
    /// optionals (nil = dropped because empty or URL); the caller appends non-nil
    /// values before dropping the batch. Each output index is written by exactly
    /// one worker, so the writes are race-free. PURE w.r.t. its inputs (no I/O —
    /// the DB read already happened).
    static func decodeConcurrently(
        _ raws: [RawMessageRow],
        contacts: ResolvedContacts,
        oneOnOne: Set<Int64>,
        amused: [String: Int],
        amusedFromOthers: [String: Int],
        laughedFromOthers: [String: Int]
    ) -> [VernacularMessage?] {
        var built = [VernacularMessage?](repeating: nil, count: raws.count)
        guard !raws.isEmpty else { return built }
        built.withUnsafeMutableBufferPointer { buf in
            // Disjoint-index invariant established above → manual unsafe escape.
            nonisolated(unsafe) let out = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: raws.count) { i in
                let decoded: VernacularMessage? = autoreleasepool {
                    let r = raws[i]
                    let body = decodedBody(text: r.text, blob: r.blob)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return nil }
                    // Fix #4: drop URL/link/promo messages from the WHOLE analysis
                    // corpus (matching /tmp/meme). One place → phrases, gems,
                    // graph, and corpus stats all benefit. NO length
                    // truncation: long messages are KEPT (the old `< 300` filter is
                    // gone).
                    if containsURL(body.lowercased()) { return nil }
                    let who = resolveWho(rawHandle: r.handle, fromMe: r.fromMe, contacts: contacts)
                    let epoch = Double(r.date) / 1e9 + 978_307_200
                    let uptake = Double(amused[r.guid] ?? 0) * 1.5
                    // per-message amused flag: only meaningful for SENT messages (an
                    // amused/approval reaction someone else placed on YOUR message).
                    let amusedFlag = r.fromMe && (amusedFromOthers[r.guid] ?? 0) > 0
                    // per-message LAUGHED flag: a 😂 laugh (2003) someone else placed
                    // on YOUR message — the honest humor signal for the funny section.
                    let laughedFlag = r.fromMe && (laughedFromOthers[r.guid] ?? 0) > 0
                    return VernacularMessage(
                        date: epoch, chat: r.chat, fromMe: r.fromMe, who: who, body: body,
                        uptake: uptake, amused: amusedFlag, laughed: laughedFlag,
                        isOneOnOne: oneOnOne.contains(r.chat), itemType: r.itemType)
                }
                (out + i).pointee = decoded
            }
        }
        return built
    }

    /// Mutates `uptake` in place. `msgs` MUST be date-ascending.
    static func addDownstreamAmusement(_ msgs: inout [VernacularMessage]) {
        var byChat: [Int64: [Int]] = [:]
        for (i, m) in msgs.enumerated() { byChat[m.chat, default: []].append(i) }
        for (_, idxs) in byChat {
            for a in 0..<idxs.count {
                let i = idxs[a]
                var bonus = 0.0
                var b = a + 1
                while b < idxs.count, b <= a + 3 {
                    let j = idxs[b]
                    if msgs[j].date - msgs[i].date > 900 { break }   // 15 min
                    if msgs[j].who != msgs[i].who, isAmusement(msgs[j].bodyLow) { bonus += 1.0 }
                    b += 1
                }
                if bonus > 0 { msgs[i].uptake += min(bonus, 3) }
            }
        }
    }

    // MARK: - decode + resolve helpers

    static func decodedBody(text: String?, blob: Data?) -> String {
        if let text, !text.isEmpty { return text }
        return AttributedBodyDecoder.decode(blob)
    }

    /// "You" for sent; resolved contact name for received; a stable sentinel
    /// for handles not in AddressBook (so attribution can exclude them).
    static func resolveWho(rawHandle: String?, fromMe: Bool, contacts: ResolvedContacts) -> String {
        if fromMe { return "You" }
        guard let raw = rawHandle, !raw.isEmpty else { return unknownLabel }
        if let c = contacts.byHandle[Handle(raw: raw)] { return c.displayName }
        return unknownLabel
    }

    /// Build `chatID → {display names of the OTHER members of that chat}` from
    /// `chat_handle_join` (chat.db lists only the OTHER participants — your own
    /// handle is never a row), resolving each handle to a contact display name
    /// via the SAME resolution the message loader uses. Unknown handles are
    /// skipped (they can never be an attribution target). This powers the
    /// SHARED-EXPOSURE gate on OUTGOING graph edges: "could the adopter SEE you
    /// use the term in a chat they're in?". Read-only; decodes NOTHING (no blob,
    /// no message text) — one cheap join. Mirrors `/tmp/expose`'s `chatParts`.
    static func chatParticipantsMap(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [Int64: Set<String>] {
        let sql = """
            SELECT chj.chat_id AS chat_id, h.id AS handle
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            """
        var map: [Int64: Set<String>] = [:]
        let rows: [Row] = try database.dbQueue.read { db in try Row.fetchAll(db, sql: sql) }
        for row in rows {
            guard let chatID: Int64 = row["chat_id"] else { continue }
            let raw: String? = row["handle"]
            guard let raw, !raw.isEmpty,
                  let contact = contacts.byHandle[Handle(raw: raw)] else { continue }
            map[chatID, default: []].insert(contact.displayName)
        }
        return map
    }

    // MARK: - full pipeline (off-main)

    /// Load + analyze in one synchronous call (call OFF the main actor).
    /// Computes the signature words via the existing `LinguisticAnalyzer`
    /// (over the user's sent bodies) then the full vernacular analysis.
    public static func computeInsights(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        baseline: LinguisticBaseline,
        maxMessages: Int = 1_000_000,
        options: VernacularAnalyzer.Options = .default
    ) throws -> VernacularInsights {
        let messages = try loadMessages(database: database, contacts: contacts, maxMessages: maxMessages)

        // Signature words: reuse LinguisticAnalyzer over the user's sent text.
        let sentBodies = messages.compactMap { $0.fromMe ? $0.body : nil }
        let ling = LinguisticAnalyzer.analyze(sentBodies: sentBodies, baseline: baseline)
        let signatureWords = ling.distinctiveWords.map {
            VernacularSignatureWord(word: $0.term, count: $0.userCount,
                                    timesMoreThanBaseline: $0.timesMoreThanBaseline,
                                    absentFromBaseline: $0.absentFromBaseline)
        }

        return VernacularAnalyzer.analyze(messages: messages, baseline: baseline,
                                          signatureWords: signatureWords, options: options)
    }

    /// Bundle of everything the Vernacular panel renders, computed from ONE
    /// chat.db read + ONE decode. The profile/spread path is the single
    /// transmission source; legacy anomalous-word/snowclone transmission has
    /// been removed from this orchestration.
    public struct AllSections: Sendable {
        public let insights: VernacularInsights
        /// PHASE-1 PROFILE — words, phrases, reclaimed words, and templates.
        public let profile: VernacularProfile
        /// Additive profile-word spread summary for the Vocabulary lens chip bar.
        /// Empty when the profile is disabled or when profiling a non-You subject.
        public let spreadProfile: SpreadProfile
        /// Optional tokenized extraction cache built only when
        /// `vernacular.profile.tokenizedCorpus` is enabled. Stored for lazy
        /// per-person profile reuse; nil on the default legacy extraction path.
        public let tokenizedCorpus: VernacularTokenizedCorpus?
        public let reactedGems: [ReactedGem]
        /// EMPHATIC CONSTRUCTIONS — the user's SHOUTED-for-emphasis words
        /// (case-sensitive over original-case sent text), ordered by count desc.
        public let emphaticConstructions: [EmphaticItem]
        /// NON-CAPS emphasis devices (word elongation + repeated punctuation) so
        /// a non-shouting user still gets a populated "how you emphasize" view.
        public let emphasisSignals: [EmphasisSignal]
        /// DISCOVERED vocabulary — distinctive single tokens the user sends
        /// (clippings + slang + internet-speak), discovered from THEIR text (not
        /// curated), ordered by times-sent desc. `abbreviations`/`slangUsed` are
        /// a transparent length split of this same list.
        public let discoveredVocab: [VocabItem]
        public let abbreviations: [VocabItem]
        public let slangUsed: [VocabItem]
        /// SHARED IN-GROUP VOCABULARY — slang you AND ≥4 friends all use (the
        /// group dialect). Curated lexicon ∩ usage; ranked by share width
        /// (`peopleCount`) desc.
        public let sharedVocabulary: [SharedTerm]
        /// VIBE / dialect clustering, derived from THIS corpus (no second read).
        public let vibe: VibeClustering
    }

    /// Cross-worker result holder for `buildAllSections`.
    ///
    /// Each field is written exactly once by one stage, and fields are read only
    /// after the owning `DispatchGroup` barrier has completed. The unchecked
    /// conformance is the same disjoint-write invariant used by
    /// `decodeConcurrently`'s unsafe output buffer.
    private final class BuildAllSectionsResults: @unchecked Sendable {
        var ling: LinguisticInsights?
        var gems: [ReactedGem]?
        var emphatic: [EmphaticItem]?
        var emphasisSignals: [EmphasisSignal]?
        var vocab: [VocabItem]?
        var sharedVocab: [SharedTerm]?
        var profile: VernacularProfile?
        var spreadProfile: SpreadProfile?
        var vibe: VibeClustering?
        var insights: VernacularInsights?
    }

    /// Load once, then compute the categorized insights, profile-backed spread,
    /// reacted gems, and style sections from the same decoded corpus (call OFF
    /// the main actor). All pure stats — one chat.db read, no double decode.
    public static func computeAllSections(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        baseline: LinguisticBaseline,
        maxMessages: Int = 1_000_000,
        options: VernacularAnalyzer.Options = .default,
        graphOptions: VernacularAnalyzer.GraphOptions = .default,
        sectionsOptions: VernacularAnalyzer.SectionsOptions = .default,
        vibeOptions: VibeClusterer.Options = .default,
        profileConfig: VernacularConfig = .fromUserDefaults(),
        profileSubject: VernacularSubject = .you
    ) throws -> AllSections {
        let messages = try loadMessages(database: database, contacts: contacts, maxMessages: maxMessages)
        // Cheap (one row per 1:1 chat, NO decode) map for EXACT per-chat vibe
        // attribution — best-effort: if it fails the vibe path falls back to
        // per-message attribution.
        let oooContact = (try? VibeLoader.oneOnOneContactMap(database: database, contacts: contacts)) ?? [:]
        // Chat-membership map (chatID → {other members}) for the OUTGOING
        // shared-exposure gate. Cheap join, decodes nothing; best-effort.
        let chatParticipants = (try? chatParticipantsMap(database: database, contacts: contacts)) ?? [:]
        return buildAllSections(messages: messages, contacts: contacts, baseline: baseline,
                                oneOnOneContact: oooContact, chatParticipants: chatParticipants,
                                options: options, graphOptions: graphOptions,
                                sectionsOptions: sectionsOptions, vibeOptions: vibeOptions,
                                profileConfig: profileConfig,
                                profileSubject: profileSubject)
    }

    /// Compute EVERY vernacular data product from an already-decoded corpus.
    /// PURE (no I/O) — split out from `computeAllSections` so the out-of-band
    /// harness (and tests) can feed a corpus directly, and so the single decode
    /// feeds the insights, profile-backed spread, sections, discovered vocab,
    /// emphasis signals, AND the vibe clustering with NO second chat.db read.
    /// `contacts` is used
    /// only to exclude contact-name fragments from the discovered vocabulary.
    public static func buildAllSections(
        messages: [VernacularMessage],
        contacts: ResolvedContacts,
        baseline: LinguisticBaseline,
        oneOnOneContact: [Int64: String] = [:],
        chatParticipants: [Int64: Set<String>] = [:],
        options: VernacularAnalyzer.Options = .default,
        graphOptions: VernacularAnalyzer.GraphOptions = .default,
        sectionsOptions: VernacularAnalyzer.SectionsOptions = .default,
        vibeOptions: VibeClusterer.Options = .default,
        profileConfig: VernacularConfig = .disabled,
        profileSubject: VernacularSubject = .you
    ) -> AllSections {
        let queue = DispatchQueue.global(qos: .userInitiated)
        // Bound the transient working sets: only this many corpus-heavy stages
        // may run at once, keeping Phase-1 peak near the old sequential envelope.
        let stageConcurrencyCap = 3
        let semaphore = DispatchSemaphore(value: stageConcurrencyCap)
        let results = BuildAllSectionsResults()
        let benchEnabled = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil

        let tokenizedCorpus: VernacularTokenizedCorpus?
        if profileConfig.isEnabled && profileConfig.useTokenizedCorpus {
            let _tTC = benchEnabled ? Date() : nil
            tokenizedCorpus = VernacularTokenizedCorpus.build(messages: messages,
                                                              contacts: contacts,
                                                              config: profileConfig)
            if let t = _tTC { print("BENCH::     buildAllSections.tokenizedCorpus \(Int(Date().timeIntervalSince(t) * 1000)) ms"); fflush(stdout) }
        } else {
            tokenizedCorpus = nil
        }

        func runStage(in group: DispatchGroup, _ work: @escaping @Sendable () -> Void) {
            group.enter()
            queue.async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }
                work()
            }
        }

        let wave1 = DispatchGroup()
        runStage(in: wave1) {
            let sentBodies = messages.compactMap { $0.fromMe ? $0.body : nil }
            results.ling = LinguisticAnalyzer.analyze(sentBodies: sentBodies, baseline: baseline)
        }
        runStage(in: wave1) {
            results.gems = VernacularAnalyzer.buildReactedGems(messages: messages, baseline: baseline,
                                                               options: sectionsOptions)
        }
        runStage(in: wave1) {
            results.emphatic = VernacularAnalyzer.buildEmphaticConstructions(messages: messages,
                                                                             options: sectionsOptions)
        }
        runStage(in: wave1) {
            results.emphasisSignals = VernacularAnalyzer.buildEmphasisSignals(messages: messages,
                                                                              options: sectionsOptions)
        }
        runStage(in: wave1) {
            // DISCOVERED vocabulary (token-level; not curated). Split by length into
            // abbreviations vs slang — both from the same discovery, count-ordered.
            let _tDV = benchEnabled ? Date() : nil
            results.vocab = VernacularAnalyzer.discoverVocab(messages: messages, baseline: baseline,
                                                             contacts: contacts, options: sectionsOptions)
            if let t = _tDV { print("BENCH::     buildAllSections.discoverVocab \(Int(Date().timeIntervalSince(t) * 1000)) ms"); fflush(stdout) }
        }
        runStage(in: wave1) {
            results.sharedVocab = VernacularAnalyzer.buildSharedVocabulary(messages: messages)
        }
        runStage(in: wave1) {
            let _tVP = benchEnabled ? Date() : nil
            results.profile = VernacularEngine.buildProfile(
                messages: messages, baseline: baseline, contacts: contacts,
                subject: profileSubject,
                config: profileConfig,
                tokenized: tokenizedCorpus)
            if let t = _tVP { print("BENCH::     buildAllSections.profile \(Int(Date().timeIntervalSince(t) * 1000)) ms"); fflush(stdout) }
        }
        // VIBE lens REMOVED (2026-06-05). The clustering math is real (deterministic
        // k-means), but it runs over a HARD-CODED 40-token slang dictionary + 7 style
        // features ported verbatim from a prototype (`VibeFeatures.slang` in
        // VibeModels.swift) — NOT the user's actually-discovered vocabulary. So the
        // dialect "vibe" is fixed, generic dimensions rather than something learned
        // from their data. Per the product call we drop the lens for now: emitting
        // `.empty` makes `VernacularViewModel` publish nil clusters → `SocialGraphPanel.hasVibe`
        // is false → the Vibe lens never appears in the mode picker. This also skips
        // its ~4s of compute. A FUTURE update should re-derive the vibe feature space
        // from the profile-backed vernacular surfaces
        // instead of a fixed list, then re-enable. VibeLoader / VibeModels /
        // VibeGraphCanvas stay in the tree as scaffolding for that work.
        results.vibe = .empty
        wave1.wait()

        let profileForSpread = results.profile ?? .disabled
        if profileForSpread.isEnabled {
            let _tSP = benchEnabled ? Date() : nil
            results.spreadProfile = buildSpread(
                profile: profileForSpread,
                messages: messages,
                baseline: baseline,
                config: profileConfig,
                chatParticipants: chatParticipants,
                options: graphOptions,
                minContactUses: profileConfig.minContactUsesForDocumentFrequency
            )
            if let t = _tSP { print("BENCH::     buildAllSections.spreadProfile \(Int(Date().timeIntervalSince(t) * 1000)) ms"); fflush(stdout) }
        } else {
            results.spreadProfile = .empty
        }

        let ling = results.ling!
        let signatureWords = ling.distinctiveWords.map {
            VernacularSignatureWord(word: $0.term, count: $0.userCount,
                                    timesMoreThanBaseline: $0.timesMoreThanBaseline,
                                    absentFromBaseline: $0.absentFromBaseline)
        }

        results.insights = VernacularAnalyzer.analyze(messages: messages, baseline: baseline,
                                                      signatureWords: signatureWords, options: options)

        let vocab = results.vocab!
        let (abbr, slang) = VernacularAnalyzer.splitVocab(vocab)

        let insights = results.insights!
        let gems = results.gems!
        let emphatic = results.emphatic!
        let emphasisSignals = results.emphasisSignals!
        // SHARED IN-GROUP VOCABULARY (Fix #2): the group dialect (curated slang ∩
        // usage, ≥4 sharers). Pure — same corpus, no extra read.
        let sharedVocab = results.sharedVocab!
        let vibe = results.vibe!
        let profile = results.profile ?? .disabled
        let spreadProfile = results.spreadProfile ?? .empty

        return AllSections(insights: insights, profile: profile, spreadProfile: spreadProfile,
                           tokenizedCorpus: tokenizedCorpus, reactedGems: gems,
                           emphaticConstructions: emphatic, emphasisSignals: emphasisSignals,
                           discoveredVocab: vocab, abbreviations: abbr, slangUsed: slang,
                           sharedVocabulary: sharedVocab, vibe: vibe)
    }
}
