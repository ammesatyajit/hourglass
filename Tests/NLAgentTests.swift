//
//  NLAgentTests.swift
//  HourglassTests
//
//  Tests for the `NLAgent` plan→execute→answer loop. Uses a stubbed
//  `LLMRuntime` (`StubLLMRuntime`) and a mock `NLAgentTools` to exercise
//  every branch deterministically without a real chat.db or LLM.
//
//  The agent loop's contract is: even when the LLM goes sideways, the
//  user gets *something* useful via the fallback path. These tests lock
//  in that contract.
//

import Foundation
import os
import XCTest
@testable import Hourglass

final class NLAgentTests: XCTestCase {

    // MARK: - Mock tools

    /// Records every tool call for assertion, returns canned results.
    /// Implemented as `@unchecked Sendable` final class rather than an
    /// actor because the agent's tool calls are best modeled as fast
    /// in-process work — going through actor isolation forced a
    /// context-switch storm that hung tests under Swift 6 strict
    /// concurrency. The underlying real impl (`MessageSearchTools`) is
    /// also a struct, not an actor.
    final class MockTools: @unchecked Sendable, NLAgentTools {
        // All mutable state lives inside the OS unfair lock — async-safe
        // in Swift 6 strict concurrency. We can't use `NSLock.lock()`
        // because that's marked unavailable from async contexts.
        struct State: Sendable {
            var lastSearchQuery: String? = nil
            var lastDateRange: ClosedRange<Date>? = nil
            var lastLimit: Int? = nil
            var oldestCallCount: Int = 0
            var contextCalls: [(String, Int, Int)] = []
            var cannedResults: [(needle: String, results: [MessageSearch.Result])] = []
            var shouldThrow: Bool = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func setCanned(needle: String, results: [MessageSearch.Result]) {
            state.withLock { $0.cannedResults.append((needle, results)) }
        }
        func setThrow(_ flag: Bool) {
            state.withLock { $0.shouldThrow = flag }
        }
        var lastSearchQuery: String? {
            state.withLock { $0.lastSearchQuery }
        }
        var lastDateRange: ClosedRange<Date>? {
            state.withLock { $0.lastDateRange }
        }
        var lastLimit: Int? {
            state.withLock { $0.lastLimit }
        }

        func search(
            query: String,
            dateRange: ClosedRange<Date>?,
            limit: Int?,
            order: MessageSearch.SortOrder
        ) async throws -> [MessageSearch.Result] {
            try state.withLock { st -> [MessageSearch.Result] in
                if st.shouldThrow { throw NSError(domain: "test", code: 1) }
                st.lastSearchQuery = query
                st.lastDateRange = dateRange
                st.lastLimit = limit
                for (needle, results) in st.cannedResults {
                    if query.contains(needle) { return results }
                }
                return []
            }
        }

        func oldestMatching(query: String) async throws -> MessageSearch.Result? {
            try state.withLock { st -> MessageSearch.Result? in
                if st.shouldThrow { throw NSError(domain: "test", code: 1) }
                st.oldestCallCount += 1
                for (needle, results) in st.cannedResults {
                    if query.contains(needle) { return results.last }
                }
                return nil
            }
        }

        func context(
            forGUID guid: String,
            before: Int,
            after: Int
        ) async throws -> [MessageSearch.Result] {
            state.withLock { st in
                st.contextCalls.append((guid, before, after))
            }
            return []
        }
    }

    // MARK: - Helpers

    private func makeFakeResult(
        id: Int64,
        guid: String,
        body: String,
        sender: String,
        date: Date
    ) -> MessageSearch.Result {
        let m = Message(
            id: id,
            guid: guid,
            date: date,
            isFromMe: false,
            chatRowID: 1,
            senderHandle: sender,
            chatStyle: 45,
            chatDisplayName: nil,
            body: body,
            associatedMessageType: 0
        )
        return MessageSearch.Result(
            message: m,
            partnerName: sender,
            senderName: sender
        )
    }

    private func makeAgent(tools: MockTools, runtime: LLMRuntime = StubLLMRuntime()) -> NLAgent {
        return NLAgent(runtime: runtime, tools: tools)
    }

    // MARK: - Canonical: argument with Annika

