//
//  VernacularSpread.swift
//  Hourglass - Phase-1 profile spread overlay
//

import Foundation

// MARK: - Sense parsing (surface#family → clean surface + friendly tag)

/// A published spread token's sense, parsed off its raw `"surface#family"` or
/// explicit spread id form. The `surface` renders prominently; `tag` renders as
/// optional supporting copy. Kept here because the old transmission view is gone
/// but the social-graph vocabulary lens still needs the display helper.
struct SenseLabel: Equatable {
    let surface: String
    let tag: String?

    init(raw: String) {
        if raw.hasPrefix("voc:") {
            self.surface = String(raw.dropFirst(4))
            self.tag = "as address"
            return
        }
        guard let hash = raw.firstIndex(of: "#") else {
            self.surface = raw
            self.tag = nil
            return
        }
        self.surface = String(raw[raw.startIndex..<hash])
        let familyRaw = String(raw[raw.index(after: hash)...])
        self.tag = Self.friendly(family: familyRaw)
    }

    private static func friendly(family: String) -> String? {
        var name = family
        while let last = name.last, last.isNumber { name.removeLast() }
        switch name.lowercased() {
        case "address":      return "as address"
        case "reference":    return "literal"
        case "discourse":    return "discourse marker"
        case "intensifier":  return "intensifier"
        case "derivational": return "derivational"
        case "general", "":  return nil
        default:             return name.isEmpty ? nil : name
        }
    }
}

/// Additive v1 spread profile for the Vocabulary lens.
///
/// V1 uses the device owner's `profile.words` plus bounded POS-context sense
/// surfaces as the global term universe. Reclaimed words are more expensive to
/// materialize for every contact, so they are included only in the lazy
/// per-person influence panel.
public struct SpreadProfile: Sendable, Equatable {
    public enum TermKind: String, Sendable, Equatable {
        case word
        case reclaimed
    }

    public struct Term: Sendable, Equatable, Identifiable {
        public let id: String
        public let rank: Int
        public let surface: String
        public let kind: TermKind
        public let spread: Int
        public let breadth: Int
        public let totalUses: Int
        public let sources: Set<String>
        public let adopters: Set<String>
        public let users: Set<String>
        public let senseTag: String?
        public var displaySurface: String {
            if let senseTag, !senseTag.isEmpty { return "\(surface) (\(senseTag))" }
            return surface
        }
        public var selectionKey: String {
            senseTag == nil ? surface : id
        }

        public init(
            id: String,
            rank: Int,
            surface: String,
            kind: TermKind,
            spread: Int,
            breadth: Int,
            totalUses: Int,
            users: Set<String>,
            sources: Set<String> = [],
            adopters: Set<String> = [],
            senseTag: String? = nil
        ) {
            self.id = id
            self.rank = rank
            self.surface = surface
            self.kind = kind
            self.spread = spread
            self.breadth = breadth
            self.totalUses = totalUses
            self.sources = sources
            self.adopters = adopters
            self.users = users
            self.senseTag = senseTag
        }
    }

    public let subject: VernacularSubject
    public let terms: [Term]
    public let graph: VernacularGraph

    public init(subject: VernacularSubject = .you, terms: [Term], graph: VernacularGraph = .empty) {
        self.subject = subject
        self.terms = terms
        self.graph = graph
    }

    public static let empty = SpreadProfile(subject: .you, terms: [], graph: .empty)
    public var isEmpty: Bool { terms.isEmpty }
}

public struct ProfileTermRef: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case word
        case reclaimed
    }

    public let id: String
    public let kind: Kind
    public let surface: String
    public let score: Double
    public let count: Int
    public let example: String?

    public init(
        id: String,
        kind: Kind,
        surface: String,
        score: Double,
        count: Int,
        example: String?
    ) {
        self.id = id
        self.kind = kind
        self.surface = surface
        self.score = score
        self.count = count
        self.example = example
    }
}

public struct InfluencedTerm: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable, Equatable {
        case theyToYou
        case youToThem
        case both
        case independent
    }

    public let id: String
    public let surface: String
    public let direction: Direction
    public let headstart: Int
    public let yourFirstUse: Date?
    public let theirFirstUse: Date?
    public let lagDays: Int?
    public let example: String?
    public let confidence: String
    public let senseTag: String?
    public var displaySurface: String {
        if let senseTag, !senseTag.isEmpty { return "\(surface) (\(senseTag))" }
        return surface
    }

    public init(
        id: String,
        surface: String,
        direction: Direction,
        headstart: Int,
        yourFirstUse: Date?,
        theirFirstUse: Date?,
        lagDays: Int?,
        example: String?,
        confidence: String,
        senseTag: String? = nil
    ) {
        self.id = id
        self.surface = surface
        self.direction = direction
        self.headstart = headstart
        self.yourFirstUse = yourFirstUse
        self.theirFirstUse = theirFirstUse
        self.lagDays = lagDays
        self.example = example
        self.confidence = confidence
        self.senseTag = senseTag
    }
}

