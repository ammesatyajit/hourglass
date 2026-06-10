//
//  VernacularPOSSense.swift
//  Hourglass - POS/context sense split for spread terms
//

import Foundation
import NaturalLanguage

struct VernacularPOSSenseSurface: Sendable, Equatable {
    let id: String
    let surface: String
    let senseTag: String
    let messageIDs: Set<Int>
    let subjectUses: Int
    let contactUses: Int
    let totalVocativeUses: Int
    let totalWordUses: Int
    let vocativeRate: Double

    var tokens: [String] { [surface] }
}

enum VernacularPOSSense {
    private struct CacheKey: Hashable, Sendable {
        let count: Int
        let firstID: Int
        let lastID: Int
        let firstDateBits: UInt64
        let lastDateBits: UInt64
        let enabled: Bool
        let minInitial: Int
        let minUserUses: Int
        let maxCandidates: Int
        let minRateBits: UInt64
        let baselineCount: Int
        let baselineTotalBits: UInt64
        let baselinePlaceholder: Bool
    }

    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: CacheKey?
        private var value: [VernacularPOSSenseSurface] = []

        func value(for key: CacheKey) -> [VernacularPOSSenseSurface]? {
            lock.lock()
            defer { lock.unlock() }
            guard self.key == key else { return nil }
            return value
        }