    func testCanonical_argumentWithAnnika_planExecuteAnswer() async {
        let tools = MockTools()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let canned = [
            makeFakeResult(id: 1, guid: "g1", body: "I really don't think that's fair", sender: "Annika", date: date),
            makeFakeResult(id: 2, guid: "g2", body: "You always say that", sender: "Annika", date: date.addingTimeInterval(-86400)),
        ]
        tools.setCanned(needle: "Annika", results: canned)

        let agent = makeAgent(tools: tools)
        let result = await agent.answer(
            userQuery: "find my argument with Annika that happened around 2 weeks ago"
        )

        XCTAssertNotNil(result.plan)
        XCTAssertEqual(result.plan?.intent, .findClusterStart)
        XCTAssertEqual(result.plan?.person, "Annika")
        XCTAssertEqual(result.plan?.timeWindow, .last14d)
        XCTAssertEqual(result.plan?.paddingDays, 3)
        XCTAssertEqual(result.candidates.count, 2)
        // Cluster start = oldest in window. canned[1] is older.
        XCTAssertEqual(result.hero?.message.guid, "g2")
        // The trace should have at least planning/searching/ranking/answering.
        XCTAssertGreaterThanOrEqual(result.trace.count, 3)
        XCTAssertFalse(result.degradedToFallback)
    }

    // MARK: - Oldest-message intent

    func testHoward_findsOldestMessage() async {
        let tools = MockTools()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // search() returns DESC; oldest is the last element.
        let canned = [
            makeFakeResult(id: 100, guid: "newer", body: "Hey", sender: "Howard", date: now),
            makeFakeResult(id: 50,  guid: "middle", body: "Hi", sender: "Howard", date: now.addingTimeInterval(-86400 * 30)),
            makeFakeResult(id: 1,   guid: "oldest", body: "First text!", sender: "Howard", date: now.addingTimeInterval(-86400 * 365)),
        ]
        tools.setCanned(needle: "Howard", results: canned)

        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "when did I first text Howard?")

        XCTAssertEqual(result.plan?.intent, .findOldestMessage)
        XCTAssertEqual(result.hero?.message.guid, "oldest")
        XCTAssertEqual(result.explanation, "Oldest matching message.")
    }

    // MARK: - Funniest in family chat

    func testFamilyFunniest_emitsReactionsLaughQuery() async {
        let tools = MockTools()
        let canned = [
            makeFakeResult(id: 1, guid: "fam1", body: "lol", sender: "Mom", date: Date())
        ]
        tools.setCanned(needle: "family", results: canned)

        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "show me the funniest things in the family chat")

