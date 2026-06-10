//
//  VernacularTokenizedCorpus.swift
//  Hourglass - Vernacular token/hash cache
//

import Foundation

/// Subject-agnostic cache of token-gated n-grams and template pattern refs.
///
/// This is an additive, flag-gated extraction cache: it precomputes the stable
/// hash + gate decisions once, but the profile extractor still performs the
/// subject-scoped Pass-A eligibility, message-order exact acceptance race, and
/// accumulator observation exactly as before.
public struct VernacularTokenizedCorpus: Sendable, Equatable {
    struct ValidityKey: Sendable, Equatable {
        let nameTokensFingerprint: UInt64
        let maxN: Int
        let templateConfigFingerprint: UInt64
        let globalFloor: Int
        let maxDistinctNgrams: Int
    }

    struct MessageGrams: Sendable, Equatable {
        var hashes: [UInt64]
        var nStart: [UInt32]
        static let empty = MessageGrams(hashes: [], nStart: [])
    }

    struct MessagePatterns: Sendable, Equatable {
        var refs: [PatternRef]
        static let empty = MessagePatterns(refs: [])
    }

    struct PatternRef: Sendable, Equatable {
        let hash: UInt64
        let start: UInt16
        let length: UInt16
        let anchors: VernacularTemplateEngine.AnchorSelection
    }

    struct GramSurface: Sendable, Equatable {
        let surface: String
        let tokens: [String]
        let n: Int
    }

    struct PatternSurface: Sendable, Equatable {
        let key: String
        let anchors: [String]
        let slotCount: Int
    }

    let validity: ValidityKey
    let messageCount: Int
    let ngramsByMessage: ContiguousArray<MessageGrams>
    let patternsByMessage: ContiguousArray<MessagePatterns>
    let slotTotalsByMessage: ContiguousArray<[Int]>
    let gramSurfaces: [UInt64: GramSurface]
    let patternSurfaces: [UInt64: PatternSurface]

    static func build(
        messages: [VernacularMessage],
        contacts: ResolvedContacts,
        config: VernacularConfig
    ) -> VernacularTokenizedCorpus {
        let nameTokens = VernacularAnalyzer.contactNameTokens(contacts)
        let maxN = max(1, config.maxNgramLength)
        let globalFloor = max(1, min(config.tokenizedCorpusGlobalFloor, config.minUserMessages))
        let maxDistinct = max(1, config.tokenizedCorpusMaxDistinctNgrams)
        let validity = ValidityKey(
            nameTokensFingerprint: fingerprint(nameTokens),
            maxN: maxN,
            templateConfigFingerprint: templateConfigFingerprint(config),
            globalFloor: globalFloor,
            maxDistinctNgrams: maxDistinct
        )

        var ngramCounts: [UInt64: Int] = [:]
        var patternCounts: [UInt64: Int] = [:]
        var slotTotals = ContiguousArray<[Int]>()
        slotTotals.reserveCapacity(messages.count)

        for message in messages {
            var totals = Array(repeating: 0, count: maxN + 1)
            guard VernacularNgramExtractor.corpusAllowed(message) else {
                slotTotals.append(totals)
                continue
            }

            let flags = VernacularNgramExtractor.tokenGateFlags(words: message.words,
                                                                nameTokens: nameTokens)
            var seenNgrams = Set<UInt64>()
            VernacularNgramExtractor.visitNgrams(words: message.words, maxN: maxN) { n, start, hash in
                totals[n] += 1
                guard VernacularNgramExtractor.gramAllowed(flags: flags, start: start, n: n) else { return }
                if seenNgrams.insert(hash).inserted {
                    ngramCounts[hash, default: 0] += 1
                }
            }
            slotTotals.append(totals)

            guard message.words.count <= config.maxTemplateMessageTokens else { continue }
            var seenPatterns = Set<UInt64>()
            VernacularTemplateEngine.visitPatternRefs(words: message.words,
                                                      nameTokens: nameTokens,
                                                      config: config) { hash, _, _, _ in
                if seenPatterns.insert(hash).inserted {
                    patternCounts[hash, default: 0] += 1
                }
            }
        }

        let admittedNgrams = Set(ngramCounts
            .filter { $0.value >= globalFloor }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(maxDistinct)
            .map(\.key))

        let admittedPatterns = Set(patternCounts
            .filter { $0.value >= globalFloor }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .map(\.key))

        var gramsByMessage = ContiguousArray<MessageGrams>()
        gramsByMessage.reserveCapacity(messages.count)
        var patternsByMessage = ContiguousArray<MessagePatterns>()
        patternsByMessage.reserveCapacity(messages.count)
        var gramSurfaces: [UInt64: GramSurface] = [:]
        var patternSurfaces: [UInt64: PatternSurface] = [:]

        for message in messages {
            guard VernacularNgramExtractor.corpusAllowed(message) else {
                gramsByMessage.append(.empty)
                patternsByMessage.append(.empty)
                continue
            }

            let flags = VernacularNgramExtractor.tokenGateFlags(words: message.words,
                                                                nameTokens: nameTokens)
            var grams = MessageGrams.empty
            VernacularNgramExtractor.visitNgrams(words: message.words, maxN: maxN) { n, start, hash in
                guard admittedNgrams.contains(hash),
                      VernacularNgramExtractor.gramAllowed(flags: flags, start: start, n: n) else { return }
                grams.hashes.append(hash)
                grams.nStart.append(packNStart(n: n, start: start))
                if gramSurfaces[hash] == nil {
                    let toks = Array(message.words[start..<(start + n)])
                    gramSurfaces[hash] = GramSurface(surface: toks.joined(separator: " "),
                                                     tokens: toks,
                                                     n: n)
                }
            }
            gramsByMessage.append(grams)

            guard message.words.count <= config.maxTemplateMessageTokens else {
                patternsByMessage.append(.empty)
                continue
            }
            var patterns = MessagePatterns.empty
            VernacularTemplateEngine.visitPatternRefs(words: message.words,
                                                      nameTokens: nameTokens,
                                                      config: config) { hash, start, length, anchors in
                guard admittedPatterns.contains(hash),
                      start >= 0, length > 0,
                      start <= Int(UInt16.max), length <= Int(UInt16.max) else { return }
                patterns.refs.append(PatternRef(hash: hash,
                                                start: UInt16(start),
                                                length: UInt16(length),
                                                anchors: anchors))
                if patternSurfaces[hash] == nil,
                   let materialized = VernacularTemplateEngine.materializePattern(
                        words: message.words,
                        start: start,
                        length: length,
                        anchors: anchors,
                        hash: hash,
                        config: config
                   ) {
                    patternSurfaces[hash] = PatternSurface(key: materialized.key,
                                                           anchors: materialized.anchors,
                                                           slotCount: materialized.slotCount)
                }
            }
            patternsByMessage.append(patterns)
        }

        return VernacularTokenizedCorpus(validity: validity,
                                         messageCount: messages.count,
                                         ngramsByMessage: gramsByMessage,
                                         patternsByMessage: patternsByMessage,
                                         slotTotalsByMessage: slotTotals,
                                         gramSurfaces: gramSurfaces,
                                         patternSurfaces: patternSurfaces)
    }

