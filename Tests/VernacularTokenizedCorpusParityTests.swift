//
//  VernacularTokenizedCorpusParityTests.swift
//  HourglassTests
//

import XCTest
@testable import Hourglass

final class VernacularTokenizedCorpusParityTests: XCTestCase {

    private func msg(_ body: String, fromMe: Bool, who: String, day: Double, chat: Int64 = 1) -> VernacularMessage {
        VernacularMessage(date: day * 86_400, chat: chat, fromMe: fromMe,
                          who: who, body: body, uptake: 0)
    }

    private var contacts: ResolvedContacts {
        ResolvedContacts(byHandle: [:], allContacts: [])
    }

    func testTokenizedNgramRefsMatchSharedLegacyHelpers() {
        var config = VernacularConfig.default
        config.maxNgramLength = 3
        config.tokenizedCorpusGlobalFloor = 1
        config.tokenizedCorpusMaxDistinctNgrams = 10_000
        let messages = [
            msg("lowk cooked aura", fromMe: true, who: "You", day: 1),
            msg("the aura is cooked", fromMe: false, who: "Ari", day: 2),
            msg("email http should not count", fromMe: true, who: "You", day: 3),
            msg("cone traffic cone cooked", fromMe: true, who: "You", day: 4),
        ]
        let nameTokens = VernacularAnalyzer.contactNameTokens(contacts)
        let cache = VernacularTokenizedCorpus.build(messages: messages,
                                                    contacts: contacts,
                                                    config: config)

        for (index, message) in messages.enumerated() {
            var expectedHashes: [UInt64] = []
            var expectedPacked: [UInt32] = []
            var expectedSlots = Array(repeating: 0, count: config.maxNgramLength + 1)
            if VernacularNgramExtractor.corpusAllowed(message) {
                let flags = VernacularNgramExtractor.tokenGateFlags(words: message.words,
                                                                    nameTokens: nameTokens)
                VernacularNgramExtractor.visitNgrams(words: message.words,
                                                     maxN: config.maxNgramLength) { n, start, hash in
                    expectedSlots[n] += 1
                    guard VernacularNgramExtractor.gramAllowed(flags: flags, start: start, n: n) else { return }
                    expectedHashes.append(hash)
                    expectedPacked.append(VernacularTokenizedCorpus.packNStart(n: n, start: start))
                }
            }

            XCTAssertEqual(cache.ngrams(at: index).hashes, expectedHashes)
            XCTAssertEqual(cache.ngrams(at: index).nStart, expectedPacked)
            XCTAssertEqual(cache.slotTotals(at: index), expectedSlots)

            var expectedPatternRefs: [VernacularTokenizedCorpus.PatternRef] = []
            if VernacularTemplateEngine.corpusAllowed(message) {
                VernacularTemplateEngine.visitPatternRefs(words: message.words,
                                                          nameTokens: nameTokens,
                                                          config: config) { hash, start, length, anchors in
                    expectedPatternRefs.append(VernacularTokenizedCorpus.PatternRef(
                        hash: hash,
                        start: UInt16(start),
                        length: UInt16(length),
                        anchors: anchors
                    ))
                }
            }
            XCTAssertEqual(cache.patterns(at: index).refs, expectedPatternRefs)
        }
    }

    func testBuildProfileMatchesLegacyPathOnFixture() {
        var config = VernacularConfig.default
        config.useTokenizedCorpus = true
        config.tokenizedCorpusGlobalFloor = 1
        config.tokenizedCorpusMaxDistinctNgrams = 10_000
        config.minSubjectMessagesForProfile = 3
        config.minUserMessages = 2
        config.lowCountDayGate = 2
        config.minDistinctDaysForLowCount = 1
        config.maxNgramLength = 3
        config.enableReclaimedContextFilter = false
        config.enableSemanticShiftEmbeddings = false

        var messages: [VernacularMessage] = []
        for day in 1...8 {
            messages.append(msg("lowk cooked aura cone", fromMe: true, who: "You", day: Double(day), chat: 1))
        }
        for day in 9...16 {
            messages.append(msg("lowk aura is cooked", fromMe: false, who: "Ari", day: Double(day), chat: 1))
        }
        for day in 17...24 {
            messages.append(msg("holy cooked aura", fromMe: true, who: "You", day: Double(day), chat: 2))
        }
        for day in 25...32 {
            messages.append(msg("holy aura cooked", fromMe: false, who: "Beck", day: Double(day), chat: 2))
        }

        let baseline = LinguisticBaseline(counts: [
            "the": 10_000, "is": 8_000, "you": 7_000, "aura": 10,
            "cone": 8, "holy": 50, "cooked": 6, "lowk": 1
        ])
        let cache = VernacularTokenizedCorpus.build(messages: messages,
                                                    contacts: contacts,
                                                    config: config)

        let legacy = VernacularEngine.buildProfile(messages: messages,
                                                   baseline: baseline,
                                                   contacts: contacts,
                                                   subject: .you,
                                                   config: config,
                                                   tokenized: nil)
        let cached = VernacularEngine.buildProfile(messages: messages,
                                                   baseline: baseline,
                                                   contacts: contacts,
                                                   subject: .you,
                                                   config: config,
                                                   tokenized: cache)
        XCTAssertEqual(cached, legacy)
    }
}
