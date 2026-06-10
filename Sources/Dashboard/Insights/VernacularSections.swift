//
//  VernacularSections.swift
//  Hourglass — Vernacular Analysis (profile support sections)
//
//  Adds pure support data products on top of the Phase-1 profile:
//
//   (A) REACTED GEMS — reaction-weighted odd phrases. amusedRate × log(uses)
//       × over-rep × weirdness, where weirdness = mean general-English rarity
//       of the phrase's content tokens (from the shipped baseline ranks).
//
//   (B) VARIANT FAMILIES — normalized n-gram families (len 3-6) that collapse
//       subject/aux/possessive/object pronoun variants (§s/§p/§o) so "im/i'm"
//       etc. count together. Feeds the gem candidate pool and lifts rare
//       catchphrase families.
//
//  PURE: every builder here is a deterministic function of `[VernacularMessage]`
//  (+ the bundled `LinguisticBaseline` for rarity). The chat.db read lives in
//  `VernacularLoader`; this file does no I/O. The amused signal is the
//  per-message `VernacularMessage.laughed` flag the loader now populates.
//

import Foundation

// MARK: - Public Sendable result types

/// An eccentric, reaction-weighted "gem" — an odd phrase of yours that drew
/// repeated amused reactions.
public struct ReactedGem: Identifiable, Sendable, Equatable {
    public let id: String           // == phrase
    public let phrase: String
    public let yourUses: Int
    public let amusedCount: Int
    public let amusedRate: Double
    public let weirdness: Double
    public let example: String?
    public init(phrase: String, yourUses: Int, amusedCount: Int,
                amusedRate: Double, weirdness: Double, example: String?) {
        self.id = phrase
        self.phrase = phrase
        self.yourUses = yourUses
        self.amusedCount = amusedCount
        self.amusedRate = amusedRate
        self.weirdness = weirdness
        self.example = example
    }
}

/// EMPHATIC CONSTRUCTION — a word the user SHOUTS for emphasis (Fix #3). Found
/// over ORIGINAL-CASE sent text (the rest of the engine lowercases, collapsing
/// "ts is NOT it" ≡ "ts is not it"). An emphatic-caps token is all-uppercase,
/// ≥2 letters, letters-only, that ALSO appears lowercased elsewhere in the
/// user's messages (so it's a word they shout — "NOT"/"NEVER" — not an acronym
/// like IDK/USA), and not in a small acronym stoplist.
public struct EmphaticItem: Identifiable, Sendable, Equatable {
    public let id: String           // == word (the canonical UPPERCASE form)
    /// The shouted word in uppercase, e.g. "NOT", "NEVER", "ACTUALLY".
    public let word: String
    /// How many sent messages shout this word (in caps).
    public let shoutedCount: Int
    /// How many times the user uses the word lowercased (the calm baseline).
    public let lowercasedCount: Int
    /// The most common short construction frame around it, e.g. "is NOT ___",
    /// "___ MAY ___". Nil if no dominant frame.
    public let frame: String?
    /// 1-2 example sent messages that shout the word (newlines stripped).
    public let examples: [String]

    public init(word: String, shoutedCount: Int, lowercasedCount: Int,
                frame: String?, examples: [String]) {
        self.id = word
        self.word = word
        self.shoutedCount = shoutedCount
        self.lowercasedCount = lowercasedCount
        self.frame = frame
        self.examples = examples
    }
}

/// One person associated with a legacy vocab/template surface. Kept because the
/// older style panels and graph overlay still accept `VocabItem` /
/// `SnowcloneTemplate` payloads while the profile-backed spread path owns new
/// transmission.
public struct Recipient: Sendable, Equatable {
    /// Resolved contact display name.
    public let person: String
    /// Your uses of the term before this person's first use.
    public let count: Int
    /// This person's first use of the term (for "lag" / ordering in the UI).
    public let firstUse: Date
    public init(person: String, count: Int, firstUse: Date) {
        self.person = person
        self.count = count
        self.firstUse = firstUse
    }
}

/// A discovered vocabulary token the user actually sends — a clipping
/// ("rlly"/"abt"/"u"), internet-native slang ("hella"/"deadass"), or other
/// non-dictionary word — with how many times they sent it. DISCOVERED from the
/// user's own sent text (NOT a curated lexicon): a token surfaces iff it is sent
/// ≥ a floor, is NOT a standard-English baseline word, is NOT a contact's
/// first-name, and is not punctuation/numeric. Ranked by `count` (times sent)
/// descending. PURE data.
///
/// `source` / `spreadTo` / `users` are retained for old UI compatibility. The
/// current graph and person panel read profile-backed `SpreadProfile` /
/// `PersonInfluence` instead.
public struct VocabItem: Identifiable, Sendable, Equatable {
    public let id: String        // == token (lowercased)
    /// The token as the user writes it (lowercased canonical form).
    public let token: String
    /// How many times the user SENT it (times-sent — the uniform sort key).
    public let count: Int
    /// How many distinct other people also use it (spread; for context).
    public let peopleCount: Int
    /// GOT-FROM: the DECISIVE incoming source's display name (someone used this
    /// term heavily before you, dominantly), else nil. The "what you got from
    /// people" lens.
    public let source: String?
    /// SPREAD-TO: the exposure-gated recipients who picked this term up from you
    /// (you used it in a chat they're in, before their first use), sorted by
    /// firstUse asc. Empty if none. The "what spreads from you" lens.
    public let spreadTo: [Recipient]
    /// USERS: the FULL roster of distinct non-you people who used this term/sense
    /// at least once — everyone whose social footprint the term touches, not just
    /// the decisive `source`/`spreadTo` traders. Reuses `Recipient`, but here
    /// `count` = how many of THIS person's messages used the term (per-message
    /// presence) and `firstUse` = their earliest use. SENSE-AWARE: the users of
    /// `brother#address` are the vocative users, NOT the literal "my brother"
    /// users. Sorted by `count` desc (tie-break: firstUse asc). Empty until the
    /// attribution pass runs. Powers the Social-Graph light-up's NEUTRAL glow for
    /// users who aren't a decisive source/adopter.
    public let users: [Recipient]
    public init(token: String, count: Int, peopleCount: Int = 0,
                source: String? = nil, spreadTo: [Recipient] = [],
                users: [Recipient] = []) {
        self.id = token
        self.token = token
        self.count = count
        self.peopleCount = peopleCount
        self.source = source
        self.spreadTo = spreadTo
        self.users = users
    }

