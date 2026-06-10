//
//  VernacularProfile.swift
//  Hourglass - Unified Vernacular Profile
//

import Foundation

/// Phase-1 output: the phrases and generalized templates that define how the
/// user texts. Transmission/graph attribution is intentionally not embedded
/// here; Phase 2 should consume stable item ids from this profile.
public struct VernacularProfile: Sendable, Equatable {
    public let isEnabled: Bool
    public let subject: VernacularSubject
    public let words: [VernacularProfilePhrase]
    public let circleSlang: [VernacularProfilePhrase]
    public let phrases: [VernacularProfilePhrase]
    public let reclaimedWords: [VernacularProfileReclaimedWord]
    public let reclaimedContextDiagnostics: [VernacularReclaimedContextDecision]
    public let templates: [VernacularProfileTemplate]
    public let topics: [VernacularProfilePhrase]
    public let stats: Stats

    public struct Stats: Sendable, Equatable {
        public let subjectName: String
        public let subjectIsYou: Bool
        public let lowConfidence: Bool
        public let caveat: String?
        public let totalMessages: Int
        public let worldMessages: Int
        public let sentMessages: Int
        public let receivedMessages: Int
        public let activeContacts: Int
        public let candidateNgramHashes: Int
        public let exactNgramCandidates: Int
        public let candidateTemplateHashes: Int
        public let exactTemplateCandidates: Int
        public let corpusMaxDate: Double?

        public init(
            subjectName: String = "You",
            subjectIsYou: Bool = true,
            lowConfidence: Bool = false,
            caveat: String? = nil,
            totalMessages: Int = 0,
            worldMessages: Int = 0,
            sentMessages: Int = 0,
            receivedMessages: Int = 0,
            activeContacts: Int = 0,
            candidateNgramHashes: Int = 0,
            exactNgramCandidates: Int = 0,
            candidateTemplateHashes: Int = 0,
            exactTemplateCandidates: Int = 0,
            corpusMaxDate: Double? = nil
        ) {
            self.subjectName = subjectName
            self.subjectIsYou = subjectIsYou
            self.lowConfidence = lowConfidence
            self.caveat = caveat
            self.totalMessages = totalMessages
            self.worldMessages = worldMessages
            self.sentMessages = sentMessages
            self.receivedMessages = receivedMessages
            self.activeContacts = activeContacts
            self.candidateNgramHashes = candidateNgramHashes
            self.exactNgramCandidates = exactNgramCandidates
            self.candidateTemplateHashes = candidateTemplateHashes
            self.exactTemplateCandidates = exactTemplateCandidates
            self.corpusMaxDate = corpusMaxDate
        }
    }

    public init(
        isEnabled: Bool,
        subject: VernacularSubject = .you,
        words: [VernacularProfilePhrase],
        circleSlang: [VernacularProfilePhrase] = [],
        phrases: [VernacularProfilePhrase],
        reclaimedWords: [VernacularProfileReclaimedWord] = [],
        reclaimedContextDiagnostics: [VernacularReclaimedContextDecision] = [],
        templates: [VernacularProfileTemplate],
        topics: [VernacularProfilePhrase] = [],
        stats: Stats
    ) {
        self.isEnabled = isEnabled
        self.subject = subject
        self.words = words
        self.circleSlang = circleSlang
        self.phrases = phrases
        self.reclaimedWords = reclaimedWords
        self.reclaimedContextDiagnostics = reclaimedContextDiagnostics
        self.templates = templates
        self.topics = topics
        self.stats = stats
    }

    public static let disabled = VernacularProfile(isEnabled: false, subject: .you,
                                                   words: [], circleSlang: [],
                                                   phrases: [], templates: [],
                                                   topics: [], stats: Stats())
}

public struct VernacularProfilePhrase: Sendable, Equatable, Identifiable {
    public let id: String
    public let rank: Int
    public let surface: String
    public let tokens: [String]
    public let n: Int
    public let score: Double
    public let features: VernacularProfileFeatures
    public let counts: VernacularProfileCounts
    public let examples: [String]

