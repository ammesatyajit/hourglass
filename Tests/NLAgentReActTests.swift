//
//  NLAgentReActTests.swift
//  HourglassTests
//
//  Tests for the ReAct tool loop in `NLAgent.answerWithToolLoop` and the
//  new tool surface (`topContacts`, `topGroups`, `overviewStats`,
//  `countMatching`, `firstMatching`, `messagesAroundTime`, `rawSearchSQL`).
//
//  We use a scripted `LLMRuntime` that emits a queue of pre-baked
//  tool-call / final-answer JSON strings, and a mock `NLAgentTools` that
//  records every tool call. Between them we drive the loop without an
//  LLM or chat.db.
//

import Foundation
import os
import XCTest
@testable import Hourglass

final class NLAgentReActTests: XCTestCase {

    // MARK: - Scripted runtime

    /// Returns a queue of pre-baked outputs; one per `respond` call. Lets
    /// us drive an N-iteration ReAct loop deterministically.
    final class ScriptedRuntime: @unchecked Sendable, LLMRuntime {
        struct State: Sendable {
            var outputs: [String]
            var callCount: Int = 0
            var receivedPrompts: [String] = []
        }
        private let state: OSAllocatedUnfairLock<State>
        let modelLabel = "ScriptedRuntime"
        var isReady: Bool { get async { true } }

        init(outputs: [String]) {
            self.state = OSAllocatedUnfairLock(initialState: State(outputs: outputs))
        }

        var callCount: Int {
            state.withLock { $0.callCount }
        }
        var prompts: [String] {
            state.withLock { $0.receivedPrompts }
        }

        func respond(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
            return state.withLock { st in
                st.callCount += 1
                st.receivedPrompts.append(userPrompt)
                guard !st.outputs.isEmpty else {
                    return "{}"  // out of outputs — bare JSON forces the loop to bail
                }
                return st.outputs.removeFirst()
            }
        }
    }

    // MARK: - Mock tools (records calls, returns canned results)

    final class MockTools: @unchecked Sendable, NLAgentTools {
        struct State: Sendable {
            var searchCalls: [(query: String, range: ClosedRange<Date>?)] = []
            var topContactsCalls: [(range: ClosedRange<Date>?, limit: Int)] = []
            var topGroupsCalls: [(range: ClosedRange<Date>?, limit: Int)] = []
            var overviewCalls: [ClosedRange<Date>?] = []
            var countCalls: [(query: String, range: ClosedRange<Date>?)] = []
            var firstCalls: [(query: String, range: ClosedRange<Date>?)] = []
            var aroundTimeCalls: [(date: Date, chat: Int64?, before: Int, after: Int)] = []
            var rawSQLCalls: [(sql: String, limit: Int)] = []
            var contextCalls: [(guid: String, before: Int, after: Int)] = []
            var readMessagesCalls: [(range: ClosedRange<Date>?, person: String?, limit: Int)] = []

            var cannedSearch: [MessageSearch.Result] = []
            var cannedFirst: MessageSearch.Result? = nil
            var cannedContext: [MessageSearch.Result] = []
            var cannedAroundTime: [MessageSearch.Result] = []
            var cannedReadMessages: [MessageSearch.Result] = []
            var cannedCount: Int = 0
            var cannedTopContacts: [DashboardStats.ContactStat] = []
            var cannedTopGroups: [DashboardStats.GroupStat] = []
            var cannedOverview: DashboardStats.OverviewCounters =
                DashboardStats.OverviewCounters(total: 0, sent: 0, received: 0, chats: 0, oldest: nil, newest: nil)
            var cannedRawSQL: [[String: String]] = []
        }
        let state = OSAllocatedUnfairLock(initialState: State())

