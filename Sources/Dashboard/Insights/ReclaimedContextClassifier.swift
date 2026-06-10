//
//  ReclaimedContextClassifier.swift
//  Hourglass - Phase-1 reclaimed-word context filter
//

import Foundation
import NaturalLanguage

/// Filters statistically-ranked reclaimed words by how the subject actually uses
/// them in context. This is deliberately not another aggregate count feature:
/// work/topic terms and personal slang can have the same worldEff/collocation,
/// but they tend to live in different message contexts.
enum ReclaimedContextClassifier {
    struct Result: Sendable, Equatable {
        let filtered: [VernacularProfileReclaimedWord]
        let diagnostics: [VernacularReclaimedContextDecision]
    }

    private struct UsageWindow {
        let surface: String
        let tokens: [String]
        let text: String
        let amused: Bool
        let laughed: Bool
    }

    private struct WindowScore {
        let slang: Double
        let topic: Double
        let namedEntity: Bool
    }

    private struct CategoryPrototype {
        let name: String
        let vector: [Double]
        let weight: Double
    }

    private static let targetToken = "_target_"

    private static let builtInSlangTokens: Set<String> = [
        "lowk", "lowkey", "deadass", "lmao", "lmfao", "fr", "wtf", "bruh",
        "yuh", "ngl", "tbh", "idk", "lmk", "yessir", "hella", "tryna", "abt"
    ]

    private static let reactiveTokens: Set<String> = [
        "crazy", "insane", "wild", "mad", "funny", "hilarious", "goated",
        "valid", "fire", "lit", "peak", "vibe", "vibes", "negative",
        "positive", "actually", "literally", "so", "hella", "nah", "no",
        "way", "rip", "lmao", "lmfao", "lol", "haha", "ahaha"
    ]

    // (The old hardcoded `reclaimedSlangSurfaceCues` word list is GONE —
    // replaced by a per-subject slang-affinity boost: cosine similarity of the
    // candidate to the centroid of the subject's OWN discovered slang, through
    // a soft ramp. Generalizes to any subject and ages with the data.)

    private static let topicTokens: Set<String> = [
        // work/logistics
        "meeting", "meetings", "email", "emails", "invoice", "invoices",
        "handoff", "handoffs", "schedule", "scheduled", "scheduling",
        "calendar", "deadline", "deadlines", "recruiting", "recruitment",
        "intern", "interns", "internship", "internships", "offer", "offers",
        "interview", "interviews", "resume", "team", "teams", "project",
        "projects", "cloud", "tech", "startup", "startups", "founder",
        "founders", "company", "companies", "yc", "vp", "ceo", "cto",
        "manager", "salesforce", "citadel", "snippet", "snippets", "code",
        "coding", "github", "deploy", "deployment",
        // school / applications / dorms
        "class", "classes", "exam", "exams", "midterm", "midterms", "final",
        "finals", "quarter", "quarters", "semester", "semesters", "ap",
        "college", "colleges", "application", "applications", "apps", "app",
        "dorm", "dorms", "campus", "lecture", "lectures", "homework",
        // places / games / activities / literal media objects
        "vista", "lounge", "clash", "royale", "game", "games", "album",
        "albums", "pic", "pics", "photo", "photos", "protein", "boba",
        "tabla", "lag", "ski", "yacht"
    ]

    private static let categorySeeds: [(name: String, weight: Double, seeds: [String])] = [
        ("work", 1.0, ["work", "meeting", "email", "invoice", "handoff", "startup",
                       "company", "recruiting", "intern", "vp", "tech", "snippet",
                       "project", "manager", "founder", "app", "apps"]),
        ("school", 0.9, ["school", "class", "exam", "quarter", "college", "application",
                         "applications", "app", "apps", "dorm", "campus", "homework", "lecture"]),
        ("instrument", 1.0, ["instrument", "guitar", "piano", "drums", "violin", "tabla"]),
        ("game", 0.9, ["game", "clash", "royale", "chess", "minecraft", "league"]),
        ("place", 0.85, ["place", "dorm", "lounge", "vista", "campus", "hotel", "airport"]),
        ("media", 0.75, ["photo", "picture", "pic", "album", "video", "playlist"]),
        ("food", 0.55, ["food", "drink", "boba", "protein", "coffee", "lunch", "dinner"])
    ]

