//
//  VernacularSharedVocab.swift
//  Hourglass — Vernacular Analysis (shared in-group vocabulary)
//
//  A FOURTH vernacular data product (Fix #2), distinct from the other three:
//
//    • "your distinctive vocab" (`discoverVocab`) = words YOU over-use vs
//      general English — a personal fingerprint.
//    • 1:1 TRANSMISSION (`VernacularGraph` edges) = who handed a term to whom.
//    • SHARED IN-GROUP VOCABULARY (this file) = the slang that YOU *and your
//      friends* ALL use — the group dialect. Not "yours", not a hand-off; the
//      common tongue of the friend group.
//
//  Faithful port of the validated standalone prototype `/tmp/shared/main.swift`
//  (run against the real chat.db). The rule, per term in a CURATED slang
//  lexicon (clean curated words + repurposed phrases — NOT open over-rep
//  discovery, which surfaces names/places/garbage):
//
//    • per-person counts (you + every resolved contact), counted ONCE PER
//      MESSAGE the term appears in (set/subsequence membership, matching the
//      prototype's `m.toks.contains` / `hasSub`).
//    • a person "uses" the term iff they have ≥2 such messages (a single
//      one-off doesn't make it part of their vocabulary).
//    • SURFACE the term iff YOU use it ≥2× AND ≥4 DISTINCT people use it.
//    • `peopleCount` = # distinct real users (incl. you); `totalUses` = sum of
//      all real-or-not per-person message counts (excl. the unknown sentinel);
//      `yourUses` = your message count; `topUsers` = the top ~5 CONTACTS
//      (excluding you) by count.
//    • ranked by `peopleCount` DESC (most widely shared dialect first).
//
//  PURE: a deterministic function of `[VernacularMessage]`. Computed in the
//  SAME off-main pass as everything else (no extra chat.db read / decode).
//

import Foundation

// MARK: - Public Sendable result type

/// One piece of SHARED in-group vocabulary — slang that you AND ≥4 friends all
/// use (the group dialect). See file header for the surfacing rule.
public struct SharedTerm: Identifiable, Sendable, Equatable {
    public let id: String        // == term
    /// The shared term/phrase (lowercased canonical form, as curated).
    public let term: String
    /// # of DISTINCT people (you + contacts) who use it ≥2× — the share width.
    public let peopleCount: Int
    /// Sum of every person's message-count for the term (excl. unknown sender).
    public let totalUses: Int
    /// How many of YOUR messages use it.
    public let yourUses: Int
    /// Top ~5 CONTACTS (excluding you) by message-count, count desc. `name` is
    /// the full resolved display name (keying parity with `GraphNode.displayName`
    /// so the UI can resolve an avatar); the prototype printed first-name only.
    public let topUsers: [TopUser]

    /// One contact who shares the term, with how many of their messages use it.
    public struct TopUser: Sendable, Equatable {
        public let name: String
        public let count: Int
        public init(name: String, count: Int) { self.name = name; self.count = count }
    }

    public init(term: String, peopleCount: Int, totalUses: Int, yourUses: Int,
                topUsers: [TopUser]) {
        self.id = term
        self.term = term
        self.peopleCount = peopleCount
        self.totalUses = totalUses
        self.yourUses = yourUses
        self.topUsers = topUsers
    }
}

// MARK: - Builder (pure, on `VernacularAnalyzer`)

public extension VernacularAnalyzer {

    /// Tunables for the shared in-group vocabulary pass. Mirrors `/tmp/shared`.
    struct SharedVocabOptions: Sendable {
        /// A person must use a term in ≥ this many messages to count as a real
        /// user of it (excludes one-offs).
        public var minPerPerson: Int
        /// YOU must use a term in ≥ this many messages for it to surface.
        public var minYou: Int
        /// ≥ this many DISTINCT people (incl. you) must use it for it to surface.
        public var minPeople: Int
        /// How many top contacts (excluding you) to list in `topUsers`.
        public var topUsersCount: Int

