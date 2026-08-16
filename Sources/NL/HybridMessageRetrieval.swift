//
//  HybridMessageRetrieval.swift
//  Hourglass
//
//  Production bridge from a validated Needle call to the generic local
//  conversation-window index. All scope resolution remains deterministic;
//  the small router never emits SQL, vector IDs, or contact handles.
//

import Foundation
import GRDB

extension MessageSearchTools {
    public func hybridSearch(
        _ request: HybridMessageRetrievalRequest
    ) async throws -> HybridMessageRetrievalOutcome? {
        guard let store = indexStore,
              (try? store.conversationWindowsAreReady()) == true,
              !request.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let scopeResolution = try await resolveHybridScope(for: request)
        guard scopeResolution.isValid else {
            return HybridMessageRetrievalOutcome(
                candidates: [],
                windowCount: 0,
                exactCandidateCount: 0,
                expandedCandidateCount: 0,
                denseCandidateCount: 0
            )
        }

        let scope = ConversationWindowSearchScope(
            chatIDs: scopeResolution.chatIDs,
            dateRange: request.dateRange,
            fromMe: scopeResolution.fromMe,
            senderHandleIDs: scopeResolution.senderHandleIDs
        )
        let encoder = AppleWordSemanticEncoder()
        let report = try await Task.detached(priority: .userInitiated) {
            try ConversationWindowIndex.search(
                semanticQuery: request.semanticQuery,
                scope: scope,
                store: store,
                // Retrieve broadly, then rerank the actual eligible message
                // bodies below. This matters in groups: a window can contain
                // Howard and a joke from Atul, but `jokes from Howard` must
                // make Howard's own text earn the result.
                limit: 24,
                encoder: encoder
            )
        }.value
        guard !report.hits.isEmpty else {
            return HybridMessageRetrievalOutcome(
                candidates: [],
                windowCount: 0,
                exactCandidateCount: report.exactCandidateCount,
                expandedCandidateCount: report.expandedCandidateCount,
                denseCandidateCount: report.denseCandidateCount
            )
        }

        // Overlapping four-turn strides can surface adjacent versions of the
        // same exchange. Keep distinct moments before materializing chat.db.
        var distinctHits: [ConversationWindowHit] = []
        for hit in report.hits {
            let memberIDs = Set(hit.memberRowIDs)
            let duplicates = distinctHits.contains { selected in
                selected.chatID == hit.chatID
                    && !memberIDs.isDisjoint(with: selected.memberRowIDs)
            }
            if !duplicates { distinctHits.append(hit) }
            if distinctHits.count == 12 { break }
        }

        let allRowIDs = Array(Set(distinctHits.flatMap(\.memberRowIDs)))
        let resultMap = try await materializeHybridResults(rowIDs: allRowIDs)
        let queryVector = encoder.vector(for: request.semanticQuery)
        let queryTerms = Set(AppleWordSemanticEncoder.contentTokens(in: request.semanticQuery))
        let expandedTerms = Set(report.expandedTerms).subtracting(queryTerms)

        struct RankedWindow {
            let hit: ConversationWindowHit
            let hero: MessageSearch.Result
            let messages: [MessageSearch.Result]
            let rank: Double
        }
        var rankedWindows: [RankedWindow] = []
        rankedWindows.reserveCapacity(distinctHits.count)

        for hit in distinctHits {
            var window = hit.memberRowIDs.compactMap { resultMap[$0] }
            if let range = request.dateRange {
                window.removeAll { !range.contains($0.message.date) }
            }
            // Search long pasted text through normal message FTS, but exclude
            // it from conversational ranking. Keep the surrounding ordinary
            // turns rather than throwing away the whole exchange.
            window.removeAll {
                $0.message.body.count
                    > ConversationWindowIndexer.maximumIndexedMessageCharacters
            }
            guard !window.isEmpty else { continue }

            let senderEligible = window.filter { result in
                if scopeResolution.fromMe == true { return result.message.isFromMe }
                if scopeResolution.fromMe == false {
                    guard !result.message.isFromMe else { return false }
                    if scopeResolution.senderRawHandles.isEmpty { return true }
                    guard let raw = result.message.senderHandle else { return false }
                    return scopeResolution.senderRawHandles.contains(raw)
                }
                return true
            }
            guard !senderEligible.isEmpty else { continue }

            let heroAndRelevance = senderEligible.map { result in
                (
                    result,
                    heroRelevance(
                        result,
                        queryTerms: queryTerms,
                        expandedTerms: expandedTerms,
                        anchorRowID: hit.anchorRowID
                    )
                )
            }.max { $0.1 < $1.1 }
            guard let (hero, relevance) = heroAndRelevance else { continue }

            // Only sender-scoped, lexically implicit windows need one extra
            // semantic check. Score the requested sender's text as a single
            // exchange instead of embedding every message independently.
            // Exact/neighbor hits skip this work entirely.
            let senderSemantic: Double
            if scopeResolution.fromMe != nil,
               relevance < 0.3,
               let queryVector,
               let senderVector = encoder.vector(
                   for: senderEligible.map(\.message.body).joined(separator: "\n")
               ) {
                senderSemantic = max(
                    0,
                    AppleWordSemanticEncoder.similarity(queryVector, senderVector)
                )
            } else {
                senderSemantic = 0
            }
            rankedWindows.append(RankedWindow(
                hit: hit,
                hero: hero,
                messages: window.sorted(by: { $0.message.date < $1.message.date }),
                rank: relevance + senderSemantic * 0.8 + hit.score * 2.5
            ))
        }
        rankedWindows.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.hit.windowID > $1.hit.windowID
        }