    /// Return a copy with the transmission lenses + user roster attached.
    public func withTransmission(source: String?, spreadTo: [Recipient],
                                 users: [Recipient] = []) -> VocabItem {
        VocabItem(token: token, count: count, peopleCount: peopleCount,
                  source: source, spreadTo: spreadTo, users: users)
    }
}

/// One non-caps emphasis device the user uses, generalizing "how you emphasize"
/// beyond ALL-CAPS shouting so a user who never shouts isn't empty (Task #3):
///   • `.elongation` — stretched words (3+ of the same letter: "soooo", "nooo",
///     "ahhh"). `example` is the actual stretched word.
///   • `.repeatedPunctuation` — runs of repeated "!" or "?" ("!!!", "???").
///     `example` is the run.
/// Each row is one concrete device (e.g. the stretched word "so" → "soooo", or
/// the run "!!!") with how many sent messages use it. Ranked by `count` desc.
/// PURE data.
public struct EmphasisSignal: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case elongation            // "soooo", "ahhh"
        case repeatedPunctuation   // "!!!", "???"
    }
    public let id: String          // "kind:key"
    public let kind: Kind
    /// The canonical device: for elongation the BASE word ("so", "no", "ah");
    /// for punctuation the run length label ("!!!", "??").
    public let key: String
    /// How many SENT messages use this device (times-sent sort key).
    public let count: Int
    /// A real example of the device as typed ("soooo", "!!!!").
    public let example: String
    public init(kind: Kind, key: String, count: Int, example: String) {
        self.id = "\(kind.rawValue):\(key)"
        self.kind = kind
        self.key = key
        self.count = count
        self.example = example
    }
}

// MARK: - Builders (pure, on `VernacularAnalyzer`)

public extension VernacularAnalyzer {

    /// Tunables for the reacted-gems + variant-family pass.
    struct SectionsOptions: Sendable {
        // ── reacted gems ("funny") ──
        /// A gem needs ≥ this many LAUGH (😂, 2003) reactions from others.
        /// Defaults to 2: the laugh-ONLY (2003) signal is much sparser than the
        /// broad amused (love+laugh+emphasize) signal, so a floor of 2 over a
        /// high RATE is the genuine "this was funny" bar. (Validated: "not on my
        /// bingo card" = 2 laughs / 5 uses = 40% — the canonical funny gem; a
        /// rate-dominant sort keeps low-rate/high-volume phrases below it.)
        public var gemMinLaughed: Int
        /// A gem's laugh-rate is only ranked once it has ≥ this many uses, so a
        /// low-rate / high-volume phrase can't outrank a high-rate catchphrase.
        public var gemMinUsesForRate: Int

        // ── emphatic constructions ──
        /// A shouted word must appear in caps ≥ this many times to surface.
        public var emphaticMinShouted: Int
        /// How many top emphatic words to return.
        public var emphaticTopK: Int

        // ── discovered vocabulary (abbreviations / slang) ──
        /// A token must be SENT ≥ this many times to be a discovered vocab item.
        public var vocabMinCount: Int
        /// A token whose baseline frequency rank is < this is a common English
        /// dictionary word and is dropped (the baseline is top-30k unigrams; a
        /// token absent from it is always kept). ~20k per the coordinator.
        public var vocabDictionaryRankGate: Int
        /// How many top discovered vocab tokens to return.
        public var vocabTopK: Int

        // ── non-caps emphasis signals (elongation / punctuation) ──
        /// A device (a stretched base word, or a punctuation-run length) must
        /// occur in ≥ this many sent messages to surface.
        public var emphasisSignalMinCount: Int
        /// How many top emphasis-signal rows to return per kind.
        public var emphasisSignalTopK: Int

        public init(
            gemMinLaughed: Int = 2,
            gemMinUsesForRate: Int = 4,
            emphaticMinShouted: Int = 2,
            emphaticTopK: Int = 12,
            vocabMinCount: Int = 8,
            vocabDictionaryRankGate: Int = 20_000,
            vocabTopK: Int = 60,
            emphasisSignalMinCount: Int = 3,
            emphasisSignalTopK: Int = 12
        ) {
            self.gemMinLaughed = gemMinLaughed
            self.gemMinUsesForRate = gemMinUsesForRate
            self.emphaticMinShouted = emphaticMinShouted
            self.emphaticTopK = emphaticTopK
            self.vocabMinCount = vocabMinCount
            self.vocabDictionaryRankGate = vocabDictionaryRankGate
            self.vocabTopK = vocabTopK
            self.emphasisSignalMinCount = emphasisSignalMinCount
            self.emphasisSignalTopK = emphasisSignalTopK
        }

        public static let `default` = SectionsOptions()
    }

    // MARK: - REACTED GEMS

