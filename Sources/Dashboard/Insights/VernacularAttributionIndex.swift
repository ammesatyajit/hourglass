//
//  VernacularAttributionIndex.swift
//  Hourglass — Vernacular Analysis (Codex consult #4, Pass A — occurrence-index attribution)
//
//  KILLS the profiled 90%-CPU hot spot. `VernacularAnalyzer.analyze` evaluated
//  decisive attribution by calling `attribute(term:messages:)` once PER candidate
//  term (~40 terms), and the OLD `attribute` re-scanned the ENTIRE ~532k-message
//  corpus TWICE per term — once to bucket per-contact first/total, then AGAIN
//  (a fresh `for m in messages where … matches(m)`) for every qualifying contact
//  to recount "before". Net: O(terms × messages × qualifiers) full-array scans,
//  plus `VernacularMessage` value-copy churn from passing the corpus by value.
//
//  Codex step ① + ⑦ (`/tmp/codex_review4.txt:11989`): build a `term → [Occurrence]`
//  INVERTED INDEX ONCE over the corpus, then compute the decisive rules from the
//  postings — O(total occurrences), NOT O(terms × messages). The postings carry
//  the Codex shape (`rowID`/`date`/`sender`/`chatID`/`fromMe`); the decisive math
//  reads only `date`, the resolved sender, and `fromMe`, so attribution math is
//  byte-identical to the old per-term scan — this is a SPEED change, not a
//  behavior change (verified 0-diff against the real chat.db).
//
//  PURE + deterministic over `[VernacularMessage]`. No I/O. The corpus is passed
//  by reference into the single index pass (no per-term value copy).
//

import Foundation

public extension VernacularAnalyzer {

    // MARK: - Occurrence (Codex shape, lines 12025–12033)

    /// One occurrence of an attribution TERM in one message. Carries the Codex
    /// postings shape. `Equatable`/`Sendable` value. The decisive attribution
    /// math reads `date`, `sender`, and `fromMe`; `rowID`/`chatID` are carried so
    /// the same postings can hydrate example bodies by rowID (Pass A hydrates only
    /// first-use examples) and feed the per-chat exposure gate without a re-scan.
    struct AttributionOccurrence: Sendable, Equatable {
        /// Stable corpus ordinal of the source message (its index in the corpus
        /// array passed to the indexer — the rowID-equivalent reference, never a
        /// stored body). Lets a caller hydrate the example body by reading the
        /// message back by index instead of retaining the string.
        public let rowID: Int
        public let date: Double
        /// Resolved sender: "You" for sent, the contact display name for known
        /// received, or the unknown sentinel (`VernacularAnalyzer.unknownLabel`).
        /// The decisive rule excludes the unknown sentinel from sourcing.
        public let sender: String
        public let chatID: Int64
        public let fromMe: Bool
        public init(rowID: Int, date: Double, sender: String, chatID: Int64, fromMe: Bool) {
            self.rowID = rowID
            self.date = date
            self.sender = sender
            self.chatID = chatID
            self.fromMe = fromMe
        }
    }

    // MARK: - Build the inverted index ONCE (over all wanted terms)

    /// Instrumentation: the number of full-corpus scans the LAST index build
    /// performed. The occurrence-index path builds the index in ONE pass for ALL
    /// terms, so this is `1` regardless of term count — the harness asserts it
    /// does NOT grow with the number of terms (the old path was `~2 × terms`).
    /// Not thread-safe; for the verification harness / debug only.
    nonisolated(unsafe) static var lastIndexScanCount = 0

    /// Build `term → [AttributionOccurrence]` for `terms` in ONE linear pass over
    /// the corpus. Single-word terms match by word-set membership (so "im" does
    /// NOT match inside "time"); multi-word PHRASES match by raw substring on the
    /// lowercased body (`bodyLow.contains`) — EXACTLY the matching rule the old
    /// `attribute` used, so the resulting attribution is identical.
    ///
    /// `corpusIndex` (the message's position in `messages`) is recorded as the
    /// occurrence `rowID` — stable within a load and enough to hydrate an example
    /// body by reading the message back, without retaining bodies in the postings.
    ///
    /// One message can contribute at most ONE occurrence per term (mirrors the old
    /// per-message `matches(m)` boolean — the old code counted a message once per
    /// term, never once per in-message repeat). PURE.
    static func buildAttributionIndex(
        messages: [VernacularMessage],
        terms: [String]
    ) -> [String: [AttributionOccurrence]] {
        lastIndexScanCount = 0
        guard !terms.isEmpty else { return [:] }
        // De-dup + partition the wanted terms into single-word (matched by
        // word-set) and phrase (matched by lowercased-substring). Lowercase the
        // needle exactly as the old `attribute` did (`term.lowercased()`).
        var wordTerms: [String: String] = [:]      // needle → original term
        var phraseTerms: [(needle: String, term: String)] = []
        var seen = Set<String>()
        for term in terms where seen.insert(term).inserted {
            let needle = term.lowercased()
            if term.contains(" ") {
                phraseTerms.append((needle, term))
            } else {
                wordTerms[needle] = term
            }
        }
        let wordNeedles = Set(wordTerms.keys)

        var out: [String: [AttributionOccurrence]] = [:]
        for term in terms { out[term] = [] }   // stable presence for every term

        // ONE pass over the corpus. For each message: emit a word occurrence for
        // every wanted single-word needle present in its word-set, and a phrase
        // occurrence for every wanted phrase whose needle is a substring of the
        // lowercased body. `lastIndexScanCount` counts this single scan.
        lastIndexScanCount += 1
        for (ci, m) in messages.enumerated() {
            let occ = AttributionOccurrence(rowID: ci, date: m.date, sender: m.who,
                                            chatID: m.chat, fromMe: m.fromMe)
            // word terms — set intersection is O(min) and avoids scanning all
            // needles when the message has few distinct words.
            if !wordNeedles.isEmpty && !m.wordSet.isDisjoint(with: wordNeedles) {
                for w in m.wordSet where wordNeedles.contains(w) {
                    out[wordTerms[w]!, default: []].append(occ)
                }
            }
            // phrase terms — raw lowercased-substring, identical to the old rule.
            if !phraseTerms.isEmpty {
                let low = m.bodyLow
                for p in phraseTerms where low.contains(p.needle) {
                    out[p.term, default: []].append(occ)
                }
            }
        }
        return out
    }

