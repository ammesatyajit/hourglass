//
//  VernacularConfig.swift
//  Hourglass - Unified Vernacular Profile
//
//  All tunable Phase-1 profile knobs live here. The engine is deterministic for
//  a fixed message corpus, baseline, contact set, and config.
//

import Foundation

/// Weights for the unified Phase-1 phrase/template scorer.
///
/// The scorer normalizes every feature into `[0, 1]` and returns the weighted
/// average of the features applicable to that item type:
///
///     score = sum(weight_i * normalizedFeature_i) / sum(weight_i)
///
/// The current principled profile uses `worldDistinctiveness`, `role`,
/// `dispersion`, `echo`, and `burstResistance` as the primary signals. The
/// older feature weights remain as weak/tunable compatibility knobs.
///
/// Setting a weight to `0` removes that feature from ranking without changing
/// candidate generation.
public struct VernacularWeights: Sendable, Equatable {
    /// Monotonic boost for longer n-grams/templates.
    public var length: Double
    /// Monroe/Fightin-Words social-world-vs-reference distinctiveness.
    public var worldDistinctiveness: Double
    /// Subject-vs-interlocutor role. Positive means subject-led idiolect.
    public var role: Double
    /// Stable spread over time/chats/people.
    public var dispersion: Double
    /// Contact echo for shared slang.
    public var echo: Double
    /// Resistance to one-day / one-month topical bursts.
    public var burstResistance: Double
    /// Contact-document-frequency IDF. Higher means fewer active contacts use it.
    public var peopleIDF: Double
    /// User-vs-received overuse.
    public var selfUsage: Double
    /// Over-representation versus the bundled normal-English baseline.
    public var rarity: Double
    /// Recent usage rise over older usage.
    public var recency: Double
    /// Resistance to one-day / one-sender blasting.
    public var spamResistance: Double
    /// Collocation glue for n-grams (`NPMI`, n >= 2).
    public var glue: Double
    /// Word-only boost when a unigram strongly anchors a distinctive adjacent
    /// bigram. Kept modest so existing word/circle rankings stay stable.
    public var collocation: Double
    /// Bounded Apple-embedding semantic-shift boost. High means the subject's
    /// usage contexts diverge from the ordinary/literal sense, or are unusually
    /// tight around one in-group context.
    public var semanticShift: Double
    /// Legacy POS/lexical style diagnostic. The principled model no longer uses
    /// POS as an exclusion gate; topic suppression comes from dispersion/burst.
    public var style: Double
    /// Template-only: distinct slot fills per template.
    public var productivity: Double
    /// Template-only: how distinctive the fixed anchors are.
    public var anchorDistinctiveness: Double
    /// Optional embedding-derived distinctiveness/dedup signal. Default-off.
    public var embedding: Double

    public init(
        length: Double = 0.06,
        worldDistinctiveness: Double = 0.28,
        role: Double = 0.24,
        dispersion: Double = 0.20,
        echo: Double = 0.16,
        burstResistance: Double = 0.18,
        peopleIDF: Double = 0.18,
        selfUsage: Double = 0.22,
        rarity: Double = 0.18,
        recency: Double = 0.04,
        spamResistance: Double = 0.10,
        glue: Double = 0.12,
        collocation: Double = 0.18,
        semanticShift: Double = 0.30,
        style: Double = 0.0,
        productivity: Double = 0.16,
        anchorDistinctiveness: Double = 0.14,
        embedding: Double = 0.0
    ) {
        self.length = length
        self.worldDistinctiveness = worldDistinctiveness
        self.role = role
        self.dispersion = dispersion
        self.echo = echo
        self.burstResistance = burstResistance
        self.peopleIDF = peopleIDF
        self.selfUsage = selfUsage
        self.rarity = rarity
        self.recency = recency
        self.spamResistance = spamResistance
        self.glue = glue
        self.collocation = collocation
        self.semanticShift = semanticShift
        self.style = style
        self.productivity = productivity
        self.anchorDistinctiveness = anchorDistinctiveness
        self.embedding = embedding
    }

    public static let `default` = VernacularWeights()
}

/// Unified Phase-1 profile configuration.
///
/// `VernacularConfig.default` is an enabled, explicit config for tests and
/// callers. Runtime loader/view-model paths use `fromUserDefaults()`, which is
/// enabled by default and can be disabled with `vernacular.profile.enabled`.
public struct VernacularConfig: Sendable, Equatable {
    /// Runtime gate for the new additive profile. The legacy UI path remains live
    /// while this is false.
    public var isEnabled: Bool
    /// Default-off extraction cache. Independent of `vernacular.profile.enabled`;
    /// when false, the legacy n-gram/template passes run unchanged.
    public var useTokenizedCorpus: Bool
    /// Global message-count floor for retaining cached gram/pattern hashes. Must
    /// stay strictly looser than `minUserMessages` so no subject candidate drops.
    public var tokenizedCorpusGlobalFloor: Int
    /// Hard cap on distinct cached n-gram hashes, admitted by global count desc.
    public var tokenizedCorpusMaxDistinctNgrams: Int
    /// Spread-layer POS/context sense split. Default on: isolates sentence-initial
    /// vocative nouns like "brother" from literal/referential uses.
    public var posSenseEnabled: Bool
    /// Minimum corpus-wide sentence-initial uses before a word is considered for
    /// the bounded NLTagger confirmation pass.
    public var posSenseMinInitial: Int
    /// Minimum uses by the device owner for a vocative sense to enter the spread
    /// universe.
    public var posSenseMinUserUses: Int
    /// Maximum sentence-initial candidates sent through NLTagger.
    public var posSenseMaxCandidates: Int
    /// Minimum confirmed-vocative/all-word-occurrence message share.
    public var posSenseMinVocativeRate: Double

    // MARK: - output caps

    /// Longest phrase n-gram to consider. Default includes 1, 2, 3, and 4-grams.
    public var maxNgramLength: Int
    /// Maximum ranked single-word surfaces returned in `VernacularProfile`.
    public var topWordCount: Int
    /// Maximum ranked shared/in-group slang surfaces returned in `VernacularProfile`.
    public var topCircleSlangCount: Int
    /// Maximum ranked phrase surfaces returned in `VernacularProfile`.
    public var topPhraseCount: Int
    /// Maximum ranked repurposed normal-English word surfaces returned.
    public var reclaimedWordCount: Int
    /// Opt-in LLM cleanup for `reclaimedWords`. Default off: the normal
    /// profile stays deterministic and model-free.
    public var enableReclaimedLLMClassifier: Bool
    /// Maximum ranked generalized templates returned in `VernacularProfile`.
    public var topTemplateCount: Int

    // MARK: - bounded extraction

