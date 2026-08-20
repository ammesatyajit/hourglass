//
//  MessageSearch.swift
//  Hourglass
//
//  Phase 1 phrase search across the user's chat.db.
//
//  Query model
//  -----------
//  - `phrase`: case-insensitive substring(s). If it contains `+`, we split on
//    `+` and require ALL parts to appear in the message body (co-occurrence).
//    Empty parts are ignored, so "foo+" == "foo".
//  - `person`: optional Contact filter — restrict to messages whose
//    participant (sender for received, chat-partner for sent in 1:1) maps to
//    this contact's handle set.
//  - `dateRange`: optional ClosedRange<Date>. Pushed down into SQL.
//
//  Pipeline (matches `reference/scripts/search_messages.py`):
//    1. Pull candidate rows by date range AND a coarse phrase pre-filter from
//       SQL (fast — `date` is indexed, LIKE on `attributedBody` byte-scans but
//       it's much smaller than fetching every row).
//       Filter `associated_message_type = 0` to drop tapbacks here.
//    2. Decode body in-process (text || attributedBody) using the
//       metadata-aware AttributedBodyDecoder.
//    3. Substring match (case-insensitive) on the *decoded* body — refines the
//       SQL coarse match and rejects metadata-only false positives.
//    4. Person filter applied last (we have to know the sender to filter).
//
//  Returns messages sorted **descending** by date (newest first). This matches
//  Spotlight-style "show me recent matches first" expectations, and means the
//  LIMIT clause keeps the most recent candidates, not the oldest.
//

import Foundation
import GRDB

public struct MessageSearch: Sendable {

    public struct Result: Sendable, Equatable {
        public let message: Message
        /// Resolved display name of the OTHER party in the chat (the partner,
        /// not the user). Filled in when we can determine it from chat_handle_join.
        public let partnerName: String
        /// Resolved sender display name ("You" or contact name or raw handle).
        public let senderName: String
        /// `chat.guid` — the canonical chat identifier (e.g.
        /// `"iMessage;-;+15551234567"` for a 1:1 or `"iMessage;+;chat0123..."`
        /// for a group). Surfaced so the reveal layer can use it for
        /// AppleScript-based jump-to-chat lookups; `nil` if the row didn't
        /// carry one (very old DBs).
        public let chatGUID: String?
        /// Reactions on this message, oldest first. Populated by
        /// `MessageSearch.search` via a single batched `ReactionLoader` call
        /// after the main result query — never N+1.
        public let reactions: [Reaction]
        /// Raw PNG / JPEG bytes of the sender's contact photo, resolved via
        /// `ContactResolver`. Nil when the sender is "You" (we don't render
        /// our own avatar for own-sent messages — the chat partner identity
        /// matters more here), when the sender is an unresolved handle, or
        /// when the resolved contact has no photo. UI falls back to initials
        /// via `AvatarView`.
        public let senderAvatar: Data?
        /// What kind of content this message carries — text, image, video,
        /// sticker, link preview, etc. Populated by a single batched
        /// `AttachmentLoader.types(forMessageGUIDs:database:)` call after the
        /// main result query (same place `reactions` are spliced in). Default
        /// `.text` so empty-loader / lookup-miss / no-GUID rows stay textual.
        public let messageType: MessageType

        public init(
            message: Message,
            partnerName: String,
            senderName: String,
            chatGUID: String? = nil,
            reactions: [Reaction] = [],
            senderAvatar: Data? = nil,
            messageType: MessageType = .text
        ) {
            self.message = message
            self.partnerName = partnerName
            self.senderName = senderName
            self.chatGUID = chatGUID
            self.reactions = reactions
            self.senderAvatar = senderAvatar
            self.messageType = messageType
        }
    }

    public let database: ChatDatabase
    public let contacts: ResolvedContacts

    public init(database: ChatDatabase, contacts: ResolvedContacts) {
        self.database = database
        self.contacts = contacts
    }

    /// Run a search. Returns matches sorted by date **descending** (newest first).
    ///
    /// `limit` is `nil` by default — **search is exhaustive**: every message
    /// matching the filters is returned. Pass an explicit limit only when you
    /// know you want to cap (e.g. a thumbnail preview that needs the top 20).
    /// Latency protection for typing-on-every-keystroke is the *caller's*
    /// responsibility (debounce + cancellation in `SearchViewModel`).
    ///
    /// **Query syntax** in `phrase`:
    /// - **Bare term**: word-boundary match (e.g. `the` matches the WORD
    ///   "the" but not inside "other"/"father"). The previous substring
    ///   default has moved behind `*term*` opt-in.
    /// - `*term*`: substring match — `*cact*` matches "cactus", "cactuses".
    /// - `"phrase"`: multi-word substring phrase (same semantics as `*…*`).
    /// - `/regex/[i]`: regex match. Trailing `i` for case-insensitive.
    ///   Invalid regex throws `PhraseQuery.Error.invalidRegex`.
    /// - `a+b`: AND — both terms must appear in the same message.
    /// - `a|b` or `a OR b`: OR — either term matches. AND binds tighter
    ///   than OR; `a|b+c` reads as `a OR (b AND c)` per `PhraseQuery.parse`.
    /// - `chat:name` / `in:name`: scope to a **specific chat** — either
    ///   a named chat (case-insensitive substring on `chat.display_name`)
    ///   or a **1:1 chat** whose participant resolves to `name`. Does
    ///   NOT match groups by participant — that's what `with:` is for.
    ///   Multiple `chat:` tokens are AND'd. Multi-word values via quotes:
    ///   `chat:"Lost Causes"`. **Comma-separated values** identify a
    ///   group by its participant roster — Messages.app prints unnamed
    ///   groups as a comma list like "Noah, Annika, Justin", so
    ///   `chat:"Noah, Annika, Justin"` matches a group chat whose
    ///   participants are EXACTLY those three (no more, no less). The
    ///   exactness is what keeps the operator distinct from `with:`:
    ///   `with:Noah with:Annika with:Justin` matches any chat where all
    ///   three participate (including larger groups with extras);
    ///   `chat:"Noah, Annika, Justin"` matches THE group of those
    ///   three. Single values (no comma) keep the narrow display_name +
    ///   1:1 semantics so they don't collide with `with:`.
    /// - `with:name`: scope to **any chat (1:1 OR group) that this
    ///   person participates in**. Resolves `name` against contacts and
    ///   raw handles. Multiple `with:` tokens AND together (chats where
    ///   ALL named people participate). Comma-separated values inside a
    ///   single token AND too — `with:"Howard, Mom"` ≡ `with:Howard
    ///   with:Mom`. Loose semantics (extras OK): a 10-person group with
    ///   Howard and Mom both in it qualifies. Use `chat:"A, B, C"` when
    ///   you want the EXACT-roster variant.
    /// - `from:person`: messages SENT BY person (matches contact display name
    ///   or raw handle). Multiple `from:` AND together.
    /// - `from:me`: messages YOU sent (`is_from_me = 1`). The literal alias
    ///   `me` always works; additionally, when the AddressBook "Me" record
    ///   was detected at resolve time, the user's own name or any of their
    ///   own handles (`from:"My Name"`, `from:415…`, etc.) also resolve to
    ///   "sent by me."
    /// - `to:person`: messages SENT TO person — `is_from_me = 1` AND chat
    ///   participants include `person`. Multiple `to:` AND together.
    /// - `before:date` / `after:date` / `on:date`: explicit date operators.
    ///   `on:` is shorthand for "between start and end of that day".
    /// - `last:7d` / `last:24h` / `last:2w` / `last:3mo` / `last:1y`: relative
    ///   delta from now. `last:N` (bare) means N days.
    /// - Natural date strings as operator values: `before:yesterday`,
    ///   `after:"may 8 2026"`. Or as standalone tokens for callers using
    ///   `dateRange` directly. ISO `YYYY-MM-DD` and `MM/DD/YYYY` accepted.
    /// - `type:image` / `type:video` / `type:audio` / `type:sticker` /
    ///   `type:link` / `type:file` / `type:text` / `type:attachment`. Multiple
    ///   `type:` tokens OR together (so `type:image type:video` = images OR
    ///   videos). `type:attachment` is sugar for any non-text non-link kind.
    ///
    /// All filters AND together (within a category — multiple `type:` tokens
    /// OR within the type category, see above). Caller-supplied `person` /
    /// `dateRange` AND with anything parsed from the phrase.
    /// Sort order for search results.
    public enum SortOrder: Sendable, Hashable {
        /// Newest-first. Default. Right for "show me the most recent
        /// match" UIs (the panel hero result, NL hero pick, etc.).
        case descending
        /// Oldest-first. Right for the NL agent's `readMessages` tool —
        /// when you're trying to scan a date window chronologically and
        /// only have a budget of N rows, you want the EARLIEST N in the
        /// window so you see the start of any cluster. With DESC you'd
        /// only ever see the tail of the window, missing context that
        /// happened weeks earlier inside the same range.
        case ascending
    }