    // MARK: - Decisive attribution FROM postings (pure, no scan)

    /// Compute the DECISIVE attribution for `term` from its ALREADY-BUILT
    /// occurrence postings. Same decisive rule as the old scan-based `attribute`
    /// (see `VernacularAnalyzer.swift` header): a source is reported ONLY if it
    /// used the term ≥`attributionMinBefore` strictly BEFORE your first use, its
    /// first use is ≥`attributionMinDays` before yours, and it dominates the
    /// runner-up (≥`attributionDominanceRatio`× or sole qualifier). Returns nil
    /// for a term you never used; an attribution with `source == nil` for
    /// ambient / no-clear-source. O(occurrences), no corpus scan. PURE.
    static func attributeFromOccurrences(
        term: String,
        occurrences: [AttributionOccurrence],
        options: Options = .default
    ) -> VernacularAttribution? {
        var yourCount = 0
        var yourFirst = Double.greatestFiniteMagnitude
        // per-contact first-use date + total uses (known received only).
        var byContact: [String: (first: Double, total: Int)] = [:]
        for o in occurrences {
            if o.fromMe {
                yourCount += 1
                yourFirst = min(yourFirst, o.date)
            } else if o.sender != Self.unknownLabel {
                var e = byContact[o.sender] ?? (o.date, 0)
                e.first = min(e.first, o.date)
                e.total += 1
                byContact[o.sender] = e
            }
        }
        guard yourCount > 0, yourFirst < .greatestFiniteMagnitude else { return nil }

        // before-count for each candidate who started before you — computed from
        // the SAME postings (the old code re-scanned the whole corpus here).
        var beforeCounts: [(who: String, before: Int, first: Double)] = []
        if !byContact.isEmpty {
            // count each early contact's strictly-before-your-first uses in ONE
            // pass over the postings (not the corpus).
            var before: [String: Int] = [:]
            for o in occurrences where !o.fromMe && o.sender != Self.unknownLabel && o.date < yourFirst {
                before[o.sender, default: 0] += 1
            }
            for (who, e) in byContact where e.first < yourFirst {
                let b = before[who] ?? 0
                if b > 0 { beforeCounts.append((who, b, e.first)) }
            }
        }
        beforeCounts.sort { $0.before > $1.before }

        let yourFirstMonth = Self.monthLabel(yourFirst)

        // Decisive test (identical thresholds + ordering to the old `attribute`).
        guard let top = beforeCounts.first,
              top.before >= options.attributionMinBefore,
              (yourFirst - top.first) >= options.attributionMinDays * 86_400 else {
            return VernacularAttribution(term: term, yourCount: yourCount,
                                         yourFirstMonth: yourFirstMonth,
                                         source: nil, sourceBeforeCount: 0, sourceFirstMonth: "")
        }
        let runnerUp = beforeCounts.dropFirst().first?.before ?? 0
        let dominant = runnerUp == 0 || Double(top.before) >= options.attributionDominanceRatio * Double(runnerUp)
        guard dominant else {
            return VernacularAttribution(term: term, yourCount: yourCount,
                                         yourFirstMonth: yourFirstMonth,
                                         source: nil, sourceBeforeCount: 0, sourceFirstMonth: "")
        }
        return VernacularAttribution(
            term: term, yourCount: yourCount, yourFirstMonth: yourFirstMonth,
            source: top.who, sourceBeforeCount: top.before,
            sourceFirstMonth: Self.monthLabel(top.first)
        )
    }

    /// Run decisive attribution for a whole set of `terms` from a SINGLE inverted
    /// index built ONCE over the corpus. This is the O(total occurrences) path
    /// `analyze` uses in place of the old O(terms × messages) per-term re-scan.
    /// Returns one (term → attribution-or-nil) per input term, in input order.
    /// PURE.
    static func attributeAll(
        terms: [String],
        messages: [VernacularMessage],
        options: Options = .default
    ) -> [VernacularAttribution] {
        let index = buildAttributionIndex(messages: messages, terms: terms)
        return terms.compactMap { term in
            attributeFromOccurrences(term: term, occurrences: index[term] ?? [], options: options)
        }
    }
}
