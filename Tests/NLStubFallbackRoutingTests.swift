//
//  NLStubFallbackRoutingTests.swift
//  HourglassTests
//
//  Covers the rule-based fallback path in `NLAgent.answer()` — reached
//  when the LLM planner returns nothing parseable (a GarbageRuntime here
//  stands in for a real model emitting non-JSON). The fallback extracts
//  person + date + concept structurally; when a concept search returns
//  zero hits AND we have a person + date anchor, it RETRIES without the
//  concept using a CENTERED date window + `in:"NAME"` 1:1 scope.
//
//  History: an earlier pass routed `StubLLMRuntime` straight to this
//  fallback. That was reverted once `NLSearchViewModel.ask()` started
//  hard-blocking the stub in production (showing "loading model" until
//  MLX swaps in). So the stub is back to being a canned-plan fixture
//  (see NLAgentTests); the fallback is now exercised via a genuine
//  parse-failure runtime, which is the real-world trigger on the MLX path.
//

import Foundation
import XCTest
@testable import Hourglass

@MainActor
final class NLStubFallbackRoutingTests: XCTestCase {

    /// Always returns non-JSON, so `PlanJSONParser.parse` fails on both
    /// attempts and `answer()` routes to `runFallback`.
    struct GarbageRuntime: LLMRuntime {
        let modelLabel = "Garbage"
        var isReady: Bool { get async { true } }
        func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
            "I'm not going to give you JSON, sorry."
        }
    }

    final class SpyTools: NLAgentTools, @unchecked Sendable {
        var capturedQueries: [String] = []
        var searchReturns: [[MessageSearch.Result]] = []
        let contactNamesValue: [String]

        init(contactNames: [String] = ["Annika Renganathan", "Henry Park", "Mom"]) {
            self.contactNamesValue = contactNames
        }

        func search(
            query: String,
            dateRange: ClosedRange<Date>?,
            limit: Int?,
            order: MessageSearch.SortOrder
        ) async throws -> [MessageSearch.Result] {
            capturedQueries.append(query)
            if !searchReturns.isEmpty {
                return searchReturns.removeFirst()
            }
            return []
        }

        func oldestMatching(query: String) async throws -> MessageSearch.Result? { nil }
        func context(forGUID: String, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
        func availableContactNames() async -> [String] { contactNamesValue }
        func topContacts(in: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.ContactStat] { [] }
        func topGroups(in: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.GroupStat] { [] }
        func overviewStats(in: ClosedRange<Date>?) async throws -> DashboardStats.OverviewCounters {
            DashboardStats.OverviewCounters(total: 0, sent: 0, received: 0, chats: 0, oldest: nil, newest: nil)
        }
        func countMatching(query: String, in: ClosedRange<Date>?) async throws -> Int { 0 }
        func firstMatching(query: String, in: ClosedRange<Date>?) async throws -> MessageSearch.Result? { nil }
        func messagesAroundTime(date: Date, chatRowID: Int64?, before: Int, after: Int) async throws -> [MessageSearch.Result] { [] }
        func readMessages(in: ClosedRange<Date>?, with: String?, limit: Int) async throws -> [MessageSearch.Result] { [] }
        func rawSearchSQL(sql: String, limit: Int) async throws -> [[String: String]] { [] }
    }

    // MARK: - Rule-based fallback structure (genuine planner failure)

    func test_plannerFailure_routesToRuleBasedFallback() async {
        let spy = SpyTools()
        let agent = NLAgent(runtime: GarbageRuntime(), tools: spy)

        let now = ISO8601DateFormatter().date(from: "2026-05-27T03:00:00Z")!
        _ = await agent.answer(
            userQuery: "find my argument with annika around 3 weeks ago",
            now: now
        )

        XCTAssertFalse(spy.capturedQueries.isEmpty, "fallback should have run at least one search")
        let first = spy.capturedQueries.first ?? ""
        XCTAssertTrue(
            first.contains("with:\"Annika Renganathan\""),
            "fallback search must resolve the person — got: \(first)"
        )
        XCTAssertTrue(first.contains("last:"), "fallback must add a date operator — got: \(first)")
        XCTAssertTrue(first.contains("argument"), "fallback must keep the concept — got: \(first)")
        XCTAssertFalse(
            first.split(separator: " ").contains("find"),
            "stopword 'find' should not leak into the query — got: \(first)"
        )
    }

    func test_zeroHitsWithConcept_retriesWithCenteredWindowAndIn1to1() async {
        let spy = SpyTools()
        // All searches return [] → the concept search misses, triggering
        // the centered-window retry.
        let agent = NLAgent(runtime: GarbageRuntime(), tools: spy)

        let now = ISO8601DateFormatter().date(from: "2026-05-27T03:00:00Z")!
        _ = await agent.answer(
            userQuery: "find my argument with annika around 3 weeks ago",
            now: now
        )

        XCTAssertGreaterThanOrEqual(
            spy.capturedQueries.count, 2,
            "expected an initial + a retry search — got \(spy.capturedQueries.count): \(spy.capturedQueries)"
        )
        let retry = spy.capturedQueries[1]
        XCTAssertTrue(retry.contains("in:\"Annika Renganathan\""), "retry uses 1:1 scope — got: \(retry)")
        XCTAssertTrue(retry.contains("after:"), "retry includes after: — got: \(retry)")
        XCTAssertTrue(retry.contains("before:"), "retry includes before: — got: \(retry)")
        XCTAssertFalse(retry.contains("argument"), "retry strips the concept — got: \(retry)")
        // 3 weeks before 2026-05-27 = 2026-05-06. The retry uses padDays=2
        // (deliberately tighter than the helper's ±5 default — ±5
        // over-fetched on heavy 1:1s, see runFallback comment), so the
        // window is 2026-05-04 .. 2026-05-08.
        XCTAssertTrue(
            retry.contains("after:2026-05-04") && retry.contains("before:2026-05-08"),
            "centered window (padDays=2) should be after:2026-05-04 before:2026-05-08 — got: \(retry)"
        )
    }

    func test_hitsWithConcept_doesNotRetry() async {
        let spy = SpyTools()
        let fake = MessageSearch.Result(
            message: Message(
                id: 1, guid: "guid-1", date: Date(), isFromMe: false,
                chatRowID: 1, senderHandle: "+14253057121", chatStyle: 45,
                chatDisplayName: nil, body: "what an argument", associatedMessageType: 0
            ),
            partnerName: "Annika Renganathan",
            senderName: "Annika Renganathan"
        )
        spy.searchReturns = [[fake]]
        let agent = NLAgent(runtime: GarbageRuntime(), tools: spy)

        let now = ISO8601DateFormatter().date(from: "2026-05-27T03:00:00Z")!
        _ = await agent.answer(
            userQuery: "find my argument with annika around 3 weeks ago",
            now: now
        )

        XCTAssertEqual(
            spy.capturedQueries.count, 1,
            "concept search hit → no retry — got \(spy.capturedQueries.count): \(spy.capturedQueries)"
        )
    }

    // MARK: - extractCenteredWindow (pure helper)

    func test_extractCenteredWindow_threeWeeksAgo() {
        let now = ISO8601DateFormatter().date(from: "2026-05-27T03:00:00Z")!
        let w = NLAgent.extractCenteredWindow(fromQuery: "around 3 weeks ago", now: now)
        XCTAssertNotNil(w)
        XCTAssertEqual(NLAgent.isoDate(w!.lower), "2026-05-01")
        XCTAssertEqual(NLAgent.isoDate(w!.upper), "2026-05-11")
    }

    func test_extractCenteredWindow_twoMonthsBack() {
        let now = ISO8601DateFormatter().date(from: "2026-05-27T03:00:00Z")!
        let w = NLAgent.extractCenteredWindow(fromQuery: "two months back", now: now)
        XCTAssertNotNil(w)
        XCTAssertEqual(NLAgent.isoDate(w!.lower), "2026-03-23")
        XCTAssertEqual(NLAgent.isoDate(w!.upper), "2026-04-02")
    }

    func test_extractCenteredWindow_noAgoPhrase_returnsNil() {
        let now = Date()
        XCTAssertNil(NLAgent.extractCenteredWindow(fromQuery: "find my argument with annika", now: now))
        XCTAssertNil(NLAgent.extractCenteredWindow(fromQuery: "this week", now: now))
        XCTAssertNil(NLAgent.extractCenteredWindow(fromQuery: "yesterday", now: now))
    }
}