    public func search(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        limit: Int? = nil,
        now: Date = Date(),
        caseSensitive: Bool = false,
        order: SortOrder = .descending
    ) throws -> [Result] {

        let parsed = Self.parseQuery(phrase, contacts: contacts, now: now)
        // Parse the free-text portion into the AST. Word-boundary is the
        // default for bare terms; `*term*` opts into substring; `/regex/`
        // declares regex; `a|b` and `a OR b` introduce OR. See
        // `PhraseQuery` for the grammar. Invalid regex throws —
        // callers expose it as a banner instead of silent empty results.
        let phraseAST = try PhraseQuery.parse(parsed.freeText, caseSensitive: caseSensitive)

        // Combine caller-supplied date range with any parsed date range.
        // Codex audit H1 (2026-05-25): use the explicit three-state
        // constraint so `.empty` (contradictory intersection) short-
        // circuits to zero rows instead of silently falling through to
        // "no filter" and broadening the search. Also honor the
        // parser-detected empty constraint (when the phrase itself
        // contains contradictory date operators).
        if parsed.dateConstraintIsEmpty { return [] }
        let combinedConstraint = Self.intersectConstraint(dateRange, parsed.dateRange)
        if case .empty = combinedConstraint { return [] }

        let (dateSQL, dateArgs) = Self.dateClause(constraint: combinedConstraint)
        let (phraseSQL, phraseArgs) = Self.phraseClause(ast: phraseAST, caseSensitive: caseSensitive)
        let (chatSQL, chatArgs) = Self.chatClause(parsed.chatFilters, contacts: contacts)
        let (fromSQL, fromArgs) = Self.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs) = Self.toClause(parsed.toFilters, contacts: contacts)
        let (withSQL, withArgs) = Self.withClause(parsed.withFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = Self.reactionsClause(parsed.reactionFilters)
        let typeSQL = Self.typeClause(parsed.typeFilters)
        let limitSQL = limit.map { _ in "LIMIT ?" } ?? ""
        let sql = """
            SELECT
                m.ROWID                    AS rowid,
                m.guid                     AS guid,
                m.date                     AS date,
                m.is_from_me               AS is_from_me,
                m.text                     AS text,
                m.attributedBody           AS attributedBody,
                m.associated_message_type  AS associated_message_type,
                h.id                       AS sender_handle,
                cmj.chat_id                AS chat_id,
                ch.style                   AS chat_style,
                ch.display_name            AS chat_display_name,
                ch.guid                    AS chat_guid
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
              \(dateSQL)
              \(phraseSQL)
              \(chatSQL)
              \(fromSQL)
              \(toSQL)
              \(withSQL)
              \(reactionsSQL)
              \(typeSQL)
            ORDER BY m.date \(order == .ascending ? "ASC" : "DESC")
            \(limitSQL)
            """

        var args: [DatabaseValueConvertible] = dateArgs
        args.append(contentsOf: phraseArgs)
        args.append(contentsOf: chatArgs)
        args.append(contentsOf: fromArgs)
        args.append(contentsOf: toArgs)
        args.append(contentsOf: withArgs)
        args.append(contentsOf: reactionsArgs)
        // The SQL LIMIT bounds CANDIDATES, but Swift-side refinement below
        // (phrase AST over decoded bodies, person filter) can reject rows —
        // a bare LIMIT of `limit` would silently DROP older matches (observed:
        // a refinement-heavy query returned 0 of 443 real matches when capped).
        // Overfetch 8× so dense queries stay one cheap fetch; the guard after
        // the loop rescans unbounded if refinement couldn't fill the cap from
        // a truncated candidate set.
        let candidateLimit = limit.map { $0 * 8 }
        if let candidateLimit { args.append(candidateLimit) }

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        // Cache: chat_id -> partner display name (for 1:1 we look up the
        // other participant; for groups we use the chat display_name).
        var partnerNameCache: [Int64: String] = [:]
        // Cache: chat_id -> [normalized handles] (for person filtering on
        // sent messages — we need to know who you sent to).
        var chatHandlesCache: [Int64: [Handle]] = [:]

        var results: [Result] = []
        results.reserveCapacity(min(rows.count, 256))

        for (rowIndex, row) in rows.enumerated() {
            // Cooperative cancellation — same rationale as FTSSearcher: a
            // superseded live search should stop hydrating mid-loop, not
            // finish a result set that will be discarded.
            if rowIndex % 256 == 255 { try Task.checkCancellation() }
            let rawDate: Int64 = row["date"]
            let date = MessageDate.date(fromRaw: rawDate)

            let isFromMe: Bool = (row["is_from_me"] as Int? ?? 0) == 1
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)

            // Phrase filter — refine the SQL coarse pre-filter against
            // the decoded body using the AST. Honors word-boundary
            // default, `*subs*` opt-out, `/regex/` regex, and `a|b` OR.
            // See `PhraseQuery.matches` for the per-needle semantics.
            if !phraseAST.isEmpty {
                if !phraseAST.matches(body: body, caseSensitive: caseSensitive) {
                    continue
                }
            }

            let chatID: Int64 = row["chat_id"]
            let senderHandle: String? = row["sender_handle"]
            let chatStyle: Int? = row["chat_style"]
            let chatDisplayName: String? = row["chat_display_name"]
            let messageGUID: String? = row["guid"]
            let chatGUID: String? = row["chat_guid"]

            // Person filter
            if let person {
                let participantHandles: [Handle]
                if isFromMe {
                    // Sent: look up the chat's other participants.
                    participantHandles = handles(forChat: chatID, cache: &chatHandlesCache)
                } else {
                    // Received: the sender IS the participant.
                    participantHandles = senderHandle.map { [Handle(raw: $0)] } ?? []
                }
                let matches = participantHandles.contains { person.handles.contains($0) }
                if !matches { continue }
            }

            let message = Message(
                id: row["rowid"],
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
                // "You" gets initials — we don't have a self-avatar source
                // and surfacing it isn't useful in search results anyway
                // (every own-sent row would carry it).
                senderAvatar = nil
            } else if let raw = senderHandle {
                sender = contacts.name(forRawHandle: raw)
                senderAvatar = contacts.avatarData(forRawHandle: raw)
            } else {
                sender = "(unknown)"
                senderAvatar = nil
            }

            results.append(Result(
                message: message,
                partnerName: partner,
                senderName: sender,
                chatGUID: chatGUID,
                senderAvatar: senderAvatar
            ))
            // Enough MATCHES — stop hydrating candidates.
            if let limit, results.count >= limit { break }
        }

        // Correctness guard for the candidate cap: if refinement couldn't
        // fill `limit` matches AND the candidate fetch itself was truncated,
        // older matches may exist beyond the cap — rescan unbounded (still
        // cancellable via the loop's checkCancellation) and trim. Dense
        // queries never hit this; sparse ones pay the pre-cap cost but
        // return the RIGHT rows.
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

