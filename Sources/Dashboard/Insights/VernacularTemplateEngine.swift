//
//  VernacularTemplateEngine.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

struct VernacularTemplateCandidate: Sendable, Equatable {
    let pattern: String
    let anchors: [String]
    let slotCount: Int
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
    let productivity: Double
    let fillEntropy: Double
    let anchorDistinctiveness: Double
    let embedding: Double
    let topFills: [VernacularProfileTemplate.Fill]
    let examples: [String]
}

struct VernacularTemplateExtractionResult: Sendable, Equatable {
    let candidates: [VernacularTemplateCandidate]
    let candidateHashCount: Int
    let exactCandidateCount: Int
}

enum VernacularTemplateEngine {
    private static let day: Double = 86_400
    private static let unknown = VernacularAnalyzer.unknownLabel

    static func mine(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        contacts: ResolvedContacts,
        activeContacts: Int,
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig,
        tokenized: VernacularTokenizedCorpus? = nil
    ) -> VernacularTemplateExtractionResult {
        let nameTokens = VernacularAnalyzer.contactNameTokens(contacts)
        if let tokenized,
           tokenized.isValid(nameTokens: nameTokens, config: config, messageCount: messages.count) {
            return mineFromTokenized(messages: messages,
                                     baseline: baseline,
                                     activeContacts: activeContacts,
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

        var sentMessageCount = 0
        var receivedMessageCount = 0
        var worldMessageCount = 0
        var activeContactMessageCounts: [String: Int] = [:]
        var hashCounts: [UInt64: Int] = [:]

        for message in messages where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            worldMessageCount += 1
            if subjectContext.isSubjectMessage(message) {
                sentMessageCount += 1
                guard message.words.count <= config.maxTemplateMessageTokens else { continue }
                var seen = Set<UInt64>()
                visitPatternHashes(words: message.words, nameTokens: nameTokens, config: config) { hash in
                    if seen.insert(hash).inserted {
                        hashCounts[hash, default: 0] += 1
                    }
                }
            } else {
                receivedMessageCount += 1
                let speaker = subjectContext.speakerLabel(message)
                if speaker != unknown {
                    activeContactMessageCounts[speaker, default: 0] += 1
                }
            }
        }

        lapMark("tmpl.passA")

        let activeContactSet = Set(activeContactMessageCounts.filter {
            $0.value >= config.activeContactMinMessages
        }.map { $0.key })

        let eligibleHashes = hashCounts
            .filter { $0.value >= config.minUserMessages }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(config.maxTemplateHashCandidates)
            .map { $0.key }
        let eligible = Set(eligibleHashes)
        guard !eligible.isEmpty else {
            return VernacularTemplateExtractionResult(candidates: [], candidateHashCount: 0,
                                                      exactCandidateCount: 0)
        }

        lapMark("tmpl.eligibleSort")

        var exact: [String: TemplateAccumulator] = [:]
        exact.reserveCapacity(min(eligible.count, config.maxExactTemplateCandidates))
        var acceptedHashes = Set<UInt64>()
        acceptedHashes.reserveCapacity(min(eligible.count, config.maxExactTemplateCandidates))
        let exactLimit = config.maxExactTemplateCandidates

        for message in messages where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            guard message.words.count <= config.maxTemplateMessageTokens else { continue }
            let isSubject = subjectContext.isSubjectMessage(message)
            let speaker = subjectContext.speakerLabel(message)
            var seenPatterns = Set<String>()
            visitEligiblePatterns(words: message.words, nameTokens: nameTokens,
                                  eligible: eligible, config: config,
                                  shouldMaterialize: { hash in
                                      exact.count < exactLimit || acceptedHashes.contains(hash)
                                  }) { pattern in
                guard seenPatterns.insert(pattern.key).inserted else { return }
                let accumulator: TemplateAccumulator
                if let existing = exact[pattern.key] {
                    accumulator = existing
                } else {
                    guard exact.count < exactLimit else { return }
                    accumulator = TemplateAccumulator(pattern: pattern.key,
                                                      anchors: pattern.anchors,
                                                      slotCount: pattern.slotCount)
                    exact[pattern.key] = accumulator
                    acceptedHashes.insert(pattern.hash)
                }
                accumulator.observe(message: message, fillKey: pattern.fillKey,
                                    isSubject: isSubject,
                                    speaker: speaker,
                                    recentCut: recentCut, activeContacts: activeContactSet,
                                    contactCap: config.maxDispersionContactsPerCandidate,
                                    chatCap: config.maxDispersionChatsPerCandidate,
                                    dayCap: config.maxDispersionDaysPerCandidate,
                                    monthCap: config.maxDispersionMonthsPerCandidate)
            }
        }

        lapMark("tmpl.passB")

        var candidates: [VernacularTemplateCandidate] = []
        candidates.reserveCapacity(exact.count)
        for (_, accumulator) in exact {
            guard accumulator.userMessages >= config.minUserMessages,
                  accumulator.fills.count >= config.minTemplateDistinctFills else { continue }
            let distinctDays = accumulator.userDayCounts.count
            guard accumulator.userMessages >= config.lowCountDayGate
                    || distinctDays >= config.minDistinctDaysForLowCount else { continue }
            let maxDayShare = accumulator.maxUserDayShare
            if maxDayShare > config.maxSingleDayShare && distinctDays < config.minDistinctDaysForLowCount + 1 {
                continue
            }

            let userRate = Double(accumulator.userMessages) / Double(max(sentMessageCount, 1))
            let receivedRate = Double(accumulator.receivedMessages) / Double(max(receivedMessageCount, 1))
            let rawSelfUsage = log((userRate + 0.000_001) / (receivedRate + 0.000_001))
            let rawRecency = log(Double(accumulator.recentUserMessages + 1) / Double(accumulator.olderUserMessages + 1))
            let anchorRarity = anchorDistinctiveness(accumulator.anchors, baseline: baseline)
            let anchorProbability = baselineProbability(tokens: accumulator.anchors, baseline: baseline)
            let zWorld = worldLogOddsEffect(count: accumulator.worldMessages,
                                            total: max(worldMessageCount, 1),
                                            referenceProbability: anchorProbability,
                                            config: config)
            let zRole = logOddsZ(aCount: accumulator.userMessages,
                                 aTotal: max(sentMessageCount, 1),
                                 bCount: accumulator.receivedMessages,
                                 bTotal: max(receivedMessageCount, 1))
            let productivity = min(1.0, Double(accumulator.fills.count) /
                                   Double(max(config.minTemplateDistinctFills * 2, 1)))
            let fillEntropy = accumulator.fillEntropy
            let contactUsers = accumulator.activeContactUsers(minUses: config.minContactUsesForDocumentFrequency)
            let peopleIDF = inverseDocumentFrequency(df: contactUsers,
                                                     activeContacts: max(activeContacts, activeContactSet.count))
            let effective = accumulator.effectiveUserMessages(dailyCap: config.dailyUserCap)
            let effectiveShare = Double(effective) / Double(max(accumulator.userMessages, 1))
            let dayPenalty = maxDayShare <= config.maxSingleDayShare
                ? 1.0
                : max(0.25, (1.0 - maxDayShare) / max(1.0 - config.maxSingleDayShare, 0.01))
            let spamResistance = clamp01(effectiveShare * dayPenalty)
            let effectiveContacts = accumulator.effectiveContacts
            let effectiveChats = accumulator.effectiveWorldChats
            let echo = activeContactSet.isEmpty ? 0 : Double(contactUsers) / Double(activeContactSet.count)
            let maxMonthShare = accumulator.maxMonthShare
            let burst = max(maxDayShare, maxMonthShare)
            let circleDispersion = accumulator.circleDispersion(context: subjectContext,
                                                                activeContactCount: activeContactSet.count)
            let userDispersion = accumulator.userDispersion(context: subjectContext)

            candidates.append(VernacularTemplateCandidate(
                pattern: accumulator.pattern,
                anchors: accumulator.anchors,
                slotCount: accumulator.slotCount,
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
                rawRarity: anchorRarity,
                rawRecency: rawRecency,
                zWorld: zWorld,
                zRole: zRole,
                peopleIDF: peopleIDF,
                spamResistance: spamResistance,
                productivity: productivity,
                fillEntropy: fillEntropy,
                anchorDistinctiveness: anchorRarity,
                embedding: 0,
                topFills: accumulator.topFills(limit: 5),
                examples: accumulator.examples
            ))
        }

        candidates.sort {
            if $0.userMessages != $1.userMessages { return $0.userMessages > $1.userMessages }
            if $0.slotCount != $1.slotCount { return $0.slotCount > $1.slotCount }
            return $0.pattern < $1.pattern
        }
        lapMark("tmpl.candidates")
        return VernacularTemplateExtractionResult(candidates: candidates,
                                                  candidateHashCount: eligible.count,
                                                  exactCandidateCount: exact.count)
    }