    /// Build the reaction-weighted "gems": odd phrases of yours that drew
    /// repeated amused reactions. Sorted by score desc. PURE.
    /// Build the "funny" gems: odd phrases of yours that made people LAUGH.
    /// Fix #1 changes (vs the old `amused`-based version):
    ///   • Uses the per-message `laughed` flag (a 😂 laugh / assoc_type 2003
    ///     from someone else) — NOT `amused`, which also counts ❤️ love (agree)
    ///     and ‼️ emphasize (important), neither of which is humor.
    ///   • EXCLUDES any candidate whose example body contains a URL/link/promo
    ///     OR is coordination (`BelovedMessagesLoader.isCoordination`) — so
    ///     "try this on ur mac rn www.messageswrapped.com" can't be a gem. (The
    ///     loader already drops URLs corpus-wide per Fix #4; this is belt-and-
    ///     suspenders for the per-phrase body.)
    ///   • Requires `laughedCount >= gemMinLaughed` (3) AND enough volume for a
    ///     meaningful rate (`yourUses >= gemMinUsesForRate`).
    ///   • Ranks by laugh-RATE (laughedCount / uses) as the PRIMARY key, so a
    ///     2%-rate phrase with 100 uses can NOT outrank a 40%-rate catchphrase.
    ///
    /// NOTE: `amusedCount`/`amusedRate` on `ReactedGem` are KEPT (UI binds them)
    /// but now carry the LAUGH count / laugh rate. Sorted by rate desc. PURE.
    static func buildReactedGems(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        options: SectionsOptions = .default
    ) -> [ReactedGem] {
        let rarity = RarityRanker(baseline: baseline)
        // mine with the SAME ranker so the scaffolding gate and the gem
        // weirdness are computed from one identical rank table.
        let families = mineVariantFamilies(messages: messages, rarity: rarity)

        // system / auto-generated text to drop (prototype `sysJunk`, plus the
        // task's extra spotify/getapp/license/developer junk).
        let sysJunk: Set<String> = [
            "invited", "join", "blend", "kumar", "spotify", "getapp",
            "fallback", "license", "developer", "evenue", "ncommerce",
        ]

        struct Scored { let gem: ReactedGem; let rate: Double }
        var scored: [Scored] = []
        for f in families {
            let parts = f.surface.split(separator: " ").map(String.init)
            if parts.contains(where: { sysJunk.contains($0) }) { continue }
            let weird = contentScore(family: f.family, rarity: rarity) / Double(max(f.n, 1))
            var laughed = 0
            var uses = 0
            var example: String?
            var sawLink = false
            var sawCoordination = false
            for m in messages where m.fromMe && hasSub(m.words, parts) {
                uses += 1
                // EXCLUDE link/promo + coordination bodies (Fix #1). A single
                // polluted body taints the whole phrase — these phrases are not
                // organic catchphrases.
                if VernacularLoader.containsURL(m.bodyLow) { sawLink = true }
                if BelovedMessagesLoader.isCoordination(m.body) { sawCoordination = true }
                if m.laughed { laughed += 1 }
                if example == nil {
                    let one = m.body.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    if !one.isEmpty { example = one }
                }
            }
            if sawLink || sawCoordination { continue }
            // Rate is computed over the actual uses (floored so a 3-use phrase
            // can't post an inflated rate); volume gate is applied below.
            let rate = Double(laughed) / Double(max(uses, options.gemMinUsesForRate))
            let gem = ReactedGem(phrase: f.surface, yourUses: f.you, amusedCount: laughed,
                                 amusedRate: rate, weirdness: weird, example: example)
            scored.append(Scored(gem: gem, rate: rate))
        }
        let ranked = scored
            .filter { $0.gem.amusedCount >= options.gemMinLaughed
                       && $0.gem.yourUses >= options.gemMinUsesForRate }
            // PRIMARY: laugh-rate; tie-break by raw laugh count then weirdness so
            // the order is deterministic.
            .sorted {
                if $0.rate != $1.rate { return $0.rate > $1.rate }
                if $0.gem.amusedCount != $1.gem.amusedCount { return $0.gem.amusedCount > $1.gem.amusedCount }
                return $0.gem.weirdness > $1.gem.weirdness
            }
            .map { $0.gem }
        // Fix #1 (collapse): the variant-family miner emits a gem per n-gram
        // length, so a single catchphrase surfaces as a stack of overlapping
        // fragments ("not on my bingo" / "not on my bingo card" / "was not on
        // my bingo card"). Fold each overlapping family to its MOST SPECIFIC
        // (longest) member — the fuller expression is the more striking one —
        // using that representative's own count + laugh-rate.
        return collapseGemFamilies(ranked)
    }