    /// Minimum number of sent messages containing a phrase/template candidate.
    public var minUserMessages: Int
    /// Low-count candidates must appear on at least this many distinct user days.
    public var minDistinctDaysForLowCount: Int
    /// Count below which `minDistinctDaysForLowCount` applies.
    public var lowCountDayGate: Int
    /// Max numeric n-gram hashes carried from pass A into exact pass B.
    public var maxNgramHashCandidates: Int
    /// Max exact n-gram surfaces retained in pass B.
    public var maxExactNgramCandidates: Int
    /// Max numeric template hashes carried from pass A into exact pass B.
    public var maxTemplateHashCandidates: Int
    /// Max exact template surfaces retained in pass B.
    public var maxExactTemplateCandidates: Int
    /// Contacts need this many received messages to count in active-contact IDF.
    public var activeContactMinMessages: Int
    /// A contact must use a surface in at least this many messages to count in DF.
    public var minContactUsesForDocumentFrequency: Int
    /// Minimum visible subject messages before a profile is considered meaningful.
    public var minSubjectMessagesForProfile: Int

    // MARK: - scoring curves

    /// Exponent in `lengthFeature = (n / maxN)^lengthExponent`.
    public var lengthExponent: Double
    /// Positive-log scale for self-use normalization.
    public var selfUsageLogScale: Double
    /// Positive-log scale for rarity/over-baseline normalization.
    public var rarityLogScale: Double
    /// Positive-log scale for recency-rise normalization.
    public var recencyLogScale: Double
    /// Minimum raw over-baseline value for weak candidates to remain eligible.
    public var minOverBaseline: Double
    /// Minimum NPMI for weak n-gram expansions to remain eligible.
    public var minGlue: Double
    /// Count scale used when turning a word's strongest exact bigram NPMI into
    /// a collocation feature. Higher values make low-count bigrams contribute less.
    public var collocationCountScale: Double
    /// Informative Dirichlet prior mass: `alpha_t = logOddsPriorMass * p_ref(t)`.
    public var logOddsPriorMass: Double
    /// Pseudo reference corpus size used with the bundled unigram probabilities.
    public var referencePseudoCount: Double
    /// Positive effect-size scale for normalizing world log-odds into `[0, 1]`.
    public var zScoreScale: Double
    /// Logit scale for turning `z_role` into a subject-role feature.
    public var roleLogitScale: Double
    /// Gentle low-count shrinkage for the world log-odds effect:
    /// `effect *= count / (count + worldEffectCountScale)`.
    public var worldEffectCountScale: Double
    /// Multiplier strength for de-weighting near-universal texting-register
    /// forms (`tmrw`, `ppl`, `rn`, `alr`, `u`/`ur` class). This is a shrinkage
    /// prior, not a hard stoplist.
    public var textingRegisterPenaltyStrength: Double
    /// Semantic-shift can rescue repurposed-sense words by acting as an alternate
    /// ranking anchor: `max(worldAnchor, semanticShift * semanticShiftAnchorStrength)`.
    public var semanticShiftAnchorStrength: Double
    /// Positive scale for normalizing cosine-distance sense shift into `[0, 1]`.
    public var semanticShiftScale: Double
    /// Weight given to deterministic context-tightness inside the semantic-shift
    /// feature. Useful for terms used in one tight in-group sense.
    public var semanticContextTightnessWeight: Double
    /// Strength of the main WORDS collocation damp for low-spread/noisy anchors.
    public var mainWordCollocationDampStrength: Double
    /// Reclaimed-word candidate/ranking gates.
    public var reclaimedMinUses: Int
    public var reclaimedMinWorldEff: Double
    public var reclaimedMinBaselineProbability: Double
    /// Primary reclaimed-word rank signal: how much the subject is a top
    /// per-capita user among contacts who also use the known-English word.
    public var reclaimedPercentileWeight: Double
    /// Soft target percentile. A term at or above this percentile gets the full
    /// percentile feature; lower terms are scaled down continuously.
    public var reclaimedKeepPercentile: Double
    /// Per-user uses required before a contact participates in the percentile
    /// distribution.
    public var reclaimedMinPerUserUses: Int
    /// Below this many qualifying users, shrink percentile toward neutral 0.5.
    public var reclaimedMinUsersForPercentile: Int
    /// Static NLEmbedding sense-distance floor for admitting real-English words
    /// missing from the movie-English baseline.
    public var reclaimedSenseAdmitFloor: Double
    public var reclaimedWeightOver: Double
    public var reclaimedWeightColloc: Double
    public var reclaimedWeightRole: Double
    public var reclaimedWeightDisp: Double
    public var reclaimedWeightSense: Double
    /// Reclaimed-only: optional log-scaled times-said boost. 0 = off.
    public var reclaimedWeightFreq: Double
    /// Reclaimed-only: reward terms used STEADILY over time (low single-month
    /// burst share) vs recent/bursty topic spikes. 0 = off.
    public var reclaimedWeightSteady: Double
    /// Fold/demote pass on kept reclaimed words (operator feedback): two kept
    /// words that ride each other ("holy"+"bang") fold into one bigram entry;
    /// a word riding a literal compound ("jet lag") is dropped.
    public var reclaimedFoldEnabled: Bool
    /// Fold when a kept partner is adjacent in at least this share of windows.
    public var reclaimedFoldShare: Double
    /// MUTUAL-partner pairs fold on window CO-OCCURRENCE at this share —
    /// "holy"/"bang" ride the same messages without being adjacent.
    public var reclaimedFoldCooccurShare: Double
    /// At compound share ≥ 0.8 the word survives ONLY with a keep margin at
    /// least this emphatic (cone +0.42 lives; jet-"lag" +0.32 dies).
    public var reclaimedCompoundHardProtectMargin: Double
    /// Drop a word whose NON-candidate partner is adjacent in at least this
    /// share of windows (a literal compound, not a reclaimed sense).
    public var reclaimedCompoundDropShare: Double
    /// Weight of the slang-share boost on idiolect phrases — phrases built
    /// from discovered slang ("are we deadass") outrank logistics scaffolding.
    public var phraseSlangWeight: Double
    /// Mine "signature frames" — emphatic-caps frames ("___ is NOT ___",
    /// "I MAY ___") and vocative frames ("brother ___") — ranked above the
    /// auto-mined templates. Subject=You only (one bounded pass).
    public var signatureFramesEnabled: Bool
    /// Minimum occurrences for a signature frame to surface.
    public var signatureFrameMinCount: Int
    /// Contact-mode statistical rescue (set by `scaledForSubject`, not
    /// directly): contacts' context margins run systematically lower (their
    /// trusted-slang sets are smaller, weakening the window scorer), so a
    /// near-miss verdict with STRONG statistics — high role-skew AND the full
    /// world-effect bar — is kept. Measured: sheesh@DavidKim (margin -0.01,
    /// roleSkew 0.31, worldEff 3.19) vs his topic junk (gym/fun roleSkew ≤0.1).
    public var reclaimedContactRescueEnabled: Bool
    /// Rescue floor: the context margin must be at least this.
    public var reclaimedRescueMarginFloor: Double
    /// Rescue requires the subject's role-skew at or above this.
    public var reclaimedRescueRoleSkew: Double
    /// Slang-affinity boost (replaces the old hardcoded slang-cue word list):
    /// cosine similarity of the candidate word to the centroid of the
    /// SUBJECT'S OWN discovered slang, passed through a soft ramp — no boost
    /// below `floor`, full `boost` by `ceil`. Per-subject and self-updating.
    public var reclaimedSlangAffinityFloor: Double
    public var reclaimedSlangAffinityCeil: Double
    public var reclaimedSlangAffinityBoost: Double
    /// Default-on usage-context filter for reclaimed words. The statistical
    /// ranker generates candidates; this classifier removes topic/neutral uses.
    public var enableReclaimedContextFilter: Bool
    /// Max ranked reclaimed candidates inspected by the context filter.
    public var reclaimedContextCandidateLimit: Int
    /// Max subject usage windows scored per reclaimed candidate.
    public var reclaimedContextMaxWindowsPerCandidate: Int
    /// Token radius retained around a reclaimed occurrence.
    public var reclaimedContextWindowRadius: Int
    /// KEEP when `slangRate - topicRate` reaches this margin.
    public var reclaimedContextKeepThreshold: Double
    /// REMOVE when topic rate reaches this threshold and keep margin is weak.
    public var reclaimedContextTopicThreshold: Double
    /// How much static category-prototype proximity contributes to topic rate.
    public var reclaimedContextCategoryWeight: Double
    /// Low-topic collocation boost for in-joke anchors such as `cone`.
    public var reclaimedContextCollocationBoost: Double
    /// Future opt-in hook for target-masked NLContextualEmbedding refinement on
    /// uncertain reclaimed candidates. Default off; not used in the fast path.
    public var enableReclaimedContextualEmbedding: Bool
    /// Legacy bounded POS/style diagnostic cap. Retained for runtime compatibility;
    /// the current scorer does not run NLTagger or gate on this value.
    public var maxStyleScoredPhraseCandidates: Int
    /// Legacy POS/style threshold. Retained for compatibility; no longer gates
    /// candidates.
    public var minPhraseStyleScore: Double
    /// Legacy POS/topic penalty strength. The current topic diagnostic is based
    /// on `z_world`, dispersion, echo, and burst.
    public var topicPenaltyStrength: Double
    /// Legacy POS/topic threshold. Retained for compatibility; no longer gates
    /// candidates.
    public var maxTopicScoreWithoutStyle: Double

