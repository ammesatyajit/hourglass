//
//  VernacularAnalyzerTests.swift
//  HourglassTests
//
//  Pure-logic coverage for the Vernacular Analysis engine (Layers 1-3 + the
//  Layer-4 prompt/parse). No chat.db, no model — small hand-built inputs.
//    - Layer 2: vocative/literal sense-split rule table.
//    - Layer 1: NPMI / over-rep collocation scoring, template extraction.
//    - Layer 3: DECISIVE attribution threshold (≥5× + ≥30d + dominance).
//    - Layer 4: LLM label JSON parsing.
//

import XCTest
@testable import Hourglass

// MARK: - helpers

private func baselineFrom(_ counts: [String: Double]) -> LinguisticBaseline {
    LinguisticBaseline(counts: counts, isPlaceholder: false)
}

private func msg(_ body: String, fromMe: Bool, who: String, daysFromEpoch: Double,
                 chat: Int64 = 1, uptake: Double = 0) -> VernacularMessage {
    VernacularMessage(date: daysFromEpoch * 86_400, chat: chat, fromMe: fromMe,
                      who: who, body: body, uptake: uptake)
}

// MARK: - Layer 2: sense splitting

final class VernacularSenseRulesTests: XCTestCase {

    func testSentenceInitialIsVocative() {
        let toks = ["brother", "what", "are", "you", "doing"]
        XCTAssertEqual(VernacularSenseRules.classify(term: "brother", at: 0, in: toks), .vocative)
    }

    func testPossessiveFrameIsLiteral() {
        let toks = ["my", "brother", "is", "here"]
        XCTAssertEqual(VernacularSenseRules.classify(term: "brother", at: 1, in: toks), .literal)
    }

    func testMidSentenceIsLiteral() {
        // "and brother" — mid-sentence, not sentence-initial → literal.
        let toks = ["wait", "and", "brother", "too"]
        XCTAssertEqual(VernacularSenseRules.classify(term: "brother", at: 2, in: toks), .literal)
    }

    func testPluralIsLiteral() {
        let toks = ["brothers", "forever"]
        // plural registered as always-literal even when sentence-initial
        XCTAssertEqual(VernacularSenseRules.classify(term: "brothers", at: 0, in: toks), .literal)
    }

    func testRuleTableGeneralizesBeyondBrother() {
        // "king" and "bro" must work too — not hardcoded to "brother".
        XCTAssertEqual(VernacularSenseRules.classify(term: "king", at: 0, in: ["king", "lets", "go"]), .vocative)
        XCTAssertEqual(VernacularSenseRules.classify(term: "bro", at: 1, in: ["my", "bro"]), .literal)
        XCTAssertEqual(VernacularSenseRules.classify(term: "bro", at: 0, in: ["bro", "no", "way"]), .vocative)
    }

    func testNonAmbiguousTermReturnsNil() {
        XCTAssertNil(VernacularSenseRules.classify(term: "hello", at: 0, in: ["hello", "there"]))
    }

    func testTallyCountsBothSenses() {
        // sentence-initial vocative
        let t1 = VernacularSenseRules.tally(tokens: ["bro", "this", "is", "wild"])
        XCTAssertEqual(t1.vocative, 1); XCTAssertEqual(t1.literal, 0)
        // literal possessive
        let t2 = VernacularSenseRules.tally(tokens: ["my", "bro", "is", "here"])
        XCTAssertEqual(t2.vocative, 0); XCTAssertEqual(t2.literal, 1)
    }

    func testPossessiveBrotherInChristStillLiteralBySyntax() {
        // KNOWN syntactic blind spot the LLM must catch: "my brother in
        // christ" reads literal to the syntax rule (possessive frame).
        let toks = VernTokens.words("my brother in christ what")
        XCTAssertEqual(VernacularSenseRules.classify(term: "brother", at: 1, in: toks), .literal)
    }
}

// MARK: - Layer 1: collocation scoring (NPMI / over-rep)

final class VernacularCollocationTests: XCTestCase {

