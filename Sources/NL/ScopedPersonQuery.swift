//
//  ScopedPersonQuery.swift
//  Hourglass — Natural-language search
//
//  A DETERMINISTIC "ask about a person (+ optional timeframe)" path that runs
//  BEFORE the brittle plan-JSON planner / ReAct tool loop. No indexing, no
//  agent loop, no plan-JSON — just:
//
//    1. INTENT DETECT (conservative): is this a question scoped to a PERSON
//       (+ optional relative time window)? — e.g. "what did I argue about with
//       Annika around 4 weeks ago". Triggers ONLY when a real person resolves
//       AND the text reads as a question about that person. Otherwise the
//       caller falls through to the existing agent untouched.
//    2. RESOLVE the person → their 1:1 chat (chat.style = 45). NEVER match a
//       group purely because its display name contains the person's name — the
//       exact bug that made `in:"Annika"` surface the "Annika effect" GROUP
//       instead of the Annika 1:1. The person→1:1 resolution lives on
//       `MessageSearchTools` (see `resolveScopedPersonChat`) so every path
//       benefits, not just this one.
//    3. RETRIEVE deterministically: that 1:1's messages within the parsed
//       window, decoded via the real `AttributedBodyDecoder`, chronological,
//       capped to fit the small model's context.
//    4. ONE focused LLM call (NOT a loop): feed the decoded window + the
//       question; ask for a concise natural-language answer + a few evidence
//       message indices.
//    5. RETURN a real `NLQueryResult` whose `explanation` is the answer prose
//       and whose `hero`/`candidates` are the cited evidence messages (real,
//       from the 1:1). `degradedToFallback` is honest — true ONLY when the
//       model genuinely couldn't answer.
//
//  Why a separate file
//  -------------------
//  Keeps the change atomic + independently revertible, and keeps the intent
//  detector / window formatter as PURE testable functions (no DB, no LLM) that
//  `tester-agent` can pin without a chat.db.
//

import Foundation
import os

private let scopedLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-scoped-person"
)

// MARK: - Intent detection (pure)

/// The recognised shape of a scoped person-question, produced by the pure
/// `ScopedPersonQuery.detect(...)` detector. Carries the *raw* person phrase
/// the user typed (resolution to a real contact happens later, against the
/// AddressBook) and the optional relative-time window.
public struct ScopedPersonQuestion: Sendable, Equatable {
    /// The person phrase exactly as it appeared after the with/to/about
    /// preposition — e.g. "Annika", "annika renganathan". Resolution to a
    /// canonical contact + 1:1 chat happens downstream.
    public let personPhrase: String
    /// The discussion verb that anchored the question (argue / talk / …).
    /// Surfaced for the trace + answer-prompt framing.
    public let verb: String
    /// A concrete date window parsed from a relative phrase ("around 4 weeks
    /// ago", "last month", "in May"), or nil when the question carries no
    /// time hint (then we scan the most recent slice of the 1:1).
    public let window: ClosedRange<Date>?
    /// The user-facing label for the window ("around 4 weeks ago",
    /// "recently"), used in the trace + answer prose.
    public let windowLabel: String

    public init(personPhrase: String, verb: String, window: ClosedRange<Date>?, windowLabel: String) {
        self.personPhrase = personPhrase
        self.verb = verb
        self.window = window
        self.windowLabel = windowLabel
    }
}

public enum ScopedPersonQuery {

    /// Discussion verbs that make a sentence read as "a question about a
    /// conversation with someone." Kept tight on purpose — these are the
    /// verbs whose answer is "read the 1:1 and summarize," NOT a keyword hit.
    /// (`text` / `message` included: "what did I text Annika about" is the
    /// same investigative shape.)
    static let discussionVerbs: Set<String> = [
        "argue", "argued", "arguing", "argument",
        "fight", "fought", "fighting",
        "talk", "talked", "talking",
        "discuss", "discussed", "discussing", "discussion",
        "plan", "planned", "planning", "plans",
        "decide", "decided", "deciding", "decision",
        "say", "said", "saying",
        "tell", "told", "telling",
        "text", "texted", "texting",
        "message", "messaged", "messaging",
        "chat", "chatted", "chatting",
        "mention", "mentioned", "mentioning",
        "agree", "agreed", "disagree", "disagreed",
        "promise", "promised",
        "apologize", "apologized", "apologise", "apologised",
        "vent", "vented", "venting",
    ]