    static func classify(
        _ ranked: [VernacularProfileReclaimedWord],
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext,
        trustedSlangSurfaces: Set<String>,
        config: VernacularConfig
    ) -> Result {
        guard config.enableReclaimedContextFilter, !ranked.isEmpty else {
            return Result(filtered: ranked, diagnostics: [])
        }

        let considered = Array(ranked.prefix(config.reclaimedContextCandidateLimit))
        let wanted = Set(considered.map { $0.surface })
        let slangTokens = trustedSlangTokens(from: trustedSlangSurfaces, excluding: wanted)
        // Stride per surface so the window sample SPREADS across the word's
        // whole history instead of clustering at its first N occurrences —
        // reclaimed words are definitionally words whose usage SHIFTED, so a
        // chronological-head sample judges them on their pre-slang era.
        let strideBySurface: [String: Int] = considered.reduce(into: [:]) { acc, item in
            acc[item.surface] = max(1, item.counts.userMessages
                / max(config.reclaimedContextMaxWindowsPerCandidate, 1))
        }
        let windows = collectWindows(for: wanted,
                                     messages: messages,
                                     subjectContext: subjectContext,
                                     maxPerSurface: config.reclaimedContextMaxWindowsPerCandidate,
                                     radius: config.reclaimedContextWindowRadius,
                                     strideBySurface: strideBySurface)
        let embedding = NLEmbedding.wordEmbedding(for: .english)
        let prototypes = buildCategoryPrototypes(embedding: embedding)
        let slangCentroid = buildSlangCentroid(from: slangTokens, embedding: embedding)
        let tagger = NLTagger(tagSchemes: [.nameType])
        // Partner adjacency/co-occurrence over EVERY subject occurrence — NOT
        // the capped window sample. The sample takes the first N occurrences
        // in corpus order, which misses collocations that emerged later
        // (measured: "holy bang" is genuinely adjacent in the user's recent
        // messages, yet holy's first-30 windows predate the phrase entirely
        // and read 0/30). Counting is cheap; only the NLTagger window SCORING
        // needs the cap.
        let partnerBySurface: [String: String] = considered.reduce(into: [:]) { acc, item in
            if let partner = item.topCollocationPartner?.lowercased(), !partner.isEmpty {
                acc[item.surface] = partner
            }
        }
        let adjStats = fullAdjacencyStats(for: wanted,
                                          partnerBySurface: partnerBySurface,
                                          messages: messages,
                                          subjectContext: subjectContext)

        var diagnostics: [VernacularReclaimedContextDecision] = []
        diagnostics.reserveCapacity(considered.count)
        var kept: [VernacularProfileReclaimedWord] = []
        kept.reserveCapacity(min(considered.count, config.reclaimedWordCount))
        // Raw ingredients per candidate (adjacency counts, raw affinity cosine,
        // pre-affinity rates) — dumped to disk in bench runs so thresholds can
        // be replayed OFFLINE in milliseconds instead of re-running the whole
        // 10+-minute extraction per tuning attempt.
        var dumpRows: [[String: Any]] = []

        for item in considered {
            let surfaceWindows = windows[item.surface] ?? []
            // Target-level slang affinity (raw cosine + the annealed addend),
            // computed HERE so the dump can record both ingredients.
            var affinityCosine = 0.0
            var affinityAddend = 0.0
            if let slangCentroid,
               let vector = embedding?.vector(for: item.surface),
               vector.count == slangCentroid.count {
                affinityCosine = cosineSimilarity(vector, slangCentroid)
                let span = max(config.reclaimedSlangAffinityCeil - config.reclaimedSlangAffinityFloor, 0.01)
                let t = clamp01((affinityCosine - config.reclaimedSlangAffinityFloor) / span)
                affinityAddend = config.reclaimedSlangAffinityBoost * (t * t * (3 - 2 * t))
            }
            let decision = decide(item: item,
                                  windows: surfaceWindows,
                                  slangTokens: slangTokens,
                                  prototypes: prototypes,
                                  slangAffinityAddend: affinityAddend,
                                  embedding: embedding,
                                  tagger: tagger,
                                  config: config)
            diagnostics.append(decision)

            let partner = item.topCollocationPartner?.lowercased() ?? ""
            let adj = adjStats[item.surface]
                ?? (before: 0, after: 0, coBefore: 0, coAfter: 0, total: 0)
            dumpRows.append([
                "surface": item.surface,
                "rank": item.rank,
                "score": item.score,
                "partner": partner,
                "partnerConsidered": wanted.contains(partner),
                "windowCount": adj.total,
                "adjBefore": adj.before,
                "adjAfter": adj.after,
                "coBefore": adj.coBefore,
                "coAfter": adj.coAfter,
                "slangRateRaw": max(0, decision.slangRate - affinityAddend),
                "topicRate": decision.topicRate,
                "keepMargin": decision.keepMargin,
                "affinityCosine": affinityCosine,
                "affinityAddend": affinityAddend,
                "verdict": decision.verdict.rawValue,
                // Gate inputs — so ADMISSION thresholds (minUses/minWorldEff/…)
                // are replayable OFFLINE from one floor-gate run's table.
                "userMessages": item.counts.userMessages,
                "worldEff": item.worldEff,
                "percentile": item.percentile,
                "collocation": item.collocation,
                "senseDistance": item.senseDistance,
                "roleSkew": item.roleSkew,
                "concentration": item.concentration,
            ])

            guard decision.verdict == .keep else { continue }
            kept.append(copy(item,
                             verdict: decision.verdict,
                             slangRate: decision.slangRate,
                             topicRate: decision.topicRate,
                             keepMargin: decision.keepMargin))
        }

        writeAdjacencyDumpIfBenching(rows: dumpRows, messages: messages, config: config)

        let consideredBySurface = Dictionary(uniqueKeysWithValues: considered.map { ($0.surface, $0) })
        let processed = config.reclaimedFoldEnabled
            ? foldAndDemote(kept, consideredBySurface: consideredBySurface, adjStats: adjStats, config: config)
            : kept
        let capped = Array(processed.prefix(config.reclaimedWordCount))
        return Result(filtered: rerank(capped), diagnostics: diagnostics)
    }

