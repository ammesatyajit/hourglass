import Foundation
import GRDB
import XCTest
@testable import Hourglass

final class ConversationWindowRetrievalTests: XCTestCase {
    private struct TestEncoder: SemanticTextEncoding {
        let dimension = 3

        func vector(for text: String) -> [Float]? {
            let words = Set(AppleWordSemanticEncoder.contentTokens(in: text))
            if !words.isDisjoint(with: ["joke", "jokes", "funny", "hilarious", "laugh", "punchline"]) {
                return [1, 0, 0]
            }
            if !words.isDisjoint(with: ["vacation", "trip", "travel", "flights", "hotel", "beach"]) {
                return [0, 1, 0]
            }
            if !words.isDisjoint(with: ["argument", "conflict", "angry", "upset", "disagree"]) {
                return [0, 0, 1]
            }
            return [0.57735, 0.57735, 0.57735]
        }

        func expandedTerms(for text: String, neighborsPerTerm: Int) -> [String] {
            let words = AppleWordSemanticEncoder.contentTokens(in: text)
            if words.contains("jokes") || words.contains("joke") {
                return ["jokes", "funny", "hilarious", "laugh", "punchline"]
            }
            if words.contains("vacation") {
                return ["vacation", "trip", "travel"]
            }
            if words.contains("planning") {
                return ["planning", "preparing"]
            }
            return words
        }
    }

