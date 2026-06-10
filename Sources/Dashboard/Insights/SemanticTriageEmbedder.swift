//
//  SemanticTriageEmbedder.swift
//  Hourglass — Vernacular Analysis (Codex upgrade #2: rare-tail context-embedding triage)
//
//  The on-device, GATED embedding layer that rescues the ultra-rare slang the
//  count/rarity admission provably cannot (yap ×29, crashout ×7, mog, goated,
//  huzz, npc, opp — statistically indistinguishable from rare typos by frequency).
//  We embed each candidate's CONTEXT (masked-target windows) with Apple's
//  on-device `NLContextualEmbedding`, then score against the confirmed-slang
//  centroids (the PURE scorer in `VernacularAnomalies.swift`).
//
//  GATING (non-negotiable, same contract as the LLM judge):
//    - `NLContextualEmbedding` needs downloadable language assets. We check
//      `hasAvailableAssets`; if absent we kick `requestAssets` (non-blocking) and
//      RETURN NIL for this pass → the caller FALLS BACK to the existing two-tier
//      admission (no regression, no crash). Assets become available for a later run.
//    - All compute is Phase-2 background work; it never blocks Phase 1 / the UI.
//
//  DECOUPLING: the candidate-lake construction, k-means, and scoring all live in
//  `VernacularAnomalies.swift` as PURE functions that take embeddings via an
//  injected `(String) -> [Float]?` closure — so they are unit-testable with
//  stubbed vectors and the pure analysis file never imports NaturalLanguage.
//  The Phase-1 profile has its own bounded post-extraction semantic-shift pass;
//  this file remains the reusable contextual-vector helper for the older rare
//  tail triage path.
//

import Foundation
import NaturalLanguage
import os

// MARK: - injectable embedding interface

/// Produces ONE mean-pooled context vector per token from that token's context
/// windows. Pure interface so the triage scorer can be driven by a stub in tests
/// and by `NLContextEmbedder` in the app. Returns nil for a token it can't embed
/// (too few windows, or the backend is unavailable → the caller falls back).
public protocol ContextVectorizing: Sendable {
    /// True iff this vectorizer can actually produce vectors right now (assets
    /// present / model ready). When false the caller skips the triage entirely.
    var isAvailable: Bool { get }
    /// Mean-pool each token's windows into one vector. `windows` maps token → its
    /// (already masked) context-window strings. Returns token → vector for the
    /// tokens it could embed; omits the rest. Tolerates cancellation.
    func vectors(for windows: [String: [String]]) -> [String: [Float]]
}

// MARK: - Apple NLContextualEmbedding backend (gated)

/// Wraps `NLContextualEmbedding` (on-device contextual embeddings). Gated on
/// `hasAvailableAssets`; reports `isAvailable == false` when assets are missing
/// (and kicks a non-blocking `requestAssets` so a later run can use them).
///
/// `NLContextualEmbedding` is a non-`Sendable` reference type, so we do NOT store
/// it — the struct holds only value types (the language + availability), and the
/// model is constructed + loaded LAZILY inside `vectors(for:)` (once per batch).
/// That keeps `NLContextEmbedder` a clean `Sendable` value the VM can capture in a
/// detached task. Availability is probed once at construction.
public struct NLContextEmbedder: ContextVectorizing {

    private let language: NLLanguage
    public let isAvailable: Bool

    private static let logger = Logger(subsystem: "com.satyajit.hourglass", category: "SemanticTriage")

    /// Build for `language` (default English). Probes asset availability: if
    /// assets aren't present we kick `requestAssets` (non-blocking) and report
    /// `isAvailable == false` so the caller FALLS BACK; construction never blocks
    /// on a download.
    public init(language: NLLanguage = .english) {
        self.language = language
        guard let emb = NLContextualEmbedding(language: language) else {
            self.isAvailable = false; return
        }
        if emb.hasAvailableAssets {
            self.isAvailable = true
        } else {
            emb.requestAssets { status, _ in
                Self.logger.debug("NLContextualEmbedding requestAssets → \(String(describing: status), privacy: .public)")
            }
            self.isAvailable = false
        }
    }

    public func vectors(for windows: [String: [String]]) -> [String: [Float]] {
        guard isAvailable, let embedding = NLContextualEmbedding(language: language),
              embedding.hasAvailableAssets, (try? embedding.load()) != nil
        else { return [:] }
        defer { embedding.unload() }
        var out: [String: [Float]] = [:]
        out.reserveCapacity(windows.count)
        for (token, wins) in windows {
            if Task.isCancelled { break }
            var acc: [Float] = []
            var n = 0
            for w in wins {
                // CRITICAL: drain per window. `embeddingResult(...)` returns
                // autoreleased ObjC objects (per-token vector buffers); over the
                // ~tens-of-thousands of windows in the candidate lake they pile up
                // un-freed until the whole batch returns → multi-GB spike / OOM.
                // The pooled [Float] is a Swift value and survives the pool.
                autoreleasepool {
                    guard !w.isEmpty,
                          let pooled = Self.meanPooledVector(of: w, embedding: embedding, language: language)
                    else { return }
                    if acc.isEmpty { acc = pooled }
                    else if acc.count == pooled.count { for i in acc.indices { acc[i] += pooled[i] } }
                    else { return }
                    n += 1
                }
            }
            guard n > 0 else { continue }
            let inv = 1.0 / Float(n)
            out[token] = acc.map { $0 * inv }
        }
        return out
    }

    /// Mean-pool the per-token contextual vectors of `text` into one vector.
    /// Returns nil if the embedding produced no vectors.
    static func meanPooledVector(of text: String, embedding: NLContextualEmbedding,
                                 language: NLLanguage) -> [Float]? {
        guard let result = try? embedding.embeddingResult(for: text, language: language) else { return nil }
        var sum: [Float] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vec, _ in
            // `vec` is [Double]; accumulate as Float.
            if sum.isEmpty { sum = vec.map { Float($0) } }
            else if sum.count == vec.count { for i in sum.indices { sum[i] += Float(vec[i]) } }
            count += 1
            return true
        }
        guard count > 0, !sum.isEmpty else { return nil }
        let inv = 1.0 / Float(count)
        return sum.map { $0 * inv }
    }
}