    /// Collapse near-duplicate "gem" rows into one representative each. Two gems
    /// belong to the same family when one's token sequence is a contiguous
    /// subsequence of the other, OR they share a contiguous run of ≥3 tokens.
    /// The kept representative is the LONGEST (most tokens; ties → longer string,
    /// then better original rank) member of the family — the fuller expression
    /// reads as the real catchphrase. Input order is treated as the ranking;
    /// output preserves the best (earliest) rank each surviving family held, so
    /// the list stays rate-ordered. PURE.
    static func collapseGemFamilies(_ gems: [ReactedGem]) -> [ReactedGem] {
        guard gems.count > 1 else { return gems }
        let toks: [[String]] = gems.map { $0.phrase.split(separator: " ").map(String.init) }
        // Union-find over gem indices: union any two that share a family.
        var parent = Array(0..<gems.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        for i in 0..<gems.count {
            for j in (i + 1)..<gems.count where sameGemFamily(toks[i], toks[j]) {
                union(i, j)
            }
        }
        // Per family root, pick the most-specific representative; remember the
        // earliest original index so the collapsed list keeps the input ranking.
        var repForRoot: [Int: Int] = [:]
        var bestRankForRoot: [Int: Int] = [:]
        for i in 0..<gems.count {
            let r = find(i)
            bestRankForRoot[r] = min(bestRankForRoot[r] ?? i, i)
            if let cur = repForRoot[r] {
                if isMoreSpecific(candidate: i, than: cur, toks: toks) { repForRoot[r] = i }
            } else {
                repForRoot[r] = i
            }
        }
        return repForRoot.keys
            .sorted { (bestRankForRoot[$0] ?? 0) < (bestRankForRoot[$1] ?? 0) }
            .compactMap { repForRoot[$0] }
            .map { gems[$0] }
    }

    /// Two token sequences are the same gem family iff one is a contiguous
    /// subsequence of the other, OR they share a contiguous run of ≥3 tokens.
    static func sameGemFamily(_ a: [String], _ b: [String]) -> Bool {
        if hasSub(a, b) || hasSub(b, a) { return true }       // contiguous substring either way
        // ≥3-token contiguous shared core.
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 3 else { return false }
        var n = short.count
        while n >= 3 {
            var i = 0
            while i + n <= short.count {
                if hasSub(long, Array(short[i..<i + n])) { return true }
                i += 1
            }
            n -= 1
        }
        return false
    }

    /// The fuller catchphrase wins: more tokens, then longer surface string,
    /// then the better (smaller) original rank index for determinism.
    private static func isMoreSpecific(candidate i: Int, than j: Int, toks: [[String]]) -> Bool {
        if toks[i].count != toks[j].count { return toks[i].count > toks[j].count }
        if toks[i].joined().count != toks[j].joined().count {
            return toks[i].joined().count > toks[j].joined().count
        }
        return i < j
    }

    // MARK: (D) EMPHATIC CONSTRUCTIONS (case-sensitive — Fix #3)

    /// Detect the user's SHOUTED-for-emphasis words over ORIGINAL-CASE sent
    /// text. The rest of the engine lowercases everything, collapsing
    /// "ts is NOT it" ≡ "ts is not it"; this is the one place that keeps case.
    ///
    /// An emphatic-caps token is: all-uppercase, ≥2 letters, letters-only, that
    /// ALSO appears LOWERCASED somewhere in the user's messages (so it's a word
    /// they shout — NOT/NEVER/ACTUALLY — not an acronym like IDK/USA), and not
    /// in a small acronym stoplist. Returns the top shouted words with counts,
    /// a dominant short frame ("is NOT ___"), and 1-2 example messages. PURE.
    static func buildEmphaticConstructions(
        messages: [VernacularMessage],
        options: SectionsOptions = .default
    ) -> [EmphaticItem] {
        EmphaticDetector.detect(sentBodies: messages.compactMap { $0.fromMe ? $0.body : nil },
                                options: options)
    }

    // MARK: (E) DISCOVERED VOCABULARY (token-level, DISCOVERY not curated)

    /// Discover the user's distinctive single-token vocabulary — clippings
    /// ("rlly"/"abt"/"u"), internet-native slang ("hella"/"deadass"), texting
    /// shorthand ("ngl"/"fr"/"idk") — from THEIR OWN sent text, NOT a curated
    /// lexicon (coordinator revision). A token surfaces iff it is:
    ///   • sent ≥ `vocabMinCount` times (times-sent floor),
    ///   • NOT a standard-English dictionary word — its baseline rank is
    ///     ≥ `vocabDictionaryRankGate` (~20k) OR it is absent from the baseline
    ///     entirely (the baseline is the top-30k English unigrams),
    ///   • NOT a contact name fragment (any whitespace-split token of any
    ///     resolved contact's display name — first OR last),
    ///   • letters/apostrophe only (the tokenizer already guarantees this; we
    ///     additionally drop tokens that are a single repeated letter and pure
    ///     laugh-keyboard mash so "aaaa"/"hahaha" don't dominate).
    /// Ranked by `count` (times sent) DESCENDING — the uniform order. PURE.
    ///
    /// This is DELIBERATELY token-level only: multi-word over-representation
    /// discovery is what produced the rejected names/places/generic garbage
    /// ("be able to", "los angeles ca"), so it is NOT used here.
    static func discoverVocab(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        options: SectionsOptions = .default
    ) -> [VocabItem] {
        let rarity = RarityRanker(baseline: baseline)

        // Contact name fragments to exclude (first + last, lowercased). Built
        // from the resolved contacts' display names. Also seed the unknown
        // sentinel's tokens so it can never leak.
        var nameTokens = Set<String>()
        for c in contacts.allContacts {
            for part in c.displayName.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }) {
                let low = part.lowercased()
                if low.count >= 2 { nameTokens.insert(low) }
            }
        }

        // Count occurrences in SENT text (times-sent), and distinct OTHER
        // people who also use each surviving token (spread, for context).
        var sentCount: [String: Int] = [:]
        var peopleByToken: [String: Set<String>] = [:]
        for m in messages {
            if m.fromMe {
                for w in m.words { sentCount[w, default: 0] += 1 }
            }
        }
        // dictionary gate: a token is a common English word if EITHER it, OR its
        // apostrophe-stripped form, has a baseline rank under the gate. The
        // strip matters because our tokenizer keeps apostrophes inside a token
        // ("i'm"/"it's"/"don't") whereas the baseline split them — so "i'm" is
        // absent as a whole token but "im" is a top-rank dictionary word. Without
        // this, standard CONTRACTIONS would masquerade as discovered "slang";
        // genuine clippings ("rlly"/"abt") have no dictionary form either way.
        func isDictionaryWord(_ tok: String) -> Bool {
            if let r = rarity.rankOf[tok], r < options.vocabDictionaryRankGate { return true }
            if tok.contains("'") || tok.contains("\u{2019}") {
                let stripped = tok.replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")
                if let r = rarity.rankOf[stripped], r < options.vocabDictionaryRankGate { return true }
            }
            return false
        }
        // Pre-filter the candidate set BEFORE the (more expensive) people pass.
        func isCandidate(_ tok: String) -> Bool {
            guard tok.count >= 1, (sentCount[tok] ?? 0) >= options.vocabMinCount else { return false }
            if isDictionaryWord(tok) { return false }
            // contact-name gate.
            if nameTokens.contains(tok) { return false }
            // junk gate: a single repeated letter ("aaaa", "mmmm", "uuu") or a
            // laugh mash ("hahaha"/"hahah"/"ahaha") is not vocabulary.
            if isSingleRepeatedLetter(tok) || isLaughMash(tok) { return false }
            return true
        }
        let candidates = Set(sentCount.keys.filter(isCandidate))
        guard !candidates.isEmpty else { return [] }
        for m in messages where !m.fromMe {
            let who = m.who
            guard who != Self.unknownLabel else { continue }
            for w in m.wordSet where candidates.contains(w) {
                peopleByToken[w, default: []].insert(who)
            }
        }

