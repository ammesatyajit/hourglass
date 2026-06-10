//
//  VernacularAnomalies.swift
//  Hourglass — Vernacular Analysis (TWO clean anomaly-first data products)
//
//  North star: "nothing matters unless it's an anomaly." The vernacular must
//  surface the RARE / WEIRD / distinctive — not common words. Two pure data
//  products, ported + cleaned from the validated standalone prototypes that ran
//  against the real chat.db:
//
//   (A) ANOMALOUS WORDS  (port of /tmp/anom) — single tokens YOU send ≥6× that
//       are RARE in the shipped general-English baseline (baseline rank > 7000,
//       or absent from the 30k unigrams). This is the user's genuinely odd
//       slang: rizz / glaze / npc / aura / mog / goated / huzz / chopped /
//       tweaking / pmo / yap / yessir / opp / crashout / cone …  EXCLUDING the
//       three leak classes that otherwise pollute a raw rarity scan:
//         • apostrophe-contractions (i'm/it's/don't/didn't…). Our tokenizer
//           keeps the apostrophe INSIDE the token, and the baseline split it —
//           so "don't"/"dont" look "absent". We normalize curly ’→' , strip the
//           apostrophe, and drop the token if its base form is a normal
//           contraction stem (im→i'm, dont→don't, didnt, cant, youre …).
//         • contact names — any whitespace fragment of a resolved contact's
//           display name (venkat/amma/beck/anshul/shreya/atul…), first OR last.
//         • AMBIENT texting register — generic shorthand (ur/rn/abt/tho/idk/ngl/
//           fr/lol/bruh/hella/cuz…) that is "rare in English" only because
//           English isn't texting. NOT a hardcoded word list — DERIVED from the
//           user's own data by the CORPUS-ROBUST two-signal `AmbientRegisterModel`
//           (Codex upgrade #1): a token is ambient iff its person-DF (fraction of
//           ACTIVE contacts who use it) is HIGH **and** its weighted log-odds
//           (Monroe-Colaresi-Quinn "Fightin' Words", informative Dirichlet prior)
//           shows it is NOT over-represented in the user's own speech. Selective
//           slang the user over-uses is KEPT even when widely shared. Replaces the
//           old fixed `ambientPeopleCutoff = 25` count (overfit to corpus size;
//           now only a sparse-data fallback). Auto-adapts to spelling variants.
//         • residual acronym / topic jargon (ai/ml/gpt/api…) — the small noise
//           class the ubiquity filter misses at low ubiquity.
//       ADMISSION (2026-06-03 v2): "anomaly = RARITY", so candidates are the
//       DEDUP UNION of a top-by-COUNT tier (high-use slang) and a top-by-RARITY
//       tier (rare-but-low-use slang the count tier can't reach — yap/crashout/
//       mog), capped at the AI judge's budget; the gated `judgeWords` pass then
//       drops the names/brands/foreign/typos rarity alone can't. DISPLAY is
//       count-ordered ("ordering by times used").
//
//   (B) SNOWCLONE TEMPLATES  (port of /tmp/frames) — the frames the user builds
//       sentences on ("holy ___", "___ ahh", "___ -core", "___ -coded",
//       "___ or nah", …), DISCOVERED from the data, NOT a hardcoded catalog
//       ("why isn't 'holy ___' found? it should find these by itself"). We mine
//       single-slot 2/3-gram skeletons over the user's sent messages, then
//       apply a name / ambient-shorthand / productivity filter. Pure statistics
//       cannot separate real snowclones (holy ___, ___ ahh, we are ___) from
//       abbreviation-anchors (shld ___, obv ___), name-possessives (venkat's
//       ___) and grammar (i think ___) — so we publish TWO tiers:
//         • CONSERVATIVE (offline, Phase 1): additionally require ≥1 DISTINCTIVE
//           anchor → a clean-enough no-model set (holy ___, ___ ahh, ___ -core,
//           ___ -coded). This is `templates`.
//         • BROAD pool (Phase 2): the full candidate set for the optional AI
//           judge (`VernacularAILabeling.judgeFrames`) to keep/drop. Kept frames
//           are rebuilt into `templates` WITH the decisive Layer-3 attribution
//           ("we are ___" → Venkat, "brother ___" → Keeshant), which is computed
//           ONLY for kept frames (it is the expensive part). Ranked by count.
//
//  PURE: every builder is a deterministic function of `[VernacularMessage]`
//  (+ the bundled baseline for rarity, + `ResolvedContacts` to exclude names).
//  No I/O — the chat.db read lives in `VernacularLoader`. Computed in the SAME
//  off-main Phase-1 pass as everything else (no extra read / decode).
//

import Foundation

/// Cached baseline for `isNameForm`'s nickname-prefix exemption — the
/// predicate runs per token, and `LinguisticBaseline.load()` parses the
/// bundled asset on every call.
private let nicknameExemptionBaseline = LinguisticBaseline.load()

// MARK: - Public Sendable result types

/// One snowclone FRAME the user builds on (a curated template with a varying
/// `_` slot), with how the user fills it. See file header for the catalog.
public struct SnowcloneTemplate: Identifiable, Sendable, Equatable {
    public let id: String        // == frame label
    /// The human-readable frame, each "_" a varying slot: "we are so _",
    /// "_ ahh _", "brother _", "_ is NOT _ lil bro".
    public let frame: String
    /// How many of YOUR sent messages match the frame.
    public let count: Int
    /// Top fills for the varying slot, by frequency desc (the words/short
    /// chunks you actually drop into the blank). `fill` is lowercased.
    public let topFills: [Fill]
    /// 1-2 real example sent messages matching the frame (newlines stripped).
    public let examples: [String]
    /// DECISIVE incoming source's display name when one exists (the existing
    /// Layer-3 attribution — someone used the frame heavily before you), else
    /// nil (your own / ambient). NOT a claim of invention — attribution only
    /// sees iMessage. The "what you got from people" lens over this frame.
    public let source: String?
    /// SPREAD-TO: the exposure-gated recipients who picked this FRAME up from you
    /// (you used it in a chat they're in, before their first use), sorted by
    /// firstUse asc. Empty if none. Retained for compatibility with old frame
    /// displays; the current graph is driven by `SpreadProfile`.
    public let spreadTo: [Recipient]
    /// USERS: the FULL roster of distinct non-you people who used this FRAME at
    /// least once — the frame's whole social footprint, beyond the decisive
    /// `source`/`spreadTo` traders. Reuses `Recipient`, but here `count` = how
    /// many of THIS person's messages matched the frame and `firstUse` = their
    /// earliest match. Sorted by `count` desc (tie-break: firstUse asc). Empty
    /// until the attribution pass runs. Powers the Social-Graph light-up's
    /// NEUTRAL glow for users who aren't a decisive source/adopter.
    public let users: [Recipient]

    /// One fill of the varying slot, with how many times you used it there.
    public struct Fill: Sendable, Equatable {
        public let fill: String
        public let count: Int
        public init(fill: String, count: Int) { self.fill = fill; self.count = count }
    }

    public init(frame: String, count: Int, topFills: [Fill], examples: [String],
                source: String?, spreadTo: [Recipient] = [], users: [Recipient] = []) {
        self.id = frame
        self.frame = frame
        self.count = count
        self.topFills = topFills
        self.examples = examples
        self.source = source
        self.spreadTo = spreadTo
        self.users = users
    }

    /// Return a copy with the transmission lenses + user roster attached (source
    /// recomputed + spreadTo recipients), keeping fills/examples intact.
    public func withTransmission(source: String?, spreadTo: [Recipient],
                                 users: [Recipient] = []) -> SnowcloneTemplate {
        SnowcloneTemplate(frame: frame, count: count, topFills: topFills,
                          examples: examples, source: source, spreadTo: spreadTo,
                          users: users)
    }
}

// MARK: - (A) ANOMALOUS WORDS

public extension VernacularAnalyzer {

    /// Tunables for the anomalous-word + snowclone-template pass. Mirrors the
    /// validated `/tmp/anom` + `/tmp/wide` constants.
    struct AnomalyOptions: Sendable {
        // ── anomalous words ──
        /// A token must be SENT ≥ this many times to be considered.
        public var minCount: Int
        /// A token shorter than this (in letters) is dropped (kills "u"/"ur"
        /// and 2-char noise; the prototype used ≥3).
        public var minLength: Int
        /// A token whose baseline frequency rank is ≤ this is COMMON English and
        /// is dropped — only tokens ranked beyond it (or absent from the 30k
        /// baseline entirely) are candidates. Matches the validated `/tmp/anom` +
        /// `/tmp/ambient` prototypes' 7000.
        public var rarityRankGate: Int
        /// Rarity rank assigned to a token ABSENT from the baseline (treated as
        /// maximally rare). The prototype used 99999.
        public var absentRank: Int
        /// SPARSE-DATA FALLBACK ONLY (2026-06-03 Codex upgrade #1): the old fixed
        /// "used by ≥ N distinct people" ambient cutoff was OVERFIT to one corpus
        /// size (under-filters small corpora, over-filters big friend-groups). The
        /// ambient/ubiquity test is now the two-signal `AmbientRegisterModel`
        /// (weighted log-odds w/ informative Dirichlet prior × person-DF — see
        /// `isAmbientRegister`). This cutoff is RETAINED only as the fallback when
        /// the population is too thin to compute a stable log-odds (`<
        /// logOddsMinActiveContacts` active contacts, or empty population counts):
        /// then a token used by ≥ this many distinct people (≥`ambientMinPerPerson`
        /// each) is treated as ambient.
        public var ambientPeopleCutoff: Int
        /// A person must use a token in ≥ this many messages to count toward its
        /// ambient ubiquity (excludes one-off echoes); also the person-DF "uses"
        /// floor in the new two-signal gate.
        public var ambientMinPerPerson: Int