        // Batched post-processing — ONE SQL query each for reactions and for
        // message types. Both keyed off the same set of result message GUIDs;
        // we collect once, then splice back in. No N+1 anywhere.
        //
        // Reactions: per-message tapback list. UI wants them on every row so
        // we always load them. Failures load empty rather than blowing up the
        // whole search — a broken reactions subquery shouldn't kill results.
        //
        // Types: per-message MessageType (text/image/video/audio/sticker/link/
        // file/applePay/location/other) derived from the attachment join and
        // balloon_bundle_id. Default `.text` so GUID-less rows (very old DBs)
        // and absent-from-map rows keep the textual default.
        let guids = results.compactMap { $0.message.guid }
        let reactionMap: [String: [Reaction]]
        let typeMap: [String: MessageType]
        if guids.isEmpty {
            reactionMap = [:]
            typeMap = [:]
        } else {
            reactionMap = (try? ReactionLoader.reactions(
                forTargetGUIDs: guids,
                database: database,
                contacts: contacts
            )) ?? [:]
            typeMap = (try? AttachmentLoader.types(
                forMessageGUIDs: guids,
                database: database
            )) ?? [:]
        }
        if !reactionMap.isEmpty || !typeMap.isEmpty {
            results = results.map { r in
                let guid = r.message.guid
                let rxns = guid.flatMap { reactionMap[$0] } ?? []
                let kind = guid.flatMap { typeMap[$0] } ?? .text
                // Skip allocating a new Result if there's nothing to splice.
                if rxns.isEmpty && kind == .text { return r }
                return Result(
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

    /// Count matching messages with a true SQL `COUNT(*)` — WITHOUT
    /// materializing (and body-decoding) every matching row, which is what
    /// `search(...).count` does.
    ///
    /// **Parity contract — why this returns `Int?`:** `search()` runs a
    /// Swift-side refinement (`PhraseQuery.matches(body:)` on the decoded body,
    /// plus the `person` participant filter) AFTER the SQL pre-filter, so a raw
    /// `COUNT(*)` over the SQL WHERE clause is in general an OVER-count (the SQL
    /// phrase pre-filter is a deliberate superset, refined in Swift). The ONLY
    /// case where `COUNT(*)` is byte-for-byte equal to `search(...).count` is
    /// when there is **no Swift refinement at all** — i.e. the parsed phrase AST
    /// is empty (a filter-only query like `from:me type:image last:30d`) AND no
    /// `person` filter is supplied. In that case every SQL row becomes a Result
    /// (the `if !phraseAST.isEmpty` guard in `search` is skipped) and the
    /// reactions/type post-processing only rewrites rows, never adds/removes
    /// them — so the cardinality is identical.
    ///
    /// Returns `nil` when the query is NOT safely aggregable (non-empty phrase
    /// AST, a `person` filter, or invalid regex). Callers MUST fall back to
    /// `search(...).count` in that case to preserve exact behavior.
    ///
    /// The WHERE clause is built from the SAME clause helpers `search()` uses,
    /// so the predicate is identical — only the projection (`COUNT(*)` vs the
    /// row SELECT) and the absence of `ORDER BY`/`LIMIT` differ.
    func aggregateCount(
        phrase: String,
        person: Contact? = nil,
        dateRange: ClosedRange<Date>? = nil,
        now: Date = Date(),
        caseSensitive: Bool = false
    ) throws -> Int? {
        // A `person` filter is applied Swift-side (it needs participant
        // resolution), so it can't be pushed into a COUNT safely.
        guard person == nil else { return nil }

        let parsed = Self.parseQuery(phrase, contacts: contacts, now: now)
        let phraseAST = try PhraseQuery.parse(parsed.freeText, caseSensitive: caseSensitive)
        // The decisive gate: any free-text needle means a Swift body refinement
        // would run, so SQL COUNT would over-count. Bail to the materialized path.
        guard phraseAST.isEmpty else { return nil }

        // Contradictory date constraints → zero rows (mirrors `search`).
        if parsed.dateConstraintIsEmpty { return 0 }
        let combinedConstraint = Self.intersectConstraint(dateRange, parsed.dateRange)
        if case .empty = combinedConstraint { return 0 }

        // Same WHERE clause builders + arg order as `search()`. The phrase
        // clause is empty (AST is empty) so it contributes nothing — identical
        // to `search`'s emitted SQL minus the SELECT/ORDER/LIMIT.
        let (dateSQL, dateArgs) = Self.dateClause(constraint: combinedConstraint)
        let (chatSQL, chatArgs) = Self.chatClause(parsed.chatFilters, contacts: contacts)
        let (fromSQL, fromArgs) = Self.fromClause(parsed.fromFilters, contacts: contacts)
        let (toSQL, toArgs) = Self.toClause(parsed.toFilters, contacts: contacts)
        let (withSQL, withArgs) = Self.withClause(parsed.withFilters, contacts: contacts)
        let (reactionsSQL, reactionsArgs) = Self.reactionsClause(parsed.reactionFilters)
        let typeSQL = Self.typeClause(parsed.typeFilters)

        let sql = """
            SELECT COUNT(*) AS c
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
              \(dateSQL)
              \(chatSQL)
              \(fromSQL)
              \(toSQL)
              \(withSQL)
              \(reactionsSQL)
              \(typeSQL)
            """

        var args: [DatabaseValueConvertible] = dateArgs
        args.append(contentsOf: chatArgs)
        args.append(contentsOf: fromArgs)
        args.append(contentsOf: toArgs)
        args.append(contentsOf: withArgs)
        args.append(contentsOf: reactionsArgs)

        return try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    // MARK: - Helpers

    /// One reaction-related filter parsed from a `reactions:` token.
    ///
    /// Three flavors:
    /// - `.count(.greaterEqual, 3)` — count comparator
    /// - `.any` — at least 1 reaction (sugar for `.count(.greaterEqual, 1)`)
    /// - `.kind(.love)` — at least one reaction of the named type
    ///
    /// Multiple filters AND together at SQL time. `reactions:>=3 reactions:love`
    /// means "at least 3 total reactions AND at least one is a love".
    public enum ReactionFilter: Sendable, Equatable {

        public enum Comparator: String, Sendable, Equatable {
            case greaterEqual = ">="
            case lessEqual = "<="
            case greater = ">"
            case less = "<"
            case equal = "="
        }

        /// Match by name. We only allow the *named* tapback kinds — the
        /// custom-emoji (`2006`) and sticker (`2007`) types don't have a
        /// stable user-facing keyword, so they're not addressable here.
        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case love, like, laugh, emphasize, question, dislike

            /// The `associated_message_type` value this name maps to.
            public var typeValue: Int {
                switch self {
                case .love: return 2000
                case .like: return 2001
                case .dislike: return 2002
                case .laugh: return 2003
                case .emphasize: return 2004
                case .question: return 2005
                }
            }
        }

        case count(Comparator, Int)
        case any
        case kind(Kind)

        /// Parse the value side of `reactions:<value>`. Returns nil if the
        /// value isn't one of the recognized shapes — the caller drops the
        /// token (it stays in `freeText` so the user isn't punished for a
        /// typo).
        public static func parse(_ value: String) -> ReactionFilter? {
            let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty else { return nil }
            if trimmed == "any" { return .any }
            if let kind = Kind(rawValue: trimmed) { return .kind(kind) }
            // Comparator shapes: ">=N", "<=N", ">N", "<N", "=N", or bare "N".
            // Order matters — check 2-char prefixes before 1-char.
            let comparators: [(String, Comparator)] = [
                (">=", .greaterEqual),
                ("<=", .lessEqual),
                (">", .greater),
                ("<", .less),
                ("=", .equal),
            ]
            for (sym, cmp) in comparators {
                if trimmed.hasPrefix(sym) {
                    let rest = trimmed.dropFirst(sym.count)
                    if let n = Int(rest), n >= 0 {
                        return .count(cmp, n)
                    }
                    return nil
                }
            }
            if let n = Int(trimmed), n >= 0 {
                return .count(.equal, n)
            }
            return nil
        }
    }

    /// One content-type filter parsed from a `type:` token.
    ///
    /// `type:image`, `type:video`, `type:audio`, `type:sticker`, `type:link`,
    /// `type:file`, `type:text`, `type:attachment` (sugar for any non-text
    /// non-link). Unrecognized values fall through to free text.
    ///
    /// Multiple `type:` tokens OR together — `type:image type:video` means
    /// "images OR videos". This matches user intuition: most filter prefixes
    /// AND, but `type:` is a discriminator where OR is what people want.
    public enum TypeFilter: Sendable, Equatable, Hashable {
        case image
        case video
        case audio
        case sticker
        case link
        case file
        case text
        /// Sugar — expands to `[image, video, audio, sticker, file, other]`
        /// at SQL build time. Excludes `.text` and `.linkPreview`.
        case attachment

        /// Resolve the filter to the concrete `MessageType` values it matches.
        public var messageTypes: [MessageType] {
            switch self {
            case .image:    return [.image]
            case .video:    return [.video]
            case .audio:    return [.audio]
            case .sticker:  return [.sticker]
            case .link:     return [.linkPreview]
            case .file:     return [.file, .applePay, .location, .other]
            case .text:     return [.text]
            case .attachment: return [.image, .video, .audio, .sticker, .file, .other]
            }
        }

        /// Parse a `type:` value. Returns nil for unrecognized inputs so the
        /// caller can fall back to treating the whole token as free text.
        public static func parse(_ value: String) -> TypeFilter? {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "image", "img", "photo": return .image
            case "video", "vid": return .video
            case "audio", "voice": return .audio
            case "sticker": return .sticker
            case "link", "url": return .link
            case "file", "doc", "pdf": return .file
            case "text", "plain": return .text
            case "attachment", "media", "any": return .attachment
            default: return nil
            }
        }
    }

    /// Parsed structured query.
    ///
    /// All filters AND together. `freeText` feeds `parseNeedles`; the others
    /// drop into their respective SQL clauses.
    public struct ParsedQuery: Sendable, Equatable {
        public let freeText: String
        public let chatFilters: [String]
        public let fromFilters: [String]
        public let toFilters: [String]
        /// `with:` tokens — scope to **any chat (1:1 OR group) this person
        /// participates in**. Different from `chatFilters` (`chat:`/`in:`),
        /// which match either a chat's `display_name` substring OR a 1:1
        /// chat by its participant (groups not matched by participant).
        public let withFilters: [String]
        public let dateRange: ClosedRange<Date>?
        /// True when the parser saw multiple date constraints whose
        /// intersection was empty — e.g. `last:7d before:2020-01-01`.
        /// Callers should short-circuit to zero results when this is set.
        /// Codex audit H1 (2026-05-25). Defaults to `false` for backward
        /// compat with tests that construct `ParsedQuery` directly.
        public let dateConstraintIsEmpty: Bool
        /// Reaction-thresholds + kind filters parsed from `reactions:` tokens.
        public let reactionFilters: [ReactionFilter]
        /// Content-type filters parsed from `type:` tokens. Multiple values
        /// OR together (so `type:image type:video` matches both).
        public let typeFilters: [TypeFilter]
        /// The tokens we recognized, in order, with their original spelling.
        /// Used by the UI to highlight active filters inline.
        public let tokens: [Token]

        public init(
            freeText: String,
            chatFilters: [String] = [],
            fromFilters: [String] = [],
            toFilters: [String] = [],
            withFilters: [String] = [],
            dateRange: ClosedRange<Date>? = nil,
            dateConstraintIsEmpty: Bool = false,
            reactionFilters: [ReactionFilter] = [],
            typeFilters: [TypeFilter] = [],
            tokens: [Token] = []
        ) {
            self.freeText = freeText
            self.chatFilters = chatFilters
            self.fromFilters = fromFilters
            self.toFilters = toFilters
            self.withFilters = withFilters
            self.dateRange = dateRange
            self.dateConstraintIsEmpty = dateConstraintIsEmpty
            self.reactionFilters = reactionFilters
            self.typeFilters = typeFilters
            self.tokens = tokens
        }
    }

    /// A single recognized token, with the substring range it occupied in the
    /// original query — handy for inline highlighting in the UI.
    public struct Token: Sendable, Equatable {
        public let prefix: TokenPrefix
        public let value: String
        public let range: Range<String.Index>
        public init(prefix: TokenPrefix, value: String, range: Range<String.Index>) {
            self.prefix = prefix
            self.value = value
            self.range = range
        }
    }

    /// Extract recognized tokens from the phrase. Everything else stays in
    /// `freeText`. Supports quoted values: `chat:"Amme Satyajit"`.
    ///
    /// Unknown token prefixes (e.g. `foo:bar`) are treated as free text — the
    /// parser is permissive so users don't get punished for typos.
    public static func parseQuery(
        _ phrase: String,
        contacts: ResolvedContacts? = nil,
        now: Date = Date()
    ) -> ParsedQuery {
        let tokens = tokenize(phrase)
        var freeText = ""
        var chats: [String] = []
        var froms: [String] = []
        var tos: [String] = []
        var withs: [String] = []
        var dateRanges: [ClosedRange<Date>] = []
        var dateInstants: [(TokenPrefix, Date)] = []
        var reactionFilters: [ReactionFilter] = []
        var typeFilters: [TypeFilter] = []
        var recognized: [Token] = []

        for token in tokens {
            if token.prefix == nil {
                // Free text — preserve original substring.
                if !freeText.isEmpty { freeText.append(" ") }
                freeText.append(String(phrase[token.range]))
                continue
            }
            guard let prefix = token.prefix else { continue }
            let raw = token.value
            if raw.isEmpty {
                // Graceful: `from:` with no value is a no-op, not a syntax error.
                // Don't add it to the filters; don't remove from query.
                recognized.append(Token(prefix: prefix, value: raw, range: token.range))
                continue
            }
            switch prefix {
            case .chat, .in:
                chats.append(raw)
            case .with:
                withs.append(raw)
            case .from:
                froms.append(raw)
            case .to:
                tos.append(raw)
            case .reactions:
                if let f = ReactionFilter.parse(raw) {
                    reactionFilters.append(f)
                } else {
                    // Unrecognized reactions value — treat the WHOLE token as
                    // free text so the user sees what they typed survive into
                    // results (matches how `foo:bar` falls through).
                    if !freeText.isEmpty { freeText.append(" ") }
                    freeText.append(String(phrase[token.range]))
                    continue
                }
            case .type:
                if let f = TypeFilter.parse(raw) {
                    typeFilters.append(f)
                } else {
                    // Unrecognized type value — fall through to free text.
                    if !freeText.isEmpty { freeText.append(" ") }
                    freeText.append(String(phrase[token.range]))
                    continue
                }
            case .before, .after, .on, .last:
                if let expr = DateParser.parse(raw, now: now) {
                    switch expr {
                    case .range(let r):
                        switch prefix {
                        case .on, .last:
                            dateRanges.append(r)
                        case .before:
                            dateRanges.append(Date.distantPast...r.lowerBound)
                        case .after:
                            dateRanges.append(r.upperBound...Date.distantFuture)
                        default: break
                        }
                    case .instant(let d):
                        dateInstants.append((prefix, d))
                    }
                }
            }
            recognized.append(Token(prefix: prefix, value: raw, range: token.range))
        }

        // Combine all date constraints by intersection. Codex audit H1
        // fix — the previous version did `intersect($0, r) ?? $0` which
        // FELL BACK to the prior range whenever the intersection was
        // empty, silently dropping the contradictory new constraint and
        // returning a wider window than the user asked for. We now
        // track the empty state and surface it on `ParsedQuery` so the
        // caller can short-circuit to zero results.
        var combined: ClosedRange<Date>? = nil
        var contradictory = false
        for r in dateRanges {
            if contradictory { break }
            if let existing = combined {
                if let next = intersect(existing, r) {
                    combined = next
                } else {
                    contradictory = true
                    combined = nil
                }
            } else {
                combined = r
            }
        }
        for (op, d) in dateInstants {
            if contradictory { break }
            let r: ClosedRange<Date>
            switch op {
            case .before: r = Date.distantPast...d
            case .after: r = d...Date.distantFuture
            case .on:
                let cal = Calendar.current
                let start = cal.startOfDay(for: d)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
                r = start...end
            default: continue
            }
            if let existing = combined {
                if let next = intersect(existing, r) {
                    combined = next
                } else {
                    contradictory = true
                    combined = nil
                }
            } else {
                combined = r
            }
        }

        return ParsedQuery(
            freeText: freeText,
            chatFilters: chats,
            fromFilters: froms,
            toFilters: tos,
            withFilters: withs,
            dateRange: combined,
            dateConstraintIsEmpty: contradictory,
            reactionFilters: reactionFilters,
            typeFilters: typeFilters,
            tokens: recognized
        )
    }

    /// Internal token result of `tokenize`.
    struct RawToken {
        let prefix: TokenPrefix?
        let value: String
        let range: Range<String.Index>
    }

    /// Walk the query string, splitting on whitespace but respecting quoted
    /// segments (`chat:"Amme Satyajit"`). Returns tokens with their ranges so
    /// callers (the highlighter, the autocomplete) know where to draw.
    static func tokenize(_ phrase: String) -> [RawToken] {
        var tokens: [RawToken] = []
        var i = phrase.startIndex
        while i < phrase.endIndex {
            // Skip whitespace.
            while i < phrase.endIndex, phrase[i].isWhitespace {
                i = phrase.index(after: i)
            }
            guard i < phrase.endIndex else { break }

            let tokenStart = i
            var inQuotes = false
            while i < phrase.endIndex {
                let ch = phrase[i]
                if ch == "\"" {
                    inQuotes.toggle()
                    i = phrase.index(after: i)
                    continue
                }
                if ch.isWhitespace && !inQuotes {
                    break
                }
                i = phrase.index(after: i)
            }
            let tokenEnd = i
            let token = String(phrase[tokenStart..<tokenEnd])
            let lower = token.lowercased()

            var matched: (TokenPrefix, String)? = nil
            for p in TokenPrefix.allCases where lower.hasPrefix(p.rawValue) {
                var v = String(token.dropFirst(p.rawValue.count))
                // Strip surrounding quotes.
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v.removeFirst()
                    v.removeLast()
                } else if v.hasPrefix("\"") {
                    v.removeFirst()
                }
                matched = (p, v)
                break
            }
            if let (prefix, value) = matched {
                tokens.append(RawToken(prefix: prefix, value: value, range: tokenStart..<tokenEnd))
            } else {
                tokens.append(RawToken(prefix: nil, value: token, range: tokenStart..<tokenEnd))
            }
        }
        return tokens
    }

    /// Intersect two optional ranges. If either is nil, returns the other.
    /// If they don't overlap, returns nil.
    ///
    /// **WARNING**: `nil` is overloaded here — it means BOTH "no filter
    /// supplied" AND "the supplied filters didn't overlap (empty)." Use
    /// `intersectConstraint(_:_:)` instead when you need to distinguish
    /// those cases at the SQL emission layer.
    /// Codex audit H1 (2026-05-25): see the constraint helper.
    static func intersect(_ a: ClosedRange<Date>?, _ b: ClosedRange<Date>?) -> ClosedRange<Date>? {
        guard let a, let b else { return a ?? b }
        return intersect(a, b)
    }

    static func intersect(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> ClosedRange<Date>? {
        let lower = max(a.lowerBound, b.lowerBound)
        let upper = min(a.upperBound, b.upperBound)
        guard lower <= upper else { return nil }
        return lower...upper
    }

    /// Explicit three-state date constraint — disambiguates "no filter"
    /// from "filter intersection was empty". `dateClause(constraint:)`
    /// turns `.empty` into a SQL false predicate so contradictory filters
    /// short-circuit the result instead of silently broadening to one of
    /// the operands. Codex audit H1 (2026-05-25).
    enum DateConstraint: Sendable, Equatable {
        case unbounded
        case range(ClosedRange<Date>)
        case empty
    }

    /// Intersect two optional ranges, surfacing the empty case explicitly.
    /// Use this when feeding `dateClause` so contradictions short-circuit.
    static func intersectConstraint(
        _ a: ClosedRange<Date>?,
        _ b: ClosedRange<Date>?
    ) -> DateConstraint {
        switch (a, b) {
        case (nil, nil): return .unbounded
        case let (a?, nil): return .range(a)
        case let (nil, b?): return .range(b)
        case let (a?, b?):
            let lower = max(a.lowerBound, b.lowerBound)
            let upper = min(a.upperBound, b.upperBound)
            return lower <= upper ? .range(lower...upper) : .empty
        }
    }

    /// Build the chat-filter predicate. `chat:`/`in:` target a **specific
    /// chat** (named OR 1:1), as opposed to `with:` which broadens to
    /// "every conversation including groups."
    ///
    /// A chat matches `in:value` if ANY of:
    ///   (a) `chat.display_name LIKE '%value%'` — named chats (groups
    ///       the user has named, project threads, etc.).
    ///   (b) `chat.style = 45` (1:1) AND a participant resolves to
    ///       `value` (via contact display name, exact handle, or raw
    ///       handle substring). 1:1s have no display_name, so (a) never
    ///       matches them — (b) is how `in:Annika` finds the 1:1.
    ///
    /// Unnamed GROUP chats are NOT matched by participant — that's
    /// what `with:` is for. So `in:Annika` will not pull up a group
    /// just because Annika is a participant; it pulls up the 1:1 with
    /// Annika and any chats *named* "Annika".
    ///
    /// Multiple `chat:`/`in:` filters AND together — each filter's
    /// (a)|(b) disjunction must hold for the chat.
    ///
    /// History: this clause was display_name-only between 2026-05-25
    /// morning and afternoon. User reverted: `in:Person` returned 0 for
    /// 1:1 chats because they have no display_name. The (b) branch is
    /// restored here, *scoped to style=45 only* so the operator stays
    /// meaningfully distinct from `with:`.
    ///
    /// 2026-05-26 follow-up: branch (c) added for **unnamed group
    /// chats**. Messages.app renders an unnamed group as a
    /// comma-separated list of its participants ("Noah, Annika, Justin")
    /// — so users naturally identify those chats by typing the same
    /// list. Without (c), `chat:"Noah, Annika, Justin"` returned 0
    /// because display_name was empty and (b) is 1:1-only. The new
    /// branch splits comma-separated values, resolves each piece to
    /// handles, and matches a group (style=43) when ALL the pieces
    /// participate. Single-piece values (no commas) keep the original
    /// two-branch semantics — `with:` is still the operator for "any
    /// chat this person is in."
    static func chatClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            var orParts: [String] = []

            // (a) display_name substring — named chats.
            orParts.append("ch.display_name LIKE ?")
            args.append("%\(filter)%")

            // (b) 1:1 chat whose participant resolves to the filter.
            //     Same two-branch (exact + LIKE substring) match the
            //     `with:` clause uses, but gated by `ch.style = 45` so
            //     groups don't sneak in.
            let resolved = resolveHandles(forFilter: filter, contacts: contacts)
            let placeholders = Array(repeating: "?", count: resolved.count)
                .joined(separator: ", ")
            orParts.append("""
                (ch.style = 45 AND ch.ROWID IN (
                    SELECT chj.chat_id
                    FROM chat_handle_join chj
                    JOIN handle ph ON ph.ROWID = chj.handle_id
                    WHERE ph.id IN (\(placeholders))
                       OR ph.id LIKE ?
                ))
                """)
            for h in resolved { args.append(h) }
            args.append("%\(filter)%")

            // (c) Group chats identified by their participant roster.
            //     The user typed `chat:"A, B, C"` because that's how
            //     Messages.app prints unnamed groups in its sidebar. The
            //     intent is "THIS specific group" — exactly the people
            //     listed, no more, no less. That's the bright line that
            //     keeps `chat:` distinct from `with:`: `with:A with:B
            //     with:C` finds any chat where all three participate
            //     (including a 12-person group with extras); `chat:"A,
            //     B, C"` finds the chat that IS those three.
            //
            //     Implementation:
            //       - Trigger only on comma-separated values (≥2
            //         non-empty pieces).
            //       - Each piece must match a participant of the chat
            //         (same OR-set + LIKE-substring as `with:`).
            //       - The chat's participant COUNT must equal the
            //         number of pieces. This is what excludes
            //         supersets ("Aeternus 2" with extras) from
            //         matching `chat:"Noah, Annika, Justin"`.
            //       - style = 43 (groups). 1:1 chats stay on branch (b).
            //
            //     Edge case noted but not handled: a person can in
            //     theory join a group with both their phone and email
            //     so they appear TWICE in chat_handle_join — that would
            //     break the count check. iMessage doesn't normally do
            //     this (one handle per person per group), so the
            //     simple COUNT(*) suffices for the common case.
            let pieces = filter
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if pieces.count >= 2 {
                var pieceArgs: [DatabaseValueConvertible] = []
                var andParts: [String] = []
                for piece in pieces {
                    let pResolved = resolveHandles(forFilter: piece, contacts: contacts)
                    let pPlace = Array(repeating: "?", count: pResolved.count)
                        .joined(separator: ", ")
                    andParts.append("""
                        ch.ROWID IN (
                            SELECT chj.chat_id
                            FROM chat_handle_join chj
                            JOIN handle ph ON ph.ROWID = chj.handle_id
                            WHERE ph.id IN (\(pPlace))
                               OR ph.id LIKE ?
                        )
                        """)
                    for h in pResolved { pieceArgs.append(h) }
                    pieceArgs.append("%\(piece)%")
                }
                orParts.append("""
                    (ch.style = 43
                     AND (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = ch.ROWID) = ?
                     AND \(andParts.joined(separator: " AND ")))
                    """)
                // Args order matches placeholder order in the emitted SQL:
                // the COUNT comparator binds before the per-piece IN/LIKE
                // pairs. Adding the per-piece args inside the loop above
                // would put them ahead of the count — hence the deferred
                // pieceArgs accumulator.
                args.append(pieces.count)
                args.append(contentsOf: pieceArgs)
            }

            clauses.append("(" + orParts.joined(separator: " OR ") + ")")
        }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Resolve a person-filter substring to a list of (raw or normalized)
    /// handle strings. The substring may match a contact's `displayName`
    /// (case-insensitive substring), or a raw/normalized handle directly
    /// (so `from:415` finds messages from a number containing "415").
    ///
    /// All distinct handles that ANY matching contact owns are OR'd together
    /// — so `from:satyajit` catches messages from BOTH the user's phone and
    /// email if the contact entry has both.
    static func resolveHandles(forFilter filter: String, contacts: ResolvedContacts) -> [String] {
        let lower = filter.lowercased()
        var handles: Set<String> = []
        // Contact display name matches.
        for c in contacts.allContacts where c.displayName.lowercased().contains(lower) {
            for h in c.handles {
                handles.insert(h.normalized)
                handles.insert(h.raw)
            }
        }
        // Raw/normalized handle substring match. Cheap — set is small.
        for (handle, _) in contacts.byHandle {
            if handle.raw.lowercased().contains(lower) || handle.normalized.lowercased().contains(lower) {
                handles.insert(handle.raw)
                handles.insert(handle.normalized)
            }
        }
        // Important: if no contact / handle matched, still try the raw filter
        // as a literal handle search. Catches "+1415..." style queries where
        // the contact isn't in AddressBook.
        if handles.isEmpty {
            handles.insert(filter)
        }
        return Array(handles)
    }

    /// True when this `from:` filter value should be interpreted as "me"
    /// (i.e. expand to `is_from_me = 1` rather than a sender-handle match).
    ///
    /// Two paths trigger this:
    ///   1. Literal alias — the lowercased value is exactly `"me"`. Always
    ///      on, no AddressBook needed. This is the documented shorthand
    ///      surfaced by `from:me` in help / autocomplete / the NL agent's
    ///      system prompt.
    ///   2. AddressBook "Me" record — when `ContactResolver` detected a
    ///      record marked via `ZCONTAINERWHERECONTACTISME IS NOT NULL`,
    ///      its name OR any of its handles also count as `me`. Lets the
    ///      user type their own phone/email/name and have it resolve to
    ///      sent messages, mirroring how `from:Mom` resolves Mom's
    ///      handles.
    ///
    /// Matching for path 2 uses the same case-insensitive substring rule
    /// `resolveHandles` uses elsewhere — so `from:satya` works when the Me
    /// record is "Satyajit Kumar". Empty filters never match (defensive
    /// guard against `from:""` accidentally turning into `is_from_me = 1`).
    static func isMeFilter(_ filter: String, contacts: ResolvedContacts) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower == "me" { return true }
        guard let me = contacts.meContact else { return false }
        if me.displayName.lowercased().contains(lower) { return true }
        for h in me.handles {
            if h.raw.lowercased().contains(lower) { return true }
            if h.normalized.lowercased().contains(lower) { return true }
        }
        return false
    }

