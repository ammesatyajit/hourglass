//
//  NLAgentReAct.swift
//  Hourglass — Natural-language search
//
//  ReAct-style tool-using loop for the NL agent. Lives alongside the
//  existing one-shot `NLAgent.answer(...)` path; the view model picks
//  which loop to drive based on the runtime (the stub stays on the legacy
//  plan-JSON path so canned demos keep working; MLX-backed real models
//  drive the tool loop).
//
//  Why ReAct over one-shot plan-JSON
//  ---------------------------------
//  The legacy `PlanJSON` planner emits a single structured plan, which the
//  agent then executes verbatim. That works for "find me X" queries but
//  fails for compositional ones: "what was my argument with Annika 3 weeks
//  ago" needs the model to (1) search a wide window, then (2) decide which
//  cluster is the argument, then (3) fetch context around the start. A
//  one-shot planner has to make all three decisions blind. The ReAct loop
//  lets the model see intermediate results before committing to the next
//  step.
//
//  Loop contract
//  -------------
//  1. The LLM emits ONE tool call as JSON: `{"tool": "...", "args": {...}}`.
//     OR a final answer: `{"answer": "...", "hero_index": <int|null>}`.
//  2. The agent runs the tool, formats the result as a short text summary,
//     and feeds it back in the next turn (appended to the user prompt).
//  3. Bounded at `maxIterations` (default 5) so we don't pay unbounded
//     LLM latency. If the model still hasn't emitted a final answer at
//     the cap, we synthesize one from the last tool result.
//  4. Every iteration is logged so we can trace the model's thinking.
//
//  Why this file and not extending NLAgent.swift directly
//  ------------------------------------------------------
//  NLAgent.swift is ~660 lines already. The ReAct surface is its own
//  ~300-line concern (system prompt, tool-call decoder, observation
//  formatter, hero picker). Keeping it separate is the simplest way to
//  ship without making the file hard to navigate.
//

import Foundation
import os

private let reactLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-agent-react"
)

// MARK: - Tool-call JSON

/// A single tool call the LLM emits. Mirrors the OpenAI / Anthropic
/// "function calling" shape but kept JSON-decodable by hand so we don't
/// depend on any provider-specific SDK.
struct NLToolCall: Sendable, Equatable {
    /// One of the tool names listed in `NLAgentReAct.toolCatalog`.
    let tool: String
    /// Free-form argument dictionary. Decoded leniently — unknown keys
    /// ignored, missing keys default per-tool.
    let args: [String: NLToolArg]
}

/// A typed argument value. We only need strings, ints, and bools.
enum NLToolArg: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    var asString: String? {
        if case .string(let s) = self { return s }
        if case .int(let i) = self { return String(i) }
        if case .bool(let b) = self { return String(b) }
        return nil
    }
    var asInt: Int? {
        if case .int(let i) = self { return i }
        if case .string(let s) = self { return Int(s) }
        return nil
    }
    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        if case .string(let s) = self { return Bool(s.lowercased()) }
        return nil
    }
}

/// The LLM's terminal "I'm done" output.
struct NLFinalAnswer: Sendable, Equatable {
    /// Natural-language answer text, surfaced verbatim in the trace.
    let answer: String
    /// Optional pointer into the most recent candidate list to mark as
    /// hero. Nil means "no hero, just text".
    let heroIndex: Int?
    /// Optional list index of a CONTACT result the model wants to anchor
    /// (e.g. top-contacts result row 0). UI displays this as the answer's
    /// supporting evidence.
    let contactIndex: Int?
}

// MARK: - Parser

/// Recovers a tool call or final answer from a raw LLM string. Same
/// brace-scanning approach as `PlanJSONParser` so messy prefaces /
/// fences don't kill the parse.
enum NLToolCallParser {

    enum ParseError: Error, CustomStringConvertible, Sendable {
        case noJSONObjectFound
        case decodeFailed(String)
        public var description: String {
            switch self {
            case .noJSONObjectFound: return "No JSON object found in LLM output."
            case .decodeFailed(let u): return "Failed to decode tool-call: \(u)"
            }
        }
    }