        // ── AMBIENT REGISTER: two-signal gate (Codex upgrade #1, corpus-robust) ──
        /// Fraction of ACTIVE contacts (≥`activeContactMinMessages` msgs) who use a
        /// token (≥`ambientMinPerPerson`×) at or above which the token is "widely
        /// shared" — the HIGH-person-DF half of the ambient test. Volume-adjusted
        /// by construction: DF counts each contact ONCE regardless of their volume,
        /// so a hyper-active contact can't dominate. A token is AMBIENT only if it
        /// ALSO fails the log-odds test (everyone says it AND it's not distinctively
        /// yours). Calibrated so the shorthand class (ur/rn/idk/bruh/lol — used by a
        /// large fraction of contacts) clears it while selective slang does not need
        /// to.
        public var personDFHighThreshold: Double
        /// Weighted log-odds z-score at or below which a token is "NOT distinctively
        /// the user's" — the LOW-log-odds half of the ambient test. A token is
        /// AMBIENT iff person-DF is high AND its `userLogOdds` z ≤ this. Selective
        /// slang the user over-uses (rizz/glaze/cone/sheesh/blud/npc) has a HIGH
        /// positive z (over-represented in their own speech) and is KEPT even when
        /// person-DF is also high. Calibrated against the validated set.
        public var logOddsLowThreshold: Double
        /// Informative-Dirichlet prior mass α0 (Monroe-Colaresi-Quinn 2008). The
        /// per-token prior is α_w = α0 · (corpus_count_w / corpus_total) — the
        /// corpus-wide unigram distribution scaled to α0 total mass. Larger α0 =
        /// stronger shrinkage of sparse counts toward the corpus prior (more
        /// conservative z-scores). 1000 is a standard mid value for chat-sized data.
        public var logOddsPriorMass: Double
        /// A contact needs ≥ this many sent messages (in the scanned corpus) to be
        /// an ACTIVE contact — the denominator of person-DF (so a contact who sent
        /// 3 texts total doesn't dilute the "fraction of people who say it").
        public var activeContactMinMessages: Int
        /// Minimum # of active contacts (the population) required to TRUST the
        /// two-signal gate; below this the population is too thin for a stable
        /// log-odds and we fall back to `ambientPeopleCutoff`.
        public var logOddsMinActiveContacts: Int
        /// How many top anomalous words to return.
        ///
        /// NOTE (2026-06-03 quality fix): the SHIPPING discovery no longer ranks
        /// by anomaly score and truncates at `topK` — it admits the TOP
        /// `wordCandidateTopK` rare/non-ambient/non-name tokens by RAW USAGE
        /// COUNT (so genuinely-distinctive LOW-count slang — cone ×64, glaze ×68,
        /// crashout, yap — survives instead of ranking below a score cutoff). The
        /// list is DISPLAYED count-ordered. `topK` is retained only as the cap on
        /// the count-ordered result (defaulted high enough to admit the whole
        /// candidate pool); kept as a tunable for callers / tests.
        public var topK: Int
        /// Cap on the JUDGE-ABLE word-candidate union (TIER COUNT ∪ TIER RARITY,
        /// below). Sized to the AI judge's per-pass budget (`maxWordBatch`≈200) so
        /// the optional `judgeWords` pass can clean the WHOLE pool. The kept items
        /// are DISPLAYED count-ordered (the order the user asked for).
        ///
        /// WHY A UNION, NOT TOP-N-BY-COUNT (measured on the real corpus, 2026-06-03):
        /// "anomaly = RARITY", so admission must be rarity-aware. By RAW COUNT the
        /// flagship slang ranks glaze #76 · cone #83 · rizz #126, but the genuinely
        /// LOW-count slang ranks yap #340 (×29) · crashout #2017 (×7) · mog #2135
        /// (×7) in a ~2700-token filtered pool whose top is dominated by HIGH-count
        /// proper-nouns/literals (zipcar/hedrick/stanford/palo/origami…). A count
        /// cap alone CANNOT reach the ×7-class slang without admitting ~2000 tokens.
        /// So the candidate set is the DEDUP UNION of two tiers — count gets the
        /// high-use slang in, RARITY gets the rare-but-low-use slang in — and the
        /// LLM judge throws out the names/brands/foreign/typos that rarity alone
        /// can't. No-model path keeps the whole union (Phase 1 accepts some noise).
        public var wordCandidateTopK: Int
        /// TIER COUNT size: top this-many survivors by RAW USAGE COUNT (keeps the
        /// high-use slang — cone/glaze/rizz/sheesh/boi/chalked/blud).
        public var wordTierCountTopN: Int
        /// TIER RARITY size: top this-many survivors by RARITY — baseline rank DESC
        /// (rarest first); absent-from-baseline tokens (all tied at `absentRank`)
        /// break ties by COUNT desc so the most-used NOVEL tokens beat one-off typos.
        /// Keeps the rare-but-low-use slang (yap/crashout/mog/goated/huzz/npc/opp…)
        /// that the count tier never reaches.
        public var wordTierRarityTopN: Int

        // ── SEMANTIC TRIAGE of the rare tail (Codex upgrade #2, context embeddings) ──
        /// CANDIDATE-LAKE count floor: a token must be sent ≥ this many times to
        /// enter the embedding-triage lake (lower than `minCount` so the ultra-rare
        /// slang — crashout ×7, mog ×7 — qualifies, but ≥3 so there is CONTEXT to
        /// embed and one-off typos are excluded). The lake is the full rare /
        /// non-ambient / non-name / non-contraction set with NO top-N cap.
        public var lakeMinCount: Int
        /// Hard cap on the candidate-lake size handed to the (Phase-2, gated)
        /// embedding triage, so the background embed pass stays bounded. The lake
        /// is ranked by RARITY then count before truncation (measured best: the
        /// absent-from-baseline slang sorts to the front; count-desc was worse —
        /// it front-loads high-count non-slang). SIZING (measured on the real
        /// corpus, uncapped lake ≈ 5470): the named targets sit at lake-rank
        /// opp #69 · goated #139 · npc #194 · huzz #377 · crashout #648 · mog #698,
        /// and **yap #2945** (yap is ranked-rare #20441, not absent, so it sorts
        /// behind the ~1278 absent tokens). 3000 covers ALL named targets incl.
        /// yap; ≈ `lakeMaxCandidates × triageMaxOccurrences` short on-device embeds
        /// (~24k) in a one-time gated background pass. Lower it on constrained
        /// machines (≈800 still gets 6/7 — everything but yap).
        public var lakeMaxCandidates: Int
        /// Max occurrences embedded per token (perf cap): take up to this many
        /// context windows around the token's occurrences and average them.
        public var triageMaxOccurrences: Int
        /// Context-window half-width: ±this many tokens around the (masked) target.
        public var triageWindowRadius: Int
        /// Number of slang CENTROIDS the confirmed-slang seed windows are k-means'd
        /// into (npc/opp/goated/huzz/yap are NOT one semantic neighborhood — a
        /// single average smears them). Deterministic k-means.
        public var triageCentroids: Int
        /// Admit a lake candidate iff its FINAL triage score (max-cosine to the
        /// slang centroids, + spread/co-occurrence boost, − typo/name penalty) is
        /// ≥ this. Calibrated so the named rare slang clears it and a rare NON-slang
        /// word ("spawned") does not.
        public var triageAdmitScore: Double
        /// Cap on how many top-scoring lake candidates the triage admits into the
        /// universe (alongside the count/rarity admits), so a borderline threshold
        /// can't flood the universe.
        public var triageMaxAdmit: Int

        // ── snowclone templates (DISCOVERED) ──
        /// CONSERVATIVE-tier count floor: a frame must match ≥ this many of your
        /// sent messages to surface in the offline `templates`. Lower than the
        /// broad floor so a genuinely-distinctive low-volume frame ("_ -coded"
        /// ×7) survives offline.
        public var templateMinCount: Int
        /// BROAD-pool count floor (the `/tmp/frames` `total >= 12` gate). A
        /// candidate must match ≥ this many sent messages to enter the AI-judge
        /// pool.
        public var snowcloneBroadMinCount: Int
        /// Productivity gate (the `/tmp/frames` `fills.count >= 6`): a frame's
        /// "_" slot must take ≥ this many DISTINCT fills (drops fixed phrases /
        /// near-constant-fill idioms — they are not productive snowclones).
        public var snowcloneMinFills: Int
        /// How many top fills to keep per frame.
        public var templateTopFills: Int
        /// Only collect example messages no longer than this (chars) so the
        /// card shows a tight, readable line (prototype used ≤70).
        public var templateMaxExampleLen: Int
        /// Cap on the published conservative `templates` (sorted by count).
        public var templateTopK: Int
        /// Cap on the BROAD frame-candidate pool handed to the AI judge.
        public var frameCandidateTopK: Int

        // ── SENSE-AWARE near-miss recovery (Codex upgrade #3, (e) Stage 1) ──
        /// A USER token must be sent ≥ this many times to be a NEAR-MISS sense
        /// candidate — a frequent surface dropped by the surface-level gates
        /// (common-in-English / ambient) whose sense split might be RECOVERED
        /// (e.g. the address sense of a kinship/honorific word). Higher than
        /// `minCount` so only well-populated surfaces (enough occurrences to
        /// cluster reliably) are considered.
        public var senseNearMissMinCount: Int
        /// Cap on the near-miss candidate pool (the most-frequent dropped USER
        /// tokens), so the occurrence-index + induction stay bounded.
        public var senseNearMissTopK: Int