        XCTAssertEqual(result.plan?.searchQuery, "in:\"family\" reactions:laugh")
        XCTAssertEqual(result.hero?.message.guid, "fam1")
    }

    // MARK: - Yes/no with proof

    func testYesNoWithProof_findsProofMessage() async {
        let tools = MockTools()
        let canned = [
            makeFakeResult(id: 1, guid: "sorry1", body: "I'm sorry about earlier", sender: "Me", date: Date()),
        ]
        tools.setCanned(needle: "Henry", results: canned)

        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "did I ever apologize to Henry?")

        XCTAssertEqual(result.plan?.intent, .yesNoWithProof)
        XCTAssertEqual(result.hero?.message.guid, "sorry1")
        XCTAssertNotNil(result.explanation)
    }

    // MARK: - Empty candidates

    func testNoCandidates_heroIsNil() async {
        let tools = MockTools()
        // No canned results — every search returns [].

        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "find my argument with Annika that happened around 2 weeks ago")

        XCTAssertNotNil(result.plan)
        XCTAssertNil(result.hero)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.degradedToFallback)  // plan succeeded, just no matches
    }

    // MARK: - Fallback path

    func testFallback_whenLLMReturnsEmpty_runsKeywordSearch() async {
        // Runtime that returns garbage that doesn't parse as JSON.
        struct GarbageRuntime: LLMRuntime {
            let modelLabel = "garbage"
            var isReady: Bool { get async { true } }
            func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
                return "no JSON here, sorry"
            }
        }
        let tools = MockTools()
        let canned = [makeFakeResult(id: 1, guid: "k", body: "hi", sender: "x", date: Date())]
        // The fallback keyword extractor for "find my argument with Annika" should produce a
        // query containing "Annika" (proper noun preserved).
        tools.setCanned(needle: "Annika", results: canned)

        let agent = NLAgent(runtime: GarbageRuntime(), tools: tools)
        let result = await agent.answer(
            userQuery: "find my argument with Annika two weeks ago"
        )

        XCTAssertNil(result.plan)
        XCTAssertTrue(result.degradedToFallback)
        XCTAssertEqual(result.hero?.message.guid, "k")
        XCTAssertNotNil(result.explanation)
    }

    func testFallback_whenLLMThrows_runsKeywordSearch() async {
        struct ThrowingRuntime: LLMRuntime {
            let modelLabel = "throws"
            var isReady: Bool { get async { true } }
            func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
                throw LLMRuntimeError.notReady(reason: "no model")
            }
        }
        let tools = MockTools()
        let agent = NLAgent(runtime: ThrowingRuntime(), tools: tools)
        let result = await agent.answer(userQuery: "anything")
        XCTAssertNil(result.plan)
        XCTAssertTrue(result.degradedToFallback)
    }

    // MARK: - Search engine throws

    func testSearchThrows_degradesGracefully() async {
        let tools = MockTools()
        tools.setThrow(true)
        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "when did I first text Howard?")

        XCTAssertNotNil(result.plan)
        XCTAssertNil(result.hero)
        XCTAssertTrue(result.degradedToFallback)
    }

    // MARK: - Best-effort keyword query

    func testBestEffortKeywordQuery_extractsNounsAndDates() {
        let q = NLAgent.bestEffortKeywordQuery(
            from: "find my argument with Annika that happened around 2 weeks ago"
        )
        XCTAssertTrue(q.contains("Annika"), "should preserve proper noun, got: \(q)")
        XCTAssertTrue(q.contains("argument"), "should preserve content word")
        XCTAssertTrue(q.contains("last:"), "should detect date phrase")
    }

    func testBestEffortKeywordQuery_handlesThisWeek() {
        let q = NLAgent.bestEffortKeywordQuery(from: "what did mom say about dinner this week?")
        // "say" is a stopword in the extractor — accepted as a minor loss
        // (the keyword search still scopes by mom + dinner + last:7d).
        XCTAssertTrue(q.contains("last:7d"), "should detect 'this week' as last:7d, got: \(q)")
        XCTAssertTrue(q.contains("mom"), "should preserve content noun, got: \(q)")
        XCTAssertTrue(q.contains("dinner"), "should preserve content noun, got: \(q)")
    }

    func testBestEffortKeywordQuery_emptyFallbackToOriginal() {
        // All stopwords — the function returns the original query.
        let original = "the my a of"
        let q = NLAgent.bestEffortKeywordQuery(from: original)
        XCTAssertEqual(q, original)
    }

    // MARK: - widen()

    func testWiden_nilRange_returnsNil() {
        XCTAssertNil(NLAgent.widen(nil, by: 3))
    }

    func testWiden_zeroPadding_returnsOriginal() {
        let range = Date()...Date().addingTimeInterval(86400)
        let widened = NLAgent.widen(range, by: 0)
        XCTAssertEqual(widened, range)
    }

    func testWiden_threeDays_widensSymmetrically() {
        let now = Date()
        let range = now...now.addingTimeInterval(86400)
        let widened = NLAgent.widen(range, by: 3)!
        XCTAssertEqual(widened.lowerBound.timeIntervalSince(range.lowerBound), -3 * 86400, accuracy: 60)
        XCTAssertEqual(widened.upperBound.timeIntervalSince(range.upperBound),  3 * 86400, accuracy: 60)
    }

    // MARK: - Generic / unknown query

    func testUnknownQuery_fallbackBuilderProducesPlausibleSearch() async {
        let tools = MockTools()
        tools.setCanned(needle: "weather", results: [
            makeFakeResult(id: 1, guid: "w", body: "it's raining", sender: "Mom", date: Date())
        ])
        let agent = makeAgent(tools: tools)
        let result = await agent.answer(userQuery: "anything weather related")

        // The stub's default fallback echoes the user query into search_query.
        XCTAssertNotNil(result.plan)
        XCTAssertTrue(
            (result.plan?.searchQuery ?? "").contains("weather"),
            "fallback query should preserve content words: \(result.plan?.searchQuery ?? "")"
        )
        XCTAssertEqual(result.hero?.message.guid, "w")
    }
}
