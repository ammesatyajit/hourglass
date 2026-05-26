//
//  Tools.swift
//  Hourglass — Natural-language search
//
//  Tools the NL agent can call. The protocol shape is intentionally narrow:
//  the agent gets `search`, `oldestMatching`, and `context`. Each tool
//  wraps the existing `MessageSearch` / `FTSSearcher` engines — the agent
//  never talks to chat.db directly.
//
//  Why a protocol
//  --------------
//  - `MessageSearchTools` is the production impl wired to real engines.
//  - `MockNLAgentTools` (in tests) returns canned `MessageSearch.Result`
//    values so we can drive the agent loop without a chat.db at all.
//  - Future: a `HybridSearchTools` impl could route through dense recall
//    when search-quality agent ships embeddings (their Phase 2). Drop-in.
//
//  The protocol is `Sendable` so the agent can call tools from any actor /
//  task context. Concrete impls hold their (already-Sendable) engine
//  references.
//

import Foundation
import GRDB

/// Tool surface exposed to `NLAgent`. Every tool runs against the existing
/// chat.db / FTS5 mirror — the NL surface is strictly read-only on the
/// data plane.
public protocol NLAgentTools: Sendable {

    /// Run a structured search using the existing operator language.
    /// `query` is a string like `with:"Annika" last:14d argument` — exactly
    /// what the Spotlight panel's keyword path would accept. The LLM's
    /// planner emits queries in this language; this tool routes them
    /// through `MessageSearch` / `FTSSearcher`.
    ///
    /// `dateRange` is an optional widening applied on TOP of any date
    /// operator inside `query`. The two AND together (the more restrictive
    /// one wins) — same semantics as `MessageSearch.search(dateRange:)`.
    /// `limit` caps the result count; nil means exhaustive.
    /// `order` controls SQL `ORDER BY` direction — defaults to descending
    /// (newest first). Pass `.ascending` for chronological window scans
    /// where the EARLIEST N matters more than the newest (see `readMessages`).
    func search(
        query: String,
        dateRange: ClosedRange<Date>?,
        limit: Int?,
        order: MessageSearch.SortOrder
    ) async throws -> [MessageSearch.Result]

    /// Like `search` but pre-sorts the SQL result by date ASCENDING (oldest
    /// first) and returns the top-1 match. Used by `find_oldest_message`
    /// intent. Most efficient when the underlying query has filters that
    /// narrow the candidate set.
    func oldestMatching(query: String) async throws -> MessageSearch.Result?

    /// Return up to `before` messages preceding `guid` and `after` messages
    /// following it, in the same chat. Used by `find_cluster_start` to
    /// verify a candidate is actually the start of a topical cluster (the
    /// 5 messages before it should NOT match the same concept).
    ///
    /// Phase 1: implemented as a date-range scan around the GUID's row.
    /// Phase 3: optimized via direct ROWID neighbor lookup once we have
    /// chat-scoped row indexes.
    func context(
        forGUID guid: String,
        before: Int,
        after: Int
    ) async throws -> [MessageSearch.Result]

    /// Resolved contact display names from the AddressBook. Used by the
    /// rule-based fallback to extract person names from a free-text query
    /// ("argument with Annika two weeks ago" → recognise "Annika" as a
    /// real contact and emit `with:"Annika"`).
    ///
    /// Defaulted to `[]` so the protocol stays narrow and test mocks don't
    /// have to wire a contact list when they don't exercise the fallback.
    /// The production `MessageSearchTools` returns
    /// `instr.contacts.allContacts.map(\.displayName)`.
    func availableContactNames() async -> [String]

    // MARK: - Analytics / dashboard tools (Phase 2 ReAct loop)

    /// "People you text the most." Wraps the same analytics the dashboard
    /// shows under "Top People". Returns merged-by-resolved-name contact
    /// stats, ranked by total (sent + received) descending.
    ///
    /// `dateRange == nil` is all-time. `limit` caps the list (defaults
    /// to a sensible 10 for NL answers; the dashboard uses 50).
    ///
    /// Implementations should prefer the in-memory aggregate
    /// (`DashboardAllTimeAggregate.recomputeForRange`) when available
    /// for microsecond turnarounds, falling back to live SQL otherwise.
    func topContacts(
        in dateRange: ClosedRange<Date>?,
        limit: Int
    ) async throws -> [DashboardStats.ContactStat]

