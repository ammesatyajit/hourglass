//
//  ConversationWindowIndex.swift
//  Hourglass
//
//  Generic, low-memory semantic retrieval over short iMessage exchanges.
//  Needle2 chooses a typed scope; this file searches the corpus. It combines:
//    - exact and expanded FTS5 recall,
//    - compact sign-bit ANN shortlisting plus exact Float16 cosine reranking,
//    - reciprocal-rank fusion,
//    - exact chat/date/sender constraints through window metadata.
//
//  The embedding backend is Apple's system `NLEmbedding`. No model is bundled,
//  downloaded by Hourglass, or kept in RAM with the message corpus.
//

import Foundation
import GRDB
import NaturalLanguage

// MARK: - Semantic text encoder

protocol SemanticTextEncoding: Sendable {
    var dimension: Int { get }
    func vector(for text: String) -> [Float]?
    func expandedTerms(for text: String, neighborsPerTerm: Int) -> [String]
}

/// Mean-pools Apple's local 300-dimensional English word vectors. The output
/// is L2-normalized, so cosine similarity is a dot product. `NLEmbedding` is a
/// system-owned immutable model; this wrapper is instantiated per indexing or
/// query operation rather than shared as app-global state.
final class AppleWordSemanticEncoder: @unchecked Sendable, SemanticTextEncoding {
    private let embedding: NLEmbedding?
    let dimension: Int
    private let cacheLock = NSLock()
    private var tokenCache: [String: [Float]] = [:]
    private var missingTokens = Set<String>()
    private var cacheOrder: [String] = []
    private let maximumCachedTokens = 4_096

    init(language: NLLanguage = .english) {
        let value = NLEmbedding.wordEmbedding(for: language)
        self.embedding = value
        self.dimension = value?.dimension ?? 0
    }

    func vector(for text: String) -> [Float]? {
        guard embedding != nil, dimension > 0 else { return nil }
        let tokens = Self.contentTokens(in: text)
        guard !tokens.isEmpty else { return nil }

        var sum = [Float](repeating: 0, count: dimension)
        var weightTotal: Float = 0
        var counts: [String: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }

        for (token, count) in counts {
            guard let values = vectorForToken(token), values.count == dimension else { continue }
            // Sublinear term frequency prevents a repeated filler word from
            // owning an entire rapid-fire conversation window.
            let weight = Float(1.0 + log(Double(count)))
            for index in values.indices { sum[index] += Float(values[index]) * weight }
            weightTotal += weight
        }
        guard weightTotal > 0 else { return nil }
        let inverseWeight = 1 / weightTotal
        for index in sum.indices { sum[index] *= inverseWeight }
        return Self.normalized(sum)
    }

    func expandedTerms(for text: String, neighborsPerTerm: Int = 5) -> [String] {
        let original = Self.contentTokens(in: text)
        guard let embedding else { return Self.uniqued(original) }
        var terms: [String] = []
        for token in original {
            terms.append(token)
            guard token.count >= 3 else { continue }
            for (neighbor, distance) in embedding.neighbors(
                for: token,
                maximumCount: max(0, neighborsPerTerm)
            ) {
                // Apple's API reports distance (lower is closer). Farther
                // neighbors are often merely distributionally related—e.g.
                // `planning` → `assisting`—and create topic drift in FTS.
                guard distance <= 0.985 else { continue }
                let normalized = Self.normalizedToken(neighbor)
                guard normalized.count >= 3,
                      normalized.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "'" })
                else { continue }
                terms.append(normalized)
            }
        }
        return Self.uniqued(terms)
    }

    private func vectorForToken(_ token: String) -> [Float]? {
        cacheLock.lock()
        if let cached = tokenCache[token] {
            cacheLock.unlock()
            return cached
        }
        if missingTokens.contains(token) {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        guard let values = embedding?.vector(for: token), values.count == dimension else {
            cacheLock.lock()
            missingTokens.insert(token)
            cacheLock.unlock()
            return nil
        }
        let vector = values.map(Float.init)
        cacheLock.lock()
        tokenCache[token] = vector
        cacheOrder.append(token)
        if cacheOrder.count > maximumCachedTokens {
            let evicted = cacheOrder.removeFirst()
            tokenCache.removeValue(forKey: evicted)
        }
        cacheLock.unlock()
        return vector
    }

    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
        var dot: Float = 0
        for index in lhs.indices { dot += lhs[index] * rhs[index] }
        return Double(dot)
    }

    private static func normalized(_ values: [Float]) -> [Float]? {
        var squared: Float = 0
        for value in values { squared += value * value }
        guard squared > 0 else { return nil }
        let inverse = 1 / sqrt(squared)
        return values.map { $0 * inverse }
    }

    static func contentTokens(in text: String) -> [String] {
        PhraseQuery.foldTypography(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
            .map(normalizedToken)
            .filter { token in
                token.count >= 2
                    && !stopwords.contains(token)
                    && token.rangeOfCharacter(from: .letters) != nil
            }
    }

    private static func normalizedToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
        "did", "do", "does", "for", "from", "had", "has", "have", "he",
        "her", "hers", "him", "his", "how", "i", "if", "in", "into", "is",
        "it", "its", "me", "my", "of", "on", "or", "our", "ours", "she",
        "that", "the", "their", "them", "they", "this", "to", "us", "was",
        "we", "were", "what", "when", "where", "which", "who", "why", "will",
        "with", "would", "you", "your", "yours", "message", "messages", "text",
        "texts", "find", "show", "said", "say", "sent", "send"
    ]
}

