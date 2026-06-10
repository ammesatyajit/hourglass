//
//  VernacularAILabeler.swift
//  Hourglass — Vernacular Analysis (Layer 4: GATED, optional AI layer)
//
//  The semantic layer for v1. Runs the already-shipped MLX LLM (Qwen via
//  `LLMRuntime`/`MLXRuntime`) ONLY over the ~100-candidate shortlist produced
//  by Layer 1 — NEVER over all messages. For each candidate phrase + 3-4
//  example messages it classifies slang/literal/idiom/repurposed and writes a
//  one-line human description.
//
//  GATING (non-negotiable, same contract as NL search):
//    - This is OPTIONAL. If no runtime is available (model not downloaded /
//      loaded), the panel shows the Layer-1/2/3 results with NO AI labels.
//    - It never blocks the statistical results and never auto-loads the model.
//      The view model only constructs a labeler when `AppDelegate` already has
//      a ready MLX runtime; under XCTest the `underTest` guard in AppDelegate
//      means a labeler is never built.
//
//  CRITICAL CASE the LLM must catch (Layer 2's syntax rule cannot):
//    "my brother in Christ" — VOCATIVE idiom despite the possessive frame.
//    The prompt explicitly primes the model to recognize the idiom; 6 real
//    examples of it exist in the data.
//
//  Embedding-based repurposing detector ("traffic cone"): SCAFFOLDED ONLY in
//  this pass — protocol + stub + the JSD-over-context design left as a TODO.
//  The LLM judge above is the semantic layer for v1. See
//  `VernacularRepurposingDetector` at the bottom of this file.
//

import Foundation
import os

// MARK: - Labeler protocol

/// Assigns AI labels to a shortlist of vernacular candidates. Pure interface;
/// the only impl that does real work is `LLMVernacularLabeler`. A nil labeler
/// (or `NoopVernacularLabeler`) means "no model" → no labels.
public protocol VernacularAILabeling: Sendable {
    /// Label the given candidates. Returns a map keyed by candidate id. May
    /// return fewer entries than asked (skips ones it can't judge). Must
    /// tolerate cancellation and never throw fatally — on error returns what
    /// it has so far (the caller treats missing entries as "no label").
    func label(_ candidates: [VernacularAICandidate]) async -> [String: VernacularAILabel]

    /// Judge a BROAD pool of DISCOVERED snowclone frame candidates: is each one
    /// a genuine snowclone (an expressive fixed frame people creatively fill) or
    /// junk (ordinary grammar, an abbreviation+word, a name/possessive, or
    /// near-constant fills)? Returns a verdict map keyed by candidate id
    /// (`skeleton`); the caller keeps only `true`. Must tolerate cancellation
    /// and never throw fatally. Has a DEFAULT NO-OP so non-LLM conformances
    /// (e.g. `NoopVernacularLabeler`) need no change.
    func judgeFrames(_ frames: [FrameJudgeCandidate]) async -> [String: Bool]

    /// Judge the COUNT-based ANOMALOUS-WORD candidate pool (the rare /
    /// non-ambient / non-name tokens admitted by `discoverAnomalousWords`): is
    /// each one expressive in-group / internet slang (or a repurposed word) to
    /// KEEP, or junk to DROP — a proper noun / name / place / brand (palo,
    /// tesla, matcha, waymo, carti), a foreign word (gracias, hola), a texting
    /// abbreviation (shld, obv, wtv, sry, wyd), or an ordinary literal word
    /// (origami, tendon, surfing)? Candidates are `VernacularAICandidate`s of
    /// kind `.word` (the token in `text`, with 2-3 example messages). Returns a
    /// verdict map keyed by candidate id (the token); the caller keeps only
    /// `true`. Must tolerate cancellation and never throw fatally. Has a DEFAULT
    /// NO-OP so non-LLM conformances need no change (the no-model path keeps the
    /// whole statistical pool — Phase 1 stands).
    func judgeWords(_ words: [VernacularAICandidate]) async -> [String: Bool]

    /// Release transient compute resources after a whole Phase-2 pass finishes.
    /// Default no-op keeps non-LLM conformances source-compatible.
    func releaseResources() async
}

public extension VernacularAILabeling {
    /// Default: judge nothing (the "no model" path leaves the conservative
    /// offline `templates` untouched).
    func judgeFrames(_ frames: [FrameJudgeCandidate]) async -> [String: Bool] { [:] }
    /// Default: judge nothing (the "no model" path keeps the whole statistical
    /// anomalous-word pool — Phase 1 stands, accepting some noise).
    func judgeWords(_ words: [VernacularAICandidate]) async -> [String: Bool] { [:] }
    /// Default: nothing to release.
    func releaseResources() async {}
}