    /// Prepositions that introduce the person in these questions. We only
    /// trigger when the person follows one of these — so "photos from June"
    /// (no with/to) and a bare name with no verb won't over-trigger.
    static let personPrepositions: [String] = ["with", "to", "about", "from"]

    /// Question-shaped openers. The query must read like a QUESTION about the
    /// conversation, not a keyword search. We accept the explicit
    /// interrogatives plus the common imperative "find/show me my … with X"
    /// investigative phrasing.
    static let questionMarkers: [String] = [
        "what", "when", "why", "how", "did", "do", "does", "was", "were",
        "had", "have", "has", "find", "show", "tell me", "remind me", "summar",
    ]

    /// Detect whether `query` is a scoped person-question. PURE — no DB, no
    /// network. Returns nil when the query doesn't clearly read as a question
    /// about a conversation with a specific person (the caller then falls
    /// through to the existing agent untouched).
    ///
    /// Conservative by design: requires BOTH (a) a discussion verb, and (b) a
    /// person introduced by with/to/about/from, and (c) a question marker. The
    /// person phrase is returned RAW; the caller must still resolve it to a
    /// real contact + 1:1 chat (and bail to the normal agent if it can't).
    ///
    /// `now` is injected for deterministic tests.
    public static func detect(_ query: String, now: Date = Date()) -> ScopedPersonQuestion? {
        let lower = query.lowercased()

        // (c) Must read as a question / investigative request.
        let looksLikeQuestion = questionMarkers.contains { lower.contains($0) }
            || query.contains("?")
        guard looksLikeQuestion else { return nil }

        // (a) Must contain a discussion verb (token-level, so "talkative"
        // doesn't count). Tokenise on non-letters.
        let tokens = lower.split { !$0.isLetter }.map(String.init)
        guard let verb = tokens.first(where: { discussionVerbs.contains($0) }) else {
            return nil
        }

        // (b) Must introduce a person via with/to/about/from. We capture the
        // contiguous capitalized / lowercase run AFTER the preposition as the
        // candidate person phrase. We deliberately read the ORIGINAL-cased
        // query here so the phrase keeps its casing for the contact resolver.
        guard let personPhrase = extractPersonPhrase(after: personPrepositions, in: query) else {
            return nil
        }
        // Guard against the preposition swallowing a time/word that's clearly
        // not a name ("about dinner", "about that"). A real name resolves
        // downstream; here we just drop obvious non-names so we don't even try.
        guard !isObviousNonName(personPhrase) else { return nil }

        // Optional relative-time window.
        let (window, label) = parseWindow(from: query, now: now)

        return ScopedPersonQuestion(
            personPhrase: personPhrase,
            verb: verb,
            window: window,
            windowLabel: label
        )
    }