    /// Build the `from:` predicate. Each filter restricts to messages that:
    ///   - are NOT from me (is_from_me = 0)
    ///   - have a sender handle that matches the resolved person.
    ///
    /// **`from:me` special case**: filters that pass `isMeFilter` emit
    /// `is_from_me = 1` instead — this is how `from:me`, `from:"<my own
    /// name>"`, and `from:"<my own phone/email>"` all resolve to "sent by
    /// me." See `isMeFilter` for the matching rules.
    ///
    /// Multiple `from:` AND together (a message can't be from two people, so
    /// AND across filters in practice means "all filters must match the same
    /// sender" — most users will use one). For OR-within-filter we just dump
    /// all candidate handles into an `IN` list. AND-ing a me-filter with a
    /// non-me filter (e.g. `from:me from:mom`) yields an impossible predicate
    /// (`is_from_me = 1 AND is_from_me = 0`) and returns zero results — the
    /// SQL is well-formed, just contradictory, which is the right behavior
    /// for a literally-impossible query.
    static func fromClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        var sawMe = false
        for filter in filters {
            if isMeFilter(filter, contacts: contacts) {
                // Collapse multiple `me` synonyms — `from:me from:Satyajit`
                // both mean "sent by me", so one `is_from_me = 1` clause is
                // enough. Without this we'd emit a redundant duplicate.
                if !sawMe {
                    clauses.append("(m.is_from_me = 1)")
                    sawMe = true
                }
                continue
            }
            let candidates = resolveHandles(forFilter: filter, contacts: contacts)
            guard !candidates.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
            // is_from_me = 0 means received. The sender's handle must
            // either appear in the resolved candidate set (exact match,
            // covers AddressBook-resolved names) OR contain the raw
            // filter as a substring (covers partial handles like
            // `from:415` for contacts not in AddressBook — mirrors the
            // `withClause` 2026-05-25 fix pinned by ChatOperatorE2ETests).
            clauses.append("(m.is_from_me = 0 AND (h.id IN (\(placeholders)) OR h.id LIKE ?))")
            for c in candidates { args.append(c) }
            args.append("%\(filter)%")
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the `to:` predicate. Each filter restricts to:
    ///   - is_from_me = 1 (you sent it)
    ///   - the chat's participants include the named person.
    ///
    /// We enumerate the candidate chats via a subquery against
    /// `chat_handle_join`, then constrain `cmj.chat_id` to that set.
    static func toClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            let candidates = resolveHandles(forFilter: filter, contacts: contacts)
            guard !candidates.isEmpty else { continue }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ", ")
            // Same two-branch matching as `withClause` / `fromClause`:
            // exact handle-set membership for AddressBook-resolved names,
            // plus a substring LIKE for partial handles that fell through
            // to the raw filter string.
            clauses.append("""
                (m.is_from_me = 1 AND cmj.chat_id IN (
                    SELECT chj.chat_id
                    FROM chat_handle_join chj
                    JOIN handle h2 ON h2.ROWID = chj.handle_id
                    WHERE h2.id IN (\(placeholders)) OR h2.id LIKE ?
                ))
                """)
            for c in candidates { args.append(c) }
            args.append("%\(filter)%")
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the `with:` predicate. Each filter restricts to messages in
    /// **any chat (1:1 OR group) that the named person participates in**.
    ///
    /// Semantically: "every conversation I've had with this person." Use
    /// this when the user types `with:Howard` and means "Howard's 1:1 AND
    /// every group Howard is in."
    ///
    /// Distinct from:
    /// - `chat:`/`in:` — match a chat's `display_name`. Used for naming a
    ///   *specific* named chat (a group chat called "Family", a project
    ///   thread, etc.). Does NOT consider participants.
    /// - `from:`/`to:` — sender-direction filters. `from:Howard` is "messages
    ///   Howard sent me"; `with:Howard` includes both directions plus any
    ///   group Howard is in.
    ///
    /// Multiple `with:` filters AND together: `with:howard with:mom` =
    /// chats where BOTH Howard and Mom participate (typically a group).
    /// **Comma-separated values** inside a single `with:` token are
    /// also AND'd — `with:"Howard, Mom"` is the same as `with:howard
    /// with:mom` (and the same query shape the user typed for `chat:`
    /// just gets the loose semantics here — extras OK).
    ///
    /// Resolution: `resolveHandles` produces candidate handles for the
    /// filter substring (contact display name + raw + normalized handle).
    /// We then filter chats whose `chat_handle_join` includes any candidate.
    static func withClause(
        _ filters: [String],
        contacts: ResolvedContacts
    ) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            // Split commas so `with:"A, B, C"` AND's the participants
            // the same way three separate `with:` tokens would. Single
            // values fall through to a one-element list and behave
            // exactly like before. Empty pieces are dropped — leading
            // comma, trailing comma, or `with:","` shouldn't blow up.
            let pieces = filter
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let effectivePieces = pieces.isEmpty ? [filter] : pieces