    /// Bench-only artifact: the per-candidate adjacency/affinity table, written
    /// once per classify run so threshold changes can be REPLAYED offline (see
    /// scripts/probes/replay-reclaimed-thresholds.py) instead of re-running the
    /// full extraction. Path overridable via HOURGLASS_ADJ_DUMP_PATH.
    private static func writeAdjacencyDumpIfBenching(
        rows: [[String: Any]],
        messages: [VernacularMessage],
        config: VernacularConfig
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["HOURGLASS_PANEL_BENCH"] != nil else { return }
        let path = env["HOURGLASS_ADJ_DUMP_PATH"] ?? "/tmp/hourglass-reclaimed-adjacency.json"
        let payload: [String: Any] = [
            "corpus": [
                "messageCount": messages.count,
                "firstID": messages.first?.messageID ?? -1,
                "lastID": messages.last?.messageID ?? -1,
            ],
            "configDefaults": [
                "keepThreshold": config.reclaimedContextKeepThreshold,
                "foldShare": config.reclaimedFoldShare,
                "compoundDropShare": config.reclaimedCompoundDropShare,
                "affinityFloor": config.reclaimedSlangAffinityFloor,
                "affinityCeil": config.reclaimedSlangAffinityCeil,
                "affinityBoost": config.reclaimedSlangAffinityBoost,
                "reclaimedMinUses": config.reclaimedMinUses,
                "reclaimedMinWorldEff": config.reclaimedMinWorldEff,
            ],
            "candidates": rows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("BENCH::   reclaimed.adjacencyDump → \(path) (\(rows.count) candidates)")
        fflush(stdout)
    }

    /// Operator-feedback pass: the collocation feature over-rewards words that
    /// ride ONE partner. Measured on the SAME sampled usage windows the
    /// verdicts used:
    ///   • FOLD — both halves are kept candidates and one is adjacent to the
    ///     other in ≥ `reclaimedFoldShare` of windows ("holy" + "bang") →
    ///     ONE folded bigram entry ("holy bang"), singles dropped.
    ///   • COMPOUND DROP — the partner is NOT a candidate and is adjacent in
    ///     ≥ `reclaimedCompoundDropShare` of windows ("jet lag") → the word is
    ///     riding a literal English compound, not a reclaimed sense; drop it.
    /// Words with real standalone usage survive: "cone" stays because its
    /// "traffic"-adjacent share sits well below the drop threshold.
    private static func foldAndDemote(
        _ kept: [VernacularProfileReclaimedWord],
        consideredBySurface: [String: VernacularProfileReclaimedWord],
        adjStats: [String: (before: Int, after: Int, coBefore: Int, coAfter: Int, total: Int)],
        config: VernacularConfig
    ) -> [VernacularProfileReclaimedWord] {
        guard !kept.isEmpty else { return kept }
        let keptBySurface = Dictionary(uniqueKeysWithValues: kept.map { ($0.surface, $0) })

        var consumed = Set<String>()
        var out: [VernacularProfileReclaimedWord] = []
        out.reserveCapacity(kept.count)

        for item in kept {
            if consumed.contains(item.surface) { continue }
            guard let partner = item.topCollocationPartner?.lowercased(),
                  !partner.isEmpty, partner != item.surface else {
                out.append(item)
                continue
            }
            let adj = adjStats[item.surface] ?? (0, 0, 0, 0, 0)
            guard adj.total > 0 else {
                out.append(item)
                continue
            }
            let share = Double(adj.before + adj.after) / Double(adj.total)
            let cooccurShare = Double(adj.coBefore + adj.coAfter) / Double(adj.total)

            // FOLD looks at the PRE-VERDICT candidate set: the bigram is the
            // unit that deserves evaluation, so "holy bang" forms even when
            // "bang" alone wouldn't survive the context filter (the folded
            // entry inherits the kept half's verdict). MUTUAL top-partnership
            // ("holy"↔"bang") is itself strong evidence the pair is one unit;
            // mutual pairs fold on window CO-OCCURRENCE — measured: holy/bang
            // ride the same messages while being adjacent in 0 of 30 sampled
            // windows, so adjacency alone can never see them.
            let isMutual = consideredBySurface[partner]?.topCollocationPartner?.lowercased() == item.surface
            let foldQualifies = share >= config.reclaimedFoldShare
                || (isMutual && cooccurShare >= config.reclaimedFoldCooccurShare)
            if let partnerItem = consideredBySurface[partner], !consumed.contains(partner),
               foldQualifies {
                // FOLD into the dominant word order ("holy bang") — adjacent
                // counts when present, else the co-occurrence positions.
                let beforeVotes = adj.before > 0 || adj.after > 0 ? adj.before : adj.coBefore
                let afterVotes = adj.before > 0 || adj.after > 0 ? adj.after : adj.coAfter
                let surface = beforeVotes >= afterVotes
                    ? "\(partner) \(item.surface)"
                    : "\(item.surface) \(partner)"
                let primary = partnerItem.score > item.score ? partnerItem : item
                let secondary = primary.surface == item.surface ? partnerItem : item
                var examples = primary.examples
                for example in secondary.examples where !examples.contains(example) {
                    examples.append(example)
                }
                out.append(VernacularProfileReclaimedWord(
                    id: "reclaimed:folded:\(surface)",
                    rank: primary.rank,
                    surface: surface,
                    score: max(item.score, partnerItem.score),
                    counts: primary.counts,
                    worldEff: max(item.worldEff, partnerItem.worldEff),
                    percentile: max(item.percentile, partnerItem.percentile),
                    collocation: max(item.collocation, partnerItem.collocation),
                    senseDistance: max(item.senseDistance, partnerItem.senseDistance),
                    roleSkew: primary.roleSkew,
                    concentration: primary.concentration,
                    topCollocationPartner: nil,
                    examples: Array(examples.prefix(3)),
                    contextVerdict: primary.contextVerdict,
                    contextSlangRate: primary.contextSlangRate,
                    contextTopicRate: primary.contextTopicRate,
                    contextKeepMargin: primary.contextKeepMargin
                ))
                consumed.insert(item.surface)
                consumed.insert(partner)
            } else if consideredBySurface[partner] == nil,
                      share >= config.reclaimedCompoundDropShare,
                      item.contextKeepMargin < (share >= 0.8
                          ? config.reclaimedCompoundHardProtectMargin
                          : 0.25) {
                // Riding a literal compound — drop. TWO TIERS, both margin-
                // protected (measured on the real dump): at share ≥ 0.8 only an
                // EMPHATIC margin survives — cone (0.80 share, +0.42 margin)
                // lives, lag (0.93, +0.32) dies; in the 0.6–0.8 band the
                // ordinary 0.25 protection applies.
                consumed.insert(item.surface)
            } else {
                out.append(item)
            }
        }

        return out.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.surface < $1.surface
        }
    }