    /// Decode the first `{ ... }` object in `raw` as EITHER a tool call
    /// or a final answer. Returns `.tool(call)` or `.final(answer)`.
    static func parse(_ raw: String) throws -> Decoded {
        guard let slice = PlanJSONParser.extractFirstJSONObject(from: raw) else {
            throw ParseError.noJSONObjectFound
        }
        guard let data = slice.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.decodeFailed("not a JSON object")
        }
        // Terminal shape: { "answer": "...", "hero_index": N }
        if let answer = json["answer"] as? String {
            let hero = json["hero_index"] as? Int
            let contact = json["contact_index"] as? Int
            return .final(NLFinalAnswer(answer: answer, heroIndex: hero, contactIndex: contact))
        }
        // Tool-call shape: { "tool": "...", "args": {...} }
        guard let tool = json["tool"] as? String else {
            throw ParseError.decodeFailed("missing 'tool' or 'answer' field")
        }
        let rawArgs = json["args"] as? [String: Any] ?? [:]
        var args: [String: NLToolArg] = [:]
        for (k, v) in rawArgs {
            if let s = v as? String { args[k] = .string(s) }
            else if let i = v as? Int { args[k] = .int(i) }
            else if let b = v as? Bool { args[k] = .bool(b) }
            else if v is NSNull { args[k] = .null }
            else if let d = v as? Double { args[k] = .int(Int(d)) }
            else { args[k] = .string(String(describing: v)) }
        }
        return .tool(NLToolCall(tool: tool, args: args))
    }

    enum Decoded: Sendable, Equatable {
        case tool(NLToolCall)
        case final(NLFinalAnswer)
    }
}

// MARK: - The loop

public extension NLAgent {