        public init(
            minCount: Int = 5,
            minLength: Int = 3,
            rarityRankGate: Int = 7000,
            absentRank: Int = 99_999,
            ambientPeopleCutoff: Int = 25,
            ambientMinPerPerson: Int = 2,
            personDFHighThreshold: Double = 0.15,
            logOddsLowThreshold: Double = 50.0,
            logOddsPriorMass: Double = 1000.0,
            activeContactMinMessages: Int = 30,
            logOddsMinActiveContacts: Int = 8,
            topK: Int = 200,
            wordCandidateTopK: Int = 200,
            wordTierCountTopN: Int = 100,
            wordTierRarityTopN: Int = 100,
            lakeMinCount: Int = 3,
            lakeMaxCandidates: Int = 3000,
            triageMaxOccurrences: Int = 8,
            triageWindowRadius: Int = 10,
            triageCentroids: Int = 5,
            triageAdmitScore: Double = 0.55,
            triageMaxAdmit: Int = 60,
            templateMinCount: Int = 5,
            snowcloneBroadMinCount: Int = 12,
            snowcloneMinFills: Int = 6,
            templateTopFills: Int = 5,
            templateMaxExampleLen: Int = 70,
            templateTopK: Int = 40,
            frameCandidateTopK: Int = 120,
            senseNearMissMinCount: Int = 30,
            senseNearMissTopK: Int = 400
        ) {
            self.minCount = minCount
            self.minLength = minLength
            self.rarityRankGate = rarityRankGate
            self.absentRank = absentRank
            self.ambientPeopleCutoff = ambientPeopleCutoff
            self.ambientMinPerPerson = ambientMinPerPerson
            self.personDFHighThreshold = personDFHighThreshold
            self.logOddsLowThreshold = logOddsLowThreshold
            self.logOddsPriorMass = logOddsPriorMass
            self.activeContactMinMessages = activeContactMinMessages
            self.logOddsMinActiveContacts = logOddsMinActiveContacts
            self.topK = topK
            self.wordCandidateTopK = wordCandidateTopK
            self.wordTierCountTopN = wordTierCountTopN
            self.wordTierRarityTopN = wordTierRarityTopN
            self.lakeMinCount = lakeMinCount
            self.lakeMaxCandidates = lakeMaxCandidates
            self.triageMaxOccurrences = triageMaxOccurrences
            self.triageWindowRadius = triageWindowRadius
            self.triageCentroids = triageCentroids
            self.triageAdmitScore = triageAdmitScore
            self.triageMaxAdmit = triageMaxAdmit
            self.templateMinCount = templateMinCount
            self.snowcloneBroadMinCount = snowcloneBroadMinCount
            self.snowcloneMinFills = snowcloneMinFills
            self.templateTopFills = templateTopFills
            self.templateMaxExampleLen = templateMaxExampleLen
            self.templateTopK = templateTopK
            self.frameCandidateTopK = frameCandidateTopK
            self.senseNearMissMinCount = senseNearMissMinCount
            self.senseNearMissTopK = senseNearMissTopK
        }

        public static let `default` = AnomalyOptions()
    }

    /// CORPUS-ROBUST AMBIENT-REGISTER MODEL (Codex upgrade #1, 2026-06-03).
    ///
    /// Replaces the fixed `ambientPeopleCutoff = 25` "used by ≥N people" gate
    /// (overfit to one corpus size). Precomputed ONCE from `[VernacularMessage]`;
    /// both the words pass and the snowclone-frame anchor filter query it, so the
    /// ambient test can never drift between them. Two signals per token:
    ///
    ///  1. `userLogOdds(token)` — the WEIGHTED LOG-ODDS-RATIO WITH INFORMATIVE
    ///     DIRICHLET PRIOR (Monroe, Colaresi & Quinn 2008, "Fightin' Words"):
    ///     group A = the USER's sent tokens, group B = the POPULATION (all OTHER
    ///     senders' tokens); the informative prior is α_w = α0 · (corpus_count_w /
    ///     corpus_total) — the corpus-wide unigram distribution scaled to α0 total
    ///     mass. Returns the z-SCORED log-odds δ̂/√σ². Large positive ⇒ the token
    ///     is over-represented in the user's OWN speech (distinctive to them). The
    ///     Dirichlet prior is what makes this stable on rare tokens (raw ratios /
    ///     pointwise-KL blow up at low counts; the prior shrinks them properly).
    ///  2. `personDF(token)` — fraction of ACTIVE contacts (≥ a message floor)
    ///     who use the token (≥`ambientMinPerPerson`×). Volume-adjusted by
    ///     construction: each contact counts ONCE regardless of their own volume,
    ///     so one hyper-active contact can't dominate.
    ///
    /// DECISION: AMBIENT (filter out) iff person-DF is HIGH **and** userLogOdds is
    /// LOW (everyone says it, and it's not distinctively you — ur/rn/idk/bruh/lol).
    /// KEEP if userLogOdds is high (over-represented in YOUR speech) even when
    /// person-DF is also high. NOTE: this is the AMBIENT/ubiquity gate ONLY — it
    /// does NOT remove topic/name/brand tokens (a user's hobby word like "origami"
    /// IS user-distinctive, so log-odds correctly KEEPS it; the LLM judge drops it).
    ///
    /// `Sendable` value type. PURE — a deterministic function of the corpus.
    struct AmbientRegisterModel: Sendable {
        /// User (group A) token counts and total.
        let userCount: [String: Int]
        let userTotal: Double
        /// Population (group B = all NOT-from-me) token counts and total.
        let popCount: [String: Int]
        let popTotal: Double
        /// Corpus-wide token counts (user + population) and total — the prior.
        let corpusCount: [String: Int]
        let corpusTotal: Double
        /// token → # ACTIVE contacts who use it ≥`ambientMinPerPerson`× (the DF
        /// numerator). Keyed only for tokens at least one active contact uses.
        let contactUseCount: [String: Int]
        /// # ACTIVE contacts (the DF denominator).
        let activeContacts: Int
        /// Prior mass α0 carried so `userLogOdds` is self-contained.
        let priorMass: Double

        /// person-DF: fraction of active contacts who use `token`. 0 if no active
        /// contacts (the fallback path handles the thin-population case).
        func personDF(_ token: String) -> Double {
            guard activeContacts > 0 else { return 0 }
            return Double(contactUseCount[token] ?? 0) / Double(activeContacts)
        }

        /// Weighted log-odds z-score of `token` for the USER vs the population,
        /// with the informative Dirichlet prior. Monroe-Colaresi-Quinn eq. (16)/(22):
        ///   δ̂ = log( (y_A+α)/(n_A+α0−y_A−α) ) − log( (y_B+α)/(n_B+α0−y_B−α) )
        ///   σ² ≈ 1/(y_A+α) + 1/(y_B+α)
        ///   ζ  = δ̂ / √σ²
        /// where α = α0·(corpus_count/corpus_total). Returns 0 when the population
        /// is empty (caller treats that as the sparse fallback).
        func userLogOdds(_ token: String) -> Double {
            guard popTotal > 0, corpusTotal > 0 else { return 0 }
            let a0 = priorMass
            let alpha = a0 * Double(corpusCount[token] ?? 0) / corpusTotal
            let yA = Double(userCount[token] ?? 0)
            let yB = Double(popCount[token] ?? 0)
            // Guard the denominators (huge in practice; clamp to ε for safety).
            let aNum = yA + alpha
            let aDen = max(userTotal + a0 - yA - alpha, 1e-9)
            let bNum = yB + alpha
            let bDen = max(popTotal + a0 - yB - alpha, 1e-9)
            let delta = log(aNum / aDen) - log(bNum / bDen)
            let variance = 1.0 / max(aNum, 1e-9) + 1.0 / max(bNum, 1e-9)
            return delta / variance.squareRoot()
        }

        /// AMBIENT verdict for `token` under `options`. Uses the two-signal gate
        /// when the population is thick enough (`activeContacts >=
        /// logOddsMinActiveContacts` and a non-empty population); otherwise FALLS
        /// BACK to the legacy `ambientPeopleCutoff` count (sparse-data diagnostic).
        func isAmbientRegister(_ token: String, options: AnomalyOptions) -> Bool {
            // Sparse-data fallback: thin population → the log-odds is untrustworthy.
            guard activeContacts >= options.logOddsMinActiveContacts, popTotal > 0 else {
                return (contactUseCount[token] ?? 0) >= options.ambientPeopleCutoff
            }
            return personDF(token) >= options.personDFHighThreshold
                && userLogOdds(token) <= options.logOddsLowThreshold
        }

        /// Build the model from the scanned corpus. `unknownLabel` is the
        /// not-in-contacts sentinel: its messages COUNT toward the population
        /// (group B) + corpus prior (it is real other-people speech), but it is NOT
        /// one identifiable contact, so it is EXCLUDED from the person-DF
        /// numerator/denominator (DF is "fraction of your CONTACTS"). PURE.
        static func build(messages: [VernacularMessage], options: AnomalyOptions) -> AmbientRegisterModel {
            var userCount: [String: Int] = [:]
            var popCount: [String: Int] = [:]
            var corpusCount: [String: Int] = [:]
            var userTotal = 0.0, popTotal = 0.0, corpusTotal = 0.0
            // per-contact message count (to find ACTIVE contacts) + per-contact
            // per-token message presence (≥ minPerPerson uses → DF).
            var contactMsgs: [String: Int] = [:]
            var contactTokenUse: [String: [String: Int]] = [:]
            let unknown = VernacularAnalyzer.unknownLabel
            for m in messages {
                if m.fromMe {
                    for w in m.words { userCount[w, default: 0] += 1; corpusCount[w, default: 0] += 1 }
                    userTotal += Double(m.words.count); corpusTotal += Double(m.words.count)
                } else {
                    for w in m.words { popCount[w, default: 0] += 1; corpusCount[w, default: 0] += 1 }
                    popTotal += Double(m.words.count); corpusTotal += Double(m.words.count)
                    if m.who != unknown {
                        contactMsgs[m.who, default: 0] += 1
                        for w in m.wordSet { contactTokenUse[m.who, default: [:]][w, default: 0] += 1 }
                    }
                }
            }
            // ACTIVE contacts = real contacts with ≥ the message floor.
            let active = contactMsgs.filter { $0.value >= options.activeContactMinMessages }.map { $0.key }
            let activeSet = Set(active)
            // DF numerator: # active contacts using a token ≥ minPerPerson×.
            var contactUseCount: [String: Int] = [:]
            for who in activeSet {
                guard let uses = contactTokenUse[who] else { continue }
                for (tok, n) in uses where n >= options.ambientMinPerPerson {
                    contactUseCount[tok, default: 0] += 1
                }
            }
            return AmbientRegisterModel(
                userCount: userCount, userTotal: userTotal,
                popCount: popCount, popTotal: popTotal,
                corpusCount: corpusCount, corpusTotal: corpusTotal,
                contactUseCount: contactUseCount, activeContacts: activeSet.count,
                priorMass: options.logOddsPriorMass)
        }
    }

