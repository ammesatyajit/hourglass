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

    /// Marker capturing whether we successfully exercised the model after
    /// construction. Set true after the first call returns — the
    /// `ChatSession` interface lazily warms on first use, and a failure at
    /// construction time isn't reliably detectable. We treat "constructed
    /// with a non-nil container" as "ready" because `ModelDownloader`'s
    /// `.ready` state already gates on successful load.
    public nonisolated var isReady: Bool { get async { true } }

    public init(
        container: ModelContainer,
        modelLabel: String = "Qwen 2.5 1.5B (MLX)"
    ) {
        self.container = container
        self.modelLabel = modelLabel
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

        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: parameters
        )

        do {
            return try await session.respond(to: userPrompt)
        } catch is CancellationError {
            throw LLMRuntimeError.generationFailed(underlying: "cancelled")
        } catch {
            throw MLXRuntimeError.inferenceFailed(underlying: String(describing: error))
        }
    }
}