    /// Pull the person phrase that follows the FIRST matching preposition.
    /// Returns up to two contiguous "name-shaped" tokens (letters,
    /// apostrophes, hyphens) — enough for "Annika" or "Annika Renganathan",
    /// while stopping at time words, prepositions, and punctuation so we don't
    /// glue "Annika around" together.
    static func extractPersonPhrase(after prepositions: [String], in query: String) -> String? {
        // Work on whitespace tokens but keep original case.
        let rawTokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let lowerTokens = rawTokens.map { $0.lowercased() }

        // Words that must terminate a name run if they appear right after the
        // preposition or mid-run (time markers, fillers, other prepositions).
        let stops: Set<String> = [
            "with", "to", "about", "from", "around", "approximately", "roughly",
            "maybe", "last", "this", "next", "in", "on", "at", "the", "a", "an",
            "ago", "back", "yesterday", "today", "tomorrow", "week", "weeks",
            "month", "months", "year", "years", "day", "days", "recently",
            "and", "or", "that", "regarding", "re",
        ]

        for (i, lt) in lowerTokens.enumerated() {
            let cleaned = lt.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            guard prepositions.contains(cleaned) else { continue }
            // Collect up to two name-shaped tokens after this preposition.
            var nameParts: [String] = []
            var j = i + 1
            while j < rawTokens.count, nameParts.count < 2 {
                let candidateLower = lowerTokens[j]
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters)
                if candidateLower.isEmpty { break }
                if stops.contains(candidateLower) { break }
                // Name-shaped: at least one letter, no digits.
                let token = rawTokens[j].trimmingCharacters(in: CharacterSet.punctuationCharacters)
                guard token.contains(where: { $0.isLetter }),
                      !token.contains(where: { $0.isNumber }) else { break }
                nameParts.append(token)
                j += 1
            }
            if !nameParts.isEmpty {
                return nameParts.joined(separator: " ")
            }
        }
        return nil
    }

    /// Reject phrases that are clearly NOT names so we don't bother resolving
    /// (and so we don't accidentally trigger on "say something about dinner").
    /// The real gate is "does this resolve to a contact"; this just trims the
    /// obvious filler the preposition extractor might pick up.
    static func isObviousNonName(_ phrase: String) -> Bool {
        let nonNames: Set<String> = [
            "it", "them", "this", "that", "these", "those", "something",
            "anything", "everything", "stuff", "things", "dinner", "lunch",
            "work", "school", "me", "him", "her", "us", "you", "myself",
        ]
        return nonNames.contains(phrase.lowercased())
    }

    // MARK: - Window parsing (pure)

    /// Parse a relative / absolute time window from the query. Returns the
    /// concrete range + a user-facing label. Nil range means "no time hint."
    ///
    /// Handles:
    ///   - "around/about N weeks/days/months/years ago" → centered window
    ///     around (now − N units), ±padding scaled to the unit.
    ///   - "last week/month/year", "this week/month/year", "yesterday",
    ///     "recently".
    ///   - "in <Month>" / "in <Month> <Year>" → that calendar month.
    static func parseWindow(from query: String, now: Date) -> (ClosedRange<Date>?, String) {
        let cal = Calendar(identifier: .gregorian)

        // 1. "N units ago" — reuse RuleBasedQueryBuilder's number parsing and
        //    center the window on the target. Pad proportionally to the unit
        //    so "4 weeks ago" doesn't demand the exact day.
        let agoPattern = #"(?i)(?:about|around|approximately|roughly|maybe)?\s*(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month|year)s?\s+(?:ago|back)"#
        if let regex = try? NSRegularExpression(pattern: agoPattern) {
            let ns = NSRange(query.startIndex..., in: query)
            if let m = regex.firstMatch(in: query, range: ns),
               m.numberOfRanges >= 3,
               let nR = Range(m.range(at: 1), in: query),
               let uR = Range(m.range(at: 2), in: query) {
                let nStr = String(query[nR]).lowercased()
                let unit = String(query[uR]).lowercased()
                let n = RuleBasedQueryBuilder.wordToInt(nStr) ?? Int(nStr) ?? 1
                let totalDays = RuleBasedQueryBuilder.daysFor(n: n, unit: unit)
                // Padding: ±3d for "weeks", ±2d for "days", ±10d for "months",
                // ±21d for "years". Wide enough to absorb the fuzziness of NL
                // time, tight enough to keep the window readable.
                let pad: Int
                switch unit {
                case "day": pad = 2
                case "week": pad = 4
                case "month": pad = 10
                default: pad = 21
                }
                if let target = cal.date(byAdding: .day, value: -totalDays, to: now),
                   let lo = cal.date(byAdding: .day, value: -pad, to: target),
                   let hi = cal.date(byAdding: .day, value: pad, to: target) {
                    let label = "around \(n) \(unit)\(n == 1 ? "" : "s") ago"
                    return (lo...hi, label)
                }
            }
        }

        let lower = query.lowercased()

        // 2. Coarse relative phrases.
        func range(daysBack: Int) -> ClosedRange<Date>? {
            guard let lo = cal.date(byAdding: .day, value: -daysBack, to: now) else { return nil }
            return lo...now
        }
        if lower.contains("last month") {
            // The PRIOR calendar month, not "last 30 days" — "what did I plan
            // with X last month" means May when it's June.
            if let startOfThis = cal.date(from: cal.dateComponents([.year, .month], from: now)),
               let startOfPrev = cal.date(byAdding: .month, value: -1, to: startOfThis),
               let endOfPrev = cal.date(byAdding: .second, value: -1, to: startOfThis) {
                return (startOfPrev...endOfPrev, "last month")
            }
        }
        if lower.contains("this month") {
            if let startOfThis = cal.date(from: cal.dateComponents([.year, .month], from: now)) {
                return (startOfThis...now, "this month")
            }
        }
        if lower.contains("last week"), let r = range(daysBack: 14) { return (r, "last week") }
        if lower.contains("this week"), let r = range(daysBack: 7) { return (r, "this week") }
        if lower.contains("last year"), let r = range(daysBack: 730) { return (r, "last year") }
        if lower.contains("this year"), let r = range(daysBack: 365) { return (r, "this year") }
        if lower.contains("yesterday"), let r = range(daysBack: 2) { return (r, "yesterday") }
        if lower.contains("recently"), let r = range(daysBack: 30) { return (r, "recently") }

        // 3. "in <Month> [<Year>]".
        if let monthRange = parseNamedMonth(from: query, now: now) {
            return monthRange
        }

        // No time hint.
        return (nil, "recently")
    }

    static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// Parse "in May", "in May 2026" → that calendar month's range. When no
    /// year is given, pick the most RECENT past occurrence of that month
    /// (matches how people refer to "in May" meaning the last May).
    static func parseNamedMonth(from query: String, now: Date) -> (ClosedRange<Date>, String)? {
        let cal = Calendar(identifier: .gregorian)
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (i, tok) in tokens.enumerated() {
            guard let month = monthNames[tok] else { continue }
            // Optional trailing year.
            var year = cal.component(.year, from: now)
            var hasExplicitYear = false
            if i + 1 < tokens.count, let y = Int(tokens[i + 1]), y >= 2000, y <= 2100 {
                year = y
                hasExplicitYear = true
            }
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = 1
            guard var start = cal.date(from: comps) else { continue }
            // No explicit year + this month is in the FUTURE → use last year.
            if !hasExplicitYear, start > now {
                comps.year = year - 1
                guard let prev = cal.date(from: comps) else { continue }
                start = prev
            }
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: start),
                  let end = cal.date(byAdding: .second, value: -1, to: nextMonth) else { continue }
            let label = "in \(tok.capitalized)\(hasExplicitYear ? " \(year)" : "")"
            return (start...end, label)
        }
        return nil
    }
}