    /// RESIDUAL acronym / topic-jargon drop — the OTHER noise class the
    /// coordinator asked to keep alongside the contact-name filter. The derived
    /// ambient-register cutoff already removes ubiquitous shorthand AND the
    /// high-ubiquity proper nouns/topics ("ucla"·70, "ai"·78 — both well above
    /// the cutoff). This compact set catches what slips through with LOW
    /// ubiquity: tech/topic ACRONYMS (a person can use "ai"/"ml"/"gpt" a lot in
    /// one DM thread without it being group-wide). It is deliberately small —
    /// acronyms + obvious topic tokens, NOT an open proper-noun gazetteer (we do
    /// NOT try to enumerate every dorm/brand; the ambient filter + name filter do
    /// the bulk, and a future semantic/AI pass can replace this). Reuses
    /// `EmphaticDetector.acronymStoplist` (lol/idk/usa/nyc/…) and extends it.
    /// Lowercased, per-build constant (NOT user data).
    static let acronymTopicStoplist: Set<String> = [
        // AI / CS topic acronyms + jargon (the coordinator's "ai the topic")
        "ai", "ml", "nlp", "llm", "llms", "gpt", "gpu", "cpu", "api", "apis",
        "sql", "ui", "ux", "ci", "cd", "sde", "swe", "pm", "ee", "cs", "ece",
        "url", "urls", "http", "https", "json", "csv", "pdf", "html", "css",
        // school/term acronyms a single thread can over-use
        "ta", "tas", "gpa", "ucla", "ucsd", "usc", "uci", "ucsb", "ucb",
    ]