            for piece in effectivePieces {
                let resolved = resolveHandles(forFilter: piece, contacts: contacts)
                // `resolveHandles` always returns at least the raw filter
                // if no contact matched, so this is never empty.
                // Defensive guard:
                guard !resolved.isEmpty else { continue }
                let placeholders = Array(repeating: "?", count: resolved.count).joined(separator: ", ")
                // Any chat (1:1 OR group) whose participants include the
                // resolved person. The previous `ch.style = 45` clause was
                // dropped in 2026-05-25 — the user wanted `with:` to mean
                // "all chats with this person" rather than "their 1:1 only."
                //
                // Two-branch match per chat:
                //   (a) EXACT: `ph.id IN (resolved...)` — when `resolveHandles`
                //       produces the full canonical handle string (the
                //       common case when the filter resolves through
                //       AddressBook).
                //   (b) SUBSTRING: `ph.id LIKE %piece%` — when the user
                //       types a partial handle like `with:888` and the
                //       AddressBook doesn't have a contact entry to
                //       resolve. Without this branch, `resolveHandles`
                //       falls through to the raw filter string, and
                //       `IN ('888')` then fails to match the actual
                //       `+15558889999` row. Bug pinned by
                //       `ChatOperatorE2ETests.test_with_handleSubstring_*`.
                clauses.append("""
                    (ch.ROWID IN (
                        SELECT chj.chat_id
                        FROM chat_handle_join chj
                        JOIN handle ph ON ph.ROWID = chj.handle_id
                        WHERE ph.id IN (\(placeholders))
                           OR ph.id LIKE ?
                    ))
                    """)
                for h in resolved { args.append(h) }
                args.append("%\(piece)%")
            }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Parse the phrase into needles. **Legacy shim.** New code should
    /// use `PhraseQuery.parse(_:)` and consume the AST directly — that's
    /// what the live `search()` path does.
    ///
    /// This function is preserved for backward compat with FTSSearcher's
    /// pre-AST callers and a handful of tests. It returns the *leaf term*
    /// strings (no regex needles surface here), which is enough for the
    /// FTS5 path's "is anything short" decision and the previous
    /// substring-search semantics.
    ///
    /// Empty needles (from trailing `+`) and pure-whitespace tokens are
    /// discarded. `preserveCase: true` retains original casing.
    static func parseNeedles(_ phrase: String, preserveCase: Bool = false) -> [String] {
        // Try the new parser first. If it succeeds, extract the term
        // strings (and ignore regex needles — they're not representable
        // as bare strings). If it throws (invalid regex), fall back to
        // the legacy `+`-split logic so callers don't break.
        if let ast = try? PhraseQuery.parse(phrase, caseSensitive: preserveCase) {
            var out: [String] = []
            for g in ast.groups {
                for n in g.needles {
                    if case .term(let t, _) = n {
                        let s = preserveCase ? t : t.lowercased()
                        if !s.isEmpty { out.append(s) }
                    }
                }
            }
            if !out.isEmpty { return out }
        }
        // Legacy fall-through (invalid AST or only-regex needles).
        return phrase
            .split(separator: "+", omittingEmptySubsequences: true)
            .map {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return preserveCase ? trimmed : trimmed.lowercased()
            }
            .filter { !$0.isEmpty }
    }

