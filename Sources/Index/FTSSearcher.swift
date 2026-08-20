//
//  FTSSearcher.swift
//  Hourglass
//
//  Query path for the FTS5 trigram mirror. Produces the same
//  `[MessageSearch.Result]` shape as the INSTR-based path so the view model
//  doesn't have to know which path ran.
//
//  How this fits in
//  ----------------
//  - The INSTR path (`MessageSearch.search`) remains the source of truth for
//    correctness and is still the fallback when the index is missing or
//    behind. See `docs/search-design.md` § "Two-track strategy".
//  - The FTS5 path is an *optimization*: when the mirror is fresh, we run
//    the lexical recall against it (sub-3ms on 525k rows) and reuse the
//    INSTR path's join+post-processing helpers to materialize Results.
//  - All filters (date / chat / from / to / type / reactions) are
//    re-evaluated against chat.db via cross-DB join, so the FTS5 result
//    is identical to what INSTR would have produced.
//
//  FTS5 query construction
//  -----------------------
//  - Free-text needles become quoted phrase tokens, AND'd together. Quoting
//    is required so trigram MATCH treats the input as a substring rather
//    than tokenized words. Example: `"cactus" "offer"` matches messages
//    containing both substrings.
//  - Filter prefixes (chat:/from:/last:/etc.) don't go into the MATCH
//    expression — they're applied as SQL predicates against `message_meta`
//    and chat.db join targets.
//  - Empty needles list (no free text) means "match everything" — we omit
//    the FTS5 MATCH and rely on the filters only. This lets `from:Mom
//    last:7d` work without typing any text.
//

import Foundation
import GRDB

public struct FTSSearcher: Sendable {

    public let store: IndexStore
    public let chatDB: ChatDatabase
    public let contacts: ResolvedContacts

    public init(store: IndexStore, chatDB: ChatDatabase, contacts: ResolvedContacts) {
        self.store = store
        self.chatDB = chatDB
        self.contacts = contacts
    }