    private func tempStore() throws -> (IndexStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Hourglass-window-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "index.sqlite")
        return (try IndexStore(url: url), directory)
    }

    private func insertSourceMessage(
        store: IndexStore,
        rowID: Int64,
        chatID: Int64,
        body: String,
        minuteOffset: Int,
        isFromMe: Bool,
        handleID: Int64?
    ) throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(minuteOffset * 60))
        try store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO messages_fts(rowid, body) VALUES (?, ?)",
                arguments: [rowID, body]
            )
            try db.execute(sql: """
                INSERT INTO message_meta(
                    rowid, guid, date, is_from_me, chat_id, handle_id,
                    associated_message_type, has_attachment, balloon_bundle_id
                ) VALUES (?, ?, ?, ?, ?, ?, 0, 0, NULL)
            """, arguments: [
                rowID, "message-\(rowID)",
                MessageDate.nanosecondsSinceMacEpoch(from: date),
                isFromMe ? 1 : 0, chatID, handleID,
            ])
        }
    }

    @discardableResult
    private func insertWindow(
        store: IndexStore,
        chatID: Int64,
        body: String,
        memberIDs: [Int64],
        fromMe: [Bool],
        handleIDs: [Int64?],
        dayOffset: Int = 0
    ) throws -> Int64 {
        let encoder = TestEncoder()
        let vector = try XCTUnwrap(encoder.vector(for: body))
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(dayOffset) * 86_400)
        let raw = MessageDate.nanosecondsSinceMacEpoch(from: start)
        return try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO conversation_window(
                    chat_id, start_date, end_date, anchor_rowid, message_count,
                    has_from_me, has_from_other, embedding, embedding_hash,
                    embedding_dimensions
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                chatID, raw, raw, memberIDs[memberIDs.count / 2], memberIDs.count,
                fromMe.contains(true) ? 1 : 0,
                fromMe.contains(false) ? 1 : 0,
                SemanticVectorCodec.encode(vector),
                SemanticVectorCodec.binarySignature(vector), vector.count,
            ])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO window_fts(rowid, body) VALUES(?, ?)", arguments: [id, body])
            for index in memberIDs.indices {
                try db.execute(sql: """
                    INSERT INTO window_member(window_id, message_rowid, ordinal, is_from_me, handle_id)
                    VALUES (?, ?, ?, ?, ?)
                """, arguments: [id, memberIDs[index], index, fromMe[index] ? 1 : 0, handleIDs[index]])
            }
            return id
        }
    }

    func testWindowingOverlapsAndNeverCrossesSessionGap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (0..<11).map { index in
            let offset: TimeInterval = index < 9 ? Double(index * 60) : Double(4_000 + index * 60)
            return ConversationWindowIndexer.SourceMessage(
                rowid: Int64(index + 1),
                body: "turn \(index)",
                date: MessageDate.nanosecondsSinceMacEpoch(from: start.addingTimeInterval(offset)),
                isFromMe: index.isMultiple(of: 2),
                handleID: index.isMultiple(of: 2) ? nil : 10
            )
        }
        let windows = ConversationWindowIndexer.makeWindows(from: messages)
        XCTAssertEqual(windows.map { $0.members.map(\.rowid) }, [
            [1, 2, 3, 4, 5, 6, 7, 8],
            [5, 6, 7, 8, 9],
            [10, 11],
        ])
        XCTAssertTrue(windows.allSatisfy { $0.members.count <= 8 })
    }

    func testFloat16CodecKeepsNormalizedVectorAccurate() throws {
        let original: [Float] = [0.12, -0.44, 0.88]
        let decoded = try XCTUnwrap(SemanticVectorCodec.decode(
            SemanticVectorCodec.encode(original),
            dimensions: original.count
        ))
        XCTAssertEqual(decoded.count, original.count)
        for index in original.indices {
            XCTAssertEqual(decoded[index], original[index], accuracy: 0.001)
        }
    }

    func testBinarySignatureRanksNearbyVectorsByHammingDistance() throws {
        let query: [Float] = [0.8, 0.2, -0.7, -0.1, 0.5, -0.4, 0.3, -0.9]
        let nearby: [Float] = [0.7, 0.1, -0.6, -0.2, 0.4, -0.3, 0.2, -0.8]
        let distant: [Float] = [-0.7, -0.1, 0.6, 0.2, -0.4, 0.3, -0.2, 0.8]
        let signature = SemanticVectorCodec.binarySignature(query)
        let nearDistance = try XCTUnwrap(SemanticVectorCodec.hammingDistance(
            signature, SemanticVectorCodec.binarySignature(nearby)
        ))
        let farDistance = try XCTUnwrap(SemanticVectorCodec.hammingDistance(
            signature, SemanticVectorCodec.binarySignature(distant)
        ))
        XCTAssertLessThan(nearDistance, farDistance)
    }

    func testSemanticNeighborsRetrieveMeaningWithoutLiteralQueryWord() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let funnyID = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: the punchline was hilarious\nMe: I cannot stop laughing",
            memberIDs: [11, 12],
            fromMe: [false, true],
            handleIDs: [10, nil]
        )
        _ = try insertWindow(
            store: store,
            chatID: 2,
            body: "Them: quarterly budget spreadsheet\nMe: looks correct",
            memberIDs: [21, 22],
            fromMe: [false, true],
            handleIDs: [20, nil]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "jokes",
            scope: ConversationWindowSearchScope(),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.first?.windowID, funnyID)
        XCTAssertGreaterThan(report.expandedCandidateCount, 0)
        XCTAssertTrue(report.expandedTerms.contains("hilarious"))
    }

    func testDenseRetrievalWorksWithNoSharedOrExpandedWords() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let travelID = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: flights are booked\nMe: I reserved the hotel too",
            memberIDs: [31, 32],
            fromMe: [false, true],
            handleIDs: [10, nil]
        )
        _ = try insertWindow(
            store: store,
            chatID: 2,
            body: "Them: quarterly budget spreadsheet",
            memberIDs: [41],
            fromMe: [false],
            handleIDs: [20]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "vacation",
            scope: ConversationWindowSearchScope(),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.first?.windowID, travelID)
        XCTAssertEqual(report.exactCandidateCount, 0)
        XCTAssertEqual(report.expandedCandidateCount, 0)
        XCTAssertGreaterThan(report.denseCandidateCount, 0)
    }

    func testMultiConceptLexicalEvidenceOutranksDenseOnlyDistractor() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relevantID = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: we are preparing for the trip\nMe: I will book everything tonight",
            memberIDs: [33, 34],
            fromMe: [false, true],
            handleIDs: [10, nil]
        )
        _ = try insertWindow(
            store: store,
            chatID: 2,
            body: "Them: flights and hotel",
            memberIDs: [35],
            fromMe: [false],
            handleIDs: [20]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "vacation planning",
            scope: ConversationWindowSearchScope(),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.first?.windowID, relevantID)
        XCTAssertGreaterThan(report.expandedCandidateCount, 0)
        XCTAssertGreaterThan(report.denseCandidateCount, 0)
    }

    func testHugePastedDocumentCannotKeywordStuffConversationResults() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insertWindow(
            store: store,
            chatID: 1,
            body: "vacation planning " + String(repeating: "boilerplate ", count: 2_000),
            memberIDs: [36],
            fromMe: [false],
            handleIDs: [10]
        )
        let exchangeID = try insertWindow(
            store: store,
            chatID: 2,
            body: "Them: we are preparing for the trip\nMe: let's choose flights tonight",
            memberIDs: [37, 38],
            fromMe: [false, true],
            handleIDs: [20, nil]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "vacation planning",
            scope: ConversationWindowSearchScope(),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.first?.windowID, exchangeID)
    }

    func testSenderAndChatFiltersCannotLeakDistractorWindows() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: hilarious punchline",
            memberIDs: [51],
            fromMe: [false],
            handleIDs: [10]
        )
        let allowedID = try insertWindow(
            store: store,
            chatID: 2,
            body: "Them: funny story",
            memberIDs: [61],
            fromMe: [false],
            handleIDs: [20]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "jokes",
            scope: ConversationWindowSearchScope(
                chatIDs: [2],
                fromMe: false,
                senderHandleIDs: [20]
            ),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.map(\.windowID), [allowedID])
    }

    func testSenderSemanticEvidenceComesFromRequestedSender() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try insertSourceMessage(
            store: store, rowID: 71, chatID: 1, body: "ordinary status update",
            minuteOffset: 0, isFromMe: false, handleID: 10
        )
        try insertSourceMessage(
            store: store, rowID: 72, chatID: 1, body: "that punchline was hilarious",
            minuteOffset: 1, isFromMe: false, handleID: 20
        )
        let otherPersonJoke = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: ordinary status update\nThem: that punchline was hilarious",
            memberIDs: [71, 72],
            fromMe: [false, false],
            handleIDs: [10, 20]
        )

        try insertSourceMessage(
            store: store, rowID: 73, chatID: 1, body: "my funny joke has a punchline",
            minuteOffset: 2, isFromMe: false, handleID: 10
        )
        let requestedSenderJoke = try insertWindow(
            store: store,
            chatID: 1,
            body: "Them: my funny joke has a punchline",
            memberIDs: [73],
            fromMe: [false],
            handleIDs: [10]
        )

        let report = try ConversationWindowIndex.search(
            semanticQuery: "jokes",
            scope: ConversationWindowSearchScope(
                chatIDs: [1],
                fromMe: false,
                senderHandleIDs: [10]
            ),
            store: store,
            encoder: TestEncoder()
        )
        XCTAssertEqual(report.hits.first?.windowID, requestedSenderJoke)
        XCTAssertTrue(report.hits.contains(where: { $0.windowID == otherPersonJoke }))
    }

    func testAppleEncoderProvidesUsefulGeneralJokeNeighbors() throws {
        let encoder = AppleWordSemanticEncoder()
        guard encoder.dimension > 0 else { throw XCTSkip("Apple English word embedding unavailable") }
        let expanded = Set(encoder.expandedTerms(for: "joke", neighborsPerTerm: 8))
        XCTAssertFalse(expanded.isDisjoint(with: ["laugh", "funny", "hilarious", "joking", "chuckle"]))
        XCTAssertNotNil(encoder.vector(for: "funny story that made everyone laugh"))
    }

    func testFullFixtureBuildCreatesReadyConversationWindows() throws {
        let bundle = Bundle(for: type(of: self))
        guard let chatURL = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("fixture chat.db not bundled")
        }
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatURL, store: store)
        XCTAssertTrue(try store.conversationWindowsAreReady())
        XCTAssertGreaterThan(try store.conversationWindowCount(), 0)
        XCTAssertEqual(try store.lastWindowedROWID(), try store.lastIndexedROWID())
    }

    func testIncrementalTailRebuildPreservesEveryAffectedChat() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<4 {
            try insertSourceMessage(
                store: store,
                rowID: Int64(index + 1),
                chatID: 1,
                body: "alpha turn \(index)",
                minuteOffset: index,
                isFromMe: index.isMultiple(of: 2),
                handleID: index.isMultiple(of: 2) ? nil : 101
            )
            try insertSourceMessage(
                store: store,
                rowID: Int64(index + 10),
                chatID: 2,
                body: "beta turn \(index)",
                minuteOffset: index + 10,
                isFromMe: index.isMultiple(of: 2),
                handleID: index.isMultiple(of: 2) ? nil : 202
            )
        }
        try store.setState(.lastIndexedROWID, value: "13")
        _ = try ConversationWindowIndexer.rebuildAll(store: store)

        try insertSourceMessage(
            store: store,
            rowID: 20,
            chatID: 1,
            body: "new alpha turn",
            minuteOffset: 4,
            isFromMe: true,
            handleID: nil
        )
        try insertSourceMessage(
            store: store,
            rowID: 21,
            chatID: 2,
            body: "new beta turn",
            minuteOffset: 14,
            isFromMe: false,
            handleID: 202
        )
        try store.setState(.lastIndexedROWID, value: "21")
        _ = try ConversationWindowIndexer.rebuildChats(
            [1, 2],
            store: store,
            afterRowID: 13,
            includeEmbeddings: false
        )

        let chatIDsContainingNewRows: [Int64] = try store.dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT cw.chat_id
                FROM conversation_window cw
                JOIN window_member wm ON wm.window_id = cw.id
                WHERE wm.message_rowid IN (20, 21)
                ORDER BY cw.chat_id
            """)
        }
        XCTAssertEqual(chatIDsContainingNewRows, [1, 2])
        XCTAssertEqual(try store.lastWindowedROWID(), 21)

        let orphanCount: Int = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM window_member wm
                LEFT JOIN conversation_window cw ON cw.id = wm.window_id
                WHERE cw.id IS NULL
            """) ?? -1
        }
        XCTAssertEqual(orphanCount, 0)
    }
}
