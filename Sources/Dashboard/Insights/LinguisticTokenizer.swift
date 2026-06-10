//
//  LinguisticTokenizer.swift
//  Hourglass — Linguistic Insights
//
//  Pure tokenization + lexical helpers for the Linguistic Insights panel.
//  No I/O, no global state — every function here is deterministic and
//  trivially unit-testable with fixed inputs.
//
//  WHAT "A WORD" MEANS HERE
//  ========================
//  We tokenize a message body into lowercased word tokens for frequency
//  analysis. The rules are tuned for casual texting, not formal prose:
//
//    - Split on anything that isn't a letter, digit, or an INTERIOR
//      apostrophe/hyphen. So "don't", "y'all", "self-care" stay whole,
//      but "...wait" / "(lol)" / "word." lose their punctuation.
//    - Lowercase via Unicode case folding so "LOL" and "lol" merge.
//    - Strip a leading/trailing apostrophe or hyphen left over from the
//      split (e.g. "'cause" → "cause"? no — we KEEP a leading apostrophe
//      word like "'cause" as "cause" only if it's framing; see trim rules).
//    - Drop pure-number tokens ("2024", "100") — they're rarely
//      distinctive style and pollute the surprisal ranking.
//    - Keep tokens of length >= 1 but the analyzer filters very short
//      ones except a curated allowlist ("ok", "no", "fr", "rn", ...).
//
//  Emoji and punctuation are handled separately by the analyzer (they're
//  style signals, not "words"), so the tokenizer deliberately discards
//  them here.
//

import Foundation

public enum LinguisticTokenizer {

    /// Characters allowed INSIDE a word in addition to letters/digits.
    /// Apostrophe (straight + curly) for contractions; hyphen for
    /// compound words. These only count when they sit between two
    /// word characters — leading/trailing ones are trimmed.
    private static let interiorJoiners: Set<Character> = ["'", "\u{2019}", "-"]

    /// Tokenize a single message body into lowercased word tokens.
    ///
    /// Pure. Order-preserving (callers that need bigrams rely on this).
    public static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            if current.isEmpty { return }
            let raw = String(current)
            current.removeAll(keepingCapacity: true)
            if let cleaned = clean(raw) {
                tokens.append(cleaned)
            }
        }

        // We iterate scalars and decide word-membership. An interior joiner
        // is only kept if it's flanked by word scalars; to keep this a
        // single pass we append the joiner provisionally and clean() trims
        // any that ended up on an edge.
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if isWordScalar(s) {
                current.append(s)
            } else if isInteriorJoiner(s) {
                // Keep only when flanked by word scalars on BOTH sides.
                let prevIsWord = i > 0 && isWordScalar(scalars[i - 1])
                let nextIsWord = i + 1 < scalars.count && isWordScalar(scalars[i + 1])
                if prevIsWord && nextIsWord {
                    current.append(s)
                } else {
                    flush()
                }
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Lowercase + trim edge joiners + reject pure-number / empty tokens.
    /// Returns nil if the token should be dropped.
    static func clean(_ raw: String) -> String? {
        // Lowercase via Unicode-aware folding.
        var s = raw.lowercased()
        // Trim any stray leading/trailing joiner that slipped through.
        while let f = s.first, interiorJoiners.contains(f) { s.removeFirst() }
        while let l = s.last, interiorJoiners.contains(l) { s.removeLast() }
        if s.isEmpty { return nil }
        // Drop pure-number tokens.
        if s.allSatisfy({ $0.isNumber }) { return nil }
        return s
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        // Letters (any script) and digits. Foundation's CharacterSet is
        // Unicode-aware; we use the scalar properties directly for speed.
        return s.properties.isAlphabetic || (s.value >= 0x30 && s.value <= 0x39)
    }

    private static func isInteriorJoiner(_ s: Unicode.Scalar) -> Bool {
        return s == "'" || s.value == 0x2019 || s == "-"
    }

    // MARK: - Bigrams

    /// Adjacent word pairs from a token list, joined by a space.
    /// "i", "love", "you" → ["i love", "love you"]. Used for the
    /// distinctive-phrase analysis. Pure.
    public static func bigrams(_ tokens: [String]) -> [String] {
        guard tokens.count >= 2 else { return [] }
        var out: [String] = []
        out.reserveCapacity(tokens.count - 1)
        for i in 0..<(tokens.count - 1) {
            out.append(tokens[i] + " " + tokens[i + 1])
        }
        return out
    }

    // MARK: - Elongation ("sooo", "lmaooo", "yesss")

    /// Detects a "stretched" word — one with a run of 3+ identical letters
    /// (e.g. "soooo", "lmaooo", "yessss", "ahhhh"). Real English words
    /// almost never have a letter tripled, so a 3+ run is a reliable signal
    /// of deliberate elongation for emphasis.
    ///
    /// Returns the canonical (de-elongated) form when stretched — collapsing
    /// each 3+ run to a single letter — else nil. "soooo" → "so",
    /// "yessss" → "yes" (collapses the 4-s run to one), "lmaooo" → "lmao".
    ///
    /// Note: collapsing to ONE can be wrong for words with legit doubles
    /// ("cool" has a real double-o). We only collapse runs of length >= 3,
    /// so "cool" (run length 2) is untouched and never flagged as elongated.
    public static func elongationCanonical(_ token: String) -> String? {
        let chars = Array(token)
        guard chars.count >= 3 else { return nil }
        var hasLongRun = false
        var collapsed: [Character] = []
        collapsed.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            var runLength = 1
            var j = i + 1
            while j < chars.count && chars[j] == c {
                runLength += 1
                j += 1
            }
            if runLength >= 3 && c.isLetter {
                hasLongRun = true
                collapsed.append(c) // collapse to a single instance
            } else {
                // Preserve the original run (handles legit doubles like "oo").
                for _ in 0..<runLength { collapsed.append(c) }
            }
            i = j
        }
        return hasLongRun ? String(collapsed) : nil
    }

    /// True iff the token shows deliberate elongation (a 3+ identical-letter
    /// run). Convenience over `elongationCanonical`.
    public static func isElongated(_ token: String) -> Bool {
        elongationCanonical(token) != nil
    }
}
