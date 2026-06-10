//
//  LinguisticBaseline.swift
//  Hourglass — Linguistic Insights
//
//  Loads + serves the baseline unigram frequency distribution that the
//  distinctive-vocabulary analysis compares the user's own texting against.
//
//  BASELINE CORPUS SOURCE + LICENSE
//  ================================
//  Resource: Resources/Assets.xcassets/BaselineUnigrams.dataset
//            (bundled as NSDataAsset "BaselineUnigrams")
//  Origin:   hermitdave/FrequencyWords, 2018 English list
//            (https://github.com/hermitdave/FrequencyWords), derived from
//            the OpenSubtitles 2018 corpus (OPUS project).
//  License:  Frequency CONTENT is Creative Commons Attribution-ShareAlike
//            4.0 (CC BY-SA 4.0); the repo's generator code is MIT.
//            Attribution is preserved in the data file's header comment.
//  Why this corpus: OpenSubtitles is a CONVERSATIONAL register, so common
//            function words dominate the head while modern texting slang
//            ("lol", "fr", "bruh", "lowkey") is rare or absent. That makes
//            a surprisal / log-odds comparison surface the user's
//            DISTINCTIVE vocabulary rather than stopwords.
//  Trim:     top 30,000 words by corpus frequency. See the data file header.
//
//  TO REGENERATE THE RESOURCE
//  --------------------------
//    curl -sL https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt -o en_50k.txt
//    head -30000 en_50k.txt | awk '{printf "%s\t%s\n", $1, $2}' > body.txt
//    # then prepend the license/attribution header (see existing file) and
//    # place at Resources/Assets.xcassets/BaselineUnigrams.dataset/baseline_en_unigrams.txt
//
//  This type is a pure value type once constructed: all lookups are O(1)
//  dictionary reads. Construction (`load()`) is the only I/O and is cheap
//  (parse ~30k lines, ~370 KB). It is `Sendable` so the analyzer can run
//  it off the main actor.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif
import os

public struct LinguisticBaseline: Sendable {

    /// word -> corpus occurrence count.
    public let counts: [String: Double]
    /// Sum of all counts. Used to turn a count into a probability.
    public let totalCount: Double
    /// True when this was constructed from the bundled corpus (vs. the
    /// tiny embedded placeholder fallback). Surfaced so the UI / lead can
    /// tell whether the real baseline shipped.
    public let isPlaceholder: Bool

    /// Smoothing floor: a token absent from the baseline is treated as if
    /// it occurred this many times. Slightly above zero so an out-of-corpus
    /// slang word ("deadass") gets a large-but-finite surprisal rather than
    /// +infinity. Half a count is the conventional add-k for unseen unigrams
    /// here (the baseline's smallest real count is ~409, so 0.5 is a strong
    /// "this is genuinely rare" prior).
    public static let unseenCount: Double = 0.5

    public init(counts: [String: Double], isPlaceholder: Bool = false) {
        self.counts = counts
        self.totalCount = max(1, counts.values.reduce(0, +))
        self.isPlaceholder = isPlaceholder
    }

    private static let logger = Logger(subsystem: "com.satyajit.hourglass",
                                       category: "LinguisticBaseline")

    /// Baseline count for a token (the smoothing floor if unseen).
    public func count(of token: String) -> Double {
        counts[token] ?? Self.unseenCount
    }

    /// Baseline probability of a token (smoothed). In (0, 1].
    public func probability(of token: String) -> Double {
        count(of: token) / (totalCount + Self.unseenCount)
    }

    /// True iff the token appears in the (untrimmed-by-us) baseline at all.
    public func isKnown(_ token: String) -> Bool {
        counts[token] != nil
    }

    // MARK: - Loading

    /// Load the bundled baseline. Falls back to a tiny embedded placeholder
    /// (clearly marked `isPlaceholder = true`) if the asset is missing or
    /// unparseable — so the analyzer never crashes and the panel still runs
    /// (it just can't distinguish slang as well). Lead should treat a
    /// placeholder baseline as a build/bundling bug to fix.
    public static func load() -> LinguisticBaseline {
        #if canImport(AppKit)
        if let asset = NSDataAsset(name: "BaselineUnigrams"),
           let parsed = parse(asset.data) {
            return parsed
        }
        #endif
        logger.error("BaselineUnigrams asset missing or unparseable — using embedded placeholder baseline. Distinctive-word quality will be degraded.")
        return placeholder()
    }

    /// Parse the `word\tcount` (or `word count`) text format, skipping
    /// `#` comment lines and blanks. Returns nil if no usable rows.
    /// Exposed for unit tests.
    public static func parse(_ data: Data) -> LinguisticBaseline? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var counts: [String: Double] = [:]
        counts.reserveCapacity(32_000)
        text.enumerateLines { line, _ in
            if line.isEmpty || line.hasPrefix("#") { return }
            // Accept tab OR whitespace separation; word is field 0, count field 1.
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2 else { return }
            let word = String(parts[0])
            guard let c = Double(parts[1]), c > 0 else { return }
            // First occurrence wins (the list is unique already).
            if counts[word] == nil { counts[word] = c }
        }
        guard !counts.isEmpty else { return nil }
        return LinguisticBaseline(counts: counts, isPlaceholder: false)
    }

    /// A tiny, obviously-incomplete fallback so the app degrades gracefully
    /// if the real corpus failed to bundle. PLACEHOLDER ONLY — these counts
    /// are rough orders of magnitude for the most common English words, not
    /// a real distribution. With only function words present, every content
    /// word reads as "distinctive", which is wrong; the marker lets callers
    /// detect and report the degraded state.
    static func placeholder() -> LinguisticBaseline {
        // Rough relative magnitudes for the top function words. Enough to
        // bury the worst stopwords; not enough to be a real baseline.
        let rough: [String: Double] = [
            "the": 23_000_000, "you": 28_000_000, "i": 27_000_000,
            "to": 17_000_000, "a": 14_000_000, "and": 10_000_000,
            "it": 13_000_000, "that": 10_000_000, "of": 8_900_000,
            "is": 7_400_000, "in": 7_300_000, "what": 6_900_000,
            "we": 6_700_000, "me": 6_400_000, "this": 5_700_000,
            "for": 5_100_000, "my": 4_900_000, "on": 4_800_000,
            "have": 4_700_000, "your": 4_600_000, "do": 4_400_000,
            "not": 4_200_000, "be": 4_200_000, "are": 4_200_000,
            "know": 3_900_000, "with": 3_800_000, "but": 3_600_000,
            "so": 3_400_000, "all": 3_500_000, "no": 4_300_000,
            "just": 3_300_000, "like": 2_900_000, "yeah": 2_000_000,
            "okay": 1_400_000, "ok": 388_000, "lol": 953, "haha": 1_582,
        ]
        return LinguisticBaseline(counts: rough, isPlaceholder: true)
    }
}