    private static func mineFromTokenized(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline,
        activeContacts: Int,
        subjectContext: VernacularSubjectContext,
        config: VernacularConfig,
        tokenized: VernacularTokenizedCorpus
    ) -> VernacularTemplateExtractionResult {
        let corpusMaxDate = messages.map(\.date).max() ?? 0
        let recentCut = corpusMaxDate - 180 * day

        let benchEnabled = ProcessInfo.processInfo.environment["HOURGLASS_PANEL_BENCH"] != nil
        var lap = benchEnabled ? Date() : nil
        func lapMark(_ label: String) {
            guard benchEnabled, let start = lap else { return }
            print("BENCH::       \(label) \(Int(Date().timeIntervalSince(start) * 1000)) ms"); fflush(stdout)
            lap = Date()
        }

        var sentMessageCount = 0
        var receivedMessageCount = 0
        var worldMessageCount = 0
        var activeContactMessageCounts: [String: Int] = [:]
        var hashCounts: [UInt64: Int] = [:]

        for (messageIndex, message) in messages.enumerated()
            where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            worldMessageCount += 1
            if subjectContext.isSubjectMessage(message) {
                sentMessageCount += 1
                guard message.words.count <= config.maxTemplateMessageTokens else { continue }
                var seen = Set<UInt64>()
                for ref in tokenized.patterns(at: messageIndex).refs where seen.insert(ref.hash).inserted {
                    hashCounts[ref.hash, default: 0] += 1
                }
            } else {
                receivedMessageCount += 1
                let speaker = subjectContext.speakerLabel(message)
                if speaker != unknown {
                    activeContactMessageCounts[speaker, default: 0] += 1
                }
            }
        }