enum SemanticVectorCodec {
    static func encode(_ vector: [Float]) -> Data {
        let half = vector.map(Float16.init)
        return half.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data, dimensions: Int) -> [Float]? {
        guard dimensions > 0, data.count == dimensions * MemoryLayout<Float16>.size else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float16.self)
            guard values.count == dimensions else { return nil }
            return values.map(Float.init)
        }
    }


    /// Compact cosine shortlist key: one sign bit per embedding dimension.
    /// Search streams ~38 bytes/window and Hamming-ranks a bounded shortlist,
    /// then computes exact cosine only for that shortlist. The full 300-D
    /// corpus is never decoded or held in RAM on each query.
    static func binarySignature(_ vector: [Float]) -> Data {
        var bytes = [UInt8](repeating: 0, count: (vector.count + 7) / 8)
        for (index, value) in vector.enumerated() where value >= 0 {
            bytes[index / 8] |= UInt8(1 << (index % 8))
        }
        return Data(bytes)
    }

    static func hammingDistance(_ lhs: Data, _ rhs: Data) -> Int? {
        guard lhs.count == rhs.count else { return nil }
        return zip(lhs, rhs).reduce(into: 0) { distance, pair in
            distance += (pair.0 ^ pair.1).nonzeroBitCount
        }
    }
}

/// Tiny cross-task gate that keeps opportunistic embedding work out of the
/// latency-critical path. It does not retain corpus data or cancel indexing;
/// it merely asks the utility task to wait briefly after a real search.
enum SemanticIndexWorkload {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var resumeAfter = Date.distantPast
    }

    private static let state = State()

    static func noteInteractiveSearch() {
        state.lock.lock()
        state.resumeAfter = max(state.resumeAfter, Date().addingTimeInterval(5))
        state.lock.unlock()
    }

    static func backgroundDelay() -> TimeInterval {
        state.lock.lock()
        let delay = max(0, state.resumeAfter.timeIntervalSinceNow)
        state.lock.unlock()
        return delay
    }
}

// MARK: - Window construction

enum ConversationWindowIndexer {
    static let maximumMessages = 8
    static let stride = 4
    static let maximumAdjacentGap: TimeInterval = 45 * 60
    static let maximumIndexedMessageCharacters = 2_000
    static let maximumIndexedWindowCharacters = 12_000

    struct SourceMessage: Sendable, Equatable {
        let rowid: Int64
        let body: String
        let date: Int64
        let isFromMe: Bool
        let handleID: Int64?

        var instant: Date { MessageDate.date(fromRaw: date) }
    }

    struct Window: Sendable, Equatable {
        let body: String
        let startDate: Int64
        let endDate: Int64
        let anchorRowID: Int64
        let members: [SourceMessage]
    }

    /// Pure sessionization/windowing helper, exposed to tests. Windows overlap
    /// by four turns, never cross a 45-minute break, and preserve isolated
    /// messages so short but meaningful exchanges remain searchable.
    static func makeWindows(from sortedMessages: [SourceMessage]) -> [Window] {
        guard !sortedMessages.isEmpty else { return [] }
        var output: [Window] = []
        var session: [SourceMessage] = []

        func emit(_ members: ArraySlice<SourceMessage>) {
            let materialized = Array(members)
            guard let first = materialized.first, let last = materialized.last else { return }
            let lines = materialized.compactMap { message -> String? in
                let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                // Long pasted documents/code are searchable through normal
                // message FTS, but they make poor conversational embeddings
                // and can keyword-stuff an otherwise tiny exchange. Keep the
                // semantic window representative and strictly bounded.
                let bounded = String(trimmed.prefix(maximumIndexedMessageCharacters))
                return (message.isFromMe ? "Me: " : "Them: ") + bounded
            }
            guard !lines.isEmpty else { return }
            let body = String(
                lines.joined(separator: "\n").prefix(maximumIndexedWindowCharacters)
            )
            output.append(Window(
                body: body,
                startDate: first.date,
                endDate: last.date,
                anchorRowID: materialized[materialized.count / 2].rowid,
                members: materialized
            ))
        }

        func flushSession() {
            guard !session.isEmpty else { return }
            var start = 0
            while start < session.count {
                let end = min(session.count, start + maximumMessages)
                emit(session[start..<end])
                if end == session.count { break }
                start += stride
            }
            session.removeAll(keepingCapacity: true)
        }

        for message in sortedMessages {
            if let previous = session.last,
               message.instant.timeIntervalSince(previous.instant) > maximumAdjacentGap {
                flushSession()
            }
            session.append(message)
        }
        flushSession()
        return output
    }

    /// Rebuild every chat's windows. Message FTS remains usable throughout;
    /// `lastWindowedROWID` is advanced only after the final chat commits.
    static func rebuildAll(store: IndexStore, includeEmbeddings: Bool = false) throws -> Int64 {
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM window_member")
            try db.execute(sql: "DELETE FROM window_fts")
            try db.execute(sql: "DELETE FROM conversation_window")
        }

        // A per-chat SELECT + transaction is prohibitively expensive on a
        // mature Messages database with thousands of historical chats. Walk
        // the mirror once in indexed keyset pages, retain only the unfinished
        // session at a page boundary, and persist completed windows in large
        // transactions. Memory stays bounded by one page plus one session.
        let encoder = includeEmbeddings ? AppleWordSemanticEncoder() : nil
        var total: Int64 = 0
        var key: (chatID: Int64, date: Int64, rowID: Int64)?
        var activeChatID: Int64?
        var activeSession: [SourceMessage] = []
        var pending: [ScopedWindow] = []
        pending.reserveCapacity(4_096)

