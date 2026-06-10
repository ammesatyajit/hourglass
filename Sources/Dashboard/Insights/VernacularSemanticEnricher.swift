//
//  VernacularSemanticEnricher.swift
//  Hourglass - Unified Vernacular Profile
//
//  Bounded post-extraction enrichment for Phase 1. This deliberately stays off
//  the n-gram/template hot paths: candidates are already capped, then only a
//  capped unigram shortlist receives semantic-shift/context-tightness features.
//

import Foundation

enum VernacularTextingRegister {
    private static let phrasePriors: [String: Double] = [
        "be able to": 0.95,
        "as long as": 0.95,
        "makes sense": 0.90,
        "make sense": 0.90,
        "reach out": 0.90,
        "reach out to": 0.95,
        "have no clue": 0.88,
        "no clue": 0.78,
        "not sure if": 0.92,
        "not sure": 0.82,
        "let me know": 0.78,
        "for sure": 0.72,
        "at the same": 0.88,
        "in terms of": 0.90,
        "kind of": 0.82,
        "sort of": 0.82
    ]

    private static let priors: [String: Double] = [
        // Near-universal texting-register abbreviations. These are shrinkage
        // priors, not hard exclusions; a strong semantic/collocation signal can
        // still rescue a real in-group sense.
        "u": 1.00, "ur": 1.00, "yr": 0.90, "yrs": 0.70,
        "rn": 0.98, "tmrw": 0.98, "tmr": 0.95, "tmrrow": 0.95,
        "tom": 0.65, "tn": 0.80, "gn": 0.80, "gm": 0.75,
        "ppl": 0.92, "alr": 0.88, "r": 0.85,
        "bc": 0.75, "bcz": 0.75, "cuz": 0.70, "coz": 0.70,
        "nvm": 0.72, "tho": 0.62, "thru": 0.62,
        "ok": 0.62, "okay": 0.50, "kk": 0.72, "k": 0.68
    ]

    static func penalty(for surface: String) -> Double {
        if let phrase = phrasePriors[surface] { return phrase }
        guard !surface.contains(" ") else {
            let toks = surface.split(separator: " ").map(String.init)
            guard !toks.isEmpty else { return 0 }
            let tokenAverage = toks.reduce(0.0) { $0 + (priors[$1] ?? 0) } / Double(toks.count)
            return tokenAverage >= 0.45 ? min(tokenAverage, 0.80) : 0
        }
        return priors[surface] ?? 0
    }
}

enum VernacularSemanticEnricher {
    private static let literalPrefix = "\u{1F}literal:"

    static func enrich(
        candidates: [VernacularPhraseCandidate],
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig
    ) -> [VernacularPhraseCandidate] {
        let registerAdjusted = candidates.map { candidate in
            candidate.withSemanticFeatures(
                semanticShift: candidate.semanticShift,
                registerPenalty: registerPenalty(for: candidate)
            )
        }

        guard config.enableSemanticShiftEmbeddings, config.weights.semanticShift > 0 else {
            return registerAdjusted
        }

        let targets = semanticTargets(from: registerAdjusted, config: config)
        guard !targets.isEmpty else { return registerAdjusted }

        let contexts = collectContexts(
            targets: Set(targets),
            messages: messages,
            subjectContext: subjectContext,
            config: config
        )
        guard !contexts.isEmpty else { return registerAdjusted }

        let semantic = semanticFeatures(contexts: contexts, orderedSurfaces: targets, config: config)
        guard !semantic.isEmpty else { return registerAdjusted }

        return registerAdjusted.map { candidate in
            guard candidate.n == 1, let feature = semantic[candidate.surface] else { return candidate }
            return candidate.withSemanticFeatures(
                semanticShift: max(candidate.semanticShift, feature),
                registerPenalty: candidate.registerPenalty
            )
        }
    }

    private static func registerPenalty(for candidate: VernacularPhraseCandidate) -> Double {
        let prior = max(candidate.registerPenalty, VernacularTextingRegister.penalty(for: candidate.surface))
        guard prior > 0 else { return 0 }
        let broadness = clamp01(candidate.circleDispersion * max(candidate.echo, 0.35))
        return clamp01(prior * (0.78 + 0.22 * broadness))
    }

