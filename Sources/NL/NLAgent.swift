//
//  NLAgent.swift
//  Hourglass — Natural-language search
//
//  The plan → execute → answer loop. Stateless (every call creates a
//  fresh trace). Composes:
//    - `LLMRuntime` for the planner
//    - `NLAgentTools` for search execution
//    - `PlanJSONParser` for output decoding
//    - the agent's *own* fallback logic when the LLM misbehaves
//
//  Design notes
//  ------------
//  - No streaming: the LLM call is one-shot. Reasoning trace is emitted
//    via pre-baked step labels (see `NLTraceStep`), not token streaming.
//  - The agent NEVER generates message content. Hero text always comes
//    from a real `MessageSearch.Result`.
//  - The fallback path (LLM unavailable, malformed JSON, etc.) always
//    runs the user's literal query through the search engine. So even
//    when the LLM goes sideways, the user gets *something* useful.
//

import Foundation
import os

/// Diagnostics for the NL agent. Filter in Console.app:
///   subsystem == "com.satyajit.bettermessages" && category == "nl-agent"
/// Every planner call logs:
///   - the user query (private; gated by the os Logger privacy rules)
///   - the raw LLM output (public — we need to see how the model emitted
///     the JSON to debug planner failures)
///   - the parse outcome (success → plan fields; failure → error + raw)
///   - retry attempts when the first parse fails
/// All three are essential for diagnosing the "planner failed" trace
/// the user sees in the dashboard NL bar; reasoning blindly about why
/// a 1.5B model didn't emit valid JSON is not allowed.
private let nlAgentLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-agent"
)

/// Stateless agent that converts an NL query → structured plan → search
/// results → answer. Composes runtime + tools at init; every call to
/// `answer` is independent and cancellable.
public final class NLAgent: Sendable {

    public let runtime: LLMRuntime
    public let tools: NLAgentTools

    /// The system prompt sent with every plan request. Kept verbatim
    /// here so `MLXRuntime` and `StubLLMRuntime` use the same instructions.
    /// If you change this prompt, also re-tune `StubLLMRuntime.defaultPlans`
    /// so canned outputs still match the contract.
    ///
    /// Prompt design notes
    /// -------------------
    /// (Originally tuned for Qwen 2.5 1.5B; the model now defaults to
    /// Gemma 4 E2B IT — same prompt works because both follow concrete
    /// examples better than abstract schemas. Keep these heuristics
    /// when iterating.)
    /// - Lead with the ONE concrete example. Small instruct models follow
    ///   the most recent / most concrete pattern in the prompt, not the
    ///   abstract schema description.
    /// - Few-shot examples cover the canonical query repertoire from the
    ///   design doc (Q3). Each shows one fresh decision (intent choice,
    ///   person extraction, time window inference, search_query OR-joining).
    /// - Hard-line the "respond ONLY with JSON, no prose, no fences" rule.
    /// - Keep under ~800 tokens for the system prompt. Even though Gemma
    ///   4 has a much larger context, instruction following degrades
    ///   when the prompt sprawls, and the user query already eats some
    ///   budget.
    /// - `search_query` examples teach the operator vocabulary AND the
    ///   OR pattern for concept expansion (argument → "argument fight
    ///   disagreement upset"). Concept OR widens recall for fuzzy intents.
    public static let plannerSystemPrompt: String = """
    You convert iMessage search questions into JSON plans. Output ONE JSON object — NO prose, NO markdown fences, NO explanation. Just the JSON.

    Schema (all fields required, use null when unknown):
    {"intent": "find_messages|find_oldest_message|find_most_recent|find_cluster_start|yes_no_with_proof", "person": "Name or null", "time_window": "last_24h|last_7d|last_14d|last_30d|last_3mo|last_6mo|last_1y|all_time", "padding_days": 0, "concept": "short topic or null", "search_query": "operator string"}

    search_query operators: with:"Name" (any chat — 1:1 or group — that this person participates in), from:"Name" (messages sent BY person), in:"chat name" (substring on the chat's display name; for a specific named chat), last:7d (or 14d/30d/3mo/1y), reactions:love|laugh|like. Combine with spaces. For fuzzy concepts use OR-joined synonyms: argument fight disagree upset.

    Examples:

    Q: find my argument with annika that happened maybe 2 weeks ago
    {"intent":"find_cluster_start","person":"Annika","time_window":"last_14d","padding_days":7,"concept":"argument","search_query":"with:\\"Annika\\" last:21d argument fight disagree upset"}

    Q: when did I first text Howard?
    {"intent":"find_oldest_message","person":"Howard","time_window":"all_time","padding_days":0,"concept":null,"search_query":"with:\\"Howard\\""}

    Q: what plans did Erik and I make about vegas
    {"intent":"find_messages","person":"Erik","time_window":"all_time","padding_days":0,"concept":"vegas plans","search_query":"with:\\"Erik\\" vegas"}

    Q: show me funny things from the family chat
    {"intent":"find_messages","person":null,"time_window":"all_time","padding_days":0,"concept":"funny","search_query":"in:\\"family\\" reactions:laugh"}

    Q: did mom say anything about dinner this week?
    {"intent":"find_messages","person":"Mom","time_window":"last_7d","padding_days":0,"concept":"dinner","search_query":"from:\\"Mom\\" last:7d dinner"}

    Q: did I ever apologize to Henry?
    {"intent":"yes_no_with_proof","person":"Henry","time_window":"all_time","padding_days":0,"concept":"apology","search_query":"with:\\"Henry\\" apologize sorry"}
    """