        func search(query: String, dateRange: ClosedRange<Date>?, limit: Int?, order: MessageSearch.SortOrder) async throws -> [MessageSearch.Result] {
            state.withLock { st in
                st.searchCalls.append((query, dateRange))
                return st.cannedSearch
            }
        }
        func oldestMatching(query: String) async throws -> MessageSearch.Result? {
            state.withLock { $0.cannedSearch.last }
        }
        func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result] {
            state.withLock { st in
                st.contextCalls.append((guid, before, after))
                return st.cannedContext
            }
        }
        func topContacts(in dateRange: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.ContactStat] {
            state.withLock { st in
                st.topContactsCalls.append((dateRange, limit))
                return st.cannedTopContacts
            }
        }
        func topGroups(in dateRange: ClosedRange<Date>?, limit: Int) async throws -> [DashboardStats.GroupStat] {
            state.withLock { st in
                st.topGroupsCalls.append((dateRange, limit))
                return st.cannedTopGroups
            }
        }
        func overviewStats(in dateRange: ClosedRange<Date>?) async throws -> DashboardStats.OverviewCounters {
            state.withLock { st in
                st.overviewCalls.append(dateRange)
                return st.cannedOverview
            }
        }
        func countMatching(query: String, in dateRange: ClosedRange<Date>?) async throws -> Int {
            state.withLock { st in
                st.countCalls.append((query, dateRange))
                return st.cannedCount
            }
        }
        func firstMatching(query: String, in dateRange: ClosedRange<Date>?) async throws -> MessageSearch.Result? {
            state.withLock { st in
                st.firstCalls.append((query, dateRange))
                return st.cannedFirst
            }
        }
        func messagesAroundTime(date: Date, chatRowID: Int64?, before: Int, after: Int) async throws -> [MessageSearch.Result] {
            state.withLock { st in
                st.aroundTimeCalls.append((date, chatRowID, before, after))
                return st.cannedAroundTime
            }
        }
        func rawSearchSQL(sql: String, limit: Int) async throws -> [[String: String]] {
            state.withLock { st in
                st.rawSQLCalls.append((sql, limit))
                return st.cannedRawSQL
            }
        }
        func readMessages(in dateRange: ClosedRange<Date>?, with personName: String?, limit: Int) async throws -> [MessageSearch.Result] {
            state.withLock { st in
                st.readMessagesCalls.append((dateRange, personName, limit))
                return st.cannedReadMessages
            }
        }
    }

    // MARK: - Helpers

    private func makeResult(
        id: Int64 = 1,
        guid: String = "g",
        body: String = "hi",
        sender: String = "Mom",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        chatRowID: Int64 = 1,
        isFromMe: Bool = false,
        partner: String? = nil
    ) -> MessageSearch.Result {
        let m = Message(
            id: id, guid: guid, date: date, isFromMe: isFromMe, chatRowID: chatRowID,
            senderHandle: sender, chatStyle: 45, chatDisplayName: nil,
            body: body, associatedMessageType: 0
        )
        return MessageSearch.Result(message: m, partnerName: partner ?? sender, senderName: isFromMe ? "You" : sender)
    }

    private func makeContactStat(_ name: String, sent: Int, received: Int) -> DashboardStats.ContactStat {
        DashboardStats.ContactStat(
            key: "name:\(name)",
            displayName: name,
            sent: sent,
            received: received,
            total: sent + received
        )
    }

    private func makeGroupStat(_ name: String, sent: Int, total: Int, rowID: Int64) -> DashboardStats.GroupStat {
        DashboardStats.GroupStat(
            chatRowID: rowID,
            displayName: name,
            sentByYou: sent,
            total: total
        )
    }

    // MARK: - Tool-call parser

    func testToolCallParser_decodesSingleTurnTool() throws {
        let raw = """
        {"tool":"search","args":{"query":"vegas","in":"all_time","limit":5}}
        """
        let dec = try NLToolCallParser.parse(raw)
        guard case .tool(let call) = dec else { return XCTFail("expected tool") }
        XCTAssertEqual(call.tool, "search")
        XCTAssertEqual(call.args["query"]?.asString, "vegas")
        XCTAssertEqual(call.args["in"]?.asString, "all_time")
        XCTAssertEqual(call.args["limit"]?.asInt, 5)
    }

    func testToolCallParser_decodesFinalAnswer() throws {
        let raw = """
        {"answer":"You texted Sarah the most.","hero_index":2}
        """
        let dec = try NLToolCallParser.parse(raw)
        guard case .final(let final) = dec else { return XCTFail("expected final") }
        XCTAssertEqual(final.answer, "You texted Sarah the most.")
        XCTAssertEqual(final.heroIndex, 2)
    }

    func testToolCallParser_acceptsPreamble() throws {
        let raw = "Here's the call: {\"tool\":\"topContacts\",\"args\":{\"limit\":3}}"
        let dec = try NLToolCallParser.parse(raw)
        guard case .tool(let call) = dec else { return XCTFail("expected tool") }
        XCTAssertEqual(call.tool, "topContacts")
        XCTAssertEqual(call.args["limit"]?.asInt, 3)
    }

    func testToolCallParser_missingFields_throws() {
        XCTAssertThrowsError(try NLToolCallParser.parse("{}"))
        XCTAssertThrowsError(try NLToolCallParser.parse("not JSON"))
    }

    // MARK: - Evidence indices (adaptive-synthesis pass)

    func testToolCallParser_decodesEvidenceIndices() throws {
        let raw = #"{"answer":"They planned dinner.","hero_index":3,"evidence_indices":[0,3,7]}"#
        let dec = try NLToolCallParser.parse(raw)
        guard case .final(let final) = dec else { return XCTFail("expected final") }
        XCTAssertEqual(final.heroIndex, 3)
        XCTAssertEqual(final.evidenceIndices, [0, 3, 7])
    }

    func testToolCallParser_evidenceIndices_tolerantOfStringsAndScalar() throws {
        // Array of numeric strings.
        let strArr = try NLToolCallParser.parse(#"{"answer":"a","hero_index":null,"evidence_indices":["1","4"]}"#)
        guard case .final(let f1) = strArr else { return XCTFail("expected final") }
        XCTAssertEqual(f1.evidenceIndices, [1, 4])
        // Single scalar.
        let scalar = try NLToolCallParser.parse(#"{"answer":"a","hero_index":null,"evidence_indices":2}"#)
        guard case .final(let f2) = scalar else { return XCTFail("expected final") }
        XCTAssertEqual(f2.evidenceIndices, [2])
        // Absent → empty, not nil/crash.
        let absent = try NLToolCallParser.parse(#"{"answer":"a","hero_index":null}"#)
        guard case .final(let f3) = absent else { return XCTFail("expected final") }
        XCTAssertEqual(f3.evidenceIndices, [])
    }

    /// The model cites evidence [3, 0, 7] from a 9-result search. The
    /// returned candidates must lead with those three (in that order) so
    /// the answer view's "hero + next 4" surfaces the cited messages.
    func testReAct_evidenceIndices_reorderCandidatesAsEvidence() async {
        let tools = MockTools()
        let results = (0..<9).map { i in
            makeResult(id: Int64(100 + i), guid: "m\(i)", body: "msg \(i)", sender: "Mom")
        }
        tools.state.withLock { $0.cannedSearch = results }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"search","args":{"query":"with:\"Mom\" thanksgiving|turkey|holiday","in":"all_time","limit":40}}"#,
            #"{"answer":"You planned Thanksgiving — she set dinner at 4 and asked for pie.","hero_index":3,"evidence_indices":[3,0,7]}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "what did Mom say about thanksgiving")

        // Hero is the first cited index.
        XCTAssertEqual(result.hero?.message.guid, "m3")
        // Candidates lead with the cited evidence in the model's order,
        // then the remaining messages follow.
        let leadGUIDs = result.candidates.prefix(3).map { $0.message.guid }
        XCTAssertEqual(leadGUIDs, ["m3", "m0", "m7"])
        // Nothing dropped: all 9 still present, deduped.
        XCTAssertEqual(result.candidates.count, 9)
        XCTAssertEqual(Set(result.candidates.map { $0.message.guid }).count, 9)
    }

    // MARK: - Adaptive breadth hint

    func testBreadthHint_zero_saysTooNarrowBroaden() {
        let hint = NLAgent.breadthHint(count: 0, shown: 0)
        XCTAssertTrue(hint.contains("TOO NARROW"))
        XCTAssertTrue(hint.lowercased().contains("broaden"))
    }

    func testBreadthHint_huge_saysTooBroadNarrow() {
        let hint = NLAgent.breadthHint(count: 340, shown: 18)
        XCTAssertTrue(hint.contains("TOO BROAD"))
        XCTAssertTrue(hint.contains("NARROW"))
    }

    func testBreadthHint_healthy_saysGoodRange() {
        let hint = NLAgent.breadthHint(count: 12, shown: 12)
        XCTAssertTrue(hint.contains("Good range"))
    }

    func testBreadthHint_healthy_withOverflow_mentionsRemainder() {
        let hint = NLAgent.breadthHint(count: 60, shown: 18)
        XCTAssertTrue(hint.contains("42 more"))
    }

    // MARK: - Qwen3 think-block stripping

    func testStripThinkBlocks_removesClosedBlockAndParses() throws {
        let raw = "<think>I should look up the top contacts first.</think>{\"tool\":\"topContacts\",\"args\":{\"limit\":5}}"
        let dec = try NLToolCallParser.parse(raw)
        guard case .tool(let call) = dec else { return XCTFail("expected tool") }
        XCTAssertEqual(call.tool, "topContacts")
    }

    func testStripThinkBlocks_removesUnclosedTrailingBlock() {
        // A think block with a stray brace inside, truncated (no closing
        // tag) — must not leave JSON for the scanner.
        let raw = "{\"answer\":\"done\",\"hero_index\":null}<think>now I wonder if {x"
        let stripped = NLToolCallParser.stripThinkBlocks(raw)
        XCTAssertFalse(stripped.contains("<think>"))
        XCTAssertTrue(stripped.contains("\"answer\""))
    }

    func testStripThinkBlocks_thinkBeforeJSON_doesNotLeakBraces() throws {
        // The exact failure shape: reasoning prose containing { } then the
        // real call. Stripping must yield the real tool call, not a partial.
        let raw = "<think>maybe i call {\"tool\":\"wrong\"}</think>\n{\"answer\":\"You texted Sarah most.\",\"hero_index\":null,\"evidence_indices\":[]}"
        let dec = try NLToolCallParser.parse(raw)
        guard case .final(let f) = dec else { return XCTFail("expected final") }
        XCTAssertEqual(f.answer, "You texted Sarah most.")
    }

    // MARK: - Duplicate-call hardening + honest degradation (Codex #2.1/#2.2)

    /// The model loops the SAME tool call and NEVER answers (even when forced).
    /// New contract (Codex #2): on a duplicate call we force a final-answer-only
    /// turn; if the model STILL refuses to answer, the synthesis fallback turns
    /// the gathered topContacts data into a usable answer — but that answer is
    /// flagged `degradedToFallback == true` (HONEST: the MODEL never produced
    /// it). The loop must stop quickly (not burn all 8 iterations). This is the
    /// "who did I text the most" ×8 failure, now handled honestly.
    func testReAct_duplicateCall_forcesFinalThenSynthesizesHonestly() async {
        let tools = MockTools()
        let contacts = [
            makeContactStat("Sarah", sent: 623, received: 617),
            makeContactStat("Mom", sent: 200, received: 180),
        ]
        tools.state.withLock { $0.cannedTopContacts = contacts }
        // Model emits the SAME topContacts call forever, never a final answer —
        // not even on the forced final-answer turn.
        let identical = #"{"tool":"topContacts","args":{"in":"2026-01-01..2026-12-31","limit":5}}"#
        let runtime = ScriptedRuntime(outputs: Array(repeating: identical, count: 8))
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "who did i text the most this year")

        // turn1: exec topContacts. turn2: duplicate → force-final, continue.
        // turn3: forced final-answer turn (still a tool call) → stop. ≤3 calls.
        XCTAssertLessThanOrEqual(runtime.callCount, 3,
            "duplicate-call hardening should force a final-answer turn then stop, not loop to the cap (got \(runtime.callCount))")
        // Synthesis still produces a usable answer from gathered data…
        XCTAssertNotNil(result.explanation)
        XCTAssertTrue(result.explanation?.contains("Sarah") ?? false,
            "synthesized answer should name the top contact — got: \(result.explanation ?? "nil")")
        // …but it is HONESTLY flagged degraded, because the model never emitted
        // a real final answer (Codex #2.2 — the old code lied with false here).
        XCTAssertTrue(result.degradedToFallback,
            "a synthesized fallback answer must report degradedToFallback == true (model never answered)")
    }

    /// On a duplicate call we force a final-answer-only turn. When the model
    /// ACTUALLY answers on that forced turn, the result is NOT degraded (the
    /// model produced a real answer) — and we stop without burning iterations.
    func testReAct_duplicateCall_forcedTurnAnswers_notDegraded() async {
        let tools = MockTools()
        let sarah = makeContactStat("Sarah", sent: 10, received: 10)
        tools.state.withLock {
            $0.cannedTopContacts = [sarah]
        }
        let dup = #"{"tool":"topContacts","args":{"limit":5}}"#
        let runtime = ScriptedRuntime(outputs: [
            dup,   // turn 1: execute topContacts
            dup,   // turn 2: duplicate → force final-answer-only turn
            // turn 3 (forced): the model answers properly this time.
            #"{"answer":"You texted Sarah the most.","hero_index":null,"evidence_indices":[]}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "who did i text the most")

        XCTAssertEqual(runtime.callCount, 3,
            "should run: exec, duplicate-detect, forced answer")
        XCTAssertEqual(result.explanation, "You texted Sarah the most.")
        XCTAssertFalse(result.degradedToFallback,
            "model answered on the forced turn → not degraded")
    }

    /// The answer-after-N-reads cap (Codex #2.4): a model that keeps READING
    /// (search/readMessages) past the cap without answering is forced to answer.
    func testReAct_readCap_forcesFinalAnswer() async {
        let tools = MockTools()
        // Distinct search calls so the duplicate breaker does NOT fire — we want
        // the READ-CAP to be what forces the final answer.
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"search","args":{"query":"a","limit":10}}"#,
            #"{"tool":"search","args":{"query":"b","limit":10}}"#,
            #"{"tool":"search","args":{"query":"c","limit":10}}"#,  // 3rd read → hits cap
            // turn 4 is the forced final-answer turn; model answers.
            #"{"answer":"Here is the answer.","hero_index":null,"evidence_indices":[]}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "search a lot")

        // 3 reads + 1 forced answer = 4 calls; must not run to the cap of 8.
        XCTAssertEqual(runtime.callCount, 4,
            "after 3 reads the loop should force the final-answer turn (got \(runtime.callCount))")
        XCTAssertEqual(result.explanation, "Here is the answer.")
        XCTAssertFalse(result.degradedToFallback)
    }

    func testSynthesizeFallback_topContacts() {
        let contacts = [
            makeContactStat("Sarah", sent: 600, received: 600),
            makeContactStat("Mom", sent: 100, received: 100),
        ]
        let ans = NLAgent.synthesizeFallbackAnswer(contacts: contacts, candidates: [])
        XCTAssertNotNil(ans)
        XCTAssertTrue(ans!.answer.contains("Sarah"))
        XCTAssertTrue(ans!.answer.contains("1200"))
        XCTAssertEqual(ans!.contactIndex, 0)
    }

    func testSynthesizeFallback_emptyData_returnsNil() {
        XCTAssertNil(NLAgent.synthesizeFallbackAnswer(contacts: [], candidates: []))
    }

    // MARK: - Date arg resolution

    func testResolveDateArg_acceptsTimeWindowVocabulary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let range = NLAgent.resolveDateArg(["in": .string("last_7d")], now: now)
        XCTAssertNotNil(range)
        XCTAssertEqual(range!.upperBound, now)
        XCTAssertEqual(range!.lowerBound.timeIntervalSince(now), -7 * 86400, accuracy: 86400)
    }

    func testResolveDateArg_acceptsExplicitISORange() {
        let now = Date()
        let range = NLAgent.resolveDateArg(
            ["in": .string("2026-01-01..2026-12-31")],
            now: now
        )
        XCTAssertNotNil(range)
        // Date-only bounds anchor to the LOCAL calendar day (Calendar.current),
        // not UTC: low → 00:00 Jan 1, high → 23:59:59 Dec 31. This matches the
        // `on:`/`before:`/`after:` operators and the UI.
        let cal = Calendar.current
        let jan1 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let dec31Start = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let dec31End = cal.date(byAdding: .day, value: 1, to: dec31Start)!.addingTimeInterval(-1)
        XCTAssertEqual(range!.lowerBound, jan1)
        XCTAssertEqual(range!.upperBound, dec31End)
    }

    /// A bare single date resolves to the whole LOCAL calendar day — the core
    /// of the "make timezone current not UTC" fix. "on june 14" must mean the
    /// user's June 14 (Calendar.current), not the UTC June 14 that
    /// `parseISODate` would anchor a date-only string to.
    func testResolveDateArg_singleDate_anchorsToLocalDay() {
        let now = Date()
        let range = NLAgent.resolveDateArg(["in": .string("2026-06-14")], now: now)
        XCTAssertNotNil(range)
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 14))!
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        XCTAssertEqual(range!.lowerBound, start)
        XCTAssertEqual(range!.upperBound, end)
        // On any non-UTC machine the local anchor differs from the UTC anchor
        // that parseISODate produces for a date-only string — assert we moved
        // off UTC.
        if cal.timeZone.secondsFromGMT(for: start) != 0 {
            XCTAssertNotEqual(range!.lowerBound, NLAgent.parseISODate("2026-06-14"))
        }
    }

    func testResolveDateArg_nullOrAllTime_returnsNil() {
        let now = Date()
        XCTAssertNil(NLAgent.resolveDateArg(["in": .string("all_time")], now: now))
        XCTAssertNil(NLAgent.resolveDateArg(["in": .string("null")], now: now))
        XCTAssertNil(NLAgent.resolveDateArg([:], now: now))
    }

    // MARK: - operatorCorrection — unknown operators

    /// A snake_case fake operator (`message_type:`, `from_me:`) must be flagged.
    /// The unknown-operator check used to require an all-LETTERS key, so an
    /// underscore exempted these → they slipped through as free text and
    /// silently matched nothing. (Surfaced by the QuerySpec emission probe,
    /// which had the 4B emit `message_type:sticker`.)
    func testOperatorCorrection_flagsUnderscoreFakeOperator() {
        let now = Date()
        let c1 = NLAgent.operatorCorrection(for: "message_type:sticker", now: now)
        XCTAssertNotNil(c1, "message_type: should be flagged as an unknown operator")
        XCTAssertTrue(c1?.contains("message_type:") ?? false)
        XCTAssertNotNil(NLAgent.operatorCorrection(for: "from_me:", now: now),
                        "from_me: should be flagged too")
    }

    /// A fully valid operator query must NOT be flagged (no false positives
    /// from widening the key charset).
    func testOperatorCorrection_validQueryNotFlagged() {
        XCTAssertNil(NLAgent.operatorCorrection(for: "from:me type:image", now: Date()))
    }

    /// A clock time isn't an operator — its key ("8") is neither a letter nor
    /// an underscore, so widening the charset must not start catching times.
    func testOperatorCorrection_timeTokenNotFlagged() {
        XCTAssertNil(NLAgent.operatorCorrection(for: "meeting at 8:30", now: Date()),
                     "a time like 8:30 must not be flagged as an operator")
    }

    // MARK: - ReAct loop — happy paths

    /// "who did I text the most in 2026" — one tool call, then a final answer.
    func testReAct_topContactsThenFinalAnswer() async {
        let tools = MockTools()
        let cannedContacts = [
            makeContactStat("Sarah", sent: 623, received: 617),
            makeContactStat("Mom", sent: 200, received: 180),
        ]
        tools.state.withLock { st in
            st.cannedTopContacts = cannedContacts
        }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"topContacts","args":{"in":"2026-01-01..2026-12-31","limit":5}}"#,
            #"{"answer":"You texted Sarah the most in 2026 — 1240 messages total.","hero_index":null}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "who did I text the most in 2026")

        XCTAssertEqual(runtime.callCount, 2)
        let calls = tools.state.withLock { $0.topContactsCalls }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.limit, 5)
        XCTAssertEqual(result.explanation, "You texted Sarah the most in 2026 — 1240 messages total.")
        XCTAssertFalse(result.degradedToFallback)
    }

    /// "what plans did we make about vegas" — one search call, then a final.
    func testReAct_searchThenFinalAnswer() async {
        let tools = MockTools()
        let canned = makeResult(guid: "vegas1", body: "Let's book the trip", sender: "Sarah")
        tools.state.withLock { $0.cannedSearch = [canned] }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"search","args":{"query":"vegas","in":"all_time","limit":15}}"#,
            #"{"answer":"You talked about Vegas across 1 message.","hero_index":0}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "what plans did we make about vegas")

        XCTAssertEqual(runtime.callCount, 2)
        XCTAssertEqual(result.hero?.message.guid, "vegas1")
        XCTAssertEqual(result.explanation, "You talked about Vegas across 1 message.")
    }

    /// "how many photos did I send last month" — countMatching, then final.
    func testReAct_countMatchingThenFinalAnswer() async {
        let tools = MockTools()
        tools.state.withLock { $0.cannedCount = 14 }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"countMatching","args":{"query":"from:me type:image last:30d","in":"last_30d"}}"#,
            #"{"answer":"You sent 14 photos in the last 30 days.","hero_index":null}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "how many photos did I send last month")

        let counts = tools.state.withLock { $0.countCalls }
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.first?.query, "from:me type:image last:30d")
        XCTAssertEqual(result.explanation, "You sent 14 photos in the last 30 days.")
    }

    /// Multi-turn: argument cluster start. Search → messagesAroundTime → final.
    func testReAct_multiTurn_argumentCluster() async {
        let tools = MockTools()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let candidate = makeResult(
            guid: "argA",
            body: "I can't believe you did that",
            sender: "Shreya",
            date: now.addingTimeInterval(-21 * 86400)
        )
        let beforeMsg = makeResult(guid: "before1", body: "How was your day?", sender: "Shreya",
                                   date: now.addingTimeInterval(-21 * 86400 - 600))
        let afterMsg = makeResult(guid: "after1", body: "Why are you upset?", sender: "Me",
                                  date: now.addingTimeInterval(-21 * 86400 + 600))
        tools.state.withLock { st in
            st.cannedSearch = [candidate]
            st.cannedAroundTime = [beforeMsg, candidate, afterMsg]
        }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"search","args":{"query":"with:\"Shreya\" last:35d argument|fight|upset","in":"last_30d","limit":20}}"#,
            #"{"tool":"messagesAroundTime","args":{"date":"2026-05-04","chat_id":null,"before":5,"after":5}}"#,
            #"{"answer":"The argument started around May 4 when Shreya said \"I can't believe you did that\".","hero_index":1}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "what was my argument with Shreya around 3 weeks ago", now: now)

        XCTAssertEqual(runtime.callCount, 3)
        let searches = tools.state.withLock { $0.searchCalls }
        XCTAssertEqual(searches.count, 1)
        XCTAssertTrue(searches.first?.query.contains("Shreya") ?? false)

        let arounds = tools.state.withLock { $0.aroundTimeCalls }
        XCTAssertEqual(arounds.count, 1)
        XCTAssertEqual(arounds.first?.before, 5)
        XCTAssertEqual(arounds.first?.after, 5)

        XCTAssertEqual(result.hero?.message.guid, "argA")
        XCTAssertNotNil(result.explanation)
    }

    // MARK: - ReAct loop — bounded iteration

    func testReAct_capsAtMaxIterations() async {
        let tools = MockTools()
        // The model never emits a final answer — just keeps requesting
        // topContacts forever.
        let runtime = ScriptedRuntime(outputs: Array(
            repeating: #"{"tool":"topContacts","args":{"limit":3}}"#,
            count: 20
        ))
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "loop forever?", maxIterations: 3)

        // 3 iterations, no final → degraded.
        XCTAssertLessThanOrEqual(runtime.callCount, 3)
        XCTAssertNil(result.explanation)
        XCTAssertTrue(result.degradedToFallback)
    }

    // MARK: - Error handling

    func testReAct_invalidToolCall_breaksGracefully() async {
        let tools = MockTools()
        let runtime = ScriptedRuntime(outputs: [
            "not parseable as JSON",
            // shouldn't get here
            #"{"answer":"never","hero_index":null}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "anything")
        // The loop stops on first parse failure.
        XCTAssertEqual(runtime.callCount, 1)
        XCTAssertTrue(result.degradedToFallback)
    }

    func testReAct_unknownTool_continuesLoop() async {
        let tools = MockTools()
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"nonsense","args":{}}"#,
            #"{"answer":"Recovered.","hero_index":null}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "test")
        XCTAssertEqual(runtime.callCount, 2)
        XCTAssertEqual(result.explanation, "Recovered.")
    }

    // MARK: - The scratchpad threads observations into prompts

    func testReAct_observationFlowsBackIntoSubsequentPrompts() async {
        let tools = MockTools()
        let sarah = makeContactStat("Sarah", sent: 10, received: 5)
        tools.state.withLock {
            $0.cannedTopContacts = [sarah]
        }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"topContacts","args":{"limit":3}}"#,
            #"{"answer":"Sarah leads.","hero_index":null}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        _ = await agent.answerWithToolLoop(userQuery: "who's #1")

        // The second prompt should contain "Sarah" — it was observed in turn 1.
        let prompts = runtime.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[0].contains("Sarah"), "first prompt has no observation yet")
        XCTAssertTrue(prompts[1].contains("Sarah"), "second prompt must include the observation")
    }

    // MARK: - Mission 1: investigative read → narrow → answer pattern

    /// The canonical Mission 1 test. "Find my argument with Annika 3 weeks
    /// ago" — the model should:
    /// 1. Call `readMessages(with: "Annika", in: "last_30d")` to scan
    ///    the conversation
    /// 2. Read the observation, identify the candidate timestamp + chat_id
    ///    where tone shifts (May 5, chat_id=42)
    /// 3. Call `messagesAroundTime(date: "2026-05-05", chat_id: 42)` to
    ///    zoom in
    /// 4. Emit a final answer with `hero_index` pointing into the
    ///    around-time result list at the start of the cluster
    func testReAct_argumentInvestigation_iterativeReadNarrowAnswer() async {
        let tools = MockTools()
        // Fixed "now" so the date-window args resolve deterministically.
        let now = Date(timeIntervalSince1970: 1_716_700_800) // 2024-05-26

        let chatID: Int64 = 42

        // Phase 1: 7 messages in the last 30 days with Annika, chronological
        // The argument starts at index 2 (May 5, "I can't believe...").
        let m100 = makeResult(id: 100, guid: "m100", body: "How was your day? :)",
                              sender: "Annika", date: now.addingTimeInterval(-22 * 86400),
                              chatRowID: chatID)
        let m101 = makeResult(id: 101, guid: "m101", body: "Good — finishing the deck",
                              sender: "Annika", date: now.addingTimeInterval(-22 * 86400 + 1000),
                              chatRowID: chatID, isFromMe: true, partner: "Annika")
        let m102 = makeResult(id: 102, guid: "m102",
                              body: "I can't believe you forgot AGAIN. This is the third time.",
                              sender: "Annika", date: now.addingTimeInterval(-21 * 86400),
                              chatRowID: chatID)
        let m103 = makeResult(id: 103, guid: "m103", body: "I'm sorry — back to back meetings",
                              sender: "Annika", date: now.addingTimeInterval(-21 * 86400 + 200),
                              chatRowID: chatID, isFromMe: true, partner: "Annika")
        let m104 = makeResult(id: 104, guid: "m104",
                              body: "You always say that and nothing ever changes",
                              sender: "Annika", date: now.addingTimeInterval(-21 * 86400 + 400),
                              chatRowID: chatID)
        let m105 = makeResult(id: 105, guid: "m105", body: "Let me make it up to you tonight",
                              sender: "Annika", date: now.addingTimeInterval(-20 * 86400),
                              chatRowID: chatID, isFromMe: true, partner: "Annika")
        let m106 = makeResult(id: 106, guid: "m106", body: "Fine. 8pm.",
                              sender: "Annika", date: now.addingTimeInterval(-19 * 86400),
                              chatRowID: chatID)
        let readWindow: [MessageSearch.Result] = [m100, m101, m102, m103, m104, m105, m106]
        // Phase 2: zoom into the cluster start. messagesAroundTime returns
        // a focused slice of ~5 messages, the canonical "around the argument"
        // window.
        let aroundCluster: [MessageSearch.Result] = [m101, m102, m103, m104, m105]

        tools.state.withLock { st in
            st.cannedReadMessages = readWindow
            st.cannedAroundTime = aroundCluster
        }

        // Scripted runtime emits: readMessages → messagesAroundTime →
        // final answer. The model picks heroIndex=1 because that's where
        // the argument starts in the around-time result list.
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"readMessages","args":{"with":"Annika","in":"last_30d","limit":25}}"#,
            #"{"tool":"messagesAroundTime","args":{"date":"2024-05-05","chat_id":42,"before":3,"after":10}}"#,
            #"{"answer":"The argument started around May 5 — Annika said \"I can't believe you forgot AGAIN. This is the third time.\" The exchange continued for two days.","hero_index":1}"#,
        ])

        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "find my argument with Annika 3 weeks ago", now: now)

        // Tool order assertions — the canonical iterative pattern.
        XCTAssertEqual(runtime.callCount, 3, "should be readMessages → messagesAroundTime → final")
        let reads = tools.state.withLock { $0.readMessagesCalls }
        XCTAssertEqual(reads.count, 1, "readMessages called once")
        XCTAssertEqual(reads.first?.person, "Annika")
        XCTAssertNotNil(reads.first?.range, "should pass last_30d range")
        let arounds = tools.state.withLock { $0.aroundTimeCalls }
        XCTAssertEqual(arounds.count, 1, "messagesAroundTime called once")
        XCTAssertEqual(arounds.first?.chat, 42, "chat_id forwarded correctly")

        // The hero should be the start-of-argument message (index 1 in
        // the around-cluster result list, which is m102 — the actual
        // first angry message).
        XCTAssertEqual(result.hero?.message.guid, "m102",
                       "hero should point at the start of the argument")
        XCTAssertNotNil(result.explanation)
        XCTAssertFalse(result.degradedToFallback)

        // The observation must contain enough context for Qwen to identify
        // the cluster start. Assertion: the readMessages observation in
        // the second prompt contains the FULL body of the candidate
        // (not just a 80-char prefix).
        let prompts = runtime.prompts
        XCTAssertGreaterThanOrEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("I can't believe you forgot AGAIN"),
                      "the full body must be in the observation, not just a preview")
        XCTAssertTrue(prompts[1].contains("chat_id=42"),
                      "chat_id must be in the observation so the model can pass it to messagesAroundTime")
        XCTAssertTrue(prompts[1].contains("Annika"),
                      "the sender name must be in the observation")
    }

    /// Iteration cap is 8. Verify the default kicks in. NOTE: the calls
    /// must be DISTINCT — the repeat-call breaker (added 2026-06-02) stops
    /// the loop the moment it sees two identical calls back-to-back, so a
    /// constant-call stream would halt at 2. We vary `limit` per turn so
    /// every signature differs and the loop runs to the real cap.
    func testReAct_defaultIterationCap_is8() async {
        let tools = MockTools()
        // 20 DISTINCT tool calls, none a final answer. Distinct args dodge
        // the repeat-breaker so the iteration cap is what bounds the loop.
        let outputs = (1...20).map { #"{"tool":"topContacts","args":{"limit":\#($0)}}"# }
        let runtime = ScriptedRuntime(outputs: outputs)
        let agent = NLAgent(runtime: runtime, tools: tools)
        _ = await agent.answerWithToolLoop(userQuery: "loop forever?")
        XCTAssertEqual(runtime.callCount, 8, "default maxIterations is now 8")
    }

    /// Verify the observation row formatter actually surfaces a 300+ char
    /// body, the chat name, and chat_id. This pins the contract the model
    /// depends on.
    func testFormatResultLine_includesFullBodyAndContext() {
        let longBody = String(repeating: "I can't believe you did that. ", count: 20)
        let r = makeResult(
            id: 99, guid: "g99", body: longBody, sender: "Annika",
            date: Date(timeIntervalSince1970: 1_716_700_800),
            chatRowID: 42,
            isFromMe: false,
            partner: "Annika"
        )
        let line = NLAgent.formatResultLine(index: 0, result: r)
        // 350-char body limit means the long body must be present
        // substantially (not 80-char truncated).
        XCTAssertTrue(line.count > 200, "observation line must be more than the old 80-char preview")
        XCTAssertTrue(line.contains("chat=\"Annika\""), "chat name in observation")
        XCTAssertTrue(line.contains("chat_id=42"), "chat_id in observation")
        XCTAssertTrue(line.contains("[0]"), "index in observation")
        XCTAssertTrue(line.contains("2024"), "human-readable timestamp with year")
        XCTAssertTrue(line.contains("(2024-"), "ISO date for messagesAroundTime")
        XCTAssertTrue(line.contains("Annika"), "sender in observation")
        // Body is preserved up to the 350-char cap.
        XCTAssertTrue(line.contains("I can't believe you did that"))
    }

    /// readMessages observation should include all rows with full bodies
    /// and pass the date range through. Tests the new tool dispatch.
    func testReAct_readMessages_dispatchAndObservation() async {
        let tools = MockTools()
        let now = Date(timeIntervalSince1970: 1_716_700_800)
        let cannedMsg = makeResult(id: 200, guid: "r200",
                                    body: "long enough body that should be in the obs",
                                    sender: "Bob",
                                    date: now.addingTimeInterval(-10 * 86400),
                                    chatRowID: 7)
        tools.state.withLock { st in
            st.cannedReadMessages = [cannedMsg]
        }
        let runtime = ScriptedRuntime(outputs: [
            #"{"tool":"readMessages","args":{"with":"Bob","in":"last_14d","limit":10}}"#,
            #"{"answer":"Read.","hero_index":0}"#,
        ])
        let agent = NLAgent(runtime: runtime, tools: tools)
        let result = await agent.answerWithToolLoop(userQuery: "read with bob", now: now)

        let calls = tools.state.withLock { $0.readMessagesCalls }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.person, "Bob")
        XCTAssertEqual(calls.first?.limit, 10)
        XCTAssertNotNil(calls.first?.range)

        XCTAssertEqual(result.hero?.message.guid, "r200")
        XCTAssertEqual(result.explanation, "Read.")

        // The observation must include the full body and chat context.
        let prompts = runtime.prompts
        XCTAssertGreaterThanOrEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("long enough body that should be in the obs"))
        XCTAssertTrue(prompts[1].contains("chat_id=7"))
    }
}