    /// AST-aware SQL pre-filter.
    ///
    /// Translates a `PhraseQuery` into the SQL WHERE fragment + arguments.
    /// The translation is a faithful AND-of-groups, OR-within-groups:
    /// each Group becomes a parenthesized OR-of-leaf-predicates; the
    /// groups are AND'd together at the top level.
    ///
    /// Per-leaf predicates:
    ///   - `.term(text, .word)` and `.term(text, .substring)` both emit
    ///     the same SQL coarse filter (substring match against text +
    ///     blob INSTR variants). The word-boundary refinement happens
    ///     in Swift on the decoded body — SQL is intentionally a coarse
    ///     superset so we never miss real candidates.
    ///   - `.regex` emits the same INSTR-against-blob fallback as a
    ///     wildcard substring. We DO try to push down the longest literal
    ///     fragment of the regex (e.g. `/cact.*/` has literal "cact") to
    ///     help SQL discriminate. When the regex has no literal portion
    ///     (e.g. `/.+/` ), the SQL clause for that leaf becomes "1"
    ///     (match-anything) and the Swift filter does the real work.
    ///
    /// Case sensitivity matches the legacy `phraseClause`: in
    /// case-insensitive mode we emit three INSTR variants (lower/Title/
    /// UPPER) per leaf; in case-sensitive mode we emit one exact match.
    static func phraseClause(
        ast: PhraseQuery,
        caseSensitive: Bool = false
    ) -> (String, [DatabaseValueConvertible]) {
        guard !ast.isEmpty else { return ("", []) }
        var groupClauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for group in ast.groups {
            var orParts: [String] = []
            for needle in group.needles {
                let (frag, fragArgs) = leafCoarseFilter(needle, caseSensitive: caseSensitive)
                orParts.append(frag)
                args.append(contentsOf: fragArgs)
            }
            if orParts.isEmpty { continue }
            // Single-needle group: avoid the extra parens for SQL clarity.
            if orParts.count == 1 {
                groupClauses.append(orParts[0])
            } else {
                groupClauses.append("(" + orParts.joined(separator: " OR ") + ")")
            }
        }
        guard !groupClauses.isEmpty else { return ("", []) }
        return ("AND " + groupClauses.joined(separator: " AND "), args)
    }

    /// Build the SQL coarse-filter fragment for a single leaf needle.
    /// Returns `(fragment, args)`. Fragment is wrapped in parens so it
    /// can be OR'd or AND'd safely.
    private static func leafCoarseFilter(
        _ needle: PhraseQuery.Needle,
        caseSensitive: Bool
    ) -> (String, [DatabaseValueConvertible]) {
        switch needle {
        case .term(let text, _):
            // Word-boundary and substring share the same coarse SQL —
            // the word-boundary refinement is purely Swift-side.
            return leafSubstringFilter(text: text, caseSensitive: caseSensitive)
        case .regex(let cr):
            // Push down the longest literal fragment of the regex if
            // we can find one. Otherwise emit "1" so the row is always
            // a candidate; Swift will filter.
            if let literal = longestLiteralFragment(of: cr.source), literal.count >= 2 {
                return leafSubstringFilter(
                    text: literal,
                    // Regex always case-insensitive in the coarse path
                    // unless the regex is explicitly case-sensitive. We
                    // err on the side of widening recall here — Swift
                    // refines anyway.
                    caseSensitive: caseSensitive && !cr.caseInsensitive
                )
            }
            return ("(1)", [])
        }
    }