    /// Retry prompt sent on parser failure. Re-issues the same task with a
    /// pointer back to the failure mode, so the model can recover. Capped
    /// at one retry (2 attempts total) to keep latency under ~5s.
    static func retrySystemPrompt(previousOutput: String, parseError: String) -> String {
        // Truncate the raw output so a runaway model doesn't blow our context.
        let snippet = String(previousOutput.prefix(400))
        return """
        \(plannerSystemPrompt)

        IMPORTANT: Your previous output failed to parse with: \(parseError).
        Previous output started with: \(snippet)
        Output ONLY the JSON object now. No prose, no markdown fences, no commentary.
        """
    }

    public init(runtime: LLMRuntime, tools: NLAgentTools) {
        self.runtime = runtime
        self.tools = tools
    }

    // MARK: - Main entry point

    /// Run the full plan → execute → answer loop for `userQuery`.
    /// Returns a fully composed `NLQueryResult`, ready for the UI to bind.
    ///
    /// `now` is injected for testability — passing a fixed date in tests
    /// keeps the time-window resolution deterministic.
    ///
    /// `maxCandidates` caps the disclosure-list size (50 is a sensible
    /// default — beyond that, the user is better served by escalating
    /// to the Spotlight panel).
    public func answer(
        userQuery: String,
        now: Date = Date(),
        maxCandidates: Int = 50
    ) async -> NLQueryResult {

        var trace: [NLTraceStep] = []
        let startAll = Date()

        // ----- Phase 1: Plan -----
        let planStart = Date()
        let planningStep = NLTraceStep(phase: .planning, label: "Planning…", status: .inProgress)
        trace.append(planningStep)

        var plan: PlanJSON? = nil
        var rawLLMOutput: String? = nil
        var lastParseError: String? = nil
        nlAgentLogger.info("planner: query=\"\(userQuery, privacy: .public)\"")
        do {
            // Attempt 1: standard prompt.
            let raw = try await runtime.respond(
                systemPrompt: Self.plannerSystemPrompt,
                userPrompt: userQuery,
                maxTokens: 256
            )
            rawLLMOutput = raw
            // Log the raw output BEFORE attempting to parse — diagnosing
            // "planner failed" requires seeing exactly what Qwen emitted.
            nlAgentLogger.info("planner: attempt1 raw output (\(raw.count, privacy: .public) chars): \(raw, privacy: .public)")

            do {
                let parsed = try PlanJSONParser.parse(raw)
                plan = parsed
                nlAgentLogger.info("planner: attempt1 parsed OK — intent=\(parsed.intent.rawValue, privacy: .public) person=\(parsed.person ?? "nil", privacy: .public) tw=\(parsed.timeWindow.rawValue, privacy: .public) query=\(parsed.searchQuery, privacy: .public)")
            } catch {
                lastParseError = String(describing: error)
                nlAgentLogger.notice("planner: attempt1 parse FAILED (\(lastParseError ?? "unknown", privacy: .public)); retrying once with stricter prompt")

                // Attempt 2: stricter prompt mentioning the prior failure.
                let retryPrompt = Self.retrySystemPrompt(
                    previousOutput: raw,
                    parseError: lastParseError ?? "unknown"
                )
                let raw2 = try await runtime.respond(
                    systemPrompt: retryPrompt,
                    userPrompt: userQuery,
                    maxTokens: 256
                )
                rawLLMOutput = raw2
                nlAgentLogger.info("planner: attempt2 raw output (\(raw2.count, privacy: .public) chars): \(raw2, privacy: .public)")
                do {
                    let parsed = try PlanJSONParser.parse(raw2)
                    plan = parsed
                    nlAgentLogger.info("planner: attempt2 parsed OK after retry")
                } catch {
                    lastParseError = String(describing: error)
                    nlAgentLogger.error("planner: attempt2 parse FAILED (\(lastParseError ?? "unknown", privacy: .public)); falling through to rule-based fallback")
                }
            }

            if let parsed = plan {
                trace[trace.count - 1] = NLTraceStep(
                    id: planningStep.id,
                    phase: .planning,
                    label: Self.planLabel(for: parsed),
                    status: .complete,
                    duration: Date().timeIntervalSince(planStart)
                )
            }
        } catch {
            // Runtime threw before we even got an output string (model not
            // loaded, OOM, cancelled). Distinct from parse failure.
            nlAgentLogger.error("planner: runtime.respond threw — \(String(describing: error), privacy: .public)")
        }

        if plan == nil {
            trace[trace.count - 1] = NLTraceStep(
                id: planningStep.id,
                phase: .planning,
                label: lastParseError == nil
                    ? "Planner unavailable — using rule-based query"
                    : "Couldn't parse plan — using rule-based query",
                status: .failed,
                duration: Date().timeIntervalSince(planStart)
            )
        }

        // If planning failed, route directly to fallback. The fallback
        // builder produces a sensible keyword search from the input.
        guard let plan else {
            return await runFallback(
                userQuery: userQuery,
                trace: trace,
                now: now,
                maxCandidates: maxCandidates,
                rawLLMOutput: rawLLMOutput
            )
        }

        // ----- Phase 2: Execute -----
        let searchStart = Date()
        let searchingStep = NLTraceStep(
            phase: .searching,
            label: "Searching `\(plan.searchQuery)`…",
            status: .inProgress
        )
        trace.append(searchingStep)

        // Resolve the time window into a concrete range. The plan may also
        // include a `padding_days` to widen the window symmetrically.
        let baseRange = plan.timeWindow.toDateRange(now: now)
        let widenedRange = Self.widen(baseRange, by: plan.paddingDays)

        var candidates: [MessageSearch.Result] = []
        var resolvedSearchQuery = plan.searchQuery
        do {
            candidates = try await tools.search(
                query: plan.searchQuery,
                dateRange: widenedRange,
                limit: maxCandidates
            )
            // FALLBACK 2A: synonym widening.
            //
            // The planner often emits OR-style synonym keywords like
            // `with:"Annika" last:21d argument fight disagree upset` because
            // the prompt encourages concept expansion. But the engine
            // currently AND's bare keywords, so 4 synonyms guarantees
            // 0 hits — none of the four words co-occur in real messages.
            //
            // When the AND'd query returns nothing, retry with each
            // keyword in isolation (effectively OR'ing them). Take the
            // first non-empty result set. This trades latency (up to N
            // extra searches) for non-zero recall, which is the right
            // tradeoff for NL queries where the user's emotional intent
            // doesn't lexically match the message body.
            if candidates.isEmpty {
                let synonyms = Self.extractBareKeywords(from: plan.searchQuery)
                if synonyms.count >= 2 {
                    let operators = Self.extractOperators(from: plan.searchQuery)
                    nlAgentLogger.info("execute: 0 hits on AND'd query; widening via OR over \(synonyms.count, privacy: .public) synonyms")
                    for syn in synonyms {
                        let altQuery = (operators + [syn]).joined(separator: " ")
                        let alt = (try? await tools.search(
                            query: altQuery,
                            dateRange: widenedRange,
                            limit: maxCandidates
                        )) ?? []
                        if !alt.isEmpty {
                            candidates = alt
                            resolvedSearchQuery = altQuery
                            nlAgentLogger.info("execute: synonym \"\(syn, privacy: .public)\" → \(alt.count, privacy: .public) hits")
                            break
                        }
                    }
                }
            }
            trace[trace.count - 1] = NLTraceStep(
                id: searchingStep.id,
                phase: .searching,
                label: "Found \(candidates.count) candidate\(candidates.count == 1 ? "" : "s")",
                status: .complete,
                duration: Date().timeIntervalSince(searchStart)
            )
        } catch {
            trace[trace.count - 1] = NLTraceStep(
                id: searchingStep.id,
                phase: .searching,
                label: "Search failed: \(error)",
                status: .failed,
                duration: Date().timeIntervalSince(searchStart)
            )
            return NLQueryResult(
                hero: nil,
                candidates: [],
                trace: trace,
                plan: plan,
                fallbackQuery: plan.searchQuery,
                degradedToFallback: true
            )
        }

        // ----- Phase 3: Rank / pick hero -----
        let rankStart = Date()
        let rankingStep = NLTraceStep(
            phase: .ranking,
            label: Self.rankingLabel(for: plan.intent, candidateCount: candidates.count),
            status: .inProgress
        )
        trace.append(rankingStep)

        let (hero, explanation) = await pickHero(
            from: candidates,
            plan: plan
        )

        trace[trace.count - 1] = NLTraceStep(
            id: rankingStep.id,
            phase: .ranking,
            label: Self.heroLabel(hero: hero, plan: plan),
            status: .complete,
            duration: Date().timeIntervalSince(rankStart)
        )

        // ----- Phase 4: Compose answer -----
        let answerStart = Date()
        let answeringStep = NLTraceStep(
            phase: .answering,
            label: "Done in \(Self.formatDuration(Date().timeIntervalSince(startAll)))",
            status: .complete,
            duration: Date().timeIntervalSince(answerStart)
        )
        trace.append(answeringStep)

        return NLQueryResult(
            hero: hero,
            candidates: Array(candidates.prefix(maxCandidates)),
            trace: trace,
            plan: plan,
            fallbackQuery: resolvedSearchQuery,
            explanation: explanation,
            degradedToFallback: false
        )
    }