public struct PersonInfluence: Sendable, Equatable {
    public let person: String
    public let theirIdiolect: [ProfileTermRef]
    public let theyToYou: [InfluencedTerm]
    public let youToThem: [InfluencedTerm]
    public let independentCoUse: [InfluencedTerm]

    public init(
        person: String,
        theirIdiolect: [ProfileTermRef],
        theyToYou: [InfluencedTerm],
        youToThem: [InfluencedTerm],
        independentCoUse: [InfluencedTerm]
    ) {
        self.person = person
        self.theirIdiolect = theirIdiolect
        self.theyToYou = theyToYou
        self.youToThem = youToThem
        self.independentCoUse = independentCoUse
    }

    public static func empty(person: String) -> PersonInfluence {
        PersonInfluence(person: person, theirIdiolect: [], theyToYou: [],
                        youToThem: [], independentCoUse: [])
    }

    public var isEmpty: Bool {
        theirIdiolect.isEmpty && theyToYou.isEmpty && youToThem.isEmpty
            && independentCoUse.isEmpty
    }
}

public extension VernacularLoader {
    /// Build the profile-word/POS-sense spread summary used by the Vocabulary chip bar.
    /// PURE: it reuses the existing decisive incoming/outgoing graph rules over
    /// the already-loaded corpus and does not touch the legacy transmission path.
    static func buildSpread(
        profile: VernacularProfile,
        messages: [VernacularMessage],
        baseline: LinguisticBaseline? = nil,
        config: VernacularConfig = .default,
        chatParticipants: [Int64: Set<String>] = [:],
        options: VernacularAnalyzer.GraphOptions = .default,
        minContactUses: Int = 2
    ) -> SpreadProfile {
        guard profile.isEnabled, profile.subject.isYou, !profile.words.isEmpty else {
            return .empty
        }

        var terms = VernacularAnalyzer.spreadTermSpecs(from: profile.words)
        // Operator item 7: the user's RECLAIMED words (cone, aura, …) belong in
        // the spread cloud too — they're the most personal terms of all.
        let wordSurfaces = Set(terms.map(\.surface))
        let reclaimedSpecs = VernacularAnalyzer.spreadTermSpecs(
            fromReclaimed: profile.reclaimedWords,
            excluding: wordSurfaces
        )
        let reclaimedIDs = Set(reclaimedSpecs.map(\.id))
        terms.append(contentsOf: reclaimedSpecs)
        terms.append(contentsOf: VernacularAnalyzer.posSenseTermSpecs(
            messages: messages,
            baseline: baseline,
            config: config
        ))
        guard !terms.isEmpty else { return .empty }

        let accumulators = VernacularAnalyzer.spreadAccumulators(for: terms)
        let graph = VernacularAnalyzer.assembleGraph(
            accumulators: accumulators,
            messages: messages,
            chatParticipants: chatParticipants,
            options: options
        )
        let accByID = Dictionary(uniqueKeysWithValues: accumulators.map { ($0.label, $0) })

        var spreadPeopleBySurface: [String: Set<String>] = [:]
        var sourcePeopleBySurface: [String: Set<String>] = [:]
        var adopterPeopleBySurface: [String: Set<String>] = [:]
        for edge in graph.edges {
            for flow in edge.terms {
                if edge.direction == .theyGaveYou,
                   let acc = accByID[flow.term],
                   acc.total.count > options.maxDistinctContacts {
                    continue
                }
                spreadPeopleBySurface[flow.term, default: []].insert(edge.person)
                switch edge.direction {
                case .theyGaveYou:
                    sourcePeopleBySurface[flow.term, default: []].insert(edge.person)
                case .youGaveThem:
                    adopterPeopleBySurface[flow.term, default: []].insert(edge.person)
                }
            }
        }

        var ranked: [(id: String, surface: String, senseTag: String?, spread: Int, breadth: Int, total: Int, users: Set<String>)] = []
        for term in terms {
            guard let acc = accByID[term.id] else { continue }
            let contactUsers = acc.total
                .filter { $0.value >= minContactUses }
                .map(\.key)
                .sorted()
            let totalUses = acc.yourTotal + acc.total.values.reduce(0, +)
            ranked.append((
                id: term.id,
                surface: term.surface,
                senseTag: term.senseTag,
                spread: spreadPeopleBySurface[term.id]?.count ?? 0,
                breadth: contactUsers.count,
                total: totalUses,
                users: Set(contactUsers)
            ))
        }

        ranked.sort {
            if $0.spread != $1.spread { return $0.spread > $1.spread }
            if $0.breadth != $1.breadth { return $0.breadth > $1.breadth }
            if $0.total != $1.total { return $0.total > $1.total }
            if $0.surface != $1.surface { return $0.surface < $1.surface }
            return $0.id < $1.id
        }

        let out = ranked.enumerated().map { idx, item in
            SpreadProfile.Term(
                id: "spread:\(item.id)",
                rank: idx + 1,
                surface: item.surface,
                kind: reclaimedIDs.contains(item.id) ? .reclaimed : .word,
                spread: item.spread,
                breadth: item.breadth,
                totalUses: item.total,
                users: item.users,
                sources: sourcePeopleBySurface[item.id] ?? [],
                adopters: adopterPeopleBySurface[item.id] ?? [],
                senseTag: item.senseTag
            )
        }
        return SpreadProfile(subject: profile.subject, terms: out, graph: graph)
    }
}