// MARK: - Resolved 1:1 chat (the source-of-truth scoping fix)

/// The outcome of resolving a person phrase → their direct conversation.
/// Lives here (not on `MessageSearch`) so the deterministic path and the
/// ReAct `readMessages` tool can share ONE person→1:1 resolver.
public struct ScopedPersonChat: Sendable, Equatable {
    /// The canonical contact display name we resolved to (for the trace +
    /// prose). Falls back to the raw phrase when the handle wasn't in the
    /// AddressBook but still matched a 1:1 by handle substring.
    public let resolvedName: String
    /// The chat ROWID(s) to read. Normally exactly one 1:1 (style 45). When
    /// the person genuinely has NO 1:1, this holds the group chats they're a
    /// member of (the documented fallback) — but a group is NEVER chosen just
    /// because its display name contains the person's name.
    public let chatRowIDs: [Int64]
    /// True when we found a real 1:1 (style 45). False when we fell back to
    /// group membership. The caller surfaces this honestly in the trace.
    public let isOneToOne: Bool

    public init(resolvedName: String, chatRowIDs: [Int64], isOneToOne: Bool) {
        self.resolvedName = resolvedName
        self.chatRowIDs = chatRowIDs
        self.isOneToOne = isOneToOne
    }
}

// MARK: - The deterministic path (detect → resolve → retrieve → one LLM call)

public extension NLAgent {

    /// How many messages of the 1:1 window we feed the model. Tuned to fit a
    /// small model's context comfortably (~90 msgs × ~40 tokens ≈ 3.6K tokens
    /// plus the question + instructions) while giving enough conversational
    /// context to actually identify what was discussed.
    static let scopedWindowCap = 90
    /// When the question has no time hint we read the most recent slice of the
    /// 1:1 — smaller, since "recently" implies the tail of the conversation.
    static let scopedNoWindowCap = 60