/// The "no model" labeler: returns nothing. The default when MLX isn't ready.
public struct NoopVernacularLabeler: VernacularAILabeling {
    public init() {}
    public func label(_ candidates: [VernacularAICandidate]) async -> [String: VernacularAILabel] { [:] }
    // `judgeFrames` / `judgeWords` inherited from the protocol's default no-op.
}

// MARK: - LLM-backed labeler

/// Drives the shortlist through the shipped `LLMRuntime`. One model call per
/// candidate (the shortlist is ~100 max and the panel labels lazily / caps the
/// batch), each independent so a bad response on one phrase can't corrupt
/// another. Greedy decoding, tiny token budget — these are 1-line judgements.
public struct LLMVernacularLabeler: VernacularAILabeling {

    private let runtime: any LLMRuntime
    /// Hard cap on how many candidates we send the model in one pass, so a
    /// huge shortlist can't pin the GPU. The panel labels the top items first.
    private let maxBatch: Int
    /// Separate (larger) cap for the anomalous-WORD judge: the count-based pool
    /// is the user's whole distinctive vocabulary (~150 by default) and the
    /// judge's JOB is to clean ALL of it (drop the proper-noun / literal tail),
    /// so we judge more words than the 40-item phrase/frame batches. One short
    /// (≤24-token) call each; runs once in a gated background pass.
    private let maxWordBatch: Int

    private static let logger = Logger(subsystem: "com.satyajit.hourglass", category: "VernacularAI")

    public init(runtime: any LLMRuntime, maxBatch: Int = 40, maxWordBatch: Int = 200) {
        self.runtime = runtime
        self.maxBatch = maxBatch
        self.maxWordBatch = maxWordBatch
    }

    public func label(_ candidates: [VernacularAICandidate]) async -> [String: VernacularAILabel] {
        guard await runtime.isReady else { return [:] }
        var out: [String: VernacularAILabel] = [:]
        for cand in candidates.prefix(maxBatch) {
            if Task.isCancelled { break }
            do {
                let userPrompt = autoreleasepool { Self.userPrompt(for: cand) }
                let raw = try await runtime.respond(
                    systemPrompt: Self.systemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: 80
                )
                let parsed = autoreleasepool { Self.parse(raw) }
                if let label = parsed { out[cand.id] = label }
            } catch {
                Self.logger.debug("label('\(cand.text, privacy: .public)') failed: \(String(describing: error), privacy: .public)")
                // skip this one; keep going
            }
        }
        return out
    }

    /// Judge the BROAD discovered frame pool one candidate at a time (same
    /// independent-call shape as `label` so a bad response can't corrupt
    /// another), capped at `maxBatch`. Missing / unparseable verdicts are
    /// omitted (the caller treats them as "drop").
    public func judgeFrames(_ frames: [FrameJudgeCandidate]) async -> [String: Bool] {
        guard await runtime.isReady else { return [:] }
        var out: [String: Bool] = [:]
        for cand in frames.prefix(maxBatch) {
            if Task.isCancelled { break }
            do {
                let userPrompt = autoreleasepool { Self.frameUserPrompt(for: cand) }
                let raw = try await runtime.respond(
                    systemPrompt: Self.frameSystemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: 24
                )
                let parsed = autoreleasepool { Self.parseFrameVerdict(raw) }
                if let keep = parsed { out[cand.id] = keep }
            } catch {
                Self.logger.debug("judgeFrame('\(cand.frame, privacy: .public)') failed: \(String(describing: error), privacy: .public)")
                // skip this one; keep going
            }
        }
        return out
    }

    /// Judge the COUNT-based anomalous-word pool one candidate at a time (same
    /// independent-call shape as `label`/`judgeFrames` so a bad response can't
    /// corrupt another), capped at `maxBatch`. Missing / unparseable verdicts
    /// are KEPT (tolerant — an indecisive model shouldn't silently delete the
    /// user's slang); the caller treats only an explicit `false` as a drop.
    public func judgeWords(_ words: [VernacularAICandidate]) async -> [String: Bool] {
        guard await runtime.isReady else { return [:] }
        var out: [String: Bool] = [:]
        for cand in words.prefix(maxWordBatch) {
            if Task.isCancelled { break }
            do {
                let userPrompt = autoreleasepool { Self.wordUserPrompt(for: cand) }
                let raw = try await runtime.respond(
                    systemPrompt: Self.wordSystemPrompt,
                    userPrompt: userPrompt,
                    maxTokens: 24
                )
                // Tolerant: default KEEP on an unparseable / indecisive reply.
                let parsed = autoreleasepool { Self.parseWordVerdict(raw) }
                out[cand.id] = parsed ?? true
            } catch {
                Self.logger.debug("judgeWord('\(cand.text, privacy: .public)') failed: \(String(describing: error), privacy: .public)")
                // skip this one; keep going (treated as KEEP — absent from `out`
                // means the caller never saw an explicit false).
            }
        }
        return out
    }