        var items = candidates.map { tok in
            VocabItem(token: tok, count: sentCount[tok] ?? 0,
                      peopleCount: peopleByToken[tok]?.count ?? 0)
        }
        // times-sent DESC, then token for stable order.
        items.sort { $0.count != $1.count ? $0.count > $1.count : $0.token < $1.token }
        return Array(items.prefix(options.vocabTopK))
    }

    /// A token that is a single letter repeated (≥2 chars, all the same letter):
    /// "aaaa", "mmmm", "uuu", "lll". Not vocabulary.
    private static func isSingleRepeatedLetter(_ tok: String) -> Bool {
        guard tok.count >= 2, let first = tok.first else { return false }
        return tok.allSatisfy { $0 == first }
    }

    /// A laugh-keyboard mash made only of h/a/(e) in an alternating-ish run
    /// ("haha", "hahaha", "ahaha", "hahah", "heh", "hahahaha"). These are
    /// expressive noise, not distinctive vocabulary. Conservative: token is ≥3
    /// chars, made ONLY of {h,a,e}, and contains at least one 'h' and one 'a'.
    private static func isLaughMash(_ tok: String) -> Bool {
        guard tok.count >= 3 else { return false }
        let allowed: Set<Character> = ["h", "a", "e"]
        guard tok.allSatisfy({ allowed.contains($0) }) else { return false }
        return tok.contains("h") && tok.contains("a")
    }

    /// Split the discovered vocabulary into clipping-shaped "abbreviations"
    /// (short shorthand: ≤ `len` letters — "u"/"ur"/"abt"/"rlly"/"ngl"/"tmrw")
    /// vs longer "slang" ("hella"/"deadass"/"lowkey"/"crashout"). BOTH come from
    /// the SAME discovery pass (not a curated list) and stay ordered by count.
    /// A transparent length split — the coordinator allows keeping the
    /// abbreviation/slang split as long as it's discovery-based. PURE.
    static func splitVocab(_ items: [VocabItem], abbreviationMaxLen len: Int = 4)
        -> (abbreviations: [VocabItem], slang: [VocabItem]) {
        var abbr: [VocabItem] = []
        var slang: [VocabItem] = []
        for it in items {
            if it.token.count <= len { abbr.append(it) } else { slang.append(it) }
        }
        return (abbr, slang)
    }

    // MARK: (F) NON-CAPS EMPHASIS SIGNALS (elongation + repeated punctuation)

    /// Generalize "how you emphasize" beyond ALL-CAPS shouting (Task #3) so a
    /// user who never shouts in caps still gets signal: detect word ELONGATION
    /// (3+ of the same letter — "soooo"/"nooo"/"ahhh") and repeated PUNCTUATION
    /// ("!!!"/"???") in the user's SENT text. Returns one row per concrete
    /// device, ranked by `count` (sent messages using it) DESC. PURE.
    static func buildEmphasisSignals(
        messages: [VernacularMessage],
        options: SectionsOptions = .default
    ) -> [EmphasisSignal] {
        EmphasisSignalDetector.detect(
            sentBodies: messages.compactMap { $0.fromMe ? $0.body : nil }, options: options)
    }

    // MARK: (C) VARIANT FAMILIES (shared)

    /// A normalized n-gram family: the §-slotted skeleton, its most-common
    /// surface form, your count, over-representation vs others, and length.
    struct VariantFamily: Sendable, Equatable {
        public let family: String      // normalized, e.g. "picking up what §s putting down"
        public let surface: String     // most-common surface form
        public let you: Int
        public let over: Double
        public let n: Int
        /// All surface forms with counts (for display), sorted desc.
        public let variants: [(form: String, count: Int)]

        public static func == (l: VariantFamily, r: VariantFamily) -> Bool {
            l.family == r.family && l.surface == r.surface && l.you == r.you
                && l.over == r.over && l.n == r.n
                && l.variants.map(\.form) == r.variants.map(\.form)
                && l.variants.map(\.count) == r.variants.map(\.count)
        }
    }

    /// Mine normalized n-gram families (len 3-6) where pronoun/aux/possessive/
    /// object variants are collapsed into §s/§p/§o slots, so "im/i'm/you're"
    /// count together. Faithful port of `/tmp/meme`'s family block. Sorted by
    /// (over × n) desc. PURE.
    ///
    /// `rarity` supplies general-English ranks for the "all-common scaffolding"
    /// gate (prototype `commonRank[$0] < 600`). Defaults to the shared ranker
    /// built from the bundled baseline so callers can mine families without a
    /// baseline parameter.
    static func mineVariantFamilies(
        messages: [VernacularMessage],
        rarity: RarityRanker = SharedRarity.shared
    ) -> [VariantFamily] {
        func minCount(_ n: Int) -> Int { n == 3 ? 5 : 3 }

        // YOURS: family counts + surface-form counts.
        var youFam: [String: Int] = [:]
        var youTotTok = 0
        var famSurface: [String: [String: Int]] = [:]
        for m in messages where m.fromMe {
            let t = m.words
            if t.count < 3 { continue }
            let nt = t.map(normSlot)
            var n = 3
            while n <= 6 {
                if t.count >= n {
                    var i = 0
                    while i <= t.count - n {
                        let fam = nt[i..<i+n].joined(separator: " ")
                        if fam.contains("\u{00A7}") {       // contains a § slot
                            youFam[fam, default: 0] += 1
                            youTotTok += 1
                            let surf = t[i..<i+n].joined(separator: " ")
                            famSurface[fam, default: [:]][surf, default: 0] += 1
                        }
                        i += 1
                    }
                }
                n += 1
            }
        }
        let keepFam = Set(youFam.filter { $0.value >= minCount($0.key.split(separator: " ").count) }.keys)

        // OTHERS: counts over the kept set.
        var othFam: [String: Int] = [:]
        var othTotTok = 0
        for m in messages where !m.fromMe {
            let t = m.words
            if t.count < 3 { continue }
            let nt = t.map(normSlot)
            var n = 3
            while n <= 6 {
                if t.count >= n {
                    var i = 0
                    while i <= t.count - n {
                        let fam = nt[i..<i+n].joined(separator: " ")
                        if keepFam.contains(fam) { othFam[fam, default: 0] += 1 }
                        othTotTok += 1
                        i += 1
                    }
                }
                n += 1
            }
        }

        let stopEdge: Set<String> = [
            "\u{00A7}s", "\u{00A7}p", "\u{00A7}o", "a", "the", "to", "of", "and", "is", "it",
            "do", "so", "or", "but", "for", "on", "at", "in", "be", "as", "if", "that",
            "this", "u", "i", "me", "my", "ur",
        ]
        var fams: [VariantFamily] = []
        for f in keepFam {
            let parts = f.split(separator: " ").map(String.init)
            guard let first = parts.first, let last = parts.last else { continue }
            if stopEdge.contains(first) || stopEdge.contains(last) { continue }
            let nonSlot = parts.filter { $0 != "\u{00A7}s" && $0 != "\u{00A7}p" && $0 != "\u{00A7}o" }
            if nonSlot.allSatisfy({ (rarity.rankOf[$0] ?? 99_999) < 600 }) { continue }   // all-common scaffolding
            let cy = youFam[f] ?? 0
            let co = othFam[f] ?? 0
            let over = (Double(cy) / Double(max(youTotTok, 1))) / (Double(co + 1) / Double(othTotTok + 1))
            if over < 4 { continue }
            let sortedSurf = (famSurface[f]?.sorted { $0.value > $1.value }) ?? []
            let surf = sortedSurf.first?.key ?? f
            let n = parts.count
            fams.append(VariantFamily(family: f, surface: surf, you: cy, over: over, n: n,
                                      variants: sortedSurf.map { ($0.key, $0.value) }))
        }
        fams.sort { ($0.over * Double($0.n)) > ($1.over * Double($1.n)) }
        return fams
    }

    // MARK: - shared primitives (ported from /tmp/meme)

    /// VARIANT NORMALIZATION: collapse subject/aux → §s, possessive → §p,
    /// object → §o. Other words pass through. Matches the prototype's `norm`.
    static func normSlot(_ w: String) -> String {
        if subjSlot.contains(w) { return "\u{00A7}s" }
        if possSlot.contains(w) { return "\u{00A7}p" }
        if objSlot.contains(w) { return "\u{00A7}o" }
        return w
    }

    private static let subjSlot: Set<String> = [
        "i'm", "im", "i\u{2019}m", "you're", "youre", "ur", "you\u{2019}re",
        "he's", "hes", "she's", "shes", "they're", "theyre", "we're", "were",
        "that's", "thats", "it's", "its", "i", "you", "he", "she", "they", "we",
    ]
    private static let possSlot: Set<String> = [
        "my", "your", "his", "her", "their", "our", "ur", "its",
    ]
    private static let objSlot: Set<String> = [
        "me", "you", "him", "her", "them", "us",
    ]

    /// Substring match of token sequence `pattern` inside `tokens` (prototype
    /// `hasSub`). Exposed internal so the section builders share one definition.
    static func hasSub(_ tokens: [String], _ pattern: [String]) -> Bool {
        if pattern.isEmpty || pattern.count > tokens.count { return false }
        let lim = tokens.count - pattern.count
        var i = 0
        while i <= lim {
            var ok = true
            var j = 0
            while j < pattern.count {
                if tokens[i + j] != pattern[j] { ok = false; break }
                j += 1
            }
            if ok { return true }
            i += 1
        }
        return false
    }

    /// Sum of general-English rarity over a family's non-slot tokens (prototype
    /// `contentScore`). Slots contribute 0.
    private static func contentScore(family: String, rarity: RarityRanker) -> Double {
        family.split(separator: " ").map { tok -> Double in
            (tok == "\u{00A7}s" || tok == "\u{00A7}p" || tok == "\u{00A7}o")
                ? 0 : rarity.rarity(String(tok))
        }.reduce(0, +)
    }
}