    /// Partner position stats over EVERY subject occurrence of each wanted
    /// surface: ADJACENT counts (the bigram signal, split by side so a fold
    /// can pick the dominant order) and same-message CO-OCCURRENCE counts
    /// ("holy" and "bang" can ride the same messages without being adjacent).
    /// Deliberately UNCAPPED — a capped corpus-order sample misses
    /// collocations that emerged late in the corpus. One cheap pass.
    private static func fullAdjacencyStats(
        for wanted: Set<String>,
        partnerBySurface: [String: String],
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext
    ) -> [String: (before: Int, after: Int, coBefore: Int, coAfter: Int, total: Int)] {
        var stats: [String: (before: Int, after: Int, coBefore: Int, coAfter: Int, total: Int)] = [:]
        stats.reserveCapacity(wanted.count)

        for message in messages where subjectContext.isSubjectMessage(message)
            && !message.isPoll
            && !message.words.isEmpty
            && !message.bodyLow.contains("http")
            && !message.wordSet.isDisjoint(with: wanted) {
            let words = message.words
            for (index, token) in words.enumerated() where wanted.contains(token) {
                var s = stats[token] ?? (0, 0, 0, 0, 0)
                s.total += 1
                if let partner = partnerBySurface[token] {
                    if index > 0 && words[index - 1] == partner { s.before += 1 }
                    if index + 1 < words.count && words[index + 1] == partner { s.after += 1 }
                    if let pIdx = words.firstIndex(of: partner), pIdx != index {
                        if pIdx < index { s.coBefore += 1 } else { s.coAfter += 1 }
                    }
                }
                stats[token] = s
            }
        }
        return stats
    }