    /// The lowercased contact first/last-name fragments (≥2 chars) to exclude —
    /// the SAME set both the words pass and the frames pass build. Shared so the
    /// name filter can never drift between the two.
    static func contactNameTokens(_ contacts: ResolvedContacts) -> Set<String> {
        var nameTokens = Set<String>()
        for c in contacts.allContacts {
            for part in c.displayName.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }) {
                let low = part.lowercased()
                if low.count >= 2 { nameTokens.insert(low) }
            }
        }
        return nameTokens
    }

    /// True iff `tok` is a contact-NAME form — the leak class a raw rarity scan
    /// admits (the frames pass got this fix; the words pass did not until now).
    /// Catches, against the contact `nameTokens`:
    ///   • the exact name ("venkat", "noah", "beck"),
    ///   • the POSSESSIVE ("venkat's"/"venkat’s" → `depossess` → "venkat"),
    ///   • the bare-PLURAL / bare-possessive s-suffix ("venkats"/"noahs"/"masons"
    ///     → strip a trailing "s" → an exact name token; guarded so it only fires
    ///     when the STEM is a real name, never on slang that merely ends in "s"),
    ///   • a NICKNAME prefix/truncation ("keesh" ⊂ "keeshant"): the candidate
    ///     (length ≥ 4) is a prefix of a name token of length ≥ 5. Length-gated so
    ///     it can't swallow short slang.
    /// PURE — a deterministic predicate over the precomputed `nameTokens`.
    static func isNameForm(_ tok: String, nameTokens: Set<String>) -> Bool {
        if nameTokens.contains(tok) { return true }
        // possessive ('s / ’s) → stem is a name.
        let bare = depossess(tok)
        if bare != tok, nameTokens.contains(bare) { return true }
        // bare s-suffix (no apostrophe) → stem is a name. Only when the stem is a
        // genuine contact name (so "yaps"→"yap" is kept; "venkats"→"venkat" drops).
        if tok.count >= 4, tok.hasSuffix("s") {
            let stem = String(tok.dropLast())
            if nameTokens.contains(stem) { return true }
        }
        // nickname prefix/truncation: candidate (≥4) is a prefix of a longer
        // name — EXEMPTING real dictionary words. True truncation nicknames
        // (venk/keesh) aren't baseline English; without the exemption a
        // contact surname can censor a real word corpus-wide (measured:
        // "gang" — Venkat's signature word, 448 uses — was silently excluded
        // for every subject because one contact is named "…Gangle").
        if tok.count >= 4, !nicknameExemptionBaseline.isKnown(tok) {
            for n in nameTokens where n.count >= 5 && n.count > tok.count {
                if n.hasPrefix(tok) { return true }
            }
        }
        return false
    }

    /// Build the user's ANOMALOUS WORDS — single tokens they send ≥`minCount`×
    /// that are RARE in general English (rank > `rarityRankGate`, or absent from
    /// the baseline), EXCLUDING (1) apostrophe-contractions, (2) the DERIVED
    /// ambient texting register (tokens ≥`ambientPeopleCutoff` distinct people
    /// use ≥2× across the whole corpus — ubiquitous shorthand like ur/rn/idk/
    /// tho/bruh/hella/cuz), (3) contact-name fragments (incl. possessive / bare-
    /// plural / nickname-prefix forms via `isNameForm`), and (4) residual tech/
    /// topic acronyms (ai/ml/gpt). The surviving candidates are admitted as the
    /// DEDUP UNION of a top-by-COUNT tier and a top-by-RARITY tier (so the rare-
    /// but-low-use slang the count tier can't reach is still admitted), capped at
    /// the AI judge budget; the optional `judgeWords` pass then drops the names/
    /// brands/foreign/typos rarity alone can't. DISPLAYED count-ordered ("ordering
    /// by times used"). Ports `/tmp/anom` + the `/tmp/ambient` register filter. PURE.
    ///
    /// `VocabItem.count` is times-sent; `peopleCount` is how many distinct OTHER
    /// people also use it (spread, for context).
    static func discoverAnomalousWords(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        options: AnomalyOptions = .default
    ) -> [VocabItem] {
        let rarity = RarityRanker(baseline: baseline)

        // Contact-name fragments to exclude (first + last, lowercased, ≥2 chars) —
        // the SAME set the frames pass uses. Matched via `isNameForm` so the
        // possessive / bare-plural / nickname-prefix leak classes are caught too.
        let nameTokens = contactNameTokens(contacts)

        // Count occurrences in SENT text (times-sent).
        var sentCount: [String: Int] = [:]
        for m in messages where m.fromMe {
            for w in m.words { sentCount[w, default: 0] += 1 }
        }

        // rarity rank for a token: its baseline rank, or `absentRank` if absent.
        func rank(_ tok: String) -> Int { rarity.rankOf[tok] ?? options.absentRank }

        // STEP 1 — cheap candidate gate over YOUR sent vocabulary (everything
        // EXCEPT the derived ambient cutoff, which needs the corpus-wide pass).
        // Matches `/tmp/ambient`'s `cand = your non-dict tokens used ≥6×`, plus
        // the contraction / name / acronym / noise drops.
        func isCheapCandidate(_ tok: String) -> Bool {
            guard tok.count >= options.minLength,
                  (sentCount[tok] ?? 0) >= options.minCount else { return false }
            // Drop ANY apostrophe-bearing token (i'm/it's/don't/it'll/y'all…):
            // genuine slang ("rizz"/"npc"/"glaze") never contains an apostrophe,
            // and our tokenizer keeps the apostrophe INSIDE the token while the
            // baseline split it — so every contraction/possessive otherwise reads
            // as "absent from the 30k". Blanket apostrophe drop (curly ’→' first).
            if tok.contains("'") || tok.contains("\u{2019}") { return false }
            // Also drop apostrophe-LESS contraction spellings (im/dont/youre/its).
            if isContraction(tok) { return false }
            // RESIDUAL acronym / topic-jargon drop (the OTHER noise class) — the
            // derived ambient cutoff handles ubiquitous shorthand + high-ubiquity
            // proper nouns; this catches low-ubiquity tech/topic acronyms ("ai"/
            // "ml"/"gpt"). NO hardcoded shorthand list (that's now derived).
            if acronymTopicStoplist.contains(tok) { return false }
            // Drop contact-name fragments — NOW including possessive ("venkat's"),
            // bare-plural ("venkats"/"noahs"), and nickname-prefix ("keesh" ⊂
            // "keeshant") forms (the leak the frames pass already plugged via
            // `depossess`; ported here). Kills venkats/noahs/keesh that slipped
            // the old exact-match-only filter.
            if isNameForm(tok, nameTokens: nameTokens) { return false }
            // Drop expressive noise (a single repeated letter / laugh-mash).
            if isSingleRepeatedLetterTok(tok) || isLaughMashTok(tok) { return false }
            // RARITY gate: rare in general English (rank beyond the gate, or
            // absent → assigned `absentRank`, far beyond it).
            return rank(tok) > options.rarityRankGate
        }
        let candidateSet = Set(sentCount.keys.filter(isCheapCandidate))
        guard !candidateSet.isEmpty else { return [] }

        // STEP 2 — CORPUS-ROBUST AMBIENT REGISTER (Codex upgrade #1). The old
        // fixed "used by ≥25 distinct people" cutoff was overfit to one corpus
        // size. Build the two-signal `AmbientRegisterModel` ONCE (weighted
        // log-odds w/ informative Dirichlet prior × person-DF) over the whole
        // corpus; the SAME model also feeds the snowclone-frame anchor filter.
        let ambient = AmbientRegisterModel.build(messages: messages, options: options)
        // displayed `peopleCount` spread = # ACTIVE other contacts using it.
        func othersCount(_ tok: String) -> Int { ambient.contactUseCount[tok] ?? 0 }

        // STEP 3 — keep only the DISTINCTIVE tail. A candidate is dropped iff it is
        // AMBIENT texting register: HIGH person-DF AND LOW user-log-odds (everyone
        // says it AND it's not distinctively yours — ur/rn/idk/bruh/lol). Selective
        // slang the user over-uses (rizz/glaze/cone/sheesh/blud/npc) keeps a high
        // positive log-odds z and survives even when person-DF is high. Falls back
        // to `ambientPeopleCutoff` when the population is too thin (handled inside).
        let kept = candidateSet.filter { !ambient.isAmbientRegister($0, options: options) }
        guard !kept.isEmpty else { return [] }

        // STEP 4 — RARITY-AWARE TWO-TIER admission (2026-06-03 v2). "Anomaly =
        // RARITY", so a top-N-by-COUNT cap is the wrong primitive: it CANNOT
        // reach the ×7-class slang (crashout #2017, mog #2135 by count) without
        // admitting ~2000 noise tokens. Instead the judge-able candidate set is
        // the DEDUP UNION of two tiers over the `kept` survivors (already rare +
        // non-ambient + non-name + non-contraction + length≥`minLength` + count
        // ≥`minCount`):
        //   • TIER COUNT  — top `wordTierCountTopN` by RAW USAGE COUNT (the
        //     high-use slang: cone/glaze/rizz/sheesh/boi/chalked/blud).
        //   • TIER RARITY — top `wordTierRarityTopN` by RARITY: baseline rank DESC
        //     (rarest first), and for absent-from-baseline tokens (all tied at
        //     `absentRank`) break ties by COUNT desc so the most-used NOVEL tokens
        //     beat one-off typos (the rare-but-low-use slang: yap/crashout/mog/
        //     goated/huzz/npc/opp…).
        // The union is capped at `wordCandidateTopK` (the AI judge's budget):
        // TIER COUNT first, then fill from TIER RARITY. The optional `judgeWords`
        // pass then drops the names/brands/foreign/typos rarity alone can't —
        // making the feature genuinely anomaly-first (rarity gets the candidate
        // in, the LLM throws out what shouldn't be). No-model path keeps the whole
        // union (Phase 1 accepts some noise). DISPLAY is count-ordered (unchanged —
        // "ordering by times used"). Deterministic throughout.
        let keptArr = Array(kept)
        // TIER COUNT: count desc, token asc.
        let byCount = keptArr.sorted {
            if (sentCount[$0] ?? 0) != (sentCount[$1] ?? 0) {
                return (sentCount[$0] ?? 0) > (sentCount[$1] ?? 0)
            }
            return $0 < $1
        }
        // TIER RARITY: rank desc (rarest first); ties (incl. all absent tokens at
        // absentRank) by count desc, then token asc.
        let byRarity = keptArr.sorted {
            let ra = rank($0), rb = rank($1)
            if ra != rb { return ra > rb }
            if (sentCount[$0] ?? 0) != (sentCount[$1] ?? 0) {
                return (sentCount[$0] ?? 0) > (sentCount[$1] ?? 0)
            }
            return $0 < $1
        }
        // UNION (dedup), TIER COUNT first then TIER RARITY, capped at the budget.
        var unionTokens: [String] = []
        var seen = Set<String>()
        func admit(_ toks: ArraySlice<String>) {
            for t in toks where !seen.contains(t) {
                guard unionTokens.count < options.wordCandidateTopK else { return }
                seen.insert(t); unionTokens.append(t)
            }
        }
        admit(byCount.prefix(options.wordTierCountTopN))
        admit(byRarity.prefix(options.wordTierRarityTopN))

        // DISPLAY count-ordered (count desc, token asc) — unchanged.
        var items: [VocabItem] = unionTokens.map { tok in
            VocabItem(token: tok, count: sentCount[tok] ?? 0, peopleCount: othersCount(tok))
        }
        items.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.token < $1.token
        }
        return Array(items.prefix(options.topK))
    }

    // MARK: - SEMANTIC TRIAGE of the rare tail (Codex upgrade #2)

    /// One token in the embedding-triage CANDIDATE LAKE — a rare / non-ambient /
    /// non-name / non-contraction token sent ≥`lakeMinCount`× that the count/rarity
    /// two-tier admission CANNOT reach (it's statistically indistinguishable from a
    /// rare typo by frequency alone). `rank` is its baseline rarity rank. Sendable.
    struct LakeCandidate: Sendable, Equatable {
        public let token: String
        public let count: Int
        public let rank: Int
        public init(token: String, count: Int, rank: Int) {
            self.token = token; self.count = count; self.rank = rank
        }
    }

    /// The inputs the embedding triage needs, all computed PURELY from the corpus:
    ///   • `lake` — the rare tail to rescue (NOT already admitted), capped.
    ///   • `seed` — the CONFIRMED slang tokens (the count/rarity admits) whose
    ///     context windows define the slang centroids.
    ///   • `windows` — masked ±W-token context windows per token (lake ∪ seed),
    ///     the target token removed (we want the CONTEXT signature, not the token).
    /// `Sendable` so it crosses the off-main boundary to the gated embedder.
    struct SemanticTriageInputs: Sendable {
        public let lake: [LakeCandidate]
        public let seed: [String]
        /// token → its context windows (each a space-joined string, target masked).
        public let windows: [String: [String]]
    }

    /// Build the embedding-triage inputs. `confirmedSlang` is the set already
    /// admitted by `discoverAnomalousWords` (count/rarity) — those become the SEED
    /// centroids and are EXCLUDED from the lake (we only need to rescue what the
    /// stats missed). The lake reuses the EXACT SAME cheap filters + the SAME
    /// `AmbientRegisterModel` ambient gate as `discoverAnomalousWords`, only with a
    /// lower count floor (`lakeMinCount`) and NO top-N cap. PURE.
    static func semanticTriageInputs(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        confirmedSlang: Set<String>,
        options: AnomalyOptions = .default
    ) -> SemanticTriageInputs {
        let rarity = RarityRanker(baseline: baseline)
        func rank(_ tok: String) -> Int { rarity.rankOf[tok] ?? options.absentRank }
        let nameTokens = contactNameTokens(contacts)

        var sentCount: [String: Int] = [:]
        for m in messages where m.fromMe { for w in m.words { sentCount[w, default: 0] += 1 } }

        // SAME cheap gate as discoverAnomalousWords, but count ≥ lakeMinCount.
        func isLakeCandidate(_ tok: String) -> Bool {
            guard tok.count >= options.minLength,
                  (sentCount[tok] ?? 0) >= options.lakeMinCount else { return false }
            if tok.contains("'") || tok.contains("\u{2019}") { return false }
            if isContraction(tok) { return false }
            if acronymTopicStoplist.contains(tok) { return false }
            if isNameForm(tok, nameTokens: nameTokens) { return false }
            if isSingleRepeatedLetterTok(tok) || isLaughMashTok(tok) { return false }
            return rank(tok) > options.rarityRankGate
        }
        let cands = Set(sentCount.keys.filter(isLakeCandidate))
        // SAME ambient gate (the Codex #1 two-signal model).
        let ambient = AmbientRegisterModel.build(messages: messages, options: options)
        let nonAmbient = cands.filter { !ambient.isAmbientRegister($0, options: options) }

        // LAKE = non-ambient survivors NOT already confirmed; rank by rarity then
        // count (rarest, most-used first), cap at lakeMaxCandidates.
        var lakeToks = nonAmbient.subtracting(confirmedSlang).sorted {
            let ra = rank($0), rb = rank($1)
            if ra != rb { return ra > rb }
            if (sentCount[$0] ?? 0) != (sentCount[$1] ?? 0) { return (sentCount[$0] ?? 0) > (sentCount[$1] ?? 0) }
            return $0 < $1
        }
        if lakeToks.count > options.lakeMaxCandidates { lakeToks = Array(lakeToks.prefix(options.lakeMaxCandidates)) }
        let lake = lakeToks.map { LakeCandidate(token: $0, count: sentCount[$0] ?? 0, rank: rank($0)) }
        // SEED = confirmed slang that actually appears in the user's sent text.
        let seed = confirmedSlang.filter { (sentCount[$0] ?? 0) >= 1 }.sorted()

        // CONTEXT WINDOWS for lake ∪ seed (masked target, ±radius), capped per token.
        let wanted = Set(lake.map { $0.token }).union(seed)
        let windows = contextWindows(for: wanted, messages: messages, options: options)
        return SemanticTriageInputs(lake: lake, seed: seed, windows: windows)
    }

    /// Extract up to `triageMaxOccurrences` masked context windows per wanted
    /// token from the user's SENT messages: a ±`triageWindowRadius`-token window
    /// around each occurrence with the TARGET TOKEN REMOVED (the context signature,
    /// not the token). Windows are space-joined lowercased word tokens. PURE.
    static func contextWindows(
        for wanted: Set<String>,
        messages: [VernacularMessage],
        options: AnomalyOptions = .default
    ) -> [String: [String]] {
        guard !wanted.isEmpty else { return [:] }
        var out: [String: [String]] = [:]
        let radius = options.triageWindowRadius
        let cap = options.triageMaxOccurrences
        var saturated = Set<String>()
        for m in messages where m.fromMe {
            if saturated.count == wanted.count { break }
            let toks = m.words
            guard !toks.isEmpty else { continue }
            // only scan messages that contain at least one wanted token.
            guard !m.wordSet.isDisjoint(with: wanted) else { continue }
            for i in toks.indices {
                let tok = toks[i]
                guard wanted.contains(tok), !saturated.contains(tok),
                      (out[tok]?.count ?? 0) < cap else { continue }
                let lo = max(0, i - radius), hi = min(toks.count - 1, i + radius)
                // window with the target at i MASKED OUT (removed).
                var window: [String] = []
                window.reserveCapacity(hi - lo)
                var j = lo
                while j <= hi { if j != i { window.append(toks[j]) }; j += 1 }
                guard !window.isEmpty else { continue }
                out[tok, default: []].append(window.joined(separator: " "))
                if (out[tok]?.count ?? 0) >= cap { saturated.insert(tok) }
            }
        }
        return out
    }

    /// One admitted rare-tail token + its triage score (for logging / tests).
    struct TriageAdmit: Sendable, Equatable {
        public let token: String
        public let score: Double
        public let count: Int
        public init(token: String, score: Double, count: Int) {
            self.token = token; self.score = score; self.count = count
        }
    }

    /// PURE semantic-triage scorer (embeddings INJECTED via `vectorFor`, so it is
    /// fully unit-testable with stubbed vectors). Steps 4-5 of the Codex plan:
    ///   • k-means the SEED (confirmed-slang) context vectors into `triageCentroids`
    ///     centroids (deterministic: sorted-seed init, fixed iterations) — NOT one
    ///     average (npc/opp/goated/huzz are not one neighborhood).
    ///   • score each LAKE candidate = MAX cosine to the centroids, BOOSTED by
    ///     multi-chat/time spread + co-occurrence with confirmed vernacular,
    ///     PENALIZED by typo/name likelihood (edit-distance-1 to a common baseline
    ///     word, or a name-form).
    ///   • admit the top `triageMaxAdmit` candidates scoring ≥ `triageAdmitScore`.
    /// `vectorFor` returns the (already mean-pooled, L2-normalizable) context vector
    /// for a token, or nil if it couldn't be embedded (too few windows / no assets).
    /// `spread`/`coUse` are optional 0…1 boosts (default 0). Deterministic.
    static func semanticTriageAdmit(
        lake: [LakeCandidate],
        seed: [String],
        vectorFor: (String) -> [Float]?,
        commonWords: Set<String>,
        nameTokens: Set<String>,
        spread: [String: Double] = [:],
        coUse: [String: Double] = [:],
        options: AnomalyOptions = .default
    ) -> [TriageAdmit] {
        // seed vectors (L2-normalized).
        let seedVecs = seed.compactMap { vectorFor($0).map(l2normalize) }.filter { !$0.isEmpty }
        guard seedVecs.count >= 1 else { return [] }
        let k = min(options.triageCentroids, seedVecs.count)
        let centroids = kmeans(seedVecs, k: k, iterations: 12)
        guard !centroids.isEmpty else { return [] }

        var admits: [TriageAdmit] = []
        for c in lake {
            guard let raw = vectorFor(c.token) else { continue }
            let v = l2normalize(raw)
            guard !v.isEmpty else { continue }
            // max cosine to any slang centroid (vectors are unit → dot = cosine).
            var maxCos = -1.0
            for ctr in centroids { maxCos = max(maxCos, dot(v, ctr)) }
            // boosts (capped) + typo/name penalty.
            let boost = 0.10 * (spread[c.token] ?? 0) + 0.10 * (coUse[c.token] ?? 0)
            var penalty = 0.0
            if isNameForm(c.token, nameTokens: nameTokens) { penalty += 0.5 }
            if isEditDistance1ToCommon(c.token, common: commonWords) { penalty += 0.15 }
            let score = maxCos + boost - penalty
            if score >= options.triageAdmitScore {
                admits.append(TriageAdmit(token: c.token, score: score, count: c.count))
            }
        }
        admits.sort { $0.score != $1.score ? $0.score > $1.score : $0.token < $1.token }
        return Array(admits.prefix(options.triageMaxAdmit))
    }

    // MARK: triage math primitives (pure)

    /// The set of COMMON baseline words (rank < `gate`) used by the triage's
    /// typo penalty: a rare lake token within edit-distance 1 of a COMMON word is
    /// a likely typo of it. (Not "any of the 30k baseline" — most of those are
    /// themselves rare; we only want frequent words a typo would target.) PURE.
    static func commonBaselineWords(baseline: LinguisticBaseline, gate: Int = 7000) -> Set<String> {
        let ranker = RarityRanker(baseline: baseline)
        var out = Set<String>()
        for (tok, r) in ranker.rankOf where r < gate { out.insert(tok) }
        return out
    }

    static func l2normalize(_ v: [Float]) -> [Float] {
        var s: Float = 0; for x in v { s += x * x }
        let n = s.squareRoot()
        guard n > 1e-9 else { return [] }
        return v.map { $0 / n }
    }
    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return -1 }
        var s: Float = 0; for i in a.indices { s += a[i] * b[i] }
        return Double(s)
    }
    /// Deterministic k-means over unit vectors (cosine = dot). Init = `k` evenly-
    /// spaced points of the (caller-sorted) input for reproducibility; `iterations`
    /// Lloyd steps; empty clusters keep their prior center. Returns L2-normalized
    /// centroids.
    static func kmeans(_ points: [[Float]], k: Int, iterations: Int) -> [[Float]] {
        guard k >= 1, points.count >= 1 else { return [] }
        let dim = points[0].count
        guard dim > 0 else { return [] }
        let kk = min(k, points.count)
        // deterministic init: evenly-spaced picks.
        var centroids: [[Float]] = (0..<kk).map { points[$0 * points.count / kk] }
        for _ in 0..<iterations {
            var sums = Array(repeating: Array(repeating: Float(0), count: dim), count: kk)
            var counts = Array(repeating: 0, count: kk)
            for p in points {
                var best = 0; var bestCos = -2.0
                for (ci, c) in centroids.enumerated() {
                    let d = dot(p, c)
                    if d > bestCos { bestCos = d; best = ci }
                }
                for d in 0..<dim { sums[best][d] += p[d] }
                counts[best] += 1
            }
            for ci in 0..<kk where counts[ci] > 0 {
                let inv = 1.0 / Float(counts[ci])
                centroids[ci] = l2normalize(sums[ci].map { $0 * inv })
            }
        }
        return centroids.filter { !$0.isEmpty }
    }
    /// True iff `tok` is within Levenshtein distance 1 of some COMMON baseline word
    /// (a likely typo of a real word — "spawned"/"spwned"). Cheap: only checks
    /// deletions/substitutions/insertions implicitly via a length-bounded scan over
    /// the common set restricted to length ±1. PURE.
    static func isEditDistance1ToCommon(_ tok: String, common: Set<String>) -> Bool {
        if common.contains(tok) { return true }
        let a = Array(tok)
        guard a.count >= 3 else { return false }
        for w in common {
            let b = Array(w)
            if abs(b.count - a.count) > 1 { continue }
            if levenshteinAtMost1(a, b) { return true }
        }
        return false
    }
    /// Levenshtein ≤ 1 test (early-out), O(n). PURE.
    static func levenshteinAtMost1(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        let (s, t) = a.count <= b.count ? (a, b) : (b, a)
        if t.count - s.count > 1 { return false }
        if s.count == t.count {                       // one substitution
            var diff = 0
            for i in s.indices { if s[i] != t[i] { diff += 1; if diff > 1 { return false } } }
            return diff == 1
        }
        // one insertion (t is longer by 1): skip exactly one char of t.
        var i = 0, j = 0, skipped = false
        while i < s.count && j < t.count {
            if s[i] == t[j] { i += 1; j += 1 }
            else { if skipped { return false }; skipped = true; j += 1 }
        }
        return true
    }

    // MARK: contraction + noise primitives (shared with /tmp/anom logic)

    /// Normalize curly ’ → straight ' and remove every apostrophe.
    static func strippedApostrophes(_ tok: String) -> String {
        tok.replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// The apostrophe-STRIPPED stems of normal English contractions, so a
    /// token like "im"/"dont"/"youre"/"its" (which our tokenizer can produce
    /// with OR without the apostrophe) is recognized as a contraction and never
    /// surfaces as "slang". The baseline lacks apostrophe forms, so without this
    /// every contraction reads as "absent from the 30k" and leaks.
    static let contractionStems: Set<String> = [
        // be / pronoun + be
        "im", "youre", "hes", "shes", "its", "were", "theyre", "thats",
        "whats", "wheres", "whos", "hows", "heres", "theres", "lets",
        // have
        "ive", "youve", "weve", "theyve", "shouldve", "couldve", "wouldve",
        "mustve",
        // will / would
        "ill", "youll", "hell", "shell", "well", "theyll", "id", "youd", "hed",
        "shed", "wed", "theyd",
        // not (n't)
        "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt",
        "shouldnt", "isnt", "arent", "wasnt", "werent", "hasnt", "havent",
        "hadnt", "aint", "mustnt", "neednt", "maynt",
        // misc
        "yall", "gonna", "wanna", "gotta", "lemme", "gimme", "kinda", "sorta",
        "oclock", "yknow", "cmon", "dunno", "aint",
    ]

    /// True iff `tok` (after curly→straight normalization + apostrophe strip)
    /// is a normal English contraction — by being a known stem, OR by being an
    /// apostrophe-bearing form whose bare stem is a known stem. Drops i'm / it's
    /// / don't / didn't / y'all / shouldn't … in both apostrophe + bare spellings.
    static func isContraction(_ tok: String) -> Bool {
        let bare = strippedApostrophes(tok)
        // an apostrophe-bearing token whose stem is a contraction (i'm, it's),
        // OR a bare token that IS a contraction stem (im, its, dont).
        if contractionStems.contains(bare) { return true }
        // also: an apostrophe token whose bare stem differs (handles odd
        // spellings) — already covered by the bare check, kept explicit for
        // clarity / future stems.
        return false
    }

    /// A token that is one letter repeated (≥2 chars, all identical): "aaaa",
    /// "mmmm", "uuu". Expressive noise, not an anomaly. (Mirror of the private
    /// `isSingleRepeatedLetter` in VernacularSections, re-declared here so this
    /// file is self-contained / independently testable.)
    static func isSingleRepeatedLetterTok(_ tok: String) -> Bool {
        guard tok.count >= 2, let first = tok.first else { return false }
        return tok.allSatisfy { $0 == first }
    }

    /// A laugh-keyboard mash made only of {h,a,e} with ≥1 'h' and ≥1 'a'
    /// ("haha"/"hahaha"/"ahaha"/"hahah"). Expressive noise, not an anomaly.
    static func isLaughMashTok(_ tok: String) -> Bool {
        guard tok.count >= 3 else { return false }
        let allowed: Set<Character> = ["h", "a", "e"]
        guard tok.allSatisfy({ allowed.contains($0) }) else { return false }
        return tok.contains("h") && tok.contains("a")
    }
}