    // MARK: - spam damping

    /// Per-day cap used for effective user-message counts.
    public var dailyUserCap: Int
    /// Drop low-day-spread candidates above this max-single-day share.
    public var maxSingleDayShare: Double
    /// Max distinct contact counters retained per exact candidate in Pass B.
    public var maxDispersionContactsPerCandidate: Int
    /// Max distinct chat counters retained per exact candidate in Pass B.
    public var maxDispersionChatsPerCandidate: Int
    /// Max distinct subject-day counters retained per exact candidate in Pass B.
    public var maxDispersionDaysPerCandidate: Int
    /// Max distinct world-month counters retained per exact candidate in Pass B.
    public var maxDispersionMonthsPerCandidate: Int

    // MARK: - template mining

    /// Longest token window considered while mining generalized templates.
    public var maxTemplateSpanTokens: Int
    /// Maximum fixed anchors retained in a template pattern.
    public var maxTemplateAnchors: Int
    /// Maximum variable slots retained in a template pattern.
    public var maxTemplateSlots: Int
    /// Maximum tokens a single generated slot may cover.
    public var maxTemplateSlotTokens: Int
    /// Minimum number of distinct fill strings across the template slots.
    public var minTemplateDistinctFills: Int
    /// Per-message cap on generated template patterns.
    public var maxTemplatePatternsPerMessage: Int
    /// Cap on usable anchors considered per token window before pair/triple
    /// combinations. Bounds the O(a^3) loop on long all-content windows.
    public var maxTemplateAnchorsPerWindow: Int
    /// Messages longer than this many word tokens are skipped for template mining
    /// only. They still feed n-gram phrase extraction.
    public var maxTemplateMessageTokens: Int
    /// Keep current single-anchor edge frames like "holy _" / "_ ahh".
    public var allowSingleAnchorEdgeTemplates: Bool
    /// Allow productive single/common-anchor templates to rank via slot variety
    /// even when the fixed anchor itself is common in the reference baseline.
    public var allowProductiveCommonAnchorTemplates: Bool
    /// Minimum normalized fill entropy for common-anchor productivity to count.
    public var minTemplateFillEntropyForCommonAnchor: Double

    // MARK: - dedup

    /// Suppress a subspan if a kept longer item covers at least this share of it.
    public var subspanDominanceShare: Double
    /// Suppress a weak longer expansion if it appears in at most this share of a
    /// kept shorter item's messages and lacks glue.
    public var weakExpansionShare: Double
    /// Glue floor below which weak longer expansions are deduped.
    public var minGlueForExpansion: Double
    /// Suppress multi-token proper-name/place-name candidates in the phrase list.
    public var suppressMultiwordNames: Bool

    // MARK: - optional embedding feature

    /// Enables the bounded Apple embedding semantic-shift pass. It runs only
    /// after candidate extraction over a capped candidate/occurrence set.
    public var enableSemanticShiftEmbeddings: Bool
    /// Max unigram candidates sent to the semantic-shift pass.
    public var semanticShiftCandidateLimit: Int
    /// Max subject-message contexts embedded per candidate.
    public var semanticShiftOccurrencesPerSurface: Int
    /// Token radius retained around a target word for semantic contexts.
    public var semanticShiftContextRadius: Int
    /// Legacy static-embedding flag kept for runtime compatibility.
    public var enableStaticEmbeddingFeatures: Bool
    /// Future cap on common baseline words used as embedding reference anchors.
    public var embeddingCommonWordLimit: Int

    /// Unified feature weights.
    public var weights: VernacularWeights