    /// ReAct-style answer loop. The model emits tool calls; the agent
    /// runs them, feeds back observations, and waits for a final answer.
    ///
    /// Bounded at `maxIterations` tool calls. If the cap is hit without
    /// a final answer, we synthesize one from the last observation.
    ///
    /// `now` is injected for testability — same convention as `answer`.
    func answerWithToolLoop(
        userQuery: String,
        now: Date = Date(),
        maxIterations: Int = 8,
        maxCandidates: Int = 50
    ) async -> NLQueryResult {
        var trace: [NLTraceStep] = []
        let startAll = Date()

        let planningStep = NLTraceStep(
            phase: .planning,
            label: "Picking a tool…",
            status: .inProgress
        )
        trace.append(planningStep)

        // Build the user prompt that includes both the question AND a
        // "scratchpad" of prior observations. The model sees the full
        // observation history each turn so it can reason across calls.
        var scratchpad: String = ""
        var lastCandidates: [MessageSearch.Result] = []
        var lastContacts: [DashboardStats.ContactStat] = []
        var iterations = 0

        // Heroless degraded answer the loop falls back to if the model
        // never emits anything parseable.
        var degraded = true
        var finalAnswer: NLFinalAnswer? = nil

        reactLogger.info("react: query=\"\(userQuery, privacy: .public)\"")

        loop: while iterations < maxIterations {
            iterations += 1
            let iterStart = Date()

            let userPrompt = Self.buildReActUserPrompt(
                question: userQuery,
                now: now,
                scratchpad: scratchpad
            )
            let raw: String
            do {
                raw = try await runtime.respond(
                    systemPrompt: Self.toolLoopSystemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: 320
                )
            } catch {
                reactLogger.error("react: runtime threw at iter=\(iterations, privacy: .public): \(String(describing: error), privacy: .public)")
                break
            }
            reactLogger.info("react: iter=\(iterations, privacy: .public) raw (\(raw.count, privacy: .public) chars): \(raw, privacy: .public)")

            let decoded: NLToolCallParser.Decoded
            do {
                decoded = try NLToolCallParser.parse(raw)
            } catch {
                reactLogger.notice("react: iter=\(iterations, privacy: .public) parse FAILED — \(String(describing: error), privacy: .public)")
                // Drop the bad turn from the scratchpad — don't poison
                // future turns with malformed model output.
                break
            }

            switch decoded {
            case .final(let answer):
                finalAnswer = answer
                degraded = false
                reactLogger.info("react: final answer at iter=\(iterations, privacy: .public)")
                trace.append(NLTraceStep(
                    phase: .answering,
                    label: "Final: \(answer.answer.prefix(80))",
                    status: .complete,
                    duration: Date().timeIntervalSince(iterStart)
                ))
                break loop

            case .tool(let call):
                trace.append(NLTraceStep(
                    phase: .searching,
                    label: "Tool: \(call.tool) (\(Self.summarizeArgs(call.args)))",
                    status: .inProgress
                ))
                // Execute the tool and append the observation to the
                // scratchpad. We always observe (even on tool error) so
                // the model can see what went wrong and adapt.
                let observation = await executeReActTool(
                    call: call,
                    now: now,
                    maxCandidates: maxCandidates,
                    lastCandidates: &lastCandidates,
                    lastContacts: &lastContacts
                )
                trace[trace.count - 1] = NLTraceStep(
                    id: trace[trace.count - 1].id,
                    phase: .searching,
                    label: "Tool: \(call.tool) → \(observation.summary)",
                    status: observation.failed ? .failed : .complete,
                    duration: Date().timeIntervalSince(iterStart)
                )
                scratchpad += """

                Step \(iterations): \(call.tool)(\(Self.summarizeArgs(call.args)))
                Observation: \(observation.observation)
                """
                reactLogger.info("react: iter=\(iterations, privacy: .public) observation: \(observation.observation, privacy: .public)")
            }
        }

        // Mark the planning step complete now that the loop ended.
        trace[0] = NLTraceStep(
            id: planningStep.id,
            phase: .planning,
            label: "Used \(iterations) tool call\(iterations == 1 ? "" : "s")",
            status: .complete,
            duration: Date().timeIntervalSince(startAll)
        )

        // Pick the hero from whatever the model anchored. Default to the
        // first candidate the most recent search returned.
        var hero: MessageSearch.Result? = lastCandidates.first
        if let final = finalAnswer, let idx = final.heroIndex,
           idx >= 0, idx < lastCandidates.count {
            hero = lastCandidates[idx]
        }
        let explanation: String? = finalAnswer?.answer

        trace.append(NLTraceStep(
            phase: .answering,
            label: "Done in \(Self.formatDuration(Date().timeIntervalSince(startAll)))",
            status: .complete,
            duration: Date().timeIntervalSince(startAll)
        ))

        return NLQueryResult(
            hero: hero,
            candidates: Array(lastCandidates.prefix(maxCandidates)),
            trace: trace,
            plan: nil,
            fallbackQuery: userQuery,
            explanation: explanation,
            degradedToFallback: degraded && hero == nil
        )
    }

    // MARK: - Tool execution

    /// Result of one tool execution. `observation` is the short text the
    /// model sees in its next prompt; `summary` is the one-liner for the
    /// trace UI.
    internal struct ToolObservation: Sendable {
        let observation: String
        let summary: String
        let failed: Bool
    }