public extension VernacularAnalyzer {
    /// Lazy person panel: compare the device owner's profile to one clicked
    /// contact. The term universe is both profiles' words + reclaimed words,
    /// plus bounded POS-context sense surfaces, keeping the one extra pass
    /// bounded.
    static func personInfluence(
        person: String,
        you: VernacularProfile,
        them: VernacularProfile,
        messages: [VernacularMessage],
        baseline: LinguisticBaseline? = nil,
        config: VernacularConfig = .default,
        chatParticipants: [Int64: Set<String>] = [:],
        options: GraphOptions = .default
    ) -> PersonInfluence {
        guard you.isEnabled, you.subject.isYou, them.isEnabled else {
            return .empty(person: person)
        }

        let youRefs = profileRefs(from: you.words, kind: .word)
            + profileRefs(from: you.reclaimedWords, kind: .reclaimed)
        let themRefs = profileRefs(from: them.reclaimedWords, kind: .reclaimed)
            + profileRefs(from: them.words, kind: .word)

        var orderedTerms: [SpreadTermSpec] = []
        var seen = Set<String>()
        for surface in (youRefs + themRefs).map(\.surface) {
            let normalized = normalizedSpreadSurface(surface)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            orderedTerms.append(SpreadTermSpec(surface: normalized,
                                               tokens: normalized.split(separator: " ").map(String.init)))
        }
        for term in posSenseTermSpecs(messages: messages, baseline: baseline, config: config) {
            guard !seen.contains(term.id) else { continue }
            seen.insert(term.id)
            orderedTerms.append(term)
        }
        guard !orderedTerms.isEmpty else {
            return PersonInfluence(person: person, theirIdiolect: themRefs,
                                   theyToYou: [], youToThem: [], independentCoUse: [])
        }

        let accumulators = spreadAccumulators(for: orderedTerms)
        _ = assembleGraph(accumulators: accumulators, messages: messages,
                          chatParticipants: chatParticipants, options: options)
        let accByID = Dictionary(uniqueKeysWithValues: accumulators.map { ($0.label, $0) })
        let day = 86_400.0

        var incomingRows: [InfluencedTerm] = []
        var outgoingRows: [InfluencedTerm] = []

        // Run BOTH directional rules on EVERY universe surface. The earlier
        // youSurfaceSet/themSurfaceSet pre-gates restricted each direction to the
        // respective party's TOP-40 list, which silently dropped real edges where a
        // term one person uses heavily never cracked the OTHER's top list — e.g.
        // "aiaiaii"/"yuh" you adopted from a friend but that aren't in your top-40,
        // or "cone" you gave a friend but that isn't in THEIR top-40. incoming()/
        // outgoing() already self-gate (yourTotal>0, ≥5-before, ≥30-day, 2×-dominance,
        // adopterMinTotal, shared-exposure), so widening the candidate set cannot
        // admit ambient register: common words have no single 2×-dominant early
        // source, so incoming() returns nil for them.
        var influencedTermIDs = Set<String>()
        for term in orderedTerms {
            guard let acc = accByID[term.id] else { continue }
            // THEY → YOU: `person` was your dominant early source for a term you use.
            // NOTE: no maxDistinctContacts niche gate here. The per-person panel is an
            // explicit query about ONE person, and the 2×-dominance rule already
            // excludes ambient register — "yuh" is used by 31 people yet Venkat is the
            // clear source (21 before you vs runner-up 3). The niche gate stays on the
            // auto-generated top-bar (buildSpread), where ambient words must not show.
            if let inc = incoming(acc, options: options, day: day), inc.source == person {
                influencedTermIDs.insert(term.id)
                incomingRows.append(InfluencedTerm(
                    id: "in:\(person):\(term.id)",
                    surface: term.surface,
                    direction: .theyToYou,
                    headstart: inc.before,
                    yourFirstUse: Date(timeIntervalSince1970: acc.yourFirst),
                    theirFirstUse: Date(timeIntervalSince1970: inc.sourceFirst),
                    lagDays: lagDays(from: inc.sourceFirst, to: acc.yourFirst),
                    example: truncatedExample(acc.firstBodyByContact[person], max: options.exampleMaxChars),
                    confidence: confidence(before: inc.before, threshold: options.minBefore),
                    senseTag: term.senseTag
                ))
            }
            // YOU → THEM: you were `person`'s dominant early source (with exposure gate).
            let outs = outgoing(acc, options: options, day: day,
                                chatParticipants: chatParticipants)
            if let out = outs.first(where: { $0.adopter == person }) {
                influencedTermIDs.insert(term.id)
                outgoingRows.append(InfluencedTerm(
                    id: "out:\(person):\(term.id)",
                    surface: term.surface,
                    direction: .youToThem,
                    headstart: out.youBefore,
                    yourFirstUse: Date(timeIntervalSince1970: acc.yourFirst),
                    theirFirstUse: Date(timeIntervalSince1970: out.adopterFirst),
                    lagDays: lagDays(from: acc.yourFirst, to: out.adopterFirst),
                    example: truncatedExample(acc.firstBodyByContact[person], max: options.exampleMaxChars),
                    confidence: confidence(before: out.youBefore, threshold: options.minBefore),
                    senseTag: term.senseTag
                ))
            }
        }

        var independentRows: [InfluencedTerm] = []
        for term in orderedTerms where !influencedTermIDs.contains(term.id) {
            guard let acc = accByID[term.id],
                  acc.yourTotal > 0,
                  (acc.total[person] ?? 0) > 0 else { continue }
            independentRows.append(InfluencedTerm(
                id: "co:\(person):\(term.id)",
                surface: term.surface,
                direction: .independent,
                headstart: min(acc.yourTotal, acc.total[person] ?? 0),
                yourFirstUse: acc.yourFirst < .greatestFiniteMagnitude
                    ? Date(timeIntervalSince1970: acc.yourFirst) : nil,
                theirFirstUse: acc.firstByContact[person].map { Date(timeIntervalSince1970: $0) },
                lagDays: acc.firstByContact[person].flatMap { lagDays(from: min(acc.yourFirst, $0), to: max(acc.yourFirst, $0)) },
                example: truncatedExample(acc.firstBodyByContact[person], max: options.exampleMaxChars),
                confidence: "co-use",
                senseTag: term.senseTag
            ))
        }

        incomingRows = rankDirectionalInfluenceRows(incomingRows, limit: 8)
        outgoingRows = rankDirectionalInfluenceRows(outgoingRows, limit: 8)
        independentRows = independentRows
            .filter { $0.headstart >= options.minBefore }
            .sorted {
                if $0.headstart != $1.headstart { return $0.headstart > $1.headstart }
                return $0.id < $1.id
            }
        independentRows = Array(independentRows.prefix(6))

        return PersonInfluence(
            person: person,
            theirIdiolect: themRefs,
            theyToYou: incomingRows,
            youToThem: outgoingRows,
            independentCoUse: independentRows
        )
    }
}