    // MARK: - Fallback path

    /// Run when the LLM plan can't be obtained or parsed. We synthesize a
    /// rule-based query from the user's input — person extraction against
    /// the real AddressBook, date extraction via `DateParser`, stopword
    /// pruning, and concept-OR keyword expansion.
    ///
    /// The result is a real structured query the existing `MessageSearch`
    /// engine understands, e.g. `with:"Annika" last:21d argument fight
    /// disagree`. The naive previous version joined all input words with
    /// AND, which guaranteed zero hits on natural-language phrasing.
    private func runFallback(
        userQuery: String,
        trace: [NLTraceStep],
        now: Date,
        maxCandidates: Int,
        rawLLMOutput: String?
    ) async -> NLQueryResult {
        var trace = trace
        let contactNames = await tools.availableContactNames()
        let built = RuleBasedQueryBuilder.build(
            from: userQuery,
            contactNames: contactNames,
            now: now
        )
        let fallbackQuery = built.query
        nlAgentLogger.info("fallback: input=\"\(userQuery, privacy: .public)\" → query=\"\(fallbackQuery, privacy: .public)\" (person=\(built.person ?? "nil", privacy: .public), date=\(built.dateOperator ?? "nil", privacy: .public), concepts=\(built.concepts.joined(separator: ","), privacy: .public))")

        let searchStart = Date()
        let step = NLTraceStep(
            phase: .searching,
            label: "Searching `\(fallbackQuery)`…",
            status: .inProgress
        )
        trace.append(step)

        let candidates: [MessageSearch.Result]
        do {
            candidates = try await tools.search(
                query: fallbackQuery,
                dateRange: nil,
                limit: maxCandidates
            )
        } catch {
            trace[trace.count - 1] = NLTraceStep(
                id: step.id,
                phase: .searching,
                label: "Fallback search failed: \(error)",
                status: .failed,
                duration: Date().timeIntervalSince(searchStart)
            )
            return NLQueryResult(
                hero: nil,
                candidates: [],
                trace: trace,
                plan: nil,
                fallbackQuery: fallbackQuery,
                degradedToFallback: true
            )
        }

        trace[trace.count - 1] = NLTraceStep(
            id: step.id,
            phase: .searching,
            label: "Found \(candidates.count) candidate\(candidates.count == 1 ? "" : "s") via rule-based fallback",
            status: .complete,
            duration: Date().timeIntervalSince(searchStart)
        )

        // Build a short user-facing explanation so the bar shows WHAT the
        // fallback did, not a generic "couldn't parse" line.
        var explanationParts: [String] = []
        if let p = built.person { explanationParts.append("recognised \(p)") }
        if let d = built.dateOperator { explanationParts.append("interpreted time as \(d)") }
        if !built.concepts.isEmpty { explanationParts.append("searched \(built.concepts.joined(separator: " / "))") }
        let explanation: String? = explanationParts.isEmpty
            ? "I couldn't parse the natural-language query precisely; ran it as a keyword search."
            : "Couldn't reach the model — " + explanationParts.joined(separator: ", ") + "."

        return NLQueryResult(
            hero: candidates.first,
            candidates: candidates,
            trace: trace,
            plan: nil,
            fallbackQuery: fallbackQuery,
            explanation: explanation,
            degradedToFallback: true
        )
    }