        lapMark("tmpl.passA")

        let activeContactSet = Set(activeContactMessageCounts.filter {
            $0.value >= config.activeContactMinMessages
        }.map { $0.key })

        let eligibleHashes = hashCounts
            .filter { $0.value >= config.minUserMessages }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(config.maxTemplateHashCandidates)
            .map { $0.key }
        let eligible = Set(eligibleHashes)
        guard !eligible.isEmpty else {
            return VernacularTemplateExtractionResult(candidates: [], candidateHashCount: 0,
                                                      exactCandidateCount: 0)
        }

        lapMark("tmpl.eligibleSort")

        var exact: [String: TemplateAccumulator] = [:]
        exact.reserveCapacity(min(eligible.count, config.maxExactTemplateCandidates))
        var acceptedHashes = Set<UInt64>()
        acceptedHashes.reserveCapacity(min(eligible.count, config.maxExactTemplateCandidates))
        let exactLimit = config.maxExactTemplateCandidates

        for (messageIndex, message) in messages.enumerated()
            where corpusAllowed(message) && subjectContext.isWorldMessage(message) {
            guard message.words.count <= config.maxTemplateMessageTokens else { continue }
            let isSubject = subjectContext.isSubjectMessage(message)
            let speaker = subjectContext.speakerLabel(message)
            var seenPatterns = Set<String>()
            for ref in tokenized.patterns(at: messageIndex).refs {
                let hash = ref.hash
                guard eligible.contains(hash) else { continue }
                guard exact.count < exactLimit || acceptedHashes.contains(hash) else { continue }
                guard let pattern = materializePattern(words: message.words,
                                                       start: Int(ref.start),
                                                       length: Int(ref.length),
                                                       anchors: ref.anchors,
                                                       hash: hash,
                                                       config: config) else {
                    continue
                }
                guard seenPatterns.insert(pattern.key).inserted else { continue }
                let accumulator: TemplateAccumulator
                if let existing = exact[pattern.key] {
                    accumulator = existing
                } else {
                    guard exact.count < exactLimit else { continue }
                    accumulator = TemplateAccumulator(pattern: pattern.key,
                                                      anchors: pattern.anchors,
                                                      slotCount: pattern.slotCount)
                    exact[pattern.key] = accumulator
                    acceptedHashes.insert(pattern.hash)
                }
                accumulator.observe(message: message, fillKey: pattern.fillKey,
                                    isSubject: isSubject,
                                    speaker: speaker,
                                    recentCut: recentCut, activeContacts: activeContactSet,
                                    contactCap: config.maxDispersionContactsPerCandidate,
                                    chatCap: config.maxDispersionChatsPerCandidate,
                                    dayCap: config.maxDispersionDaysPerCandidate,
                                    monthCap: config.maxDispersionMonthsPerCandidate)
            }
        }

