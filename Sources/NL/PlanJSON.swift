//
//  PlanJSON.swift
//  Hourglass — Natural-language search
//
//  The structured plan the LLM emits as its first-shot output. Parsed via
//  `Codable` with permissive decoding (missing fields default; unknown
//  fields ignored). The shape is documented in `docs/nl-search-design.md`
//  § Q2 — keep this file in sync with the system prompt the runtime ships.
//
//  The parser is *defensive*: small models like Qwen 2.5 1.5B occasionally
//  emit markdown fences, prose preamble, or trailing chatter. We strip
//  fences, locate the first `{ ... }` block, and parse just that.
//

import Foundation

/// A single LLM-emitted plan. Drives the agent's `execute` step.
public struct PlanJSON: Codable, Sendable, Equatable {

    /// What kind of answer the user is asking for. Drives the post-search
    /// ranking strategy.
    public enum Intent: String, Codable, Sendable, Equatable, CaseIterable {
        /// Generic phrase + filter search. Sort by recency, return all
        /// matches. The default and most common intent.
        case findMessages = "find_messages"

        /// The *first* message ever sent to/from a person. SQL gets
        /// ORDER BY date ASC LIMIT 1.
        case findOldestMessage = "find_oldest_message"

        /// The *latest* message matching the filter. Top-1 of the default
        /// recency-sorted result.
        case findMostRecent = "find_most_recent"

        /// The *start* of an argumentative / topical cluster. Triggers a
        /// second verify-the-context tool call (Phase 3+); Phase 1 falls
        /// back to top-1 of date-sorted candidates.
        case findClusterStart = "find_cluster_start"

        /// "Did X ever happen?" — yes/no answer with a quoted message as
        /// proof. UI surfaces the boolean + the proof row.
        case yesNoWithProof = "yes_no_with_proof"
    }

    /// Relative time-window vocabulary. Mapped to concrete `ClosedRange<Date>`
    /// by the agent (which knows the wall clock — keeping it abstract here
    /// makes the LLM-emitted JSON time-independent and easier to test).
    public enum TimeWindow: String, Codable, Sendable, Equatable, CaseIterable {
        case last24h = "last_24h"
        case last7d = "last_7d"
        case last14d = "last_14d"
        case last30d = "last_30d"
        case last3mo = "last_3mo"
        case last6mo = "last_6mo"
        case last1y = "last_1y"
        case allTime = "all_time"

        /// Convert this abstract window to a concrete date range anchored
        /// at `now`. Returns nil for `all_time` (the SQL search engine
        /// interprets a nil range as "no date filter").
        public func toDateRange(now: Date) -> ClosedRange<Date>? {
            let cal = Calendar(identifier: .gregorian)
            let lower: Date?
            switch self {
            case .last24h:  lower = cal.date(byAdding: .hour,   value: -24,   to: now)
            case .last7d:   lower = cal.date(byAdding: .day,    value: -7,    to: now)
            case .last14d:  lower = cal.date(byAdding: .day,    value: -14,   to: now)
            case .last30d:  lower = cal.date(byAdding: .day,    value: -30,   to: now)
            case .last3mo:  lower = cal.date(byAdding: .month,  value: -3,    to: now)
            case .last6mo:  lower = cal.date(byAdding: .month,  value: -6,    to: now)
            case .last1y:   lower = cal.date(byAdding: .year,   value: -1,    to: now)
            case .allTime:  return nil
            }
            guard let lower else { return nil }
            return lower...now
        }
    }