    /// "Group chats you text the most." Mirrors `topContacts` but ranks
    /// group chats (style 43) by `sentByYou` desc.
    func topGroups(
        in dateRange: ClosedRange<Date>?,
        limit: Int
    ) async throws -> [DashboardStats.GroupStat]

    /// Overview counters for a window — total / sent / received / distinct
    /// chats. Used for questions like "how many messages did I send in
    /// 2026" without needing a full search.
    ///
    /// When `dateRange == nil` this is the all-time overview. The chat
    /// count is the all-time number (it's stable across windows and the
    /// dashboard tile uses the same convention).
    func overviewStats(
        in dateRange: ClosedRange<Date>?
    ) async throws -> DashboardStats.OverviewCounters

    /// Run a `search` but return ONLY the count, not the result list.
    /// Cheaper than `search().count` when the LLM just needs a number
    /// for questions like "how many photos did I send last month".
    func countMatching(
        query: String,
        in dateRange: ClosedRange<Date>?
    ) async throws -> Int

    /// The single oldest match for `query` within `dateRange`. Clearer
    /// sibling of `oldestMatching` that accepts a window — the LLM uses
    /// this when locating the START of a topical cluster ("when did the
    /// argument actually start").
    ///
    /// Returns `nil` when no message matches.
    func firstMatching(
        query: String,
        in dateRange: ClosedRange<Date>?
    ) async throws -> MessageSearch.Result?

    /// Fetch `before` messages BEFORE and `after` messages AFTER `date`
    /// in the conversation identified by `chatRowID`. If `chatRowID` is
    /// nil, any chat is allowed. Used by the LLM to zoom into the
    /// surroundings of a candidate moment ("what did we actually say
    /// after the argument started").
    func messagesAroundTime(
        date: Date,
        chatRowID: Int64?,
        before: Int,
        after: Int
    ) async throws -> [MessageSearch.Result]

    /// Read a chronological dump of messages in a date window, optionally
    /// scoped to one person. Returns up to `limit` messages ordered
    /// chronologically (oldest → newest) so the model can SCAN the
    /// conversation and decide where to zoom in.
    ///
    /// This is the "let me actually read what was said" tool, distinct
    /// from `search` (which is keyword-driven). Use it for investigative
    /// queries — "find my argument with Annika 3 weeks ago" — where the
    /// model needs to read the tone of the conversation before it can
    /// identify the cluster start.
    ///
    /// `personName` matches against the contact name (resolves to a
    /// `with:NAME` operator under the hood — every chat the person is in).
    /// Pass `nil` to dump messages across all chats in the window.
    ///
    /// `dateRange == nil` is unbounded (rare — caller should normally
    /// scope to last N weeks).
    func readMessages(
        in dateRange: ClosedRange<Date>?,
        with personName: String?,
        limit: Int
    ) async throws -> [MessageSearch.Result]

    /// LAST-RESORT escape hatch — execute an arbitrary read-only SQL
    /// query against chat.db. Returns up to `limit` rows shaped as
    /// `[String: String]` (column name → stringified value). The LLM is
    /// instructed to AVOID this tool unless every other primitive fails.
    ///
    /// Implementations MUST guard against mutations: open the connection
    /// read-only, reject statements that aren't a SELECT, and cap the
    /// row count.
    func rawSearchSQL(
        sql: String,
        limit: Int
    ) async throws -> [[String: String]]
}

public extension NLAgentTools {
    /// Convenience overload — defaults `order` to `.descending` so the
    /// many existing callers that don't care about ordering keep
    /// working. The order-aware shape lives on the protocol; this
    /// extension just supplies the default.
    func search(
        query: String,
        dateRange: ClosedRange<Date>?,
        limit: Int?
    ) async throws -> [MessageSearch.Result] {
        try await search(query: query, dateRange: dateRange, limit: limit, order: .descending)
    }