    /// Build a CorpusStats from synthetic messages and assert NPMI ordering.
    func testNPMIHigherForGluedPair() {
        // "plot armor" always co-occurs; "the plot" co-occurs loosely.
        var msgs: [VernacularMessage] = []
        for i in 0..<30 { msgs.append(msg("plot armor is real", fromMe: i % 2 == 0, who: i % 2 == 0 ? "You" : "A\(i % 5)", daysFromEpoch: Double(i))) }
        for i in 0..<30 { msgs.append(msg("the plot was good", fromMe: false, who: "B\(i % 5)", daysFromEpoch: Double(i))) }
        // Make "the" and "plot" individually common so "the plot" has low glue.
        for i in 0..<60 { msgs.append(msg("the thing", fromMe: false, who: "C", daysFromEpoch: Double(i))) }
        let base = baselineFrom(["the": 1_000_000, "plot": 50, "armor": 10, "is": 500_000,
                                 "real": 9_000, "was": 400_000, "good": 80_000, "thing": 70_000])
        let stats = CorpusStats(messages: msgs, baseline: base)
        let npmiGlued = stats.npmi("plot armor", stats.stat["plot armor"]?.count ?? 0)
        let npmiLoose = stats.npmi("the plot", stats.stat["the plot"]?.count ?? 0)
        XCTAssertGreaterThan(npmiGlued, npmiLoose,
                             "tightly-glued 'plot armor' should out-score loose 'the plot' on NPMI")
    }

    func testOverRepPositiveForRareEnglishPairing() {
        var msgs: [VernacularMessage] = []
        for i in 0..<20 { msgs.append(msg("plot armor", fromMe: false, who: "A\(i % 4)", daysFromEpoch: Double(i))) }
        let base = baselineFrom(["plot": 50, "armor": 10])
        let stats = CorpusStats(messages: msgs, baseline: base)
        // A pairing that's rare in English should over-represent (>0) in-corpus.
        XCTAssertGreaterThan(stats.over("plot armor", 20), 0)
    }

    func testHasNovelWordGate() {
        var msgs: [VernacularMessage] = []
        // The register set = the user's TOP-250 most-frequent words. Build a
        // corpus with 260 distinct LETTER filler words (the tokenizer drops
        // digits, so fillers must be letter-only), each used 30× — more than
        // "traffic cone" (20×). So "cone" ranks BELOW the top-250 and reads as
        // a novel (non-register) word, while two fillers do not.
        let alpha = Array("abcdefghijklmnopqrstuvwxyz")
        func fillerWord(_ i: Int) -> String { "\(alpha[i / 26])\(alpha[i % 26])x" }
        for i in 0..<260 {
            let w = fillerWord(i)
            for _ in 0..<10 { msgs.append(msg("\(w) \(w) \(w)", fromMe: true, who: "You", daysFromEpoch: 0)) }
        }
        for i in 0..<20 { msgs.append(msg("traffic cone", fromMe: true, who: "You", daysFromEpoch: Double(i))) }
        let base = baselineFrom(["traffic": 4000, "cone": 200])
        let stats = CorpusStats(messages: msgs, baseline: base)
        XCTAssertTrue(stats.hasNovelWord("traffic cone"), "carries non-register word 'cone'")
        XCTAssertFalse(stats.hasNovelWord("\(fillerWord(0)) \(fillerWord(1))"), "two register words → not novel")
    }
}

// MARK: - Layer 1: template extraction

final class VernacularTemplateTests: XCTestCase {

    func testSkeletonAbstractsContentToBlank() {
        let common: Set<String> = ["the", "is", "so", "way"]
        let sk = TemplateMiner.skeleton(TemplateMiner.tokens("the way bananas is"), common: common)
        // "bananas" is content → "_"; frame words kept.
        XCTAssertEqual(sk, ["the", "way", "_", "is"])
    }

    func testKeepsAllCapsEmphasis() {
        let common: Set<String> = ["is"]
        let sk = TemplateMiner.skeleton(TemplateMiner.tokens("this NOT it"), common: common)
        XCTAssertTrue(sk.contains("NOT"), "ALL-CAPS emphasis is preserved as a frame, not blanked")
    }

    func testMiddleBlankRequiresInteriorSlot() {
        // "_ is" — blank is first, not interior → false.
        XCTAssertFalse(TemplateMiner.isMiddleBlank(["_", "is"]))
        // "the _ is" — interior blank with two frames → true.
        XCTAssertTrue(TemplateMiner.isMiddleBlank(["the", "_", "is"]))
    }