    private static func semanticTargets(
        from candidates: [VernacularPhraseCandidate],
        config: VernacularConfig
    ) -> [String] {
        candidates
            .filter { $0.n == 1 && $0.userMessages >= config.minUserMessages }
            .sorted {
                let lhs = semanticPriority($0, config: config)
                let rhs = semanticPriority($1, config: config)
                if lhs != rhs { return lhs > rhs }
                if $0.userMessages != $1.userMessages { return $0.userMessages > $1.userMessages }
                return $0.surface < $1.surface
            }
            .prefix(config.semanticShiftCandidateLimit)
            .map { $0.surface }
    }

    private static func semanticPriority(_ candidate: VernacularPhraseCandidate, config: VernacularConfig) -> Double {
        let world = candidate.zWorld > 0 ? min(candidate.zWorld / max(config.zScoreScale, 0.1), 1.0) : 0
        let role = 1.0 / (1.0 + exp(-candidate.zRole / max(config.roleLogitScale, 0.1)))
        let count = min(log(Double(candidate.userMessages + 1)) / log(120.0), 1.0)
        let dispersion = max(candidate.userDispersion, candidate.circleDispersion)
        let register = candidate.registerPenalty
        return world * 0.42
            + candidate.collocation * 0.28
            + count * 0.22
            + role * 0.12
            + dispersion * 0.10
            - register * 0.10
    }

    private final class SurfaceContext {
        let surface: String
        var windows: [String] = []
        var contextTokenCounts: [String: Int] = [:]

        init(surface: String) {
            self.surface = surface
        }
    }

    private static func collectContexts(
        targets: Set<String>,
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig
    ) -> [String: SurfaceContext] {
        var contexts: [String: SurfaceContext] = [:]
        contexts.reserveCapacity(targets.count)
        for surface in targets.sorted() {
            contexts[surface] = SurfaceContext(surface: surface)
        }

        let occurrenceLimit = max(config.semanticShiftOccurrencesPerSurface, 1)
        let radius = max(config.semanticShiftContextRadius, 1)
        for message in messages where subjectAllowed(message, subjectContext: subjectContext) {
            let present = message.wordSet.intersection(targets).sorted()
            guard !present.isEmpty else { continue }
            for surface in present {
                guard let context = contexts[surface], context.windows.count < occurrenceLimit else { continue }
                var index = 0
                while index < message.words.count && context.windows.count < occurrenceLimit {
                    if message.words[index] == surface {
                        context.windows.append(maskedWindow(words: message.words, targetIndex: index, radius: radius))
                        addContextTokens(from: message.words, targetIndex: index, radius: radius, into: context)
                    }
                    index += 1
                }
            }
        }
        return contexts.filter { !$0.value.windows.isEmpty }
    }

    private static func subjectAllowed(_ message: VernacularMessage, subjectContext: VernacularSubjectContext) -> Bool {
        subjectContext.isSubjectMessage(message)
            && !message.isPoll
            && !message.bodyLow.contains("http")
            && !message.words.isEmpty
    }

    private static func maskedWindow(words: [String], targetIndex: Int, radius: Int) -> String {
        let lo = max(0, targetIndex - radius)
        let hi = min(words.count, targetIndex + radius + 1)
        var pieces: [String] = []
        pieces.reserveCapacity(hi - lo)
        for i in lo..<hi {
            pieces.append(i == targetIndex ? "_" : words[i])
        }
        return pieces.joined(separator: " ")
    }

    private static func addContextTokens(
        from words: [String],
        targetIndex: Int,
        radius: Int,
        into context: SurfaceContext
    ) {
        let lo = max(0, targetIndex - radius)
        let hi = min(words.count, targetIndex + radius + 1)
        for i in lo..<hi where i != targetIndex {
            let token = words[i]
            guard token.count >= 2,
                  !LinguisticStopwords.isStopword(token),
                  VernacularTextingRegister.penalty(for: token) < 0.7
            else { continue }
            context.contextTokenCounts[token, default: 0] += 1
        }
    }

