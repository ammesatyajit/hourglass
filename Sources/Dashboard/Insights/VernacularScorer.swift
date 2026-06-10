//
//  VernacularScorer.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

enum VernacularScorer {
    static func scoreWords(
        _ candidates: [VernacularPhraseCandidate],
        subject: VernacularSubject,
        config: VernacularConfig
    ) -> [VernacularProfilePhrase] {
        let scored = candidates
            .filter { $0.n == 1 }
            .map { makePhraseItem(candidate: $0, subject: subject,
                                  idPrefix: "word", mode: .idiolect, config: config) }
            .sorted(by: phraseSort)
        return Array(scored.prefix(config.topWordCount)).enumerated().map { index, item in
            rerankPhrase(item, rank: index + 1)
        }
    }

    static func scoreCircleSlang(
        _ candidates: [VernacularPhraseCandidate],
        subject: VernacularSubject,
        config: VernacularConfig
    ) -> [VernacularProfilePhrase] {
        let scored = candidates
            .map { makePhraseItem(candidate: $0, subject: subject,
                                  idPrefix: "circle", mode: .circle, config: config) }
            .sorted(by: phraseSort)
        let dedupBudget = max(config.topCircleSlangCount * 8, 400)
        let deduped = dedupPhrases(Array(scored.prefix(dedupBudget)), config: config)
        return Array(deduped.prefix(config.topCircleSlangCount)).enumerated().map { index, item in
            rerankPhrase(item, rank: index + 1)
        }
    }

    static func scorePhrases(
        _ candidates: [VernacularPhraseCandidate],
        subject: VernacularSubject,
        config: VernacularConfig,
        slangSurfaces: Set<String> = []
    ) -> [VernacularProfilePhrase] {
        let scored = candidates
            .filter { $0.n >= 2 }
            .map { makePhraseItem(candidate: $0, subject: subject,
                                  idPrefix: "phrase", mode: .idiolect, config: config,
                                  slangSurfaces: slangSurfaces) }
            .sorted(by: phraseSort)
        let dedupBudget = max(config.topPhraseCount * 8, 400)
        let deduped = dedupPhrases(Array(scored.prefix(dedupBudget)), config: config)
        return Array(deduped.prefix(config.topPhraseCount)).enumerated().map { index, item in
            rerankPhrase(item, rank: index + 1)
        }
    }