        func flushSession() {
            guard let chatID = activeChatID, !activeSession.isEmpty else { return }
            pending.append(contentsOf: makeWindows(from: activeSession).map {
                ScopedWindow(chatID: chatID, window: $0)
            })
            activeSession.removeAll(keepingCapacity: true)
        }

        func persistPending() throws {
            guard !pending.isEmpty else { return }
            try store.dbQueue.write { db in
                try insert(scopedWindows: pending, db: db, encoder: encoder)
            }
            total += Int64(pending.count)
            pending.removeAll(keepingCapacity: true)
        }

        while true {
            let page = try loadSourcePage(store: store, after: key, limit: 8_000)
            guard !page.isEmpty else { break }
            for (chatID, message) in page {
                if activeChatID != chatID {
                    flushSession()
                    activeChatID = chatID
                } else if let previous = activeSession.last,
                          message.instant.timeIntervalSince(previous.instant) > maximumAdjacentGap {
                    flushSession()
                }
                activeSession.append(message)
                key = (chatID, message.date, message.rowid)
            }
            // Do not flush activeSession: the next page may continue the same
            // exchange. Persist everything that ended naturally in this page.
            try persistPending()
        }
        flushSession()
        try persistPending()

        let through = try store.lastIndexedROWID()
        try store.setState(.lastWindowedROWID, value: String(through))
        return total
    }

    /// Rebuild only chats touched by an incremental message-index update.
    static func rebuildChats(
        _ chatIDs: Set<Int64>,
        store: IndexStore,
        afterRowID: Int64,
        includeEmbeddings: Bool = true
    ) throws -> Int64 {
        let encoder = includeEmbeddings ? AppleWordSemanticEncoder() : nil
        var total: Int64 = 0
        for chatID in chatIDs.sorted() {
            total += try rebuildChatTail(
                chatID,
                afterRowID: afterRowID,
                store: store,
                encoder: encoder
            )
        }
        let through = try store.lastIndexedROWID()
        try store.setState(.lastWindowedROWID, value: String(through))
        return total
    }

    /// Fill a bounded number of nil vectors. Called by the existing utility-
    /// priority index sync loop, so semantic coverage improves incrementally
    /// without delaying first-launch lexical search.
    @discardableResult
    static func backfillEmbeddings(
        store: IndexStore,
        limit: Int = 96,
        encoder: any SemanticTextEncoding = AppleWordSemanticEncoder()
    ) throws -> Int {
        guard encoder.dimension > 0, limit > 0 else { return 0 }
        let rows: [(Int64, String)] = try store.dbQueue.read { db in
            let fetched = try Row.fetchAll(db, sql: """
                SELECT w.id AS id, f.body AS body
                FROM conversation_window w
                JOIN window_fts f ON f.rowid = w.id
                WHERE (w.embedding IS NULL AND w.embedding_dimensions >= 0)
                   OR (w.embedding IS NOT NULL AND w.embedding_hash IS NULL)
                ORDER BY w.id DESC
                LIMIT ?
            """, arguments: [limit])
            return fetched.compactMap { row in
                guard let id: Int64 = row["id"], let body: String = row["body"] else { return nil }
                return (id, body)
            }
        }
        var encoded: [(Int64, Data, Data)] = []
        var failedIDs: [Int64] = []
        for (id, body) in rows {
            let bounded = String(body.prefix(maximumIndexedWindowCharacters))
            if let vector = encoder.vector(for: bounded) {
                encoded.append((
                    id,
                    SemanticVectorCodec.encode(vector),
                    SemanticVectorCodec.binarySignature(vector)
                ))
            } else {
                failedIDs.append(id)
            }
        }
        try store.dbQueue.write { db in
            if !encoded.isEmpty {
                let statement = try db.makeStatement(sql: """
                    UPDATE conversation_window
                    SET embedding = ?, embedding_hash = ?, embedding_dimensions = ?
                    WHERE id = ?
                """)
                for (id, data, signature) in encoded {
                    try statement.execute(arguments: [data, signature, encoder.dimension, id])
                }
            }
            if !failedIDs.isEmpty {
                let failed = try db.makeStatement(sql: """
                    UPDATE conversation_window
                    SET embedding_dimensions = -1
                    WHERE id = ? AND embedding IS NULL
                """)
                for id in failedIDs { try failed.execute(arguments: [id]) }
            }
        }
        return rows.count
    }

    private static func rebuildChat(
        _ chatID: Int64,
        store: IndexStore,
        encoder: (any SemanticTextEncoding)?,
        deleteExisting: Bool
    ) throws -> Int64 {
        let messages: [SourceMessage] = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.rowid AS rowid, f.body AS body, m.date AS date,
                       m.is_from_me AS is_from_me, m.handle_id AS handle_id
                FROM message_meta m
                JOIN messages_fts f ON f.rowid = m.rowid
                WHERE m.chat_id = ? AND m.associated_message_type = 0
                ORDER BY m.date ASC, m.rowid ASC
            """, arguments: [chatID])
            return rows.compactMap { row in
                guard let rowid: Int64 = row["rowid"],
                      let date: Int64 = row["date"] else { return nil }
                return SourceMessage(
                    rowid: rowid,
                    body: (row["body"] as String?) ?? "",
                    date: date,
                    isFromMe: ((row["is_from_me"] as Int?) ?? 0) == 1,
                    handleID: row["handle_id"]
                )
            }
        }
        let windows = makeWindows(from: messages)
        try store.dbQueue.write { db in
            if deleteExisting {
                try db.execute(sql: """
                    DELETE FROM window_fts
                    WHERE rowid IN (SELECT id FROM conversation_window WHERE chat_id = ?)
                """, arguments: [chatID])
                try db.execute(sql: """
                    DELETE FROM window_member
                    WHERE window_id IN (SELECT id FROM conversation_window WHERE chat_id = ?)
                """, arguments: [chatID])
                try db.execute(sql: "DELETE FROM conversation_window WHERE chat_id = ?", arguments: [chatID])
            }

            let windowStatement = try db.makeStatement(sql: """
                INSERT INTO conversation_window(
                    chat_id, start_date, end_date, anchor_rowid, message_count,
                    has_from_me, has_from_other, embedding, embedding_hash,
                    embedding_dimensions
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            let ftsStatement = try db.makeStatement(
                sql: "INSERT INTO window_fts(rowid, body) VALUES(?, ?)"
            )
            let memberStatement = try db.makeStatement(sql: """
                INSERT INTO window_member(window_id, message_rowid, ordinal, is_from_me, handle_id)
                VALUES (?, ?, ?, ?, ?)
            """)
            for window in windows {
                let vector = encoder?.vector(for: window.body)
                let data = vector.map(SemanticVectorCodec.encode)
                try windowStatement.execute(arguments: [
                    chatID, window.startDate, window.endDate, window.anchorRowID,
                    window.members.count,
                    window.members.contains(where: \.isFromMe) ? 1 : 0,
                    window.members.contains(where: { !$0.isFromMe }) ? 1 : 0,
                    data, vector.map(SemanticVectorCodec.binarySignature),
                    vector?.count ?? 0,
                ])
                let windowID = db.lastInsertedRowID
                try ftsStatement.execute(arguments: [windowID, window.body])
                for (ordinal, member) in window.members.enumerated() {
                    try memberStatement.execute(arguments: [
                        windowID, member.rowid, ordinal,
                        member.isFromMe ? 1 : 0, member.handleID,
                    ])
                }
            }
        }
        return Int64(windows.count)
    }

    /// Rebuild only the suffix affected by newly appended rows. We prepend up
    /// to seven prior turns so an overlap/session that began before the sync
    /// boundary remains intact, delete only existing windows touching that
    /// suffix, then insert the replacement windows. Cost is proportional to
    /// new messages, not to the lifetime size of an active chat.
    private static func rebuildChatTail(
        _ chatID: Int64,
        afterRowID: Int64,
        store: IndexStore,
        encoder: (any SemanticTextEncoding)?
    ) throws -> Int64 {
        let newMessages = try loadSourceMessages(
            store: store,
            sql: """
                SELECT m.rowid AS rowid, f.body AS body, m.date AS date,
                       m.is_from_me AS is_from_me, m.handle_id AS handle_id
                FROM message_meta m
                JOIN messages_fts f ON f.rowid = m.rowid
                WHERE m.chat_id = ? AND m.associated_message_type = 0 AND m.rowid > ?
                ORDER BY m.date ASC, m.rowid ASC
            """,
            arguments: [chatID, afterRowID]
        )
        guard let firstNew = newMessages.first else { return 0 }
        var prefix = try loadSourceMessages(
            store: store,
            sql: """
                SELECT m.rowid AS rowid, f.body AS body, m.date AS date,
                       m.is_from_me AS is_from_me, m.handle_id AS handle_id
                FROM message_meta m
                JOIN messages_fts f ON f.rowid = m.rowid
                WHERE m.chat_id = ? AND m.associated_message_type = 0
                  AND (m.date < ? OR (m.date = ? AND m.rowid < ?))
                ORDER BY m.date DESC, m.rowid DESC
                LIMIT ?
            """,
            arguments: [
                chatID, firstNew.date, firstNew.date, firstNew.rowid,
                maximumMessages - 1,
            ]
        )
        prefix.reverse()
        let source = prefix + newMessages
        let windows = makeWindows(from: source)
        let prefixIDs = prefix.map(\.rowid)
        let prefixPlaceholders = Array(repeating: "?", count: prefixIDs.count).joined(separator: ",")
        let prefixClause = prefixIDs.isEmpty
            ? ""
            : " OR wm.message_rowid IN (\(prefixPlaceholders))"
        var affectedArguments: [DatabaseValueConvertible] = [chatID, afterRowID]
        affectedArguments.append(contentsOf: prefixIDs)

        try store.dbQueue.write { db in
            let affectedSubquery = """
                SELECT DISTINCT wm.window_id
                FROM window_member wm
                JOIN conversation_window cw ON cw.id = wm.window_id
                WHERE cw.chat_id = ?
                  AND (wm.message_rowid > ?\(prefixClause))
            """
            // Keep window_member until last so the same bounded subquery can
            // identify targets for both parent tables without constructing a
            // potentially huge SQLite placeholder list after a long offline
            // catch-up.
            try db.execute(
                sql: "DELETE FROM window_fts WHERE rowid IN (\(affectedSubquery))",
                arguments: StatementArguments(affectedArguments)
            )
            try db.execute(
                sql: "DELETE FROM conversation_window WHERE id IN (\(affectedSubquery))",
                arguments: StatementArguments(affectedArguments)
            )
            try db.execute(
                sql: "DELETE FROM window_member WHERE window_id NOT IN (SELECT id FROM conversation_window)"
            )
            try insert(windows: windows, chatID: chatID, db: db, encoder: encoder)
        }
        return Int64(windows.count)
    }

    private static func loadSourceMessages(
        store: IndexStore,
        sql: String,
        arguments: [DatabaseValueConvertible]
    ) throws -> [SourceMessage] {
        try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                guard let rowid: Int64 = row["rowid"],
                      let date: Int64 = row["date"] else { return nil }
                return SourceMessage(
                    rowid: rowid,
                    body: (row["body"] as String?) ?? "",
                    date: date,
                    isFromMe: ((row["is_from_me"] as Int?) ?? 0) == 1,
                    handleID: row["handle_id"]
                )
            }
        }
    }

    private struct ScopedWindow {
        let chatID: Int64
        let window: Window
    }

    private static func loadSourcePage(
        store: IndexStore,
        after key: (chatID: Int64, date: Int64, rowID: Int64)?,
        limit: Int
    ) throws -> [(Int64, SourceMessage)] {
        var arguments: [DatabaseValueConvertible] = []
        let boundary: String
        if let key {
            boundary = """
                AND (
                    m.chat_id > ?
                    OR (m.chat_id = ? AND m.date > ?)
                    OR (m.chat_id = ? AND m.date = ? AND m.rowid > ?)
                )
            """
            arguments.append(contentsOf: [
                key.chatID, key.chatID, key.date,
                key.chatID, key.date, key.rowID,
            ])
        } else {
            boundary = ""
        }
        arguments.append(limit)
        return try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.chat_id AS chat_id, m.rowid AS rowid, f.body AS body,
                       m.date AS date, m.is_from_me AS is_from_me,
                       m.handle_id AS handle_id
                FROM message_meta m
                JOIN messages_fts f ON f.rowid = m.rowid
                WHERE m.chat_id IS NOT NULL AND m.associated_message_type = 0
                  \(boundary)
                ORDER BY m.chat_id ASC, m.date ASC, m.rowid ASC
                LIMIT ?
            """, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                guard let chatID: Int64 = row["chat_id"],
                      let rowID: Int64 = row["rowid"],
                      let date: Int64 = row["date"] else { return nil }
                return (chatID, SourceMessage(
                    rowid: rowID,
                    body: (row["body"] as String?) ?? "",
                    date: date,
                    isFromMe: ((row["is_from_me"] as Int?) ?? 0) == 1,
                    handleID: row["handle_id"]
                ))
            }
        }
    }

    private static func insert(
        windows: [Window],
        chatID: Int64,
        db: Database,
        encoder: (any SemanticTextEncoding)?
    ) throws {
        try insert(
            scopedWindows: windows.map { ScopedWindow(chatID: chatID, window: $0) },
            db: db,
            encoder: encoder
        )
    }

    private static func insert(
        scopedWindows: [ScopedWindow],
        db: Database,
        encoder: (any SemanticTextEncoding)?
    ) throws {
        let windowStatement = try db.makeStatement(sql: """
            INSERT INTO conversation_window(
                chat_id, start_date, end_date, anchor_rowid, message_count,
                has_from_me, has_from_other, embedding, embedding_hash,
                embedding_dimensions
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        let ftsStatement = try db.makeStatement(
            sql: "INSERT INTO window_fts(rowid, body) VALUES(?, ?)"
        )
        let memberStatement = try db.makeStatement(sql: """
            INSERT INTO window_member(window_id, message_rowid, ordinal, is_from_me, handle_id)
            VALUES (?, ?, ?, ?, ?)
        """)
        for scoped in scopedWindows {
            let window = scoped.window
            let vector = encoder?.vector(for: window.body)
            try windowStatement.execute(arguments: [
                scoped.chatID, window.startDate, window.endDate, window.anchorRowID,
                window.members.count,
                window.members.contains(where: \.isFromMe) ? 1 : 0,
                window.members.contains(where: { !$0.isFromMe }) ? 1 : 0,
                vector.map(SemanticVectorCodec.encode),
                vector.map(SemanticVectorCodec.binarySignature),
                vector?.count ?? 0,
            ])
            let windowID = db.lastInsertedRowID
            try ftsStatement.execute(arguments: [windowID, window.body])
            for (ordinal, member) in window.members.enumerated() {
                try memberStatement.execute(arguments: [
                    windowID, member.rowid, ordinal,
                    member.isFromMe ? 1 : 0, member.handleID,
                ])
            }
        }
    }
}