// MARK: - (B) SNOWCLONE TEMPLATES — DISCOVERED (not curated) + AI-JUDGED

/// One BROAD-pool frame candidate handed to the optional AI judge in Phase 2.
/// Carries everything the judge needs to decide "is this a snowclone?" AND
/// everything the view model needs to rebuild a `SnowcloneTemplate` for the
/// kept frames — so we never re-mine. `id == skeleton` (the mined skeleton,
/// e.g. "holy _" / "_ ahh"), keyed so the judge's verdict map merges back.
public struct FrameJudgeCandidate: Sendable, Equatable, Identifiable {
    /// The mined single-slot skeleton: tokens joined by spaces, exactly one is
    /// "_" (the varying slot). e.g. "holy _", "_ ahh", "the way _".
    public let skeleton: String
    /// The human display frame ("holy ___", "___ ahh", "___ -core").
    public let frame: String
    /// How many of YOUR sent messages match the frame.
    public let count: Int
    /// Top fills for the "_" slot, frequency desc (lowercased).
    public let topFills: [SnowcloneTemplate.Fill]
    /// 1-2 real example sent messages (newlines stripped, length-capped).
    public let examples: [String]
    public var id: String { skeleton }
    public init(skeleton: String, frame: String, count: Int,
                topFills: [SnowcloneTemplate.Fill], examples: [String]) {
        self.skeleton = skeleton
        self.frame = frame
        self.count = count
        self.topFills = topFills
        self.examples = examples
    }
}