    static func scoreReclaimedWords(
        _ candidates: [VernacularPhraseCandidate],
        subject: VernacularSubject,
        config: VernacularConfig,
        limit: Int? = nil
    ) -> [VernacularProfileReclaimedWord] {
        let outputLimit = max(0, limit ?? config.reclaimedWordCount)
        guard outputLimit > 0 else { return [] }
        let scored = candidates
            .filter { isReclaimedCandidate($0, config: config) }
            .map { makeReclaimedWord(candidate: $0, subject: subject, config: config) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.percentile != $1.percentile { return $0.percentile > $1.percentile }
                if $0.worldEff != $1.worldEff { return $0.worldEff > $1.worldEff }
                if $0.counts.userMessages != $1.counts.userMessages {
                    return $0.counts.userMessages > $1.counts.userMessages
                }
                return $0.surface < $1.surface
            }

        return Array(scored.prefix(outputLimit)).enumerated().map { index, item in
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

    static func scoreTopics(
        _ candidates: [VernacularPhraseCandidate],
        subject: VernacularSubject,
        config: VernacularConfig
    ) -> [VernacularProfilePhrase] {
        let scored = candidates
            .map { makePhraseItem(candidate: $0, subject: subject,
                                  idPrefix: "topic", mode: .topic, config: config) }
            .sorted(by: phraseSort)
        return Array(scored.prefix(min(config.topPhraseCount, 40))).enumerated().map { index, item in
            rerankPhrase(item, rank: index + 1)
        }
    }

    static func scoreTemplates(
        _ candidates: [VernacularTemplateCandidate],
        subject: VernacularSubject,
        config: VernacularConfig
    ) -> [VernacularProfileTemplate] {
        let scored = candidates.map { candidate -> VernacularProfileTemplate in
            let components = templateComponents(candidate: candidate, config: config)
            let features = VernacularProfileFeatures(
                length: components.length,
                peopleIDF: candidate.peopleIDF,
                selfUsage: components.role,
                rarity: components.zWorldFeature,
                recency: components.recency,
                spamResistance: candidate.spamResistance,
                glue: 0,
                collocation: 0,
                semanticShift: 0,
                registerPenalty: 0,
                style: 0,
                topic: components.topic,
                zWorld: candidate.zWorld,
                zRole: candidate.zRole,
                dispersion: candidate.userDispersion,
                echo: candidate.echo,
                burst: candidate.burst,
                productivity: candidate.productivity,
                anchorDistinctiveness: candidate.anchorDistinctiveness,
                embedding: candidate.embedding,
                finalScore: components.final
            )
            let counts = VernacularProfileCounts(
                userMessages: candidate.userMessages,
                receivedMessages: candidate.receivedMessages,
                activeContactUsers: candidate.activeContactUsers,
                distinctUserDays: candidate.distinctUserDays,
                effectiveUserMessages: candidate.effectiveUserMessages,
                maxUserDayShare: candidate.maxUserDayShare,
                maxMonthShare: candidate.maxMonthShare,
                effectiveContacts: candidate.effectiveContacts,
                effectiveChats: candidate.effectiveChats,
                worldMessages: candidate.worldMessages,
                recentUserMessages: candidate.recentUserMessages,
                olderUserMessages: candidate.olderUserMessages
            )
            return VernacularProfileTemplate(
                id: "template:\(subject.idComponent):\(candidate.pattern)",
                rank: 0,
                pattern: candidate.pattern,
                anchors: candidate.anchors,
                slotCount: candidate.slotCount,
                score: components.final,
                features: features,
                counts: counts,
                topFills: candidate.topFills,
                examples: candidate.examples
            )
        }

        let sorted = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.counts.userMessages != $1.counts.userMessages {
                return $0.counts.userMessages > $1.counts.userMessages
            }
            return $0.pattern < $1.pattern
        }
        let deduped = dedupTemplates(sorted)
        return Array(deduped.prefix(config.topTemplateCount)).enumerated().map { index, item in
            VernacularProfileTemplate(
                id: item.id,
                rank: index + 1,
                pattern: item.pattern,
                anchors: item.anchors,
                slotCount: item.slotCount,
                score: item.score,
                features: item.features,
                counts: item.counts,
                topFills: item.topFills,
                examples: item.examples
            )
        }
    }

    private enum PhraseMode {
        case idiolect
        case circle
        case topic
    }

    private static let reclaimedProperNounStoplist: Set<String> = [
        "palo", "alto", "santa", "monica", "claude", "bruin", "bruins",
        "salesforce", "stanford", "berkeley", "ucla", "usc", "google",
        "apple", "tesla", "cactus", "phoenix"
    ]

    private static let reclaimedProperPhraseStoplist: Set<String> = [
        "palo alto", "palo verde", "phoenix peak", "santa monica",
        "los angeles", "san francisco", "new york", "uc berkeley",
        "berkeley bowl", "stanford mall", "ucla campus", "usc campus"
    ]

    private static let reclaimedPlaceTailStoplist: Set<String> = [
        "alto", "verde", "peak", "monica", "angeles", "francisco",
        "york", "campus", "mall", "bowl"
    ]

    private static let reclaimedOrdinalSuffixes: Set<String> = [
        "st", "nd", "rd", "th"
    ]

    private static let reclaimedMonthTokens: Set<String> = [
        "jan", "january", "feb", "february", "mar", "march", "apr", "april",
        "may", "jun", "june", "jul", "july", "aug", "august", "sep",
        "sept", "september", "oct", "october", "nov", "november", "dec",
        "december"
    ]

    private struct PhraseComponents {
        let length: Double
        let role: Double
        let zWorldFeature: Double
        let recency: Double
        let glue: Double
        let dispersion: Double
        let topic: Double
        let final: Double
    }

    private static func makePhraseItem(
        candidate: VernacularPhraseCandidate,
        subject: VernacularSubject,
        idPrefix: String,
        mode: PhraseMode,
        config: VernacularConfig,
        slangSurfaces: Set<String> = []
    ) -> VernacularProfilePhrase {
        let components = phraseComponents(candidate: candidate, mode: mode, config: config)
        // Operator feedback: slang-bearing phrases ("are we deadass", "yuh sg")
        // should outrank logistics scaffolding ("lmk when ur"). Boost by the
        // share of tokens that are themselves discovered slang (words ∪ circle
        // slang ∪ reclaimed surfaces). The share rides the `style` feature slot
        // (unused for phrases) so the bench can show it.
        var slangShare = 0.0
        if mode == .idiolect, !slangSurfaces.isEmpty, !candidate.tokens.isEmpty {
            let hits = candidate.tokens.filter { slangSurfaces.contains($0) }.count
            slangShare = Double(hits) / Double(candidate.tokens.count)
        }
        let finalScore = components.final + config.phraseSlangWeight * slangShare
        let features = VernacularProfileFeatures(
            length: components.length,
            peopleIDF: candidate.peopleIDF,
            selfUsage: components.role,
            rarity: components.zWorldFeature,
            recency: components.recency,
            spamResistance: candidate.spamResistance,
            glue: components.glue,
            collocation: candidate.n == 1 ? candidate.collocation : 0,
            semanticShift: candidate.semanticShift,
            registerPenalty: candidate.registerPenalty,
            style: slangShare,
            topic: components.topic,
            zWorld: candidate.zWorld,
            zRole: candidate.zRole,
            dispersion: components.dispersion,
            echo: candidate.echo,
            burst: candidate.burst,
            productivity: 0,
            anchorDistinctiveness: 0,
            embedding: candidate.embedding,
            finalScore: finalScore
        )
        let counts = VernacularProfileCounts(
            userMessages: candidate.userMessages,
            receivedMessages: candidate.receivedMessages,
            activeContactUsers: candidate.activeContactUsers,
            distinctUserDays: candidate.distinctUserDays,
            effectiveUserMessages: candidate.effectiveUserMessages,
            maxUserDayShare: candidate.maxUserDayShare,
            maxMonthShare: candidate.maxMonthShare,
            effectiveContacts: candidate.effectiveContacts,
            effectiveChats: candidate.effectiveChats,
            worldMessages: candidate.worldMessages,
            recentUserMessages: candidate.recentUserMessages,
            olderUserMessages: candidate.olderUserMessages
        )
        return VernacularProfilePhrase(
            id: "\(idPrefix):\(subject.idComponent):\(candidate.surface)",
            rank: 0,
            surface: candidate.surface,
            tokens: candidate.tokens,
            n: candidate.n,
            score: finalScore,
            features: features,
            counts: counts,
            examples: candidate.examples
        )
    }

    /// Reclaimed = REPURPOSED NORMAL ENGLISH. The static-embedding rescue
    /// exists for real words the baseline misses — NOT for acronym/texting
    /// tokens (wbu/ofc/lmk), which were flooding CONTACTS' reclaimed lists
    /// (operator item 6; they stay eligible for words/circle slang). A
    /// real-word shape: at least 4 characters and at least one vowel.
    private static func isRealWordShaped(_ surface: String) -> Bool {
        guard surface.count >= 4 else { return false }
        return surface.contains(where: { "aeiouy".contains($0) })
    }

    private static func isReclaimedCandidate(
        _ candidate: VernacularPhraseCandidate,
        config: VernacularConfig
    ) -> Bool {
        guard candidate.n == 1 else { return false }
        let baselineAdmitted = candidate.baselineKnown
            && candidate.baselineProbability >= config.reclaimedMinBaselineProbability
        let staticEmbeddingRescue = !candidate.baselineKnown
            && candidate.hasStaticEmbeddingVector
            && candidate.reclaimedSenseDistance >= config.reclaimedSenseAdmitFloor
            && isRealWordShaped(candidate.surface)
        guard baselineAdmitted || staticEmbeddingRescue else { return false }
        guard candidate.userMessages >= config.reclaimedMinUses else { return false }
        guard candidate.registerPenalty <= 0 else { return false }
        guard candidate.zWorld >= config.reclaimedMinWorldEff else { return false }
        guard !isReclaimedProperNounish(candidate.surface,
                                        partner: candidate.topCollocationPartner) else { return false }
        return true
    }

    private static func makeReclaimedWord(
        candidate: VernacularPhraseCandidate,
        subject: VernacularSubject,
        config: VernacularConfig
    ) -> VernacularProfileReclaimedWord {
        let over = clamp01(candidate.zWorld / max(config.zScoreScale, 0.1))
        let percentile = clamp01(candidate.reclaimedPercentile)
        let percentileFeature = clamp01(percentile / max(config.reclaimedKeepPercentile, 0.01))
        let collocation = clamp01(candidate.collocation)
        let roleSkew = clamp01(abs(candidate.zRole) / max(config.roleLogitScale * 3.0, 0.1))
        let concentration = clamp01(1.0 - max(candidate.userDispersion, candidate.circleDispersion))
        let senseDistance = clamp01(candidate.reclaimedSenseDistance)
        let frequency = clamp01(log(Double(candidate.userMessages) + 1.0) / log(1_000.0))
        // Steadiness: 1 - peak-month share. High = used across many months (durable
        // vernacular); low = concentrated in one bursty window (recent topic/jargon).
        let steadiness = clamp01(1.0 - candidate.maxMonthShare)
        let score = weightedAverage([
            (percentileFeature, config.reclaimedPercentileWeight),
            (over, config.reclaimedWeightOver),
            (collocation, config.reclaimedWeightColloc),
            (roleSkew, config.reclaimedWeightRole),
            (concentration, config.reclaimedWeightDisp),
            (senseDistance, config.reclaimedWeightSense),
            (frequency, config.reclaimedWeightFreq),
            (steadiness, config.reclaimedWeightSteady)
        ])
        return VernacularProfileReclaimedWord(
            id: "reclaimed:\(subject.idComponent):\(candidate.surface)",
            rank: 0,
            surface: candidate.surface,
            score: score,
            counts: profileCounts(candidate),
            worldEff: candidate.zWorld,
            percentile: percentile,
            collocation: collocation,
            senseDistance: senseDistance,
            roleSkew: roleSkew,
            concentration: concentration,
            topCollocationPartner: candidate.topCollocationPartner,
            examples: candidate.examples
        )
    }

    private static func isReclaimedProperNounish(_ token: String, partner: String?) -> Bool {
        if reclaimedProperNounStoplist.contains(token) { return true }
        if token.count <= 1 { return true }
        if token.contains(where: { $0.isNumber }) { return true }
        if isReclaimedDateArtifact(surface: token, partner: partner) { return true }
        guard let partner = partner, !partner.isEmpty else { return false }
        if isReclaimedDateArtifact(surface: partner, partner: token) { return true }
        let forward = "\(token) \(partner)"
        let reverse = "\(partner) \(token)"
        if reclaimedProperPhraseStoplist.contains(forward)
            || reclaimedProperPhraseStoplist.contains(reverse) {
            return true
        }
        if reclaimedProperNounStoplist.contains(partner)
            && reclaimedPlaceTailStoplist.contains(token) {
            return true
        }
        if reclaimedProperNounStoplist.contains(token)
            && reclaimedPlaceTailStoplist.contains(partner) {
            return true
        }
        return false
    }

    private static func isReclaimedDateArtifact(surface: String, partner: String?) -> Bool {
        if reclaimedOrdinalSuffixes.contains(surface) { return true }
        guard let partner else { return false }
        if reclaimedOrdinalSuffixes.contains(partner) { return true }
        let surfaceIsMonth = reclaimedMonthTokens.contains(surface)
        let partnerIsMonth = reclaimedMonthTokens.contains(partner)
        if surfaceIsMonth && (reclaimedOrdinalSuffixes.contains(partner) || isNumericToken(partner)) {
            return true
        }
        if partnerIsMonth && (reclaimedOrdinalSuffixes.contains(surface) || isNumericToken(surface)) {
            return true
        }
        return false
    }

    private static func isNumericToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber }
    }

    private static func profileCounts(_ candidate: VernacularPhraseCandidate) -> VernacularProfileCounts {
        VernacularProfileCounts(
            userMessages: candidate.userMessages,
            receivedMessages: candidate.receivedMessages,
            activeContactUsers: candidate.activeContactUsers,
            distinctUserDays: candidate.distinctUserDays,
            effectiveUserMessages: candidate.effectiveUserMessages,
            maxUserDayShare: candidate.maxUserDayShare,
            maxMonthShare: candidate.maxMonthShare,
            effectiveContacts: candidate.effectiveContacts,
            effectiveChats: candidate.effectiveChats,
            worldMessages: candidate.worldMessages,
            recentUserMessages: candidate.recentUserMessages,
            olderUserMessages: candidate.olderUserMessages
        )
    }

    private static func phraseComponents(
        candidate: VernacularPhraseCandidate,
        mode: PhraseMode,
        config: VernacularConfig
    ) -> PhraseComponents {
        let length = pow(Double(candidate.n) / Double(max(config.maxNgramLength, 1)),
                         config.lengthExponent)
        let zWorldFeature = squashPositive(candidate.zWorld, scale: config.zScoreScale)
        let role = logistic(candidate.zRole / config.roleLogitScale)
        let recency = squashPositive(candidate.rawRecency, scale: config.recencyLogScale)
        let glue = candidate.n >= 2 ? clamp01(candidate.glue) : 0
        let burstResistance = clamp01(1.0 - candidate.burst)
        let circleDispersion = clamp01(candidate.circleDispersion)
        let userDispersion = clamp01(candidate.userDispersion)
        let semanticShift = clamp01(candidate.semanticShift)
        let registerPenalty = clamp01(candidate.registerPenalty)
        let registerMultiplier = clamp01(1.0 - config.textingRegisterPenaltyStrength * registerPenalty)
        let worldAnchor = zWorldFeature * registerMultiplier
        let semanticAnchor = semanticShift
            * config.semanticShiftAnchorStrength
            * clamp01(1.0 - 0.70 * registerPenalty)
        let rankingAnchor = max(worldAnchor, semanticAnchor)
        let wordCollocation = candidate.n == 1
            ? clamp01(candidate.collocation) * collocationDamp(candidate: candidate,
                                                               zWorldFeature: zWorldFeature,
                                                               semanticShift: semanticShift,
                                                               config: config)
            : 0
        let topic = topicScore(zWorld: zWorldFeature,
                               dispersion: max(circleDispersion, userDispersion),
                               echo: candidate.echo,
                               burst: candidate.burst)

        let final: Double
        switch mode {
        case .idiolect:
            let support = weightedAverage([
                (1.0, config.weights.worldDistinctiveness),
                (role, config.weights.role),
                (userDispersion, config.weights.dispersion),
                (burstResistance, config.weights.burstResistance),
                (candidate.spamResistance, config.weights.spamResistance),
                (recency, config.weights.recency),
                (length, config.weights.length),
                (glue, candidate.n >= 2 ? config.weights.glue : 0),
                (wordCollocation, candidate.n == 1 ? config.weights.collocation : 0),
                (semanticShift, config.weights.semanticShift),
                (candidate.embedding, config.weights.embedding)
            ])
            final = rankingAnchor * support
            return PhraseComponents(length: length, role: role, zWorldFeature: zWorldFeature,
                                    recency: recency, glue: glue, dispersion: userDispersion,
                                    topic: topic, final: final)
        case .circle:
            let support = weightedAverage([
                (1.0, config.weights.worldDistinctiveness),
                (circleDispersion, config.weights.dispersion),
                (candidate.echo, config.weights.echo),
                (burstResistance, config.weights.burstResistance),
                (candidate.spamResistance, config.weights.spamResistance),
                (recency, config.weights.recency),
                (length, config.weights.length),
                (glue, candidate.n >= 2 ? config.weights.glue : 0),
                (semanticShift, candidate.n == 1 ? config.weights.semanticShift : 0),
                (candidate.embedding, config.weights.embedding)
            ])
            final = rankingAnchor * support
            return PhraseComponents(length: length, role: role, zWorldFeature: zWorldFeature,
                                    recency: recency, glue: glue, dispersion: circleDispersion,
                                    topic: topic, final: final)
        case .topic:
            return PhraseComponents(length: length, role: role, zWorldFeature: zWorldFeature,
                                    recency: recency, glue: glue,
                                    dispersion: max(circleDispersion, userDispersion),
                                    topic: topic, final: topic)
        }
    }

    private struct TemplateComponents {
        let length: Double
        let role: Double
        let zWorldFeature: Double
        let recency: Double
        let topic: Double
        let final: Double
    }

    private static func templateComponents(
        candidate: VernacularTemplateCandidate,
        config: VernacularConfig
    ) -> TemplateComponents {
        let size = Double(candidate.anchors.count + candidate.slotCount)
        let maxSize = Double(max(config.maxTemplateAnchors + config.maxTemplateSlots, 1))
        let length = pow(min(1, size / maxSize), config.lengthExponent)
        let role = logistic(candidate.zRole / config.roleLogitScale)
        let zWorldFeature = squashPositive(candidate.zWorld, scale: config.zScoreScale)
        let recency = squashPositive(candidate.rawRecency, scale: config.recencyLogScale)
        let burstResistance = clamp01(1.0 - candidate.burst)
        let topic = topicScore(zWorld: zWorldFeature,
                               dispersion: max(candidate.userDispersion, candidate.circleDispersion),
                               echo: candidate.echo,
                               burst: candidate.burst)
        let fillEntropyFloor = clamp01(config.minTemplateFillEntropyForCommonAnchor)
        let productiveCommonAnchor = config.allowProductiveCommonAnchorTemplates
            && candidate.fillEntropy >= fillEntropyFloor
            ? candidate.productivity * candidate.fillEntropy
            : 0
        let rankingAnchor = max(zWorldFeature, productiveCommonAnchor)
        let support = weightedAverage([
            (1.0, config.weights.worldDistinctiveness),
            (role, config.weights.role),
            (candidate.userDispersion, config.weights.dispersion),
            (burstResistance, config.weights.burstResistance),
            (candidate.spamResistance, config.weights.spamResistance),
            (candidate.productivity, config.weights.productivity),
            (candidate.anchorDistinctiveness, config.weights.anchorDistinctiveness),
            (recency, config.weights.recency),
            (length, config.weights.length),
            (candidate.embedding, config.weights.embedding)
        ])
        let final = rankingAnchor * support
        return TemplateComponents(length: length, role: role,
                                  zWorldFeature: zWorldFeature,
                                  recency: recency, topic: topic,
                                  final: final)
    }

    private static func dedupPhrases(
        _ items: [VernacularProfilePhrase],
        config: VernacularConfig
    ) -> [VernacularProfilePhrase] {
        var kept: [VernacularProfilePhrase] = []
        for item in items {
            var suppress = false
            for accepted in kept {
                if accepted.n > item.n,
                   containsSubsequence(accepted.tokens, item.tokens),
                   Double(accepted.counts.userMessages) / Double(max(item.counts.userMessages, 1)) >= config.subspanDominanceShare {
                    suppress = true
                    break
                }
                if accepted.n < item.n,
                   containsSubsequence(item.tokens, accepted.tokens),
                   Double(item.counts.userMessages) / Double(max(accepted.counts.userMessages, 1)) <= config.weakExpansionShare,
                   item.features.glue < config.minGlueForExpansion {
                    suppress = true
                    break
                }
            }
            if !suppress { kept.append(item) }
        }
        return kept
    }

    private static func dedupTemplates(_ items: [VernacularProfileTemplate]) -> [VernacularProfileTemplate] {
        var kept: [VernacularProfileTemplate] = []
        var seenExact = Set<String>()
        var seenAnchorShapes = Set<String>()
        for item in items {
            guard seenExact.insert(item.pattern).inserted else { continue }
            let anchorShape = item.anchors.joined(separator: " ") + "#slots:\(item.slotCount)"
            if seenAnchorShapes.contains(anchorShape) { continue }
            seenAnchorShapes.insert(anchorShape)
            kept.append(item)
        }
        return kept
    }

    private static func containsSubsequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        if haystack == needle { return true }
        var start = 0
        while start <= haystack.count - needle.count {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
            start += 1
        }
        return false
    }

    private static func phraseSort(_ lhs: VernacularProfilePhrase, _ rhs: VernacularProfilePhrase) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.n != rhs.n { return lhs.n > rhs.n }
        if lhs.counts.userMessages != rhs.counts.userMessages {
            return lhs.counts.userMessages > rhs.counts.userMessages
        }
        return lhs.surface < rhs.surface
    }

    private static func rerankPhrase(_ item: VernacularProfilePhrase, rank: Int) -> VernacularProfilePhrase {
        VernacularProfilePhrase(
            id: item.id,
            rank: rank,
            surface: item.surface,
            tokens: item.tokens,
            n: item.n,
            score: item.score,
            features: item.features,
            counts: item.counts,
            examples: item.examples
        )
    }

    private static func topicScore(zWorld: Double, dispersion: Double, echo: Double, burst: Double) -> Double {
        clamp01(zWorld * (1.0 - clamp01(dispersion)) * max(clamp01(burst), 1.0 - clamp01(echo)))
    }

    private static func collocationDamp(
        candidate: VernacularPhraseCandidate,
        zWorldFeature: Double,
        semanticShift: Double,
        config: VernacularConfig
    ) -> Double {
        guard candidate.n == 1 else { return 1 }
        let spread = max(clamp01(candidate.userDispersion), clamp01(candidate.circleDispersion))
        let social = clamp01(candidate.echo)
        let distinctiveness = max(clamp01(zWorldFeature), clamp01(semanticShift))
        var damp = 0.20 + 0.45 * spread + 0.20 * social + 0.25 * distinctiveness
        if candidate.userMessages < 12 { damp = min(damp, 0.45) }
        return clamp01(1.0 - config.mainWordCollocationDampStrength * (1.0 - clamp01(damp)))
    }

    private static func weightedAverage(_ pairs: [(Double, Double)]) -> Double {
        var numerator = 0.0
        var denominator = 0.0
        for (value, weight) in pairs where weight > 0 {
            numerator += clamp01(value) * weight
            denominator += weight
        }
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    private static func squashPositive(_ value: Double, scale: Double) -> Double {
        guard value > 0 else { return 0 }
        return 1.0 - exp(-value / max(scale, 0.000_001))
    }

    private static func logistic(_ x: Double) -> Double {
        1.0 / (1.0 + exp(-x))
    }

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}
