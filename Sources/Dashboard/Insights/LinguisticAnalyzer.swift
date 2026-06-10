//
//  LinguisticAnalyzer.swift
//  Hourglass — Linguistic Insights
//
//  The pure analysis engine behind the "How you talk" panel. Given the
//  user's own SENT message bodies and a baseline word-frequency
//  distribution, it surfaces what is DISTINCTIVE about their texting style
//  vs. a normal speaker — not just their most frequent words (which would
//  be stopwords).
//
//  METHOD — distinctive vocabulary
//  ===============================
//  We rank words by the **log-odds-ratio with an informative Dirichlet
//  prior** (Monroe, Colaresi & Quinn 2008, "Fightin' Words: Lexical Feature
//  Selection and Evaluation for Identifying the Content of Political
//  Conflict"). This is the standard, well-behaved estimator for "which
//  words distinguish corpus A from corpus B":
//
//      delta_w = log( (y_w^A + a_w) / (n^A + a0 - y_w^A - a_w) )
//              - log( (y_w^B + a_w) / (n^B + a0 - y_w^B - a_w) )
//
//      var(delta_w) ≈ 1/(y_w^A + a_w) + 1/(y_w^B + a_w)
//      z_w = delta_w / sqrt(var(delta_w))
//
//  where A = the user's corpus, B = the baseline, y_w = count of word w,
//  n = total tokens, a_w = the prior count for w (we use the baseline's own
//  frequency scaled to a modest pseudo-count mass a0). The z-score shrinks
//  the score of words seen only a handful of times in the user's corpus, so
//  a single weird typo can't top the chart — but genuinely characteristic
//  slang the user says constantly ("lowkey", "fr", "deadass") rises because
//  it's both frequent FOR THEM and rare in the baseline.
//
//  Everything here is PURE: deterministic functions over value-type inputs,
//  no I/O, no global mutable state. The chat.db read that produces the
//  `[String]` bodies lives in `LinguisticInsightsLoader` and is the only
//  impure part of the feature.
//

import Foundation

// MARK: - Output value type

/// The full result of a linguistic analysis. A `Sendable` value type so it
/// can cross the actor boundary from the background analysis to the view.
public struct LinguisticInsights: Sendable, Equatable {

    /// A word/phrase the user uses far more than the baseline speaker.
    public struct DistinctiveTerm: Sendable, Equatable, Identifiable {
        public let term: String
        /// User-corpus occurrence count.
        public let userCount: Int
        /// Per-10k-token rate in the user's corpus (for display).
        public let userRatePer10k: Double
        /// How many times more frequent (rate-wise) the user is vs. the
        /// baseline. >= 1. Capped for display sanity. `.infinity`-ish
        /// values are clamped to a large finite number upstream.
        public let timesMoreThanBaseline: Double
        /// True iff the term never appears in the baseline corpus at all
        /// (pure internet-native / in-group slang).
        public let absentFromBaseline: Bool
        /// The Fightin'-Words z-score that drove the ranking.
        public let score: Double
        public var id: String { term }
    }

    /// A characteristic opener/closer word.
    public struct PositionalWord: Sendable, Equatable, Identifiable {
        public let word: String
        public let count: Int
        /// Fraction of messages that start (or end) with this word.
        public let share: Double
        public var id: String { word }
    }

    /// A frequently-stretched word ("soooo", "lmaooo").
    public struct Elongation: Sendable, Equatable, Identifiable {
        /// The de-elongated canonical form ("so", "lmao").
        public let canonical: String
        /// The longest / most-elongated raw form actually seen ("sooooo").
        public let exampleForm: String
        public let count: Int
        public var id: String { canonical }
    }

    /// One headline style statistic for a card.
    public struct StyleStat: Sendable, Equatable, Identifiable {
        public let key: String          // stable id, e.g. "avg_words"
        public let title: String        // "Average message"
        public let value: String        // "8.4 words"
        public let detail: String?      // "≈ 41 characters"
        public var id: String { key }
    }

    public var totalSentMessages: Int
    public var totalTokens: Int
    public var distinctiveWords: [DistinctiveTerm]
    public var distinctivePhrases: [DistinctiveTerm]
    public var openers: [PositionalWord]
    public var closers: [PositionalWord]
    public var elongations: [Elongation]
    public var styleStats: [StyleStat]