    func availableContactNames() async -> [String] { [] }
    func topContacts(in dateRange: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.ContactStat] { [] }
    func topGroups(in dateRange: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.GroupStat] { [] }
    func overviewStats(in dateRange: ClosedRange<Date>?) async throws -> DashboardStats.OverviewCounters {
        DashboardStats.OverviewCounters(total: 0, sent: 0, received: 0, chats: 0, oldest: nil, newest: nil)
    }
    func countMatching(query: String, in dateRange: ClosedRange<Date>?) async throws -> Int {
        try await search(query: query, dateRange: dateRange, limit: nil).count
    }
    func firstMatching(query: String, in dateRange: ClosedRange<Date>?) async throws -> MessageSearch.Result? {
        try await search(query: query, dateRange: dateRange, limit: nil).last
    }
    func messagesAroundTime(date: Date, chatRowID: Int64?, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
    func readMessages(in dateRange: ClosedRange<Date>?, with personName: String?, limit: Int) async throws -> [MessageSearch.Result] {
        // Default delegates to `search` with a `with:NAME` operator when
        // a person is given, and an empty needle (no text filter). The
        // production impl on `MessageSearchTools` reverses the sort to
        // chronological. Mocks can override directly.
        let parts: [String]
        if let name = personName, !name.isEmpty {
            let needsQuotes = name.contains(" ") || name.contains("\"")
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let token = needsQuotes ? "with:\"\(escaped)\"" : "with:\(name)"
            parts = [token]
        } else {
            parts = []
        }
        let query = parts.joined(separator: " ")
        let results = try await search(query: query, dateRange: dateRange, limit: limit)
        // search() returns DESC (newest first). Reverse for chronological.
        return results.reversed()
    }
    func rawSearchSQL(sql: String, limit: Int) async throws -> [[String: String]] { [] }
}

// MARK: - Production impl

/// `NLAgentTools` backed by the real search engines. Holds a reference to
/// the FTS5-or-INSTR routing path used elsewhere in the app — *exactly*
/// the same behavior the keyword Spotlight panel sees.
///
/// The two-track FTS5/INSTR routing already lives inside `SearchViewModel`
/// — for the NL agent we keep things explicit and let the caller pass in
/// whichever search engine they want. Defaults to picking FTS when fresh.
public struct MessageSearchTools: NLAgentTools {

    /// The INSTR-based engine (always available, ~1 s per query on 525k rows).
    public let instr: MessageSearch
    /// The FTS5-based engine (3 ms per query, available when mirror is fresh).
    public let fts: FTSSearcher?
    /// IndexStore for freshness checks. Nil disables FTS routing entirely.
    public let indexStore: IndexStore?
    /// The chat.db handle. Used for context-window scans.
    public let chatDB: ChatDatabase

    public init(
        instr: MessageSearch,
        fts: FTSSearcher?,
        indexStore: IndexStore?,
        chatDB: ChatDatabase
    ) {
        self.instr = instr
        self.fts = fts
        self.indexStore = indexStore
        self.chatDB = chatDB
    }

    public func search(
        query: String,
        dateRange: ClosedRange<Date>?,
        limit: Int?,
        order: MessageSearch.SortOrder
    ) async throws -> [MessageSearch.Result] {
        // Route to FTS when fresh, INSTR otherwise — same policy as
        // SearchViewModel.search. We make the cheap freshness check here
        // rather than caching at init so a long-lived `MessageSearchTools`
        // doesn't go stale.
        let useFTS = shouldUseFTS()
        let results: [MessageSearch.Result]
        if useFTS, let fts {
            results = try fts.search(
                phrase: query,
                dateRange: dateRange,
                limit: limit,
                order: order
            )
        } else {
            results = try instr.search(
                phrase: query,
                dateRange: dateRange,
                limit: limit,
                order: order
            )
        }
        return results
    }

    public func oldestMatching(query: String) async throws -> MessageSearch.Result? {
        // Phase 1: run a normal exhaustive search, then take the first
        // chronologically. Phase 3 can push the ORDER BY ASC + LIMIT 1
        // into SQL for speed; we don't bother yet because oldest-message
        // queries are uncommon and the operator-narrowed candidate set is
        // usually small.
        let all = try await search(query: query, dateRange: nil, limit: nil)
        // `MessageSearch.search` returns DESC (newest first). The oldest
        // is the last element.
        return all.last
    }