    /// Attempt the DETERMINISTIC scoped person-question path. Returns a fully
    /// composed `NLQueryResult` when the query both (a) reads as a scoped
    /// person-question AND (b) resolves to a real conversation; returns `nil`
    /// otherwise — the caller then falls through to the normal agent loop
    /// UNTOUCHED (so keyword queries like "photos from June" never regress).
    ///
    /// `now` is injected for testability.
    func answerScopedPersonQuestion(
        userQuery: String,
        now: Date = Date()
    ) async -> NLQueryResult? {
        // ----- 1. INTENT DETECT (pure) -----
        guard let question = ScopedPersonQuery.detect(userQuery, now: now) else {
            return nil
        }
        scopedLogger.info("scoped: candidate question person=\"\(question.personPhrase, privacy: .public)\" verb=\(question.verb, privacy: .public) window=\(question.windowLabel, privacy: .public)")

        // ----- 2. RESOLVE person → 1:1 chat (the source-level scoping fix) ---
        let resolved: ScopedPersonChat?
        do {
            resolved = try await tools.resolveScopedPersonChat(named: question.personPhrase)
        } catch {
            scopedLogger.notice("scoped: resolveScopedPersonChat threw — \(String(describing: error), privacy: .public); falling through to normal agent")
            return nil
        }
        guard let chat = resolved else {
            // Person didn't resolve to any conversation — this isn't really a
            // scoped person-question we can answer deterministically. Fall
            // through to the normal agent (which may still keyword-search).
            scopedLogger.info("scoped: \"\(question.personPhrase, privacy: .public)\" resolved to NO chat — deferring to normal agent")
            return nil
        }
        scopedLogger.info("scoped: resolved \"\(question.personPhrase, privacy: .public)\" → \(chat.resolvedName, privacy: .public) chats=\(chat.chatRowIDs.map(String.init).joined(separator: ","), privacy: .public) isOneToOne=\(chat.isOneToOne, privacy: .public)")

        // ----- 3. RETRIEVE deterministically -----
        let cap = question.window == nil ? Self.scopedNoWindowCap : Self.scopedWindowCap
        let window = await scopedRetrieve(chat: chat, question: question, cap: cap)
        guard !window.isEmpty else {
            // No messages in the requested window. Honest degraded answer
            // pointing at the right conversation + window — NOT a fabricated
            // "Found N messages."
            scopedLogger.info("scoped: 0 messages in window for \(chat.resolvedName, privacy: .public)")
            let trace = [
                NLTraceStep(phase: .searching,
                            label: "Read \(chat.resolvedName)\(chat.isOneToOne ? " (1:1)" : " (group)") \(question.windowLabel)",
                            status: .complete, duration: 0),
            ]
            let explanation = "I couldn't find any messages with \(chat.resolvedName) \(question.windowLabel) to answer that. Try a different time window."
            return NLQueryResult(
                hero: nil,
                candidates: [],
                trace: trace,
                plan: nil,
                fallbackQuery: scopedFallbackQuery(chat: chat, question: question),
                explanation: explanation,
                degradedToFallback: true
            )
        }

        // ----- 4. ONE focused LLM call (NOT a loop) -----
        let startAll = Date()
        let llmStart = Date()
        let raw: String
        do {
            raw = try await runtime.respond(
                systemPrompt: Self.scopedAnswerSystemPrompt,
                userPrompt: Self.scopedAnswerUserPrompt(
                    question: question,
                    chat: chat,
                    window: window
                ),
                maxTokens: 512
            )
        } catch {
            scopedLogger.notice("scoped: runtime.respond threw — \(String(describing: error), privacy: .public); honest degrade")
            return scopedDegradedResult(chat: chat, question: question, window: window, llmFailed: true)
        }
        scopedLogger.info("scoped: raw answer (\(raw.count, privacy: .public) chars): \(raw, privacy: .public)")

        // ----- 5. RETURN a real NLQueryResult -----
        let parsed = ScopedAnswerParser.parse(raw)
        guard let answer = parsed, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The model genuinely produced nothing usable. Honest degrade —
            // but still hand back the real window so the user sees the right
            // conversation (NOT a generic "Found N").
            scopedLogger.notice("scoped: model produced no usable answer; honest degrade")
            return scopedDegradedResult(chat: chat, question: question, window: window, llmFailed: false)
        }

