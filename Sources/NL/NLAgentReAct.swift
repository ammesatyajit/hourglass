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
    /// Indices into the most-recent candidate list the model chose as
    /// SUPPORTING EVIDENCE for its answer. The loop reorders candidates so
    /// these surface directly under the hero in the UI (the answer view
    /// shows hero + next 4). Empty when the model didn't cite specific
    /// messages — we then fall back to the natural search order.
    let evidenceIndices: [Int]

    init(answer: String, heroIndex: Int?, contactIndex: Int? = nil, evidenceIndices: [Int] = []) {
        self.answer = answer
        self.heroIndex = heroIndex
        self.contactIndex = contactIndex
        self.evidenceIndices = evidenceIndices
    }
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
        // Defensive: strip any Qwen3 `<think>…</think>` reasoning block
        // before scanning for JSON. We disable thinking at the template
        // level (`enable_thinking: false` in MLXRuntime), but if a block
        // ever leaks, its prose can contain stray `{`/`}` that would
        // confuse the brace scanner. Remove closed blocks AND a dangling
        // unclosed `<think>` (truncated by the token budget) up to EOS.
        let cleaned = Self.stripThinkBlocks(raw)
        guard let slice = PlanJSONParser.extractFirstJSONObject(from: cleaned) else {
            throw ParseError.noJSONObjectFound
        }
        guard let data = slice.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.decodeFailed("not a JSON object")
        }
        // Terminal shape: { "answer": "...", "hero_index": N,
        //                   "evidence_indices": [a, b, c] }
        if let answer = json["answer"] as? String {
            let hero = json["hero_index"] as? Int
            let contact = json["contact_index"] as? Int
            // `evidence_indices` is tolerant: accept an array of ints,
            // an array of numeric strings, or a single int. Small models
            // emit all three shapes.
            var evidence: [Int] = []
            if let arr = json["evidence_indices"] as? [Any] {
                for e in arr {
                    if let i = e as? Int { evidence.append(i) }
                    else if let d = e as? Double { evidence.append(Int(d)) }
                    else if let s = e as? String, let i = Int(s) { evidence.append(i) }
                }
            } else if let one = json["evidence_indices"] as? Int {
                evidence = [one]
            }
            return .final(NLFinalAnswer(
                answer: answer,
                heroIndex: hero,
                contactIndex: contact,
                evidenceIndices: evidence
            ))
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

    /// Remove `<think>…</think>` blocks (and a trailing unclosed `<think>`)
    /// from a raw model output. Case-insensitive on the tags. Cheap string
    /// scan — no regex, so a pathological block can't blow up.
    static func stripThinkBlocks(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<think>", options: .caseInsensitive) {
            if let close = s.range(of: "</think>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unclosed (truncated) — drop from the tag to the end.
                s.removeSubrange(open.lowerBound..<s.endIndex)
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // DETERMINISTIC FAST PATH — runs BEFORE the brittle ReAct loop. When
        // the query reads as a question scoped to a real PERSON (+ optional
        // timeframe) that resolves to an actual conversation, we resolve the
        // 1:1 directly (NEVER a group matched by display-name substring),
        // retrieve the window, and do ONE focused read-and-answer call. When
        // it doesn't apply, this returns nil and the existing loop runs
        // exactly as before — so keyword queries ("photos from June") never
        // regress. See `ScopedPersonQuery` / `answerScopedPersonQuestion`.
        if let scoped = await answerScopedPersonQuestion(userQuery: userQuery, now: now) {
            reactLogger.info("react: handled by deterministic scoped-person path (degraded=\(scoped.degradedToFallback, privacy: .public))")
            return scoped
        }

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

        // Repeat-call breaker. A small model can get stuck re-issuing the
        // SAME tool with the SAME args (observed: "who did I text the most"
        // called topContacts ×8, never answered, 83s wasted). We now track
        // EVERY call signature we've executed (not just the immediately
        // previous one) so a model that re-issues an earlier call after one
        // intervening call is also caught. On a duplicate we don't just break
        // and hope — we force a FINAL-ANSWER-ONLY synthesis turn (no tool
        // catalog) so the model actually answers from what it already saw.
        var executedSignatures = Set<String>()
        var repeatedCall = false

        // Read-cap: how many message-reading tool calls (search / readMessages)
        // we allow before forcing the model to answer. Investigative queries
        // should converge in 1-3 reads; beyond that the small model is usually
        // spinning, so we force the final-answer turn rather than burn all 8
        // iterations. Stats tools (topContacts etc.) don't count — they return
        // a complete answer in one shot and are handled by `answerNowHint`.
        var readToolCalls = 0
        let maxReadToolCalls = 3

        // Honest degradation tracking (Codex #2.2). `modelEmittedFinal` is the
        // SINGLE source of truth for "did the model actually answer": set true
        // ONLY when the MODEL emits a real, parseable final answer (on a normal
        // turn OR the forced final-answer turn). The post-loop synthesis
        // fallback (`synthesizeFallbackAnswer`) deliberately does NOT set it —
        // a synthesized "Found N messages" is not the model answering, so
        // `degradedToFallback` reports it truthfully. (The old code kept a
        // separate `degraded` flag and flipped it false on synthesis, which
        // lied — the UI showed a confident answer the model never produced.)
        var modelEmittedFinal = false
        var finalAnswer: NLFinalAnswer? = nil

        // Set when we want ONE more LLM turn that is FINAL-ANSWER-ONLY: no tool
        // catalog, an explicit "answer now from what you have" instruction.
        // Triggered by a duplicate tool call or the read-cap. The forced turn
        // runs inside the loop (so it shares the iteration budget) but cannot
        // itself issue a tool — a tool call from it is ignored and we fall
        // through to synthesis.
        var forceFinalAnswer = false
        var forceFinalReason = ""

        reactLogger.info("react: query=\"\(userQuery, privacy: .public)\"")

        loop: while iterations < maxIterations {
            iterations += 1
            let iterStart = Date()

            // FINAL-ANSWER-ONLY turn (forced): no tool catalog, an explicit
            // "you already called X — do not repeat it, answer now" signal.
            // Otherwise the normal tool-loop prompt.
            let systemPrompt = forceFinalAnswer
                ? Self.forcedFinalAnswerSystemPrompt
                : Self.toolLoopSystemPrompt
            let userPrompt = forceFinalAnswer
                ? Self.buildForcedFinalAnswerPrompt(
                    question: userQuery,
                    now: now,
                    scratchpad: scratchpad,
                    reason: forceFinalReason
                )
                : Self.buildReActUserPrompt(
                    question: userQuery,
                    now: now,
                    scratchpad: scratchpad
                )
            let raw: String
            do {
                raw = try await runtime.respond(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    // Bumped 320 → 512: the final turn now emits a 2–4
                    // sentence evidence-grounded answer plus an
                    // evidence_indices array, which is longer than the
                    // old one-liner. Tool-call turns stay tiny; this only
                    // affects the synthesis turn's headroom.
                    maxTokens: 512
                )
            } catch {
                reactLogger.error("react: runtime threw at iter=\(iterations, privacy: .public): \(String(describing: error), privacy: .public)")
                break
            }
            reactLogger.info("react: iter=\(iterations, privacy: .public)\(forceFinalAnswer ? " [forced-final]" : "") raw (\(raw.count, privacy: .public) chars): \(raw, privacy: .public)")

            let decoded: NLToolCallParser.Decoded
            do {
                decoded = try NLToolCallParser.parse(raw)
            } catch {
                reactLogger.notice("react: iter=\(iterations, privacy: .public) parse FAILED — \(String(describing: error), privacy: .public)")
                // Drop the bad turn from the scratchpad — don't poison
                // future turns with malformed model output.
                break
            }

            // If this was the forced final-answer turn, we accept ONLY a final
            // answer. A tool call here means the model still didn't answer —
            // stop and let the honest synthesis fallback run (we already told
            // it not to call tools, and there's no catalog to call against).
            if forceFinalAnswer {
                if case .final(let answer) = decoded {
                    finalAnswer = answer
                    modelEmittedFinal = true
                    reactLogger.info("react: forced final answer accepted at iter=\(iterations, privacy: .public)")
                    trace.append(NLTraceStep(
                        phase: .answering,
                        label: "Final: \(answer.answer.prefix(80))",
                        status: .complete,
                        duration: Date().timeIntervalSince(iterStart)
                    ))
                } else {
                    reactLogger.notice("react: forced final-answer turn still emitted a tool call — stopping, will synthesize honestly")
                    trace.append(NLTraceStep(
                        phase: .answering,
                        label: "Stopped — couldn't get a direct answer",
                        status: .complete,
                        duration: Date().timeIntervalSince(iterStart)
                    ))
                }
                break loop
            }

            switch decoded {
            case .final(let answer):
                finalAnswer = answer
                modelEmittedFinal = true
                reactLogger.info("react: final answer at iter=\(iterations, privacy: .public)")
                trace.append(NLTraceStep(
                    phase: .answering,
                    label: "Final: \(answer.answer.prefix(80))",
                    status: .complete,
                    duration: Date().timeIntervalSince(iterStart)
                ))
                break loop

            case .tool(let call):
                // DUPLICATE-CALL HARDENING (Codex #2.1): reject a byte-identical
                // tool call (same tool + same args) that we've ALREADY executed
                // this loop — not just back-to-back, but anywhere in the run.
                // The model is stuck (it already saw this exact observation and
                // learned nothing). Instead of breaking and hoping, FORCE a
                // final-answer-only turn: feed back an error observation, drop
                // the tool catalog, and make it answer from what it has.
                let signature = "\(call.tool)|\(Self.summarizeArgs(call.args))"
                if executedSignatures.contains(signature) {
                    repeatedCall = true
                    forceFinalAnswer = true
                    forceFinalReason = "You already called \(call.tool)(\(Self.summarizeArgs(call.args))) and saw its result above. Do NOT call it again — answer the question now from what you already have."
                    reactLogger.notice("react: iter=\(iterations, privacy: .public) duplicate call \(signature, privacy: .public) — forcing final-answer-only turn")
                    scratchpad += """

                    Step \(iterations): \(call.tool)(\(Self.summarizeArgs(call.args)))
                    Observation: ERROR — you already ran this exact query and saw the result above. Repeating it gives no new information. Answer the question NOW from what you already have.
                    """
                    // Label prefixed "Stopped — repeated" so the trace digest's
                    // repeat-breaker detector still fires; marked complete (the
                    // forced final-answer turn that follows appends its own
                    // answering step).
                    trace.append(NLTraceStep(
                        phase: .answering,
                        label: "Stopped — repeated the same lookup; answering from what we have",
                        status: .complete,
                        duration: Date().timeIntervalSince(iterStart)
                    ))
                    continue loop
                }
                executedSignatures.insert(signature)

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

                // ANSWER-AFTER-N-READS CAP (Codex #2.4): count message-reading
                // tool calls. If the model keeps reading/searching past the cap
                // without answering, it's spinning — force the final-answer
                // turn rather than burning the rest of the iteration budget.
                if Self.isReadTool(call.tool) {
                    readToolCalls += 1
                    if readToolCalls >= maxReadToolCalls {
                        forceFinalAnswer = true
                        forceFinalReason = "You have read messages \(readToolCalls) times. Stop searching and answer the question NOW from what you've already read above."
                        reactLogger.notice("react: read-cap hit (\(readToolCalls, privacy: .public)) — forcing final-answer-only turn")
                    }
                }
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

        // Synthesis fallback: the loop ended WITHOUT a model-emitted final
        // answer (hit the iteration cap, the forced-final turn still didn't
        // answer, or a parse failure). Don't strand the user on "no match"
        // when we actually gathered data — build a basic answer from the last
        // observation so a stats query like "who did I text the most" still
        // resolves. This is the safety net for small-model non-convergence.
        //
        // HONEST DEGRADATION (Codex #2.2): we record that the answer was
        // SYNTHESIZED (not model-emitted) and leave `modelEmittedFinal` false.
        // A synthesized "Found N messages — see the top match" is NOT the model
        // answering the question; it's us papering over non-convergence, so the
        // result reports `degradedToFallback == true` truthfully. (Previously
        // this flipped a `degraded` flag to false, which made the UI show a
        // confident answer the model never actually produced.)
        var answerWasSynthesized = false
        if finalAnswer == nil, let synth = Self.synthesizeFallbackAnswer(
            contacts: lastContacts,
            candidates: lastCandidates
        ) {
            finalAnswer = synth
            answerWasSynthesized = true
            reactLogger.notice("react: synthesized fallback answer (HONEST degraded — model emitted no final answer; repeatedCall=\(repeatedCall, privacy: .public), iters=\(iterations, privacy: .public))")
        }

        // Pick the hero from whatever the model anchored. Default to the
        // first candidate the most recent search returned.
        var hero: MessageSearch.Result? = lastCandidates.first
        if let final = finalAnswer, let idx = final.heroIndex,
           idx >= 0, idx < lastCandidates.count {
            hero = lastCandidates[idx]
        }
        let explanation: String? = finalAnswer?.answer

        // Reorder candidates so the model's chosen EVIDENCE surfaces
        // first — the answer view renders hero + the next 4 candidates,
        // so curating that head matters. Order: hero (if any) → cited
        // evidence (in the model's order) → everything else (natural
        // search order). De-duped by message id. When the model cited
        // nothing, this is a no-op and the natural order stands.
        var orderedCandidates = lastCandidates
        if let final = finalAnswer {
            var head: [MessageSearch.Result] = []
            var seen = Set<Int64>()
            func pushIfValid(_ idx: Int) {
                guard idx >= 0, idx < lastCandidates.count else { return }
                let r = lastCandidates[idx]
                if seen.insert(r.message.id).inserted { head.append(r) }
            }
            if let h = final.heroIndex { pushIfValid(h) }
            for e in final.evidenceIndices { pushIfValid(e) }
            if !head.isEmpty {
                let tail = lastCandidates.filter { !seen.contains($0.message.id) }
                orderedCandidates = head + tail
                hero = head.first
            }
        }

        trace.append(NLTraceStep(
            phase: .answering,
            label: "Done in \(Self.formatDuration(Date().timeIntervalSince(startAll)))",
            status: .complete,
            duration: Date().timeIntervalSince(startAll)
        ))

        // HONEST `degradedToFallback` (Codex #2.2): true IFF the model did NOT
        // produce a real final answer for this query. The model genuinely
        // answering (on a normal turn OR the forced final-answer turn) is the
        // ONLY non-degraded outcome — `modelEmittedFinal` is the single source
        // of truth. A SYNTHESIZED answer ("Found N messages" / "you texted X
        // the most") is degraded even when it's useful and has a hero, because
        // the MODEL didn't produce it. A model answer with no hero (e.g. a
        // pure-stats answer that cites no single message) is NOT degraded —
        // the model still answered. (`answerWasSynthesized` is by construction
        // `!modelEmittedFinal`; kept in the OR for explicitness/readability.)
        let degradedHonest = !modelEmittedFinal || answerWasSynthesized
        return NLQueryResult(
            hero: hero,
            candidates: Array(orderedCandidates.prefix(maxCandidates)),
            trace: trace,
            plan: nil,
            fallbackQuery: userQuery,
            explanation: explanation,
            degradedToFallback: degradedHonest
        )
    }

    /// Build a basic answer from gathered data when the model never emitted
    /// a final answer (capped or looped). Prefers a top-contacts summary
    /// (the common stats query), then falls back to "here's the top match"
    /// when we have message candidates. Returns nil only when we have
    /// nothing at all — then the caller's degraded path stands.
    internal static func synthesizeFallbackAnswer(
        contacts: [DashboardStats.ContactStat],
        candidates: [MessageSearch.Result]
    ) -> NLFinalAnswer? {
        if let top = contacts.first {
            var text = "You texted \(top.displayName) the most — \(top.total) messages (\(top.sent) sent, \(top.received) received)."
            if contacts.count >= 2 {
                let runners = contacts.dropFirst().prefix(2)
                    .map { "\($0.displayName) (\($0.total))" }
                    .joined(separator: ", ")
                text += " Then \(runners)."
            }
            return NLFinalAnswer(answer: text, heroIndex: nil, contactIndex: 0, evidenceIndices: [])
        }
        if !candidates.isEmpty {
            let n = candidates.count
            return NLFinalAnswer(
                answer: "Found \(n) relevant message\(n == 1 ? "" : "s") — see the top match below.",
                heroIndex: 0,
                contactIndex: nil,
                evidenceIndices: Array(0..<min(n, 5))
            )
        }
        return nil
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

    /// How many result rows to surface in a `search` observation. With
    /// Qwen3-1.7B's 32K context this is comfortable — ~18 rows × ~90
    /// tokens ≈ 1.6K tokens, leaving plenty for the scratchpad history.
    static let searchPreviewCount = 18
    /// How many rows to surface in a `readMessages` (chronological) dump.
    /// Higher because investigative scans need the full local window.
    static let readPreviewCount = 45

    /// Appended to stats-tool observations (topContacts / topGroups /
    /// count / overview). These tools return the COMPLETE answer in one
    /// shot — there's nothing more to fetch — so the model must answer,
    /// not re-call. Without this nudge a small model re-issued the same
    /// stats tool every turn until the iteration cap (the topContacts ×8
    /// loop). The repeat-breaker + synthesis fallback are the safety net;
    /// this is the first line of defense (so it answers in 2 turns).
    static let answerNowHint = "You now have everything needed — emit the FINAL answer JSON now. Do NOT call another tool."

    /// Build the adaptive-breadth hint appended to a result observation.
    /// The whole point: the small model doesn't have to infer the
    /// broaden/narrow heuristic — the observation TELLS it what to do
    /// based on the count. This is what makes "ask broader if too narrow,
    /// narrow if too broad" actually happen with a 1.7B planner.
    static func breadthHint(count: Int, shown: Int) -> String {
        switch count {
        case 0:
            return "\nZERO matches — TOO NARROW. Broaden and retry: drop a filter, widen the date window (or use all_time), OR-join synonyms (e.g. \"dinner|food|eat\"), or use *substring* matching. Do NOT answer \"nothing found\" until you've tried at least one broader query."
        case 1...3:
            return "\nOnly \(count) match\(count == 1 ? "" : "es") — possibly TOO NARROW. If this fully answers the question, proceed to the answer. If it seems incomplete, broaden once and retry."
        case 4...80:
            // Healthy range — read them.
            let more = count > shown ? " (\(count - shown) more not shown — narrow further if you need to read every one)" : ""
            return "\nGood range — read these \(shown) carefully\(more)."
        default:
            return "\n\(count) matches — TOO BROAD to read individually (showing \(shown)). If the question is about a SPECIFIC event/message, NARROW and retry: add a person (with:/from:), a date window, a type: filter, or more specific keywords. If the question is about VOLUME or WHO/HOW-MANY, you can answer from the count + top results without narrowing."
        }
    }

    /// B1 operator-validation gate. Inspect a search query string for two
    /// classes of model error that the search engine otherwise swallows
    /// SILENTLY (the research's "no silent failures" rule):
    ///   1. **arg-injection** — `key=value` tokens (e.g. `limit=40`,
    ///      `in=all_time`) where the model crammed JSON args INTO the query
    ///      text. The engine treats them as ineffective literal words, so the
    ///      result set is quietly wrong (observed: Qwen3-4B on the
    ///      protein-shake recall — `…|eat limit=40 in=all_time` → 49 junk rows).
    ///   2. **unknown `key:` operators** (e.g. `mood:happy`, `topic:gym`) that
    ///      aren't in the real grammar — they match nothing → 0 results → the
    ///      model gives up.
    /// Returns a corrective observation (so the model SELF-corrects on the next
    /// turn) when the query is malformed, or nil when it's clean. Purely
    /// deterministic — no model self-reflection (which hurts <70B models).
    /// The valid set is derived from `TokenPrefix.allCases` so the gate can
    /// never drift from the real parser (B5 intent).
    /// Split a query on UNQUOTED whitespace (a quoted value may contain
    /// spaces, e.g. `with:"Amma Sat"`), so a legitimate value isn't split.
    static func tokenizeQuery(_ query: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inQuote = false
        for ch in query {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    /// When a search returns ZERO and the query is all-filters-with-NO-free-text
    /// but has an `in:`/`chat:` (chat-name) or `with:` (person) token, the model
    /// likely jammed a search KEYWORD into a scope operator (observed: `in:"gym"`
    /// AND `with:gym|gymnastics|…` for "how many times did I mention gym" → 0,
    /// since no chat/person is named gym). Returns CONDITIONAL guidance so it
    /// moves the word to bare free text — while letting a legit scope (`with:"Beck"`
    /// with 0 in-window) be treated as a valid "none found". `from:`/`to:` are
    /// excluded: `from:me`/`to:me` are common legit filters, not the footgun.
    /// Precise by construction: `from:me type:image` has no in:/chat:/with: token.
    static func misplacedKeywordHint(for query: String) -> String? {
        let validPrefixes = TokenPrefix.allCases.map { $0.rawValue }
        var hasChatFilter = false
        var hasPersonFilter = false
        var hasFreeText = false
        for tok in tokenizeQuery(query) {
            let lower = tok.lowercased()
            if let p = validPrefixes.first(where: { lower.hasPrefix($0) }) {
                if p == TokenPrefix.in.rawValue || p == TokenPrefix.chat.rawValue {
                    hasChatFilter = true
                } else if p == TokenPrefix.with.rawValue || p == TokenPrefix.to.rawValue {
                    // with:/to: scope to a PERSON. A keyword OR a GROUP-CHAT name
                    // jammed here matches no person → 0 (observed: `to:"Hao group"`
                    // for "in the Hao group" → 0; a group is scoped with in:).
                    // to:me is handled upstream in operatorCorrection (#27).
                    hasPersonFilter = true
                }
            } else if tok != "|" && tok != "+" && !tok.isEmpty {
                hasFreeText = true
            }
        }
        guard (hasChatFilter || hasPersonFilter) && !hasFreeText else { return nil }
        var what: [String] = []
        if hasChatFilter { what.append("in:/chat: = CHAT NAME") }
        if hasPersonFilter { what.append("with:/to: = a PERSON") }
        var msg = "\nThis returned 0 and every token is a FILTER (\(what.joined(separator: ", "))). If you were scoping to a REAL chat/person and 0 is correct, answer it. Otherwise KEEP your other operators (from:/type:) and fix ONLY the scope, then retry:"
        if hasPersonFilter {
            msg += " ▶ a GROUP CHAT is scoped with in:\"<name>\" using its DISTINCTIVE word (e.g. in:\"Hao\", NOT to:/with: and NOT in:\"Hao group\" — the word 'group' usually isn't in the real chat name)."
        }
        msg += " ▶ a search WORD goes BARE (not wrapped in any operator)."
        return msg
    }

    /// If `s` is a date ("2026-09-01") or date-range ("2026-09-01..2026-12-31"),
    /// return its START date string; else nil. Used to catch a date misplaced
    /// into a chat-scope (`in:`/`chat:`) operator.
    static func dateRangeStart(_ s: String) -> String? {
        let first = s.components(separatedBy: "..").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard first.count == 10 else { return nil } // YYYY-MM-DD
        for (i, c) in first.enumerated() {
            if i == 4 || i == 7 { if c != "-" { return nil } }
            else if !c.isNumber { return nil }
        }
        return first
    }

    static func operatorCorrection(for query: String, now: Date) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Tokenize on UNQUOTED whitespace so a quoted value isn't split.
        let tokens = tokenizeQuery(query)

        let validPrefixes = Set(TokenPrefix.allCases.map { $0.rawValue }) // "with:", …
        let validList = TokenPrefix.allCases.map { $0.rawValue }.joined(separator: " ")
        var argInjections: [String] = []
        var unknownOps: [String] = []
        var badTypes: [String] = []
        var badReactions: [String] = []
        var toSelfOps: [String] = []
        var dateInChatOps: [String] = []
        var anyFutureDate = false

        for tok in tokens {
            // (1) arg-injection: a bare letter/underscore key immediately
            // followed by '='. `reactions:>=3` is safe — its key segment
            // contains ':' and '>' so it fails the letters-only test.
            if let eq = tok.firstIndex(of: "=") {
                let key = tok[tok.startIndex..<eq]
                if !key.isEmpty && key.allSatisfy({ $0.isLetter || $0 == "_" }) {
                    argInjections.append(String(tok))
                    continue
                }
            }
            // (2) unknown `word:` operator. Times like `8:30` are safe — the
            // segment before ':' isn't all letters. A real value after a valid
            // prefix (before:2026-01-01) keeps its prefix in `validPrefixes`.
            if let colon = tok.firstIndex(of: ":") {
                let word = tok[tok.startIndex..<colon]
                let prefix = String(tok[tok.startIndex...colon]).lowercased() // incl. ':'
                if !word.isEmpty && word.allSatisfy({ $0.isLetter }) && !validPrefixes.contains(prefix) {
                    unknownOps.append(String(tok))
                    continue
                }
                // (3) B5 — bounded-enum value check for `type:`. `type:message`
                // / `type:chat` look valid (the prefix is real) but the VALUE
                // isn't a content type, so the filter silently matches nothing
                // → confidently-wrong zero counts. Validate against the REAL
                // parser (TypeFilter.parse → nil = unrecognized). Skip values
                // with OR/wildcard chars (parser handles those differently).
                if prefix == TokenPrefix.type.rawValue {
                    var value = String(tok[tok.index(after: colon)...])
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !value.isEmpty && value.allSatisfy({ $0.isLetter }) &&
                        MessageSearch.TypeFilter.parse(value) == nil {
                        badTypes.append(String(tok))
                    }
                }
                // (3b) B5 — bounded-enum value check for `reactions:`. Same trap
                // as type:message: `reactions:heart` looks valid (real prefix)
                // but "heart" isn't a kind (the ❤️ reaction is `love`), so the
                // token falls into free text → silent 0 ("reacted to 0 messages"
                // when there are thousands). Validate via the real parser.
                if prefix == TokenPrefix.reactions.rawValue {
                    let value = String(tok[tok.index(after: colon)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !value.isEmpty && !value.contains("|") && !value.contains("*") &&
                        MessageSearch.ReactionFilter.parse(value) == nil {
                        badReactions.append(String(tok))
                    }
                }
                // (3c) `to:me` footgun. `to:X` = messages YOU SENT to X, so
                // `to:me` is contradictory with from:<someone-else> → 0 (observed:
                // "photos Beck sent me" → `from:"Beck" to:me type:image` → 0,
                // when from:"Beck" type:image alone is 313). The model means
                // "received BY me", which is just from:<person> in a 1:1.
                if prefix == TokenPrefix.to.rawValue {
                    let value = String(tok[tok.index(after: colon)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
                    if value == "me" || value == "self" || value == "myself" {
                        toSelfOps.append(String(tok))
                    }
                }
                // (4) date/date-range jammed into a chat-scope operator.
                // `in:`/`chat:` filter by CHAT NAME — a date there silently
                // matches no chat (observed: `in:"2026-09-01..2026-12-31"` for
                // "since September" → 0). Dates belong in the JSON `in` arg.
                if prefix == TokenPrefix.in.rawValue || prefix == TokenPrefix.chat.rawValue {
                    let raw = String(tok[tok.index(after: colon)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if let startStr = Self.dateRangeStart(raw) {
                        dateInChatOps.append(String(tok))
                        if let d = NLAgent.parseISODate(startStr), d > now { anyFutureDate = true }
                    }
                }
            }
        }

        guard !argInjections.isEmpty || !unknownOps.isEmpty || !badTypes.isEmpty || !badReactions.isEmpty || !toSelfOps.isEmpty || !dateInChatOps.isEmpty else { return nil }

        var msg = "INVALID QUERY — not run (it would fail silently). "
        if !argInjections.isEmpty {
            msg += "These are ARGUMENTS stuffed into the query text: \(argInjections.joined(separator: ", ")). Move them out of \"query\" into the JSON args — shape: {\"query\":\"<your search words>\",\"in\":\"all_time\",\"limit\":40}. (The angle-bracket part is a PLACEHOLDER — replace it with your own keywords; do NOT search for it literally.) "
        }
        if !unknownOps.isEmpty {
            msg += "Unknown operator(s): \(unknownOps.joined(separator: ", ")). "
        }
        if !badTypes.isEmpty {
            msg += "Invalid type filter(s): \(badTypes.joined(separator: ", ")). `type:` accepts ONLY image|video|audio|sticker|link|file|text|attachment. For ALL messages (no content filter), OMIT type: entirely — there is no type:message. "
        }
        if !badReactions.isEmpty {
            msg += "Invalid reaction filter(s): \(badReactions.joined(separator: ", ")). `reactions:` accepts a KIND — love, like, laugh, emphasize, question, dislike (the ❤️/heart reaction is `love`) — or a count comparator (e.g. >=3) or `any`. "
        }
        if !toSelfOps.isEmpty {
            msg += "`\(toSelfOps.joined(separator: ", "))` does NOT mean 'received by you'. `to:X` filters messages YOU SENT to X — so `to:me` is contradictory with from:<someone else> and matches the wrong messages. For 'messages <person> sent you', use `from:\"<person>\"` ALONE (drop the to:me). "
        }
        if !dateInChatOps.isEmpty {
            msg += "DATE in a chat-scope operator: \(dateInChatOps.joined(separator: ", ")). A date is NEVER a keyword. Remove ONLY the in:/chat:<date> token from \"query\" and put the date in the JSON \"in\" arg — but KEEP every other operator you had (from:, to:, type:, with:, reactions:). E.g. `from:me in:2026-06-14` → {\"query\":\"from:me\",\"in\":\"2026-06-14\"}. The query becomes \"\" ONLY if the date was its sole content. Do NOT put the date in both places. "
            if anyFutureDate {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
                msg += "Also: today is \(f.string(from: now)), so that date is in the FUTURE — for a 'since <month>' query you mean the most-recent PAST occurrence (use last year). "
            }
        }
        msg += "Operators valid INSIDE \"query\": \(validList), plus | for OR, + for AND, and *substr* for substring. Retry with a corrected query."
        return msg
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
            if let corrective = Self.operatorCorrection(for: query, now: now) {
                return ToolObservation(observation: corrective, summary: "invalid query", failed: true)
            }
            do {
                let results = try await tools.search(
                    query: query,
                    dateRange: dateRange,
                    limit: limit
                )
                lastCandidates = results
                // Show up to `searchPreviewCount` results with full bodies.
                // Qwen3-1.7B's 32K context lets us surface many more rows
                // than the old 6, so the model can actually READ the result
                // set and synthesize over it rather than guessing from a
                // tiny sample.
                let shown = min(Self.searchPreviewCount, results.count)
                let preview = results.prefix(shown).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                let hint = NLAgent.breadthHint(count: results.count, shown: shown)
                let kwHint = results.isEmpty ? (Self.misplacedKeywordHint(for: query) ?? "") : ""
                let obs = "Found \(results.count) match\(results.count == 1 ? "" : "es"). Showing \(shown) with full bodies:\n\(preview)\(hint)\(kwHint)"
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
                // STRICT 1:1 SCOPING (Codex #2.3): when a person is named, the
                // ReAct path used to map `with:NAME` → `in:"NAME"`, which ORs a
                // `display_name LIKE '%NAME%'` branch and leaks a same-named
                // GROUP ("Annika effect" beat the Annika 1:1 — the Annika
                // effect bug). We now resolve the person → their 1:1 (style=45)
                // via the SAME `resolveScopedPersonChat` the deterministic path
                // uses (no display_name branch → a group can never win), and
                // read EXACTLY those chat ROWIDs. If the person doesn't resolve
                // to any chat, we fall back to the old `readMessages` behaviour
                // so we never silently return nothing.
                var results: [MessageSearch.Result] = []
                var scopeNote = ""
                if let name = personName, !name.isEmpty,
                   let chat = try await tools.resolveScopedPersonChat(named: name) {
                    results = try await tools.readMessagesInChats(
                        rowIDs: chat.chatRowIDs,
                        in: dateRange,
                        limit: limit
                    )
                    scopeNote = chat.isOneToOne ? "" : " (group — no 1:1 found)"
                } else {
                    results = try await tools.readMessages(
                        in: dateRange,
                        with: personName,
                        limit: limit
                    )
                }
                lastCandidates = results
                // Show up to `readPreviewCount` rows chronologically. This
                // is the "actually read the conversation" tool, so we show
                // a wide local window — the model's 32K context absorbs it.
                let displayCount = min(results.count, Self.readPreviewCount)
                let preview = results.prefix(displayCount).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                let scope = personName.map { "with \($0)\(scopeNote)" } ?? "(all chats)"
                let windowLabel = dateRange.map {
                    "\(NLAgent.formatISODate($0.lowerBound))..\(NLAgent.formatISODate($0.upperBound))"
                } ?? "all_time"
                let hint = NLAgent.breadthHint(count: results.count, shown: displayCount)
                let obs = "Read \(results.count) message\(results.count == 1 ? "" : "s") \(scope) in \(windowLabel) (chronological). Showing \(displayCount):\n\(preview)\(hint)"
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

        case "friendsMadeSince", "newFriends", "friendsSince":
            // "Who did I become friends with since <date>." Contact-merged
            // before/after-cutoff volume split — the right answer for "new
            // friends", where topContacts (volume) returns your OLDEST friends.
            // Cutoff = the `since` arg (YYYY-MM-DD) or the resolved range's
            // lower bound; default 1 year ago. Guard a future cutoff (the
            // temporal-hallucination failure: "since September" → 2026-09).
            var cutoff = call.args["since"]?.asString.flatMap(NLAgent.parseISODate)
                ?? dateRange?.lowerBound
                ?? Calendar.current.date(byAdding: .year, value: -1, to: now)!
            if cutoff > now {
                // The model picked a future cutoff — clamp to the most recent
                // PAST occurrence of that month/day (≈ "since September" → last Sept).
                cutoff = Calendar.current.date(byAdding: .year, value: -1, to: cutoff) ?? now
            }
            let limit = call.args["limit"]?.asInt ?? 12
            do {
                let friends = try await tools.friendsMadeSince(
                    cutoff, minAfter: 100, minAfterShare: 0.85, maxBefore: 250, limit: limit)
                lastCandidates = []
                let since = NLAgent.formatISODate(cutoff)
                let obs: String
                if friends.isEmpty {
                    obs = "No new contacts found since \(since) (nobody crossed the volume threshold). The user may have made no new close friends in that window."
                } else {
                    let lines = friends.enumerated().map { (i, f) in
                        "[\(i)] \(f.name): \(f.after) msgs after \(since), \(f.before) before"
                    }.joined(separator: "\n")
                    obs = "People you became friends with since \(since) (almost all their messages post-date it; old friends excluded):\n\(lines)\nAnswer with these names."
                }
                return ToolObservation(observation: obs, summary: "\(friends.count) new friends", failed: false)
            } catch {
                return ToolObservation(observation: "friendsMadeSince failed: \(error)", summary: "failed", failed: true)
            }

        case "plansInWindow", "plans", "commitments":
            // The "what did I commit to / plan in this window" tool. One
            // observation: YOUR cue-filtered sent messages across ALL chats,
            // chronological — so the model summarizes every distinct plan in a
            // single read instead of diving into one chat and stopping (the
            // grounded-eval failure mode, docs/nl-eval-grounded.md).
            let limit = call.args["limit"]?.asInt ?? 60
            do {
                let results = try await tools.plansInWindow(in: dateRange, limit: limit)
                lastCandidates = results
                let displayCount = min(results.count, Self.readPreviewCount)
                let preview = results.prefix(displayCount).enumerated().map { (i, r) in
                    NLAgent.formatResultLine(index: i, result: r)
                }.joined(separator: "\n")
                let windowLabel = dateRange.map {
                    "\(NLAgent.formatISODate($0.lowerBound))..\(NLAgent.formatISODate($0.upperBound))"
                } ?? "all_time"
                let obs: String
                if results.isEmpty {
                    obs = "Found 0 plan-like messages you sent in \(windowLabel). Try a wider window, or use `search`/`readMessages` if the user named a specific person or topic."
                } else {
                    obs = "Your \(results.count) plan/commitment message\(results.count == 1 ? "" : "s") across all chats in \(windowLabel) (chronological, each tagged with the chat). Summarize the DISTINCT plans — dedupe, drop non-commitments:\n\(preview)"
                }
                return ToolObservation(
                    observation: obs,
                    summary: "\(results.count) plans",
                    failed: false
                )
            } catch {
                return ToolObservation(
                    observation: "plansInWindow failed: \(error)",
                    summary: "failed",
                    failed: true
                )
            }

        case "countMatching", "count":
            let query = call.args["query"]?.asString ?? ""
            if let corrective = Self.operatorCorrection(for: query, now: now) {
                return ToolObservation(observation: corrective, summary: "invalid query", failed: true)
            }
            do {
                let n = try await tools.countMatching(query: query, in: dateRange)
                // A 0 count on an in:/chat:-only query usually means a keyword
                // was jammed into the chat-name operator — guide, don't let the
                // model report a confidently-wrong "0".
                let kwHint = n == 0 ? (Self.misplacedKeywordHint(for: query) ?? "") : ""
                let obs = kwHint.isEmpty ? "Count = \(n).\n\(Self.answerNowHint)" : "Count = \(n).\(kwHint)"
                return ToolObservation(
                    observation: obs,
                    summary: "n=\(n)",
                    failed: !kwHint.isEmpty
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
            if let corrective = Self.operatorCorrection(for: query, now: now) {
                return ToolObservation(observation: corrective, summary: "invalid query", failed: true)
            }
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
                let obs = "Top \(stats.count) contact\(stats.count == 1 ? "" : "s"):\n\(preview)\n\(Self.answerNowHint)"
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
                let obs = "Top \(stats.count) group\(stats.count == 1 ? "" : "s"):\n\(preview)\n\(Self.answerNowHint)"
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
                    observation: "Overview: total=\(o.total), sent=\(o.sent), received=\(o.received), chats=\(o.chats)\n\(Self.answerNowHint)",
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
                observation: "Unknown tool '\(call.tool)'. Available: friendsMadeSince, plansInWindow, search, readMessages, countMatching, firstMatching, topContacts, topGroups, overviewStats, messagesAroundTime, context, rawSearchSQL. Emit a final answer with {\"answer\": \"...\"} when done.",
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
        /no_think
        You answer questions about iMessage history by calling TOOLS. Output ONE JSON object per turn — NO prose, NO markdown fences, NO <think> blocks. After each tool call you receive an observation; READ it carefully and use it to decide your next call. When you have the answer, output a FINAL JSON.

        YOUR JOB: converge on the RIGHT set of messages, READ them, then write a clear answer that CITES specific messages as evidence. You are not just running one search — you iterate until the result set is the right size to actually read, then you read it and synthesize.

        THE LOOP (do this every time):
        1. Run a search/read tool.
        2. Look at the COUNT in the observation:
           • ZERO or very few results → TOO NARROW. Broaden: drop a filter, widen the date window (try all_time), OR-join synonyms (food|dinner|eat), or use *substring*. Retry.
           • Too many to read (the observation says "TOO BROAD") → NARROW: add a person (with:/from:), a date window, a type: filter, or sharper keywords. Retry.
           • A readable number (≈4–80) → READ every shown row.
        3. When the set is right and you've read it, emit the FINAL answer citing the messages that prove it.
        You have up to 8 tool calls — spend them adapting breadth, not guessing.

        Available tools (priority order):

        0a) {"tool":"friendsMadeSince","args":{"since":"YYYY-MM-DD","limit":<int>}}
           Who the user BECAME FRIENDS WITH since a date — contacts whose messages are almost all AFTER the date (a new relationship), old friends excluded. Use for "who are my new friends", "people I met since X", "friends I made this year". Pass `since` as the most-recent PAST occurrence (e.g. "since September" with today in June → LAST year's Sept-01). Do NOT use topContacts — that returns your OLDEST friends, the opposite.

        0) {"tool":"plansInWindow","args":{"in":"<date-range>","limit":<int>}}
           Your cue-filtered SENT messages across ALL chats in a window — the things you said you'd do (let's/I'll/gonna/confirmed/tmrw/meeting/times…), chronological, each tagged with its chat. Use this FIRST and usually ONLY for "what plans/commitments did I make this <week/window>", "what did I agree to", "what's coming up". One observation holds every plan across every chat — read it and summarize the DISTINCT plans (dedupe, drop non-commitments, name who each is with). Do NOT then dive into one chat — you already have the full picture.

        1) {"tool":"readMessages","args":{"with":"<name or null>","in":"<date-range>","limit":<int>}}
           Read a CHRONOLOGICAL dump of messages in the 1:1 chat with a person in a window. Returns full message bodies. Use this FIRST for investigative queries — "what was my argument with X N weeks ago" — when you need to actually SCAN the conversation to identify where the argument starts. The `with` arg scopes to the 1:1 conversation with that person (NOT group chats they happen to be in). If readMessages comes back empty, fall through to `search` with `with:"NAME"` for the broader "any chat with NAME" scope. CRITICAL: pick a TIGHT date range (≤7 days) centered on the target time, and use limit 60-80. A wide window like last_30d returns the OLDEST 25 messages from the start of the month and buries the target in chatter — the model never sees it.

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
        CALENDAR vs ROLLING — they are DIFFERENT questions, pick by the user's words:
          • "last month" / "this month" → in:"last_month" / "this_month" (a full CALENDAR month). NOT last_30d.
          • "last week" / "this week" → in:"last_week" / "this_week" (a full CALENDAR week). NOT last_7d.
          • "yesterday" / "today" → in:"yesterday" / "today".
          • "last 30 days" / "past 30 days" (rolling) → in:"last_30d". "last 7 days" → in:"last_7d".
        Use the rolling forms ONLY when the user literally says a number of days. Default a bare "last month/week" to the calendar form. Do NOT also put a last:Nd operator in the query when you use a calendar "in" — the "in" arg already scopes the window.

        Observation rows are numbered [0], [1], … and contain timestamp, ISO date, chat name, chat_id, sender, and full body — read them carefully to decide the next move AND to cite as evidence.

        FINAL answer shape (emit when done):
        {"answer":"<2–4 sentence answer grounded in the messages you read>","hero_index":<index of the single most important message, or null>,"evidence_indices":[<indices of 2–5 messages that back up your answer>]}
        • answer: written for the user, referencing what the messages actually say. Quote a short phrase when it helps.
        • hero_index / evidence_indices: indices from the MOST RECENT observation's result list. These messages are shown to the user as proof, so pick the ones that genuinely support your answer. Use null / [] only for pure-stats answers (counts, rankings) where no single message is evidence.

        Rules:
        - ADAPT BREADTH every turn based on the count (see THE LOOP above). Never stop at zero results without broadening first. Never answer a specific-event question off a "TOO BROAD" set without narrowing first.
        - For INVESTIGATIVE / PERSON-SCOPED-TOPIC queries ("what was my argument with X", "what did X and I talk about", "what's going on with X", "catch me up on X", "when did we plan Y") use readMessages on the X 1:1 FIRST (with:"X"), READ the recent messages, scan for the tone/topic shift, optionally messagesAroundTime to zoom, then synthesize WHAT you actually discussed with evidence_indices pointing at the key messages. These ask about TOPICS/content — do NOT use topContacts (that gives volume/ranking, not what you talked about).
        - For STATS questions ("who/how-many/which") prefer topContacts / topGroups / countMatching / overviewStats; evidence_indices can be empty.
        - DEFAULT WINDOW: a SUPERLATIVE/ranking query with NO time qualifier ("my most active group chat", "who do I text the most", "biggest group chat", "my top contacts") means ALL of history — use in:"all_time". Do NOT silently scope it to the current month/week (that answers a different, narrower question). Only narrow when the user names a window ("last week", "in 2026", "lately").
        - For GENERIC life-summary queries with NO topic and NO person ("what have I been up to", "what's new", "catch me up", "how's my life been") — no keyword to search: pull WHO you've been most active with via topContacts AND topGroups over the window (optionally overviewStats for volume) and NAME the top people/groups with counts ("most active with Beck, Annika, and the Hao group…"); a bare message total ("23,231 messages") is NOT acceptable. topContacts answers WHO, never WHAT — so this who-ranking path is ONLY for those generic phrases:
          • If the query names a FEELING or TOPIC ("what have I been stressed/worried/excited about", "what have I said about X") it is a CONTENT question — search that topic's CUE WORDS as BARE free text: just the words OR-joined, e.g. `stressed|stressful|anxious|overwhelmed|worried` — do NOT wrap them in with:/chat:/from: (those are NOT keywords), keep it SHORT (≤6 synonyms, NEVER repeat a word), then READ the matches and synthesize WHAT they reveal. Do NOT use topContacts.
          • If the query names a PERSON ("what did X and I talk about") use the INVESTIGATIVE/readMessages path above.
        - For "around N weeks/months ago" CALCULATE THE TARGET DATE (today minus N), then pass a TIGHT CENTERED range "YYYY-MM-DD..YYYY-MM-DD" (±3–5 days). DON'T use last_30d for these — it buries the target. Today's date is at the top of the user prompt.
        - NEVER call rawSearchSQL unless every other tool fails. Output ONLY the JSON object.

        Examples:

        Q: who did I text the most in 2026
        Turn 1: {"tool":"topContacts","args":{"in":"2026-01-01..2026-12-31","limit":5}}
        Observation: Top 5 contacts: [0] Sarah: 1240 total ...
        Turn 2: {"answer":"You texted Sarah the most in 2026 — 1240 messages total (623 sent, 617 received), well ahead of everyone else.","hero_index":null,"evidence_indices":[]}

        Q: what did Mom say about Thanksgiving plans  (BROADEN example)
        Turn 1: {"tool":"search","args":{"query":"with:\\"Mom\\" thanksgiving","in":"all_time","limit":40}}
        Observation: Found 0 matches. ZERO matches — TOO NARROW. Broaden and retry...
        Turn 2: {"tool":"search","args":{"query":"with:\\"Mom\\" thanksgiving|turkey|holiday|dinner","in":"all_time","limit":40}}
        Observation: Found 9 matches. Showing 9 with full bodies:
          [0] ... Mom: are you coming home for thanksgiving?
          [3] ... Mom: dinner's at 4, bring the pie
          [7] ... You: landing wed night, i'll cook the turkey
          ...
        Turn 3: {"answer":"You and Mom planned Thanksgiving over text: she asked if you were coming home, set dinner for 4pm and asked you to bring pie; you said you'd land Wednesday night and cook the turkey.","hero_index":3,"evidence_indices":[0,3,7]}

        Q: find my argument with Annika around 3 weeks ago  (NARROW + read example; today 2026-05-27 → ~2026-05-06)
        Turn 1: {"tool":"readMessages","args":{"with":"Annika","in":"2026-05-03..2026-05-09","limit":80}}
        Observation: Read 42 messages with Annika ... Showing 42:
          [2] Mon May 5 ... Annika: I can't believe you forgot AGAIN. This is the third time.
          [3] Mon May 5 ... You: I'm sorry. I really am. I had back-to-back …
          [4] Mon May 5 ... Annika: You always say that and nothing ever changes
          [6] Wed May 7 ... Annika: Fine. 8pm.
          ... Good range — read these 42 carefully.
        Turn 2: {"answer":"The argument started May 5 when Annika said \\"I can't believe you forgot AGAIN — this is the third time.\\" You apologized; she said nothing changes; it cooled by May 7 when you agreed to talk it through at 8pm.","hero_index":2,"evidence_indices":[2,3,4,6]}

        Q: how many photos did I send Mom last month   (CALENDAR month — note in:"last_month", and NO last:Nd in the query)
        Turn 1: {"tool":"countMatching","args":{"query":"from:me to:\\"Mom\\" type:image","in":"last_month"}}
        Observation: Count = 14.
        Turn 2: {"answer":"You sent Mom 14 photos last month.","hero_index":null,"evidence_indices":[]}
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

    /// Which tool calls are "reads" that count against the answer-after-N-reads
    /// cap (Codex #2.4). Search + chronological reads + zoom-ins are the ones a
    /// stuck model loops on; the one-shot stats tools (topContacts, count, …)
    /// return a complete answer and are handled by `answerNowHint`, so they
    /// don't count.
    internal static func isReadTool(_ tool: String) -> Bool {
        switch tool {
        case "search", "readMessages", "messagesAroundTime", "context",
             "firstMatching", "oldestMatching", "rawSearchSQL",
             "plansInWindow", "plans", "commitments",
             "friendsMadeSince", "newFriends", "friendsSince":
            return true
        default:
            return false
        }
    }

    /// System prompt for the FORCED final-answer turn (Codex #2.1 / #2.4). NO
    /// tool catalog at all — the model's only legal move is to emit the final
    /// answer JSON. Used after a duplicate tool call or the read-cap, so a
    /// stuck model produces an answer from what it already gathered instead of
    /// spinning until the iteration cap.
    static var forcedFinalAnswerSystemPrompt: String {
        """
        /no_think
        You have already gathered information about the user's iMessage history (shown in the prior tool observations). You CANNOT call any more tools. Your ONLY job now is to write the final answer from what you already have.

        Read the observations above carefully and answer the user's question directly. Cite the specific messages that support your answer.

        Output ONE JSON object, NOTHING else (no prose, no markdown fences, no <think>):
        {"answer":"<2-4 sentence answer grounded in the messages you already read>","hero_index":<index of the single most important message from the most recent observation, or null>,"evidence_indices":[<indices of 2-5 messages that back up your answer>]}
        - For a stats/ranking question (who/how-many/which), hero_index and evidence_indices may be null/[].
        - If the observations genuinely don't contain an answer, say so honestly in `answer` and use null/[].
        - Do NOT ask to run another search. Do NOT emit a "tool" field. Answer NOW.
        """
    }

    /// User prompt for the forced final-answer turn: the question + the full
    /// scratchpad of observations + the explicit "you already called X — do
    /// not repeat it, answer now" signal (Codex #2.4).
    static func buildForcedFinalAnswerPrompt(
        question: String,
        now: Date,
        scratchpad: String,
        reason: String
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)
        return """
        Today's date: \(today)
        Question: \(question)

        What you've already gathered:
        \(scratchpad)

        \(reason)

        Emit ONLY the final answer JSON now.
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
        // Explicit range: "YYYY-MM-DD..YYYY-MM-DD" (optionally with times).
        let parts = trimmed.components(separatedBy: "..")
        if parts.count == 2 {
            let loStr = parts[0].trimmingCharacters(in: .whitespaces)
            let hiStr = parts[1].trimmingCharacters(in: .whitespaces)
            if let lo = NLAgent.parseISODate(loStr),
               var hi = NLAgent.parseISODate(hiStr),
               lo <= hi {
                // INCLUSIVE end (B2): a DATE-ONLY upper bound ("2026-05-31")
                // parses to that day's 00:00:00, so the closed range would
                // silently DROP the entire final day — "2026-05-01..2026-05-31"
                // excluded all of May 31 (here, 175 sent messages). Extend a
                // date-only upper to the last second of that day. A timestamped
                // upper ("...T14:00:00Z") is left exactly as the model meant it.
                let hiIsDateOnly = hiStr.count == 10 && !hiStr.contains("T") && !hiStr.contains(":")
                if hiIsDateOnly {
                    hi = hi.addingTimeInterval(24 * 3600 - 1)
                }
                return lo...hi
            }
        }
        // Bare SINGLE date "YYYY-MM-DD" → that whole calendar day [00:00..23:59:59].
        // Without this, a single date in the `in` arg fell through to nil (NO date
        // filter) → counted ALL messages (observed B2 bug: in:"2026-06-14" →
        // 544,105 instead of ~371 for that day). "on june 14" naturally maps here.
        if trimmed.count == 10, !trimmed.contains("T"), !trimmed.contains(":"),
           let d = NLAgent.parseISODate(trimmed) {
            return d...d.addingTimeInterval(24 * 3600 - 1)
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