        lapMark("tmpl.passB")

        var candidates: [VernacularTemplateCandidate] = []
        candidates.reserveCapacity(exact.count)
        for (_, accumulator) in exact {
            guard accumulator.userMessages >= config.minUserMessages,
                  accumulator.fills.count >= config.minTemplateDistinctFills else { continue }
            let distinctDays = accumulator.userDayCounts.count
            guard accumulator.userMessages >= config.lowCountDayGate
                    || distinctDays >= config.minDistinctDaysForLowCount else { continue }
            let maxDayShare = accumulator.maxUserDayShare
            if maxDayShare > config.maxSingleDayShare && distinctDays < config.minDistinctDaysForLowCount + 1 {
                continue
            }

            let userRate = Double(accumulator.userMessages) / Double(max(sentMessageCount, 1))
            let receivedRate = Double(accumulator.receivedMessages) / Double(max(receivedMessageCount, 1))
            let rawSelfUsage = log((userRate + 0.000_001) / (receivedRate + 0.000_001))
            let rawRecency = log(Double(accumulator.recentUserMessages + 1) / Double(accumulator.olderUserMessages + 1))
            let anchorRarity = anchorDistinctiveness(accumulator.anchors, baseline: baseline)
            let anchorProbability = baselineProbability(tokens: accumulator.anchors, baseline: baseline)
            let zWorld = worldLogOddsEffect(count: accumulator.worldMessages,
                                            total: max(worldMessageCount, 1),
                                            referenceProbability: anchorProbability,
                                            config: config)
            let zRole = logOddsZ(aCount: accumulator.userMessages,
                                 aTotal: max(sentMessageCount, 1),
                                 bCount: accumulator.receivedMessages,
                                 bTotal: max(receivedMessageCount, 1))
            let productivity = min(1.0, Double(accumulator.fills.count) /
                                   Double(max(config.minTemplateDistinctFills * 2, 1)))
            let fillEntropy = accumulator.fillEntropy
            let contactUsers = accumulator.activeContactUsers(minUses: config.minContactUsesForDocumentFrequency)
            let peopleIDF = inverseDocumentFrequency(df: contactUsers,
                                                     activeContacts: max(activeContacts, activeContactSet.count))
            let effective = accumulator.effectiveUserMessages(dailyCap: config.dailyUserCap)
            let effectiveShare = Double(effective) / Double(max(accumulator.userMessages, 1))
            let dayPenalty = maxDayShare <= config.maxSingleDayShare
                ? 1.0
                : max(0.25, (1.0 - maxDayShare) / max(1.0 - config.maxSingleDayShare, 0.01))
            let spamResistance = clamp01(effectiveShare * dayPenalty)
            let effectiveContacts = accumulator.effectiveContacts
            let effectiveChats = accumulator.effectiveWorldChats
            let echo = activeContactSet.isEmpty ? 0 : Double(contactUsers) / Double(activeContactSet.count)
            let maxMonthShare = accumulator.maxMonthShare
            let burst = max(maxDayShare, maxMonthShare)
            let circleDispersion = accumulator.circleDispersion(context: subjectContext,
                                                                activeContactCount: activeContactSet.count)
            let userDispersion = accumulator.userDispersion(context: subjectContext)

            candidates.append(VernacularTemplateCandidate(
                pattern: accumulator.pattern,
                anchors: accumulator.anchors,
                slotCount: accumulator.slotCount,
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
                rawRarity: anchorRarity,
                rawRecency: rawRecency,
                zWorld: zWorld,
                zRole: zRole,
                peopleIDF: peopleIDF,
                spamResistance: spamResistance,
                productivity: productivity,
                fillEntropy: fillEntropy,
                anchorDistinctiveness: anchorRarity,
                embedding: 0,
                topFills: accumulator.topFills(limit: 5),
                examples: accumulator.examples
            ))
        }