    /// Run a search using the FTS5 mirror. Same signature as
    /// `MessageSearch.search` so SearchViewModel can swap between them.
    public func search(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int? = nil,
        now: Date = Date(),
        caseSensitive: Bool = false,
        order: MessageSearch.SortOrder = .descending
    ) throws -> [MessageSearch.Result] {

        let parsed = MessageSearch.parseQuery(phrase, contacts: contacts, now: now)
        // Parse the free-text into the structured AST. Same parser the
        // INSTR path uses; we then introspect to decide whether the FTS5
        // mirror can serve this query at all.
        let phraseAST = try PhraseQuery.parse(parsed.freeText, caseSensitive: caseSensitive)

        // FTS5 can't help with:
        //   (a) Regex needles — there's no equivalent in MATCH syntax.
        //   (b) Terms shorter than 3 characters — SQLite's trigram
        //       tokenizer can't index or query those. (A 2-char "hi"
        //       query against the trigram index silently returns zero.)
        //
        // Either condition forces us to delegate to the INSTR path,
        // which can handle both correctness paths. The delegation is
        // the entire fallback — we don't try to half-execute on FTS5.
        //
        //   (c) NO free text at all (operator-only queries like
        //       `with:"Bec` mid-type, or `in:"…" reactions:>=5`) — the
        //       MATCH degenerates to `1`, so the FTS join is pure
        //       overhead AND it defeats chat.db's date-index early-exit:
        //       measured 8.3s (FTS, capped) vs 0.14s (INSTR, capped) for
        //       a live `with:"Be` keystroke over 657k rows.
        if phraseAST.isEmpty || phraseAST.containsRegex || phraseAST.containsShortTerm(minLength: 3) {
            let fallback = MessageSearch(database: chatDB, contacts: contacts)
            return try fallback.search(
                phrase: phrase,
                person: person,
                dateRange: dateRange,
                limit: limit,
                now: now,
                caseSensitive: caseSensitive,
                order: order
            )
        }

        // Caller `dateRange` AND any parsed date range. Codex audit H1
        // fix — use the three-state constraint so contradictory date
        // filters short-circuit to zero rows instead of broadening. Also
        // honor the parser-detected empty constraint.
        if parsed.dateConstraintIsEmpty { return [] }
        let combinedConstraint = MessageSearch.intersectConstraint(dateRange, parsed.dateRange)
        if case .empty = combinedConstraint { return [] }
        let combinedRange: ClosedRange<Date>?
        switch combinedConstraint {
        case .unbounded: combinedRange = nil
        case .range(let r): combinedRange = r
        case .empty: combinedRange = nil  // unreachable due to early return
        }

        // Build the FTS5 MATCH expression from the AST. Each term needle
        // becomes a quoted substring; groups OR within, AND across.
        // With the trigram tokenizer, a quoted phrase matches as a
        // literal substring (no word-boundary issues at this layer — the
        // word-boundary refinement happens Swift-side).
        //
        // Note: FTS5 special chars (`"`, `*`, parens, etc.) get
        // escaped by quote-doubling the inner contents. We use a simple
        // quote-escape since trigram needles never need wildcard support.
        let ftsExpression: String? = Self.buildFTS5Expression(from: phraseAST)

        // Build the SQL — we run it on chat.db's queue and ATTACH the
        // index file as `idx`. See comment near the executor below.

        // Compose the WHERE clause from filter clauses on the source side.
        // Reuse `MessageSearch.{chat,from,to,reactions,type,date}Clause`
        // helpers — they emit SQL against the same chat.db column names
        // (m.text, m.attributedBody, ch.display_name, h.id) which we keep
        // by aliasing the join targets the same way.
        let (chatSQL, chatArgs) = MessageSearch.chatClause(parsed.chatFilters, contacts: contacts)
        let (fromSQL, fromArgs) = MessageSearch.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs)     = MessageSearch.toClause(parsed.toFilters, contacts: contacts)
        let (withSQL, withArgs) = MessageSearch.withClause(parsed.withFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = MessageSearch.reactionsClause(parsed.reactionFilters)
        let typeSQL = MessageSearch.typeClause(parsed.typeFilters)
        // Date — push down to message_meta.date for speed (the indexed
        // column lives in the mirror, no join needed).
        let (metaDateSQL, metaDateArgs) = Self.metaDateClause(combinedRange)

        let matchSQL: String
        var matchArgs: [DatabaseValueConvertible] = []
        if let ftsExpression {
            matchSQL = "messages_fts MATCH ?"
            matchArgs.append(ftsExpression)
        } else {
            // No text needles — apply filters only. We still need to read
            // from the mirror's meta table so the rest of the query has
            // something to filter on. Skip the FTS table entirely.
            matchSQL = "1"
        }

        // Run on chat.db's connection — we ATTACH the index file there. This
        // avoids opening a third concurrent handle to chat.db (which is
        // already opened twice: by the main `ChatDatabase` and by the
        // background `IndexBuilder`). SQLite can deadlock at the OS-file-lock
        // level when several read-only handles to the same path race for an
        // exclusive lock during ATTACH. Going through the existing chat.db
        // queue removes that source of contention.
        //
        // The mirror tables are then addressed as `idx.messages_fts`,
        // `idx.message_meta`. Chat.db tables (`message`, `chat`, etc.) live
        // at the unqualified top.
        let limitSQL = limit.map { _ in "LIMIT ?" } ?? ""

        // Note: FTS5 MATCH expressions are written with the UNQUALIFIED table
        // name even when the table is in an attached schema. SQLite resolves
        // this through the FROM clause's schema, so `FROM idx.messages_fts`
        // + `WHERE messages_fts MATCH ?` works correctly. Writing the WHERE
        // as `WHERE idx.messages_fts MATCH ?` fails with `no such column`.
        let usingFTS = ftsExpression != nil
        let fromClause: String
        if usingFTS {
            fromClause = """
            FROM idx.messages_fts
            JOIN idx.message_meta meta ON meta.rowid = idx.messages_fts.rowid
            """
        } else {
            fromClause = "FROM idx.message_meta meta"
        }

        let sql = """
            \(fromClause)
            JOIN chat_message_join cmj ON cmj.message_id = meta.rowid
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = meta.handle_id
            JOIN message m ON m.ROWID = meta.rowid
            WHERE \(matchSQL)
              AND meta.associated_message_type = 0
              \(metaDateSQL)
              \(chatSQL)
              \(fromSQL)
              \(toSQL)
              \(withSQL)
              \(reactionsSQL)
              \(typeSQL)
            ORDER BY meta.date \(order == .ascending ? "ASC" : "DESC")
            \(limitSQL)
            """

        let selectSQL = """
            SELECT
                meta.rowid                AS msg_rowid,
                meta.guid                 AS guid,
                meta.date                 AS date,
                meta.is_from_me           AS is_from_me,
                m.text                    AS text,
                m.attributedBody          AS attributedBody,
                meta.associated_message_type AS associated_message_type,
                h.id                      AS sender_handle,
                -- IMPORTANT: read chat_id from cmj (always non-NULL via the
                -- INNER JOIN) NOT from meta (where the column is nullable).
                -- We used to crash with `Row.subscript.getter` assertion
                -- failures because some indexed rows had meta.chat_id = NULL
                -- while the join still resolved.
                cmj.chat_id               AS chat_id,
                ch.style                  AS chat_style,
                ch.display_name           AS chat_display_name,
                ch.guid                   AS chat_guid
            \(sql)
            """

        var args: [DatabaseValueConvertible] = matchArgs
        args.append(contentsOf: metaDateArgs)
        args.append(contentsOf: chatArgs)
        args.append(contentsOf: fromArgs)
        args.append(contentsOf: toArgs)
        args.append(contentsOf: withArgs)
        args.append(contentsOf: reactionsArgs)
        // Candidate overfetch — see MessageSearch.search: a bare LIMIT bounds
        // candidates BEFORE the Swift-side phrase refinement below, which can
        // silently drop older matches. Overfetch 8×; the post-loop guard
        // rescans unbounded when refinement couldn't fill the cap from a
        // truncated candidate set.
        let candidateLimit = limit.map { $0 * 8 }
        if let candidateLimit { args.append(candidateLimit) }

        let indexPath = store.url.path
        let rows: [Row] = try chatDB.dbQueue.writeWithoutTransaction { db in
            try db.execute(
                sql: "ATTACH DATABASE ? AS idx",
                arguments: [indexPath]
            )
            defer { try? db.execute(sql: "DETACH DATABASE idx") }
            return try Row.fetchAll(db, sql: selectSQL, arguments: StatementArguments(args))
        }

        // Materialize Result rows. Same body refinement + person check the
        // INSTR path does, for safety: if the FTS match returns a row whose
        // decoded body actually doesn't contain the needle (extraordinarily
        // rare given trigram precision), we drop it.
        var partnerNameCache: [Int64: String] = [:]
        var chatHandlesCache: [Int64: [Handle]] = [:]
        var results: [MessageSearch.Result] = []
        results.reserveCapacity(min(rows.count, 256))

        for (rowIndex, row) in rows.enumerated() {
            // Cooperative cancellation: hydration (attributedBody decode per
            // row) is the expensive half of a search. When the live-typing
            // path supersedes this search, stop wasting CPU mid-loop instead
            // of finishing a result set nobody will look at.
            if rowIndex % 256 == 255 { try Task.checkCancellation() }
            // Defensive optional reads — every column that COULD return
            // NULL is decoded as optional and skipped if missing, instead
            // of force-decoding and crashing the app. Bug history: we
            // shipped force-decodes that crashed on any row where
            // meta.chat_id was NULL (the column is nullable in the
            // schema). Same defensive treatment for date/rowid: schemas
            // and joins SHOULD make them non-NULL, but a corrupted
            // index file or a mid-build read could violate that
            // invariant and we'd rather skip a row than crash.
            guard let rawDate: Int64 = row["date"],
                  let msgRowID: Int64 = row["msg_rowid"],
                  let chatID: Int64 = row["chat_id"] else {
                continue
            }
            let date = MessageDate.date(fromRaw: rawDate)
            let isFromMe: Bool = (row["is_from_me"] as Int? ?? 0) == 1
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)

            if !phraseAST.isEmpty {
                // Refine the FTS5 trigram recall with the AST's
                // word-boundary / substring / regex semantics. Trigram
                // recall is byte-substring; without this step a search
                // for `the` (bare, word-boundary by default) would
                // include "father", "other", etc.
                if !phraseAST.matches(body: body, caseSensitive: caseSensitive) {
                    continue
                }
            }

            // chatID + msgRowID + rawDate already extracted above in the
            // guard at the top of the loop body. Read the rest as
            // optional and let them flow through nil-tolerant downstream
            // helpers (Message + partnerName).
            let senderHandle: String? = row["sender_handle"]
            let chatStyle: Int? = row["chat_style"]
            let chatDisplayName: String? = row["chat_display_name"]
            let messageGUID: String? = row["guid"]
            let chatGUID: String? = row["chat_guid"]

            if let person {
                let participantHandles: [Handle]
                if isFromMe {
                    participantHandles = self.handles(forChat: chatID, cache: &chatHandlesCache)
                } else {
                    participantHandles = senderHandle.map { [Handle(raw: $0)] } ?? []
                }
                let matches = participantHandles.contains { person.handles.contains($0) }
                if !matches { continue }
            }

            let message = Message(
                id: msgRowID,
                guid: messageGUID,
                date: date,
                isFromMe: isFromMe,
                chatRowID: chatID,
                senderHandle: senderHandle,
                chatStyle: chatStyle,
                chatDisplayName: chatDisplayName,
                body: body,
                associatedMessageType: row["associated_message_type"] as Int? ?? 0
            )

            let partner = partnerName(
                forChat: chatID,
                style: chatStyle,
                displayName: chatDisplayName,
                cache: &partnerNameCache,
                handlesCache: &chatHandlesCache
            )

            let sender: String
            let senderAvatar: Data?
            if isFromMe {
                sender = "You"
                senderAvatar = nil
            } else if let raw = senderHandle {
                sender = contacts.name(forRawHandle: raw)
                senderAvatar = contacts.avatarData(forRawHandle: raw)
            } else {
                sender = "(unknown)"
                senderAvatar = nil
            }

            results.append(MessageSearch.Result(
                message: message,
                partnerName: partner,
                senderName: sender,
                chatGUID: chatGUID,
                senderAvatar: senderAvatar
            ))
            // Enough MATCHES — stop hydrating candidates.
            if let limit, results.count >= limit { break }
        }