    // MARK: - Helpers

    /// Pick the hero from the candidate list according to `plan.intent`.
    /// Returns (hero, explanation). Explanation is non-nil when the choice
    /// involves reasoning the user benefits from seeing.
    private func pickHero(
        from candidates: [MessageSearch.Result],
        plan: PlanJSON
    ) async -> (MessageSearch.Result?, String?) {
        guard !candidates.isEmpty else { return (nil, nil) }
        switch plan.intent {
        case .findOldestMessage:
            // Candidates come back DESC; oldest is the tail.
            return (candidates.last, "Oldest matching message.")

        case .findMostRecent:
            return (candidates.first, nil)

        case .findClusterStart:
            // Phase 1: pick the candidate whose 5 preceding messages are
            // NOT all from the same chat (proxy for "this isn't the
            // middle of an ongoing conversation"). If we can't verify, just
            // pick the oldest candidate in the date-narrowed window.
            //
            // The verify pass is OFF for Phase 1 (no extra LLM hops) —
            // the date-window pre-narrowing already gives us a good
            // approximation since the user's "around 2 weeks ago" pins
            // us to a focused slice. We pick the oldest candidate in
            // that slice as the cluster start.
            let oldest = candidates.last
            let explanation = oldest.map { _ in
                "Picked the oldest matching message in the time window — likely the start of the topic."
            }
            return (oldest, explanation)

        case .yesNoWithProof:
            // If any candidate matches, return the most recent as proof.
            return (candidates.first, "Found a match — see the message below as proof.")

        case .findMessages:
            return (candidates.first, nil)
        }
    }