// MARK: - Internal helpers

struct SpreadTermSpec: Sendable {
    let id: String
    let surface: String
    let tokens: [String]
    let distinctive: Bool
    let senseTag: String?
    let predicate: (@Sendable (VernacularMessage) -> Bool)?

    init(
        id: String? = nil,
        surface: String,
        tokens: [String],
        distinctive: Bool = true,
        senseTag: String? = nil,
        predicate: (@Sendable (VernacularMessage) -> Bool)? = nil
    ) {
        self.id = id ?? surface
        self.surface = surface
        self.tokens = tokens
        self.distinctive = distinctive
        self.senseTag = senseTag
        self.predicate = predicate
    }
}

extension VernacularAnalyzer {
    static func spreadTermSpecs(from words: [VernacularProfilePhrase]) -> [SpreadTermSpec] {
        var out: [SpreadTermSpec] = []
        var seen = Set<String>()
        for item in words {
            let surface = normalizedSpreadSurface(item.surface)
            guard !surface.isEmpty, !seen.contains(surface) else { continue }
            let tokens = item.tokens.isEmpty ? surface.split(separator: " ").map(String.init) : item.tokens
            guard !tokens.isEmpty else { continue }
            seen.insert(surface)
            out.append(SpreadTermSpec(surface: surface, tokens: tokens, distinctive: true))
        }
        return out
    }