        // Reorder candidates so the cited evidence surfaces first (hero +
        // next few). De-duped by message id; uncited messages follow in
        // chronological order. Indices are into `window`.
        var head: [MessageSearch.Result] = []
        var seen = Set<Int64>()
        for idx in answer.evidenceIndices where idx >= 0 && idx < window.count {
            let r = window[idx]
            if seen.insert(r.message.id).inserted { head.append(r) }
        }
        let tail = window.filter { !seen.contains($0.message.id) }
        let ordered = head + tail
        let hero = ordered.first

        let llmSeconds = Date().timeIntervalSince(llmStart)
        let totalSeconds = Date().timeIntervalSince(startAll)
        let trace: [NLTraceStep] = [
            NLTraceStep(phase: .planning,
                        label: "Scoped to your conversation with \(chat.resolvedName)",
                        status: .complete, duration: nil),
            NLTraceStep(phase: .searching,
                        label: "Read \(window.count) messages with \(chat.resolvedName)\(chat.isOneToOne ? "" : " (group — no 1:1 found)") \(question.windowLabel)",
                        status: .complete, duration: nil),
            NLTraceStep(phase: .answering,
                        label: "Summarized \(window.count) messages",
                        status: .complete, duration: llmSeconds),
            NLTraceStep(phase: .answering,
                        label: "Done in \(Self.formatDuration(totalSeconds))",
                        status: .complete, duration: totalSeconds),
        ]

        return NLQueryResult(
            hero: hero,
            candidates: Array(ordered.prefix(50)),
            trace: trace,
            plan: nil,
            fallbackQuery: scopedFallbackQuery(chat: chat, question: question),
            explanation: answer.text,
            degradedToFallback: false
        )
    }

    /// Pull the 1:1 window from the resolved chat. Kept separate so the
    /// orchestration reads cleanly + so this is the one place that decides
    /// the retrieval shape.
    private func scopedRetrieve(
        chat: ScopedPersonChat,
        question: ScopedPersonQuestion,
        cap: Int
    ) async -> [MessageSearch.Result] {
        let results = (try? await tools.readMessagesInChats(
            rowIDs: chat.chatRowIDs,
            in: question.window,
            limit: cap
        )) ?? []
        return results
    }

    /// A structured-query string the user can drop into the Spotlight panel
    /// to reproduce the window. Uses `chat:` (1:1-scoped) when we have a 1:1.
    private func scopedFallbackQuery(chat: ScopedPersonChat, question: ScopedPersonQuestion) -> String {
        // Use the resolved name; `chat:` matches the 1:1 by participant.
        let nameToken = chat.resolvedName.contains(" ")
            ? "chat:\"\(chat.resolvedName)\""
            : "chat:\(chat.resolvedName)"
        return nameToken
    }

    /// Build an honest degraded result that still surfaces the real window —
    /// used when the model fails or returns nothing usable. Never fabricates a
    /// "Found N messages" claim; says plainly that it couldn't summarize.
    private func scopedDegradedResult(
        chat: ScopedPersonChat,
        question: ScopedPersonQuestion,
        window: [MessageSearch.Result],
        llmFailed: Bool
    ) -> NLQueryResult {
        let trace = [
            NLTraceStep(phase: .searching,
                        label: "Read \(window.count) messages with \(chat.resolvedName) \(question.windowLabel)",
                        status: .complete, duration: nil),
            NLTraceStep(phase: .answering,
                        label: llmFailed ? "Model unavailable" : "Couldn't summarize the conversation",
                        status: .failed, duration: nil),
        ]
        let explanation = "Here are your messages with \(chat.resolvedName) \(question.windowLabel); I couldn't summarize what was discussed."
        return NLQueryResult(
            hero: window.first,
            candidates: Array(window.prefix(50)),
            trace: trace,
            plan: nil,
            fallbackQuery: scopedFallbackQuery(chat: chat, question: question),
            explanation: explanation,
            // Honest: we have the messages, but the ANSWER genuinely failed.
            degradedToFallback: true
        )
    }

    // MARK: - One-shot answer prompt

    static let scopedAnswerSystemPrompt: String = """
    /no_think
    You are reading a slice of a private 1:1 text conversation and answering ONE question about it. The messages are numbered and shown oldest → newest, each as `[index] timestamp Sender: text`.

    Read the conversation, then answer the user's question in 1-3 plain sentences describing what was actually discussed / argued / decided. Ground every claim in the messages — quote a short phrase when it helps. If the conversation does not contain an answer, say so briefly and honestly.

    Output ONE JSON object, NOTHING else (no prose, no markdown fences, no <think>):
    {"answer":"<1-3 sentence answer grounded in the messages>","evidence_indices":[<2-3 indices of the messages that best support the answer>]}

    - answer: written for the user ("You and Annika argued about …"). Concise.
    - evidence_indices: the indices (from the list below) of the 2-3 most relevant messages. Pick real, on-topic lines.
    """

    /// Compose the one-shot user prompt: question + the rendered window.
    static func scopedAnswerUserPrompt(
        question: ScopedPersonQuestion,
        chat: ScopedPersonChat,
        window: [MessageSearch.Result]
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE MMM d HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let lines = window.enumerated().map { (i, r) -> String in
            let ts = df.string(from: r.message.date)
            let who = r.message.isFromMe ? "You" : r.senderName
            let body = r.message.body
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let clipped = body.count > 300 ? String(body.prefix(300)) + "…" : body
            return "[\(i)] \(ts) \(who): \(clipped)"
        }.joined(separator: "\n")

        return """
        Question: \(question.text(resolvedName: chat.resolvedName))

        Conversation with \(chat.resolvedName) (\(question.windowLabel), \(window.count) messages, oldest first):
        \(lines)

        Answer the question now as the JSON object.
        """
    }
}

