//
//  VernacularModels.swift
//  Hourglass — Vernacular Analysis
//
//  Public value types produced by `VernacularAnalyzer`. All `Sendable` so the
//  whole result can cross the actor boundary from the background analysis to
//  the SwiftUI panel. Mirrors the categorized output of the validated
//  prototypes (`/tmp/slang3`, `/tmp/vern`, `/tmp/report`, `/tmp/bro`):
//
//    • Signature words      — distinctive unigrams (reuses LinguisticAnalyzer)
//    • Slang phrases        — NPMI-glued, over-represented bigrams/trigrams
//    • Templates            — formulaic skeletons with real fill-in examples
//    • Tags & constructions — trailing "… word?" + caps-vocative families
//    • Attributions         — DECISIVE "first seen in your texts" sources
//
//  AI labels (Layer 4) are attached OPTIONALLY: every lexical item carries an
//  `aiLabel: VernacularAILabel?` that is nil when the model isn't loaded and
//  populated only after the gated LLM pass runs over the shortlist.
//

import Foundation

// MARK: - AI label (Layer 4, optional)

/// A one-line semantic judgement from the gated LLM labeler. Attached to a
/// phrase/word when the model is available; absent otherwise. PURE data.
public struct VernacularAILabel: Sendable, Equatable {
    /// Coarse class the model assigned.
    public enum Kind: String, Sendable, Equatable {
        case slang        // in-group / internet-native slang
        case literal      // ordinary literal usage
        case idiom        // a fixed expression / idiom
        case repurposed   // ordinary words given an in-group meaning
        case name         // a proper noun the stats let through
        case unknown
    }
    public let kind: Kind
    /// A short human-readable description ("affectionate vocative address";
    /// "approval tag inviting agreement"). One line, model-written.
    public let description: String
    public init(kind: Kind, description: String) {
        self.kind = kind
        self.description = description
    }
}

// MARK: - Categorized result items

/// A distinctive single word (from `LinguisticAnalyzer`, re-wrapped so the
/// panel renders signature words alongside the new categories).
public struct VernacularSignatureWord: Sendable, Equatable, Identifiable {
    public let word: String
    public let count: Int
    /// Times-more-frequent than the baseline speaker (>= 1). Display-capped.
    public let timesMoreThanBaseline: Double
    public let absentFromBaseline: Bool
    public var aiLabel: VernacularAILabel?
    public var id: String { word }
    public init(word: String, count: Int, timesMoreThanBaseline: Double,
                absentFromBaseline: Bool, aiLabel: VernacularAILabel? = nil) {
        self.word = word
        self.count = count
        self.timesMoreThanBaseline = timesMoreThanBaseline
        self.absentFromBaseline = absentFromBaseline
        self.aiLabel = aiLabel
    }
}

/// A slang phrase (bigram/trigram) ranked by the lightweight signal stack.
public struct VernacularPhrase: Sendable, Equatable, Identifiable {
    public let phrase: String
    public let count: Int
    /// How many distinct people in your chats use it (spread).
    public let peopleCount: Int
    /// Social-uptake per use (amused reactions + downstream laughter).
    public let uptakePerUse: Double
    /// True if it's rising recently (recency burst).
    public let rising: Bool
    /// One real example message containing the phrase (for the card).
    public let example: String?
    /// Earliest user of the phrase across your chats ("first seen…").
    public let firstSeenWho: String
    public let firstSeenMonth: String
    /// True if the words are individually-common English but the PAIRING is
    /// rare (the "repurposed common phrase" / traffic-cone class).
    public let isRepurposedCandidate: Bool
    public var aiLabel: VernacularAILabel?
    public var id: String { phrase }
    public init(phrase: String, count: Int, peopleCount: Int, uptakePerUse: Double,
                rising: Bool, example: String?, firstSeenWho: String, firstSeenMonth: String,
                isRepurposedCandidate: Bool, aiLabel: VernacularAILabel? = nil) {
        self.phrase = phrase
        self.count = count
        self.peopleCount = peopleCount
        self.uptakePerUse = uptakePerUse
        self.rising = rising
        self.example = example
        self.firstSeenWho = firstSeenWho
        self.firstSeenMonth = firstSeenMonth
        self.isRepurposedCandidate = isRepurposedCandidate
        self.aiLabel = aiLabel
    }
}

/// A formulaic message template / snowclone with real fill-in examples.
/// "_" marks a word that varies; CAPS and emoji markers are kept.
public struct VernacularTemplate: Sendable, Equatable, Identifiable {
    /// The skeleton, e.g. "the way _ is" or "not _ being _".
    public let skeleton: String
    public let count: Int
    /// Up to two real sent messages matching the skeleton.
    public let examples: [String]
    public var aiLabel: VernacularAILabel?
    public var id: String { skeleton }
    public init(skeleton: String, count: Int, examples: [String], aiLabel: VernacularAILabel? = nil) {
        self.skeleton = skeleton
        self.count = count
        self.examples = examples
        self.aiLabel = aiLabel
    }
}