    public init(
        isEnabled: Bool = true,
        useTokenizedCorpus: Bool = false,
        tokenizedCorpusGlobalFloor: Int = 2,
        tokenizedCorpusMaxDistinctNgrams: Int = 200_000,
        posSenseEnabled: Bool = true,
        posSenseMinInitial: Int = 8,
        posSenseMinUserUses: Int = 5,
        posSenseMaxCandidates: Int = 200,
        posSenseMinVocativeRate: Double = 0.15,
        maxNgramLength: Int = 4,
        topWordCount: Int = 40,
        topCircleSlangCount: Int = 80,
        topPhraseCount: Int = 80,
        reclaimedWordCount: Int = 20,
        enableReclaimedLLMClassifier: Bool = false,
        topTemplateCount: Int = 40,
        minUserMessages: Int = 5,
        minDistinctDaysForLowCount: Int = 2,
        lowCountDayGate: Int = 10,
        maxNgramHashCandidates: Int = 50_000,
        maxExactNgramCandidates: Int = 25_000,
        maxTemplateHashCandidates: Int = 20_000,
        maxExactTemplateCandidates: Int = 12_000,
        activeContactMinMessages: Int = 30,
        minContactUsesForDocumentFrequency: Int = 2,
        minSubjectMessagesForProfile: Int = 30,
        lengthExponent: Double = 1.15,
        selfUsageLogScale: Double = 3.0,
        rarityLogScale: Double = 5.0,
        recencyLogScale: Double = 2.0,
        minOverBaseline: Double = 0.35,
        minGlue: Double = 0.05,
        collocationCountScale: Double = 12.0,
        logOddsPriorMass: Double = 50_000,
        referencePseudoCount: Double = 1_000_000,
        zScoreScale: Double = 6.0,
        roleLogitScale: Double = 3.0,
        worldEffectCountScale: Double = 10.0,
        textingRegisterPenaltyStrength: Double = 0.82,
        semanticShiftAnchorStrength: Double = 0.85,
        semanticShiftScale: Double = 0.45,
        semanticContextTightnessWeight: Double = 0.40,
        mainWordCollocationDampStrength: Double = 0.65,
        reclaimedMinUses: Int = 25,
        reclaimedMinWorldEff: Double = 3.0,
        reclaimedMinBaselineProbability: Double = 1e-6,
        reclaimedPercentileWeight: Double = 0.24,
        reclaimedKeepPercentile: Double = 0.80,
        reclaimedMinPerUserUses: Int = 3,
        reclaimedMinUsersForPercentile: Int = 4,
        reclaimedSenseAdmitFloor: Double = 0.25,
        reclaimedWeightOver: Double = 0.42,
        reclaimedWeightColloc: Double = 0.34,
        reclaimedWeightRole: Double = 0.0,
        reclaimedWeightDisp: Double = 0.0,
        reclaimedWeightSense: Double = 0.25,
        reclaimedWeightFreq: Double = 0.0,
        reclaimedWeightSteady: Double = 0.0,
        reclaimedFoldEnabled: Bool = true,
        reclaimedFoldShare: Double = 0.5,
        reclaimedFoldCooccurShare: Double = 0.4,
        reclaimedCompoundHardProtectMargin: Double = 0.40,
        reclaimedCompoundDropShare: Double = 0.6,
        phraseSlangWeight: Double = 0.6,
        signatureFramesEnabled: Bool = true,
        signatureFrameMinCount: Int = 6,
        reclaimedContactRescueEnabled: Bool = false,
        reclaimedRescueMarginFloor: Double = -0.05,
        reclaimedRescueRoleSkew: Double = 0.30,
        reclaimedSlangAffinityFloor: Double = 0.30,
        reclaimedSlangAffinityCeil: Double = 0.60,
        reclaimedSlangAffinityBoost: Double = 0.22,
        enableReclaimedContextFilter: Bool = true,
        reclaimedContextCandidateLimit: Int = 80,
        reclaimedContextMaxWindowsPerCandidate: Int = 30,
        reclaimedContextWindowRadius: Int = 8,
        reclaimedContextKeepThreshold: Double = 0.10,
        reclaimedContextTopicThreshold: Double = 0.35,
        reclaimedContextCategoryWeight: Double = 0.45,
        reclaimedContextCollocationBoost: Double = 0.18,
        enableReclaimedContextualEmbedding: Bool = false,
        maxStyleScoredPhraseCandidates: Int = 6_000,
        minPhraseStyleScore: Double = 0.18,
        topicPenaltyStrength: Double = 0.45,
        maxTopicScoreWithoutStyle: Double = 0.72,
        dailyUserCap: Int = 3,
        maxSingleDayShare: Double = 0.75,
        maxDispersionContactsPerCandidate: Int = 32,
        maxDispersionChatsPerCandidate: Int = 64,
        maxDispersionDaysPerCandidate: Int = 180,
        maxDispersionMonthsPerCandidate: Int = 96,
        maxTemplateSpanTokens: Int = 6,
        maxTemplateAnchors: Int = 3,
        maxTemplateSlots: Int = 3,
        maxTemplateSlotTokens: Int = 5,
        minTemplateDistinctFills: Int = 4,
        maxTemplatePatternsPerMessage: Int = 48,
        maxTemplateAnchorsPerWindow: Int = 4,
        maxTemplateMessageTokens: Int = 40,
        allowSingleAnchorEdgeTemplates: Bool = true,
        allowProductiveCommonAnchorTemplates: Bool = true,
        minTemplateFillEntropyForCommonAnchor: Double = 0.55,
        subspanDominanceShare: Double = 0.65,
        weakExpansionShare: Double = 0.35,
        minGlueForExpansion: Double = 0.10,
        suppressMultiwordNames: Bool = true,
        enableSemanticShiftEmbeddings: Bool = false,
        semanticShiftCandidateLimit: Int = 200,
        semanticShiftOccurrencesPerSurface: Int = 25,
        semanticShiftContextRadius: Int = 4,
        enableStaticEmbeddingFeatures: Bool = false,
        embeddingCommonWordLimit: Int = 200,
        weights: VernacularWeights = .default
    ) {
        self.isEnabled = isEnabled
        self.useTokenizedCorpus = useTokenizedCorpus
        self.tokenizedCorpusGlobalFloor = max(1, tokenizedCorpusGlobalFloor)
        self.tokenizedCorpusMaxDistinctNgrams = max(1, tokenizedCorpusMaxDistinctNgrams)
        self.posSenseEnabled = posSenseEnabled
        self.posSenseMinInitial = max(1, posSenseMinInitial)
        self.posSenseMinUserUses = max(1, posSenseMinUserUses)
        self.posSenseMaxCandidates = max(1, posSenseMaxCandidates)
        self.posSenseMinVocativeRate = min(max(posSenseMinVocativeRate, 0), 1)
        self.maxNgramLength = max(1, maxNgramLength)
        self.topWordCount = max(0, topWordCount)
        self.topCircleSlangCount = max(0, topCircleSlangCount)
        self.topPhraseCount = max(0, topPhraseCount)
        self.reclaimedWordCount = max(0, reclaimedWordCount)
        self.enableReclaimedLLMClassifier = enableReclaimedLLMClassifier
        self.topTemplateCount = max(0, topTemplateCount)
        self.minUserMessages = max(1, minUserMessages)
        self.minDistinctDaysForLowCount = max(1, minDistinctDaysForLowCount)
        self.lowCountDayGate = max(1, lowCountDayGate)
        self.maxNgramHashCandidates = max(1, maxNgramHashCandidates)
        self.maxExactNgramCandidates = max(1, maxExactNgramCandidates)
        self.maxTemplateHashCandidates = max(1, maxTemplateHashCandidates)
        self.maxExactTemplateCandidates = max(1, maxExactTemplateCandidates)
        self.activeContactMinMessages = max(1, activeContactMinMessages)
        self.minContactUsesForDocumentFrequency = max(1, minContactUsesForDocumentFrequency)
        self.minSubjectMessagesForProfile = max(1, minSubjectMessagesForProfile)
        self.lengthExponent = max(0.01, lengthExponent)
        self.selfUsageLogScale = max(0.1, selfUsageLogScale)
        self.rarityLogScale = max(0.1, rarityLogScale)
        self.recencyLogScale = max(0.1, recencyLogScale)
        self.minOverBaseline = minOverBaseline
        self.minGlue = minGlue
        self.collocationCountScale = max(0.1, collocationCountScale)
        self.logOddsPriorMass = max(1, logOddsPriorMass)
        self.referencePseudoCount = max(1, referencePseudoCount)
        self.zScoreScale = max(0.1, zScoreScale)
        self.roleLogitScale = max(0.1, roleLogitScale)
        self.worldEffectCountScale = max(0.0, worldEffectCountScale)
        self.textingRegisterPenaltyStrength = min(max(textingRegisterPenaltyStrength, 0), 1)
        self.semanticShiftAnchorStrength = min(max(semanticShiftAnchorStrength, 0), 1)
        self.semanticShiftScale = max(0.01, semanticShiftScale)
        self.semanticContextTightnessWeight = min(max(semanticContextTightnessWeight, 0), 1)
        self.mainWordCollocationDampStrength = min(max(mainWordCollocationDampStrength, 0), 1)
        self.reclaimedMinUses = max(1, reclaimedMinUses)
        self.reclaimedMinWorldEff = max(0, reclaimedMinWorldEff)
        self.reclaimedMinBaselineProbability = max(0, reclaimedMinBaselineProbability)
        self.reclaimedPercentileWeight = max(0, reclaimedPercentileWeight)
        self.reclaimedKeepPercentile = min(max(reclaimedKeepPercentile, 0.01), 1)
        self.reclaimedMinPerUserUses = max(1, reclaimedMinPerUserUses)
        self.reclaimedMinUsersForPercentile = max(1, reclaimedMinUsersForPercentile)
        self.reclaimedSenseAdmitFloor = min(max(reclaimedSenseAdmitFloor, 0), 1)
        self.reclaimedWeightOver = max(0, reclaimedWeightOver)
        self.reclaimedWeightColloc = max(0, reclaimedWeightColloc)
        self.reclaimedWeightRole = max(0, reclaimedWeightRole)
        self.reclaimedWeightDisp = max(0, reclaimedWeightDisp)
        self.reclaimedWeightSense = max(0, reclaimedWeightSense)
        self.reclaimedWeightFreq = max(0, reclaimedWeightFreq)
        self.reclaimedWeightSteady = max(0, reclaimedWeightSteady)
        self.reclaimedFoldEnabled = reclaimedFoldEnabled
        self.reclaimedFoldShare = min(max(reclaimedFoldShare, 0), 1)
        self.reclaimedFoldCooccurShare = min(max(reclaimedFoldCooccurShare, 0), 1)
        self.reclaimedCompoundHardProtectMargin = min(max(reclaimedCompoundHardProtectMargin, 0), 1)
        self.reclaimedCompoundDropShare = min(max(reclaimedCompoundDropShare, 0), 1)
        self.phraseSlangWeight = max(0, phraseSlangWeight)
        self.signatureFramesEnabled = signatureFramesEnabled
        self.signatureFrameMinCount = max(2, signatureFrameMinCount)
        self.reclaimedContactRescueEnabled = reclaimedContactRescueEnabled
        self.reclaimedRescueMarginFloor = min(max(reclaimedRescueMarginFloor, -1), 1)
        self.reclaimedRescueRoleSkew = min(max(reclaimedRescueRoleSkew, 0), 1)
        self.reclaimedSlangAffinityFloor = min(max(reclaimedSlangAffinityFloor, 0), 1)
        self.reclaimedSlangAffinityCeil = min(max(reclaimedSlangAffinityCeil, reclaimedSlangAffinityFloor + 0.01), 1)
        self.reclaimedSlangAffinityBoost = max(0, reclaimedSlangAffinityBoost)
        self.enableReclaimedContextFilter = enableReclaimedContextFilter
        self.reclaimedContextCandidateLimit = max(1, reclaimedContextCandidateLimit)
        self.reclaimedContextMaxWindowsPerCandidate = max(1, reclaimedContextMaxWindowsPerCandidate)
        self.reclaimedContextWindowRadius = max(1, reclaimedContextWindowRadius)
        self.reclaimedContextKeepThreshold = min(max(reclaimedContextKeepThreshold, -1), 1)
        self.reclaimedContextTopicThreshold = min(max(reclaimedContextTopicThreshold, 0), 1)
        self.reclaimedContextCategoryWeight = min(max(reclaimedContextCategoryWeight, 0), 1)
        self.reclaimedContextCollocationBoost = min(max(reclaimedContextCollocationBoost, 0), 1)
        self.enableReclaimedContextualEmbedding = enableReclaimedContextualEmbedding
        self.maxStyleScoredPhraseCandidates = max(1, maxStyleScoredPhraseCandidates)
        self.minPhraseStyleScore = min(max(minPhraseStyleScore, 0), 1)
        self.topicPenaltyStrength = min(max(topicPenaltyStrength, 0), 1)
        self.maxTopicScoreWithoutStyle = min(max(maxTopicScoreWithoutStyle, 0), 1)
        self.dailyUserCap = max(1, dailyUserCap)
        self.maxSingleDayShare = min(maxSingleDayShare, 1.0)
        self.maxDispersionContactsPerCandidate = max(1, maxDispersionContactsPerCandidate)
        self.maxDispersionChatsPerCandidate = max(1, maxDispersionChatsPerCandidate)
        self.maxDispersionDaysPerCandidate = max(1, maxDispersionDaysPerCandidate)
        self.maxDispersionMonthsPerCandidate = max(1, maxDispersionMonthsPerCandidate)
        self.maxTemplateSpanTokens = max(2, maxTemplateSpanTokens)
        self.maxTemplateAnchors = max(1, maxTemplateAnchors)
        self.maxTemplateSlots = max(1, maxTemplateSlots)
        self.maxTemplateSlotTokens = max(1, maxTemplateSlotTokens)
        self.minTemplateDistinctFills = max(1, minTemplateDistinctFills)
        self.maxTemplatePatternsPerMessage = max(1, maxTemplatePatternsPerMessage)
        self.maxTemplateAnchorsPerWindow = max(1, maxTemplateAnchorsPerWindow)
        self.maxTemplateMessageTokens = max(2, maxTemplateMessageTokens)
        self.allowSingleAnchorEdgeTemplates = allowSingleAnchorEdgeTemplates
        self.allowProductiveCommonAnchorTemplates = allowProductiveCommonAnchorTemplates
        self.minTemplateFillEntropyForCommonAnchor = min(max(minTemplateFillEntropyForCommonAnchor, 0), 1)
        self.subspanDominanceShare = min(max(subspanDominanceShare, 0), 1)
        self.weakExpansionShare = min(max(weakExpansionShare, 0), 1)
        self.minGlueForExpansion = minGlueForExpansion
        self.suppressMultiwordNames = suppressMultiwordNames
        self.enableSemanticShiftEmbeddings = enableSemanticShiftEmbeddings
        self.semanticShiftCandidateLimit = max(1, semanticShiftCandidateLimit)
        self.semanticShiftOccurrencesPerSurface = max(1, semanticShiftOccurrencesPerSurface)
        self.semanticShiftContextRadius = max(1, semanticShiftContextRadius)
        self.enableStaticEmbeddingFeatures = enableStaticEmbeddingFeatures
        self.embeddingCommonWordLimit = max(1, embeddingCommonWordLimit)
        self.weights = weights
    }