        // Correctness guard for the candidate cap (see MessageSearch.search).
        if let limit, let candidateLimit,
           results.count < limit, rows.count >= candidateLimit {
            return try search(
                phrase: phrase,
                person: person,
                dateRange: dateRange,
                limit: nil,
                now: now,
                caseSensitive: caseSensitive,
                order: order
            ).prefix(limit).map { $0 }
        }

        // Splice in reactions + types — same batched approach as MessageSearch.search.
        let guids = results.compactMap { $0.message.guid }
        let reactionMap: [String: [Reaction]]
        let typeMap: [String: MessageType]
        if guids.isEmpty {
            reactionMap = [:]
            typeMap = [:]
        } else {
            reactionMap = (try? ReactionLoader.reactions(
                forTargetGUIDs: guids,
                database: chatDB,
                contacts: contacts
            )) ?? [:]
            typeMap = (try? AttachmentLoader.types(
                forMessageGUIDs: guids,
                database: chatDB
            )) ?? [:]
        }
        if !reactionMap.isEmpty || !typeMap.isEmpty {
            results = results.map { r in
                let guid = r.message.guid
                let rxns = guid.flatMap { reactionMap[$0] } ?? []
                let kind = guid.flatMap { typeMap[$0] } ?? .text
                if rxns.isEmpty && kind == .text { return r }
                return MessageSearch.Result(
                    message: r.message,
                    partnerName: r.partnerName,
                    senderName: r.senderName,
                    chatGUID: r.chatGUID,
                    reactions: rxns,
                    senderAvatar: r.senderAvatar,
                    messageType: kind
                )
            }
        }