        // Diversity pass: the top results must be DIFFERENT moments. The
        // member-overlap dedupe above only drops overlapping window strides;
        // non-overlapping windows of one long conversation (or several hits
        // minutes apart in one chat) would still fill every slot. Group by
        // exchange identity — same chat within a two-hour moment, the
        // conflict retriever's precedent — keeping one result per exchange
        // with the runner-up windows' messages attached as context.
        let exchanges = MessageExchangeGrouping.distinctExchanges(
            from: rankedWindows.map {
                MessageExchangeGrouping.Candidate(hero: $0.hero, messages: $0.messages)
            },
            maxExchanges: 6
        )

        var ordered: [MessageSearch.Result] = []
        var seen = Set<Int64>()
        func append(_ result: MessageSearch.Result) {
            if seen.insert(result.message.id).inserted { ordered.append(result) }
        }

        // Flat candidates lead with one hero per distinct exchange so any
        // consumer rendering a top-N list shows N different moments; each
        // exchange's surrounding messages follow for context-aware paths.
        for exchange in exchanges { append(exchange.hero) }
        for exchange in exchanges {
            for result in exchange.messages { append(result) }
            if ordered.count >= request.limit { break }
        }

        return HybridMessageRetrievalOutcome(
            candidates: Array(ordered.prefix(request.limit)),
            windowCount: exchanges.count,
            exactCandidateCount: report.exactCandidateCount,
            expandedCandidateCount: report.expandedCandidateCount,
            denseCandidateCount: report.denseCandidateCount,
            exchanges: exchanges
        )
    }

    private struct HybridScopeResolution: Sendable {
        let chatIDs: [Int64]?
        let fromMe: Bool?
        let senderHandleIDs: [Int64]
        let senderRawHandles: Set<String>
        let isValid: Bool
    }

    private func resolveHybridScope(
        for request: HybridMessageRetrievalRequest
    ) async throws -> HybridScopeResolution {
        var scopedChatIDs: Set<Int64>?

        if let person = request.withPerson, !person.isEmpty {
            guard let resolved = try await resolveScopedPersonChat(named: person) else {
                return HybridScopeResolution(
                    chatIDs: [], fromMe: nil, senderHandleIDs: [],
                    senderRawHandles: [], isValid: false
                )
            }
            scopedChatIDs = Set(resolved.chatRowIDs)
        }

        if let chat = request.chat, !chat.isEmpty {
            let chatIDs = Set(try await resolveHybridChatIDs(named: chat))
            if let existing = scopedChatIDs { scopedChatIDs = existing.intersection(chatIDs) }
            else { scopedChatIDs = chatIDs }
            if scopedChatIDs?.isEmpty == true {
                return HybridScopeResolution(
                    chatIDs: [], fromMe: nil, senderHandleIDs: [],
                    senderRawHandles: [], isValid: false
                )
            }
        }

        guard let sender = request.fromSender, !sender.isEmpty else {
            return HybridScopeResolution(
                chatIDs: scopedChatIDs.map(Array.init),
                fromMe: nil,
                senderHandleIDs: [],
                senderRawHandles: [],
                isValid: true
            )
        }
        if sender.caseInsensitiveCompare("me") == .orderedSame {
            return HybridScopeResolution(
                chatIDs: scopedChatIDs.map(Array.init),
                fromMe: true,
                senderHandleIDs: [],
                senderRawHandles: [],
                isValid: true
            )
        }

        let rawHandles = MessageSearch.resolveHandles(forFilter: sender, contacts: instr.contacts)
        guard !rawHandles.isEmpty else {
            return HybridScopeResolution(
                chatIDs: scopedChatIDs.map(Array.init),
                fromMe: false,
                senderHandleIDs: [],
                senderRawHandles: [],
                isValid: false
            )
        }
        let placeholders = Array(repeating: "?", count: rawHandles.count).joined(separator: ",")
        let handleIDs: [Int64] = try await chatDB.dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT ROWID FROM handle WHERE id IN (\(placeholders))",
                arguments: StatementArguments(rawHandles)
            )
        }
        guard !handleIDs.isEmpty else {
            return HybridScopeResolution(
                chatIDs: scopedChatIDs.map(Array.init),
                fromMe: false,
                senderHandleIDs: [],
                senderRawHandles: Set(rawHandles),
                isValid: false
            )
        }
        return HybridScopeResolution(
            chatIDs: scopedChatIDs.map(Array.init),
            fromMe: false,
            senderHandleIDs: handleIDs,
            senderRawHandles: Set(rawHandles),
            isValid: true
        )
    }

    private func resolveHybridChatIDs(named name: String) async throws -> [Int64] {
        let rawHandles = MessageSearch.resolveHandles(forFilter: name, contacts: instr.contacts)
        let chatDB = self.chatDB
        return try await chatDB.dbQueue.read { db in
            var clauses = ["ch.display_name LIKE ? COLLATE NOCASE"]
            var args: [DatabaseValueConvertible] = ["%\(name)%"]
            if !rawHandles.isEmpty {
                let placeholders = Array(repeating: "?", count: rawHandles.count).joined(separator: ",")
                clauses.append("""
                    (ch.style = 45 AND EXISTS (
                        SELECT 1 FROM chat_handle_join chj
                        JOIN handle h ON h.ROWID = chj.handle_id
                        WHERE chj.chat_id = ch.ROWID AND h.id IN (\(placeholders))
                    ))
                """)
                args.append(contentsOf: rawHandles)
            }
            return try Int64.fetchAll(db, sql: """
                SELECT DISTINCT ch.ROWID
                FROM chat ch
                WHERE \(clauses.joined(separator: " OR "))
            """, arguments: StatementArguments(args))
        }
    }

    private func materializeHybridResults(
        rowIDs: [Int64]
    ) async throws -> [Int64: MessageSearch.Result] {
        guard !rowIDs.isEmpty else { return [:] }
        let chatDB = self.chatDB
        let contacts = instr.contacts
        return try await Task.detached(priority: .userInitiated) {
            let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
            var results: [MessageSearch.Result] = try chatDB.dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.ROWID AS rowid, m.guid AS guid, m.date AS date,
                           m.is_from_me AS is_from_me, m.text AS text,
                           m.attributedBody AS attributedBody,
                           m.associated_message_type AS associated_message_type,
                           h.id AS sender_handle, cmj.chat_id AS chat_id,
                           ch.style AS chat_style, ch.display_name AS chat_display_name,
                           ch.guid AS chat_guid
                    FROM message m
                    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                    JOIN chat ch ON ch.ROWID = cmj.chat_id
                    LEFT JOIN handle h ON h.ROWID = m.handle_id
                    WHERE m.ROWID IN (\(placeholders))
                      AND m.associated_message_type = 0
                """, arguments: StatementArguments(rowIDs))

                let chatIDs = Set(rows.compactMap { $0["chat_id"] as Int64? })
                var participants: [Int64: [String]] = [:]
                if !chatIDs.isEmpty {
                    let chatPlaceholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
                    let participantRows = try Row.fetchAll(db, sql: """
                        SELECT chj.chat_id AS chat_id, h.id AS handle
                        FROM chat_handle_join chj
                        JOIN handle h ON h.ROWID = chj.handle_id
                        WHERE chj.chat_id IN (\(chatPlaceholders))
                    """, arguments: StatementArguments(Array(chatIDs)))
                    for participant in participantRows {
                        if let chatID: Int64 = participant["chat_id"],
                           let handle: String = participant["handle"] {
                            participants[chatID, default: []].append(handle)
                        }
                    }
                }

                return rows.compactMap { row in
                    guard let rowID: Int64 = row["rowid"],
                          let rawDate: Int64 = row["date"],
                          let chatID: Int64 = row["chat_id"] else { return nil }
                    let text: String? = row["text"]
                    let blob: Data? = row["attributedBody"]
                    let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
                    let isFromMe = ((row["is_from_me"] as Int?) ?? 0) == 1
                    let senderHandle: String? = row["sender_handle"]
                    let chatStyle: Int? = row["chat_style"]
                    let displayName: String? = row["chat_display_name"]
                    let partner: String
                    if let displayName, !displayName.isEmpty {
                        partner = displayName
                    } else {
                        let names = (participants[chatID] ?? []).map { contacts.name(forRawHandle: $0) }
                        partner = names.isEmpty ? (senderHandle ?? "(unknown)") : names.joined(separator: ", ")
                    }
                    let senderName = isFromMe
                        ? "You"
                        : senderHandle.map { contacts.name(forRawHandle: $0) } ?? "(unknown)"
                    let senderAvatar = isFromMe
                        ? nil
                        : senderHandle.flatMap { contacts.avatarData(forRawHandle: $0) }
                    return MessageSearch.Result(
                        message: Message(
                            id: rowID,
                            guid: row["guid"],
                            date: MessageDate.date(fromRaw: rawDate),
                            isFromMe: isFromMe,
                            chatRowID: chatID,
                            senderHandle: senderHandle,
                            chatStyle: chatStyle,
                            chatDisplayName: displayName,
                            body: body,
                            associatedMessageType: (row["associated_message_type"] as Int?) ?? 0
                        ),
                        partnerName: partner,
                        senderName: senderName,
                        chatGUID: row["chat_guid"],
                        senderAvatar: senderAvatar
                    )
                }
            }

            let guids = results.compactMap(\.message.guid)
            if !guids.isEmpty {
                let reactions = (try? ReactionLoader.reactions(
                    forTargetGUIDs: guids,
                    database: chatDB,
                    contacts: contacts
                )) ?? [:]
                let types = (try? AttachmentLoader.types(
                    forMessageGUIDs: guids,
                    database: chatDB
                )) ?? [:]
                results = results.map { result in
                    guard let guid = result.message.guid else { return result }
                    return MessageSearch.Result(
                        message: result.message,
                        partnerName: result.partnerName,
                        senderName: result.senderName,
                        chatGUID: result.chatGUID,
                        reactions: reactions[guid] ?? [],
                        senderAvatar: result.senderAvatar,
                        messageType: types[guid] ?? .text
                    )
                }
            }
            return Dictionary(uniqueKeysWithValues: results.map { ($0.message.id, $0) })
        }.value
    }

    private func heroRelevance(
        _ result: MessageSearch.Result,
        queryTerms: Set<String>,
        expandedTerms: Set<String>,
        anchorRowID: Int64
    ) -> Double {
        let bodyTerms = Set(AppleWordSemanticEncoder.contentTokens(in: result.message.body))
        let exactOverlap = Double(queryTerms.intersection(bodyTerms).count)
        let expandedOverlap = Double(expandedTerms.intersection(bodyTerms).count)
        let emptyPenalty = bodyTerms.isEmpty ? 0.3 : 0
        let anchorBoost = result.message.id == anchorRowID ? 0.025 : 0
        return exactOverlap * 0.32
            + min(expandedOverlap, 3) * 0.09
            + log1p(Double(result.reactions.count)) * 0.03
            + anchorBoost
            - emptyPenalty
    }
}