    /// The classic substring coarse filter — TEXT LIKE + INSTR variants
    /// against the attributedBody blob. Identical to the pre-AST
    /// `phraseClause` semantics; just factored out so AST traversal can
    /// reuse it.
    private static func leafSubstringFilter(
        text: String,
        caseSensitive: Bool
    ) -> (String, [DatabaseValueConvertible]) {
        if text.isEmpty { return ("(1)", []) }
        if caseSensitive {
            return (
                "(m.text GLOB ? OR INSTR(m.attributedBody, ?) > 0)",
                ["*\(text)*", Data(text.utf8)]
            )
        }
        let lower = text.lowercased()
        let title = lower.capitalized
        let upper = lower.uppercased()
        // Codex audit M2 (2026-05-25): the three INSTR variants
        // (lower/Title/UPPER) miss MIXED-case bytes like `iPhone`,
        // `macOS`, `eBay` — neither lower nor Title nor UPPER bytes
        // appear in messages that use the canonical casing. For those
        // terms we add a recall-safe branch matching every row whose
        // content lives in `attributedBody` (m.text is NULL/empty);
        // Swift's word-boundary refinement then drops the
        // non-matching rows. The branch is gated on `isMixedCase`
        // so plain-lowercase queries like `hello` keep their fast
        // 3-variant SQL path.
        let isMixedCase = (text != lower && text != title && text != upper)
        // A term with a "smart-quotable" character (apostrophe, quote, dash,
        // ellipsis) can't be byte-matched in the blob: iMessage stores the
        // CURLY variant (’ “ ” — …) but the query carries the STRAIGHT one,
        // so INSTR misses every such message ("Couldn't" never finds the
        // stored "Couldn’t"). Route these through the recall-safe branch
        // (match all attributedBody-only rows) and let the Swift refinement —
        // which folds typography — do the precise match.
        let hasFoldableTypography = text.contains {
            "'’‘\u{2018}\u{2019}\u{201B}\"\u{201C}\u{201D}—–\u{2013}\u{2014}…\u{2026}".contains($0)
        }
        if isMixedCase || hasFoldableTypography {
            return (
                """
                (
                    m.text LIKE ?
                    OR INSTR(m.attributedBody, ?) > 0
                    OR INSTR(m.attributedBody, ?) > 0
                    OR INSTR(m.attributedBody, ?) > 0
                    OR (
                        m.attributedBody IS NOT NULL
                        AND (m.text IS NULL OR m.text = '')
                    )
                )
                """,
                ["%\(lower)%", Data(lower.utf8), Data(title.utf8), Data(upper.utf8)]
            )
        }
        return (
            """
            (
                m.text LIKE ?
                OR INSTR(m.attributedBody, ?) > 0
                OR INSTR(m.attributedBody, ?) > 0
                OR INSTR(m.attributedBody, ?) > 0
            )
            """,
            ["%\(lower)%", Data(lower.utf8), Data(title.utf8), Data(upper.utf8)]
        )
    }

    /// Find the longest contiguous literal substring of a regex source.
    /// `cact.*` → "cact"; `^(hello|world)$` → "" (alternations); `a.b` →
    /// "a" or "b" (we return the first of the longest). Used to push
    /// down a literal coarse filter for regex needles.
    ///
    /// Conservative — we only treat characters as "literal" if they're
    /// alphanumeric or the space character. Any regex metachar terminates
    /// the current run. Skips over escape sequences so `\.` doesn't
    /// accidentally bleed.
    static func longestLiteralFragment(of source: String) -> String? {
        var best = ""
        var current = ""
        var i = source.startIndex
        let metacharSet: Set<Character> = [
            "\\", "(", ")", "[", "]", "{", "}",
            ".", "?", "+", "*", "|", "^", "$",
        ]
        while i < source.endIndex {
            let ch = source[i]
            if ch == "\\" {
                // Skip the escape character and the escaped char both.
                if best.count < current.count { best = current }
                current = ""
                let next = source.index(after: i)
                if next < source.endIndex {
                    i = source.index(after: next)
                } else {
                    i = source.endIndex
                }
                continue
            }
            if metacharSet.contains(ch) {
                if best.count < current.count { best = current }
                current = ""
                i = source.index(after: i)
                continue
            }
            current.append(ch)
            i = source.index(after: i)
        }
        if best.count < current.count { best = current }
        return best.isEmpty ? nil : best
    }

    /// Legacy SQL builder for plain-string needles. Kept for FTSSearcher's
    /// path during the AST migration. Internally delegates to the AST
    /// version by wrapping each string into a `.term(_, .substring)`
    /// (substring semantics — the legacy callers all assumed substring).
    static func phraseClause(
        _ needles: [String],
        caseSensitive: Bool = false
    ) -> (String, [DatabaseValueConvertible]) {
        let groups = needles.map { PhraseQuery.Group([.term($0, .substring)]) }
        let ast = PhraseQuery(groups: groups)
        return phraseClause(ast: ast, caseSensitive: caseSensitive)
    }

    /// Build the reactions predicate.
    ///
    /// Reactions live in the same `message` table — they're rows where
    /// `associated_message_type` is in 2000-2999. To filter a target message
    /// by reaction count or kind we use a correlated subquery against
    /// `message` itself, matched on `associated_message_guid`.
    ///
    /// The join key is **not** equal to `m.guid` directly — real rows carry
    /// a positional prefix (`p:N/`, `bp:`). We enumerate the known variants
    /// in an IN list rather than using `LIKE '%' || m.guid`:
    ///   - `m.guid` (bare — rare, but does appear)
    ///   - `'p:0/' || m.guid` (most common, ~92%)
    ///   - `'p:1/' || m.guid` … `'p:N/' || m.guid` for N up to 9
    ///   - `'bp:' || m.guid`
    ///
    /// A leading-wildcard LIKE turns the subquery into a full scan of every
    /// tapback row per candidate, which collapsed an empirical real-world DB
    /// (~200k messages, ~50k tapbacks) into multi-minute query times. The
    /// IN approach can use the implicit index on `associated_message_guid`
    /// and stays sub-second.
    ///
    /// SQL shape for a single `.count(>=, 3)` filter:
    /// ```
    /// AND (
    ///   SELECT COUNT(*) FROM message r
    ///   WHERE r.associated_message_type BETWEEN 2000 AND 2999
    ///     AND r.associated_message_guid IN (
    ///         m.guid, 'p:0/' || m.guid, 'p:1/' || m.guid, …, 'bp:' || m.guid
    ///     )
    /// ) >= 3
    /// ```
    ///
    /// For `.kind(.love)` we add `AND r.associated_message_type = 2000` and
    /// require count > 0.
    ///
    /// Multiple filters AND together (each becomes its own subquery).
    /// `reactions:>=3 reactions:love` ⇒ at least 3 total AND at least one love.
    ///
    /// Empty input → no predicate.
    static func reactionsClause(_ filters: [ReactionFilter]) -> (String, [DatabaseValueConvertible]) {
        guard !filters.isEmpty else { return ("", []) }
        // Build the IN list of join-key variants. We cover `p:0/` through
        // `p:9/` (the parts with single-digit indices that we've actually
        // observed in real-world DBs), `bp:`, and the bare GUID. Beyond
        // p:9/ is extraordinarily rare (multi-part attachment messages
        // with 10+ segments are essentially non-existent in iMessage's
        // history) — if it ever needed expanding we'd add up to 19.
        let prefixes: [String] = [""] + (0...9).map { "p:\($0)/" } + ["bp:"]
        let inExpressions = prefixes.map { p in
            p.isEmpty ? "m.guid" : "'\(p)' || m.guid"
        }.joined(separator: ", ")

        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for filter in filters {
            // Common subquery template — the join key IN list and the
            // type range. The `m.guid IS NOT NULL` guard prevents matching
            // every NULL-GUID row to empty-prefix variants on a few very
            // old rows that have no guid.
            // Per-sender dedup with removal honor: count DISTINCT senders
            // (handle_id, is_from_me) whose LATEST reaction row for this
            // target is an add (2000-2999), not a removal (3000-3999).
            //
            // The inner correlated `MAX(date)` selects each sender's most
            // recent reaction row across the full 2000-3999 range; the
            // outer `BETWEEN 2000 AND 2999` predicate then keeps only
            // those whose latest is still an active add. This matches
            // `ReactionLoader.loadReactions`'s in-memory logic, so the
            // count the user sees on a message bubble agrees with the
            // count `reactions:>=N` matches against.
            //
            // Codex audit H4 (2026-05-25): the previous SQL only looked
            // at 2000-2999, so a sender who reacted and unreacted still
            // counted toward `reactions:>=N`.
            let baseSub = """
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM message r
                    WHERE r.associated_message_type BETWEEN 2000 AND 2999
                      AND m.guid IS NOT NULL
                      AND r.associated_message_guid IN (\(inExpressions))
                      AND r.date = (
                        SELECT MAX(r2.date) FROM message r2
                        WHERE r2.handle_id IS r.handle_id
                          AND r2.is_from_me = r.is_from_me
                          AND r2.associated_message_guid = r.associated_message_guid
                          AND r2.associated_message_type BETWEEN 2000 AND 3999
                      )
                    GROUP BY r.handle_id, r.is_from_me
                )
                """
            switch filter {
            case .count(let cmp, let n):
                clauses.append("((\(baseSub)) \(cmp.rawValue) ?)")
                args.append(n)
            case .any:
                // Sugar for count >= 1.
                clauses.append("((\(baseSub)) >= 1)")
            case .kind(let kind):
                // Same latest-row check as `baseSub`, plus a constraint
                // that the latest type equals the requested kind. After
                // the H4 fix this also drops senders whose latest row is
                // a removal — `reactions:love` won't match messages where
                // a love was added then unreacted.
                let typed = """
                    SELECT COUNT(*) FROM (
                        SELECT 1 FROM message r
                        WHERE r.associated_message_type = ?
                          AND m.guid IS NOT NULL
                          AND r.associated_message_guid IN (\(inExpressions))
                          AND r.date = (
                            SELECT MAX(r2.date) FROM message r2
                            WHERE r2.handle_id IS r.handle_id
                              AND r2.is_from_me = r.is_from_me
                              AND r2.associated_message_guid = r.associated_message_guid
                              AND r2.associated_message_type BETWEEN 2000 AND 3999
                          )
                        GROUP BY r.handle_id, r.is_from_me
                    )
                    """
                clauses.append("((\(typed)) >= 1)")
                args.append(kind.typeValue)
            }
        }
        if clauses.isEmpty { return ("", []) }
        return ("AND (" + clauses.joined(separator: " AND ") + ")", args)
    }