    public static let `default` = VernacularConfig(isEnabled: true)
    public static let disabled = VernacularConfig(isEnabled: false)

    /// Runtime config. New profile computation is enabled by default for the
    /// Stage-A UI cutover, while `vernacular.profile.enabled = false` restores
    /// the legacy list rendering path.
    public static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> VernacularConfig {
        var config = VernacularConfig.default
        if defaults.object(forKey: "vernacular.profile.enabled") != nil {
            config.isEnabled = defaults.bool(forKey: "vernacular.profile.enabled")
        }
        if defaults.object(forKey: "vernacular.profile.tokenizedCorpus") != nil {
            config.useTokenizedCorpus = defaults.bool(forKey: "vernacular.profile.tokenizedCorpus")
        }
        config.tokenizedCorpusGlobalFloor = defaults.integerOrDefault("vernacular.profile.tokenizedCorpus.globalFloor", config.tokenizedCorpusGlobalFloor)
        config.tokenizedCorpusMaxDistinctNgrams = defaults.integerOrDefault("vernacular.profile.tokenizedCorpus.maxDistinctNgrams", config.tokenizedCorpusMaxDistinctNgrams)
        if defaults.object(forKey: "vernacular.spread.posSense") != nil {
            config.posSenseEnabled = defaults.bool(forKey: "vernacular.spread.posSense")
        }
        config.posSenseMinInitial = defaults.integerOrDefault("vernacular.spread.posSense.minInitial", config.posSenseMinInitial)
        config.posSenseMinUserUses = defaults.integerOrDefault("vernacular.spread.posSense.minUserUses", config.posSenseMinUserUses)
        config.posSenseMaxCandidates = defaults.integerOrDefault("vernacular.spread.posSense.maxCandidates", config.posSenseMaxCandidates)
        config.posSenseMinVocativeRate = defaults.doubleOrDefault("vernacular.spread.posSense.minVocativeRate", config.posSenseMinVocativeRate)
        config.maxNgramLength = defaults.integerOrDefault("vernacular.profile.maxNgramLength", config.maxNgramLength)
        config.topWordCount = defaults.integerOrDefault("vernacular.profile.topWordCount", config.topWordCount)
        config.topCircleSlangCount = defaults.integerOrDefault("vernacular.profile.topCircleSlangCount", config.topCircleSlangCount)
        config.topPhraseCount = defaults.integerOrDefault("vernacular.profile.topPhraseCount", config.topPhraseCount)
        config.reclaimedWordCount = defaults.integerOrDefault("vernacular.profile.reclaimed.count", config.reclaimedWordCount)
        if defaults.object(forKey: "vernacular.profile.reclaimed.llmClassify") != nil {
            config.enableReclaimedLLMClassifier = defaults.bool(forKey: "vernacular.profile.reclaimed.llmClassify")
        }
        config.topTemplateCount = defaults.integerOrDefault("vernacular.profile.topTemplateCount", config.topTemplateCount)
        config.minUserMessages = defaults.integerOrDefault("vernacular.profile.minUserMessages", config.minUserMessages)
        config.dailyUserCap = defaults.integerOrDefault("vernacular.profile.dailyUserCap", config.dailyUserCap)
        config.maxSingleDayShare = defaults.doubleOrDefault("vernacular.profile.maxSingleDayShare", config.maxSingleDayShare)
        config.lengthExponent = defaults.doubleOrDefault("vernacular.profile.lengthExponent", config.lengthExponent)
        config.minOverBaseline = defaults.doubleOrDefault("vernacular.profile.minOverBaseline", config.minOverBaseline)
        config.minGlue = defaults.doubleOrDefault("vernacular.profile.minGlue", config.minGlue)
        config.collocationCountScale = defaults.doubleOrDefault("vernacular.profile.collocationCountScale", config.collocationCountScale)
        config.logOddsPriorMass = defaults.doubleOrDefault("vernacular.profile.logOddsPriorMass", config.logOddsPriorMass)
        config.referencePseudoCount = defaults.doubleOrDefault("vernacular.profile.referencePseudoCount", config.referencePseudoCount)
        config.zScoreScale = defaults.doubleOrDefault("vernacular.profile.zScoreScale", config.zScoreScale)
        config.roleLogitScale = defaults.doubleOrDefault("vernacular.profile.roleLogitScale", config.roleLogitScale)
        config.worldEffectCountScale = defaults.doubleOrDefault("vernacular.profile.worldEffectCountScale", config.worldEffectCountScale)
        config.textingRegisterPenaltyStrength = defaults.doubleOrDefault("vernacular.profile.textingRegisterPenaltyStrength", config.textingRegisterPenaltyStrength)
        config.semanticShiftAnchorStrength = defaults.doubleOrDefault("vernacular.profile.semanticShiftAnchorStrength", config.semanticShiftAnchorStrength)
        config.semanticShiftScale = defaults.doubleOrDefault("vernacular.profile.semanticShiftScale", config.semanticShiftScale)
        config.semanticContextTightnessWeight = defaults.doubleOrDefault("vernacular.profile.semanticContextTightnessWeight", config.semanticContextTightnessWeight)
        config.mainWordCollocationDampStrength = defaults.doubleOrDefault("vernacular.profile.mainWordCollocationDampStrength", config.mainWordCollocationDampStrength)
        config.reclaimedMinUses = defaults.integerOrDefault("vernacular.profile.reclaimed.minUses", config.reclaimedMinUses)
        config.reclaimedMinWorldEff = defaults.doubleOrDefault("vernacular.profile.reclaimed.minWorldEff", config.reclaimedMinWorldEff)
        config.reclaimedMinBaselineProbability = defaults.doubleOrDefault("vernacular.profile.reclaimed.minBaselineProb", config.reclaimedMinBaselineProbability)
        config.reclaimedPercentileWeight = defaults.doubleOrDefault("vernacular.profile.reclaimed.percentileWeight", config.reclaimedPercentileWeight)
        config.reclaimedKeepPercentile = defaults.doubleOrDefault("vernacular.profile.reclaimed.keepPercentile", config.reclaimedKeepPercentile)
        config.reclaimedMinPerUserUses = defaults.integerOrDefault("vernacular.profile.reclaimed.minPerUserUses", config.reclaimedMinPerUserUses)
        config.reclaimedMinUsersForPercentile = defaults.integerOrDefault("vernacular.profile.reclaimed.minUsersForPercentile", config.reclaimedMinUsersForPercentile)
        config.reclaimedSenseAdmitFloor = defaults.doubleOrDefault("vernacular.profile.reclaimed.senseAdmitFloor", config.reclaimedSenseAdmitFloor)
        config.reclaimedWeightOver = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.over", config.reclaimedWeightOver)
        config.reclaimedWeightColloc = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.colloc", config.reclaimedWeightColloc)
        config.reclaimedWeightRole = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.role", config.reclaimedWeightRole)
        config.reclaimedWeightDisp = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.disp", config.reclaimedWeightDisp)
        config.reclaimedWeightSense = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.sense", config.reclaimedWeightSense)
        config.reclaimedWeightFreq = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.freq", config.reclaimedWeightFreq)
        config.reclaimedWeightSteady = defaults.doubleOrDefault("vernacular.profile.reclaimed.weight.steady", config.reclaimedWeightSteady)
        if defaults.object(forKey: "vernacular.profile.reclaimed.fold") != nil {
            config.reclaimedFoldEnabled = defaults.bool(forKey: "vernacular.profile.reclaimed.fold")
        }
        config.reclaimedFoldShare = defaults.doubleOrDefault("vernacular.profile.reclaimed.fold.share", config.reclaimedFoldShare)
        config.reclaimedFoldCooccurShare = defaults.doubleOrDefault("vernacular.profile.reclaimed.fold.cooccurShare", config.reclaimedFoldCooccurShare)
        config.reclaimedCompoundHardProtectMargin = defaults.doubleOrDefault("vernacular.profile.reclaimed.fold.hardProtectMargin", config.reclaimedCompoundHardProtectMargin)
        config.reclaimedCompoundDropShare = defaults.doubleOrDefault("vernacular.profile.reclaimed.fold.compoundDropShare", config.reclaimedCompoundDropShare)
        config.phraseSlangWeight = defaults.doubleOrDefault("vernacular.profile.phrase.weight.slang", config.phraseSlangWeight)
        if defaults.object(forKey: "vernacular.profile.signatureFrames") != nil {
            config.signatureFramesEnabled = defaults.bool(forKey: "vernacular.profile.signatureFrames")
        }
        config.signatureFrameMinCount = defaults.integerOrDefault("vernacular.profile.signatureFrames.minCount", config.signatureFrameMinCount)
        config.reclaimedRescueMarginFloor = defaults.doubleOrDefault("vernacular.profile.reclaimed.rescue.marginFloor", config.reclaimedRescueMarginFloor)
        config.reclaimedRescueRoleSkew = defaults.doubleOrDefault("vernacular.profile.reclaimed.rescue.roleSkew", config.reclaimedRescueRoleSkew)
        config.reclaimedSlangAffinityFloor = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.affinityFloor", config.reclaimedSlangAffinityFloor)
        config.reclaimedSlangAffinityCeil = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.affinityCeil", config.reclaimedSlangAffinityCeil)
        config.reclaimedSlangAffinityBoost = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.affinityBoost", config.reclaimedSlangAffinityBoost)
        if defaults.object(forKey: "vernacular.profile.reclaimed.contextFilter") != nil {
            config.enableReclaimedContextFilter = defaults.bool(forKey: "vernacular.profile.reclaimed.contextFilter")
        }
        config.reclaimedContextCandidateLimit = defaults.integerOrDefault("vernacular.profile.reclaimed.context.candidateLimit", config.reclaimedContextCandidateLimit)
        config.reclaimedContextMaxWindowsPerCandidate = defaults.integerOrDefault("vernacular.profile.reclaimed.context.maxWindowsPerCandidate", config.reclaimedContextMaxWindowsPerCandidate)
        config.reclaimedContextWindowRadius = defaults.integerOrDefault("vernacular.profile.reclaimed.context.windowRadius", config.reclaimedContextWindowRadius)
        config.reclaimedContextKeepThreshold = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.keepThreshold", config.reclaimedContextKeepThreshold)
        config.reclaimedContextTopicThreshold = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.topicThreshold", config.reclaimedContextTopicThreshold)
        config.reclaimedContextCategoryWeight = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.categoryWeight", config.reclaimedContextCategoryWeight)
        config.reclaimedContextCollocationBoost = defaults.doubleOrDefault("vernacular.profile.reclaimed.context.collocationBoost", config.reclaimedContextCollocationBoost)
        if defaults.object(forKey: "vernacular.profile.reclaimed.context.contextualEmbedding") != nil {
            config.enableReclaimedContextualEmbedding = defaults.bool(forKey: "vernacular.profile.reclaimed.context.contextualEmbedding")
        }
        config.semanticShiftCandidateLimit = defaults.integerOrDefault("vernacular.profile.semanticShiftCandidateLimit", config.semanticShiftCandidateLimit)
        config.semanticShiftOccurrencesPerSurface = defaults.integerOrDefault("vernacular.profile.semanticShiftOccurrencesPerSurface", config.semanticShiftOccurrencesPerSurface)
        config.semanticShiftContextRadius = defaults.integerOrDefault("vernacular.profile.semanticShiftContextRadius", config.semanticShiftContextRadius)
        config.minSubjectMessagesForProfile = defaults.integerOrDefault("vernacular.profile.minSubjectMessagesForProfile", config.minSubjectMessagesForProfile)
        config.maxDispersionContactsPerCandidate = defaults.integerOrDefault("vernacular.profile.maxDispersionContactsPerCandidate", config.maxDispersionContactsPerCandidate)
        config.maxDispersionChatsPerCandidate = defaults.integerOrDefault("vernacular.profile.maxDispersionChatsPerCandidate", config.maxDispersionChatsPerCandidate)
        config.maxDispersionDaysPerCandidate = defaults.integerOrDefault("vernacular.profile.maxDispersionDaysPerCandidate", config.maxDispersionDaysPerCandidate)
        config.maxDispersionMonthsPerCandidate = defaults.integerOrDefault("vernacular.profile.maxDispersionMonthsPerCandidate", config.maxDispersionMonthsPerCandidate)
        config.maxStyleScoredPhraseCandidates = defaults.integerOrDefault("vernacular.profile.maxStyleScoredPhraseCandidates", config.maxStyleScoredPhraseCandidates)
        config.minPhraseStyleScore = defaults.doubleOrDefault("vernacular.profile.minPhraseStyleScore", config.minPhraseStyleScore)
        config.topicPenaltyStrength = defaults.doubleOrDefault("vernacular.profile.topicPenaltyStrength", config.topicPenaltyStrength)
        config.maxTopicScoreWithoutStyle = defaults.doubleOrDefault("vernacular.profile.maxTopicScoreWithoutStyle", config.maxTopicScoreWithoutStyle)
        config.maxTemplateSpanTokens = defaults.integerOrDefault("vernacular.profile.maxTemplateSpanTokens", config.maxTemplateSpanTokens)
        config.maxTemplatePatternsPerMessage = defaults.integerOrDefault("vernacular.profile.maxTemplatePatternsPerMessage", config.maxTemplatePatternsPerMessage)
        config.maxTemplateAnchorsPerWindow = defaults.integerOrDefault("vernacular.profile.maxTemplateAnchorsPerWindow", config.maxTemplateAnchorsPerWindow)
        config.maxTemplateMessageTokens = defaults.integerOrDefault("vernacular.profile.maxTemplateMessageTokens", config.maxTemplateMessageTokens)
        config.minTemplateFillEntropyForCommonAnchor = defaults.doubleOrDefault("vernacular.profile.minTemplateFillEntropyForCommonAnchor", config.minTemplateFillEntropyForCommonAnchor)

        var weights = config.weights
        weights.length = defaults.doubleOrDefault("vernacular.profile.weight.length", weights.length)
        weights.worldDistinctiveness = defaults.doubleOrDefault("vernacular.profile.weight.worldDistinctiveness", weights.worldDistinctiveness)
        weights.role = defaults.doubleOrDefault("vernacular.profile.weight.role", weights.role)
        weights.dispersion = defaults.doubleOrDefault("vernacular.profile.weight.dispersion", weights.dispersion)
        weights.echo = defaults.doubleOrDefault("vernacular.profile.weight.echo", weights.echo)
        weights.burstResistance = defaults.doubleOrDefault("vernacular.profile.weight.burstResistance", weights.burstResistance)
        weights.peopleIDF = defaults.doubleOrDefault("vernacular.profile.weight.peopleIDF", weights.peopleIDF)
        weights.selfUsage = defaults.doubleOrDefault("vernacular.profile.weight.selfUsage", weights.selfUsage)
        weights.rarity = defaults.doubleOrDefault("vernacular.profile.weight.rarity", weights.rarity)
        weights.recency = defaults.doubleOrDefault("vernacular.profile.weight.recency", weights.recency)
        weights.spamResistance = defaults.doubleOrDefault("vernacular.profile.weight.spamResistance", weights.spamResistance)
        weights.glue = defaults.doubleOrDefault("vernacular.profile.weight.glue", weights.glue)
        weights.collocation = defaults.doubleOrDefault("vernacular.profile.weight.collocation", weights.collocation)
        weights.semanticShift = defaults.doubleOrDefault("vernacular.profile.weight.semanticShift", weights.semanticShift)
        weights.style = defaults.doubleOrDefault("vernacular.profile.weight.style", weights.style)
        weights.productivity = defaults.doubleOrDefault("vernacular.profile.weight.productivity", weights.productivity)
        weights.anchorDistinctiveness = defaults.doubleOrDefault("vernacular.profile.weight.anchorDistinctiveness", weights.anchorDistinctiveness)
        weights.embedding = defaults.doubleOrDefault("vernacular.profile.weight.embedding", weights.embedding)
        config.weights = weights

        if defaults.object(forKey: "vernacular.profile.suppressMultiwordNames") != nil {
            config.suppressMultiwordNames = defaults.bool(forKey: "vernacular.profile.suppressMultiwordNames")
        }
        if defaults.object(forKey: "vernacular.profile.allowProductiveCommonAnchorTemplates") != nil {
            config.allowProductiveCommonAnchorTemplates = defaults.bool(forKey: "vernacular.profile.allowProductiveCommonAnchorTemplates")
        }
        if defaults.object(forKey: "vernacular.profile.embeddings.enabled") != nil {
            config.enableSemanticShiftEmbeddings = defaults.bool(forKey: "vernacular.profile.embeddings.enabled")
        }
        config.enableStaticEmbeddingFeatures = defaults.bool(forKey: "vernacular.profile.embeddings.static.enabled")
        return config
    }