    public init(
        totalSentMessages: Int = 0,
        totalTokens: Int = 0,
        distinctiveWords: [DistinctiveTerm] = [],
        distinctivePhrases: [DistinctiveTerm] = [],
        openers: [PositionalWord] = [],
        closers: [PositionalWord] = [],
        elongations: [Elongation] = [],
        styleStats: [StyleStat] = []
    ) {
        self.totalSentMessages = totalSentMessages
        self.totalTokens = totalTokens
        self.distinctiveWords = distinctiveWords
        self.distinctivePhrases = distinctivePhrases
        self.openers = openers
        self.closers = closers
        self.elongations = elongations
        self.styleStats = styleStats
    }

    /// True when there wasn't enough sent text to say anything meaningful.
    public var isEmpty: Bool { totalSentMessages == 0 || totalTokens == 0 }
}

// MARK: - Analyzer

public enum LinguisticAnalyzer {

    /// Tunables for the analysis. Defaults are reasonable for a few-thousand-
    /// to-hundreds-of-thousands-message corpus; exposed mainly so tests can
    /// lower the thresholds for tiny fixtures.
    public struct Options: Sendable {
        /// Minimum times a word must appear in the user's corpus to be
        /// eligible as "distinctive" (kills one-off typos).
        public var minWordCount: Int
        /// Minimum times a bigram must appear to be eligible.
        public var minPhraseCount: Int
        /// Words shorter than this are dropped UNLESS in `shortAllowlist`.
        public var minWordLength: Int
        /// Short words worth keeping despite length (real texting tokens).
        public var shortAllowlist: Set<String>
        /// How many distinctive words / phrases / openers etc. to return.
        public var topK: Int
        /// Pseudo-count mass (a0) for the Dirichlet prior in Fightin' Words.
        /// The prior shape is the baseline distribution; a0 scales how much
        /// we trust it. Larger → more shrinkage toward the baseline.
        public var priorMass: Double

        public init(
            minWordCount: Int = 5,
            minPhraseCount: Int = 4,
            minWordLength: Int = 3,
            shortAllowlist: Set<String> = LinguisticAnalyzer.defaultShortAllowlist,
            topK: Int = 12,
            priorMass: Double = 1_000
        ) {
            self.minWordCount = minWordCount
            self.minPhraseCount = minPhraseCount
            self.minWordLength = minWordLength
            self.shortAllowlist = shortAllowlist
            self.topK = topK
            self.priorMass = priorMass
        }

        public static let `default` = Options()
    }

    /// Short tokens (< minWordLength) that are nonetheless meaningful
    /// texting vocabulary and should survive the length filter.
    public static let defaultShortAllowlist: Set<String> = [
        "fr", "rn", "ngl", "tbh", "idk", "idc", "omg", "wtf", "lmk", "imo",
        "fml", "smh", "bc", "btw", "asap", "lol", "lmao", "hbu", "wbu",
        "nvm", "ily", "wyd", "hru", "af", "ok", "no", "yo", "ew", "aw",
        "uh", "oop", "bet", "yas", "rip", "ofc", "irl", "dm", "pls", "plz",
    ]