    func testMineSurfacesDistinctiveTemplateWithExamples() {
        var msgs: [VernacularMessage] = []
        // YOU say "the way _ is" a lot; contacts barely do. The content slot
        // fillers ("bananas","elephant"…) are ABSENT from the baseline so they
        // abstract to "_"; the frame words ("the","way","is") are top-400.
        let fillers = ["bananas", "elephant", "umbrella", "calendar"]
        for i in 0..<40 {
            msgs.append(msg("the way \(fillers[i % 4]) is", fromMe: true, who: "You", daysFromEpoch: Double(i)))
        }
        for i in 0..<3 { msgs.append(msg("the way home is", fromMe: false, who: "A", daysFromEpoch: Double(i))) }
        // Only the frame words are in the baseline (so fillers → "_").
        let base = baselineFrom(["the": 1_000_000, "way": 50_000, "is": 500_000])
        let templates = TemplateMiner.mine(messages: msgs, baseline: base,
                                           options: VernacularAnalyzer.Options(minTemplateCount: 10))
        let target = templates.first { $0.skeleton == "the way _ is" }
        XCTAssertNotNil(target, "the distinctive 'the way _ is' template should surface")
        XCTAssertFalse(target?.examples.isEmpty ?? true, "template carries real fill-in examples")
    }
}

// MARK: - Layer 3: DECISIVE attribution

final class VernacularAttributionTests: XCTestCase {

    private let opts = VernacularAnalyzer.Options()  // minBefore=5, minDays=30, ratio=2

