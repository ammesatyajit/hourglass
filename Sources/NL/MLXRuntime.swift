//
//  MLXRuntime.swift
//  Hourglass — Natural-language search
//
//  Concrete `LLMRuntime` impl backed by `mlx-swift-lm`'s `ChatSession`.
//  Phase 2 of the NL search lift: real local LLM inference via MLX on
//  Apple Silicon. Implements the same protocol as `StubLLMRuntime` so
//  `NLAgent` doesn't notice the swap.
//
//  Concurrency
//  -----------
//  An `actor` because:
//    1. `ChatSession` mutates KV-cache state across calls. Two `respond`
//       calls in parallel would step on each other's KV cache and produce
//       garbage tokens.
//    2. The underlying `ModelContext` references Metal allocations that
//       want a single-owner pattern.
//  Actor isolation = the simplest correct serialization. The agent loop
//  is already async and waits for each LLM call before issuing the next,
//  so the serialization isn't a throughput loss.
//
//  Lifecycle
//  ---------
//  An `MLXRuntime` is born WITH an already-loaded `ModelContainer` —
//  download is owned by `ModelDownloader`. The runtime constructs a fresh
//  `ChatSession` per `respond()` call so each prompt is independent (no
//  multi-turn history leaks between agent invocations). Building a
//  ChatSession is cheap (~ms); building a model is expensive (~1 s warm
//  + 1 GB RAM resident). We pay the expensive cost once.
//

import Foundation
import MLX
import MLXLMCommon
import MLXLLM

public enum MLXRuntimeError: Error, CustomStringConvertible, Sendable {
    /// The model container handed in was nil (caller picked the wrong code
    /// path — should have stayed on the stub runtime).
    case modelNotLoaded
    /// Inference threw mid-flight. `underlying` is the typed description.
    case inferenceFailed(underlying: String)

    public var description: String {
        switch self {
        case .modelNotLoaded:
            return "MLXRuntime: model container not loaded"
        case .inferenceFailed(let u):
            return "MLXRuntime inference failed: \(u)"
        }
    }
}

/// Local-LLM runtime backed by MLX on Apple Silicon. Holds a reference to a
/// shared `ModelContainer` and produces fresh `ChatSession` instances per
/// query. Actor-isolated to serialize Metal calls.
public actor MLXRuntime: LLMRuntime {

    /// Loaded model. Provided by the caller (typically `ModelDownloader`).
    private let container: ModelContainer

    /// Display name surfaced in the trace footer ("Powered by …").
    public nonisolated let modelLabel: String

    /// Which chat-template family the loaded model belongs to. Drives the
    /// per-family render-kwarg handling in `respond` — only Qwen3 honours
    /// (and needs) `enable_thinking`. See `NLModelFamily`.
    private nonisolated let family: NLModelFamily

    /// Marker capturing whether we successfully exercised the model after
    /// construction. Set true after the first call returns — the
    /// `ChatSession` interface lazily warms on first use, and a failure at
    /// construction time isn't reliably detectable. We treat "constructed
    /// with a non-nil container" as "ready" because `ModelDownloader`'s
    /// `.ready` state already gates on successful load.
    public nonisolated var isReady: Bool { get async { true } }

    /// Preferred initializer — derives the label AND the chat-template family
    /// from the model id, so the runtime is correct for BOTH Qwen3 (default
    /// Standard/4B) and Qwen2.5-Instruct (opt-in High/7B) without the caller
    /// having to know the per-family quirks.
    public init(container: ModelContainer, modelID: String) {
        self.container = container
        self.family = NLModelPreference.family(forModelID: modelID)
        self.modelLabel = NLModelPreference.displayLabel(forModelID: modelID)
    }

    /// Explicit initializer — kept so call sites that want to hand in a
    /// specific label/family can. Defaults to the Qwen3-4B Standard mode
    /// (the new default model) so any incidental caller gets the right
    /// template handling rather than the stale 1.7B label.
    public init(
        container: ModelContainer,
        modelLabel: String = NLModelQuality.standard.displayLabel,
        family: NLModelFamily = .qwen3
    ) {
        self.container = container
        self.modelLabel = modelLabel
        self.family = family
    }

    /// Generate a structured plan via the model. We construct a fresh
    /// `ChatSession` per call — see header comment for rationale.
    public func respond(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            // 0.0 = greedy decoding. Right call for JSON: any randomness
            // can produce structurally-invalid output. The downstream
            // parser is tolerant but a non-deterministic plan makes
            // regression tests harder, and the win from sampling
            // diversity is zero on a structured task.
            temperature: 0.0
        )

        // CHAT-TEMPLATE HANDLING IS PER-FAMILY (see `NLModelFamily`):
        //
        // • Qwen3 (default Standard/4B): the template emits a `<think>…</think>`
        //   reasoning block BEFORE its answer unless `enable_thinking=false`
        //   is passed as a template render kwarg. We measured the cost: every
        //   ReAct turn spent ~10s generating a think block, and a small model's
        //   low-quality reasoning then RE-called the same tool instead of
        //   answering — 8 turns × 10s = 83s with no final answer ("who did I
        //   text the most" looped topContacts ×8). The soft-switch `/no_think`
        //   in the prompt did NOT suppress it (the mlx-community template
        //   ignores it); the template kwarg does. With this off, a tool-call
        //   turn drops to ~1–3s. `additionalContext` is mlx-swift-lm's
        //   documented passthrough to the template's render kwargs.
        //
        // • Qwen2.5-Instruct (opt-in High/7B): NO reasoning mode — its
        //   template never references `enable_thinking` and never emits
        //   `<think>`. We deliberately DON'T pass the kwarg here so the render
        //   kwargs match exactly what the 2.5 template expects (a stray kwarg
        //   would be ignored by Jinja, but matching the template's contract is
        //   the correct, future-proof behaviour). The `/no_think` token left
        //   in the system prompt is a harmless no-op for this family.
        let additionalContext: [String: any Sendable]? = family.supportsEnableThinkingKwarg
            ? ["enable_thinking": false]
            : nil
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters,
            additionalContext: additionalContext
        )

        do {
            return try await session.respond(to: userPrompt)
        } catch is CancellationError {
            throw LLMRuntimeError.generationFailed(underlying: "cancelled")
        } catch {
            throw MLXRuntimeError.inferenceFailed(underlying: String(describing: error))
        }
    }

    /// Free the Metal buffer cache once a whole NL query is done. MLX
    /// keeps a pool of GPU buffers warm between evaluations for speed;
    /// after the answer is on screen we don't need them, and holding the
    /// working set keeps the GPU + unified memory in an elevated power
    /// state. Clearing returns the device to idle. The model WEIGHTS stay
    /// resident in the `ModelContainer` (cheap to keep, expensive to
    /// reload) — this only drops the transient activation/KV buffers, so
    /// the next query just re-warms the cache (a few ms) rather than
    /// reloading the model. Net: no battery drain at rest, negligible
    /// latency cost. The model container is unaffected.
    public func releaseResources() async {
        MLX.GPU.clearCache()
    }
}