    private static func trustedSlangTokens(
        from surfaces: Set<String>,
        excluding reclaimedSurfaces: Set<String>
    ) -> Set<String> {
        var tokens = builtInSlangTokens
        for surface in surfaces {
            let parts = surface.split(separator: " ").map(String.init)
            guard parts.count == 1, let token = parts.first else { continue }
            if token.count >= 2 && !reclaimedSurfaces.contains(token) {
                tokens.insert(token)
            }
        }
        return tokens
    }

    private static func collectWindows(
        for wanted: Set<String>,
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext,
        maxPerSurface: Int,
        radius: Int,
        strideBySurface: [String: Int] = [:]
    ) -> [String: [UsageWindow]] {
        guard !wanted.isEmpty else { return [:] }
        var windows: [String: [UsageWindow]] = [:]
        windows.reserveCapacity(wanted.count)
        // Deterministic spread: take every stride-th qualifying occurrence so
        // a 700-use word samples its whole timeline, not its first month.
        var occurrenceIndex: [String: Int] = [:]

        for message in messages where subjectContext.isSubjectMessage(message)
            && !message.isPoll
            && !message.words.isEmpty
            && !message.bodyLow.contains("http")
            && !message.wordSet.isDisjoint(with: wanted) {
            var seenInMessage = Set<String>()
            for (index, token) in message.words.enumerated() where wanted.contains(token) {
                guard !seenInMessage.contains(token) else { continue }
                seenInMessage.insert(token)
                let occurrence = occurrenceIndex[token, default: 0]
                occurrenceIndex[token] = occurrence + 1
                let stride = max(strideBySurface[token] ?? 1, 1)
                guard occurrence % stride == 0 else { continue }
                let currentCount = windows[token]?.count ?? 0
                guard currentCount < maxPerSurface else { continue }
                let lower = max(0, index - radius)
                let upper = min(message.words.count, index + radius + 1)
                var slice = Array(message.words[lower..<upper])
                let local = index - lower
                if slice.indices.contains(local) {
                    slice[local] = targetToken
                }
                let text = clipped(message.body)
                windows[token, default: []].append(UsageWindow(surface: token,
                                                               tokens: slice,
                                                               text: text,
                                                               amused: message.amused,
                                                               laughed: message.laughed))
            }
        }
        return windows
    }

