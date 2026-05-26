//
//  NLQueryResult.swift
//  Hourglass — Natural-language search
//
//  The answer shape returned by `NLAgent.answer(...)`. Designed for the
//  dashboard NL bar: one hero row, full reasoning trace, all candidates
//  the agent considered for transparency, plus a fallback structured
//  query the user can drop into the Spotlight panel if the NL answer
//  doesn't satisfy.
//

import Foundation

/// Single trace step in the agent's reasoning. Rendered live in the NL
/// bar's expanded UI so the user can watch progress instead of staring
/// at a spinner.
///
/// Step labels are pre-baked strings (NOT LLM-generated). They appear
/// deterministically as the agent enters each phase. The user sees real
/// progress without latency-sensitive token streaming.
public struct NLTraceStep: Sendable, Equatable, Identifiable {

    public enum Phase: String, Sendable, Equatable, CaseIterable {
        case planning      // LLM emitting the JSON plan
        case searching     // running search tools
        case ranking       // verifying / picking the hero
        case answering     // composing the final answer
    }

    public enum Status: String, Sendable, Equatable {
        case inProgress    // step is running, spinner UI
        case complete      // step finished successfully (checkmark)
        case failed        // step errored — surface to user
    }

    public let id: UUID
    public let phase: Phase
    public let label: String          // e.g. "Planning…", "Searching `<query>`"
    public let status: Status
    /// Duration in seconds for completed steps; nil while in-progress.
    public let duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        phase: Phase,
        label: String,
        status: Status,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.phase = phase
        self.label = label
        self.status = status
        self.duration = duration
    }
}

/// Final shape returned by `NLAgent.answer(...)`. The dashboard NL bar
/// binds to this struct's fields.
public struct NLQueryResult: Sendable, Equatable {

    /// The single best match. Nil when the search returned zero candidates
    /// (UI surfaces a "no results" state with the fallback query).
    public let hero: MessageSearch.Result?

    /// Every candidate the agent's search tools returned, in the order
    /// the agent considered them. The hero is index 0 if present.
    /// Capped at 50 in the agent to keep the disclosure UI manageable.
    public let candidates: [MessageSearch.Result]

    /// The reasoning trace, oldest step first. The dashboard renders this
    /// as a numbered list.
    public let trace: [NLTraceStep]

    /// The parsed plan the LLM emitted. Surfaced for debugging + the
    /// "see what the agent thought" affordance in the UI.
    public let plan: PlanJSON?

    /// A structured-query string the user can drop into the Spotlight
    /// panel as a fallback. ALWAYS populated — even when the NL agent
    /// succeeded, this is the query the keyword path would run to
    /// reproduce the result set. Useful for "see all 12 matches in
    /// Spotlight" CTAs.
    public let fallbackQuery: String

    /// Optional human-readable explanation. For `find_cluster_start`
    /// intents, e.g. "Picked the May 9 message because the previous 5
    /// in this chat were about dinner plans." Nil when no explanation
    /// is warranted.
    public let explanation: String?

    /// True when an unrecoverable failure short-circuited the loop and
    /// the result is purely a fallback. UI shows a clearly-worded
    /// "couldn't process this query" message instead of a hero row.
    public let degradedToFallback: Bool

    public init(
        hero: MessageSearch.Result?,
        candidates: [MessageSearch.Result],
        trace: [NLTraceStep],
        plan: PlanJSON?,
        fallbackQuery: String,
        explanation: String? = nil,
        degradedToFallback: Bool = false
    ) {
        self.hero = hero
        self.candidates = candidates
        self.trace = trace
        self.plan = plan
        self.fallbackQuery = fallbackQuery
        self.explanation = explanation
        self.degradedToFallback = degradedToFallback
    }
}