// MARK: - Hybrid search

struct ConversationWindowSearchScope: Sendable, Equatable {
    let chatIDs: [Int64]?
    let dateRange: ClosedRange<Date>?
    /// nil means either direction; true means at least one sent-by-me member;
    /// false means at least one received member, optionally from handle IDs.
    let fromMe: Bool?
    let senderHandleIDs: [Int64]

    init(
        chatIDs: [Int64]? = nil,
        dateRange: ClosedRange<Date>? = nil,
        fromMe: Bool? = nil,
        senderHandleIDs: [Int64] = []
    ) {
        self.chatIDs = chatIDs
        self.dateRange = dateRange
        self.fromMe = fromMe
        self.senderHandleIDs = senderHandleIDs
    }
}

struct ConversationWindowHit: Sendable, Equatable {
    let windowID: Int64
    let chatID: Int64
    let anchorRowID: Int64
    let memberRowIDs: [Int64]
    let score: Double
}

struct ConversationWindowSearchReport: Sendable, Equatable {
    let hits: [ConversationWindowHit]
    let exactCandidateCount: Int
    let expandedCandidateCount: Int
    let denseCandidateCount: Int
    let expandedTerms: [String]
}

enum ConversationWindowIndex {
    private static let maximumSearchableWindowCharacters =
        ConversationWindowIndexer.maximumIndexedWindowCharacters