// MARK: - Answer prompt helpers

extension ScopedPersonQuestion {
    /// A clean restatement of the user's question for the answer prompt,
    /// substituting the canonical resolved name.
    func text(resolvedName: String) -> String {
        "What did I \(verb) about with \(resolvedName) \(windowLabel)?"
    }
}

// MARK: - Parse the model's one-shot answer

/// The decoded one-shot answer: prose + the message indices the model cited.
struct ScopedAnswer: Equatable {
    let text: String
    let evidenceIndices: [Int]
}

/// Tolerant parser for the one-shot answer JSON. Reuses the same brace-scan +
/// `<think>`-strip the ReAct parser uses, and accepts the loose
/// `evidence_indices` shapes small models emit (array of ints, numeric
/// strings, or a single int). Falls back to treating the whole cleaned output
/// as the answer prose when no JSON object is present (so a model that emits a
/// bare sentence still produces a usable answer rather than degrading).
enum ScopedAnswerParser {
    static func parse(_ raw: String) -> ScopedAnswer? {
        let cleaned = NLToolCallParser.stripThinkBlocks(raw)
        guard !cleaned.isEmpty else { return nil }

        if let slice = PlanJSONParser.extractFirstJSONObject(from: cleaned),
           let data = slice.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let answer = (json["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var evidence: [Int] = []
            if let arr = json["evidence_indices"] as? [Any] {
                for e in arr {
                    if let i = e as? Int { evidence.append(i) }
                    else if let d = e as? Double { evidence.append(Int(d)) }
                    else if let s = e as? String, let i = Int(s) { evidence.append(i) }
                }
            } else if let one = json["evidence_indices"] as? Int {
                evidence = [one]
            } else if let d = json["evidence_indices"] as? Double {
                evidence = [Int(d)]
            }
            if let answer, !answer.isEmpty {
                return ScopedAnswer(text: answer, evidenceIndices: evidence)
            }
        }

        // No JSON / no answer field — but if the model emitted readable prose
        // (and not just a fragment of JSON), use it verbatim. Reject outputs
        // that are obviously a broken JSON skeleton.
        let looksLikeJSONSkeleton = cleaned.hasPrefix("{") && !cleaned.contains(" ")
        if !looksLikeJSONSkeleton, cleaned.count >= 8 {
            return ScopedAnswer(text: cleaned, evidenceIndices: [])
        }
        return nil
    }
}