/// A trailing approval/question tag ("… right?", "… no?") or a caps-vocative
/// construction ("brother …", "… NOT … lil bro").
public struct VernacularConstruction: Sendable, Equatable, Identifiable {
    public enum Family: String, Sendable, Equatable {
        case tag           // trailing "… word?"
        case construction  // caps / vocative scaffolding
    }
    public let pattern: String     // "… no?", "brother …"
    public let family: Family
    public let count: Int
    public let uptakePerUse: Double
    public var aiLabel: VernacularAILabel?
    public var id: String { "\(family.rawValue):\(pattern)" }
    public init(pattern: String, family: Family, count: Int, uptakePerUse: Double,
                aiLabel: VernacularAILabel? = nil) {
        self.pattern = pattern
        self.family = family
        self.count = count
        self.uptakePerUse = uptakePerUse
        self.aiLabel = aiLabel
    }
}

/// A DECISIVE attribution: "you started using <term> on <date>; <source> used
/// it heavily before you." Reported ONLY when the source is unambiguous (see
/// `VernacularAnalyzer.attribute`). Otherwise `source` is nil ("no clear
/// source / ambient").
public struct VernacularAttribution: Sendable, Equatable, Identifiable {
    public let term: String
    public let yourCount: Int
    public let yourFirstMonth: String
    /// The decisive early source's display name, or nil for ambient/original.
    public let source: String?
    public let sourceBeforeCount: Int
    public let sourceFirstMonth: String
    public var id: String { term }
    public init(term: String, yourCount: Int, yourFirstMonth: String,
                source: String?, sourceBeforeCount: Int, sourceFirstMonth: String) {
        self.term = term
        self.yourCount = yourCount
        self.yourFirstMonth = yourFirstMonth
        self.source = source
        self.sourceBeforeCount = sourceBeforeCount
        self.sourceFirstMonth = sourceFirstMonth
    }
}

/// A sense-split summary for an ambiguous address term (Layer 2 result),
/// surfaced so the panel can show "you use 'brother' as slang N times".
public struct VernacularSenseSplit: Sendable, Equatable, Identifiable {
    public let term: String
    public let vocativeCount: Int    // the slang sense (counted)
    public let literalCount: Int     // the kinship sense (excluded)
    public var id: String { term }
    public init(term: String, vocativeCount: Int, literalCount: Int) {
        self.term = term
        self.vocativeCount = vocativeCount
        self.literalCount = literalCount
    }
}

// MARK: - Top-level result

/// The full Vernacular analysis. `Sendable` value type → crosses to the view.
public struct VernacularInsights: Sendable, Equatable {
    public var totalMessages: Int          // sent + received scanned
    public var sentMessages: Int
    public var signatureWords: [VernacularSignatureWord]
    public var slangPhrases: [VernacularPhrase]
    public var repurposedPhrases: [VernacularPhrase]
    public var templates: [VernacularTemplate]
    public var tags: [VernacularConstruction]
    public var constructions: [VernacularConstruction]
    public var attributions: [VernacularAttribution]
    public var senseSplits: [VernacularSenseSplit]

    public init(
        totalMessages: Int = 0,
        sentMessages: Int = 0,
        signatureWords: [VernacularSignatureWord] = [],
        slangPhrases: [VernacularPhrase] = [],
        repurposedPhrases: [VernacularPhrase] = [],
        templates: [VernacularTemplate] = [],
        tags: [VernacularConstruction] = [],
        constructions: [VernacularConstruction] = [],
        attributions: [VernacularAttribution] = [],
        senseSplits: [VernacularSenseSplit] = []
    ) {
        self.totalMessages = totalMessages
        self.sentMessages = sentMessages
        self.signatureWords = signatureWords
        self.slangPhrases = slangPhrases
        self.repurposedPhrases = repurposedPhrases
        self.templates = templates
        self.tags = tags
        self.constructions = constructions
        self.attributions = attributions
        self.senseSplits = senseSplits
    }

    public var isEmpty: Bool {
        sentMessages == 0 ||
        (signatureWords.isEmpty && slangPhrases.isEmpty && templates.isEmpty
         && tags.isEmpty && constructions.isEmpty)
    }

    /// Every lexical item that is a candidate for AI labeling, as a flat list
    /// of (id, phrase, examples) tuples. The labeler runs over THIS shortlist
    /// only — never over all messages. Keyed so results can be merged back.
    public func aiCandidates() -> [VernacularAICandidate] {
        var out: [VernacularAICandidate] = []
        for p in slangPhrases { out.append(.init(id: p.id, kind: .phrase, text: p.phrase, examples: p.example.map { [$0] } ?? [])) }
        for p in repurposedPhrases { out.append(.init(id: p.id, kind: .phrase, text: p.phrase, examples: p.example.map { [$0] } ?? [])) }
        for t in tags { out.append(.init(id: t.id, kind: .tag, text: t.pattern, examples: [])) }
        for c in constructions { out.append(.init(id: c.id, kind: .construction, text: c.pattern, examples: [])) }
        return out
    }
}

/// One item handed to the AI labeler. Keeps the labeler decoupled from the
/// full insight types — it just needs a stable id, the surface text, and a
/// few example messages.
public struct VernacularAICandidate: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case phrase, tag, construction, word }
    public let id: String
    public let kind: Kind
    public let text: String
    public let examples: [String]
    public init(id: String, kind: Kind, text: String, examples: [String]) {
        self.id = id
        self.kind = kind
        self.text = text
        self.examples = examples
    }
}
