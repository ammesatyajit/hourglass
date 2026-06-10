//
//  VernacularAnalyzer.swift
//  Hourglass — Vernacular Analysis (Layer 1 statistical + Layer 3 attribution)
//
//  The pure engine behind "Your Vernacular." Ported faithfully from the four
//  validated standalone prototypes that run against the real chat.db:
//    • /tmp/slang3 — slang phrases (NPMI + over-rep + content/register/title
//      gates + spread), social uptake (amused reactions + downstream
//      laughter), repurposed-common-phrase detector, "… word?" approval tags,
//      caps-vocative constructions.
//    • /tmp/vern   — formulaic skeleton templates (interior-blank wrap-around
//      frames) with real fill-in examples, distinctiveness vs received.
//    • /tmp/report — lexical-term attribution (who used it before you).
//    • /tmp/bro    — vocative/literal sense-splitting (now Layer 2,
//      `VernacularSenseRules`).
//
//  METHOD — slang phrase score (the signal stack that works, no model):
//    interesting = (max(over-rep − 2.5, 0.2) + 2.6·NPMI)
//                  · (1 + 1.6·min(uptake/use, 3))     ← social uptake
//                  · (1 + 0.35·max(0, ln(recencyRise)))
//    gated by: spread ≥ 3 people, over-rep > 3.2, carries a non-register
//    word, lowercase-dominant (Title-case ratio < 0.5 → not a proper noun).
//
//  METHOD — DECISIVE attribution (Layer 3, tightened from /tmp/report):
//    A source is reported ONLY if it is unambiguous: used the term ≥5× BEFORE
//    your first use, AND its first use is ≥30 days before yours, AND it is the
//    dominant early user (its before-count ≥ 2× the runner-up, OR it is the
//    sole qualifier). Otherwise → nil (ambient / no clear source). The label
//    is "first seen in your texts" — attribution only sees iMessage, so we
//    never claim invention or that you "got it from" them.
//
//  Everything here is PURE and deterministic over value-type inputs. The
//  chat.db read that produces `[VernacularMessage]` lives in
//  `VernacularLoader` and is the only impure part.
//

import Foundation

public enum VernacularAnalyzer {

    // MARK: - Tunables

    public struct Options: Sendable {
        /// Min raw count for a bigram/trigram to enter the candidate pool.
        public var minPhraseCount: Int
        /// Min distinct people who must use a slang phrase (spread).
        public var minSpread: Int
        /// Over-representation gate for slang phrases.
        public var slangOverRepGate: Double
        /// Min times a template must appear (by you) to surface.
        public var minTemplateCount: Int
        /// Min count for an approval tag.
        public var minTagCount: Int
        /// Attribution: min times a source used a term BEFORE you.
        public var attributionMinBefore: Int
        /// Attribution: min days the source must precede your first use.
        public var attributionMinDays: Double
        /// Attribution: source's before-count must be ≥ this × the runner-up.
        public var attributionDominanceRatio: Double
        /// How many items to return per category.
        public var topK: Int

        public init(
            minPhraseCount: Int = 15,
            minSpread: Int = 3,
            slangOverRepGate: Double = 3.2,
            minTemplateCount: Int = 18,
            minTagCount: Int = 40,
            attributionMinBefore: Int = 5,
            attributionMinDays: Double = 30,
            attributionDominanceRatio: Double = 2.0,
            topK: Int = 18
        ) {
            self.minPhraseCount = minPhraseCount
            self.minSpread = minSpread
            self.slangOverRepGate = slangOverRepGate
            self.minTemplateCount = minTemplateCount
            self.minTagCount = minTagCount
            self.attributionMinBefore = attributionMinBefore
            self.attributionMinDays = attributionMinDays
            self.attributionDominanceRatio = attributionDominanceRatio
            self.topK = topK
        }

        public static let `default` = Options()
    }

    // MARK: - Entry point