    public init(
        id: String,
        rank: Int,
        surface: String,
        tokens: [String],
        n: Int,
        score: Double,
        features: VernacularProfileFeatures,
        counts: VernacularProfileCounts,
        examples: [String]
    ) {
        self.id = id
        self.rank = rank
        self.surface = surface
        self.tokens = tokens
        self.n = n
        self.score = score
        self.features = features
        self.counts = counts
        self.examples = examples
    }
}

public struct VernacularProfileReclaimedWord: Sendable, Equatable, Identifiable {
    public let id: String
    public let rank: Int
    public let surface: String
    public let score: Double
    public let counts: VernacularProfileCounts
    public let worldEff: Double
    public let percentile: Double
    public let collocation: Double
    public let senseDistance: Double
    public let roleSkew: Double
    public let concentration: Double
    public let topCollocationPartner: String?
    public let examples: [String]
    public let contextVerdict: VernacularReclaimedContextVerdict
    public let contextSlangRate: Double
    public let contextTopicRate: Double
    public let contextKeepMargin: Double

    public init(
        id: String,
        rank: Int,
        surface: String,
        score: Double,
        counts: VernacularProfileCounts,
        worldEff: Double,
        percentile: Double,
        collocation: Double,
        senseDistance: Double,
        roleSkew: Double,
        concentration: Double,
        topCollocationPartner: String?,
        examples: [String],
        contextVerdict: VernacularReclaimedContextVerdict = .keep,
        contextSlangRate: Double = 0,
        contextTopicRate: Double = 0,
        contextKeepMargin: Double = 0
    ) {
        self.id = id
        self.rank = rank
        self.surface = surface
        self.score = score
        self.counts = counts
        self.worldEff = worldEff
        self.percentile = percentile
        self.collocation = collocation
        self.senseDistance = senseDistance
        self.roleSkew = roleSkew
        self.concentration = concentration
        self.topCollocationPartner = topCollocationPartner
        self.examples = examples
        self.contextVerdict = contextVerdict
        self.contextSlangRate = contextSlangRate
        self.contextTopicRate = contextTopicRate
        self.contextKeepMargin = contextKeepMargin
    }
}

public enum VernacularReclaimedContextVerdict: String, Sendable, Equatable {
    case keep = "KEEP"
    case remove = "REMOVE"
    case neutral = "NEUTRAL"
}

public struct VernacularReclaimedContextDecision: Sendable, Equatable, Identifiable {
    public let id: String
    public let surface: String
    public let rank: Int
    public let verdict: VernacularReclaimedContextVerdict
    public let slangRate: Double
    public let topicRate: Double
    public let keepMargin: Double
    public let topicCategoryProximity: Double
    public let namedEntityRate: Double
    public let windows: Int
    public let topCollocationPartner: String?
    public let example: String?

    public init(
        id: String,
        surface: String,
        rank: Int,
        verdict: VernacularReclaimedContextVerdict,
        slangRate: Double,
        topicRate: Double,
        keepMargin: Double,
        topicCategoryProximity: Double,
        namedEntityRate: Double,
        windows: Int,
        topCollocationPartner: String?,
        example: String?
    ) {
        self.id = id
        self.surface = surface
        self.rank = rank
        self.verdict = verdict
        self.slangRate = slangRate
        self.topicRate = topicRate
        self.keepMargin = keepMargin
        self.topicCategoryProximity = topicCategoryProximity
        self.namedEntityRate = namedEntityRate
        self.windows = windows
        self.topCollocationPartner = topCollocationPartner
        self.example = example
    }
}

public struct VernacularProfileTemplate: Sendable, Equatable, Identifiable {
    public let id: String
    public let rank: Int
    public let pattern: String
    public let anchors: [String]
    public let slotCount: Int
    public let score: Double
    public let features: VernacularProfileFeatures
    public let counts: VernacularProfileCounts
    public let topFills: [Fill]
    public let examples: [String]

    public struct Fill: Sendable, Equatable, Identifiable {
        public let fill: String
        public let count: Int
        public var id: String { fill }
        public init(fill: String, count: Int) {
            self.fill = fill
            self.count = count
        }
    }