        candidates.sort {
            if $0.userMessages != $1.userMessages { return $0.userMessages > $1.userMessages }
            if $0.slotCount != $1.slotCount { return $0.slotCount > $1.slotCount }
            return $0.pattern < $1.pattern
        }
        lapMark("tmpl.candidates")
        return VernacularTemplateExtractionResult(candidates: candidates,
                                                  candidateHashCount: eligible.count,
                                                  exactCandidateCount: exact.count)
    }

    struct GeneratedPattern {
        let key: String
        let hash: UInt64
        let anchors: [String]
        let slotCount: Int
        let fillKey: String
    }

    struct AnchorSelection: Sendable, Equatable {
        let count: Int
        let a0: Int
        let a1: Int
        let a2: Int

        init(_ a0: Int) {
            self.count = 1
            self.a0 = a0
            self.a1 = -1
            self.a2 = -1
        }

        init(_ a0: Int, _ a1: Int) {
            self.count = 2
            self.a0 = a0
            self.a1 = a1
            self.a2 = -1
        }

        init(_ a0: Int, _ a1: Int, _ a2: Int) {
            self.count = 3
            self.a0 = a0
            self.a1 = a1
            self.a2 = a2
        }

        func contains(_ position: Int) -> Bool {
            position == a0 || (count >= 2 && position == a1) || (count >= 3 && position == a2)
        }
    }

    /// Reference type so per-observation mutation is IN PLACE (same O(uses²)
    /// struct-copy fix as NgramAccumulator).
    private final class TemplateAccumulator {
        let pattern: String
        let anchors: [String]
        let slotCount: Int
        var userMessages = 0
        var receivedMessages = 0
        var worldMessages = 0
        var contactCounts: [String: Int] = [:]
        var fills: [String: Int] = [:]
        var userDayCounts: [Int: Int] = [:]
        var userChatCounts: [Int64: Int] = [:]
        var worldMonthCounts: [Int: Int] = [:]
        var worldChatCounts: [Int64: Int] = [:]
        var recentUserMessages = 0
        var olderUserMessages = 0
        var examples: [String] = []

        init(pattern: String, anchors: [String], slotCount: Int) {
            self.pattern = pattern
            self.anchors = anchors
            self.slotCount = slotCount
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
            VernacularTemplateEngine.simpsonEffective(contactCounts.values)
        }

        var effectiveWorldChats: Double {
            VernacularTemplateEngine.simpsonEffective(worldChatCounts.values)
        }

        func observe(
            message: VernacularMessage,
            fillKey: String,
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
            VernacularTemplateEngine.incrementCapped(&worldMonthCounts,
                                                     key: VernacularSubjectContext.monthKey(message.date),
                                                     limit: monthCap)
            VernacularTemplateEngine.incrementCapped(&worldChatCounts,
                                                     key: message.chat,
                                                     limit: chatCap)
            if isSubject {
                userMessages += 1
                fills[fillKey, default: 0] += 1
                let dayKey = VernacularSubjectContext.dayKey(message.date)
                VernacularTemplateEngine.incrementCapped(&userDayCounts, key: dayKey, limit: dayCap)
                VernacularTemplateEngine.incrementCapped(&userChatCounts, key: message.chat, limit: chatCap)
                if message.date >= recentCut { recentUserMessages += 1 } else { olderUserMessages += 1 }
                if examples.count < 3 {
                    let one = message.body.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    if !one.isEmpty, one.count <= 120, !examples.contains(one) {
                        examples.append(one)
                    }
                }
            } else {
                receivedMessages += 1
                if activeContacts.contains(speaker) {
                    VernacularTemplateEngine.incrementCapped(&contactCounts, key: speaker, limit: contactCap)
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
            let time = VernacularTemplateEngine.normalizedEntropy(worldMonthCounts.values, universe: context.activeWorldMonths)
            let contact = activeContactCount > 0 ? effectiveContacts / Double(activeContactCount) : 0
            let chat = context.activeWorldChats > 0 ? effectiveWorldChats / Double(context.activeWorldChats) : 0
            return VernacularTemplateEngine.geometricMean([max(time, 0.05), max(contact, 0.05), max(chat, 0.05)])
        }

        func userDispersion(context: VernacularSubjectContext) -> Double {
            let day = VernacularTemplateEngine.normalizedEntropy(userDayCounts.values, universe: context.activeSubjectDays)
            let subjectChats = VernacularTemplateEngine.simpsonEffective(userChatCounts.values)
            let chat = context.activeSubjectChats > 0 ? subjectChats / Double(context.activeSubjectChats) : 0
            return VernacularTemplateEngine.geometricMean([max(day, 0.05), max(chat, 0.05)])
        }

        func topFills(limit: Int) -> [VernacularProfileTemplate.Fill] {
            fills.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map { VernacularProfileTemplate.Fill(fill: $0.key, count: $0.value) }
        }

        var fillEntropy: Double {
            VernacularTemplateEngine.normalizedEntropy(fills.values, universe: fills.count)
        }
    }

    static func visitPatternHashes(
        words: [String],
        nameTokens: Set<String>,
        config: VernacularConfig,
        _ visit: (UInt64) -> Void
    ) {
        visitPatternRefs(words: words, nameTokens: nameTokens, config: config) { hash, _, _, _ in
            visit(hash)
        }
    }

    static func visitEligiblePatterns(
        words: [String],
        nameTokens: Set<String>,
        eligible: Set<UInt64>,
        config: VernacularConfig,
        shouldMaterialize: (UInt64) -> Bool,
        _ visit: (GeneratedPattern) -> Void
    ) {
        visitPatternRefs(words: words, nameTokens: nameTokens, config: config) { hash, start, length, anchors in
            guard eligible.contains(hash),
                  shouldMaterialize(hash),
                  let pattern = materializePattern(words: words, start: start, length: length,
                                                   anchors: anchors, hash: hash, config: config) else {
                return
            }
            visit(pattern)
        }
    }

    static func visitPatternRefs(
        words: [String],
        nameTokens: Set<String>,
        config: VernacularConfig,
        _ visit: (UInt64, Int, Int, AnchorSelection) -> Void
    ) {
        guard words.count >= 2, words.count <= config.maxTemplateMessageTokens else { return }
        let usableAnchors = words.map { isUsableAnchor($0, nameTokens: nameTokens) }
        var emitted = 0
        let maxSpan = min(config.maxTemplateSpanTokens, words.count)

        func emit(start: Int, length: Int, anchors: AnchorSelection) -> Bool {
            guard emitted < config.maxTemplatePatternsPerMessage else { return false }
            guard let hash = patternHash(words: words, start: start, length: length,
                                         anchors: anchors, config: config) else {
                return true
            }
            emitted += 1
            visit(hash, start, length, anchors)
            return emitted < config.maxTemplatePatternsPerMessage
        }

        for start in 0..<words.count {
            guard emitted < config.maxTemplatePatternsPerMessage else { return }
            let remaining = words.count - start
            guard remaining >= 2 else { break }
            for length in 2...min(maxSpan, remaining) {
                guard emitted < config.maxTemplatePatternsPerMessage else { return }
                var anchorPositions: [Int] = []
                anchorPositions.reserveCapacity(min(config.maxTemplateAnchorsPerWindow, length))
                for rel in 0..<length where usableAnchors[start + rel] {
                    anchorPositions.append(rel)
                    if anchorPositions.count >= config.maxTemplateAnchorsPerWindow { break }
                }
                guard !anchorPositions.isEmpty else { continue }

                if config.allowSingleAnchorEdgeTemplates, length == 2 {
                    for anchor in anchorPositions where anchor == 0 || anchor == length - 1 {
                        guard emit(start: start, length: length, anchors: AnchorSelection(anchor)) else { return }
                    }
                }

                for i in 0..<anchorPositions.count {
                    for j in (i + 1)..<anchorPositions.count {
                        let anchors = AnchorSelection(anchorPositions[i], anchorPositions[j])
                        guard emit(start: start, length: length, anchors: anchors) else { return }
                    }
                }

                guard config.maxTemplateAnchors >= 3, anchorPositions.count >= 3 else { continue }
                for i in 0..<anchorPositions.count {
                    for j in (i + 1)..<anchorPositions.count {
                        for k in (j + 1)..<anchorPositions.count {
                            let anchors = AnchorSelection(anchorPositions[i], anchorPositions[j], anchorPositions[k])
                            guard emit(start: start, length: length, anchors: anchors) else { return }
                        }
                    }
                }
            }
        }
    }

    private static func patternHash(
        words: [String],
        start: Int,
        length: Int,
        anchors: AnchorSelection,
        config: VernacularConfig
    ) -> UInt64? {
        guard anchors.count <= config.maxTemplateAnchors else { return nil }
        guard anchors.count >= 2 || (config.allowSingleAnchorEdgeTemplates && length == 2) else { return nil }
        var hash = fnvOffset
        var slotCount = 0
        var i = 0
        while i < length {
            if anchors.contains(i) {
                appendString(words[start + i], to: &hash)
                appendSeparator(to: &hash)
                i += 1
            } else {
                let slotStart = i
                while i < length && !anchors.contains(i) { i += 1 }
                let slotLength = i - slotStart
                guard slotLength > 0, slotLength <= config.maxTemplateSlotTokens else { return nil }
                slotCount += 1
                guard slotCount <= config.maxTemplateSlots else { return nil }
                appendSlot(to: &hash)
                appendSeparator(to: &hash)
            }
        }
        guard slotCount > 0 else { return nil }
        return hash
    }

    static func materializePattern(
        words: [String],
        start: Int,
        length: Int,
        anchors: AnchorSelection,
        hash: UInt64,
        config: VernacularConfig
    ) -> GeneratedPattern? {
        guard anchors.count <= config.maxTemplateAnchors else { return nil }
        guard anchors.count >= 2 || (config.allowSingleAnchorEdgeTemplates && length == 2) else { return nil }
        var parts: [String] = []
        var fillParts: [String] = []
        var anchorTokens: [String] = []
        parts.reserveCapacity(anchors.count + config.maxTemplateSlots)
        fillParts.reserveCapacity(config.maxTemplateSlots)
        anchorTokens.reserveCapacity(anchors.count)

        var slotCount = 0
        var i = 0
        while i < length {
            if anchors.contains(i) {
                let token = words[start + i]
                parts.append(token)
                anchorTokens.append(token)
                i += 1
            } else {
                let slotStart = i
                while i < length && !anchors.contains(i) { i += 1 }
                let slotLength = i - slotStart
                guard slotLength > 0, slotLength <= config.maxTemplateSlotTokens else { return nil }
                slotCount += 1
                guard slotCount <= config.maxTemplateSlots else { return nil }
                parts.append("_")
                fillParts.append(words[(start + slotStart)..<(start + i)].joined(separator: " "))
            }
        }
        guard slotCount > 0 else { return nil }
        let key = parts.joined(separator: " ")
        return GeneratedPattern(key: key, hash: hash, anchors: anchorTokens,
                                slotCount: slotCount, fillKey: fillParts.joined(separator: " | "))
    }

    private static func isUsableAnchor(_ token: String, nameTokens: Set<String>) -> Bool {
        guard token.count >= 2 else { return false }
        if token.contains("'") || token.contains("\u{2019}") { return false }
        if VernacularAnalyzer.isNameForm(token, nameTokens: nameTokens) { return false }
        if VernacularAnalyzer.isSingleRepeatedLetterTok(token) || VernacularAnalyzer.isLaughMashTok(token) {
            return false
        }
        return true
    }

    private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private static func appendString(_ string: String, to hash: inout UInt64) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
    }

    private static func appendSlot(to hash: inout UInt64) {
        hash ^= 0x5F
        hash &*= fnvPrime
    }

    private static func appendSeparator(to hash: inout UInt64) {
        hash ^= 0x1F
        hash &*= fnvPrime
    }

    static func corpusAllowed(_ message: VernacularMessage) -> Bool {
        !message.isPoll && !message.bodyLow.contains("http") && !message.words.isEmpty
    }

    private static func anchorDistinctiveness(_ anchors: [String], baseline: LinguisticBaseline) -> Double {
        guard !anchors.isEmpty else { return 0 }
        let values = anchors.map { token -> Double in
            let p = max(baseline.probability(of: token), 1e-12)
            return min(1.0, max(0, -log(p) / 18.0))
        }
        return values.reduce(0, +) / Double(values.count)
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