    func isValid(nameTokens: Set<String>, config: VernacularConfig, messageCount: Int) -> Bool {
        validity == ValidityKey(
            nameTokensFingerprint: Self.fingerprint(nameTokens),
            maxN: max(1, config.maxNgramLength),
            templateConfigFingerprint: Self.templateConfigFingerprint(config),
            globalFloor: max(1, min(config.tokenizedCorpusGlobalFloor, config.minUserMessages)),
            maxDistinctNgrams: max(1, config.tokenizedCorpusMaxDistinctNgrams)
        ) && self.messageCount == messageCount
    }

    func ngrams(at index: Int) -> MessageGrams {
        guard ngramsByMessage.indices.contains(index) else { return .empty }
        return ngramsByMessage[index]
    }

    func patterns(at index: Int) -> MessagePatterns {
        guard patternsByMessage.indices.contains(index) else { return .empty }
        return patternsByMessage[index]
    }

    func slotTotals(at index: Int) -> [Int] {
        guard slotTotalsByMessage.indices.contains(index) else { return [] }
        return slotTotalsByMessage[index]
    }

    static func packNStart(n: Int, start: Int) -> UInt32 {
        let safeN = min(max(n, 0), 255)
        let safeStart = min(max(start, 0), 0x00FF_FFFF)
        return (UInt32(safeN) << 24) | UInt32(safeStart)
    }

    static func unpackNStart(_ packed: UInt32) -> (n: Int, start: Int) {
        (Int((packed >> 24) & 0xFF), Int(packed & 0x00FF_FFFF))
    }

    static func fingerprint(_ tokens: Set<String>) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        for token in tokens.sorted() {
            append(token, to: &h)
            appendByte(0x1F, to: &h)
        }
        return h
    }

    static func templateConfigFingerprint(_ config: VernacularConfig) -> UInt64 {
        var h: UInt64 = 14_695_981_039_346_656_037
        appendInt(config.maxTemplateSpanTokens, to: &h)
        appendInt(config.maxTemplateAnchors, to: &h)
        appendInt(config.maxTemplateSlots, to: &h)
        appendInt(config.maxTemplateSlotTokens, to: &h)
        appendInt(config.maxTemplatePatternsPerMessage, to: &h)
        appendInt(config.maxTemplateAnchorsPerWindow, to: &h)
        appendInt(config.maxTemplateMessageTokens, to: &h)
        appendInt(config.allowSingleAnchorEdgeTemplates ? 1 : 0, to: &h)
        return h
    }

    private static func appendInt(_ value: Int, to hash: inout UInt64) {
        append(String(value), to: &hash)
        appendByte(0x1F, to: &hash)
    }

    private static func append(_ string: String, to hash: inout UInt64) {
        for byte in string.utf8 { appendByte(byte, to: &hash) }
    }

    private static func appendByte(_ byte: UInt8, to hash: inout UInt64) {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
}