// MARK: - EmphaticDetector (case-sensitive shouted-word detection — Fix #3)

/// Finds the words the user SHOUTS for emphasis, over ORIGINAL-CASE text. Pure
/// + standalone (no baseline needed) so it's trivially unit-testable. See
/// `EmphaticItem` / `buildEmphaticConstructions` for the contract.
public enum EmphaticDetector {

    /// Internet/texting + proper-noun acronyms that are typed in caps WITHOUT
    /// being emphasis. The "appears lowercased elsewhere" gate already drops
    /// most proper-noun acronyms (you rarely write "usa" in prose); this catches
    /// the texting acronyms (lol/idk/…) that DO appear lowercased a lot.
    public static let acronymStoplist: Set<String> = [
        "lol", "lmao", "lmfao", "idk", "idc", "tbh", "imo", "imho", "fr", "ngl",
        "omg", "wtf", "wth", "smh", "istg", "ikr", "ts", "icl", "fyi", "btw",
        "asap", "aka", "rn", "af", "ong", "iirc", "irl", "dm", "pfp", "gg",
        "usa", "uk", "us", "nyc", "la", "tv", "ai", "ceo", "id", "ok", "pm", "am",
    ]

    /// WEAK shouted words to DROP (Task #2): pronouns + ultra-common /
    /// sentence-initial words that get capitalized for reasons OTHER than
    /// emphasis (sentence start, list headers, "WE need…", "OH no", "YOU guys")
    /// — the user flagged WE/OH/YOU/NO/ALL as noise, the same class as the UCLA
    /// acronym already filtered. This is a DENYLIST of known false-positives, NOT
    /// an allowlist: genuine emphasis words (NOT/REALLY/SO/NEVER/HELLA/WAIT/
    /// ACTUALLY/LITERALLY and any other adverb/negation/intensifier the user
    /// actually shouts) are deliberately ABSENT and still surface — note SO is
    /// KEPT (an intensifier) even though the near-twin NO is dropped, matching
    /// the user's explicit keep/drop lists. Lowercased forms.
    public static let weakShoutStoplist: Set<String> = [
        // personal / possessive / demonstrative pronouns (a whole noise class)
        "i", "we", "you", "he", "she", "it", "they", "me", "us", "him", "them",
        "my", "your", "our", "his", "her", "their", "its", "this", "that",
        "these", "those", "who", "u", "ur",
        // ultra-common determiners / conjunctions / prepositions / copula /
        // interjections that capitalize for non-emphasis reasons (sentence start,
        // list headers, SQL/code like "… AS email"). Same class as the user's
        // named IS/THE/AND/A/NO/ALL. (KEEP "so" — an intensifier.)
        "oh", "no", "yes", "yeah", "all", "a", "an", "the", "and", "or", "but",
        "is", "are", "was", "were", "be", "am", "of", "to", "as", "if", "in",
        "on", "at", "by", "for", "from", "with", "hi", "hey", "yo",
    ]

