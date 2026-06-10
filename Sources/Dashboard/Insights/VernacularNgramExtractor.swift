//
//  VernacularNgramExtractor.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation
import NaturalLanguage

struct VernacularPhraseCandidate: Sendable, Equatable {
    let surface: String
    let tokens: [String]
    let n: Int
    let userMessages: Int
    let receivedMessages: Int
    let worldMessages: Int
    let activeContactUsers: Int
    let distinctUserDays: Int
    let effectiveUserMessages: Double
    let maxUserDayShare: Double
    let maxMonthShare: Double
    let effectiveContacts: Double
    let effectiveChats: Double
    let userDispersion: Double
    let circleDispersion: Double
    let echo: Double
    let burst: Double
    let recentUserMessages: Int
    let olderUserMessages: Int
    let rawSelfUsage: Double
    let rawRarity: Double
    let rawRecency: Double
    let zWorld: Double
    let zRole: Double
    let peopleIDF: Double
    let spamResistance: Double
    let glue: Double
    let collocation: Double
    let topCollocationPartner: String?
    /// Subject's per-capita percentile among qualifying users of this term.
    /// Used only by the reclaimed known-English surface.
    let reclaimedPercentile: Double
    /// Number of users in the percentile distribution before small-sample shrink.
    let reclaimedPercentileUsers: Int
    /// Static NLEmbedding sense-distance for reclaimed known-English words.
    let reclaimedSenseDistance: Double
    /// True when Apple's static English embedding knows this unigram.
    let hasStaticEmbeddingVector: Bool
    let baselineProbability: Double
    let baselineKnown: Bool
    /// Bounded semantic-shift feature from Apple embeddings/context tightness.
    let semanticShift: Double
    /// Shrinkage prior for near-universal texting register abbreviations.
    let registerPenalty: Double
    /// Legacy embedding feature slot; currently mirrors semanticShift for
    /// compatibility with older diagnostics/weights.
    let embedding: Double
    let examples: [String]
}

struct VernacularNgramExtractionResult: Sendable, Equatable {
    let candidates: [VernacularPhraseCandidate]
    let candidateHashCount: Int
    let exactCandidateCount: Int
    let activeContacts: Int
}

enum VernacularNgramExtractor {
    private struct CollocationInfo: Sendable, Equatable {
        let score: Double
        let partner: String
    }

    private struct StaticSenseInfo: Sendable, Equatable {
        let distance: Double
        let hasWordVector: Bool
    }

    private static let day: Double = 86_400
    private static let staticSensePartnerCap = 30
    private static let unknown = VernacularAnalyzer.unknownLabel
    private static let urlish: Set<String> = [
        "www", "com", "http", "https", "org", "net", "gg", "io", "co", "docs", "google"
    ]
    private static let literalSensePartners: Set<String> = [
        "a", "an", "the", "one", "two", "no", "not", "my", "your", "our", "their",
        "me", "you", "it", "this", "that", "these", "those", "is", "are", "was",
        "were", "be", "been", "being", "am", "up", "down", "in", "out", "on",
        "off", "to", "of", "for", "from", "with", "at", "by", "about", "as"
    ]

    static func extract(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig,
        tokenized: VernacularTokenizedCorpus? = nil
    ) -> VernacularNgramExtractionResult {
        let maxN = max(1, config.maxNgramLength)
        let nameTokens = VernacularAnalyzer.contactNameTokens(contacts)
        if let tokenized,
           tokenized.isValid(nameTokens: nameTokens, config: config, messageCount: messages.count) {
            return extractFromTokenized(messages: messages,
                                        baseline: baseline,
                                        subjectContext: subjectContext,
                                        config: config,
                                        tokenized: tokenized)
        }
        let corpusMaxDate = messages.map(\.date).max() ?? 0
        let recentCut = corpusMaxDate - 180 * day

        let benchEnabled = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil
        var lap = benchEnabled ? Date() : nil
        func lapMark(_ label: String) {
            guard benchEnabled, let start = lap else { return }
            print("BENCH::       \(label) \(Int(Date().timeIntervalSince(start) * 1000)) ms"); fflush(stdout)
            lap = Date()
        }

        var subjectMessageCount = 0
        var otherMessageCount = 0
        var worldMessageCount = 0
        var activeContactMessageCounts: [String: Int] = [:]
        var subjectUnigramCounts: [String: Int] = [:]
        var subjectUnigramTotal = 0.0
        var subjectSlotsByN = Array(repeating: 0, count: maxN + 1)
        var hashCounts: [UInt64: Int] = [:]

        for message in messages where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            let isSubject = subjectContext.isSubjectMessage(message)
            worldMessageCount += 1
            if isSubject {
                subjectMessageCount += 1
                for word in message.words {
                    subjectUnigramCounts[word, default: 0] += 1
                    subjectUnigramTotal += 1
                }
                let flags = tokenGateFlags(words: message.words, nameTokens: nameTokens)
                var seenHashes = Set<UInt64>()
                visitNgrams(words: message.words, maxN: maxN) { n, start, hash in
                    subjectSlotsByN[n] += 1
                    guard gramAllowed(flags: flags, start: start, n: n) else { return }
                    if seenHashes.insert(hash).inserted {
                        hashCounts[hash, default: 0] += 1
                    }
                }
            } else {
                otherMessageCount += 1
                let speaker = subjectContext.speakerLabel(message)
                if speaker != unknown {
                    activeContactMessageCounts[speaker, default: 0] += 1
                }
            }
        }
        lapMark("ngram.passA")