    public let intent: Intent
    /// Resolved person name, e.g. "Annika". Nil when the query isn't
    /// person-scoped. Matched against `ContactResolver` later.
    public let person: String?
    public let timeWindow: TimeWindow
    /// Optional ± padding around the time window (days). Lets queries like
    /// "around 2 weeks ago" widen the search beyond an exact 14-day cutoff.
    /// The agent applies this by widening the window symmetrically before
    /// search; defaults to 0.
    public let paddingDays: Int
    /// A short conceptual handle for what the user is looking for —
    /// "argument", "vegas plans", "funny". Used by the rank step (Phase 3)
    /// when intent is `find_cluster_start` / `yes_no_with_proof`. Nil for
    /// purely structural queries ("when did I first text X").
    public let concept: String?
    /// The literal structured query string the LLM proposes — uses our
    /// existing operator language (`with:`, `from:`, `last:`, `in:`,
    /// `reactions:`). The agent passes this through to `MessageSearch`.
    public let searchQuery: String

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case intent
        case person
        case timeWindow = "time_window"
        case paddingDays = "padding_days"
        case concept
        case searchQuery = "search_query"
    }

    public init(
        intent: Intent,
        person: String?,
        timeWindow: TimeWindow,
        paddingDays: Int = 0,
        concept: String?,
        searchQuery: String
    ) {
        self.intent = intent
        self.person = person
        self.timeWindow = timeWindow
        self.paddingDays = paddingDays
        self.concept = concept
        self.searchQuery = searchQuery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .findMessages
        self.person = try c.decodeIfPresent(String.self, forKey: .person).flatMap { $0.isEmpty ? nil : $0 }
        self.timeWindow = try c.decodeIfPresent(TimeWindow.self, forKey: .timeWindow) ?? .allTime
        self.paddingDays = try c.decodeIfPresent(Int.self, forKey: .paddingDays) ?? 0
        self.concept = try c.decodeIfPresent(String.self, forKey: .concept).flatMap { $0.isEmpty ? nil : $0 }
        self.searchQuery = try c.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
    }
}

// MARK: - Parser

public enum PlanJSONParser {

    public enum ParseError: Error, CustomStringConvertible, Sendable {
        /// No `{ ... }` block found in the input string.
        case noJSONObjectFound
        /// JSON found but didn't decode into a `PlanJSON`.
        case decodeFailed(underlying: String)

        public var description: String {
            switch self {
            case .noJSONObjectFound:
                return "No JSON object found in LLM output."
            case .decodeFailed(let u):
                return "Failed to decode plan JSON: \(u)"
            }
        }
    }

    /// Locate the first JSON object in `raw` and decode it as a `PlanJSON`.
    ///
    /// Handles common LLM quirks:
    /// - Markdown code fences (``` or ```json) wrapping the JSON.
    /// - Prose preamble ("Here's the plan: { ... }").
    /// - Trailing chatter after the closing brace.
    /// - Slightly malformed JSON with trailing commas (NOT supported — we
    ///   rely on `JSONDecoder`'s strict parsing; the system prompt makes
    ///   the model emit valid JSON).
    public static func parse(_ raw: String) throws -> PlanJSON {
        guard let slice = extractFirstJSONObject(from: raw) else {
            throw ParseError.noJSONObjectFound
        }
        guard let data = slice.data(using: .utf8) else {
            throw ParseError.decodeFailed(underlying: "could not encode JSON slice to utf8")
        }
        do {
            return try JSONDecoder().decode(PlanJSON.self, from: data)
        } catch {
            throw ParseError.decodeFailed(underlying: "\(error)")
        }
    }

    /// Walk `s` and return the first balanced `{ ... }` slice. Returns nil
    /// if no top-level object exists. Brace-counting respects string
    /// literals so JSON values like `"a {b}"` don't confuse the scanner.
    static func extractFirstJSONObject(from s: String) -> String? {
        var depth = 0
        var inString = false
        var escape = false
        var start: String.Index?

        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" {
                    inString = true
                } else if c == "{" {
                    if depth == 0 { start = i }
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0, let s0 = start {
                        let end = s.index(after: i)
                        return String(s[s0..<end])
                    }
                    if depth < 0 {
                        // Malformed — unbalanced closing brace. Reset.
                        depth = 0
                        start = nil
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