    private struct RankedID {
        let id: Int64
        let chatID: Int64
        let anchorRowID: Int64
        let similarity: Double
    }

    static func search(
        semanticQuery: String,
        scope: ConversationWindowSearchScope,
        store: IndexStore,
        limit: Int = 8,
        encoder: any SemanticTextEncoding = AppleWordSemanticEncoder()
    ) throws -> ConversationWindowSearchReport {
        SemanticIndexWorkload.noteInteractiveSearch()
        let exactTerms = AppleWordSemanticEncoder.contentTokens(in: semanticQuery)
            .filter { $0.count >= 3 }
        let expandedGroups = exactTerms.map { term in
            encoder.expandedTerms(for: term, neighborsPerTerm: 5).filter { $0.count >= 3 }
        }
        let expandedTerms = Array(Set(expandedGroups.flatMap { $0 })).sorted()

        let exact = try lexicalCandidates(
            terms: exactTerms,
            joinWithAND: true,
            scope: scope,
            store: store,
            limit: 100
        )
        let strongTarget = min(6, max(1, limit))
        var groupedExpansion: [RankedID] = []
        if Set(exact.map(\.id)).count < strongTarget {
            groupedExpansion = try lexicalCandidates(
                expression: groupedExpression(expandedGroups),
                scope: scope,
                store: store,
                limit: 140
            )
        }
        var expanded: [RankedID] = []
        if Set((exact + groupedExpansion).map(\.id)).count < strongTarget {
            expanded = try lexicalCandidates(
                terms: expandedTerms,
                joinWithAND: false,
                scope: scope,
                store: store,
                limit: 180
            )
        }
        let queryVector = encoder.vector(for: semanticQuery)
        let highConfidenceLexicalCount = Set(
            (exact + groupedExpansion).map(\.id)
        ).count
        // Dense recall earns its cost when exact/grouped evidence is sparse.
        // Once six strong windows exist, vectors mostly add weaker results
        // while needlessly increasing interactive latency.
        let shouldSearchDense = queryVector != nil
            && highConfidenceLexicalCount < strongTarget

        // Cache only a small, deliberately ordered set on the query path.
        // Encoding all 180 lexical candidates made a first search take many
        // seconds on a mature index. The utility backfill handles exhaustive
        // coverage; this bounded warm-up gives the current query useful dense
        // evidence without compromising interactive latency.
        if shouldSearchDense, let queryVector {
            var immediateIDs: [Int64] = []
            var seen = Set<Int64>()
            let prioritized = exact + groupedExpansion + expanded
            for candidate in prioritized where seen.insert(candidate.id).inserted {
                immediateIDs.append(candidate.id)
                if immediateIDs.count == 12 { break }
            }
            if !immediateIDs.isEmpty {
                _ = try encodeMissingWindows(ids: immediateIDs, store: store, encoder: encoder)
            }
            _ = queryVector // makes the bounded warm-up intent explicit
        }

        let dense = if shouldSearchDense, let queryVector {
            try denseCandidates(
                queryVector: queryVector,
                scope: scope,
                store: store,
                limit: 120
            )
        } else {
            [RankedID]()
        }

        // Reciprocal-rank fusion is robust across incomparable BM25 and cosine
        // scales. Exact lexical evidence remains strongest; dense meaning can
        // still retrieve a window with none of the literal query words.
        var fused: [Int64: (score: Double, chatID: Int64, anchor: Int64)] = [:]
        func add(_ candidates: [RankedID], weight: Double, similarityWeight: Double = 0) {
            for (rank, candidate) in candidates.enumerated() {
                var value = fused[candidate.id] ?? (0, candidate.chatID, candidate.anchorRowID)
                value.score += weight / Double(40 + rank)
                value.score += max(0, candidate.similarity) * similarityWeight
                fused[candidate.id] = value
            }
        }
        // Dense similarity is a recall source, not permission to displace a
        // window that satisfies the query's concept groups. Apple word-vector
        // averages are intentionally tiny and fast, but unrelated long text
        // can still have a deceptively high cosine score. Preserve dense-only
        // retrieval when lexical recall is empty while making exact/grouped
        // evidence authoritative whenever it exists.
        add(exact, weight: 5.0)
        add(groupedExpansion, weight: 4.0)
        add(expanded, weight: 1.0)
        add(dense, weight: 0.8, similarityWeight: 0.008)

        let selected = fused.sorted {
            if $0.value.score != $1.value.score { return $0.value.score > $1.value.score }
            return $0.key > $1.key
        }.prefix(max(1, limit))
        let memberMap = try members(for: selected.map(\.key), store: store)
        let hits = selected.map { id, value in
            ConversationWindowHit(
                windowID: id,
                chatID: value.chatID,
                anchorRowID: value.anchor,
                memberRowIDs: memberMap[id] ?? [value.anchor],
                score: value.score
            )
        }
        return ConversationWindowSearchReport(
            hits: hits,
            exactCandidateCount: exact.count,
            expandedCandidateCount: Set(
                (groupedExpansion + expanded).map(\.id)
            ).count,
            denseCandidateCount: dense.count,
            expandedTerms: expandedTerms
        )
    }