    private static func decide(
        item: VernacularProfileReclaimedWord,
        windows: [UsageWindow],
        slangTokens: Set<String>,
        prototypes: [CategoryPrototype],
        slangAffinityAddend: Double,
        embedding: NLEmbedding?,
        tagger: NLTagger,
        config: VernacularConfig
    ) -> VernacularReclaimedContextDecision {
        let count = max(windows.count, 1)
        var slangSum = 0.0
        var topicSum = 0.0
        var namedEntityCount = 0
        var bestExample: String?
        var bestMargin = -Double.infinity

        for window in windows {
            let score = scoreWindow(window, slangTokens: slangTokens, tagger: tagger)
            slangSum += score.slang
            topicSum += score.topic
            if score.namedEntity { namedEntityCount += 1 }
            let margin = score.slang - score.topic
            if margin > bestMargin {
                bestMargin = margin
                bestExample = window.text
            }
        }

        var slangRate = windows.isEmpty ? 0 : clamp01(slangSum / Double(count))
        let averageTopic = windows.isEmpty ? 0 : clamp01(topicSum / Double(count))
        let namedEntityRate = windows.isEmpty ? 0 : Double(namedEntityCount) / Double(count)
        let category = categoryProximity(for: item.surface,
                                         prototypes: prototypes,
                                         embedding: embedding)
        let categoryTopic = category * config.reclaimedContextCategoryWeight
        var topicRate = clamp01(averageTopic + categoryTopic)

        // Target-level slang affinity: how close the WORD ITSELF sits to the
        // centroid of the subject's OWN discovered slang in embedding space,
        // through a soft ramp (a minor cutoff, annealed — not a binary list).
        // Computed by the caller so the bench dump can record the raw cosine.
        slangRate = clamp01(slangRate + slangAffinityAddend)
        if item.collocation >= 0.55 && topicRate < config.reclaimedContextTopicThreshold {
            slangRate = clamp01(slangRate + item.collocation * config.reclaimedContextCollocationBoost)
        }

        let keepMargin = slangRate - topicRate
        var verdict: VernacularReclaimedContextVerdict
        if keepMargin >= config.reclaimedContextKeepThreshold {
            verdict = .keep
        } else if topicRate >= config.reclaimedContextTopicThreshold && keepMargin < config.reclaimedContextKeepThreshold {
            verdict = .remove
        } else {
            verdict = .neutral
        }
        // Contact-mode statistical rescue: with few sampled windows the
        // margin is noise, so a near-miss with STRONG statistics — the
        // subject uses it far more than the people around them (role-skew)
        // AND it clears the full world-effect bar — is kept on the evidence
        // the window scorer can't see. Category proximity blocks the rescue:
        // a contact's signature TOPICS (max epochs, transformer decoder) also
        // have high role-skew, but they sit near the topic prototypes where
        // slang (sheesh) sits near nothing.
        if verdict != .keep,
           config.reclaimedContactRescueEnabled,
           keepMargin >= config.reclaimedRescueMarginFloor,
           item.roleSkew >= config.reclaimedRescueRoleSkew,
           item.worldEff >= config.reclaimedMinWorldEff,
           category <= 0.30 {
            verdict = .keep
        }

        return VernacularReclaimedContextDecision(
            id: "reclaimed-context:\(item.surface)",
            surface: item.surface,
            rank: item.rank,
            verdict: verdict,
            slangRate: slangRate,
            topicRate: topicRate,
            keepMargin: keepMargin,
            topicCategoryProximity: category,
            namedEntityRate: namedEntityRate,
            windows: windows.count,
            topCollocationPartner: item.topCollocationPartner,
            example: bestExample ?? item.examples.first
        )
    }