    /// Run the full analysis. PURE — same inputs always give the same output.
    ///
    /// - Parameters:
    ///   - sentBodies: the user's own sent message texts (already decoded).
    ///   - baseline: the comparison frequency distribution.
    ///   - options: tunables (defaults are production values).
    public static func analyze(
        sentBodies: [String],
        baseline: LinguisticBaseline,
        options: Options = .default
    ) -> LinguisticInsights {

        // ---- Single pass: tokenize, accumulate counts + style signals ----
        var wordCounts: [String: Int] = [:]
        var bigramCounts: [String: Int] = [:]
        var openerCounts: [String: Int] = [:]
        var closerCounts: [String: Int] = [:]
        // canonical -> (count, longestExampleForm)
        var elongCounts: [String: (count: Int, example: String)] = [:]

        var totalTokens = 0
        var totalChars = 0
        var totalWordsForLen = 0
        var messagesWithText = 0
        var lowercaseOnlyMessages = 0
        var questionMessages = 0
        var exclamationMessages = 0
        var emojiBearingMessages = 0
        var totalEmoji = 0
        var noPunctuationMessages = 0
        var abbreviationTokenHits = 0

        let abbreviationSet = defaultShortAllowlist

        for body in sentBodies {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            messagesWithText += 1
            totalChars += trimmed.count

            // Style signals over the raw body (case + punctuation matter).
            if isEffectivelyLowercase(trimmed) { lowercaseOnlyMessages += 1 }
            let lastMeaningful = trimmed.last(where: { !$0.isWhitespace })
            if trimmed.contains("?") { questionMessages += 1 }
            if trimmed.contains("!") { exclamationMessages += 1 }
            if !endsWithSentencePunctuation(lastMeaningful) { noPunctuationMessages += 1 }
            let emoji = emojiCount(in: trimmed)
            if emoji > 0 { emojiBearingMessages += 1; totalEmoji += emoji }

            // Tokenize for vocabulary.
            let tokens = LinguisticTokenizer.tokenize(trimmed)
            if tokens.isEmpty { continue }
            totalTokens += tokens.count
            totalWordsForLen += tokens.count

            if let first = tokens.first { openerCounts[first, default: 0] += 1 }
            if let last = tokens.last { closerCounts[last, default: 0] += 1 }

            for t in tokens {
                wordCounts[t, default: 0] += 1
                if abbreviationSet.contains(t) { abbreviationTokenHits += 1 }
                // Elongation detection on the original token.
                if let canonical = LinguisticTokenizer.elongationCanonical(t) {
                    var entry = elongCounts[canonical] ?? (0, t)
                    entry.count += 1
                    if t.count > entry.example.count { entry.example = t }
                    elongCounts[canonical] = entry
                }
            }
            for bg in LinguisticTokenizer.bigrams(tokens) {
                bigramCounts[bg, default: 0] += 1
            }
        }

        guard messagesWithText > 0, totalTokens > 0 else {
            return LinguisticInsights()
        }

        // ---- Distinctive single words (Fightin' Words log-odds z-score) ----
        let distinctiveWords = rankDistinctive(
            counts: wordCounts,
            totalUserTokens: totalTokens,
            baseline: baseline,
            baselineLookup: { baseline.count(of: $0) },
            baselineTotal: baseline.totalCount,
            minCount: options.minWordCount,
            minLength: options.minWordLength,
            shortAllowlist: options.shortAllowlist,
            dropStopwords: true,
            priorMass: options.priorMass,
            topK: options.topK
        )

        // ---- Distinctive phrases (bigrams) ----
        // The baseline is unigram-only, so a bigram's baseline expectation is
        // approximated as the product of its two words' baseline probabilities
        // times the user's total token count (independence assumption). This
        // surfaces collocations the user over-uses ("my guy", "no cap",
        // "i'm dead").
        let userBigramTotal = max(1, totalTokens - messagesWithText) // ~ #adjacent pairs
        let distinctivePhrases = rankDistinctive(
            counts: bigramCounts,
            totalUserTokens: userBigramTotal,
            baseline: baseline,
            baselineLookup: { bigramBaselineCount($0, baseline: baseline, userBigramTotal: userBigramTotal) },
            baselineTotal: Double(userBigramTotal),
            minCount: options.minPhraseCount,
            minLength: 0,
            shortAllowlist: [],
            dropStopwords: false,
            isPhrase: true,
            priorMass: options.priorMass,
            topK: options.topK
        )

        // ---- Openers / closers ----
        let openers = positional(openerCounts, totalMessages: messagesWithText, topK: options.topK)
        let closers = positional(closerCounts, totalMessages: messagesWithText, topK: options.topK)

        // ---- Elongations ----
        let elongations = elongCounts
            .filter { $0.value.count >= max(2, options.minPhraseCount - 1) }
            .map { LinguisticInsights.Elongation(canonical: $0.key, exampleForm: $0.value.example, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(options.topK)
            .map { $0 }

        // ---- Style stats ----
        let styleStats = buildStyleStats(
            messages: messagesWithText,
            totalTokens: totalTokens,
            totalWordsForLen: totalWordsForLen,
            totalChars: totalChars,
            lowercaseOnly: lowercaseOnlyMessages,
            questions: questionMessages,
            exclamations: exclamationMessages,
            emojiBearing: emojiBearingMessages,
            totalEmoji: totalEmoji,
            noPunctuation: noPunctuationMessages,
            abbreviationHits: abbreviationTokenHits
        )

        return LinguisticInsights(
            totalSentMessages: messagesWithText,
            totalTokens: totalTokens,
            distinctiveWords: distinctiveWords,
            distinctivePhrases: distinctivePhrases,
            openers: openers,
            closers: closers,
            elongations: Array(elongations),
            styleStats: styleStats
        )
    }

    // MARK: - Distinctive ranking (Fightin' Words)

    /// Generic distinctive-term ranker shared by words and phrases.
    /// `baselineLookup` returns the prior (baseline) count for a term;
    /// `baselineTotal` is the baseline corpus size in the same units.
    static func rankDistinctive(
        counts: [String: Int],
        totalUserTokens: Int,
        baseline: LinguisticBaseline,
        baselineLookup: (String) -> Double,
        baselineTotal: Double,
        minCount: Int,
        minLength: Int,
        shortAllowlist: Set<String>,
        dropStopwords: Bool,
        isPhrase: Bool = false,
        priorMass: Double,
        topK: Int
    ) -> [LinguisticInsights.DistinctiveTerm] {

        let nUser = Double(max(1, totalUserTokens))
        let nBase = max(1, baselineTotal)
        // a0 = total prior pseudo-count mass distributed by baseline shape.
        let a0 = priorMass

        var scored: [LinguisticInsights.DistinctiveTerm] = []
        scored.reserveCapacity(min(counts.count, 256))

        for (term, rawCount) in counts {
            if rawCount < minCount { continue }
            if dropStopwords {
                if LinguisticStopwords.isStopword(term) { continue }
                if term.count < minLength && !shortAllowlist.contains(term) { continue }
                // Reject tokens that are a single repeated character ("aaa")
                // unless allowlisted — they're noise, not vocabulary.
                if isSingleCharRepeat(term) && !shortAllowlist.contains(term) { continue }
            }
            if isPhrase {
                // A "signature phrase" needs at least one content word —
                // drop all-stopword bigrams ("to the", "that was", "was no")
                // which are filler, not voice. Also drop bigrams whose words
                // are both ultra-short noise.
                let parts = term.split(separator: " ").map(String.init)
                let allStopwords = parts.allSatisfy { LinguisticStopwords.isStopword($0) }
                if allStopwords { continue }
            }

            let yUser = Double(rawCount)
            let baseCount = baselineLookup(term)
            // Prior pseudo-count for this term = its share of baseline mass.
            let aW = max(0.01, a0 * (baseCount / nBase))

            // Fightin' Words log-odds with informative Dirichlet prior.
            let userOdds = (yUser + aW) / (nUser + a0 - yUser - aW)
            let baseOdds = (baseCount + aW) / (nBase + a0 - baseCount - aW)
            guard userOdds > 0, baseOdds > 0 else { continue }
            let delta = log(userOdds) - log(baseOdds)
            let variance = 1.0 / (yUser + aW) + 1.0 / (baseCount + aW)
            guard variance > 0 else { continue }
            let z = delta / sqrt(variance)

            // We only want terms the user uses MORE than baseline.
            if z <= 0 || delta <= 0 { continue }

            let userRate = yUser / nUser
            let baseRate = baseCount / nBase
            let times = baseRate > 0 ? min(userRate / baseRate, 99_999) : 99_999
            let absent = !baseline.isKnown(isPhrase ? firstWord(term) : term) && baseCount <= LinguisticBaseline.unseenCount

            scored.append(.init(
                term: term,
                userCount: rawCount,
                userRatePer10k: userRate * 10_000,
                timesMoreThanBaseline: times,
                absentFromBaseline: isPhrase ? false : absent,
                score: z
            ))
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.userCount > $1.userCount
        }
        return Array(scored.prefix(topK))
    }

    /// Approximate baseline count for a bigram under a word-independence
    /// assumption: expected occurrences ≈ p(w1) * p(w2) * (#user pairs),
    /// expressed back in "count" units against the same total.
    static func bigramBaselineCount(_ bigram: String, baseline: LinguisticBaseline, userBigramTotal: Int) -> Double {
        let parts = bigram.split(separator: " ")
        guard parts.count == 2 else { return LinguisticBaseline.unseenCount }
        let p1 = baseline.probability(of: String(parts[0]))
        let p2 = baseline.probability(of: String(parts[1]))
        let expected = p1 * p2 * Double(max(1, userBigramTotal))
        return max(LinguisticBaseline.unseenCount, expected)
    }

    private static func firstWord(_ phrase: String) -> String {
        String(phrase.split(separator: " ").first ?? "")
    }

    // MARK: - Positional (openers / closers)

    static func positional(_ counts: [String: Int], totalMessages: Int, topK: Int) -> [LinguisticInsights.PositionalWord] {
        let n = Double(max(1, totalMessages))
        return counts
            // Openers/closers are interesting even when they're stopwords
            // ("hey", "ok", "lol") — but drop the most contentless ones so
            // the card isn't just "i" / "the".
            .filter { !$0.key.isEmpty && $0.value >= 2 && !isUninterestingPositional($0.key) }
            .map { LinguisticInsights.PositionalWord(word: $0.key, count: $0.value, share: Double($0.value) / n) }
            .sorted { $0.count > $1.count }
            .prefix(topK)
            .map { $0 }
    }

    /// Positional words that are too contentless to be an interesting
    /// opener/closer headline.
    private static func isUninterestingPositional(_ word: String) -> Bool {
        let boring: Set<String> = ["the", "a", "an", "to", "of", "and", "in", "it", "is", "that", "this"]
        return boring.contains(word)
    }

    // MARK: - Style stats

    static func buildStyleStats(
        messages: Int,
        totalTokens: Int,
        totalWordsForLen: Int,
        totalChars: Int,
        lowercaseOnly: Int,
        questions: Int,
        exclamations: Int,
        emojiBearing: Int,
        totalEmoji: Int,
        noPunctuation: Int,
        abbreviationHits: Int
    ) -> [LinguisticInsights.StyleStat] {
        let m = Double(max(1, messages))
        let avgWords = Double(totalWordsForLen) / m
        let avgChars = Double(totalChars) / m
        let emojiPerMsg = Double(totalEmoji) / m
        let lowercasePct = Double(lowercaseOnly) / m * 100
        let questionPct = Double(questions) / m * 100
        let exclamationPct = Double(exclamations) / m * 100
        let noPunctPct = Double(noPunctuation) / m * 100
        let abbrevPer100 = Double(abbreviationHits) / Double(max(1, totalTokens)) * 100

        func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }
        func one(_ v: Double) -> String { String(format: "%.1f", v) }

        var stats: [LinguisticInsights.StyleStat] = []
        stats.append(.init(key: "avg_words", title: "Average message",
                           value: "\(one(avgWords)) words",
                           detail: "≈ \(Int(avgChars.rounded())) characters"))
        stats.append(.init(key: "lowercase", title: "lowercase only",
                           value: pct(lowercasePct),
                           detail: "of your messages skip capitals"))
        stats.append(.init(key: "emoji", title: "Emoji habit",
                           value: emojiPerMsg >= 0.05 ? "\(one(emojiPerMsg)) / msg" : "rarely",
                           detail: "\(pct(Double(emojiBearing) / m * 100)) of messages have one"))
        stats.append(.init(key: "questions", title: "You ask a lot",
                           value: pct(questionPct),
                           detail: "of messages contain a question"))
        stats.append(.init(key: "exclaim", title: "Exclamation rate",
                           value: pct(exclamationPct),
                           detail: "of messages use !"))
        stats.append(.init(key: "no_punct", title: "No end punctuation",
                           value: pct(noPunctPct),
                           detail: "of messages just… stop"))
        stats.append(.init(key: "abbrev", title: "Abbreviation rate",
                           value: abbrevPer100 >= 0.05 ? "\(one(abbrevPer100)) / 100 words" : "rare",
                           detail: "lol, idk, ngl, tbh, fr…"))
        return stats
    }

    // MARK: - Lexical helpers (pure)

    /// True if the string has no uppercase letters (it may have non-letters).
    /// "hey what's up" → true, "Hey" → false, "123!" → true (no letters).
    static func isEffectivelyLowercase(_ s: String) -> Bool {
        for ch in s where ch.isUppercase { return false }
        // Require at least one letter so pure-symbol messages don't count.
        return s.contains(where: { $0.isLetter })
    }

    static func endsWithSentencePunctuation(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return ".!?…".contains(ch)
    }

    /// Count emoji-presentation scalars in a string. Approximate but robust:
    /// counts scalars with the Emoji property excluding plain digits/`#`/`*`
    /// (which carry the Emoji property but are usually just text here).
    static func emojiCount(in s: String) -> Int {
        var count = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // Skip ASCII digits / # / * keycap bases — they have isEmoji but
            // are virtually always plain text in messages.
            if (v >= 0x30 && v <= 0x39) || v == 0x23 || v == 0x2A { continue }
            if scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && v > 0x2000) {
                count += 1
            }
        }
        return count
    }

    static func isSingleCharRepeat(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return s.count >= 2 && s.allSatisfy { $0 == first }
    }
}