    /// Case-PRESERVING tokenizer matching `VernTokens.words`'s split rules
    /// (letters + apostrophes are token chars) but WITHOUT lowercasing.
    static func tokensPreservingCase(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
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

    /// A token that is shouted caps: ≥2 chars, ALL letters (no apostrophes/
    /// digits), and all-uppercase (has at least one cased letter and equals its
    /// own uppercasing).
    static func isShoutToken(_ tok: String) -> Bool {
        guard tok.count >= 2 else { return false }
        guard tok.allSatisfy({ $0.isLetter }) else { return false }
        let upper = tok.uppercased()
        return tok == upper && upper != tok.lowercased()
    }

    public static func detect(
        sentBodies: [String],
        options: VernacularAnalyzer.SectionsOptions = .default
    ) -> [EmphaticItem] {
        // Pre-tokenize once (case-preserving), reused across both passes.
        let tokenized = sentBodies.map { (body: $0, toks: tokensPreservingCase($0)) }

        // PASS 1: per lowercased word, how many times it appears LOWERCASED
        // (its calm baseline). Used to require the shouted word is one the user
        // also writes in lower case (so it's a word, not an acronym).
        var lowerCount: [String: Int] = [:]
        for entry in tokenized {
            for tok in entry.toks where tok == tok.lowercased() && tok != tok.uppercased() {
                lowerCount[tok, default: 0] += 1
            }
        }

        // PASS 2: collect shouts per UPPERCASE word.
        struct Agg {
            var shouted = 0
            var prev: [String: Int] = [:]      // lowercased previous token
            var next: [String: Int] = [:]      // lowercased next token
            var examples: [String] = []
        }
        var byWord: [String: Agg] = [:]
        for entry in tokenized {
            let toks = entry.toks
            // EMPHASIS, not yelling: only count caps words in a MIXED-CASE
            // message (≥1 lowercased word token). A fully-capslocked message
            // ("WE NEED U ON THE BASS DRUM") is whole-message shouting, not
            // per-word emphasis — every word there would falsely look emphatic.
            let hasLowerWord = toks.contains { $0 == $0.lowercased() && $0 != $0.uppercased() }
            guard hasLowerWord else { continue }
            for (i, tok) in toks.enumerated() {
                guard isShoutToken(tok) else { continue }
                let lower = tok.lowercased()
                // must appear lowercased elsewhere (a shoutable WORD), and not a
                // known acronym, and not a WEAK pronoun / sentence-initial word
                // (Task #2 de-noising — WE/OH/YOU/NO/ALL etc.).
                guard (lowerCount[lower] ?? 0) > 0 else { continue }
                guard !acronymStoplist.contains(lower) else { continue }
                guard !weakShoutStoplist.contains(lower) else { continue }
                let word = tok.uppercased()
                var agg = byWord[word] ?? Agg()
                agg.shouted += 1
                if i > 0 { agg.prev[toks[i - 1].lowercased(), default: 0] += 1 }
                if i + 1 < toks.count { agg.next[toks[i + 1].lowercased(), default: 0] += 1 }
                // EXAMPLE BUG FIX (Task #2): the example MUST contain the shouted
                // word. We are inside the loop because `tok` (≡ `word` uppercased)
                // is in THIS message, so `entry.body` does contain it — but make
                // the guarantee EXPLICIT + defensive: store the example tokenized
                // alongside so the verify step (and any caller) can assert the
                // all-caps token is present.
                if agg.examples.count < 2 {
                    let one = entry.body
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    // Belt-and-suspenders: only accept it if its case-preserving
                    // tokens contain the exact all-caps WORD.
                    if !one.isEmpty, !agg.examples.contains(one),
                       tokensPreservingCase(one).contains(word) {
                        agg.examples.append(one)
                    }
                }
                byWord[word] = agg
            }
        }

        var items: [EmphaticItem] = []
        for (word, agg) in byWord where agg.shouted >= options.emphaticMinShouted {
            let low = lowerCount[word.lowercased()] ?? 0
            // A genuine emphasis word is one the user NORMALLY writes lowercased
            // and occasionally SHOUTS — so its calm form must dominate. This
            // drops domain acronyms (e.g. "NLP" shouted ×24 but only lowercased
            // ×15) that the lowercased-elsewhere gate alone lets through.
            guard low > agg.shouted else { continue }
            items.append(EmphaticItem(
                word: word,
                shoutedCount: agg.shouted,
                lowercasedCount: low,
                frame: frame(word: word, prev: agg.prev, next: agg.next, shouts: agg.shouted),
                examples: agg.examples))
        }
        // most-shouted first, then alphabetical for stability.
        items.sort {
            if $0.shoutedCount != $1.shoutedCount { return $0.shoutedCount > $1.shoutedCount }
            return $0.word < $1.word
        }
        return Array(items.prefix(options.emphaticTopK))
    }

    /// Build a short construction frame "left WORD right". A side is the
    /// dominant lowercased neighbor when it accounts for ≥ half the shouts (and
    /// occurs ≥2×); otherwise the slot is "___". Returns nil if both slots vary
    /// AND there's no signal (degenerate "___ WORD ___" is still useful, so we
    /// always return a frame).
    static func frame(word: String, prev: [String: Int], next: [String: Int], shouts: Int) -> String? {
        func dominant(_ counts: [String: Int]) -> String {
            guard let top = counts.max(by: { $0.value < $1.value }) else { return "___" }
            return (top.value >= 2 && Double(top.value) >= 0.5 * Double(shouts)) ? top.key : "___"
        }
        return "\(dominant(prev)) \(word) \(dominant(next))"
    }
}

// MARK: - EmphasisSignalDetector (non-caps emphasis — Task #3)

/// Detects NON-CAPS emphasis devices in the user's sent text so a user who
/// never shouts in caps still gets a populated "how you emphasize" view: word
/// ELONGATION (3+ repeated letters — "soooo"/"nooo"/"ahhh") and repeated
/// PUNCTUATION ("!!!"/"???"). Pure + standalone (no baseline) so it's trivially
/// unit-testable. Ranked by count (sent messages using the device) DESC.
public enum EmphasisSignalDetector {