        func store(_ value: [VernacularPOSSenseSurface], for key: CacheKey) {
            lock.lock()
            self.key = key
            self.value = value
            lock.unlock()
        }
    }

    private static let cache = CacheBox()

    private static let ambientInitials: Set<String> = [
        "ok", "okay", "hey", "hi", "hello", "yo", "yeah", "yep", "yes", "nah", "no",
        "lol", "lmao", "lmfao", "bro", "bruh", "omg", "oh", "uh", "um", "ah",
        "bye", "gn", "gm", "thanks", "thank", "ty", "wait", "today", "tomorrow",
        "tmrw", "sent", "send", "sending", "min", "mins", "minute", "minutes",
        "type", "thing", "things", "someone", "everyone", "anyone",
    ]

    private static let clauseStarterTokens: Set<String> = [
        "i", "im", "i'm", "ive", "i've", "ill", "i'll", "you", "u", "we", "they",
        "he", "she", "it", "this", "that", "the", "a", "an", "my", "your", "ur",
        "his", "her", "their", "our", "what", "when", "where", "why", "how", "who",
        "is", "are", "am", "was", "were", "be", "been", "being", "do", "does",
        "did", "have", "has", "had", "can", "could", "will", "would", "should",
        "not", "no", "so", "then",
    ]

    static func detectVocativeSurfaces(
        messages: [VernacularMessage],
        baseline: LinguisticBaseline?,
        config: VernacularConfig
    ) -> [VernacularPOSSenseSurface] {
        guard config.posSenseEnabled, !messages.isEmpty else { return [] }
        let key = CacheKey(
            count: messages.count,
            firstID: messages.first?.messageID ?? -1,
            lastID: messages.last?.messageID ?? -1,
            firstDateBits: (messages.first?.date ?? 0).bitPattern,
            lastDateBits: (messages.last?.date ?? 0).bitPattern,
            enabled: config.posSenseEnabled,
            minInitial: config.posSenseMinInitial,
            minUserUses: config.posSenseMinUserUses,
            maxCandidates: config.posSenseMaxCandidates,
            minRateBits: config.posSenseMinVocativeRate.bitPattern,
            baselineCount: baseline?.counts.count ?? 0,
            baselineTotalBits: (baseline?.totalCount ?? 0).bitPattern,
            baselinePlaceholder: baseline?.isPlaceholder ?? true
        )
        if let cached = cache.value(for: key) { return cached }

        let nameTokens = contactNameTokens(messages)
        var initialCounts: [String: Int] = [:]
        for message in messages {
            guard let first = firstAlphabeticToken(message.words) else { continue }
            initialCounts[first, default: 0] += 1
        }

        let candidates = initialCounts
            .filter { token, count in
                count >= config.posSenseMinInitial
                    && passesInitialFilter(token, baseline: baseline, nameTokens: nameTokens)
            }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(config.posSenseMaxCandidates)
            .map(\.key)
        let candidateSet = Set(candidates)
        guard !candidateSet.isEmpty else {
            cache.store([], for: key)
            return []
        }

        var totalWordUses: [String: Int] = [:]
        var messageIDsByBase: [String: Set<Int>] = [:]
        var subjectUses: [String: Int] = [:]
        var contactUses: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])

        for message in messages {
            for token in message.wordSet where candidateSet.contains(token) {
                totalWordUses[token, default: 0] += 1
            }
            guard message.messageID >= 0,
                  let first = firstAlphabeticToken(message.words),
                  candidateSet.contains(first) else { continue }
            let confirmed = autoreleasepool {
                isVocativeOpening(message: message, base: first, tagger: tagger)
            }
            guard confirmed else { continue }
            messageIDsByBase[first, default: []].insert(message.messageID)
            if message.fromMe {
                subjectUses[first, default: 0] += 1
            } else if message.who != "You", message.who != VernacularAnalyzer.unknownLabel {
                contactUses[first, default: 0] += 1
            }
        }

        var out: [VernacularPOSSenseSurface] = []
        for base in candidates {
            let ids = messageIDsByBase[base] ?? []
            let subj = subjectUses[base] ?? 0
            let contacts = contactUses[base] ?? 0
            let totalWord = max(totalWordUses[base] ?? 0, 1)
            let rate = Double(ids.count) / Double(totalWord)
            guard subj >= config.posSenseMinUserUses,
                  contacts > 0,
                  rate >= config.posSenseMinVocativeRate else { continue }
            out.append(VernacularPOSSenseSurface(
                id: "voc:\(base)",
                surface: base,
                senseTag: "as address",
                messageIDs: ids,
                subjectUses: subj,
                contactUses: contacts,
                totalVocativeUses: ids.count,
                totalWordUses: totalWord,
                vocativeRate: rate
            ))
        }

        out.sort {
            if $0.subjectUses != $1.subjectUses { return $0.subjectUses > $1.subjectUses }
            if $0.contactUses != $1.contactUses { return $0.contactUses > $1.contactUses }
            return $0.surface < $1.surface
        }
        cache.store(out, for: key)
        return out
    }

    private static func firstAlphabeticToken(_ words: [String]) -> String? {
        words.first { token in token.contains(where: { $0.isLetter }) }
    }

    private static func passesInitialFilter(
        _ token: String,
        baseline: LinguisticBaseline?,
        nameTokens: Set<String>
    ) -> Bool {
        guard token.count >= 3 else { return false }
        guard token.rangeOfCharacter(from: .letters) != nil else { return false }
        if nameTokens.contains(token) { return false }
        if ambientInitials.contains(token) { return false }
        if LinguisticStopwords.isStopword(token) { return false }
        if VernacularTextingRegister.penalty(for: token) >= 0.65 { return false }
        if VernacularAnalyzer.isContraction(token) { return false }
        if let baseline, baseline.probability(of: token) > 0.002 { return false }
        return true
    }

    private static func contactNameTokens(_ messages: [VernacularMessage]) -> Set<String> {
        var out = Set<String>()
        for message in messages where !message.fromMe
            && message.who != "You"
            && message.who != VernacularAnalyzer.unknownLabel {
            for part in message.who.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\u{00A0}" }) {
                let token = part.lowercased()
                if token.count >= 3 { out.insert(token) }
            }
        }
        return out
    }

    private static func isVocativeOpening(
        message: VernacularMessage,
        base: String,
        tagger: NLTagger
    ) -> Bool {
        let body = message.body
        guard !body.isEmpty else { return false }
        let low = message.bodyLow.trimmingCharacters(in: .whitespacesAndNewlines)
        if low.hasPrefix("\(base)'s") || low.hasPrefix("\(base)\u{2019}s") { return false }

        let tagged = leadingLexicalTokens(in: body, tagger: tagger, limit: 4)
        guard let first = tagged.first, first.token == base else { return false }
        guard first.tag == .noun || first.tag == .otherWord else { return false }
        guard tagged.count > 1 else { return true }
        let next = tagged[1]
        if clauseStarterTokens.contains(next.token) { return true }
        guard let nextTag = next.tag else { return false }
        switch nextTag {
        case .pronoun, .determiner, .verb, .adverb, .number, .adjective:
            return true
        default:
            return false
        }
    }

    private static func leadingLexicalTokens(
        in body: String,
        tagger: NLTagger,
        limit: Int
    ) -> [(token: String, tag: NLTag?)] {
        tagger.string = body
        var out: [(token: String, tag: NLTag?)] = []
        let range = body.startIndex..<body.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            let raw = String(body[tokenRange]).lowercased()
            if let token = VernTokens.words(raw).first, token.contains(where: { $0.isLetter }) {
                out.append((token: token, tag: tag))
            }
            return out.count < limit
        }
        return out
    }
}