    /// Run the full statistical + attribution analysis. PURE.
    ///
    /// - Parameters:
    ///   - messages: all scanned messages (sent + received), date-ascending.
    ///   - baseline: the bundled English unigram distribution (for over-rep).
    ///   - signatureWords: distinctive unigrams already computed by
    ///     `LinguisticAnalyzer` (reused, not recomputed).
    ///   - options: tunables.
    public static func analyze(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        signatureWords: [VernacularSignatureWord],
        options: Options = .default
    ) -> VernacularInsights {

        let sentCount = messages.reduce(0) { $0 + ($1.fromMe ? 1 : 0) }
        guard sentCount > 0 else { return VernacularInsights() }

        // ---- shared corpus stats (unigram + n-gram counts) ----
        let stats = CorpusStats(messages: messages, baseline: baseline)

        // ---- slang phrases + repurposed (Layer 1) ----
        let (slang, repurposed) = stats.rankPhrases(options: options)

        // ---- templates with examples (Layer 1) ----
        let templates = TemplateMiner.mine(messages: messages, baseline: baseline, options: options)

        // ---- tags + caps-vocative constructions (Layer 1) ----
        let tags = stats.approvalTags(options: options)
        let constructions = stats.capsVocativeConstructions()

        // ---- sense splits (Layer 2) ----
        let senseSplits = stats.senseSplits()

        // ---- decisive attribution (Layer 3) ----
        // Candidate terms = a curated lexical-slang seed (the kind of words
        // that DO get caught off a friend, validated in /tmp/report) + the
        // user's own distinctive signature words + the surfaced slang phrases.
        // Proper-noun phrases ("wei li") and name-like signature words get
        // marked ambient by the decisive gate and are dropped by the
        // source != nil filter, so over-including is harmless — the seed list
        // just ensures genuinely-attributable lexis ("big bro", "lil bro") is
        // always evaluated even if it didn't top another category.
        var attrTerms: [String] = Self.attributionSeedTerms
        attrTerms.append(contentsOf: signatureWords.prefix(14).map { $0.word })
        attrTerms.append(contentsOf: slang.prefix(8).map { $0.phrase })
        // de-dup, preserve order
        var seen = Set<String>()
        attrTerms = attrTerms.filter { seen.insert($0).inserted }
        // OCCURRENCE-INDEX path (Codex consult #4, Pass A): build the term→postings
        // inverted index ONCE over the corpus, then derive each term's decisive
        // attribution from its postings. Replaces the old per-term re-scan
        // (`attrTerms.map { attribute(term:messages:) }`, which scanned all ~532k
        // messages ≥2× PER term). Output is byte-identical — a SPEED change only.
        let attributions = attributeAll(terms: attrTerms, messages: messages, options: options)
            .filter { $0.yourCount >= options.attributionMinBefore }

        return VernacularInsights(
            totalMessages: messages.count,
            sentMessages: sentCount,
            signatureWords: signatureWords,
            slangPhrases: Array(slang.prefix(options.topK)),
            repurposedPhrases: Array(repurposed.prefix(12)),
            templates: Array(templates.prefix(12)),
            tags: Array(tags.prefix(10)),
            constructions: constructions,
            attributions: attributions,
            senseSplits: senseSplits
        )
    }

    // MARK: - DECISIVE attribution (Layer 3)

    /// Find who used `term` heavily before you — but report a source ONLY when
    /// it's decisive. See file header for the exact rule. Returns nil for a
    /// term you don't use; a `VernacularAttribution` with `source == nil` for
    /// "ambient / no clear source."
    ///
    /// Single-word terms match by word-set membership (so "im" doesn't match
    /// inside "time"); phrases match by substring on the lowercased body —
    /// same matching rule as the validated `/tmp/report` prototype.
    public static func attribute(
        term: String,
        messages: [VernacularMessage],
        options: Options = .default
    ) -> VernacularAttribution? {
        // OCCURRENCE-FED (Codex consult #4, Pass A): collect THIS term's postings
        // in ONE linear pass (the old code scanned the whole corpus once to bucket
        // per-contact stats, then AGAIN per qualifying contact to recount before —
        // O(messages × qualifiers)), then run the pure decisive math over the
        // postings. Same matching rule (word-set for single words, lowercased
        // substring for phrases) and same thresholds → byte-identical output, no
        // re-scan. Retained as the public single-term entry point (unit tests +
        // any external caller); `analyze` uses the batched `attributeAll`.
        let occ = buildAttributionIndex(messages: messages, terms: [term])[term] ?? []
        return attributeFromOccurrences(term: term, occurrences: occ, options: options)
    }

    // MARK: - shared helpers

    static let unknownLabel = "someone not in your contacts"

    /// Curated lexical-slang seed list for attribution — the kind of words a
    /// person genuinely picks up from a friend (validated in `/tmp/report`).
    /// Mixed with the user's own distinctive words at analysis time. Each is
    /// still subject to the DECISIVE gate, so listing one here does NOT force
    /// an attribution; it only guarantees the term is evaluated.
    static let attributionSeedTerms: [String] = [
        "lil bro", "big bro", "deadass", "hella", "lowkey", "cooked", "crashout",
        "gotchu", "fs", "icl", "yk", "tho", "diff", "lock in", "plot armor",
        "my goat", "gotchu fam", "grown ass man", "hell nah",
    ]

    static func monthLabel(_ epoch: Double) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM yyyy"
        return df.string(from: Date(timeIntervalSince1970: epoch))
    }
}

// MARK: - Tokenization (matches the prototypes' `words(_:)`)

enum VernTokens {
    /// Lowercased letter/apostrophe word tokens. Mirrors the prototype's
    /// `words(_:)` exactly so counts reproduce the validated output.
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                cur.append(ch)
            } else {
                if !cur.isEmpty { out.append(cur) }
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func titlecase(_ gram: String) -> String {
        gram.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