    static func posSenseTermSpecs(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline?,
        config: VernacularConfig
    ) -> [SpreadTermSpec] {
        VernacularPOSSense.detectVocativeSurfaces(messages: messages,
                                                  baseline: baseline,
                                                  config: config)
            .map { surface in
                let ids = surface.messageIDs
                return SpreadTermSpec(
                    id: surface.id,
                    surface: surface.surface,
                    tokens: surface.tokens,
                    distinctive: true,
                    senseTag: surface.senseTag,
                    predicate: { message in
                        message.messageID >= 0 && ids.contains(message.messageID)
                    }
                )
            }
    }

    /// Reclaimed-word specs for the spread universe (operator item 7). Folded
    /// bigrams ("holy bang") come through as token sequences like any phrase.
    static func spreadTermSpecs(
        fromReclaimed words: [VernacularProfileReclaimedWord],
        excluding seen: Set<String>
    ) -> [SpreadTermSpec] {
        var out: [SpreadTermSpec] = []
        var localSeen = seen
        for item in words {
            let surface = normalizedSpreadSurface(item.surface)
            guard !surface.isEmpty, !localSeen.contains(surface) else { continue }
            let tokens = surface.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { continue }
            localSeen.insert(surface)
            out.append(SpreadTermSpec(surface: surface, tokens: tokens, distinctive: true))
        }
        return out
    }

    static func spreadAccumulators(for terms: [SpreadTermSpec]) -> [GraphAcc] {
        terms.map { term in
            if let predicate = term.predicate {
                return GraphAcc(term.id, predicate, distinctive: term.distinctive)
            }
            return GraphAcc(term.id, { message in
                if term.tokens.count == 1 {
                    return message.wordSet.contains(term.tokens[0])
                }
                return hasSubsequence(message.words, term.tokens)
            }, distinctive: term.distinctive)
        }
    }

    static func profileRefs(from words: [VernacularProfilePhrase], kind: ProfileTermRef.Kind) -> [ProfileTermRef] {
        words.map {
            ProfileTermRef(
                id: "\(kind.rawValue):\($0.surface)",
                kind: kind,
                surface: normalizedSpreadSurface($0.surface),
                score: $0.score,
                count: $0.counts.userMessages,
                example: $0.examples.first
            )
        }
    }

    static func profileRefs(from words: [VernacularProfileReclaimedWord], kind: ProfileTermRef.Kind) -> [ProfileTermRef] {
        words.map {
            ProfileTermRef(
                id: "\(kind.rawValue):\($0.surface)",
                kind: kind,
                surface: normalizedSpreadSurface($0.surface),
                score: $0.score,
                count: $0.counts.userMessages,
                example: $0.examples.first
            )
        }
    }

    static func normalizedSpreadSurface(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func lagDays(from earlier: Double, to later: Double) -> Int? {
        guard earlier.isFinite, later.isFinite else { return nil }
        return Int((later - earlier) / 86_400.0)
    }

    static func confidence(before: Int, threshold: Int) -> String {
        before >= threshold * 2 ? "high" : "medium"
    }

    static func rankDirectionalInfluenceRows(_ rows: [InfluencedTerm], limit: Int) -> [InfluencedTerm] {
        Array(rows.sorted {
            let c0 = confidenceRank($0.confidence)
            let c1 = confidenceRank($1.confidence)
            if c0 != c1 { return c0 > c1 }
            if $0.headstart != $1.headstart { return $0.headstart > $1.headstart }
            if ($0.lagDays ?? Int.max) != ($1.lagDays ?? Int.max) {
                return ($0.lagDays ?? Int.max) < ($1.lagDays ?? Int.max)
            }
            return $0.id < $1.id
        }.prefix(limit))
    }

    static func confidenceRank(_ confidence: String) -> Int {
        switch confidence {
        case "high": return 2
        case "medium": return 1
        default: return 0
        }
    }
}