    private static func lexicalCandidates(
        terms: [String],
        joinWithAND: Bool,
        scope: ConversationWindowSearchScope,
        store: IndexStore,
        limit: Int
    ) throws -> [RankedID] {
        guard !terms.isEmpty else { return [] }
        let expression = terms.prefix(36)
            .map(FTSSearcher.quoteNeedleForFTS5)
            .joined(separator: joinWithAND ? " AND " : " OR ")
        return try lexicalCandidates(
            expression: expression,
            scope: scope,
            store: store,
            limit: limit
        )
    }

    private static func lexicalCandidates(
        expression: String?,
        scope: ConversationWindowSearchScope,
        store: IndexStore,
        limit: Int
    ) throws -> [RankedID] {
        guard let expression, !expression.isEmpty else { return [] }
        let (scopeSQL, scopeArgs) = scopeClause(scope, alias: "w")
        var args: [DatabaseValueConvertible] = [
            expression, maximumSearchableWindowCharacters,
        ]
        args.append(contentsOf: scopeArgs)
        args.append(limit)
        return try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.id AS id, w.chat_id AS chat_id,
                       w.anchor_rowid AS anchor_rowid, bm25(window_fts) AS rank
                FROM window_fts
                JOIN conversation_window w ON w.id = window_fts.rowid
                WHERE window_fts MATCH ?
                  AND length(window_fts.body) <= ?
                  \(scopeSQL)
                ORDER BY rank ASC
                LIMIT ?
            """, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let id: Int64 = row["id"],
                      let chatID: Int64 = row["chat_id"],
                      let anchor: Int64 = row["anchor_rowid"] else { return nil }
                return RankedID(id: id, chatID: chatID, anchorRowID: anchor, similarity: 0)
            }
        }
    }

    private static func groupedExpression(_ groups: [[String]]) -> String? {
        let nonempty = groups.compactMap { group -> String? in
            let expression = group.prefix(12)
                .map(FTSSearcher.quoteNeedleForFTS5)
                .joined(separator: " OR ")
            return expression.isEmpty ? nil : "(\(expression))"
        }
        guard !nonempty.isEmpty else { return nil }
        return nonempty.joined(separator: " AND ")
    }

    private static func denseCandidates(
        queryVector: [Float],
        scope: ConversationWindowSearchScope,
        store: IndexStore,
        limit: Int
    ) throws -> [RankedID] {
        let querySignature = SemanticVectorCodec.binarySignature(queryVector)
        let (scopeSQL, scopeArgs) = scopeClause(
            scope, alias: "w", includeSender: false
        )
        var senderJoin = ""
        var queryArgs: [DatabaseValueConvertible] = []
        if let fromMe = scope.fromMe {
            var conditions = ["is_from_me = ?"]
            queryArgs.append(fromMe ? 1 : 0)
            if !fromMe, !scope.senderHandleIDs.isEmpty {
                let placeholders = Array(
                    repeating: "?", count: scope.senderHandleIDs.count
                ).joined(separator: ",")
                conditions.append("handle_id IN (\(placeholders))")
                queryArgs.append(contentsOf: scope.senderHandleIDs)
            }
            // Use the selective sender index once rather than a correlated
            // window_member lookup for every embedded window.
            senderJoin = """
                JOIN (
                    SELECT DISTINCT window_id
                    FROM window_member
                    WHERE \(conditions.joined(separator: " AND "))
                ) sender_window ON sender_window.window_id = w.id
            """
        }
        queryArgs.append(contentsOf: scopeArgs)
        let shortlistLimit = max(360, limit * 6)
        var approximate: [RankedID] = []
        approximate.reserveCapacity(shortlistLimit + 1)
        try store.dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT w.id AS id, w.chat_id AS chat_id, w.anchor_rowid AS anchor_rowid,
                       w.embedding_hash AS embedding_hash
                FROM conversation_window w
                \(senderJoin)
                WHERE w.embedding_hash IS NOT NULL
                  \(scopeSQL)
            """, arguments: StatementArguments(queryArgs))
            while let row = try cursor.next() {
                guard let id: Int64 = row["id"],
                      let chatID: Int64 = row["chat_id"],
                      let anchor: Int64 = row["anchor_rowid"],
                      let signature: Data = row["embedding_hash"],
                      let distance = SemanticVectorCodec.hammingDistance(
                          querySignature, signature
                      ) else { continue }
                approximate.append(RankedID(
                    id: id,
                    chatID: chatID,
                    anchorRowID: anchor,
                    similarity: -Double(distance)
                ))
                if approximate.count > shortlistLimit * 2 {
                    approximate.sort { $0.similarity > $1.similarity }
                    approximate.removeLast(approximate.count - shortlistLimit)
                }
            }
        }
        approximate.sort { $0.similarity > $1.similarity }
        approximate = Array(approximate.prefix(shortlistLimit))
        guard !approximate.isEmpty else { return [] }

        let metadata = Dictionary(uniqueKeysWithValues: approximate.map { ($0.id, $0) })
        let ids = approximate.map(\.id)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var best: [RankedID] = try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, embedding, embedding_dimensions
                FROM conversation_window
                WHERE id IN (\(placeholders)) AND embedding IS NOT NULL
            """, arguments: StatementArguments(ids))
            return rows.compactMap { row in
                guard let id: Int64 = row["id"],
                      let candidate = metadata[id],
                      let data: Data = row["embedding"],
                      let dimensions: Int = row["embedding_dimensions"],
                      let vector = SemanticVectorCodec.decode(data, dimensions: dimensions),
                      vector.count == queryVector.count else { return nil }
                return RankedID(
                    id: id,
                    chatID: candidate.chatID,
                    anchorRowID: candidate.anchorRowID,
                    similarity: AppleWordSemanticEncoder.similarity(queryVector, vector)
                )
            }
        }
        best.sort { $0.similarity > $1.similarity }
        return Array(best.prefix(limit))
    }

    private static func encodeMissingWindows(
        ids: [Int64],
        store: IndexStore,
        encoder: any SemanticTextEncoding
    ) throws -> [Int64: [Float]] {
        guard encoder.dimension > 0, !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows: [(Int64, String)] = try store.dbQueue.read { db in
            var args: [DatabaseValueConvertible] = ids
            args.append(maximumSearchableWindowCharacters)
            let fetched = try Row.fetchAll(db, sql: """
                SELECT w.id AS id, f.body AS body
                FROM conversation_window w
                JOIN window_fts f ON f.rowid = w.id
                WHERE w.id IN (\(placeholders))
                  AND (w.embedding IS NULL OR w.embedding_hash IS NULL)
                  AND length(f.body) <= ?
            """, arguments: StatementArguments(args))
            return fetched.compactMap { row in
                guard let id: Int64 = row["id"], let body: String = row["body"] else { return nil }
                return (id, body)
            }
        }
        var vectors: [Int64: [Float]] = [:]
        for (id, body) in rows {
            if let vector = encoder.vector(for: body) { vectors[id] = vector }
        }
        if !vectors.isEmpty {
            try store.dbQueue.write { db in
                let statement = try db.makeStatement(sql: """
                    UPDATE conversation_window
                    SET embedding = ?, embedding_hash = ?, embedding_dimensions = ?
                    WHERE id = ?
                """)
                for (id, vector) in vectors {
                    try statement.execute(arguments: [
                        SemanticVectorCodec.encode(vector),
                        SemanticVectorCodec.binarySignature(vector),
                        vector.count, id,
                    ])
                }
            }
        }
        return vectors
    }

    private static func members(
        for windowIDs: [Int64],
        store: IndexStore
    ) throws -> [Int64: [Int64]] {
        guard !windowIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: windowIDs.count).joined(separator: ",")
        return try store.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT window_id, message_rowid
                FROM window_member
                WHERE window_id IN (\(placeholders))
                ORDER BY window_id, ordinal
            """, arguments: StatementArguments(windowIDs))
            var output: [Int64: [Int64]] = [:]
            for row in rows {
                guard let windowID: Int64 = row["window_id"],
                      let messageID: Int64 = row["message_rowid"] else { continue }
                output[windowID, default: []].append(messageID)
            }
            return output
        }
    }

    private static func scopeClause(
        _ scope: ConversationWindowSearchScope,
        alias: String,
        includeSender: Bool = true
    ) -> (String, [DatabaseValueConvertible]) {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []

        if let chatIDs = scope.chatIDs {
            guard !chatIDs.isEmpty else { return ("AND 0", []) }
            let placeholders = Array(repeating: "?", count: chatIDs.count).joined(separator: ",")
            clauses.append("\(alias).chat_id IN (\(placeholders))")
            args.append(contentsOf: chatIDs)
        }
        if let range = scope.dateRange {
            let lowerNS = MessageDate.nanosecondsSinceMacEpoch(from: range.lowerBound)
            let upperNS = MessageDate.nanosecondsSinceMacEpoch(from: range.upperBound)
            let lowerS = MessageDate.secondsSinceMacEpoch(from: range.lowerBound)
            let upperS = MessageDate.secondsSinceMacEpoch(from: range.upperBound)
            clauses.append("""
                ((\(alias).end_date > 1000000000000
                    AND \(alias).end_date >= ? AND \(alias).start_date <= ?)
                 OR (\(alias).end_date <= 1000000000000
                    AND \(alias).end_date >= ? AND \(alias).start_date <= ?))
            """)
            args.append(lowerNS)
            args.append(upperNS)
            args.append(lowerS)
            args.append(upperS)
        }
        if includeSender, let fromMe = scope.fromMe {
            if fromMe {
                clauses.append("EXISTS (SELECT 1 FROM window_member wm WHERE wm.window_id = \(alias).id AND wm.is_from_me = 1)")
            } else if scope.senderHandleIDs.isEmpty {
                clauses.append("EXISTS (SELECT 1 FROM window_member wm WHERE wm.window_id = \(alias).id AND wm.is_from_me = 0)")
            } else {
                let placeholders = Array(repeating: "?", count: scope.senderHandleIDs.count).joined(separator: ",")
                clauses.append("""
                    EXISTS (SELECT 1 FROM window_member wm
                            WHERE wm.window_id = \(alias).id AND wm.is_from_me = 0
                              AND wm.handle_id IN (\(placeholders)))
                """)
                args.append(contentsOf: scope.senderHandleIDs)
            }
        }
        let sql = clauses.map { "AND \($0)" }.joined(separator: "\n")
        return (sql, args)
    }
}
