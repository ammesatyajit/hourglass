//
//  VernacularSenseRules.swift
//  Hourglass — Vernacular Analysis (legacy display-stat helper — DEMOTED)
//
//  RETIRED AS SOURCE OF TRUTH. This file now survives only as the helper behind
//  a secondary display stat: the "address terms" vocative/literal tic count in
//  `VernacularCorpusStats` / the style panel. Spread attribution uses the newer
//  profile-backed spread overlay plus `VernacularPOSSense` for sentence-initial
//  address senses such as "brother (as address)".
//
//  ── ORIGINAL NOTE (historical) ──
//  Some "slang" words are also ordinary kinship / honorific nouns: "brother",
//  "bro", "king", "queen", "chief", "boss", "sis", "fam". When someone writes
//  "brother what are you doing" they're using the VOCATIVE sense (addressing
//  you as "brother" — the slang/affectionate sense). When they write "my
//  brother is visiting" they mean the LITERAL kinship sense. Counting both as
//  the same thing pollutes the vernacular stats: a person who texts about
//  their actual brother a lot would look like a heavy slang user.
//
//  This module is a small, REUSABLE rule table (not hardcoded to "brother",
//  per the brief). For any registered address term it classifies an
//  occurrence as vocative or literal using a strict syntactic rule:
//
//    VOCATIVE  = the term is the FIRST word token of the message
//                ("bro what", "king 👑", "brother no").
//    LITERAL   = anything else: preceded by a possessive / article / kinship
//                modifier ("my brother", "his bro"), plural ("brothers"),
//                a compound ("brother-in-law"), or simply mid-sentence
//                ("and my brother", "Sarina's brother").
//
//  This is deliberately conservative (high precision on the vocative sense)
//  and matches the validated `/tmp/bro/main.swift` prototype. It is a SYNTAX
//  rule, so it has a known blind spot: the idiom "my brother in Christ" is
//  vocative-in-spirit but possessive-in-form, so this classifier marks it
//  LITERAL. That case is exactly what Layer 4's semantic LLM judge exists to
//  catch — see `VernacularAILabeler`.
//
//  Everything here is PURE: a static rule table + deterministic functions
//  over tokenized input. No I/O, trivially unit-testable.
//

import Foundation

public enum VernacularSenseRules {

    /// Which sense an occurrence of an address term carries.
    public enum Sense: String, Sendable, Equatable {
        /// Sentence-initial address — the slang / affectionate sense we count.
        case vocative
        /// Literal kinship / honorific noun ("my brother", "the king").
        case literal
    }

    /// Words that REQUIRE us to treat a following address term as literal when
    /// they immediately precede it: possessives, articles, kinship modifiers.
    /// e.g. "my brother", "his bro", "the king", "big bro", "lil sis".
    public static let literalPreceders: Set<String> = [
        "my", "your", "his", "her", "their", "our", "ur", "ya",
        "a", "an", "the",
        "step", "half", "big", "little", "lil", "older", "younger",
        "baby", "blood", "god", "frat", "biological", "host",
        "this", "that", "some", "any", "no",
    ]

    /// Address terms that have BOTH a literal noun sense and a vocative/slang
    /// sense, so they need sense-splitting. The value is the set of plural /
    /// inflected forms that are always literal (a plural address term is a
    /// description, not direct address).
    ///
    /// Keyed by the singular lowercased lemma. Extend this table to cover a
    /// new ambiguous term — the classifier is fully data-driven off it.
    public static let ambiguousTerms: [String: Set<String>] = [
        "brother": ["brothers"],
        "bro":     ["bros"],
        "sis":     [],
        "sister":  ["sisters"],
        "king":    ["kings"],
        "queen":   ["queens"],
        "chief":   ["chiefs"],
        "boss":    ["bosses"],
        "fam":     [],
        "homie":   ["homies"],
        "dawg":    ["dawgs"],
        "champ":   ["champs"],
        "legend":  ["legends"],
    ]

    /// True iff `lemma` is an address term that needs sense-splitting.
    public static func isAmbiguousAddressTerm(_ lemma: String) -> Bool {
        ambiguousTerms[lemma.lowercased()] != nil
    }

    /// Classify the sense of `term` appearing at `index` within `tokens`
    /// (lowercased word tokens, in order). Returns nil when `term` doesn't
    /// match the token at that index (defensive) or isn't ambiguous.
    ///
    /// Rule (strict, high-precision):
    ///   - plural / inflected form               → literal
    ///   - index == 0 (sentence-initial)         → vocative
    ///   - preceded by a literal-preceder word   → literal
    ///   - otherwise mid-sentence                → literal
    ///
    /// The vocative sense is intentionally narrow: ONLY a term that opens the
    /// message. This is what the validated prototype used and what keeps the
    /// vocative count clean ("brother what" counts; "and brother" does not).
    public static func classify(term: String, at index: Int, in tokens: [String]) -> Sense? {
        let lemma = term.lowercased()
        // Plural / inflected variants registered as always-literal.
        for (singular, plurals) in ambiguousTerms {
            if lemma == singular { break }
            if plurals.contains(lemma) { return .literal }
        }
        guard ambiguousTerms[lemma] != nil else { return nil }
        guard index >= 0, index < tokens.count, tokens[index].lowercased() == lemma else { return nil }

        if index == 0 { return .vocative }
        let prev = tokens[index - 1].lowercased()
        if literalPreceders.contains(prev) { return .literal }
        // Mid-sentence, no possessive/article in front: still literal under
        // the strict rule (e.g. "Sarina's brother", "and brother"). Only a
        // genuine sentence-initial address is vocative.
        return .literal
    }

    /// Count vocative vs literal senses of every registered ambiguous term in
    /// a single message's token stream. A message may contain more than one
    /// (rare) — each is classified independently.
    public static func tally(tokens: [String]) -> (vocative: Int, literal: Int) {
        var voc = 0, lit = 0
        for (i, tok) in tokens.enumerated() {
            let lemma = tok.lowercased()
            // Fast reject: only do work for tokens that are ambiguous lemmas
            // or registered plurals.
            guard isAmbiguousAddressTerm(lemma) || isRegisteredPlural(lemma) else { continue }
            switch classify(term: lemma, at: i, in: tokens) {
            case .vocative: voc += 1
            case .literal:  lit += 1
            case .none:     break
            }
        }
        return (voc, lit)
    }

    /// True iff `lemma` is a plural/inflected form of any ambiguous term.
    static func isRegisteredPlural(_ lemma: String) -> Bool {
        for (_, plurals) in ambiguousTerms where plurals.contains(lemma) { return true }
        return false
    }
}