        let activeContacts = Set(activeContactMessageCounts.filter {
            $0.value >= config.activeContactMinMessages
        }.map { $0.key })

        let eligibleHashes = hashCounts
            .filter { $0.value >= config.minUserMessages }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(config.maxNgramHashCandidates)
            .map { $0.key }
        let eligible = Set(eligibleHashes)
        lapMark("ngram.eligibleSort")
        guard !eligible.isEmpty else {
            return VernacularNgramExtractionResult(candidates: [], candidateHashCount: 0,
                                                   exactCandidateCount: 0,
                                                   activeContacts: activeContacts.count)
        }

        var exact: [String: NgramAccumulator] = [:]
        exact.reserveCapacity(min(eligible.count, config.maxExactNgramCandidates))
        var acceptedHashes = Set<UInt64>()
        acceptedHashes.reserveCapacity(min(eligible.count, config.maxExactNgramCandidates))
        let exactLimit = config.maxExactNgramCandidates

        for message in messages where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            let isSubject = subjectContext.isSubjectMessage(message)
            let speaker = subjectContext.speakerLabel(message)
            var seenSurfaces = Set<String>()
            var flags: TokenGateFlags? = nil
            visitNgrams(words: message.words, maxN: maxN) { n, start, hash in
                guard eligible.contains(hash) else { return }
                if exact.count >= exactLimit && !acceptedHashes.contains(hash) { return }
                let resolved = flags ?? tokenGateFlags(words: message.words, nameTokens: nameTokens)
                flags = resolved
                guard gramAllowed(flags: resolved, start: start, n: n) else { return }
                let toks = Array(message.words[start..<(start + n)])
                let surface = toks.joined(separator: " ")
                guard seenSurfaces.insert(surface).inserted else { return }
                let accumulator: NgramAccumulator
                if let existing = exact[surface] {
                    accumulator = existing
                } else {
                    guard exact.count < exactLimit else { return }
                    accumulator = NgramAccumulator(surface: surface, tokens: toks, n: n)
                    exact[surface] = accumulator
                    acceptedHashes.insert(hash)
                }
                accumulator.observe(message: message,
                                    isSubject: isSubject,
                                    speaker: speaker,
                                    recentCut: recentCut,
                                    activeContacts: activeContacts,
                                    contactCap: config.maxDispersionContactsPerCandidate,
                                    chatCap: config.maxDispersionChatsPerCandidate,
                                    dayCap: config.maxDispersionDaysPerCandidate,
                                    monthCap: config.maxDispersionMonthsPerCandidate)
            }
        }
        lapMark("ngram.passB")

        let strongestCollocation = strongestUnigramCollocations(
            exact: exact,
            totalBigramSlots: Double(max(subjectSlotsByN.indices.contains(2) ? subjectSlotsByN[2] : 0, 1)),
            unigramCounts: subjectUnigramCounts,
            unigramTotal: max(subjectUnigramTotal, 1),
            config: config
        )
        let staticSense = staticSenseSignals(exact: exact, baseline: baseline, config: config)

        var candidates: [VernacularPhraseCandidate] = []
        candidates.reserveCapacity(exact.count)
        for (_, accumulator) in exact {
            guard accumulator.userMessages >= config.minUserMessages else { continue }
            let distinctDays = accumulator.userDayCounts.count
            guard accumulator.userMessages >= config.lowCountDayGate
                    || distinctDays >= config.minDistinctDaysForLowCount else { continue }

            let maxDayShare = accumulator.maxUserDayShare
            if maxDayShare > config.maxSingleDayShare && distinctDays < config.minDistinctDaysForLowCount + 1 {
                continue
            }

            let userRate = Double(accumulator.userMessages) / Double(max(subjectMessageCount, 1))
            let receivedRate = Double(accumulator.receivedMessages) / Double(max(otherMessageCount, 1))
            let rawSelfUsage = log((userRate + 0.000_001) / (receivedRate + 0.000_001))
            let rawRecency = log(Double(accumulator.recentUserMessages + 1) / Double(accumulator.olderUserMessages + 1))
            let baseProbability = baselineProbability(tokens: accumulator.tokens, baseline: baseline)
            let zWorld = worldLogOddsEffect(count: accumulator.worldMessages,
                                            total: max(worldMessageCount, 1),
                                            referenceProbability: baseProbability,
                                            config: config)
            let zRole = logOddsZ(aCount: accumulator.userMessages,
                                 aTotal: max(subjectMessageCount, 1),
                                 bCount: accumulator.receivedMessages,
                                 bTotal: max(otherMessageCount, 1))
            let slots = Double(max(subjectSlotsByN[accumulator.n], 1))
            let rawRarity = log((Double(accumulator.worldMessages) + 0.5) /
                                (Double(max(worldMessageCount, 1)) * baseProbability + 0.5))
            let glue = accumulator.n >= 2
                ? npmi(tokens: accumulator.tokens, count: accumulator.userMessages,
                       totalSlots: slots, unigramCounts: subjectUnigramCounts,
                       unigramTotal: max(subjectUnigramTotal, 1))
                : 0

            let contactUsers = accumulator.activeContactUsers(minUses: config.minContactUsesForDocumentFrequency)
            let peopleIDF = inverseDocumentFrequency(df: contactUsers, activeContacts: activeContacts.count)
            let effective = accumulator.effectiveUserMessages(dailyCap: config.dailyUserCap)
            let effectiveShare = Double(effective) / Double(max(accumulator.userMessages, 1))
            let dayPenalty = maxDayShare <= config.maxSingleDayShare
                ? 1.0
                : max(0.25, (1.0 - maxDayShare) / max(1.0 - config.maxSingleDayShare, 0.01))
            let spamResistance = clamp01(effectiveShare * dayPenalty)
            let effectiveContacts = accumulator.effectiveContacts
            let effectiveChats = accumulator.effectiveWorldChats
            let echo = activeContacts.isEmpty ? 0 : Double(contactUsers) / Double(activeContacts.count)
            let maxMonthShare = accumulator.maxMonthShare
            let burst = max(maxDayShare, maxMonthShare)
            let circleDispersion = accumulator.circleDispersion(context: subjectContext,
                                                                activeContactCount: activeContacts.count)
            let userDispersion = accumulator.userDispersion(context: subjectContext)
            let percentile = accumulator.n == 1
                ? reclaimedPercentile(
                    subjectUses: accumulator.userMessages,
                    subjectTotalMessages: subjectMessageCount,
                    contactUses: accumulator.contactCounts,
                    contactTotalMessages: activeContactMessageCounts,
                    minPerUserUses: config.reclaimedMinPerUserUses,
                    minUsersForPercentile: config.reclaimedMinUsersForPercentile
                )
                : (value: 0.5, users: 0)

            candidates.append(VernacularPhraseCandidate(
                surface: accumulator.surface,
                tokens: accumulator.tokens,
                n: accumulator.n,
                userMessages: accumulator.userMessages,
                receivedMessages: accumulator.receivedMessages,
                worldMessages: accumulator.worldMessages,
                activeContactUsers: contactUsers,
                distinctUserDays: distinctDays,
                effectiveUserMessages: effective,
                maxUserDayShare: maxDayShare,
                maxMonthShare: maxMonthShare,
                effectiveContacts: effectiveContacts,
                effectiveChats: effectiveChats,
                userDispersion: userDispersion,
                circleDispersion: circleDispersion,
                echo: clamp01(echo),
                burst: clamp01(burst),
                recentUserMessages: accumulator.recentUserMessages,
                olderUserMessages: accumulator.olderUserMessages,
                rawSelfUsage: rawSelfUsage,
                rawRarity: rawRarity,
                rawRecency: rawRecency,
                zWorld: zWorld,
                zRole: zRole,
                peopleIDF: peopleIDF,
                spamResistance: spamResistance,
                glue: max(0, glue),
                collocation: accumulator.n == 1 ? (strongestCollocation[accumulator.surface]?.score ?? 0) : 0,
                topCollocationPartner: accumulator.n == 1 ? strongestCollocation[accumulator.surface]?.partner : nil,
                reclaimedPercentile: accumulator.n == 1 ? percentile.value : 0.5,
                reclaimedPercentileUsers: accumulator.n == 1 ? percentile.users : 0,
                reclaimedSenseDistance: accumulator.n == 1 ? (staticSense[accumulator.surface]?.distance ?? 0) : 0,
                hasStaticEmbeddingVector: accumulator.n == 1 ? (staticSense[accumulator.surface]?.hasWordVector ?? false) : false,
                baselineProbability: accumulator.n == 1 ? baseline.probability(of: accumulator.surface) : baseProbability,
                baselineKnown: accumulator.n == 1 ? baseline.isKnown(accumulator.surface) : false,
                semanticShift: 0,
                registerPenalty: VernacularTextingRegister.penalty(for: accumulator.surface),
                embedding: 0,
                examples: accumulator.examples
            ))
        }

        candidates.sort {
            if $0.userMessages != $1.userMessages { return $0.userMessages > $1.userMessages }
            if $0.n != $1.n { return $0.n > $1.n }
            return $0.surface < $1.surface
        }
        lapMark("ngram.candidates")
        return VernacularNgramExtractionResult(
            candidates: candidates,
            candidateHashCount: eligible.count,
            exactCandidateCount: exact.count,
            activeContacts: activeContacts.count
        )
    }

    private static func extractFromTokenized(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig,
        tokenized: VernacularTokenizedCorpus
    ) -> VernacularNgramExtractionResult {
        let maxN = max(1, config.maxNgramLength)
        let corpusMaxDate = messages.map(\.date).max() ?? 0
        let recentCut = corpusMaxDate - 180 * day

        let benchEnabled = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil
        var lap = benchEnabled ? Date() : nil
        func lapMark(_ label: String) {
            guard benchEnabled, let start = lap else { return }
            print("BENCH::       \(label) \(Int(Date().timeIntervalSince(start) * 1000)) ms"); fflush(stdout)
            lap = Date()
        }

        var subjectMessageCount = 0
        var otherMessageCount = 0
        var worldMessageCount = 0
        var activeContactMessageCounts: [String: Int] = [:]
        var subjectUnigramCounts: [String: Int] = [:]
        var subjectUnigramTotal = 0.0
        var subjectSlotsByN = Array(repeating: 0, count: maxN + 1)
        var hashCounts: [UInt64: Int] = [:]

        for (messageIndex, message) in messages.enumerated()
            where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            let isSubject = subjectContext.isSubjectMessage(message)
            worldMessageCount += 1
            if isSubject {
                subjectMessageCount += 1
                for word in message.words {
                    subjectUnigramCounts[word, default: 0] += 1
                    subjectUnigramTotal += 1
                }
                let totals = tokenized.slotTotals(at: messageIndex)
                var n = 1
                while n <= maxN {
                    if n < totals.count { subjectSlotsByN[n] += totals[n] }
                    n += 1
                }
                var seenHashes = Set<UInt64>()
                let grams = tokenized.ngrams(at: messageIndex)
                for hash in grams.hashes where seenHashes.insert(hash).inserted {
                    hashCounts[hash, default: 0] += 1
                }
            } else {
                otherMessageCount += 1
                let speaker = subjectContext.speakerLabel(message)
                if speaker != unknown {
                    activeContactMessageCounts[speaker, default: 0] += 1
                }
            }
        }
        lapMark("ngram.passA")

        let activeContacts = Set(activeContactMessageCounts.filter {
            $0.value >= config.activeContactMinMessages
        }.map { $0.key })

        let eligibleHashes = hashCounts
            .filter { $0.value >= config.minUserMessages }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(config.maxNgramHashCandidates)
            .map { $0.key }
        let eligible = Set(eligibleHashes)
        lapMark("ngram.eligibleSort")
        guard !eligible.isEmpty else {
            return VernacularNgramExtractionResult(candidates: [], candidateHashCount: 0,
                                                   exactCandidateCount: 0,
                                                   activeContacts: activeContacts.count)
        }

        var exact: [String: NgramAccumulator] = [:]
        exact.reserveCapacity(min(eligible.count, config.maxExactNgramCandidates))
        var acceptedHashes = Set<UInt64>()
        acceptedHashes.reserveCapacity(min(eligible.count, config.maxExactNgramCandidates))
        let exactLimit = config.maxExactNgramCandidates

        for (messageIndex, message) in messages.enumerated()
            where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            let isSubject = subjectContext.isSubjectMessage(message)
            let speaker = subjectContext.speakerLabel(message)
            var seenSurfaces = Set<String>()
            let grams = tokenized.ngrams(at: messageIndex)
            for offset in grams.hashes.indices {
                let hash = grams.hashes[offset]
                guard eligible.contains(hash) else { continue }
                if exact.count >= exactLimit && !acceptedHashes.contains(hash) { continue }
                let packed = grams.nStart[offset]
                let (n, start) = VernacularTokenizedCorpus.unpackNStart(packed)
                guard n > 0, start >= 0, start + n <= message.words.count else { continue }
                let toks = Array(message.words[start..<(start + n)])
                let surface = toks.joined(separator: " ")
                guard seenSurfaces.insert(surface).inserted else { continue }
                let accumulator: NgramAccumulator
                if let existing = exact[surface] {
                    accumulator = existing
                } else {
                    guard exact.count < exactLimit else { continue }
                    accumulator = NgramAccumulator(surface: surface, tokens: toks, n: n)
                    exact[surface] = accumulator
                    acceptedHashes.insert(hash)
                }
                accumulator.observe(message: message,
                                    isSubject: isSubject,
                                    speaker: speaker,
                                    recentCut: recentCut,
                                    activeContacts: activeContacts,
                                    contactCap: config.maxDispersionContactsPerCandidate,
                                    chatCap: config.maxDispersionChatsPerCandidate,
                                    dayCap: config.maxDispersionDaysPerCandidate,
                                    monthCap: config.maxDispersionMonthsPerCandidate)
            }
        }
        lapMark("ngram.passB")

        let strongestCollocation = strongestUnigramCollocations(
            exact: exact,
            totalBigramSlots: Double(max(subjectSlotsByN.indices.contains(2) ? subjectSlotsByN[2] : 0, 1)),
            unigramCounts: subjectUnigramCounts,
            unigramTotal: max(subjectUnigramTotal, 1),
            config: config
        )
        let staticSense = staticSenseSignals(exact: exact, baseline: baseline, config: config)

        var candidates: [VernacularPhraseCandidate] = []
        candidates.reserveCapacity(exact.count)
        for (_, accumulator) in exact {
            guard accumulator.userMessages >= config.minUserMessages else { continue }
            let distinctDays = accumulator.userDayCounts.count
            guard accumulator.userMessages >= config.lowCountDayGate
                    || distinctDays >= config.minDistinctDaysForLowCount else { continue }

            let maxDayShare = accumulator.maxUserDayShare
            if maxDayShare > config.maxSingleDayShare && distinctDays < config.minDistinctDaysForLowCount + 1 {
                continue
            }

            let userRate = Double(accumulator.userMessages) / Double(max(subjectMessageCount, 1))
            let receivedRate = Double(accumulator.receivedMessages) / Double(max(otherMessageCount, 1))
            let rawSelfUsage = log((userRate + 0.000_001) / (receivedRate + 0.000_001))
            let rawRecency = log(Double(accumulator.recentUserMessages + 1) / Double(accumulator.olderUserMessages + 1))
            let baseProbability = baselineProbability(tokens: accumulator.tokens, baseline: baseline)
            let zWorld = worldLogOddsEffect(count: accumulator.worldMessages,
                                            total: max(worldMessageCount, 1),
                                            referenceProbability: baseProbability,
                                            config: config)
            let zRole = logOddsZ(aCount: accumulator.userMessages,
                                 aTotal: max(subjectMessageCount, 1),
                                 bCount: accumulator.receivedMessages,
                                 bTotal: max(otherMessageCount, 1))
            let slots = Double(max(subjectSlotsByN[accumulator.n], 1))
            let rawRarity = log((Double(accumulator.worldMessages) + 0.5) /
                                (Double(max(worldMessageCount, 1)) * baseProbability + 0.5))
            let glue = accumulator.n >= 2
                ? npmi(tokens: accumulator.tokens, count: accumulator.userMessages,
                       totalSlots: slots, unigramCounts: subjectUnigramCounts,
                       unigramTotal: max(subjectUnigramTotal, 1))
                : 0

            let contactUsers = accumulator.activeContactUsers(minUses: config.minContactUsesForDocumentFrequency)
            let peopleIDF = inverseDocumentFrequency(df: contactUsers, activeContacts: activeContacts.count)
            let effective = accumulator.effectiveUserMessages(dailyCap: config.dailyUserCap)
            let effectiveShare = Double(effective) / Double(max(accumulator.userMessages, 1))
            let dayPenalty = maxDayShare <= config.maxSingleDayShare
                ? 1.0
                : max(0.25, (1.0 - maxDayShare) / max(1.0 - config.maxSingleDayShare, 0.01))
            let spamResistance = clamp01(effectiveShare * dayPenalty)
            let effectiveContacts = accumulator.effectiveContacts
            let effectiveChats = accumulator.effectiveWorldChats
            let echo = activeContacts.isEmpty ? 0 : Double(contactUsers) / Double(activeContacts.count)
            let maxMonthShare = accumulator.maxMonthShare
            let burst = max(maxDayShare, maxMonthShare)
            let circleDispersion = accumulator.circleDispersion(context: subjectContext,
                                                                activeContactCount: activeContacts.count)
            let userDispersion = accumulator.userDispersion(context: subjectContext)
            let percentile = accumulator.n == 1
                ? reclaimedPercentile(
                    subjectUses: accumulator.userMessages,
                    subjectTotalMessages: subjectMessageCount,
                    contactUses: accumulator.contactCounts,
                    contactTotalMessages: activeContactMessageCounts,
                    minPerUserUses: config.reclaimedMinPerUserUses,
                    minUsersForPercentile: config.reclaimedMinUsersForPercentile
                )
                : (value: 0.5, users: 0)

            candidates.append(VernacularPhraseCandidate(
                surface: accumulator.surface,
                tokens: accumulator.tokens,
                n: accumulator.n,
                userMessages: accumulator.userMessages,
                receivedMessages: accumulator.receivedMessages,
                worldMessages: accumulator.worldMessages,
                activeContactUsers: contactUsers,
                distinctUserDays: distinctDays,
                effectiveUserMessages: effective,
                maxUserDayShare: maxDayShare,
                maxMonthShare: maxMonthShare,
                effectiveContacts: effectiveContacts,
                effectiveChats: effectiveChats,
                userDispersion: userDispersion,
                circleDispersion: circleDispersion,
                echo: clamp01(echo),
                burst: clamp01(burst),
                recentUserMessages: accumulator.recentUserMessages,
                olderUserMessages: accumulator.olderUserMessages,
                rawSelfUsage: rawSelfUsage,
                rawRarity: rawRarity,
                rawRecency: rawRecency,
                zWorld: zWorld,
                zRole: zRole,
                peopleIDF: peopleIDF,
                spamResistance: spamResistance,
                glue: max(0, glue),
                collocation: accumulator.n == 1 ? (strongestCollocation[accumulator.surface]?.score ?? 0) : 0,
                topCollocationPartner: accumulator.n == 1 ? strongestCollocation[accumulator.surface]?.partner : nil,
                reclaimedPercentile: accumulator.n == 1 ? percentile.value : 0.5,
                reclaimedPercentileUsers: accumulator.n == 1 ? percentile.users : 0,
                reclaimedSenseDistance: accumulator.n == 1 ? (staticSense[accumulator.surface]?.distance ?? 0) : 0,
                hasStaticEmbeddingVector: accumulator.n == 1 ? (staticSense[accumulator.surface]?.hasWordVector ?? false) : false,
                baselineProbability: accumulator.n == 1 ? baseline.probability(of: accumulator.surface) : baseProbability,
                baselineKnown: accumulator.n == 1 ? baseline.isKnown(accumulator.surface) : false,
                semanticShift: 0,
                registerPenalty: VernacularTextingRegister.penalty(for: accumulator.surface),
                embedding: 0,
                examples: accumulator.examples
            ))
        }

        candidates.sort {
            if $0.userMessages != $1.userMessages { return $0.userMessages > $1.userMessages }
            if $0.n != $1.n { return $0.n > $1.n }
            return $0.surface < $1.surface
        }
        lapMark("ngram.candidates")
        return VernacularNgramExtractionResult(
            candidates: candidates,
            candidateHashCount: eligible.count,
            exactCandidateCount: exact.count,
            activeContacts: activeContacts.count
        )
    }

    private final class NgramAccumulator {
        let surface: String
        let tokens: [String]
        let n: Int
        var userMessages = 0
        var receivedMessages = 0
        var worldMessages = 0
        var contactCounts: [String: Int] = [:]
        var userDayCounts: [Int: Int] = [:]
        var userChatCounts: [Int64: Int] = [:]
        var worldMonthCounts: [Int: Int] = [:]
        var worldChatCounts: [Int64: Int] = [:]
        var recentUserMessages = 0
        var olderUserMessages = 0
        var examples: [String] = []

        init(surface: String, tokens: [String], n: Int) {
            self.surface = surface
            self.tokens = tokens
            self.n = n
        }

        var maxUserDayShare: Double {
            guard userMessages > 0 else { return 0 }
            return Double(userDayCounts.values.max() ?? 0) / Double(userMessages)
        }

        var maxMonthShare: Double {
            guard worldMessages > 0 else { return 0 }
            return Double(worldMonthCounts.values.max() ?? 0) / Double(worldMessages)
        }

        var effectiveContacts: Double {
            VernacularNgramExtractor.simpsonEffective(contactCounts.values)
        }

        var effectiveWorldChats: Double {
            VernacularNgramExtractor.simpsonEffective(worldChatCounts.values)
        }

        func observe(
            message: VernacularMessage,
            isSubject: Bool,
            speaker: String,
            recentCut: Double,
            activeContacts: Set<String>,
            contactCap: Int,
            chatCap: Int,
            dayCap: Int,
            monthCap: Int
        ) {
            worldMessages += 1
            VernacularNgramExtractor.incrementCapped(&worldMonthCounts,
                                                     key: VernacularSubjectContext.monthKey(message.date),
                                                     limit: monthCap)
            VernacularNgramExtractor.incrementCapped(&worldChatCounts,
                                                     key: message.chat,
                                                     limit: chatCap)
            if isSubject {
                userMessages += 1
                let dayKey = VernacularSubjectContext.dayKey(message.date)
                VernacularNgramExtractor.incrementCapped(&userDayCounts, key: dayKey, limit: dayCap)
                VernacularNgramExtractor.incrementCapped(&userChatCounts, key: message.chat, limit: chatCap)
                if message.date >= recentCut { recentUserMessages += 1 } else { olderUserMessages += 1 }
                if examples.count < 3 {
                    let one = message.body.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    if !one.isEmpty, !examples.contains(one) { examples.append(one) }
                }
            } else {
                receivedMessages += 1
                if activeContacts.contains(speaker) {
                    VernacularNgramExtractor.incrementCapped(&contactCounts, key: speaker, limit: contactCap)
                }
            }
        }

        func activeContactUsers(minUses: Int) -> Int {
            contactCounts.values.filter { $0 >= minUses }.count
        }

        func effectiveUserMessages(dailyCap: Int) -> Double {
            Double(userDayCounts.values.reduce(0) { $0 + min($1, dailyCap) })
        }

        func circleDispersion(context: VernacularSubjectContext, activeContactCount: Int) -> Double {
            let time = VernacularNgramExtractor.normalizedEntropy(worldMonthCounts.values, universe: context.activeWorldMonths)
            let contact = activeContactCount > 0 ? effectiveContacts / Double(activeContactCount) : 0
            let chat = context.activeWorldChats > 0 ? effectiveWorldChats / Double(context.activeWorldChats) : 0
            return VernacularNgramExtractor.geometricMean([max(time, 0.05), max(contact, 0.05), max(chat, 0.05)])
        }

        func userDispersion(context: VernacularSubjectContext) -> Double {
            let day = VernacularNgramExtractor.normalizedEntropy(userDayCounts.values, universe: context.activeSubjectDays)
            let subjectChats = VernacularNgramExtractor.simpsonEffective(userChatCounts.values)
            let chat = context.activeSubjectChats > 0 ? subjectChats / Double(context.activeSubjectChats) : 0
            return VernacularNgramExtractor.geometricMean([max(day, 0.05), max(chat, 0.05)])
        }
    }

    static func corpusAllowed(_ message: VernacularMessage) -> Bool {
        !message.isPoll && !message.bodyLow.contains("http") && !message.words.isEmpty
    }

    static func visitNgrams(
        words: [String],
        maxN: Int,
        _ visit: (Int, Int, UInt64) -> Void
    ) {
        guard !words.isEmpty else { return }
        let limit = min(maxN, words.count)
        for n in 1...limit {
            var start = 0
            while start <= words.count - n {
                visit(n, start, stableHash(words: words, start: start, n: n))
                start += 1
            }
        }
    }

    static func stableHash(words: [String], start: Int, n: Int) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for i in start..<(start + n) {
            for byte in words[i].utf8 {
                h ^= UInt64(byte)
                h &*= prime
            }
            h ^= 0x1F
            h &*= prime
        }
        return h
    }

    struct TokenGateFlags {
        let ok: [Bool]
        let stop: [Bool]
        let content: [Bool]
    }

    static func tokenGateFlags(words: [String], nameTokens: Set<String>) -> TokenGateFlags {
        let count = words.count
        var ok = [Bool](repeating: false, count: count)
        var stop = [Bool](repeating: false, count: count)
        var content = [Bool](repeating: false, count: count)
        for i in 0..<count {
            let token = words[i]
            let isStop = LinguisticStopwords.isStopword(token)
            stop[i] = isStop
            content[i] = token.count >= 2 && !isStop
            var allowed = token.count >= 2
            if allowed && urlish.contains(token) { allowed = false }
            if allowed && (token.contains("'") || token.contains("\u{2019}")) { allowed = false }
            if allowed && VernacularAnalyzer.isContraction(token) { allowed = false }
            if allowed && VernacularAnalyzer.acronymTopicStoplist.contains(token) { allowed = false }
            if allowed && VernacularAnalyzer.isNameForm(token, nameTokens: nameTokens) { allowed = false }
            if allowed && (VernacularAnalyzer.isSingleRepeatedLetterTok(token)
                           || VernacularAnalyzer.isLaughMashTok(token)) { allowed = false }
            ok[i] = allowed
        }
        return TokenGateFlags(ok: ok, stop: stop, content: content)
    }

    static func gramAllowed(flags: TokenGateFlags, start: Int, n: Int) -> Bool {
        var hasContent = false
        var allStopwords = true
        for i in start..<(start + n) {
            if !flags.ok[i] { return false }
            if !flags.stop[i] { allStopwords = false }
            if flags.content[i] { hasContent = true }
        }
        if n == 1 { return hasContent }
        return hasContent && !allStopwords
    }

    private static func baselineProbability(tokens: [String], baseline: LinguisticBaseline) -> Double {
        tokens.reduce(1.0) { $0 * max(baseline.probability(of: $1), 1e-12) }
    }

    private static func worldLogOddsEffect(
        count: Int,
        total: Int,
        referenceProbability: Double,
        config: VernacularConfig
    ) -> Double {
        let p = min(max(referenceProbability, 1e-12), 0.95)
        let alpha = max(config.logOddsPriorMass * p, 0.01)
        let alpha0 = max(config.logOddsPriorMass, alpha + 0.01)
        let refTotal = config.referencePseudoCount
        let refCount = max(refTotal * p, 0.01)
        let a = Double(count)
        let aTotal = Double(max(total, count + 1))
        let aOther = max(aTotal - a, 1)
        let refOther = max(refTotal - refCount, 1)
        let delta = log((a + alpha) / (aOther + alpha0 - alpha))
            - log((refCount + alpha) / (refOther + alpha0 - alpha))
        let confidence = a / max(a + max(config.worldEffectCountScale, 0), 1)
        return delta * confidence
    }

    private static func logOddsZ(aCount: Int, aTotal: Int, bCount: Int, bTotal: Int) -> Double {
        let alpha = 0.5
        let a = Double(aCount)
        let b = Double(bCount)
        let aOther = max(Double(aTotal - aCount), 1)
        let bOther = max(Double(bTotal - bCount), 1)
        let delta = log((a + alpha) / (aOther + alpha)) - log((b + alpha) / (bOther + alpha))
        let variance = 1.0 / max(a + alpha, 0.000_001) + 1.0 / max(b + alpha, 0.000_001)
        return delta / sqrt(max(variance, 0.000_001))
    }

    private static func npmi(
        tokens: [String],
        count: Int,
        totalSlots: Double,
        unigramCounts: [String: Int],
        unigramTotal: Double
    ) -> Double {
        let p = Double(count) / max(totalSlots, 1)
        guard p > 0, p < 1 else { return 0 }
        var independent = 1.0
        for token in tokens {
            independent *= Double(max(unigramCounts[token] ?? 1, 1)) / max(unigramTotal, 1)
        }
        guard independent > 0 else { return 0 }
        let pmi = log(p / independent)
        let denom = -log(p)
        guard denom > 0 else { return 0 }
        return pmi / denom
    }

    private static func strongestUnigramCollocations(
        exact: [String: NgramAccumulator],
        totalBigramSlots: Double,
        unigramCounts: [String: Int],
        unigramTotal: Double,
        config: VernacularConfig
    ) -> [String: CollocationInfo] {
        var strongest: [String: CollocationInfo] = [:]
        let scale = max(config.collocationCountScale, 0.1)
        for accumulator in exact.values where accumulator.n == 2 && accumulator.userMessages >= config.minUserMessages {
            let glue = max(0, npmi(tokens: accumulator.tokens,
                                   count: accumulator.userMessages,
                                   totalSlots: totalBigramSlots,
                                   unigramCounts: unigramCounts,
                                   unigramTotal: unigramTotal))
            guard glue > 0 else { continue }
            let countConfidence = 1.0 - exp(-Double(accumulator.userMessages) / scale)
            let feature = clamp01(glue * countConfidence)
            guard feature > 0 else { continue }
            for index in accumulator.tokens.indices {
                let token = accumulator.tokens[index]
                let partner = accumulator.tokens.enumerated()
                    .filter { $0.offset != index }
                    .map { $0.element }
                    .joined(separator: " ")
                if feature > (strongest[token]?.score ?? 0) {
                    strongest[token] = CollocationInfo(score: feature, partner: partner)
                }
            }
        }
        return strongest
    }

    private static func staticSenseSignals(
        exact: [String: NgramAccumulator],
        baseline: LinguisticBaseline,
        config: VernacularConfig
    ) -> [String: StaticSenseInfo] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return [:] }

        var allPartnerWeights: [String: [String: Double]] = [:]
        var contentPartnerWeights: [String: [String: Double]] = [:]
        for accumulator in exact.values where accumulator.n == 2 && accumulator.userMessages >= config.minUserMessages {
            let weight = Double(accumulator.userMessages)
            for index in accumulator.tokens.indices {
                let token = accumulator.tokens[index]
                let partner = accumulator.tokens.enumerated()
                    .filter { $0.offset != index }
                    .map { $0.element }
                    .joined(separator: " ")
                recordStaticSensePartner(&allPartnerWeights,
                                         token: token,
                                         partner: partner,
                                         weight: weight)
                guard staticSensePartnerAllowed(partner) else { continue }
                recordStaticSensePartner(&contentPartnerWeights,
                                         token: token,
                                         partner: partner,
                                         weight: weight)
            }
        }

        var result: [String: StaticSenseInfo] = [:]
        result.reserveCapacity(exact.count / 2)
        for accumulator in exact.values where accumulator.n == 1 && accumulator.userMessages >= config.reclaimedMinUses {
            let token = accumulator.surface
            guard VernacularTextingRegister.penalty(for: token) <= 0 else { continue }
            guard let wordVector = embedding.vector(for: token) else { continue }
            let partnerDistance = staticPartnerDistance(
                wordVector: wordVector,
                partnerWeights: contentPartnerWeights[token] ?? [:],
                embedding: embedding
            )
            let allSupport = staticTopPartnerSupport(
                allPartnerWeights[token] ?? [:],
                userMessages: accumulator.userMessages
            )
            let baselineMissedCue: Double
            if !baseline.isKnown(token) && accumulator.userMessages >= config.reclaimedMinUses {
                baselineMissedCue = min(0.45, 0.18 + 0.32 * allSupport)
            } else {
                baselineMissedCue = 0
            }
            result[token] = StaticSenseInfo(
                distance: clamp01(max(partnerDistance, baselineMissedCue)),
                hasWordVector: true
            )
        }
        return result
    }

    private static func recordStaticSensePartner(
        _ buckets: inout [String: [String: Double]],
        token: String,
        partner: String,
        weight: Double
    ) {
        guard !token.isEmpty, !partner.isEmpty, token != partner else { return }
        var bucket = buckets[token] ?? [:]
        bucket[partner, default: 0] += weight
        if bucket.count > staticSensePartnerCap,
           let weakest = bucket.min(by: {
               if $0.value != $1.value { return $0.value < $1.value }
               return $0.key > $1.key
           })?.key {
            bucket.removeValue(forKey: weakest)
        }
        buckets[token] = bucket
    }

    private static func staticSensePartnerAllowed(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        if literalSensePartners.contains(token) { return false }
        if LinguisticStopwords.isStopword(token) { return false }
        if token.contains(where: { $0.isNumber }) { return false }
        if urlish.contains(token) { return false }
        return true
    }

    private static func staticPartnerDistance(
        wordVector: [Double],
        partnerWeights: [String: Double],
        embedding: NLEmbedding
    ) -> Double {
        guard !wordVector.isEmpty, !partnerWeights.isEmpty else { return 0 }
        var centroid = [Double](repeating: 0, count: wordVector.count)
        var totalWeight = 0.0
        let partners = partnerWeights.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(staticSensePartnerCap)
        for (partner, weight) in partners {
            guard let vector = embedding.vector(for: partner), vector.count == wordVector.count else { continue }
            let w = sqrt(max(weight, 1))
            for index in vector.indices {
                centroid[index] += vector[index] * w
            }
            totalWeight += w
        }
        guard totalWeight > 0 else { return 0 }
        for index in centroid.indices {
            centroid[index] /= totalWeight
        }
        let distance = cosineDistance(wordVector, centroid)
        return clamp01((distance - 0.25) / 0.75)
    }

    private static func staticTopPartnerSupport(
        _ partnerWeights: [String: Double],
        userMessages: Int
    ) -> Double {
        guard userMessages > 0, let top = partnerWeights.values.max() else { return 0 }
        return clamp01(top / Double(userMessages))
    }

    private static func cosineDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
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
        let cosine = dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
        return 1.0 - min(max(cosine, -1.0), 1.0)
    }

    private static func reclaimedPercentile(
        subjectUses: Int,
        subjectTotalMessages: Int,
        contactUses: [String: Int],
        contactTotalMessages: [String: Int],
        minPerUserUses: Int,
        minUsersForPercentile: Int
    ) -> (value: Double, users: Int) {
        guard subjectUses > 0, subjectTotalMessages > 0 else { return (0.5, 0) }
        let subjectRate = Double(subjectUses) / Double(subjectTotalMessages)
        var rates = [subjectRate]
        rates.reserveCapacity(min(contactUses.count + 1, max(minUsersForPercentile, 1) * 4))
        for (contact, uses) in contactUses where uses >= minPerUserUses {
            guard let total = contactTotalMessages[contact], total > 0 else { continue }
            rates.append(Double(uses) / Double(total))
        }
        let users = rates.count
        guard users > 1 else { return (0.5, users) }
        let raw = Double(rates.filter { $0 <= subjectRate }.count) / Double(users)
        guard users < minUsersForPercentile else { return (clamp01(raw), users) }
        let strength = Double(max(users - 1, 0)) / Double(max(minUsersForPercentile - 1, 1))
        return (clamp01(0.5 + (raw - 0.5) * strength), users)
    }

    private static func inverseDocumentFrequency(df: Int, activeContacts: Int) -> Double {
        guard activeContacts > 0 else { return 1 }
        let numerator = log(Double(activeContacts + 1) / Double(df + 1))
        let denominator = log(Double(activeContacts + 1))
        guard denominator > 0 else { return 1 }
        return clamp01(numerator / denominator)
    }

    private static func normalizedEntropy<V: Collection>(_ values: V, universe: Int) -> Double where V.Element == Int {
        let total = values.reduce(0, +)
        guard total > 0, universe > 1 else { return 0 }
        var entropy = 0.0
        for value in values where value > 0 {
            let p = Double(value) / Double(total)
            entropy -= p * log(p)
        }
        return clamp01(entropy / log(Double(max(universe, 2))))
    }

    private static func simpsonEffective<V: Collection>(_ values: V) -> Double where V.Element == Int {
        let total = values.reduce(0, +)
        guard total > 0 else { return 0 }
        var sumSquares = 0.0
        for value in values where value > 0 {
            let p = Double(value) / Double(total)
            sumSquares += p * p
        }
        guard sumSquares > 0 else { return 0 }
        return 1.0 / sumSquares
    }

    private static func incrementCapped<Key: Hashable>(
        _ counts: inout [Key: Int],
        key: Key,
        limit: Int
    ) {
        let cap = max(limit, 1)
        if counts[key] != nil || counts.count < cap {
            counts[key, default: 0] += 1
        }
    }

    private static func geometricMean(_ values: [Double]) -> Double {
        let positives = values.map { max($0, 0.000_001) }
        let logSum = positives.reduce(0.0) { $0 + log($1) }
        return clamp01(exp(logSum / Double(max(positives.count, 1))))
    }

    private static func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}
