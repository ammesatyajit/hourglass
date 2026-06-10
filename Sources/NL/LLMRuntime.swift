//
//  LLMRuntime.swift
//  Hourglass — Natural-language search
//
//  Abstraction layer over the LLM. Lets us:
//    - Test the agent loop without bundling a 1 GB model.
//    - Swap MLX Swift LM in for the stub when Phase 2 lands.
//    - Add a network-hosted fallback runtime later (NOT recommended; the
//      product promise is local-only) without rewriting `NLAgent`.
//
//  The protocol is intentionally narrow: a single async call that takes a
//  system + user prompt and returns the model's reply as a string. The
//  *interpretation* of that string (JSON parsing, tool-call extraction,
//  retry on malformed output) lives in `NLAgent`, NOT in the runtime — so
//  every runtime can be drop-in replaced.
//
//  See `docs/nl-search-design.md` § Q1 for the runtime rationale (mlx-swift-lm
//  beats Cactus on integration friction, beats llama.cpp on first-party-ness,
//  beats Llama 3.2 3B on latency at no real quality loss).
//

import Foundation

/// Abstraction over a local LLM. Implementations decode/encode messages
/// in their native format but expose a uniform Swift API.
///
/// The runtime is `Sendable` so the agent loop can be driven from a
/// detached background task; the concrete `MLXRuntime` (Phase 2) holds
/// the model behind a serial actor or queue.
public protocol LLMRuntime: Sendable {
    /// Generate a reply for `userPrompt` under `systemPrompt`. Returns
    /// the raw string the model emitted — no JSON parsing, no stripping
    /// of markdown fences, no retries. Caller owns interpretation.
    ///
    /// `maxTokens` bounds the output length. Default 256 is enough for
    /// a typical plan JSON (we've measured ~50 tokens for the canonical
    /// query).
    ///
    /// Throws if the runtime fails to produce output — typical causes:
    /// model file missing, OOM, generation cancelled.
    func respond(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String

    /// Whether the runtime can actually generate right now. False before
    /// the model is downloaded / loaded, true after. The UI uses this to
    /// switch the NL bar between the "Download model" first-run state
    /// and the active state.
    var isReady: Bool { get async }

    /// A short, user-presentable name for the model running here. Shown in
    /// the trace footer ("This was generated locally. Powered by …").
    var modelLabel: String { get }

    /// Release any transient compute resources held after a query finishes.
    /// Called by the view model once a WHOLE NL query completes (not per
    /// tool-call turn). For GPU-backed runtimes this frees the Metal buffer
    /// cache so the GPU + unified memory return to a low-power idle instead
    /// of holding a warm working set — the difference between an idle app
    /// and one that keeps nibbling battery after the answer is on screen.
    /// Default: no-op (the stub holds nothing).
    func releaseResources() async
}

extension LLMRuntime {
    /// Default `maxTokens` for callers that don't care to specify. Sized
    /// for a plan JSON (~50 tokens typical, 256 leaves ample headroom for
    /// reasoning prose if the model decides to chatter).
    public func respond(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        try await respond(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: 256)
    }

    /// Default: nothing to release.
    public func releaseResources() async {}
}

// MARK: - Errors

public enum LLMRuntimeError: Error, CustomStringConvertible, Sendable {
    /// Runtime not initialized — typically the model file isn't downloaded.
    case notReady(reason: String)
    /// Generation failed mid-flight (OOM, cancelled, etc.).
    case generationFailed(underlying: String)
    /// Output exceeded `maxTokens` and was truncated. Caller decides whether
    /// to retry with a larger budget or treat as malformed.
    case truncated