/// Result of the discovery pass: the CONSERVATIVE no-AI subset (published as
/// `templates` in Phase 1 so no-model users see a reasonably clean set) plus
/// the BROAD candidate pool (kept for the Phase-2 AI judge). `Sendable` so it
/// crosses the off-main → main boundary.
public struct DiscoveredFrames: Sendable, Equatable {
    /// CONSERVATIVE subset — published in Phase 1 (offline). Each frame has
    /// ≥1 distinctive anchor; names/abbreviations/pure-grammar dropped.
    public let templates: [SnowcloneTemplate]
    /// BROAD pool — every statistically-real single-slot frame (names +
    /// ambient anchors removed) for the Phase-2 AI judge to keep/drop.
    public let frameCandidates: [FrameJudgeCandidate]
    public init(templates: [SnowcloneTemplate], frameCandidates: [FrameJudgeCandidate]) {
        self.templates = templates
        self.frameCandidates = frameCandidates
    }
}

public extension VernacularAnalyzer {

    /// One mined single-slot frame skeleton with its fills + examples. The
    /// `slotIndex` is where the "_" sits (0-based over the space-split
    /// skeleton). Internal to the discovery pass.
    private struct MinedFrame {
        let skeleton: String          // e.g. "holy _", "_ ahh", "the way _"
        let slotIndex: Int            // index of the "_" token in the skeleton
        var fills: [String: Int]
        var total: Int
        var examples: [String]
    }