        public init(minPerPerson: Int = 2, minYou: Int = 2, minPeople: Int = 4,
                    topUsersCount: Int = 5) {
            self.minPerPerson = minPerPerson
            self.minYou = minYou
            self.minPeople = minPeople
            self.topUsersCount = topUsersCount
        }

        public static let `default` = SharedVocabOptions()
    }

    /// The CURATED slang lexicon (single-token words). Clean curated set —
    /// deliberately NOT open over-representation discovery (which surfaces
    /// names/places/garbage). Ported verbatim from `/tmp/shared`'s `wordsSlang`.
    static let sharedVocabWords: [String] = [
        "hella", "deadass", "lowkey", "lowk", "cooked", "crashout", "ts", "yuh",
        "icl", "ngl", "tbh", "bet", "gng", "twin", "bruh", "cone", "gyat",
        "sybau", "aura", "cooking",
    ]

    /// The CURATED repurposed/slang PHRASES (multi-token). Ported verbatim from
    /// `/tmp/shared`'s `phrases`.
    static let sharedVocabPhrases: [String] = [
        "traffic cone", "lil bro", "big bro", "my goat", "lock in", "of my soul",
        "hell nah", "grown ass", "plot armor", "no cap", "fr fr",
    ]

    /// Build the SHARED IN-GROUP VOCABULARY — the slang you AND ≥4 friends all
    /// use. PURE; a deterministic function of `messages`. Ranked by `peopleCount`
    /// (share width) DESC, ties broken by `totalUses` DESC then `term` for a
    /// stable order. Faithful port of `/tmp/shared/main.swift`.
    static func buildSharedVocabulary(
        messages: [VernacularMessage],
        options: SharedVocabOptions = .default
    ) -> [SharedTerm] {
        // Pre-split the curated phrases into token sequences once.
        let phraseTokens: [(label: String, toks: [String])] =
            sharedVocabPhrases.map { ($0, $0.split(separator: " ").map(String.init)) }

        // term -> (person display name -> # of that person's MESSAGES using it).
        // Counted once per message (set / subsequence membership), exactly like
        // the prototype's per-person tally.
        var perPerson: [String: [String: Int]] = [:]
        for w in sharedVocabWords { perPerson[w] = [:] }
        for (label, _) in phraseTokens { perPerson[label] = [:] }

        for m in messages {
            let who = m.who
            // single-token slang: set membership (once per message).
            for w in sharedVocabWords where m.wordSet.contains(w) {
                perPerson[w, default: [:]][who, default: 0] += 1
            }
            // phrases: contiguous subsequence over ordered tokens (once per msg).
            for (label, toks) in phraseTokens where hasSubsequence(m.words, toks) {
                perPerson[label, default: [:]][who, default: 0] += 1
            }
        }

        let unknown = Self.unknownLabel
        var rows: [SharedTerm] = []
        for (term, counts) in perPerson {
            // a "real user": ≥ minPerPerson messages AND a known sender.
            let realUsers = counts.filter { $0.key != unknown && $0.value >= options.minPerPerson }
            let people = realUsers.count
            let total = counts.filter { $0.key != unknown }.values.reduce(0, +)
            let you = counts["You"] ?? 0
            guard you >= options.minYou, people >= options.minPeople else { continue }
            let top = realUsers
                .filter { $0.key != "You" }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(options.topUsersCount)
                .map { SharedTerm.TopUser(name: $0.key, count: $0.value) }
            rows.append(SharedTerm(term: term, peopleCount: people, totalUses: total,
                                   yourUses: you, topUsers: Array(top)))
        }
        // most widely shared first; deterministic ties.
        rows.sort {
            if $0.peopleCount != $1.peopleCount { return $0.peopleCount > $1.peopleCount }
            if $0.totalUses != $1.totalUses { return $0.totalUses > $1.totalUses }
            return $0.term < $1.term
        }
        return rows
    }
}