    public func releaseResources() async {
        await runtime.releaseResources()
    }

    // MARK: - prompt + parsing (pure, unit-testable)

    static let systemPrompt = """
    You are a linguist labeling expressions from one person's text messages. \
    For the given expression and example uses, output EXACTLY one line of JSON:
    {"kind":"<slang|literal|idiom|repurposed|name>","desc":"<short human description, <=8 words>"}

    Definitions:
    - slang: in-group / internet-native slang ("deadass", "lowkey").
    - idiom: a fixed conventional expression. Treat affectionate vocative \
    address as idiom even when it has a possessive frame — e.g. \
    "my brother in Christ" is a VOCATIVE idiom addressing the listener, NOT a \
    literal statement about a sibling.
    - repurposed: ordinary words given a private in-group meaning ("traffic cone").
    - literal: ordinary literal usage.
    - name: a proper noun (a person/place/brand the statistics let through).
    Output ONLY the JSON line. No prose, no code fences.
    """

    static func userPrompt(for c: VernacularAICandidate) -> String {
        var lines = ["Expression: \"\(c.text)\""]
        if !c.examples.isEmpty {
            lines.append("Examples:")
            for e in c.examples.prefix(4) { lines.append("- \(e.prefix(120))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Tolerant parse: pull the first {...} object, read `kind` + `desc`.
    static func parse(_ raw: String) -> VernacularAILabel? {
        guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi else { return nil }
        let json = String(raw[lo...hi])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let kindRaw = (obj["kind"] as? String)?.lowercased() ?? "unknown"
        let desc = (obj["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = VernacularAILabel.Kind(rawValue: kindRaw) ?? .unknown
        guard !desc.isEmpty || kind != .unknown else { return nil }
        return VernacularAILabel(kind: kind, description: desc)
    }

    // MARK: - frame judge (pure, unit-testable)

    static let frameSystemPrompt = """
    You judge candidate phrase frames mined from one person's text messages. A \
    frame has one blank slot "___". Decide if it is a SNOWCLONE.

    A SNOWCLONE is an EXPRESSIVE FIXED FRAME people creatively fill for effect — \
    the frame is recognizable and the blank is the punchline:
    - "we are so ___" → back, cooked, done
    - "holy ___" → shit, cow, moly
    - "___ ahh" → goofy, weird (the "-ahh" intensifier)
    - "___ -core" / "___ -coded" (derivational suffix)
    NOT a snowclone:
    - ordinary grammar: "i think ___", "going to ___", "do you ___", "are you ___"
    - an abbreviation + a word: "shld ___", "obv ___", "u ___", "im ___"
    - a name or possessive: "venkat ___", "venkat's ___"
    - near-constant fills (the blank almost always the same one or two words).

    Output EXACTLY one line of JSON: {"snowclone":true} or {"snowclone":false}. \
    No prose, no code fences.
    """

    static func frameUserPrompt(for c: FrameJudgeCandidate) -> String {
        var lines = ["Frame: \"\(c.frame)\""]
        if !c.topFills.isEmpty {
            let fills = c.topFills.prefix(6).map { $0.fill }.joined(separator: ", ")
            lines.append("Top fills for ___: \(fills)")
        }
        if !c.examples.isEmpty {
            lines.append("Examples:")
            for e in c.examples.prefix(2) { lines.append("- \(e.prefix(120))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Tolerant parse of the frame verdict: pull the first {...} and read the
    /// boolean `snowclone`. Also tolerates a bare "true"/"false" if the model
    /// skips the JSON. Returns nil when it can't tell (caller drops the frame).
    static func parseFrameVerdict(_ raw: String) -> Bool? {
        if let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi,
           let data = String(raw[lo...hi]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let b = obj["snowclone"] as? Bool { return b }
            if let s = (obj["snowclone"] as? String)?.lowercased() {
                if s == "true" { return true }
                if s == "false" { return false }
            }
        }
        // Fallback: a bare true/false anywhere in the output.
        let low = raw.lowercased()
        if low.contains("true") && !low.contains("false") { return true }
        if low.contains("false") && !low.contains("true") { return false }
        return nil
    }

    // MARK: - word judge (pure, unit-testable)

    static let wordSystemPrompt = """
    You judge candidate words mined from one person's text messages. Decide if a \
    word is SLANG worth keeping in their personal vocabulary.

    KEEP (slang:true) — expressive internet / in-group slang, or an ordinary word \
    given a new in-group meaning:
    - rizz, glaze, cone, crashout, yap, sheesh, blud, chalked, larp, holy, mog, \
    goated, huzz, opp, aura
    DROP (slang:false):
    - proper nouns / names / places / brands: palo, tesla, matcha, waymo, carti
    - foreign words: gracias, hola, oui, salut
    - texting abbreviations: shld, obv, wtv, sry, wyd, tmrw, prolly
    - ordinary literal words: origami, tendon, surfing, dentist, laundry

    You are given the word and 2-3 example messages. Output EXACTLY one line of \
    JSON: {"slang":true} or {"slang":false}. No prose, no code fences.
    """

    static func wordUserPrompt(for c: VernacularAICandidate) -> String {
        var lines = ["Word: \"\(c.text)\""]
        if !c.examples.isEmpty {
            lines.append("Examples:")
            for e in c.examples.prefix(3) { lines.append("- \(e.prefix(120))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Tolerant parse of the word verdict: pull the first {...} and read the
    /// boolean `slang`. Also tolerates a bare "true"/"false" if the model skips
    /// the JSON. Returns nil when it can't tell — the CALLER then defaults to
    /// KEEP (an indecisive model must not silently delete the user's slang).
    static func parseWordVerdict(_ raw: String) -> Bool? {
        if let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi,
           let data = String(raw[lo...hi]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let b = obj["slang"] as? Bool { return b }
            if let s = (obj["slang"] as? String)?.lowercased() {
                if s == "true" { return true }
                if s == "false" { return false }
            }
        }
        // Fallback: a bare true/false anywhere in the output.
        let low = raw.lowercased()
        if low.contains("true") && !low.contains("false") { return true }
        if low.contains("false") && !low.contains("true") { return false }
        return nil
    }
}

// MARK: - Embedding-based repurposing detector (SCAFFOLD ONLY — v2)

/// Detects "repurposed" common phrases (the "traffic cone" class) by the
/// distributional-semantics route the count-based signals provably cannot
/// separate (see plans.md 2026-06-02 "slang detector iteration": raising the
/// over-rep gate did NOT separate "traffic cone" from "makes sense").
///
/// STATUS: scaffold. A protocol + a stub returning `nil`. We deliberately do
/// NOT add an embedding-model SPM dependency in this pass — the LLM judge in
/// `LLMVernacularLabeler` is the semantic layer for v1.
///
/// TODO(v2) — JSD-over-context design (research-backed; refs in plans.md):
///   1. For each candidate phrase, gather its CONTEXT windows (±N tokens
///      around every occurrence) across the user's chats.
///   2. Embed each window with a small on-device model (MLX already ships).
///      Build a reference set of windows for the phrase's LITERAL sense
///      (e.g. from the baseline corpus or a generic web sample).
///   3. Score semantic shift = Jensen-Shannon divergence (or cosine distance)
///      between the in-group usage cluster and the literal-meaning reference.
///      High divergence ⇒ repurposed ("traffic cone": in-group contexts are
///      names/jokes/reactions with no road/orange/construction → diverges);
///      low divergence ⇒ compositional ("makes sense" matches normal usage).
///   Refs: arxiv 2304.01666 (JSD-over-prominence semantic-shift survey),
///         Springer s10579-024-09769-1 (incremental semantic shift).
public protocol VernacularRepurposingDetecting: Sendable {
    /// Returns a 0…1 "repurposing score" per phrase, or an empty map if the
    /// detector isn't available (the v1 stub always returns empty).
    func repurposingScores(for phrases: [String], contexts: [String: [String]]) async -> [String: Double]
}

/// v1 stub: always returns empty. Wiring point for the v2 embedding detector.
public struct StubRepurposingDetector: VernacularRepurposingDetecting {
    public init() {}
    public func repurposingScores(for phrases: [String], contexts: [String: [String]]) async -> [String: Double] {
        // TODO(v2): replace with the JSD-over-context detector described above.
        [:]
    }
}