        return results
    }

    // MARK: - SQL aggregate count (Perf Pass C, Codex #4 step ②)

    /// Count matching messages against the FTS5 mirror with a true SQL
    /// `COUNT(*)` — without materializing or body-decoding any rows.
    ///
    /// Same parity contract as `MessageSearch.aggregateCount`: a `COUNT(*)` is
    /// only byte-for-byte equal to `search(...).count` when NO Swift-side body
    /// refinement runs — i.e. the parsed phrase AST is empty (filter-only query)
    /// and no `person` filter is supplied. In that case the FTS query omits the
    /// MATCH entirely (`matchSQL = "1"`) and every metadata row becomes a Result,
    /// so the count is exact. Returns `nil` (= "fall back to materialized
    /// search") otherwise, including the regex / short-term cases the search
    /// path delegates to INSTR anyway.
    public func aggregateCount(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        now: Date = Date(),
        caseSensitive: Bool = false
    ) throws -> Int? {
        guard person == nil else { return nil }

        let parsed = MessageSearch.parseQuery(phrase, contacts: contacts, now: now)
        let phraseAST = try PhraseQuery.parse(parsed.freeText, caseSensitive: caseSensitive)
        // Filter-only is the sole aggregable shape (no body refinement). A
        // non-empty AST — even an all-substring one — would be refined Swift-side
        // in `search`, so a COUNT would diverge: bail to the materialized path.
        guard phraseAST.isEmpty else { return nil }

        if parsed.dateConstraintIsEmpty { return 0 }
        let combinedConstraint = MessageSearch.intersectConstraint(dateRange, parsed.dateRange)
        if case .empty = combinedConstraint { return 0 }
        let combinedRange: ClosedRange<Date>?
        switch combinedConstraint {
        case .unbounded: combinedRange = nil
        case .range(let r): combinedRange = r
        case .empty: combinedRange = nil  // unreachable due to early return
        }

        // Same filter clauses + arg order as `search()` (the filter-only path,
        // where `matchSQL` is "1" and the FROM is meta-only). COUNT(*) over the
        // identical predicate.
        let (chatSQL, chatArgs) = MessageSearch.chatClause(parsed.chatFilters, contacts: contacts)
        let (fromSQL, fromArgs) = MessageSearch.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs)     = MessageSearch.toClause(parsed.toFilters, contacts: contacts)
        let (withSQL, withArgs) = MessageSearch.withClause(parsed.withFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = MessageSearch.reactionsClause(parsed.reactionFilters)
        let typeSQL = MessageSearch.typeClause(parsed.typeFilters)
        let (metaDateSQL, metaDateArgs) = Self.metaDateClause(combinedRange)

        let sql = """
            SELECT COUNT(*) AS c
            FROM idx.message_meta meta
            JOIN chat_message_join cmj ON cmj.message_id = meta.rowid
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = meta.handle_id
            JOIN message m ON m.ROWID = meta.rowid
            WHERE 1
              AND meta.associated_message_type = 0
              \(metaDateSQL)
              \(chatSQL)
              \(fromSQL)
              \(toSQL)
              \(withSQL)
              \(reactionsSQL)
              \(typeSQL)
            """

        var args: [DatabaseValueConvertible] = metaDateArgs
        args.append(contentsOf: chatArgs)
        args.append(contentsOf: fromArgs)
        args.append(contentsOf: toArgs)
        args.append(contentsOf: withArgs)
        args.append(contentsOf: reactionsArgs)

        let indexPath = store.url.path
        return try chatDB.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS idx", arguments: [indexPath])
            defer { try? db.execute(sql: "DETACH DATABASE idx") }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    // MARK: - Helpers

    /// Quote a needle so FTS5 trigram MATCH treats it as a literal substring.
    /// Doubles internal `"` to escape per the FTS5 syntax (the same rule
    /// SQLite identifiers follow).
    static func quoteNeedleForFTS5(_ needle: String) -> String {
        let escaped = needle.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Translate the AST into an FTS5 MATCH expression.
    ///
    /// Mapping:
    ///   - Each `.term(_, _)` leaf becomes a quoted phrase (substring under
    ///     trigram). Word-boundary semantics aren't representable here;
    ///     we get the broader substring match and the Swift refiner
    ///     narrows it.
    ///   - Groups (OR within) translate to `(a OR b)` parenthesized.
    ///   - Top-level AND-of-groups joins with ` AND ` (FTS5 keyword).
    ///
    /// Returns nil if the AST is empty OR contains no representable
    /// leaves (e.g. all regex — caller falls back upstream).
    static func buildFTS5Expression(from ast: PhraseQuery) -> String? {
        if ast.isEmpty { return nil }
        var groupExprs: [String] = []
        for g in ast.groups {
            var ors: [String] = []
            for n in g.needles {
                guard case .term(let t, _) = n, !t.isEmpty else { continue }
                ors.append(quoteNeedleForFTS5(t))
            }
            if ors.isEmpty { continue }
            if ors.count == 1 {
                groupExprs.append(ors[0])
            } else {
                groupExprs.append("(" + ors.joined(separator: " OR ") + ")")
            }
        }
        if groupExprs.isEmpty { return nil }
        return groupExprs.joined(separator: " AND ")
    }

    /// Date clause against `message_meta.date`. Same ns/seconds disambiguation
    /// as `MessageSearch.dateClause` but written against the indexed column
    /// on the mirror side — much faster than the join target.
    static func metaDateClause(_ range: ClosedRange<Date>?) -> (String, [DatabaseValueConvertible]) {
        guard let range else { return ("", []) }
        let loNS = MessageDate.nanosecondsSinceMacEpoch(from: range.lowerBound)
        let hiNS = MessageDate.nanosecondsSinceMacEpoch(from: range.upperBound)
        let loS = MessageDate.secondsSinceMacEpoch(from: range.lowerBound)
        let hiS = MessageDate.secondsSinceMacEpoch(from: range.upperBound)
        let sql = """
            AND (
                  (meta.date > 1000000000000 AND meta.date BETWEEN ? AND ?)
               OR (meta.date <= 1000000000000 AND meta.date BETWEEN ? AND ?)
            )
            """
        return (sql, [loNS, hiNS, loS, hiS])
    }

    /// Partner-name resolution (copied/adapted from `MessageSearch`).
    private func partnerName(
        forChat chatID: Int64,
        style: Int?,
        displayName: String?,
        cache: inout [Int64: String],
        handlesCache: inout [Int64: [Handle]]
    ) -> String {
        if let cached = cache[chatID] { return cached }
        let label: String
        if let displayName, !displayName.isEmpty {
            // UI renders a person.3 SF Symbol from chatStyle == 43; no
            // need for an ASCII "[group] " text prefix anymore. Keeps the
            // FTSSearcher path identical to MessageSearch for parity.
            label = displayName
        } else if style == 43 {
            let hs = self.handles(forChat: chatID, cache: &handlesCache)
            let names = hs.map { contacts.byHandle[$0]?.displayName ?? $0.raw }
            let preview = names.prefix(4).joined(separator: ", ")
            let suffix = names.count > 4 ? " +\(names.count - 4)" : ""
            label = preview + suffix
        } else {
            let hs = self.handles(forChat: chatID, cache: &handlesCache)
            if let first = hs.first {
                label = contacts.byHandle[first]?.displayName ?? first.raw
            } else {
                label = "(unknown)"
            }
        }
        cache[chatID] = label
        return label
    }

    private func handles(forChat chatID: Int64, cache: inout [Int64: [Handle]]) -> [Handle] {
        if let cached = cache[chatID] { return cached }
        let rows: [String] = (try? chatDB.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT h.id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                """, arguments: [chatID])
        }) ?? []
        let hs = rows.map { Handle(raw: $0) }
        cache[chatID] = hs
        return hs
    }
}