    /// Build the content-type predicate.
    ///
    /// Push as much as we can down to SQL so we don't waste candidates on the
    /// Swift side. SQL handles two cuts:
    ///   1. Attachment-based: messages whose ROWID is in the join target set
    ///      with attachments matching the filter (image/video/audio/sticker/
    ///      file mime prefix or is_sticker).
    ///   2. Balloon-based: messages whose `balloon_bundle_id` matches the
    ///      provider for link previews (`URLBalloonProvider`), Apple Pay,
    ///      etc. Captured as a `balloon_bundle_id LIKE '%...%'` clause.
    ///
    /// `type:text` is special — it's the NEGATION of any-attachment AND
    /// any-balloon. We emit:
    ///   AND m.ROWID NOT IN (SELECT message_id FROM message_attachment_join)
    ///   AND (m.balloon_bundle_id IS NULL OR m.balloon_bundle_id = '')
    ///
    /// `type:attachment` expands to `image OR video OR audio OR sticker OR file`
    /// (any non-text non-link content type). See `TypeFilter.messageTypes`.
    ///
    /// Multiple `type:` filters OR together at the top level — `type:image
    /// type:video` means "image OR video". This differs from how `chat:` /
    /// `from:` work (those AND) because users overwhelmingly want OR for type.
    ///
    /// Empty input → no predicate.
    static func typeClause(_ filters: [TypeFilter]) -> String {
        guard !filters.isEmpty else { return "" }

        // Flatten the requested types — dedup, preserving order. `attachment`
        // sugar expands here. Multiple `type:` tokens unify into a single OR.
        var requested: Set<MessageType> = []
        for f in filters {
            for t in f.messageTypes { requested.insert(t) }
        }
        guard !requested.isEmpty else { return "" }

        // Special case: `type:text` (and nothing else) — exclude any row that
        // has an attachment or a known balloon_bundle_id. We could mix text
        // with other types (`type:text type:image` ⇒ "text OR image") but
        // that's a strange query; we still support it via the union below.
        let wantsText = requested.contains(.text)
        // Attachment-based predicates: assembled into a single subquery
        // against the join. Each MIME class contributes a row-filter on the
        // attachment table; we union them in a single inner SELECT.
        let mimePreds = mimePredicates(for: requested)
        // Balloon-based predicates: link previews, Apple Pay, location, other.
        let balloonPreds = balloonPredicates(for: requested)

        var ors: [String] = []
        if !mimePreds.isEmpty {
            let mimeWhere = mimePreds.joined(separator: " OR ")
            ors.append("""
                m.ROWID IN (
                    SELECT mj.message_id
                    FROM message_attachment_join mj
                    JOIN attachment a ON a.ROWID = mj.attachment_id
                    WHERE \(mimeWhere)
                )
                """)
        }
        if !balloonPreds.isEmpty {
            ors.append("(" + balloonPreds.joined(separator: " OR ") + ")")
        }
        if wantsText {
            // A pure text message has no attachment row AND no balloon bundle.
            // (Empty string treated equivalently to NULL — both occur in real
            // DBs for the no-balloon case.)
            ors.append("""
                (
                  m.ROWID NOT IN (SELECT mj.message_id FROM message_attachment_join mj)
                  AND (m.balloon_bundle_id IS NULL OR m.balloon_bundle_id = '')
                )
                """)
        }
        if ors.isEmpty { return "" }
        return "AND (" + ors.joined(separator: " OR ") + ")"
    }

    /// Build the per-attachment mime/sticker predicates for the requested
    /// types. Each clause matches one attachment row's columns.
    private static func mimePredicates(for kinds: Set<MessageType>) -> [String] {
        var out: [String] = []
        if kinds.contains(.sticker) {
            out.append("a.is_sticker = 1")
        }
        if kinds.contains(.image) {
            out.append("(a.mime_type LIKE 'image/%' AND (a.is_sticker = 0 OR a.is_sticker IS NULL))")
        }
        if kinds.contains(.video) {
            out.append("a.mime_type LIKE 'video/%'")
        }
        if kinds.contains(.audio) {
            out.append("a.mime_type LIKE 'audio/%'")
        }
        if kinds.contains(.file) {
            // "File" here means: a real attachment row that ISN'T image/
            // video/audio/sticker. PDFs, vcards, docx, source files, plugin
            // payloads that didn't already get matched by balloon predicates.
            out.append("""
                (
                  (a.is_sticker = 0 OR a.is_sticker IS NULL)
                  AND (
                    a.mime_type IS NULL OR a.mime_type = ''
                    OR (
                      a.mime_type NOT LIKE 'image/%'
                      AND a.mime_type NOT LIKE 'video/%'
                      AND a.mime_type NOT LIKE 'audio/%'
                    )
                  )
                )
                """)
        }
        return out
    }

    /// Build the balloon_bundle_id predicates for the requested types. Each
    /// clause matches one row of `message` directly.
    private static func balloonPredicates(for kinds: Set<MessageType>) -> [String] {
        var out: [String] = []
        if kinds.contains(.linkPreview) {
            out.append("m.balloon_bundle_id LIKE '%URLBalloonProvider%'")
        }
        if kinds.contains(.applePay) {
            out.append("(m.balloon_bundle_id LIKE '%PeerPaymentMessagesExtension%' OR m.balloon_bundle_id LIKE '%PassbookUI%')")
        }
        if kinds.contains(.location) {
            out.append("m.balloon_bundle_id LIKE '%FindMyMessagesApp%'")
        }
        if kinds.contains(.other) {
            // "Other" captures the remaining balloon plugins (GamePigeon,
            // polls, handwriting, digital touch, …) — anything that has a
            // balloon_bundle_id but isn't one we recognize. Used by
            // `type:attachment` to sweep up plugin payloads.
            out.append("""
                (
                  m.balloon_bundle_id IS NOT NULL
                  AND m.balloon_bundle_id != ''
                  AND m.balloon_bundle_id NOT LIKE '%URLBalloonProvider%'
                  AND m.balloon_bundle_id NOT LIKE '%PeerPaymentMessagesExtension%'
                  AND m.balloon_bundle_id NOT LIKE '%PassbookUI%'
                  AND m.balloon_bundle_id NOT LIKE '%FindMyMessagesApp%'
                )
                """)
        }
        return out
    }

    /// Build the date predicate.
    ///
    /// Handles three states from the constraint:
    ///   - `.unbounded` → no predicate (`""`).
    ///   - `.range(r)` → half-open `>= lo AND < hi` (codex L1 fix —
    ///     the previous `BETWEEN ? AND ?` was inclusive on both ends,
    ///     so an `on:2024-05-22` window ending at `2024-05-23 00:00:00`
    ///     also matched midnight of May 23).
    ///   - `.empty` → `AND 0` (codex H1 fix — contradictory filters
    ///     short-circuit to zero rows instead of falling through to
    ///     "no filter" and silently broadening).
    ///
    /// Also handles the nanoseconds-OR-seconds case from `plans.md`.
    static func dateClause(constraint: DateConstraint) -> (String, [DatabaseValueConvertible]) {
        switch constraint {
        case .unbounded:
            return ("", [])
        case .empty:
            // Force zero rows. `AND 0` is the cheapest dead predicate;
            // SQLite optimizes the rest of the WHERE away.
            return ("AND 0", [])
        case .range(let range):
            let lo = range.lowerBound
            let hi = range.upperBound
            let loNS = MessageDate.nanosecondsSinceMacEpoch(from: lo)
            let hiNS = MessageDate.nanosecondsSinceMacEpoch(from: hi)
            let loS = MessageDate.secondsSinceMacEpoch(from: lo)
            let hiS = MessageDate.secondsSinceMacEpoch(from: hi)
            let sql = """
                AND (
                      (m.date > 1000000000000 AND m.date >= ? AND m.date < ?)
                   OR (m.date <= 1000000000000 AND m.date >= ? AND m.date < ?)
                )
                """
            return (sql, [loNS, hiNS, loS, hiS])
        }
    }

    /// Backward-compat overload. `nil` is ambiguous between "no filter"
    /// and "empty intersection"; new callers should use
    /// `dateClause(constraint:)` and `intersectConstraint(_:_:)` so the
    /// distinction is preserved. We keep this for callers that genuinely
    /// only have the optional shape (programmatic-range path) where
    /// `nil` is always "no filter."
    static func dateClause(_ range: ClosedRange<Date>?) -> (String, [DatabaseValueConvertible]) {
        dateClause(constraint: range.map(DateConstraint.range) ?? .unbounded)
    }

    /// Resolve a chat's "partner" name — what we'd show in a results list
    /// as the conversation identity.
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
            // No more "[group] " text prefix — the UI renders a person.3
            // SF Symbol when `chatStyle == 43`, which reads cleaner than
            // ASCII brackets glued to the front of the name.
            label = displayName
        } else if style == 43 {
            // Group without a name: list a few members.
            let hs = handles(forChat: chatID, cache: &handlesCache)
            let names = hs.map { contacts.byHandle[$0]?.displayName ?? $0.raw }
            let preview = names.prefix(4).joined(separator: ", ")
            let suffix = names.count > 4 ? " +\(names.count - 4)" : ""
            label = preview + suffix
        } else {
            // 1:1: the single other participant.
            let hs = handles(forChat: chatID, cache: &handlesCache)
            if let first = hs.first {
                label = contacts.byHandle[first]?.displayName ?? first.raw
            } else {
                label = "(unknown)"
            }
        }

        cache[chatID] = label
        return label
    }

    /// Fetch & cache the participant handles for a chat (excluding the user).
    private func handles(forChat chatID: Int64, cache: inout [Int64: [Handle]]) -> [Handle] {
        if let cached = cache[chatID] { return cached }
        let rows: [String] = (try? database.dbQueue.read { db in
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