    /// English vowels (y excluded — a disemvoweled clipping like "shld"/"wtv"
    /// has no a/e/i/o/u). Used to separate real morphemes from clippings.
    private static let frameVowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Strip a trailing possessive ('s / curly ’s) so "venkat's" is recognized
    /// as the contact first-name "venkat" (the name-possessive class the AI
    /// must NOT have to see — we drop it offline).
    static func depossess(_ token: String) -> String {
        for suffix in ["\u{2019}s", "'s"] where token.hasSuffix(suffix) {
            return String(token.dropLast(suffix.count))
        }
        return token
    }

    /// Build the snowclone frames by DISCOVERY (not a hardcoded catalog),
    /// returning BOTH the conservative offline `templates` and the broad
    /// candidate `frameCandidates` pool. Faithful port of `/tmp/frames`:
    ///
    ///  1. MINE — one pass over your sent messages; for every adjacent 2-gram
    ///     and 3-gram, emit each single-slot skeleton (one position → "_",
    ///     capturing the replaced token as the fill). Accumulate per-skeleton
    ///     {fills, total, ≤2 short example bodies}.
    ///  2. AMBIENT / NAME / PRODUCTIVITY filter — using cross-person token
    ///     ubiquity over ALL messages (you + every contact): a frame's anchor
    ///     tokens must not be a contact first-name (incl. possessive) nor
    ///     ambient shorthand (`rank >= rarityRankGate && ubiquity >= cutoff`).
    ///     Require `total >= 12 && fills.count >= 6`. This is the BROAD pool.
    ///  3. CONSERVATIVE subset — additionally require ≥1 DISTINCTIVE anchor
    ///     (a dict word ranked > 800, OR a non-dict non-ambient token that is
    ///     not a disemvoweled clipping: length ≥ 4 with a vowel). Published as
    ///     `templates` in Phase 1.
    ///
    /// The display `frame` formats suffixes specially: "_ core" → "___ -core",
    /// "_ coded" → "___ -coded"; otherwise "_" → "___" in place.
    ///
    /// `attribute` here is intentionally false for ALL conservative frames:
    /// per-frame attribution is the EXPENSIVE Layer-3 pass, so we defer it to
    /// the Phase-2 AI-kept set (`VernacularViewModel` computes it only for kept
    /// frames). Offline `templates` carry `source = nil`. PURE.
    static func discoverSnowcloneFrames(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        options: AnomalyOptions = .default
    ) -> DiscoveredFrames {
        let rarity = RarityRanker(baseline: baseline)
        func rank(_ tok: String) -> Int { rarity.rankOf[tok] ?? options.absentRank }

        // Contact first/last-name fragments (lowercased, ≥2 chars) — the SAME
        // name set + the SAME `isNameForm` predicate `discoverAnomalousWords`
        // uses, so the name filter can never drift between the two passes
        // (possessive / bare-plural / nickname-prefix all caught uniformly).
        let nameTokens = contactNameTokens(contacts)
        func isName(_ tok: String) -> Bool { isNameForm(tok, nameTokens: nameTokens) }

        // CORPUS-ROBUST AMBIENT REGISTER (Codex upgrade #1) — the SAME two-signal
        // model the words pass uses (weighted log-odds w/ Dirichlet prior ×
        // person-DF), so the ambient anchor test can never drift between the two
        // passes. Replaces the old fixed cross-person ubiquity ≥ cutoff count.
        let ambient = AmbientRegisterModel.build(messages: messages, options: options)
        func isAmbient(_ tok: String) -> Bool { ambient.isAmbientRegister(tok, options: options) }

        // MINE single-slot 2- and 3-gram skeletons over SENT messages.
        var frames: [String: MinedFrame] = [:]
        func emit(_ skeleton: String, slot: Int, fill: String, body: String) {
            var f = frames[skeleton] ?? MinedFrame(skeleton: skeleton, slotIndex: slot,
                                                   fills: [:], total: 0, examples: [])
            f.fills[fill, default: 0] += 1
            f.total += 1
            if f.examples.count < 2 {
                let one = body.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !one.isEmpty, one.count <= options.templateMaxExampleLen,
                   !f.examples.contains(one) {
                    f.examples.append(one)
                }
            }
            frames[skeleton] = f
        }
        for m in messages where m.fromMe {
            let t = m.words
            if t.count >= 2 {
                var i = 0
                while i <= t.count - 2 {
                    emit("_ \(t[i+1])", slot: 0, fill: t[i], body: m.body)
                    emit("\(t[i]) _", slot: 1, fill: t[i+1], body: m.body)
                    i += 1
                }
            }
            if t.count >= 3 {
                var i = 0
                while i <= t.count - 3 {
                    emit("_ \(t[i+1]) \(t[i+2])", slot: 0, fill: t[i], body: m.body)
                    emit("\(t[i]) _ \(t[i+2])", slot: 1, fill: t[i+1], body: m.body)
                    emit("\(t[i]) \(t[i+1]) _", slot: 2, fill: t[i+2], body: m.body)
                    i += 1
                }
            }
        }

        // ── anchor predicates (port of `/tmp/frames`) ──
        // An anchor is BAD (drops the whole frame) if it is a contact name
        // (incl. possessive) or RARE-but-ambient shorthand. The ambient test is
        // now the two-signal model (`isAmbient`), but it is applied ONLY to RARE
        // anchors (rank >= gate) — exactly as the old `rank >= gate && ubiquity`
        // structure did — so common grammatical anchors ("we"/"are"/"the" in
        // "we are ___") are NOT mis-flagged as ambient and the snowclone survives.
        // A DISTINCTIVE anchor is a dict word ranked > 800, OR a non-dict
        // non-ambient token that is not a disemvoweled clipping (length ≥ 4 with
        // ≥1 vowel — keeps "coded", drops "shld"/"wtv").
        func anchorBad(_ w: String) -> Bool {
            isName(w) || (rank(w) >= options.rarityRankGate && isAmbient(w))
        }
        func hasVowel(_ w: String) -> Bool { w.contains { Self.frameVowels.contains($0) } }
        func isDistinctive(_ w: String) -> Bool {
            if isName(w) { return false }
            let r = rank(w)
            if r < options.rarityRankGate { return r > 800 }
            if isAmbient(w) { return false }
            return w.count >= 4 && hasVowel(w)
        }

        var candidates: [FrameJudgeCandidate] = []      // BROAD pool
        var conservative: [SnowcloneTemplate] = []
        for (_, f) in frames {
            // Anchors = the non-"_" tokens of the skeleton.
            let anchors = f.skeleton.split(separator: " ").map(String.init).filter { $0 != "_" }
            // Productivity gate (broad pool floor) + no name/ambient anchor.
            guard f.fills.count >= options.snowcloneMinFills,
                  !anchors.contains(where: anchorBad) else { continue }

            let topFills = f.fills
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(options.templateTopFills)
                .map { SnowcloneTemplate.Fill(fill: $0.key, count: $0.value) }
            let display = displayFrame(skeleton: f.skeleton)

            // BROAD pool: total >= 12 (the broad floor).
            if f.total >= options.snowcloneBroadMinCount {
                candidates.append(FrameJudgeCandidate(
                    skeleton: f.skeleton, frame: display, count: f.total,
                    topFills: Array(topFills), examples: f.examples))
            }
            // CONSERVATIVE subset: total >= templateMinCount AND ≥1 distinctive
            // anchor. (A lower count floor than broad so genuinely-distinctive
            // low-volume frames like "_ -coded" survive offline.)
            if f.total >= options.templateMinCount, anchors.contains(where: isDistinctive) {
                conservative.append(SnowcloneTemplate(
                    frame: display, count: f.total, topFills: Array(topFills),
                    examples: f.examples, source: nil))
            }
        }
        // most-used first; deterministic ties.
        conservative.sort { $0.count != $1.count ? $0.count > $1.count : $0.frame < $1.frame }
        candidates.sort { $0.count != $1.count ? $0.count > $1.count : $0.skeleton < $1.skeleton }
        return DiscoveredFrames(
            templates: Array(conservative.prefix(options.templateTopK)),
            frameCandidates: Array(candidates.prefix(options.frameCandidateTopK)))
    }

    /// Render a mined skeleton as the display frame: "_" → "___" in place,
    /// except the derivational suffixes "core"/"coded" render hyphenated
    /// ("_ core" → "___ -core", "_ coded" → "___ -coded"). Literal tokens are
    /// kept verbatim.
    static func displayFrame(skeleton: String) -> String {
        let toks = skeleton.split(separator: " ").map(String.init)
        // Special-case the trailing derivational suffix.
        if toks.count == 2, toks[0] == "_" {
            if toks[1] == "core" { return "___ -core" }
            if toks[1] == "coded" { return "___ -coded" }
        }
        return toks.map { $0 == "_" ? "___" : $0 }.joined(separator: " ")
    }

    /// Convert a mined skeleton into the `frameFind`/`matchFrame` pattern + the
    /// fill slot index. Split on space: "_" → "_" slot, every other token is a
    /// literal that must match exactly. `fillerIdx` is the captured-slot index
    /// of the single "_" (always 0 for single-slot frames — there is exactly
    /// one capture). `initialOnly` is false (frames match anywhere). Used by
    /// the view model to rebuild a `SnowcloneTemplate` + attribute the kept
    /// frames in Phase 2. PURE.
    static func framePattern(skeleton: String) -> (pattern: [String], fillerIdx: Int) {
        let toks = skeleton.split(separator: " ").map(String.init)
        // Single-slot frame → exactly one "_" capture → fillerIdx 0.
        return (toks, 0)
    }

    /// Build a `SnowcloneTemplate` for a single AI-KEPT frame candidate,
    /// computing the DECISIVE incoming attribution over the frame-match
    /// predicate (the expensive Layer-3 pass — run ONLY for kept frames). The
    /// fills + examples are reused from the candidate (already mined). PURE.
    ///
    /// SUPERSEDED (2026-06-03 alignment): the Phase-2 path now re-runs the
    /// profile-backed spread overlay now handles GOT-FROM and SPREAD-TO
    /// consistently for published terms. Kept as a single-frame attribution
    /// helper for older snowclone diagnostics (still PURE + valid).
    static func templateForKeptFrame(
        _ cand: FrameJudgeCandidate,
        messages: [VernacularMessage],
        analyzerOptions: Options = .default
    ) -> SnowcloneTemplate {
        let (pattern, _) = framePattern(skeleton: cand.skeleton)
        let source = attributeFrameSource(
            messages: messages, options: analyzerOptions,
            matches: { frameFind($0.words, pattern, initialOnly: false) != nil })
        return SnowcloneTemplate(frame: cand.frame, count: cand.count,
                                 topFills: cand.topFills, examples: cand.examples,
                                 source: source)
    }

    /// DECISIVE incoming source over an arbitrary message predicate — the
    /// prototype `/tmp/wide`'s `attribute(_ pred:)`. Returns the display name of
    /// the contact who satisfied `matches` heavily BEFORE your first match, IFF
    /// it is unambiguous: ≥ `attributionMinBefore` uses strictly before your
    /// first, first use ≥ `attributionMinDays` before yours, and dominant
    /// (before-count ≥ `attributionDominanceRatio` × the runner-up, OR sole
    /// qualifier). Else nil (ambient / your own). Unknown senders are excluded.
    /// PURE.
    static func attributeFrameSource(
        messages: [VernacularMessage],
        options: Options = .default,
        matches: (VernacularMessage) -> Bool
    ) -> String? {
        let day = 86_400.0
        // your first matching use.
        var yourFirst = Double.greatestFiniteMagnitude
        for m in messages where m.fromMe && matches(m) {
            yourFirst = min(yourFirst, m.date)
        }
        guard yourFirst < .greatestFiniteMagnitude else { return nil }
        // per-contact: first matching use + count strictly before your first.
        var firstUse: [String: Double] = [:]
        var beforeCount: [String: Int] = [:]
        for m in messages where !m.fromMe && m.who != Self.unknownLabel && matches(m) {
            firstUse[m.who] = min(firstUse[m.who] ?? .greatestFiniteMagnitude, m.date)
            if m.date < yourFirst { beforeCount[m.who, default: 0] += 1 }
        }
        // qualifiers: used it ≥minBefore× before you AND first ≥minDays earlier.
        let quals = beforeCount.keys.filter {
            (beforeCount[$0] ?? 0) >= options.attributionMinBefore
                && (firstUse[$0] ?? yourFirst) <= yourFirst - options.attributionMinDays * day
        }
        guard let top = quals.max(by: { (beforeCount[$0] ?? 0) < (beforeCount[$1] ?? 0) })
        else { return nil }
        // dominance: ≥ratio× the runner-up, OR sole qualifier.
        let runnerUp = beforeCount.keys.filter { $0 != top }.map { beforeCount[$0] ?? 0 }.max() ?? 0
        guard runnerUp == 0
                || Double(beforeCount[top] ?? 0) >= options.attributionDominanceRatio * Double(runnerUp)
        else { return nil }
        return top
    }

    // MARK: frame matcher (port of /tmp/wide's `mf` / `frameFind`)

    /// Match `pattern` against the token slice starting at `ti`, collecting
    /// captured fills in order. "_" captures exactly one token; "*" captures a
    /// 1-3 token chunk (joined by spaces); any other entry is a literal token
    /// that must match exactly. Returns the captured fills, or nil on no match.
    /// Recursive backtracking, faithful to the prototype's `mf`.
    static func matchFrame(_ tokens: [String], _ pattern: [String],
                           _ ti: Int, _ pi: Int, _ fills: inout [String]) -> Bool {
        if pi == pattern.count { return true }
        let p = pattern[pi]
        if p == "_" {
            guard ti < tokens.count else { return false }
            fills.append(tokens[ti])
            if matchFrame(tokens, pattern, ti + 1, pi + 1, &fills) { return true }
            fills.removeLast()
            return false
        }
        if p == "*" {
            var len = 1
            while len <= 3 {
                if ti + len <= tokens.count {
                    let chunk = tokens[ti..<ti + len].joined(separator: " ")
                    fills.append(chunk)
                    if matchFrame(tokens, pattern, ti + len, pi + 1, &fills) { return true }
                    fills.removeLast()
                }
                len += 1
            }
            return false
        }
        guard ti < tokens.count, tokens[ti] == p else { return false }
        return matchFrame(tokens, pattern, ti + 1, pi + 1, &fills)
    }

    /// Find the frame anywhere in `tokens` (or only at index 0 if `initialOnly`),
    /// returning the captured fills of the first match. Port of `frameFind`.
    static func frameFind(_ tokens: [String], _ pattern: [String], initialOnly: Bool)
        -> [String]? {
        if initialOnly {
            var f: [String] = []
            return matchFrame(tokens, pattern, 0, 0, &f) ? f : nil
        }
        var start = 0
        while start <= tokens.count {
            var f: [String] = []
            if matchFrame(tokens, pattern, start, 0, &f) { return f }
            start += 1
        }
        return nil
    }
}