    public func context(
        forGUID guid: String,
        before: Int,
        after: Int
    ) async throws -> [MessageSearch.Result] {
        // We need: (chat_id, date) for this message, then surrounding rows
        // in the same chat ordered by date. The query goes against chat.db
        // directly — small and bounded, no FTS5 needed.
        let beforeCount = max(0, before)
        let afterCount = max(0, after)

        // Look up the anchor row: chat_id + date for the given GUID.
        // In async contexts GRDB picks the async `read` overload — that
        // requires a Sendable closure.
        let anchorRow: Row? = try await chatDB.dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT cmj.chat_id AS chat_id, m.date AS date
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.guid = ?
                LIMIT 1
                """, arguments: [guid])
        }
        guard let anchorRow else { return [] }
        let anchorChatID: Int64 = anchorRow["chat_id"]
        let anchorDate: Int64 = anchorRow["date"]

        // The selected columns mirror what MessageSearch.search reads so we
        // can reuse the same row→Result decoding logic.
        let columnList = """
            m.ROWID                   AS rowid,
            m.guid                    AS guid,
            m.date                    AS date,
            m.is_from_me              AS is_from_me,
            m.text                    AS text,
            m.attributedBody          AS attributedBody,
            m.associated_message_type AS associated_message_type,
            h.id                      AS sender_handle,
            cmj.chat_id               AS chat_id,
            ch.style                  AS chat_style,
            ch.display_name           AS chat_display_name,
            ch.guid                   AS chat_guid
            """
        let beforeSQL = """
            SELECT \(columnList)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ?
              AND m.associated_message_type = 0
              AND m.date < ?
            ORDER BY m.date DESC
            LIMIT ?
            """
        let afterSQL = """
            SELECT \(columnList)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ?
              AND m.associated_message_type = 0
              AND m.date > ?
            ORDER BY m.date ASC
            LIMIT ?
            """

        // Over-fetch 2x to absorb tapbacks/hidden rows the WHERE drops.
        let beforeRows: [Row] = (try? await chatDB.dbQueue.read { db in
            try Row.fetchAll(db, sql: beforeSQL,
                             arguments: [anchorChatID, anchorDate, beforeCount * 2])
        }) ?? []
        let afterRows: [Row] = (try? await chatDB.dbQueue.read { db in
            try Row.fetchAll(db, sql: afterSQL,
                             arguments: [anchorChatID, anchorDate, afterCount * 2])
        }) ?? []

        let mapped: (Row) -> MessageSearch.Result = { row in
            let rawDate: Int64 = row["date"]
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
            let isFromMe = (row["is_from_me"] as Int? ?? 0) == 1
            let senderHandle: String? = row["sender_handle"]
            let chatDisplayName: String? = row["chat_display_name"]
            let chatStyle: Int? = row["chat_style"]
            let m = Message(
                id: row["rowid"],
                guid: row["guid"],
                date: MessageDate.date(fromRaw: rawDate),
                isFromMe: isFromMe,
                chatRowID: row["chat_id"],
                senderHandle: senderHandle,
                chatStyle: chatStyle,
                chatDisplayName: chatDisplayName,
                body: body,
                associatedMessageType: row["associated_message_type"] as Int? ?? 0
            )
            let partner: String
            // Match MessageSearch / FTSSearcher: no "[group] " text prefix —
            // the UI shows a person.3 SF Symbol from `chatStyle == 43`.
            if let dn = chatDisplayName, !dn.isEmpty { partner = dn }
            else { partner = senderHandle ?? "(unknown)" }
            let sender = isFromMe ? "You" : (senderHandle ?? "(unknown)")
            return MessageSearch.Result(
                message: m,
                partnerName: partner,
                senderName: sender,
                chatGUID: row["chat_guid"]
            )
        }

        var resBefore = beforeRows.prefix(beforeCount).map(mapped)
        let resAfter  = afterRows.prefix(afterCount).map(mapped)
        // Return in chronological order (oldest → newest) so the agent
        // sees the cluster naturally.
        resBefore.reverse()
        return Array(resBefore) + Array(resAfter)
    }

    /// Real contact names known to the AddressBook. Surfaces to the NL
    /// agent's rule-based fallback so it can recognise person names in a
    /// free-text query like "find my argument with annika".
    public func availableContactNames() async -> [String] {
        instr.contacts.allContacts.map(\.displayName)
    }

    // MARK: - Analytics tool implementations
    //
    // These wrap the same `DashboardLoader` queries the dashboard uses.
    // We run them on the GRDB read queue (synchronously, but inside an
    // async function so the agent can `await`). No SQL injection surface
    // — every query is parameterized through the loader's prepared
    // statements.

    public func topContacts(
        in dateRange: ClosedRange<Date>?,
        limit: Int
    ) async throws -> [DashboardStats.ContactStat] {
        let contacts = instr.contacts
        let chatDB = self.chatDB
        return try await Task.detached(priority: .userInitiated) {
            try chatDB.dbQueue.read { db in
                try DashboardLoader.loadTopContacts(
                    db: db,
                    dateRange: dateRange,
                    contacts: contacts,
                    limit: max(1, limit)
                )
            }
        }.value
    }

    public func topGroups(
        in dateRange: ClosedRange<Date>?,
        limit: Int
    ) async throws -> [DashboardStats.GroupStat] {
        let contacts = instr.contacts
        let chatDB = self.chatDB
        return try await Task.detached(priority: .userInitiated) {
            try chatDB.dbQueue.read { db in
                try DashboardLoader.loadTopGroups(
                    db: db,
                    dateRange: dateRange,
                    contacts: contacts,
                    limit: max(1, limit)
                )
            }
        }.value
    }

    public func overviewStats(
        in dateRange: ClosedRange<Date>?
    ) async throws -> DashboardStats.OverviewCounters {
        let chatDB = self.chatDB
        // For all-time, the dashboard loader already has the right shape.
        // For a window, we shadow the same query with a date predicate
        // so this tool can answer "how many messages did I send in 2026"
        // without a full search.
        if dateRange == nil {
            return try await Task.detached(priority: .userInitiated) {
                try chatDB.dbQueue.read { db in
                    try DashboardLoader.loadOverview(db: db)
                }
            }.value
        }
        let range = dateRange!
        return try await Task.detached(priority: .userInitiated) { () throws -> DashboardStats.OverviewCounters in
            try chatDB.dbQueue.read { db in
                let (dateSQL, dateArgs) = DashboardLoader.dateClause(range)
                struct Row1: FetchableRecord {
                    let total: Int
                    let sent: Int
                    let received: Int
                    init(row: Row) {
                        total = row["total"] ?? 0
                        sent = row["sent"] ?? 0
                        received = row["received"] ?? 0
                    }
                }
                let countersSQL = """
                    SELECT
                        COUNT(*)                                                       AS total,
                        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END)              AS sent,
                        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
                    FROM message m
                    WHERE m.associated_message_type = 0
                      \(dateSQL)
                    """
                let counters = try Row1.fetchOne(db, sql: countersSQL, arguments: StatementArguments(dateArgs))
                let chatsSQL = """
                    SELECT COUNT(DISTINCT cmj.chat_id)
                    FROM chat_message_join cmj
                    JOIN message m ON m.ROWID = cmj.message_id
                    WHERE m.associated_message_type = 0
                      \(dateSQL)
                    """
                let chats = try Int.fetchOne(db, sql: chatsSQL, arguments: StatementArguments(dateArgs)) ?? 0
                return DashboardStats.OverviewCounters(
                    total: counters?.total ?? 0,
                    sent: counters?.sent ?? 0,
                    received: counters?.received ?? 0,
                    chats: chats,
                    oldest: range.lowerBound,
                    newest: range.upperBound
                )
            }
        }.value
    }

    public func countMatching(
        query: String,
        in dateRange: ClosedRange<Date>?
    ) async throws -> Int {
        // We could push COUNT(*) into SQL, but the existing search
        // pipeline already applies the body refinement (PhraseQuery AST)
        // which SQL alone cannot replicate. So we run the regular search
        // and count the returned set. This stays under sub-second for
        // any reasonable query on the user's DB.
        let results = try await search(query: query, dateRange: dateRange, limit: nil)
        return results.count
    }

    public func firstMatching(
        query: String,
        in dateRange: ClosedRange<Date>?
    ) async throws -> MessageSearch.Result? {
        let results = try await search(query: query, dateRange: dateRange, limit: nil)
        // `search` returns DESC (newest first); oldest is the tail.
        return results.last
    }

    public func messagesAroundTime(
        date: Date,
        chatRowID: Int64?,
        before: Int,
        after: Int
    ) async throws -> [MessageSearch.Result] {
        let beforeCount = max(0, before)
        let afterCount = max(0, after)
        guard beforeCount + afterCount > 0 else { return [] }

        // Express `date` in both ns and seconds Mac-absolute-time so we
        // can match rows in either format (the dual-format rule lives in
        // plans.md → "Critical Technical Knowledge").
        let anchorNS = MessageDate.nanosecondsSinceMacEpoch(from: date)
        let anchorS = MessageDate.secondsSinceMacEpoch(from: date)

        // Column list mirrors `MessageSearch.search` so we can reuse the
        // same Row → Result decoding path.
        let columnList = """
            m.ROWID                   AS rowid,
            m.guid                    AS guid,
            m.date                    AS date,
            m.is_from_me              AS is_from_me,
            m.text                    AS text,
            m.attributedBody          AS attributedBody,
            m.associated_message_type AS associated_message_type,
            h.id                      AS sender_handle,
            cmj.chat_id               AS chat_id,
            ch.style                  AS chat_style,
            ch.display_name           AS chat_display_name,
            ch.guid                   AS chat_guid
            """
        let chatScope: String
        var chatArgs: [DatabaseValueConvertible] = []
        if let chatRowID {
            chatScope = "AND cmj.chat_id = ?"
            chatArgs.append(chatRowID)
        } else {
            chatScope = ""
        }
        let beforeSQL = """
            SELECT \(columnList)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
              \(chatScope)
              AND (
                  (m.date > 1000000000000 AND m.date < ?)
               OR (m.date <= 1000000000000 AND m.date < ?)
              )
            ORDER BY m.date DESC
            LIMIT ?
            """
        let afterSQL = """
            SELECT \(columnList)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
              \(chatScope)
              AND (
                  (m.date > 1000000000000 AND m.date >= ?)
               OR (m.date <= 1000000000000 AND m.date >= ?)
              )
            ORDER BY m.date ASC
            LIMIT ?
            """

        var beforeArgs: [DatabaseValueConvertible] = chatArgs
        beforeArgs.append(anchorNS)
        beforeArgs.append(anchorS)
        beforeArgs.append(beforeCount)

        var afterArgs: [DatabaseValueConvertible] = chatArgs
        afterArgs.append(anchorNS)
        afterArgs.append(anchorS)
        afterArgs.append(afterCount)

        let chatDB = self.chatDB
        let contacts = instr.contacts

        // Map rows to Sendable Results INSIDE the read block — GRDB's
        // `Row` is not Sendable, so we can't cross the actor hop with it.
        let (resBefore, resAfter): ([MessageSearch.Result], [MessageSearch.Result]) =
            try await Task.detached(priority: .userInitiated) { () throws -> ([MessageSearch.Result], [MessageSearch.Result]) in
                try chatDB.dbQueue.read { db -> ([MessageSearch.Result], [MessageSearch.Result]) in
                    let bRows = try Row.fetchAll(db, sql: beforeSQL, arguments: StatementArguments(beforeArgs))
                    let aRows = try Row.fetchAll(db, sql: afterSQL, arguments: StatementArguments(afterArgs))
                    let map: (Row) -> MessageSearch.Result = { row in
                        let rawDate: Int64 = row["date"]
                        let text: String? = row["text"]
                        let blob: Data? = row["attributedBody"]
                        let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
                        let isFromMe = (row["is_from_me"] as Int? ?? 0) == 1
                        let senderHandle: String? = row["sender_handle"]
                        let chatDisplayName: String? = row["chat_display_name"]
                        let chatStyle: Int? = row["chat_style"]
                        let m = Message(
                            id: row["rowid"],
                            guid: row["guid"],
                            date: MessageDate.date(fromRaw: rawDate),
                            isFromMe: isFromMe,
                            chatRowID: row["chat_id"],
                            senderHandle: senderHandle,
                            chatStyle: chatStyle,
                            chatDisplayName: chatDisplayName,
                            body: body,
                            associatedMessageType: row["associated_message_type"] as Int? ?? 0
                        )
                        let partner: String
                        if let dn = chatDisplayName, !dn.isEmpty { partner = dn }
                        else { partner = senderHandle ?? "(unknown)" }
                        let sender: String
                        if isFromMe { sender = "You" }
                        else if let raw = senderHandle { sender = contacts.name(forRawHandle: raw) }
                        else { sender = "(unknown)" }
                        return MessageSearch.Result(
                            message: m,
                            partnerName: partner,
                            senderName: sender,
                            chatGUID: row["chat_guid"]
                        )
                    }
                    return (bRows.map(map), aRows.map(map))
                }
            }.value

        // Return in chronological order — oldest before first, then
        // newest after.
        var orderedBefore = resBefore
        orderedBefore.reverse()
        return orderedBefore + resAfter
    }

    /// Production impl of `readMessages`. Delegates to `search()` with a
    /// `with:NAME` operator (when `personName != nil`) and then reverses
    /// the result list to chronological order. This is the "let the model
    /// scan the convo" tool the iterative ReAct loop uses to decide where
    /// to zoom in.
    public func readMessages(
        in dateRange: ClosedRange<Date>?,
        with personName: String?,
        limit: Int
    ) async throws -> [MessageSearch.Result] {
        let safeLimit = max(1, min(limit, 100))
        var parts: [String] = []
        if let name = personName, !name.isEmpty {
            let needsQuotes = name.contains(" ") || name.contains("\"")
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            let token = needsQuotes ? "with:\"\(escaped)\"" : "with:\(name)"
            parts.append(token)
        }
        let query = parts.joined(separator: " ")
        // Pass `.ascending` so SQL returns the OLDEST N rows in the
        // window — not the newest N. For an investigative query like
        // "find the argument with Annika 3 weeks ago," the model needs
        // to see the start of the window where the argument began. With
        // DESC + limit the model only ever saw the tail of the window
        // (this week's messages) and missed the older context entirely.
        // Bug pinned by codex audit M4 (2026-05-25).
        return try await search(
            query: query,
            dateRange: dateRange,
            limit: safeLimit,
            order: .ascending
        )
    }

    /// Read-only SQL escape hatch. The LLM is instructed to NEVER call
    /// this when one of the higher-level tools fits. We still defend in
    /// depth: reject non-SELECT statements, cap the row count, and
    /// stringify every value so the LLM can read the result.
    public func rawSearchSQL(
        sql: String,
        limit: Int
    ) async throws -> [[String: String]] {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Defense: only single SELECTs. The chat.db connection is opened
        // read-only at the GRDB level, but a multi-statement input could
        // still execute pragmas or attach side effects.
        guard lower.hasPrefix("select ") || lower.hasPrefix("with ") else {
            throw NSError(domain: "MessageSearchTools.rawSearchSQL",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Only SELECT / WITH queries are allowed."])
        }
        if trimmed.contains(";") {
            // Bare semicolons that aren't the trailing one are suspicious.
            let body = trimmed.dropLast(trimmed.hasSuffix(";") ? 1 : 0)
            if body.contains(";") {
                throw NSError(domain: "MessageSearchTools.rawSearchSQL",
                              code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Multi-statement queries are not allowed."])
            }
        }
        let safeLimit = max(1, min(limit, 200))
        // Wrap the LLM's SELECT in an outer `LIMIT` so SQLite stops
        // producing rows at the cap instead of materializing the entire
        // result set into memory and slicing afterward. Without this an
        // LLM-emitted `SELECT * FROM message` would load ~500k rows
        // before we drop them. Strip a trailing semicolon (already
        // guarded above as the only allowed one) so the wrapping
        // parens close cleanly.
        let stripped = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
        let wrapped = "SELECT * FROM (\(stripped)) LIMIT \(safeLimit)"
        let chatDB = self.chatDB
        return try await Task.detached(priority: .userInitiated) { () throws -> [[String: String]] in
            try chatDB.dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: wrapped)
                var out: [[String: String]] = []
                out.reserveCapacity(rows.count)
                for row in rows {
                    var dict: [String: String] = [:]
                    for col in row.columnNames {
                        let v = row[col]
                        dict[col] = String(describing: v as Any)
                    }
                    out.append(dict)
                }
                return out
            }
        }.value
    }

    /// Decide whether to route a search through FTS5. Cheap (microseconds).
    private func shouldUseFTS() -> Bool {
        guard let indexStore else { return false }
        guard fts != nil else { return false }
        let freshness = (try? indexStore.freshness(against: chatDB)) ?? .missing
        switch freshness {
        case .ready: return true
        case .behind, .missing: return false
        }
    }
}