    /// Dispatch ONE tool call. Mutates `lastCandidates` / `lastContacts`
    /// so the loop can pick a hero / contact from the most recent result.
    internal func executeReActTool(
        call: NLToolCall,
        now: Date,
        maxCandidates: Int,
        lastCandidates: inout [MessageSearch.Result],
        lastContacts: inout [DashboardStats.ContactStat]
    ) async -> ToolObservation {
        let dateRange: ClosedRange<Date>? = Self.resolveDateArg(call.args, now: now)

        switch call.tool {
        case "search":
            let query = call.args["query"]?.asString ?? ""
            let limit = call.args["limit"]?.asInt ?? maxCandidates
            do {
                let results = try await tools.search(
                    query: query,
                    dateRange: dateRange,
                    limit: limit
                )
                lastCandidates = results
                // Show up to 6 results with full bodies — enough context
                // for the model to judge tone/relevance without blowing
                // the 1.5B context window.
                let preview = results.prefix(6).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                let obs = "Found \(results.count) match\(results.count == 1 ? "" : "es"). Showing top \(min(6, results.count)) with full bodies:\n\(preview)"
                return ToolObservation(
                    observation: obs,
                    summary: "\(results.count) match\(results.count == 1 ? "" : "es")",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "search failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "readMessages":
            // The "let me actually read" tool — chronological dump of N
            // messages with full bodies. Distinct from `search` which is
            // keyword-driven. Used by investigative queries where the
            // model needs to scan the conversation for tone/topic shifts.
            let personName = call.args["with"]?.asString ?? call.args["person"]?.asString
            let limit = call.args["limit"]?.asInt ?? 25
            do {
                let results = try await tools.readMessages(
                    in: dateRange,
                    with: personName,
                    limit: limit
                )
                lastCandidates = results
                // Show ALL results returned (capped at 30 to keep prompts
                // sane). With limit=20-30 and ~400 char obs lines this is
                // ~6-9k chars — within Qwen 1.5B's effective context.
                let displayCount = min(results.count, 30)
                let preview = results.prefix(displayCount).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                let scope = personName.map { "with \($0)" } ?? "(all chats)"
                let windowLabel = dateRange.map {
                    "\(NLAgent.formatISODate($0.lowerBound))..\(NLAgent.formatISODate($0.upperBound))"
                } ?? "all_time"
                let obs = "Read \(results.count) message\(results.count == 1 ? "" : "s") \(scope) in \(windowLabel) (chronological). Showing \(displayCount):\n\(preview)"
                return ToolObservation(
                    observation: obs,
                    summary: "\(results.count) msgs",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "readMessages failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "countMatching", "count":
            let query = call.args["query"]?.asString ?? ""
            do {
                let n = try await tools.countMatching(query: query, in: dateRange)
                return ToolObservation(
                    observation: "Count = \(n).",
                    summary: "n=\(n)",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "count failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "firstMatching", "oldestMatching":
            let query = call.args["query"]?.asString ?? ""
            do {
                let first = try await tools.firstMatching(query: query, in: dateRange)
                if let first {
                    lastCandidates = [first]
                    return ToolObservation(
                        observation: "First match:\n\(NLAgent.formatResultLine(index: 0, result: first))",
                        summary: "1 hit",
                        failed: false
                    )
                }
                return ToolObservation(
                    observation: "No match in window.",
                    summary: "none",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "firstMatching failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "topContacts":
            let limit = call.args["limit"]?.asInt ?? 5
            do {
                let stats = try await tools.topContacts(in: dateRange, limit: limit)
                lastContacts = stats
                let preview = stats.prefix(min(limit, 10)).enumerated().map { (i, s) in
                    "  [\(i)] \(s.displayName): \(s.total) total (\(s.sent) sent, \(s.received) received)"
                }.joined(separator: "\n")
                let obs = "Top \(stats.count) contact\(stats.count == 1 ? "" : "s"):\n\(preview)"
                return ToolObservation(
                    observation: obs,
                    summary: "\(stats.count) contacts",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "topContacts failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "topGroups":
            let limit = call.args["limit"]?.asInt ?? 5
            do {
                let stats = try await tools.topGroups(in: dateRange, limit: limit)
                let preview = stats.prefix(min(limit, 10)).enumerated().map { (i, s) in
                    "  [\(i)] \(s.displayName): \(s.sentByYou) sent / \(s.total) total"
                }.joined(separator: "\n")
                let obs = "Top \(stats.count) group\(stats.count == 1 ? "" : "s"):\n\(preview)"
                return ToolObservation(
                    observation: obs,
                    summary: "\(stats.count) groups",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "topGroups failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "overviewStats":
            do {
                let o = try await tools.overviewStats(in: dateRange)
                return ToolObservation(
                    observation: "Overview: total=\(o.total), sent=\(o.sent), received=\(o.received), chats=\(o.chats)",
                    summary: "total=\(o.total)",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "overviewStats failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "messagesAroundTime":
            let dateStr = call.args["date"]?.asString ?? ""
            let chatID = call.args["chat_id"]?.asInt.map(Int64.init)
            let before = call.args["before"]?.asInt ?? 5
            let after = call.args["after"]?.asInt ?? 5
            guard let parsedDate = NLAgent.parseISODate(dateStr) else {
                return ToolObservation(
                    observation: "messagesAroundTime: invalid date '\(dateStr)' — pass ISO 8601 (YYYY-MM-DD).",
                    summary: "bad date",
                    failed: true
                )
            }
            do {
                let results = try await tools.messagesAroundTime(
                    date: parsedDate,
                    chatRowID: chatID,
                    before: before,
                    after: after
                )
                lastCandidates = results
                let preview = results.prefix(20).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                return ToolObservation(
                    observation: "Context around \(NLAgent.formatDateTime(parsedDate)) (chat_id=\(chatID.map(String.init) ?? "any")):\n\(preview)",
                    summary: "\(results.count) msgs",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "messagesAroundTime failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "context":
            // Reuses the existing `context` tool — fetch around a GUID.
            let guid = call.args["guid"]?.asString ?? ""
            let before = call.args["before"]?.asInt ?? 5
            let after = call.args["after"]?.asInt ?? 5
            do {
                let results = try await tools.context(forGUID: guid, before: before, after: after)
                lastCandidates = results
                let preview = results.prefix(20).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                return ToolObservation(
                    observation: "Context for GUID \(guid):\n\(preview)",
                    summary: "\(results.count) msgs",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "context failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "rawSearchSQL":
            // LAST RESORT — the system prompt actively discourages it.
            let sql = call.args["sql"]?.asString ?? ""
            let limit = call.args["limit"]?.asInt ?? 20
            do {
                let rows = try await tools.rawSearchSQL(sql: sql, limit: limit)
                let preview = rows.prefix(5).enumerated().map { (i, r) in
                    "  [\(i)] " + r.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                }.joined(separator: "\n")
                return ToolObservation(
                    observation: "SQL returned \(rows.count) row\(rows.count == 1 ? "" : "s"):\n\(preview)",
                    summary: "\(rows.count) rows",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "rawSearchSQL failed: \(error). Try one of the higher-level tools instead.",
                    summary: "failed",
                    failed: true
                )
            }

        default:
            return ToolObservation(
                observation: "Unknown tool '\(call.tool)'. Available: search, readMessages, countMatching, firstMatching, topContacts, topGroups, overviewStats, messagesAroundTime, context, rawSearchSQL. Emit a final answer with {\"answer\": \"...\"} when done.",
                summary: "unknown",
                failed: true
            )
        }
    }

    // MARK: - System prompt + user-prompt assembly

    /// System prompt for the ReAct loop. Lists the tool catalog and the
    /// JSON shape the model must emit.
    ///
    /// Engineering notes:
    /// - One example per tool. 1.5B models follow examples more reliably
    ///   than schema descriptions.
    /// - The "raw SQL is a last resort" instruction is repeated twice
    ///   (once in the rules, once in the rawSearchSQL example) because
    ///   the temptation to fall back to SQL is strong.
    /// - The date-fuzzy guidance ("around 3 weeks ago" → wide window) is
    ///   front-loaded with concrete examples since this is the canonical
    ///   failure mode for one-shot planners.
    static var toolLoopSystemPrompt: String {
        """
        You answer questions about iMessage history by calling TOOLS. Output ONE JSON object per turn — NO prose, NO markdown fences. After each tool call you receive an observation; READ it carefully and use it to decide your next call. When you have the answer, output a FINAL JSON.

        Available tools (priority order):

        1) {"tool":"readMessages","args":{"with":"<name or null>","in":"<date-range>","limit":<int>}}
           Read a CHRONOLOGICAL dump of messages with a person in a window. Returns full message bodies. Use this FIRST for investigative queries — "what was my argument with X N weeks ago" — when you need to actually SCAN the conversation to identify where the argument starts. Limit 20-30 is plenty.

        2) {"tool":"search","args":{"query":"<operator-string>","in":"<date-range or null>","limit":<int>}}
           Run a structured KEYWORD search. Use this when you know specific terms to look for.
           Query operators: with:"Name" (any chat with person — 1:1 OR group), from:"Name" (sent by), in:"chat" (chat name substring), last:7d|14d|30d|3mo|1y, before:YYYY-MM-DD, after:YYYY-MM-DD, on:YYYY-MM-DD, type:image|video|audio|sticker|link|file, reactions:love|laugh|like|>=3, a+b (AND), a|b (OR), *substr* (substring).

        3) {"tool":"messagesAroundTime","args":{"date":"YYYY-MM-DDTHH:MM:SSZ","chat_id":<int or null>,"before":<int>,"after":<int>}}
           Fetch N messages immediately before + after a moment. Use this to ZOOM IN once you have a candidate timestamp + chat_id from a prior tool. The chat_id and the FULL ISO timestamp (with T and Z) come straight from the observation rows — copy them verbatim. Bare YYYY-MM-DD still works but anchors at midnight and misses afternoon/evening events.

        4) {"tool":"countMatching","args":{"query":"<string>","in":"<date-range or null>"}}
           Return ONLY the count. Use for "how many X did I send".

        5) {"tool":"firstMatching","args":{"query":"<string>","in":"<date-range or null>"}}
           Earliest match in a window. Use for "when did X first happen".

        6) {"tool":"topContacts","args":{"in":"<date-range or null>","limit":<int>}}
           People you texted the most. Returns name + sent + received + total.

        7) {"tool":"topGroups","args":{"in":"<date-range or null>","limit":<int>}}
           Group chats you texted the most.

        8) {"tool":"overviewStats","args":{"in":"<date-range or null>"}}
           Total / sent / received / chat-count for a window.

        9) {"tool":"context","args":{"guid":"<message-guid>","before":<int>,"after":<int>}}
           Like messagesAroundTime but anchored to a message GUID.

        10) {"tool":"rawSearchSQL","args":{"sql":"SELECT ...","limit":<int>}}
            LAST RESORT. ONLY if no other tool fits. Avoid this — treat as broken-glass.

        Date ranges (the "in" arg): pass a string like "last_7d", "last_14d", "last_30d", "last_3mo", "last_1y", "all_time", or explicit "YYYY-MM-DD..YYYY-MM-DD". For year scopes use "YYYY-01-01..YYYY-12-31".

        Observation rows contain timestamp, ISO date, chat name, chat_id, sender, and full body — read them carefully to decide the next move.

        Final answer shape (emit when done):
        {"answer":"<short natural-language answer>","hero_index":<index of best message in last result list, or null>}

        Rules:
        - For INVESTIGATIVE queries ("what was my argument with X", "when did we plan Y", "show me when X happened") use readMessages FIRST. Then read the observation, identify a candidate timestamp + chat_id where tone shifts or the topic appears, then call messagesAroundTime to zoom in. Then emit a final answer.
        - For STATS questions ("who/how-many/which") prefer topContacts / topGroups / countMatching / overviewStats.
        - For "around N weeks ago" use a WIDE date range (e.g. last_30d for "3 weeks ago"). Fuzzy human time needs slack.
        - You may call tools up to 8 times. End with a final-answer JSON.
        - NEVER call rawSearchSQL unless every other tool fails.
        - Output ONLY the JSON object. No prose.

        Examples:

        Q: who did I text the most in 2026
        Turn 1: {"tool":"topContacts","args":{"in":"2026-01-01..2026-12-31","limit":5}}
        Observation: Top 5 contacts: [0] Sarah: 1240 total (...) ...
        Turn 2: {"answer":"You texted Sarah the most in 2026 — 1240 messages total (623 sent, 617 received).","hero_index":null}

        Q: find my argument with Annika 3 weeks ago
        Turn 1: {"tool":"readMessages","args":{"with":"Annika","in":"last_30d","limit":25}}
        Observation: Read 18 messages with Annika in last_30d (chronological). Showing 18:
          [0] Sun May 4 2026 12:14 (2026-05-04T19:14:00Z) chat="Annika" chat_id=42 Annika: How was your day? :)
          [1] Sun May 4 2026 12:30 (2026-05-04T19:30:00Z) chat="Annika" chat_id=42 You: Good — just finishing up the deck
          [2] Mon May 5 2026 19:42 (2026-05-06T02:42:00Z) chat="Annika" chat_id=42 Annika: I can't believe you forgot AGAIN. This is the third time.
          [3] Mon May 5 2026 19:45 (2026-05-06T02:45:00Z) chat="Annika" chat_id=42 You: I'm sorry. I really am. I had back-to-back …
          [4] Mon May 5 2026 19:51 (2026-05-06T02:51:00Z) chat="Annika" chat_id=42 Annika: You always say that and nothing ever changes
          [5] Tue May 6 2026 08:12 (2026-05-06T15:12:00Z) chat="Annika" chat_id=42 You: I want to talk through this properly tonight
          [6] Wed May 7 2026 14:02 (2026-05-07T21:02:00Z) chat="Annika" chat_id=42 Annika: Fine. 8pm.
          ...
        Turn 2: {"tool":"messagesAroundTime","args":{"date":"2026-05-06T02:42:00Z","chat_id":42,"before":3,"after":10}}
        Observation: Context around Mon May 5 2026 19:42 (chat_id=42): ...
        Turn 3: {"answer":"The argument started on May 5 — Annika opened with \\"I can't believe you forgot AGAIN. This is the third time.\\" The exchange continued until May 7 when you agreed to talk it through.","hero_index":2}

        Q: how many photos did I send Mom last month
        Turn 1: {"tool":"countMatching","args":{"query":"from:me to:\\"Mom\\" type:image last:30d","in":"last_30d"}}
        Observation: Count = 14.
        Turn 2: {"answer":"You sent Mom 14 photos in the last 30 days.","hero_index":null}

        Q: what plans did we make about vegas
        Turn 1: {"tool":"search","args":{"query":"vegas","in":"all_time","limit":15}}
        Observation: Found 24 matches. Showing top 6 with full bodies: ...
        Turn 2: {"answer":"You talked about Vegas across 24 messages — see the top match.","hero_index":0}
        """
    }

    /// Compose the per-turn user prompt: the original question + the
    /// running scratchpad of prior observations.
    static func buildReActUserPrompt(
        question: String,
        now: Date,
        scratchpad: String
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)
        if scratchpad.isEmpty {
            return """
            Today's date: \(today)
            Question: \(question)

            Emit your first tool call as JSON.
            """
        }
        return """
        Today's date: \(today)
        Question: \(question)

        Prior tool calls:
        \(scratchpad)

        Emit your next tool call as JSON, OR a final answer if you have enough.
        """
    }

    /// Render a tool-args dict as a short label for the trace UI.
    internal static func summarizeArgs(_ args: [String: NLToolArg]) -> String {
        let interesting: [String] = ["query", "limit", "in", "date", "guid"]
        var parts: [String] = []
        for key in interesting {
            guard let v = args[key], let s = v.asString else { continue }
            let clipped = s.count > 40 ? String(s.prefix(40)) + "…" : s
            parts.append("\(key)=\(clipped)")
        }
        return parts.joined(separator: " ")
    }

    /// Parse the `in:` arg into a date range. Accepts the same window
    /// vocabulary as `PlanJSON.TimeWindow` plus explicit YYYY-MM-DD..YYYY-MM-DD.
    internal static func resolveDateArg(_ args: [String: NLToolArg], now: Date) -> ClosedRange<Date>? {
        guard let s = args["in"]?.asString else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "all_time" || trimmed.lowercased() == "null" {
            return nil
        }
        // Try the abstract window vocabulary first.
        if let window = PlanJSON.TimeWindow(rawValue: trimmed) {
            return window.toDateRange(now: now)
        }
        // Explicit range: "YYYY-MM-DD..YYYY-MM-DD" or "YYYY-MM-DD - YYYY-MM-DD".
        let parts = trimmed.components(separatedBy: "..")
        if parts.count == 2,
           let lo = NLAgent.parseISODate(parts[0].trimmingCharacters(in: .whitespaces)),
           let hi = NLAgent.parseISODate(parts[1].trimmingCharacters(in: .whitespaces)),
           lo <= hi {
            return lo...hi
        }
        return nil
    }

    /// Parse a date arg from the LLM. Accepts BOTH:
    ///   - `YYYY-MM-DD` (date only — anchors at UTC midnight, kept for
    ///     date-range args and backward compat with the early
    ///     `messagesAroundTime` schema)
    ///   - Full ISO 8601 `YYYY-MM-DDTHH:MM[:SS]Z|±HH:MM` (used by the
    ///     `messagesAroundTime` zoom path — codex audit H3 found that
    ///     anchoring at midnight made the tool miss afternoon/evening
    ///     events; the observation row now exposes the full timestamp so
    ///     the model can copy it back here).
    static func parseISODate(_ s: String) -> Date? {
        // Try full ISO 8601 with time first.
        let withTime = ISO8601DateFormatter()
        withTime.formatOptions = [.withInternetDateTime]
        if let d = withTime.date(from: s) { return d }
        // ISO 8601 with fractional seconds.
        withTime.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withTime.date(from: s) { return d }
        // Date-only fallback.
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        if let d = dateOnly.date(from: s) { return d }
        let alt = DateFormatter()
        alt.calendar = Calendar(identifier: .iso8601)
        alt.dateFormat = "yyyy-MM-dd"
        alt.timeZone = TimeZone(identifier: "UTC")
        return alt.date(from: s)
    }

    static func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: d)
    }

    /// Richer date-time formatter for ReAct observations — includes the
    /// year, day of week, and time. The model needs this granularity to
    /// reason about "3 weeks ago"-style time hints (and to feed the
    /// resulting `date:` arg into `messagesAroundTime` accurately).
    /// Example: "Sun May 4 2026 19:42".
    internal static func formatDateTime(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d yyyy HH:mm"
        return df.string(from: d)
    }

    /// ISO-8601 timestamp string for the `messagesAroundTime` `date:` arg.
    /// Emitted with full date AND time so the model can anchor the zoom
    /// on the EXACT message moment, not midnight of that day. Codex audit
    /// H3 (2026-05-25) found that date-only anchoring made the tool miss
    /// 19:42 events because it queried ±N messages around 00:00. Surfaced
    /// alongside the human-readable timestamp in each observation row so
    /// the model can copy-paste verbatim into the next tool call.
    internal static func formatISODate(_ d: Date) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        df.timeZone = TimeZone(identifier: "UTC")
        return df.string(from: d)
    }

    /// Format one message result into a single rich observation line for
    /// the model. Includes: index, timestamp (human + ISO), sender,
    /// chat name + chat_id, and the FULL body (truncated only past a
    /// generous limit so the model can identify tone/argument cues).
    ///
    /// Why this format
    /// ---------------
    /// The previous observation used 80-char body previews; that was the
    /// root cause of "can't decide if this is an argument" failures —
    /// the model literally couldn't see enough of the message to judge
    /// tone. We now ship up to 350 chars of body per row, plus the
    /// chat context the model needs to call `messagesAroundTime` with
    /// the right `chat_id`. Keeps the observation under ~500 chars per
    /// row, so 5-8 rows fits comfortably in a 1.5B-model context window.
    internal static func formatResultLine(
        index: Int,
        result: MessageSearch.Result,
        bodyChars: Int = 350
    ) -> String {
        let dt = formatDateTime(result.message.date)
        let iso = formatISODate(result.message.date)
        let chatRowID = result.message.chatRowID
        let chatName = result.partnerName.isEmpty ? "(unknown chat)" : result.partnerName
        let body = result.message.body
        let truncated: String
        if body.count > bodyChars {
            truncated = String(body.prefix(bodyChars)) + "…"
        } else {
            truncated = body
        }
        // Collapse newlines so a multi-line message stays one observation
        // row — the model parses better when each row is a single line.
        let oneLine = truncated
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "  [\(index)] \(dt) (\(iso)) chat=\"\(chatName)\" chat_id=\(chatRowID) \(result.senderName): \(oneLine)"
    }
}

// MARK: - Free functions for non-extension access in tests

/// Re-export of the ISO date parser for tests that need to round-trip
/// through `parseISODate` without entering the extension scope.
internal func nlAgentParseISODate(_ s: String) -> Date? {
    NLAgent.parseISODate(s)
}