    /// Derive the working config for ONE subject's build:
    /// - Count gates become PROPORTIONS of the subject's message volume
    ///   relative to the MEASURED device-owner volume (`referenceVolume` —
    ///   counted from the same corpus, never assumed). The owner's ratio is
    ///   exactly 1, so their gates are the tuned defaults BY CONSTRUCTION;
    ///   a contact's visible slice is 10-100× smaller, and absolute counts
    ///   starved their lists (measured: sheesh@DavidKim, 8 uses vs the flat
    ///   minUses=25). Floored so tiny corpora don't admit one-offs; capped
    ///   at the tuned defaults.
    /// - Non-owner subjects switch the reclaimed classifier to CONTACT MODE:
    ///   a lower keep threshold plus the statistical rescue — their context
    ///   margins run systematically lower because their trusted-slang sets
    ///   are smaller (measured: twin@Saketh +0.08 vs the 0.10 threshold).
    public func scaledForSubject(
        subjectMessageCount: Int,
        referenceVolume: Int,
        isYou: Bool
    ) -> VernacularConfig {
        var scaled = self
        let volume = Double(max(subjectMessageCount, 1))
        let reference = Double(max(referenceVolume, 1))
        func proportional(_ tuned: Int, floor floorValue: Int) -> Int {
            let raw = Double(tuned) * volume / reference
            return min(tuned, max(floorValue, Int(raw.rounded())))
        }
        scaled.reclaimedMinUses = proportional(reclaimedMinUses, floor: 6)
        scaled.minUserMessages = proportional(minUserMessages, floor: 3)
        scaled.posSenseMinUserUses = proportional(posSenseMinUserUses, floor: 3)
        if !isYou {
            scaled.reclaimedContextKeepThreshold = min(reclaimedContextKeepThreshold, 0.05)
            scaled.reclaimedContactRescueEnabled = true
        }
        return scaled
    }
}

private extension UserDefaults {
    func integerOrDefault(_ key: String, _ fallback: Int) -> Int {
        object(forKey: key) == nil ? fallback : integer(forKey: key)
    }

    func doubleOrDefault(_ key: String, _ fallback: Double) -> Double {
        object(forKey: key) == nil ? fallback : double(forKey: key)
    }
}