    private static func scoreWindow(
        _ window: UsageWindow,
        slangTokens: Set<String>,
        tagger: NLTagger
    ) -> WindowScore {
        var slang = 0.0
        var topic = 0.0
        let tokenSet = Set(window.tokens)

        let slangHits = tokenSet.intersection(slangTokens).count
        if slangHits > 0 {
            slang += min(0.70, Double(slangHits) * 0.28)
        }

        let reactiveHits = tokenSet.intersection(reactiveTokens).count
        if reactiveHits > 0 {
            slang += min(0.55, Double(reactiveHits) * 0.16)
        }

        if hasPhrase(["no", "way"], in: window.tokens)
            || hasPhrase(["so", targetToken], in: window.tokens)
            || hasPhrase([targetToken, "asf"], in: window.tokens)
            || hasPhrase([targetToken, "af"], in: window.tokens) {
            slang += 0.25
        }

        if window.laughed { slang += 0.25 }
        else if window.amused { slang += 0.12 }
        if window.tokens.count <= 8 && slang > 0 {
            slang += 0.12
        }

        let topicHits = tokenSet.intersection(topicTokens).count
        if topicHits > 0 {
            topic += min(0.75, Double(topicHits) * 0.28)
        }

        let named = hasNamedEntity(in: window.text, tagger: tagger)
        if named { topic += 0.38 }
        if window.tokens.count >= 12 && topicHits > 0 {
            topic += 0.12
        }

        return WindowScore(slang: clamp01(slang),
                           topic: clamp01(topic),
                           namedEntity: named)
    }