    public init(
        id: String,
        rank: Int,
        pattern: String,
        anchors: [String],
        slotCount: Int,
        score: Double,
        features: VernacularProfileFeatures,
        counts: VernacularProfileCounts,
        topFills: [Fill],
        examples: [String]
    ) {
        self.id = id
        self.rank = rank
        self.pattern = pattern
        self.anchors = anchors
        self.slotCount = slotCount
        self.score = score
        self.features = features
        self.counts = counts
        self.topFills = topFills
        self.examples = examples
    }
}

/// Feature breakdown exposed so the operator can inspect why an item ranked.
public struct VernacularProfileFeatures: Sendable, Equatable {
    public let length: Double
    public let peopleIDF: Double
    public let selfUsage: Double
    public let rarity: Double
    public let recency: Double
    public let spamResistance: Double
    public let glue: Double
    public let collocation: Double
    public let semanticShift: Double
    public let registerPenalty: Double
    public let style: Double
    public let topic: Double
    public let zWorld: Double
    public let zRole: Double
    public let dispersion: Double
    public let echo: Double
    public let burst: Double
    public let productivity: Double
    public let anchorDistinctiveness: Double
    public let embedding: Double
    public let finalScore: Double

    public init(
        length: Double = 0,
        peopleIDF: Double = 0,
        selfUsage: Double = 0,
        rarity: Double = 0,
        recency: Double = 0,
        spamResistance: Double = 0,
        glue: Double = 0,
        collocation: Double = 0,
        semanticShift: Double = 0,
        registerPenalty: Double = 0,
        style: Double = 0,
        topic: Double = 0,
        zWorld: Double = 0,
        zRole: Double = 0,
        dispersion: Double = 0,
        echo: Double = 0,
        burst: Double = 0,
        productivity: Double = 0,
        anchorDistinctiveness: Double = 0,
        embedding: Double = 0,
        finalScore: Double = 0
    ) {
        self.length = length
        self.peopleIDF = peopleIDF
        self.selfUsage = selfUsage
        self.rarity = rarity
        self.recency = recency
        self.spamResistance = spamResistance
        self.glue = glue
        self.collocation = collocation
        self.semanticShift = semanticShift
        self.registerPenalty = registerPenalty
        self.style = style
        self.topic = topic
        self.zWorld = zWorld
        self.zRole = zRole
        self.dispersion = dispersion
        self.echo = echo
        self.burst = burst
        self.productivity = productivity
        self.anchorDistinctiveness = anchorDistinctiveness
        self.embedding = embedding
        self.finalScore = finalScore
    }
}

public struct VernacularProfileCounts: Sendable, Equatable {
    public let userMessages: Int
    public let receivedMessages: Int
    public let activeContactUsers: Int
    public let distinctUserDays: Int
    public let effectiveUserMessages: Double
    public let maxUserDayShare: Double
    public let maxMonthShare: Double
    public let effectiveContacts: Double
    public let effectiveChats: Double
    public let worldMessages: Int
    public let recentUserMessages: Int
    public let olderUserMessages: Int

    public init(
        userMessages: Int = 0,
        receivedMessages: Int = 0,
        activeContactUsers: Int = 0,
        distinctUserDays: Int = 0,
        effectiveUserMessages: Double = 0,
        maxUserDayShare: Double = 0,
        maxMonthShare: Double = 0,
        effectiveContacts: Double = 0,
        effectiveChats: Double = 0,
        worldMessages: Int = 0,
        recentUserMessages: Int = 0,
        olderUserMessages: Int = 0
    ) {
        self.userMessages = userMessages
        self.receivedMessages = receivedMessages
        self.activeContactUsers = activeContactUsers
        self.distinctUserDays = distinctUserDays
        self.effectiveUserMessages = effectiveUserMessages
        self.maxUserDayShare = maxUserDayShare
        self.maxMonthShare = maxMonthShare
        self.effectiveContacts = effectiveContacts
        self.effectiveChats = effectiveChats
        self.worldMessages = worldMessages
        self.recentUserMessages = recentUserMessages
        self.olderUserMessages = olderUserMessages
    }
}
