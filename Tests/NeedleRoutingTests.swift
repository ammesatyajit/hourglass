import XCTest
import os
@testable import Hourglass

final class NeedleRoutingTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-08-14T21:30:00Z")!
    private let contacts = ["Howard Rosen", "Annika Knechtel", "Beck Peterson", "Mom", "Vedant"]

    private struct HostileNeedleRuntime: NeedleRoutingRuntime {
        let modelLabel = "hostile-test-needle"
        var isReady: Bool { get async { true } }

        func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
            "{}"
        }

        func route(userQuery: String, now: Date) async throws -> NeedleRoutingResult {
            NeedleRoutingResult(
                call: NLToolCall(tool: "top_groups", args: ["limit": .int(99), "in": .string("question")]),
                callCount: 1,
                reasoning: nil,
                confidence: 0.99,
                rawJSON: "{}"
            )
        }
    }

    private final class RecordingTools: @unchecked Sendable, NLAgentTools {
        struct State: Sendable {
            var query: String?
            var range: ClosedRange<Date>?
            var limit: Int?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        let names: [String]

        init(names: [String]) { self.names = names }

        var lastQuery: String? { state.withLock { $0.query } }
        var lastRange: ClosedRange<Date>? { state.withLock { $0.range } }
        var lastLimit: Int? { state.withLock { $0.limit } }

        func availableContactNames() async -> [String] { names }

        func search(
            query: String,
            dateRange: ClosedRange<Date>?,
            limit: Int?,
            order: MessageSearch.SortOrder
        ) async throws -> [MessageSearch.Result] {
            state.withLock {
                $0.query = query
                $0.range = dateRange
                $0.limit = limit
            }
            return []
        }

        func oldestMatching(query: String) async throws -> MessageSearch.Result? { nil }
        func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
    }

    private final class HybridTools: @unchecked Sendable, NLAgentTools {
        private let state = OSAllocatedUnfairLock(initialState: (hybrid: 0, literal: 0))
        var hybridCalls: Int { state.withLock { $0.hybrid } }
        var literalCalls: Int { state.withLock { $0.literal } }

        func availableContactNames() async -> [String] { ["Howard Rosen"] }

        func hybridSearch(
            _ request: HybridMessageRetrievalRequest
        ) async throws -> HybridMessageRetrievalOutcome? {
            state.withLock { $0.hybrid += 1 }
            XCTAssertEqual(request.semanticQuery, "jokes")
            XCTAssertEqual(request.fromSender, "Howard Rosen")
            let message = Message(
                id: 700,
                guid: "hybrid-joke",
                date: Date(timeIntervalSince1970: 100),
                isFromMe: false,
                chatRowID: 9,
                senderHandle: "+15555550100",
                chatStyle: 45,
                chatDisplayName: nil,
                body: "That punchline was hilarious",
                associatedMessageType: 0
            )
            let result = MessageSearch.Result(
                message: message,
                partnerName: "Howard Rosen",
                senderName: "Howard Rosen"
            )
            return HybridMessageRetrievalOutcome(
                candidates: [result],
                windowCount: 1,
                exactCandidateCount: 0,
                expandedCandidateCount: 1,
                denseCandidateCount: 1
            )
        }

        func search(
            query: String,
            dateRange: ClosedRange<Date>?,
            limit: Int?,
            order: MessageSearch.SortOrder
        ) async throws -> [MessageSearch.Result] {
            state.withLock { $0.literal += 1 }
            return []
        }

        func oldestMatching(query: String) async throws -> MessageSearch.Result? { nil }
        func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
    }

    private final class ConflictTools: @unchecked Sendable, NLAgentTools {
        struct State: Sendable {
            var queries: [String] = []
            var requestedChatIDs: [[Int64]] = []
            var searchHadDateRange = false
            var directReadHadDateRange = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        var queries: [String] { state.withLock { $0.queries } }
        var requestedChatIDs: [[Int64]] { state.withLock { $0.requestedChatIDs } }
        var searchHadDateRange: Bool { state.withLock { $0.searchHadDateRange } }
        var directReadHadDateRange: Bool { state.withLock { $0.directReadHadDateRange } }

        func availableContactNames() async -> [String] { ["Annika Knechtel"] }

        func search(
            query: String,
            dateRange: ClosedRange<Date>?,
            limit: Int?,
            order: MessageSearch.SortOrder
        ) async throws -> [MessageSearch.Result] {
            state.withLock {
                $0.queries.append(query)
                $0.searchHadDateRange = dateRange != nil
            }
            // The relevant message never says "argument". It is recalled by
            // a conflict phrase; the group row proves authoritative chat-ID
            // filtering happens after broad lexical recall.
            return [
                Self.result(
                    id: 1,
                    guid: "implicit-conflict",
                    chatID: 42,
                    seconds: 20,
                    body: "I can't believe you forgot AGAIN. This is not okay."
                ),
                Self.result(
                    id: 2,
                    guid: "group-distractor",
                    chatID: 99,
                    seconds: 30,
                    body: "That argument in the debate club was interesting."
                ),
            ]
        }

        func oldestMatching(query: String) async throws -> MessageSearch.Result? { nil }

        func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result] {
            guard guid == "implicit-conflict" else { return [] }
            return [Self.result(
                id: 3,
                guid: "context",
                chatID: 42,
                seconds: 21,
                body: "I told you this really mattered to me.",
                isFromMe: true
            )]
        }

        func resolveScopedPersonChat(named phrase: String) async throws -> ScopedPersonChat? {
            ScopedPersonChat(resolvedName: "Annika Knechtel", chatRowIDs: [42], isOneToOne: true)
        }

        func readMessagesInChats(
            rowIDs: [Int64],
            in dateRange: ClosedRange<Date>?,
            limit: Int
        ) async throws -> [MessageSearch.Result] {
            state.withLock {
                $0.requestedChatIDs.append(rowIDs)
                $0.directReadHadDateRange = dateRange != nil
            }
            return [
                Self.result(
                    id: 1,
                    guid: "implicit-conflict",
                    chatID: 42,
                    seconds: 20,
                    body: "I can't believe you forgot AGAIN. This is not okay."
                ),
                Self.result(
                    id: 4,
                    guid: "ordinary",
                    chatID: 42,
                    seconds: 40,
                    body: "Could you grab milk on the way home?"
                ),
            ]
        }

        private static func result(
            id: Int64,
            guid: String,
            chatID: Int64,
            seconds: TimeInterval,
            body: String,
            isFromMe: Bool = false
        ) -> MessageSearch.Result {
            MessageSearch.Result(
                message: Message(
                    id: id,
                    guid: guid,
                    date: Date(timeIntervalSince1970: seconds),
                    isFromMe: isFromMe,
                    chatRowID: chatID,
                    senderHandle: "+15555550123",
                    chatStyle: chatID == 42 ? 45 : 43,
                    chatDisplayName: chatID == 42 ? nil : "Debate Club",
                    body: body,
                    associatedMessageType: 0
                ),
                partnerName: chatID == 42 ? "Annika Knechtel" : "Debate Club",
                senderName: isFromMe ? "You" : "Annika Knechtel"
            )
        }
    }

    func testToolCatalogIsGrammarConstrainedAndExcludesSQL() throws {
        let data = try XCTUnwrap(NeedleToolCatalog.json.data(using: .utf8))
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(tools.count, 10)
        XCTAssertFalse(tools.contains { ($0["name"] as? String) == "rawSearchSQL" })

        let count = try XCTUnwrap(tools.first { ($0["name"] as? String) == "count_messages" })
        let parameters = try XCTUnwrap(count["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let media = try XCTUnwrap(properties["type"] as? [String: Any])
        XCTAssertEqual(media["enum"] as? [String], ["image", "video", "audio", "sticker", "link", "file"])

        let search = try XCTUnwrap(tools.first { ($0["name"] as? String) == "search_messages" })
        let searchParameters = try XCTUnwrap(search["parameters"] as? [String: Any])
        let searchProperties = try XCTUnwrap(searchParameters["properties"] as? [String: Any])
        let date = try XCTUnwrap(searchProperties["in"] as? [String: Any])
        let datePattern = try XCTUnwrap(date["pattern"] as? String)
        XCTAssertNil("question".range(of: datePattern, options: .regularExpression))
        XCTAssertNotNil("2026-05-01..2026-06-15".range(of: datePattern, options: .regularExpression))
    }

    func testExplicitCountRepairsWrongNeedleToolAndBuildsTypedFilters() {
        let badModel = NeedleRoutingResult(
            call: NLToolCall(tool: "search_messages", args: ["chat": .string("voice")]),
            callCount: 1,
            reasoning: nil,
            confidence: 0.9,
            rawJSON: "{}"
        )
        let decision = NeedleCallValidator.validate(
            model: badModel,
            query: "how many voice messages have I sent",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "count_messages")
        XCTAssertEqual(decision.call.args["from"], .string("me"))
        XCTAssertEqual(decision.call.args["type"], .string("audio"))
        XCTAssertNil(decision.call.args["chat"])
        XCTAssertTrue(decision.repaired)
    }

    func testPhotoSearchExtractsSenderMediaAndCalendarWindow() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "show me photos Howard sent last week",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "search_messages")
        XCTAssertEqual(decision.call.args["from"], .string("Howard Rosen"))
        XCTAssertEqual(decision.call.args["type"], .string("image"))
        XCTAssertEqual(decision.call.args["in"], .string("last_week"))
        XCTAssertNil(decision.call.args["query"])
    }

    func testSentLinkSearchKeepsConversationAndDirectionSeparate() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "find links I sent Annika this month",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.args["with"], .string("Annika Knechtel"))
        XCTAssertEqual(decision.call.args["from"], .string("me"))
        XCTAssertEqual(decision.call.args["type"], .string("link"))
        XCTAssertEqual(decision.call.args["in"], .string("this_month"))
    }

    func testExplicitNamedDateRangeDoesNotLeakIntoBodySearch() {
        let badModel = NeedleRoutingResult(
            call: NLToolCall(tool: "search_messages", args: [
                "query": .string("Annika"),
                "from": .string("May 1"),
                "chat": .string("May 1"),
                "type": .string("link"),
                "reaction": .string("like"),
                "in": .string("question"),
            ]),
            callCount: 1,
            reasoning: nil,
            confidence: 0,
            rawJSON: "{}"
        )
        let decision = NeedleCallValidator.validate(
            model: badModel,
            query: "messages with Annika between May 1 and June 15, 2026",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "search_messages")
        XCTAssertEqual(decision.call.args["with"], .string("Annika Knechtel"))
        XCTAssertEqual(decision.call.args["in"], .string("2026-05-01..2026-06-15"))
        XCTAssertNil(decision.call.args["query"])
        XCTAssertNil(decision.call.args["from"])
        XCTAssertNil(decision.call.args["chat"])
        XCTAssertNil(decision.call.args["type"])
        XCTAssertNil(decision.call.args["reaction"])
        XCTAssertTrue(decision.repaired)
    }

    func testISODateRangeKeepsRealTopicOnly() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "project updates with Annika from 2026-05-01 to 2026-06-15",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.args["in"], .string("2026-05-01..2026-06-15"))
        XCTAssertEqual(decision.call.args["query"], .string("project updates"))
    }

    func testArbitraryRollingWindowEmitsExecutableConcreteRange() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Howard over the past 10 days",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.args["in"], .string("2026-08-04..2026-08-14"))
        XCTAssertNotNil(NLAgent.resolveDateArg(decision.call.args, now: now))
        XCTAssertNil(decision.call.args["query"])
    }

    func testNamedMonthAndSinceDateUseCalendarRanges() {
        let may = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Howard in May",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(may.call.args["in"], .string("2026-05-01..2026-05-31"))

        let since = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Howard since December 1",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(since.call.args["in"], .string("2025-12-01..2026-08-14"))
    }

    func testTopicWordsDoNotBecomeMediaOrReactionFilters() {
        let linkedIn = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Annika about LinkedIn",
            contactNames: contacts,
            now: now
        )
        XCTAssertNil(linkedIn.call.args["type"])
        XCTAssertEqual(linkedIn.call.args["query"], .string("LinkedIn"))

        let ordinaryLiked = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Annika where she said she liked surfing",
            contactNames: contacts,
            now: now
        )
        XCTAssertNil(ordinaryLiked.call.args["reaction"])

        let videoGames = NeedleCallValidator.validate(
            model: nil,
            query: "find video games Howard mentioned",
            contactNames: contacts,
            now: now
        )
        XCTAssertNil(videoGames.call.args["type"])
    }

    func testExplicitTapbackStillBecomesReactionFilter() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "messages with Annika that she reacted to with a thumbs up",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.args["reaction"], .string("like"))
        XCTAssertNil(decision.call.args["query"])
    }

    func testTopicAndPersonSearchRejectsNeedleRankingTool() {
        let badModel = NeedleRoutingResult(
            call: NLToolCall(tool: "top_groups", args: ["limit": .int(5)]),
            callCount: 1,
            reasoning: nil,
            confidence: 0.9,
            rawJSON: "{}"
        )
        let decision = NeedleCallValidator.validate(
            model: badModel,
            query: "surf plans with Vedant",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.modelTool, "top_groups")
        XCTAssertEqual(decision.call.tool, "search_messages")
        XCTAssertEqual(decision.call.args["with"], .string("Vedant"))
        XCTAssertEqual(decision.call.args["query"], .string("surf plans"))
        XCTAssertEqual(decision.call.args["limit"], .int(50))
        XCTAssertTrue(decision.repaired)
    }

    func testReadConversationUsesPersonAndCenteredRelativeWindow() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "what were Annika and I talking about around two weeks ago",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "read_conversation")
        XCTAssertEqual(decision.call.args["with"], .string("Annika Knechtel"))
        let range = decision.call.args["in"]?.asString
        XCTAssertNotNil(range)
        XCTAssertTrue(range?.contains("..") == true)
    }

    func testStatsToolsAreSelectedDeterministically() {
        let cases: [(String, String)] = [
            ("who do I text the most", "top_contacts"),
            ("what is my most active group chat", "top_groups"),
            ("give me my total sent and received messages this year", "overview_stats"),
            ("what plans did I make this week", "plans_in_window"),
            ("who are the new friends I made since January 1", "friends_made_since"),
        ]
        for (query, expected) in cases {
            let decision = NeedleCallValidator.validate(model: nil, query: query, contactNames: contacts, now: now)
            XCTAssertEqual(decision.call.tool, expected, query)
        }
    }

    func testTopContactChatScopeAndLimitAreReadable() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "who are my top five contacts in the Hao group",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "top_contacts")
        XCTAssertEqual(decision.call.args["chat"], .string("Hao"))
        XCTAssertEqual(decision.call.args["limit"], .int(5))
    }

    func testContactSearchDoesNotBecomeMessageSearch() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "do I have anyone named Arnav in my contacts",
            contactNames: contacts,
            now: now
        )
        XCTAssertEqual(decision.call.tool, "search_contacts")
        XCTAssertEqual(decision.call.args["name"], .string("Arnav"))
    }

    func testLegacyCompilationProducesExistingReadableQueryLanguage() {
        let call = NLToolCall(tool: "search_messages", args: [
            "with": .string("Annika Knechtel"),
            "from": .string("me"),
            "type": .string("link"),
            "query": .string("vegas"),
            "in": .string("this_month"),
        ])
        let legacy = NeedleCallValidator.legacyCall(from: call)
        XCTAssertEqual(legacy?.tool, "search")
        XCTAssertEqual(
            legacy?.args["query"]?.asString,
            "with:\"Annika Knechtel\" from:me type:link vegas"
        )
        XCTAssertEqual(legacy?.args["in"], .string("this_month"))
    }

    func testRealisticAcceptanceCorpusRoutesToTheRightFunction() {
        let cases: [(query: String, tool: String)] = [
            // Ordinary person and topic search.
            ("what did Howard say about dinner", "search_messages"),
            ("find the Vegas plans I discussed with Annika", "search_messages"),
            ("did Mom mention the dentist", "search_messages"),
            ("show my messages to Beck about rent", "search_messages"),
            ("messages from Howard about surfing", "search_messages"),
            ("texts with Vedant about the group project", "search_messages"),
            ("messages about flights in the Hao group chat", "search_messages"),

            // Dates and attachment filters remain ordinary searches.
            ("photos Howard sent yesterday", "search_messages"),
            ("videos I sent Annika last month", "search_messages"),
            ("voice notes from Mom this week", "search_messages"),
            ("PDFs with Beck from May 1 through June 15", "search_messages"),
            ("stickers Vedant sent me", "search_messages"),
            ("messages with Annika between December 20 and January 5", "search_messages"),
            ("messages with Mom before May 8", "search_messages"),
            ("messages with Beck over the past three months", "search_messages"),

            // Explicit reactions, counts, and first-message requests.
            ("messages Annika liked", "search_messages"),
            ("messages Mom heart-reacted to", "search_messages"),
            ("how many messages did I send Howard last month", "count_messages"),
            ("how often did Annika text me this year", "count_messages"),
            ("number of photos Mom sent this week", "count_messages"),
            ("when did I first text Beck", "first_message"),
            ("first message Howard sent me", "first_message"),
            ("earliest photo from Annika", "first_message"),

            // Ranking, overview, and higher-level local database tools.
            ("who do I text most", "top_contacts"),
            ("show my top 10 contacts this year", "top_contacts"),
            ("most active groups last month", "top_groups"),
            ("top five group chats this year", "top_groups"),
            ("total messages sent and received this year", "overview_stats"),
            ("catch me up on my conversation with Mom this week", "read_conversation"),
            ("what were Annika and I talking about yesterday", "read_conversation"),
            ("what plans did I make next week", "plans_in_window"),
            ("which commitments did I agree to this month", "plans_in_window"),
            ("who did I meet since January", "friends_made_since"),
            ("new friends I made this year", "friends_made_since"),
            ("do I know anyone named Arnav", "search_contacts"),
            ("find Priya in my contacts", "search_contacts"),
            ("top contacts in the Hao group chat", "top_contacts"),
        ]

        // Simulate a confident but wrong Needle ranking call. The validator
        // must still produce the same user-intended route for every query.
        let hostileModel = NeedleRoutingResult(
            call: NLToolCall(tool: "top_groups", args: [
                "limit": .int(99),
                "in": .string("question"),
            ]),
            callCount: 1,
            reasoning: nil,
            confidence: 0.99,
            rawJSON: "{}"
        )
        for item in cases {
            let decision = NeedleCallValidator.validate(
                model: hostileModel,
                query: item.query,
                contactNames: contacts,
                now: now
            )
            XCTAssertEqual(decision.call.tool, item.tool, item.query)
            if item.tool != "search_contacts" {
                let legacy = NeedleCallValidator.legacyCall(from: decision.call)
                XCTAssertNotNil(legacy, "\(item.query) did not compile to an executable database tool")
                if let query = legacy?.args["query"]?.asString {
                    XCTAssertNil(
                        NLAgent.operatorCorrection(for: query, now: now),
                        "\(item.query) compiled an invalid search expression: \(query)"
                    )
                }
                if let date = decision.call.args["in"]?.asString, date != "all_time" {
                    XCTAssertNotNil(
                        NLAgent.resolveDateArg(decision.call.args, now: now),
                        "\(item.query) emitted a date the executor cannot resolve: \(date)"
                    )
                }
            }
        }
    }

    func testRealisticAcceptanceCorpusExtractsCriticalFilters() {
        struct Case {
            let query: String
            let expected: [String: NLToolArg]
            let absent: [String]
        }
        let cases: [Case] = [
            Case(
                query: "show my messages to Beck about rent",
                expected: ["with": .string("Beck Peterson"), "from": .string("me"), "query": .string("rent")],
                absent: []
            ),
            Case(
                query: "messages from Howard about surfing",
                expected: ["from": .string("Howard Rosen"), "query": .string("surfing")],
                absent: ["with"]
            ),
            Case(
                query: "videos I sent Annika last month",
                expected: ["with": .string("Annika Knechtel"), "from": .string("me"), "type": .string("video"), "in": .string("last_month")],
                absent: ["query"]
            ),
            Case(
                query: "voice notes from Mom this week",
                expected: ["from": .string("Mom"), "type": .string("audio"), "in": .string("this_week")],
                absent: ["with", "query"]
            ),
            Case(
                query: "PDFs with Beck from May 1 through June 15, 2026",
                expected: ["with": .string("Beck Peterson"), "type": .string("file"), "in": .string("2026-05-01..2026-06-15")],
                absent: ["query"]
            ),
            Case(
                query: "messages with Annika between December 20 and January 5",
                expected: ["with": .string("Annika Knechtel"), "in": .string("2025-12-20..2026-01-05")],
                absent: ["query"]
            ),
            Case(
                query: "messages with Mom before May 8",
                expected: ["with": .string("Mom"), "in": .string("2001-01-01..2026-05-07")],
                absent: ["query"]
            ),
            Case(
                query: "messages with Beck over the past three months",
                expected: ["with": .string("Beck Peterson"), "in": .string("2026-05-14..2026-08-14")],
                absent: ["query"]
            ),
            Case(
                query: "messages Annika liked",
                expected: ["with": .string("Annika Knechtel"), "reaction": .string("like")],
                absent: ["query"]
            ),
            Case(
                query: "how many messages did I send Howard last month",
                expected: ["with": .string("Howard Rosen"), "from": .string("me"), "in": .string("last_month")],
                absent: ["query"]
            ),
            Case(
                query: "show my top 10 contacts this year",
                expected: ["limit": .int(10), "in": .string("2026-01-01..2026-12-31")],
                absent: ["query"]
            ),
            Case(
                query: "top contacts in the Hao group chat",
                expected: ["chat": .string("Hao"), "limit": .int(5)],
                absent: ["query"]
            ),
        ]

        for item in cases {
            let decision = NeedleCallValidator.validate(model: nil, query: item.query, contactNames: contacts, now: now)
            for (key, value) in item.expected {
                XCTAssertEqual(decision.call.args[key], value, "\(item.query) [\(key)]")
            }
            for key in item.absent {
                XCTAssertNil(decision.call.args[key], "\(item.query) unexpectedly emitted \(key)")
            }
        }
    }

    func testAmbiguousContentWordsDoNotHijackFunctionSelection() {
        let ordinarySearches = [
            "how many people are coming to dinner",
            "top secret plans with Vedant",
            "the Top Gun movie Howard mentioned",
            "find the first aid message from Mom",
            "group project notes with Vedant",
            "contactless payments with Annika",
            "messages about a new friend app",
            "most active ingredient in the recipe Mom sent",
            "what plans did Vedant send me",
            "the number of the restaurant Annika sent",
        ]
        for query in ordinarySearches {
            let decision = NeedleCallValidator.validate(model: nil, query: query, contactNames: contacts, now: now)
            XCTAssertEqual(decision.call.tool, "search_messages", query)
        }
    }

    func testCasualParaphrasesRouteWithoutDependingOnExactTestWording() {
        let cases: [(String, String)] = [
            ("who have I texted the most?", "top_contacts"),
            ("which person do I message most?", "top_contacts"),
            ("show my three most texted people", "top_contacts"),
            ("which group chat do I use the most?", "top_groups"),
            ("rank my group chats", "top_groups"),
            ("give me a recap of my chat with Mom", "read_conversation"),
            ("summarize my texts with Annika from last week", "read_conversation"),
            ("what did Beck and I talk about yesterday", "read_conversation"),
            ("when was the first message with Mom", "first_message"),
            ("show the first ever photo Annika sent", "first_message"),
            ("what do I have planned next week", "plans_in_window"),
            ("who are my new friends since March", "friends_made_since"),
            ("find a contact called Priya", "search_contacts"),
            ("does Arnav exist in my address book", "search_contacts"),
            ("who are the top people in the Hao chat", "top_contacts"),
            ("rank my contacts by messages", "top_contacts"),
            ("message totals for this month", "overview_stats"),
            ("how active have I been this month", "overview_stats"),
            ("all my messaging stats this year", "overview_stats"),
            ("how many times did Mom mention dinner", "count_messages"),
        ]
        for (query, expected) in cases {
            let decision = NeedleCallValidator.validate(model: nil, query: query, contactNames: contacts, now: now)
            XCTAssertEqual(decision.call.tool, expected, query)
        }
    }

    func testDirectionParaphrasesCompileToReadableSenderFilters() {
        let cases: [(String, String)] = [
            ("links I shared with Beck", "me"),
            ("photo Beck shared with me", "Beck Peterson"),
            ("pictures sent by Mom", "Mom"),
            ("messages I received from Howard", "Howard Rosen"),
        ]
        for (query, sender) in cases {
            let decision = NeedleCallValidator.validate(model: nil, query: query, contactNames: contacts, now: now)
            XCTAssertEqual(decision.call.args["from"], .string(sender), query)
        }
    }

    func testCommonDateRangeSyntaxIsCanonicalAndExecutable() {
        let cases: [(String, String)] = [
            ("messages with Annika between 5/1/26 and 6/15/26", "2026-05-01..2026-06-15"),
            ("messages with Annika between 5/1 and 6/15", "2026-05-01..2026-06-15"),
            ("messages with Annika May 1 - June 15", "2026-05-01..2026-06-15"),
            ("messages with Annika after May 1 and before June 15", "2026-05-02..2026-06-14"),
            ("messages with Annika since May 1", "2026-05-01..2026-08-14"),
            ("messages with Annika until June 15", "2001-01-01..2026-06-15"),
            ("messages with Annika from May through July", "2026-05-01..2026-07-31"),
            ("messages with Annika in June 2025", "2025-06-01..2025-06-30"),
        ]
        for (query, expected) in cases {
            let decision = NeedleCallValidator.validate(model: nil, query: query, contactNames: contacts, now: now)
            XCTAssertEqual(decision.call.args["in"], .string(expected), query)
            XCTAssertNotNil(NLAgent.resolveDateArg(decision.call.args, now: now), query)
        }
    }

    func testProductNeedlePathRepairsThenExecutesTheValidatedDatabaseCall() async {
        let tools = RecordingTools(names: contacts)
        let agent = NLAgent(runtime: HostileNeedleRuntime(), tools: tools)

        let result = await agent.answerWithNeedle(
            userQuery: "show my messages to Beck about rent last month",
            now: now
        )

        XCTAssertEqual(tools.lastQuery, "with:\"Beck Peterson\" from:me rent")
        XCTAssertNotNil(tools.lastRange)
        XCTAssertEqual(tools.lastLimit, 50)
        XCTAssertTrue(result.trace.contains { $0.label.contains("route corrected") })
        XCTAssertFalse(result.trace.contains { $0.status == .failed })
    }

    func testNeedleUsesGenericHybridRetrieverForConceptualMessageQuery() async {
        let tools = HybridTools()
        let agent = NLAgent(runtime: HostileNeedleRuntime(), tools: tools)

        let result = await agent.answerWithNeedle(
            userQuery: "jokes from Howard",
            now: now
        )

        XCTAssertEqual(result.hero?.message.id, 700)
        XCTAssertEqual(tools.hybridCalls, 1)
        XCTAssertEqual(tools.literalCalls, 0)
        XCTAssertTrue(result.trace.contains { $0.label.contains("Hybrid retrieval") })
        XCTAssertTrue(result.trace.contains { $0.label.contains("dense candidates") })
    }

    func testArgumentWithPersonUsesConflictRetrievalAndReturnsImplicitEvidence() async {
        let tools = ConflictTools()
        let agent = NLAgent(runtime: HostileNeedleRuntime(), tools: tools)

        let result = await agent.answerWithNeedle(
            userQuery: "argument with Annika",
            now: now
        )

        XCTAssertEqual(result.hero?.message.id, 1)
        XCTAssertFalse(result.hero?.message.body.lowercased().contains("argument") ?? true)
        XCTAssertTrue(result.candidates.contains { $0.message.id == 3 }, "surrounding conversation should load")
        XCTAssertFalse(result.candidates.contains { $0.message.chatRowID == 99 }, "same-person groups must not leak")
        XCTAssertEqual(tools.requestedChatIDs, [[42]])
        XCTAssertEqual(tools.queries.count, 1)
        XCTAssertTrue(tools.queries[0].contains("believe"))
        XCTAssertTrue(tools.queries[0].contains("in:\"Annika Knechtel\""))
        XCTAssertTrue(result.trace.contains { $0.label.contains("qualifying conversation windows") })
        XCTAssertTrue(result.trace.contains { $0.phase == .ranking })
    }

    func testConflictProfileRanksImplicitTensionAboveBenignSimilarLanguage() {
        let tense = ConversationalConceptRetrieval.conflictScore(
            body: "I can't believe you forgot AGAIN. This is not okay!",
            sentiment: -0.8
        )
        let repairOnly = ConversationalConceptRetrieval.conflictScore(
            body: "Sorry I missed your call, I was driving.",
            sentiment: -0.1
        )
        let positiveAlways = ConversationalConceptRetrieval.conflictScore(
            body: "You always make me laugh!",
            sentiment: 0.8
        )

        XCTAssertGreaterThan(tense, repairOnly)
        XCTAssertGreaterThan(tense, positiveAlways)
    }

    func testConflictWindowRejectsIsolatedNegativeReflectionWithOrdinaryContext() {
        let messages = [
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "I've been perceiving the past year in a very negative light. I think this is because of how other people perceive me.",
                isFromMe: true,
                sentiment: -0.9
            ),
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "Do u wanna see",
                isFromMe: true,
                sentiment: 0
            ),
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "sure",
                isFromMe: false,
                sentiment: 0.1
            ),
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "i am excited",
                isFromMe: false,
                sentiment: 0.8
            ),
        ]

        let evaluation = ConversationalConceptRetrieval.evaluateConflictWindow(messages)
        XCTAssertEqual(evaluation.score, 0)
        XCTAssertNil(evaluation.anchorIndex)
    }

    func testConflictWindowRequiresMultipleMessagesAndAcceptsDirectedExchange() {
        let accusation = ConversationalConceptRetrieval.ConflictWindowMessage(
            body: "I can't believe you forgot AGAIN. This is not okay.",
            isFromMe: false,
            sentiment: -0.8
        )
        let isolated = ConversationalConceptRetrieval.evaluateConflictWindow([accusation])
        XCTAssertEqual(isolated.score, 0, "a single indexed message is not a conversation window")

        let exchange = ConversationalConceptRetrieval.evaluateConflictWindow([
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "I told you this really mattered to me.",
                isFromMe: true,
                sentiment: -0.4
            ),
            accusation,
            ConversationalConceptRetrieval.ConflictWindowMessage(
                body: "You're right, I'm sorry.",
                isFromMe: true,
                sentiment: -0.2
            ),
        ])
        XCTAssertGreaterThan(exchange.score, 0)
        XCTAssertEqual(exchange.anchorIndex, 1)
        XCTAssertGreaterThanOrEqual(exchange.evidenceCount, 2)
    }

    func testConflictRetrievalPreservesValidatedDateRange() async {
        let tools = ConflictTools()
        let agent = NLAgent(runtime: HostileNeedleRuntime(), tools: tools)

        _ = await agent.answerWithNeedle(
            userQuery: "argument with Annika between May 1 and June 15",
            now: now
        )

        XCTAssertTrue(tools.searchHadDateRange)
        XCTAssertTrue(tools.directReadHadDateRange)
    }

    func testFunctionArgumentDoesNotTriggerSocialConflictProfile() {
        let decision = NeedleCallValidator.validate(
            model: nil,
            query: "function argument Annika sent me",
            contactNames: contacts,
            now: now
        )
        XCTAssertNil(ConversationalConceptRetrieval.request(for: "function argument Annika sent me", call: decision.call))
    }
}