    /// Extract bare-keyword tokens (those WITHOUT a `prefix:` operator).
    /// Used by the synonym-OR fallback path: when an AND'd query like
    /// `with:"Annika" last:21d argument fight disagree upset` returns 0
    /// hits, we retry each bare keyword in isolation. Tokens that contain
    /// `:` (operator tokens) are filtered out; quoted segments are preserved.
    static func extractBareKeywords(from query: String) -> [String] {
        // Reuse the tokenisation behaviour the search engine itself uses —
        // split on whitespace, keeping quoted segments together. We don't
        // need full operator parsing because we only care about WHICH
        // tokens are bare (no `:` before whitespace).
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for c in query {
            if c == "\"" {
                inQuotes.toggle()
                current.append(c)
            } else if c.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { !$0.contains(":") }
    }

    /// Inverse of `extractBareKeywords` — return only the operator tokens
    /// (those WITH `:` or quoted operator values).
    static func extractOperators(from query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for c in query {
            if c == "\"" {
                inQuotes.toggle()
                current.append(c)
            } else if c.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.filter { $0.contains(":") }
    }

    /// Widen a date range symmetrically by `paddingDays` on each side.
    /// Returns nil if `range` is nil (no padding to apply).
    static func widen(_ range: ClosedRange<Date>?, by paddingDays: Int) -> ClosedRange<Date>? {
        guard let range, paddingDays > 0 else { return range }
        let interval = TimeInterval(paddingDays) * 24 * 60 * 60
        let lower = range.lowerBound.addingTimeInterval(-interval)
        let upper = range.upperBound.addingTimeInterval(interval)
        return lower...upper
    }

    /// Short user-facing description of the plan, e.g.
    /// "argument with Annika, last 14 days (±3d)".
    static func planLabel(for plan: PlanJSON) -> String {
        var parts: [String] = []
        if let concept = plan.concept, !concept.isEmpty {
            parts.append(concept)
        }
        if let person = plan.person, !person.isEmpty {
            parts.append("with \(person)")
        }
        switch plan.timeWindow {
        case .allTime: break
        default:
            var win = plan.timeWindow.rawValue.replacingOccurrences(of: "_", with: " ")
            if plan.paddingDays > 0 {
                win += " (±\(plan.paddingDays)d)"
            }
            parts.append(win)
        }
        if parts.isEmpty {
            return "Plan: \(plan.intent.rawValue)"
        }
        return "Plan: " + parts.joined(separator: ", ")
    }

    static func rankingLabel(for intent: PlanJSON.Intent, candidateCount: Int) -> String {
        switch intent {
        case .findClusterStart:
            return "Picking the cluster start from \(candidateCount) candidate\(candidateCount == 1 ? "" : "s")…"
        case .findOldestMessage:
            return "Finding the oldest match…"
        case .yesNoWithProof:
            return "Looking for proof…"
        default:
            return "Ranking \(candidateCount) candidate\(candidateCount == 1 ? "" : "s")…"
        }
    }

    static func heroLabel(hero: MessageSearch.Result?, plan: PlanJSON) -> String {
        guard let hero else { return "No matches" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return "Picked \(hero.senderName) on \(fmt.string(from: hero.message.date))"
    }

    static func formatDuration(_ s: TimeInterval) -> String {
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        return String(format: "%.1fs", s)
    }

    /// Build a permissive keyword query from `userQuery`. Strategy:
    /// 1. Strip common NL filler ("find", "show me", "around", "ago", "the").
    /// 2. Preserve proper-noun-shaped words (capitalized, len > 2) as-is.
    /// 3. Apply a simple relative-date heuristic ("last week", "2 weeks ago"
    ///    → `last:7d`/`last:14d`).
    /// Doesn't aim for correctness; aims for *plausibility* so the search
    /// engine has something to chew on instead of an unfiltered "all messages".
    public static func bestEffortKeywordQuery(from userQuery: String) -> String {
        let cleaned = userQuery
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stopwords: Set<String> = [
            "find", "show", "me", "the", "a", "an", "around", "ago",
            "that", "what", "when", "where", "who", "why", "did", "do",
            "i", "you", "my", "your", "have", "had", "has", "ever",
            "about", "with", "and", "but", "or", "so", "if", "is", "are",
            "in", "on", "at", "to", "from", "of", "for", "as", "by",
            "this", "these", "those", "any", "happened", "saying", "say",
        ]

        // Relative date heuristic: detect "(N) (week|weeks|day|days|month|months|year|years) ago"
        // and "this week / last week / this year" patterns.
        var dateOperator: String? = nil
        let lower = cleaned.lowercased()
        if lower.contains("this week") { dateOperator = "last:7d" }
        else if lower.contains("last week") { dateOperator = "last:14d" }
        else if lower.contains("this month") { dateOperator = "last:30d" }
        else if lower.contains("this year") { dateOperator = "last:365d" }
        // Match patterns like "2 weeks ago", "three days ago"
        let regex = try? NSRegularExpression(
            pattern: #"(\d+)\s+(day|week|month|year)s?\s+ago"#,
            options: [.caseInsensitive]
        )
        if dateOperator == nil, let regex {
            let r = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            if let m = regex.firstMatch(in: cleaned, range: r),
               m.numberOfRanges >= 3,
               let nRange = Range(m.range(at: 1), in: cleaned),
               let unitRange = Range(m.range(at: 2), in: cleaned),
               let n = Int(cleaned[nRange]) {
                let unit = cleaned[unitRange].lowercased()
                let totalDays: Int
                switch unit {
                case "day":   totalDays = n
                case "week":  totalDays = n * 7
                case "month": totalDays = n * 30
                case "year":  totalDays = n * 365
                default:      totalDays = n
                }
                // Widen slightly because NL "2 weeks ago" is fuzzy.
                let padded = max(totalDays + 7, totalDays)
                dateOperator = "last:\(padded)d"
            }
        }

        // Pull content words.
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !stopwords.contains($0.lowercased()) }
            .filter { $0.count > 1 }
            .filter { !$0.contains("week") && !$0.contains("day") && !$0.contains("month") && !$0.contains("year") && !$0.contains("ago") }

        var out = tokens.joined(separator: " ")
        if let op = dateOperator {
            out = "\(op) \(out)"
        }
        return out.trimmingCharacters(in: .whitespaces).isEmpty ? userQuery : out
    }
}