    private static func hasPhrase(_ phrase: [String], in tokens: [String]) -> Bool {
        guard phrase.count > 1, tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) {
            var matches = true
            for offset in phrase.indices where tokens[start + offset] != phrase[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    private static func hasNamedEntity(in text: String, tagger: NLTagger) -> Bool {
        guard !text.isEmpty else { return false }
        tagger.string = text
        var found = false
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .nameType,
                             options: options) { tag, _ in
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// Centroid of the SUBJECT'S OWN discovered slang in static embedding
    /// space — the data-driven replacement for the old hardcoded slang-cue
    /// word list. `slangTokens` is already per-subject (their discovered
    /// words/circle slang/template anchors plus the closed-class built-ins).
    /// Needs a handful of in-vocabulary tokens to be meaningful; returns nil
    /// otherwise so callers skip the boost gracefully.
    private static func buildSlangCentroid(
        from slangTokens: Set<String>,
        embedding: NLEmbedding?
    ) -> [Double]? {
        guard let embedding else { return nil }
        var centroid: [Double] = []
        var count = 0.0
        for token in slangTokens {
            guard let vector = embedding.vector(for: token) else { continue }
            if centroid.isEmpty {
                centroid = vector
            } else if centroid.count == vector.count {
                for index in vector.indices {
                    centroid[index] += vector[index]
                }
            } else {
                continue
            }
            count += 1
        }
        guard count >= 3, !centroid.isEmpty else { return nil }
        for index in centroid.indices {
            centroid[index] /= count
        }
        return centroid
    }

    private static func buildCategoryPrototypes(embedding: NLEmbedding?) -> [CategoryPrototype] {
        guard let embedding else { return [] }
        var out: [CategoryPrototype] = []
        out.reserveCapacity(categorySeeds.count)
        for category in categorySeeds {
            var centroid: [Double] = []
            var count = 0.0
            for seed in category.seeds {
                guard let vector = embedding.vector(for: seed) else { continue }
                if centroid.isEmpty {
                    centroid = vector
                } else if centroid.count == vector.count {
                    for index in vector.indices {
                        centroid[index] += vector[index]
                    }
                }
                count += 1
            }
            guard count > 0, !centroid.isEmpty else { continue }
            for index in centroid.indices {
                centroid[index] /= count
            }
            out.append(CategoryPrototype(name: category.name, vector: centroid, weight: category.weight))
        }
        return out
    }

    private static func categoryProximity(
        for token: String,
        prototypes: [CategoryPrototype],
        embedding: NLEmbedding?
    ) -> Double {
        guard !prototypes.isEmpty,
              let embedding,
              let vector = embedding.vector(for: token)
        else { return 0 }
        var best = 0.0
        for proto in prototypes where proto.vector.count == vector.count {
            let sim = cosineSimilarity(vector, proto.vector)
            let normalized = clamp01((sim - 0.18) / 0.50) * proto.weight
            best = max(best, normalized)
        }
        return clamp01(best)
    }

    private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    private static func copy(
        _ item: VernacularProfileReclaimedWord,
        verdict: VernacularReclaimedContextVerdict,
        slangRate: Double,
        topicRate: Double,
        keepMargin: Double
    ) -> VernacularProfileReclaimedWord {
        VernacularProfileReclaimedWord(
            id: item.id,
            rank: item.rank,
            surface: item.surface,
            score: item.score,
            counts: item.counts,
            worldEff: item.worldEff,
            percentile: item.percentile,
            collocation: item.collocation,
            senseDistance: item.senseDistance,
            roleSkew: item.roleSkew,
            concentration: item.concentration,
            topCollocationPartner: item.topCollocationPartner,
            examples: item.examples,
            contextVerdict: verdict,
            contextSlangRate: slangRate,
            contextTopicRate: topicRate,
            contextKeepMargin: keepMargin
        )
    }

    private static func rerank(_ items: [VernacularProfileReclaimedWord]) -> [VernacularProfileReclaimedWord] {
        items.enumerated().map { index, item in
            VernacularProfileReclaimedWord(
                id: item.id,
                rank: index + 1,
                surface: item.surface,
                score: item.score,
                counts: item.counts,
                worldEff: item.worldEff,
                percentile: item.percentile,
                collocation: item.collocation,
                senseDistance: item.senseDistance,
                roleSkew: item.roleSkew,
                concentration: item.concentration,
                topCollocationPartner: item.topCollocationPartner,
                examples: item.examples,
                contextVerdict: item.contextVerdict,
                contextSlangRate: item.contextSlangRate,
                contextTopicRate: item.contextTopicRate,
                contextKeepMargin: item.contextKeepMargin
            )
        }
    }

    private static func clipped(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(220))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