    private static func semanticFeatures(
        contexts: [String: SurfaceContext],
        orderedSurfaces: [String],
        config: VernacularConfig
    ) -> [String: Double] {
        let vectorizer = NLContextEmbedder()
        guard vectorizer.isAvailable else { return [:] }

        let windowMap = vectorWindows(contexts: contexts, orderedSurfaces: orderedSurfaces)
        guard !windowMap.isEmpty else { return [:] }

        let vectors = vectorizer.vectors(for: windowMap)
        guard !vectors.isEmpty else { return [:] }

        var out: [String: Double] = [:]
        out.reserveCapacity(contexts.count)
        for surface in orderedSurfaces {
            guard let context = contexts[surface] else { continue }
            let literalKey = literalPrefix + surface
            let shift: Double
            if let usage = vectors[surface],
               let literal = vectors[literalKey],
               usage.count == literal.count {
                shift = clamp01(cosineDistance(usage, literal) / max(config.semanticShiftScale, 0.01))
            } else {
                shift = 0
            }
            let tightness = lexicalTightness(context.contextTokenCounts)
            let tightnessFeature = tightness * config.semanticContextTightnessWeight
            let countConfidence = 1.0 - exp(-Double(context.windows.count) / 12.0)
            let feature = max(shift, tightnessFeature) * countConfidence
            if feature > 0 {
                out[surface] = clamp01(feature)
            }
        }
        return out
    }

    private static func vectorWindows(
        contexts: [String: SurfaceContext],
        orderedSurfaces: [String]
    ) -> [String: [String]] {
        var out: [String: [String]] = [:]
        out.reserveCapacity(contexts.count)
        for surface in orderedSurfaces {
            guard let context = contexts[surface] else { continue }
            out[surface] = context.windows
            out[literalPrefix + surface] = literalWindows(for: surface)
        }
        return out
    }

    private static func literalWindows(for surface: String) -> [String] {
        [
            "this is a \(surface)",
            "i saw the \(surface)",
            "the \(surface) is there"
        ]
    }

    private static func lexicalTightness(_ counts: [String: Int]) -> Double {
        let total = counts.values.reduce(0, +)
        guard total > 0, counts.count > 1 else { return counts.isEmpty ? 0 : 1 }
        var entropy = 0.0
        for value in counts.values where value > 0 {
            let p = Double(value) / Double(total)
            entropy -= p * log(p)
        }
        let normalized = entropy / log(Double(max(counts.count, 2)))
        return clamp01(1.0 - normalized)
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for i in lhs.indices {
            let a = Double(lhs[i])
            let b = Double(rhs[i])
            dot += a * b
            lhsNorm += a * a
            rhsNorm += b * b
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        let cosine = dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
        return 1.0 - min(max(cosine, -1.0), 1.0)
    }

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}

private extension VernacularPhraseCandidate {
    func withSemanticFeatures(semanticShift: Double, registerPenalty: Double) -> VernacularPhraseCandidate {
        VernacularPhraseCandidate(
            surface: surface,
            tokens: tokens,
            n: n,
            userMessages: userMessages,
            receivedMessages: receivedMessages,
            worldMessages: worldMessages,
            activeContactUsers: activeContactUsers,
            distinctUserDays: distinctUserDays,
            effectiveUserMessages: effectiveUserMessages,
            maxUserDayShare: maxUserDayShare,
            maxMonthShare: maxMonthShare,
            effectiveContacts: effectiveContacts,
            effectiveChats: effectiveChats,
            userDispersion: userDispersion,
            circleDispersion: circleDispersion,
            echo: echo,
            burst: burst,
            recentUserMessages: recentUserMessages,
            olderUserMessages: olderUserMessages,
            rawSelfUsage: rawSelfUsage,
            rawRarity: rawRarity,
            rawRecency: rawRecency,
            zWorld: zWorld,
            zRole: zRole,
            peopleIDF: peopleIDF,
            spamResistance: spamResistance,
            glue: glue,
            collocation: collocation,
            topCollocationPartner: topCollocationPartner,
            reclaimedPercentile: reclaimedPercentile,
            reclaimedPercentileUsers: reclaimedPercentileUsers,
            reclaimedSenseDistance: reclaimedSenseDistance,
            hasStaticEmbeddingVector: hasStaticEmbeddingVector,
            baselineProbability: baselineProbability,
            baselineKnown: baselineKnown,
            semanticShift: min(max(semanticShift, 0), 1),
            registerPenalty: min(max(registerPenalty, 0), 1),
            embedding: min(max(semanticShift, 0), 1),
            examples: examples
        )
    }
}