    func testDecisiveSourceReported() {
        var msgs: [VernacularMessage] = []
        // Venkat uses "deadass" 8× starting day 0; YOU start day 100.
        for i in 0..<8 { msgs.append(msg("deadass", fromMe: false, who: "Venkat", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("deadass", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "deadass", messages: msgs, options: opts)
        XCTAssertEqual(a?.source, "Venkat")
        XCTAssertEqual(a?.sourceBeforeCount, 8)
    }

    func testNotDecisiveWhenBelowFiveBefore() {
        var msgs: [VernacularMessage] = []
        for i in 0..<3 { msgs.append(msg("hella", fromMe: false, who: "Arjit", daysFromEpoch: Double(i))) } // only 3 before
        for i in 0..<6 { msgs.append(msg("hella", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "hella", messages: msgs, options: opts)
        XCTAssertNil(a?.source, "fewer than 5 uses before you → ambient, no source")
    }

    func testNotDecisiveWhenWithinThirtyDays() {
        var msgs: [VernacularMessage] = []
        // 6 uses but only ~5 days before you → fails the 30-day rule.
        for i in 0..<6 { msgs.append(msg("lowkey", fromMe: false, who: "David", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("lowkey", fromMe: true, who: "You", daysFromEpoch: 5 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "lowkey", messages: msgs, options: opts)
        XCTAssertNil(a?.source, "source must precede you by ≥30 days")
    }

    func testNotDecisiveWhenNoDominantUser() {
        var msgs: [VernacularMessage] = []
        // Two contacts use it equally (6 each) before you → no 2× dominance.
        for i in 0..<6 { msgs.append(msg("yk", fromMe: false, who: "A", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("yk", fromMe: false, who: "B", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("yk", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "yk", messages: msgs, options: opts)
        XCTAssertNil(a?.source, "tie between two early users → not decisive")
    }

    func testSoleQualifierIsDecisiveEvenWithoutRunnerUp() {
        var msgs: [VernacularMessage] = []
        for i in 0..<7 { msgs.append(msg("cooked", fromMe: false, who: "Melina", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("cooked", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "cooked", messages: msgs, options: opts)
        XCTAssertEqual(a?.source, "Melina", "a sole qualifier is decisive")
    }

    func testUnknownContactNeverAttributed() {
        var msgs: [VernacularMessage] = []
        let unknown = VernacularAnalyzer.unknownLabel
        for i in 0..<8 { msgs.append(msg("fr", fromMe: false, who: unknown, daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("fr", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "fr", messages: msgs, options: opts)
        XCTAssertNil(a?.source, "handles not in contacts can't be a named source")
    }

    func testSingleWordMatchesWordSetNotSubstring() {
        var msgs: [VernacularMessage] = []
        // "im" must NOT match inside "time". Source says "time" 8× (no "im" word).
        for i in 0..<8 { msgs.append(msg("what time is it", fromMe: false, who: "A", daysFromEpoch: Double(i))) }
        for i in 0..<6 { msgs.append(msg("im here", fromMe: true, who: "You", daysFromEpoch: 100 + Double(i))) }
        let a = VernacularAnalyzer.attribute(term: "im", messages: msgs, options: opts)
        XCTAssertNil(a?.source, "single-word term must match whole words only")
        XCTAssertEqual(a?.yourCount, 6)
    }
}

// MARK: - Layer 4: AI label parsing (pure)

final class VernacularAILabelParseTests: XCTestCase {

    func testParsesCleanJSON() {
        let raw = #"{"kind":"idiom","desc":"affectionate vocative address"}"#
        let label = LLMVernacularLabeler.parse(raw)
        XCTAssertEqual(label?.kind, .idiom)
        XCTAssertEqual(label?.description, "affectionate vocative address")
    }

    func testParsesJSONWithSurroundingProse() {
        let raw = "Sure! Here you go:\n{\"kind\":\"slang\",\"desc\":\"internet slang\"} done"
        let label = LLMVernacularLabeler.parse(raw)
        XCTAssertEqual(label?.kind, .slang)
    }

    func testUnknownKindFallsBack() {
        let raw = #"{"kind":"wat","desc":"hmm"}"#
        XCTAssertEqual(LLMVernacularLabeler.parse(raw)?.kind, .unknown)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(LLMVernacularLabeler.parse("no json here at all"))
    }

    func testRepurposedKindParses() {
        let raw = #"{"kind":"repurposed","desc":"private in-group meaning"}"#
        XCTAssertEqual(LLMVernacularLabeler.parse(raw)?.kind, .repurposed)
    }

    func testUserPromptIncludesExamples() {
        let c = VernacularAICandidate(id: "x", kind: .phrase, text: "traffic cone",
                                      examples: ["he's a traffic cone fr"])
        let prompt = LLMVernacularLabeler.userPrompt(for: c)
        XCTAssertTrue(prompt.contains("traffic cone"))
        XCTAssertTrue(prompt.contains("Examples:"))
    }

    func testSystemPromptPrimesBrotherInChristIdiom() {
        // The critical-case priming must be present in the prompt.
        XCTAssertTrue(LLMVernacularLabeler.systemPrompt.lowercased().contains("brother in christ"))
    }
}

// MARK: - Layer 4 gating (Noop labeler)

final class VernacularGatingTests: XCTestCase {

    func testNoopLabelerReturnsNoLabels() async {
        let labels = await NoopVernacularLabeler().label([
            VernacularAICandidate(id: "a", kind: .phrase, text: "x", examples: [])
        ])
        XCTAssertTrue(labels.isEmpty)
    }

    func testStubRepurposingDetectorReturnsEmpty() async {
        let scores = await StubRepurposingDetector().repurposingScores(for: ["traffic cone"], contexts: [:])
        XCTAssertTrue(scores.isEmpty, "v1 embedding detector is a scaffold returning empty")
    }
}

// MARK: - end-to-end pure analyze

final class VernacularAnalyzeEndToEndTests: XCTestCase {

    func testAnalyzeProducesCategorizedResultWithoutModel() {
        var msgs: [VernacularMessage] = []
        // a slang phrase used by several people, you started after a source
        for i in 0..<20 {
            msgs.append(msg("plot armor for real", fromMe: i % 3 == 0,
                            who: i % 3 == 0 ? "You" : "Friend\(i % 4)", daysFromEpoch: Double(i), uptake: 1.0))
        }
        // trailing approval tag
        for i in 0..<50 { msgs.append(msg("that works no?", fromMe: true, who: "You", daysFromEpoch: Double(i))) }
        let base = baselineFrom(["plot": 50, "armor": 10, "for": 600_000, "real": 9000,
                                 "that": 700_000, "works": 8000, "no": 400_000])
        let result = VernacularAnalyzer.analyze(messages: msgs, baseline: base, signatureWords: [])
        XCTAssertGreaterThan(result.sentMessages, 0)
        // tags should include "… no?"
        XCTAssertTrue(result.tags.contains { $0.pattern == "… no?" })
        // nothing should have an AI label (no labeler ran)
        XCTAssertTrue(result.slangPhrases.allSatisfy { $0.aiLabel == nil })
    }
}