    public var description: String {
        switch self {
        case .notReady(let reason):  return "LLMRuntime not ready: \(reason)"
        case .generationFailed(let u): return "LLM generation failed: \(u)"
        case .truncated:               return "LLM output was truncated"
        }
    }
}

// MARK: - Stub runtime

/// Canned-plan runtime that bypasses any real LLM. Returns hard-coded JSON
/// plans for a small set of canonical queries — enough to drive the agent
/// loop, the dashboard UI, and the test suite end-to-end **without
/// bundling a model**.
///
/// Use this for:
/// - Phase 1 scaffolding (this round) — every code path runs except the
///   real MLX call.
/// - Unit tests — deterministic plan output, no model file required, no
///   tokenization latency on CI.
/// - Demos when you don't want to wait on a ~1 GB download.
///
/// Phase 2 will introduce `MLXRuntime` and swap the default. `StubLLMRuntime`
/// stays in the codebase forever as a test fixture.
public struct StubLLMRuntime: LLMRuntime {

    /// Canned plans keyed by a lowercase normalized query.
    public typealias PlanTable = [String: String]

    /// Built-in canned plans covering the canonical queries from the brief.
    /// Keys are lowercased + collapsed whitespace; values are the verbatim
    /// JSON the agent would receive from a real model.
    public static let defaultPlans: PlanTable = [
        // Canonical: cluster-start + temporal + semantic.
        "find my argument with annika that happened around 2 weeks ago": """
        {
          "intent": "find_cluster_start",
          "person": "Annika",
          "time_window": "last_14d",
          "padding_days": 3,
          "concept": "argument",
          "search_query": "with:\\"Annika\\" last:21d argument"
        }
        """,

        // Deterministic: oldest message in a 1:1.
        "when did i first text howard?": """
        {
          "intent": "find_oldest_message",
          "person": "Howard",
          "time_window": "all_time",
          "concept": null,
          "search_query": "from:\\"Howard\\""
        }
        """,

        // Reactions-driven: most-reacted in a chat.
        "show me the funniest things in the family chat": """
        {
          "intent": "find_messages",
          "person": null,
          "time_window": "all_time",
          "concept": "funny",
          "search_query": "in:\\"family\\" reactions:laugh"
        }
        """,

        // Phrase + person + date.
        "what did mom say about dinner this week?": """
        {
          "intent": "find_messages",
          "person": "mom",
          "time_window": "last_7d",
          "concept": "dinner",
          "search_query": "from:\\"mom\\" last:7d dinner"
        }
        """,

        // Yes/no with proof.
        "did i ever apologize to henry?": """
        {
          "intent": "yes_no_with_proof",
          "person": "Henry",
          "time_window": "all_time",
          "concept": "apology",
          "search_query": "with:\\"Henry\\" apologize"
        }
        """,
    ]

    public let plans: PlanTable
    public let modelLabel: String
    /// Always true for the stub — there's no model file to wait for.
    public var isReady: Bool { get async { true } }

    /// Fallback plan emitted when the query doesn't match any canned entry.
    /// Composed live so we can echo the user's text back into the plan's
    /// `search_query` field — keeps the stub's behavior plausible for novel
    /// queries (we ship a real keyword search built from the input).
    public let fallbackBuilder: @Sendable (_ query: String) -> String

    public init(
        plans: PlanTable = StubLLMRuntime.defaultPlans,
        modelLabel: String = "StubLLMRuntime",
        fallbackBuilder: (@Sendable (String) -> String)? = nil
    ) {
        self.plans = plans
        self.modelLabel = modelLabel
        self.fallbackBuilder = fallbackBuilder ?? Self.defaultFallback
    }

    public func respond(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let normalized = Self.normalize(userPrompt)
        if let canned = plans[normalized] {
            return canned
        }
        return fallbackBuilder(userPrompt)
    }

    /// Lowercase + collapse whitespace + trim trailing punctuation. Lenient
    /// matching so the stub catches `"Find my argument…"` and
    /// `"  find my argument …  "` as the same key.
    static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Collapse multiple whitespace runs to single spaces.
        let parts = lower.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    /// Default fallback: emit a "find_messages" plan with the user's query
    /// as the literal search_query. Permissive — it gets the agent loop
    /// through end-to-end and lets the keyword path handle the result.
    static let defaultFallback: @Sendable (String) -> String = { query in
        // Escape any inline double-quotes so the JSON parses.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "intent": "find_messages",
          "person": null,
          "time_window": "all_time",
          "concept": null,
          "search_query": "\(escaped)"
        }
        """
    }
}