    /// The canonical BASE key for a stretched token: every maximal run of the
    /// same character is squeezed to a SINGLE character ("soooo"→"so",
    /// "nooo"→"no", "ahhhh"→"ah", "yesss"→"yes", "omggg"→"omg"). Returns nil for
    /// a token with NO ≥3 run (not stretched). This is only a GROUPING key — the
    /// row's `example` shows the real typed form — so collapsing genuine double
    /// letters too (e.g. "realllly"→"realy") is harmless: it still groups all
    /// stretch-variants of the same word together.
    static func stretchBase(_ tokenLower: String) -> String? {
        guard hasStretch(tokenLower) else { return nil }
        var base = ""
        var prev: Character? = nil
        for ch in tokenLower where ch != prev {
            base.append(ch)
            prev = ch
        }
        return base.isEmpty ? nil : base
    }

    /// True iff the token has a run of ≥3 of the same letter (matches
    /// `VibeFeatures.hasStretch` semantics at the token level).
    static func hasStretch(_ tokenLower: String) -> Bool {
        var run = 1
        var prev: Character? = nil
        for ch in tokenLower {
            if ch == prev {
                run += 1
                if run >= 3 && ch.isLetter { return true }
            } else { run = 1 }
            prev = ch
        }
        return false
    }

    public static func detect(
        sentBodies: [String],
        options: VernacularAnalyzer.SectionsOptions = .default
    ) -> [EmphasisSignal] {
        struct Agg { var count = 0; var example = "" }
        var elong: [String: Agg] = [:]         // base word → agg
        var punct: [String: Agg] = [:]         // "!" / "?" run-class → agg

        for body in sentBodies {
            let low = body.lowercased()
            // ELONGATION: scan original-case tokens (so the example is as typed),
            // but key on the lowercased base. Count once per (message, base).
            var seenBasesThisMsg = Set<String>()
            for tok in EmphaticDetector.tokensPreservingCase(body) {
                let tl = tok.lowercased()
                guard hasStretch(tl), let base = stretchBase(tl) else { continue }
                if seenBasesThisMsg.contains(base) { continue }
                seenBasesThisMsg.insert(base)
                var a = elong[base] ?? Agg()
                a.count += 1
                if a.example.isEmpty { a.example = tok }     // the stretched word as typed
                elong[base] = a
            }

            // REPEATED PUNCTUATION: runs of ≥2 of "!" or "?" → key "!!" / "??".
            // Count once per (message, mark). The example is the longest run of
            // that mark in the message.
            for mark in ["!", "?"] as [Character] {
                var best = 0
                var run = 0
                for ch in low {
                    if ch == mark { run += 1; best = max(best, run) } else { run = 0 }
                }
                if best >= 2 {
                    let key = String(repeating: mark, count: 2)   // canonical "!!"/"??"
                    var a = punct[key] ?? Agg()
                    a.count += 1
                    let run = String(repeating: mark, count: best)
                    if run.count > a.example.count { a.example = run }
                    punct[key] = a
                }
            }
        }

        func rows(_ dict: [String: Agg], kind: EmphasisSignal.Kind) -> [EmphasisSignal] {
            dict.compactMap { (key, a) -> EmphasisSignal? in
                guard a.count >= options.emphasisSignalMinCount else { return nil }
                let example = a.example.isEmpty ? key : a.example
                return EmphasisSignal(kind: kind, key: key, count: a.count, example: example)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
            .prefix(options.emphasisSignalTopK)
            .map { $0 }
        }

        // Both kinds, each ranked by count desc, elongation first then punctuation
        // (UI can group by `kind`).
        return rows(elong, kind: .elongation) + rows(punct, kind: .repeatedPunctuation)
    }
}

// MARK: - rarity ranking (general-English baseline ranks)

/// Maps a word to a general-English RARITY value from the shipped baseline:
/// rank-by-frequency (rarer ⇒ higher rank ⇒ higher rarity); words absent from
/// the baseline are treated as very rare. Mirrors `/tmp/meme`'s `commonRank` /
/// `rarity` (the prototype used the file LINE INDEX; we derive an equivalent
/// rank by sorting the baseline counts descending — same monotone signal).
public struct RarityRanker: Sendable {
    /// word -> 0-based rank (0 = most common). Built once from the baseline.
    public let rankOf: [String: Int]
    /// Rarity for an out-of-vocabulary (not in top-N) word: log(60000).
    public static let oovRarity = log(60_000.0)

    public init(baseline: LinguisticBaseline) {
        let sorted = baseline.counts.sorted { l, r in
            if l.value != r.value { return l.value > r.value }
            return l.key < r.key            // stable tie-break for determinism
        }
        var map: [String: Int] = [:]
        map.reserveCapacity(sorted.count)
        for (i, kv) in sorted.enumerated() { map[kv.key] = i }
        self.rankOf = map
    }

    /// Higher = rarer in general English. Ranked word at rank r ⇒ log(r + 50);
    /// unranked ⇒ log(60000). (Prototype `rarity`.)
    public func rarity(_ w: String) -> Double {
        if let r = rankOf[w] { return log(Double(r + 50)) }
        return Self.oovRarity
    }
}

/// Process-wide lazily-loaded rarity ranks, so `mineVariantFamilies` (which the
/// prototype runs against the bundled baseline file) can apply the same
/// "all-common scaffolding" gate without taking a baseline parameter. Loaded
/// once; pure thereafter. Public only because it is the default value of a
/// public method's parameter; not meant for general use.
public struct SharedRarity {
    public static let shared = RarityRanker(baseline: LinguisticBaseline.load())
}
