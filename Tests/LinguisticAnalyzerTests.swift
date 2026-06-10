//
//  LinguisticAnalyzerTests.swift
//  HourglassTests
//
//  Covers the PURE logic of the Linguistic Insights feature:
//    - tokenization (apostrophes, hyphens, punctuation, numbers, emoji)
//    - elongation detection / canonicalization
//    - stopword backstop
//    - baseline parsing (the `word\tcount` format + comments)
//    - distinctive-vocabulary ranking (surprisal / log-odds): the key
//      property is that DISTINCTIVE slang beats both stopwords AND
//      normal-frequency words, with small fixed inputs and a hand-built
//      baseline (no dependency on the real bundled corpus or chat.db).
//

import XCTest
@testable import Hourglass

final class LinguisticTokenizerTests: XCTestCase {

    func testBasicTokenizationLowercases() {
        XCTAssertEqual(LinguisticTokenizer.tokenize("Hello WORLD"), ["hello", "world"])
    }

    func testKeepsInteriorApostrophe() {
        XCTAssertEqual(LinguisticTokenizer.tokenize("don't y'all"), ["don't", "y'all"])
    }

    func testKeepsInteriorHyphen() {
        XCTAssertEqual(LinguisticTokenizer.tokenize("self-care low-key"), ["self-care", "low-key"])
    }

    func testStripsSurroundingPunctuation() {
        XCTAssertEqual(LinguisticTokenizer.tokenize("(lol) wait... really?!"),
                       ["lol", "wait", "really"])
    }

    func testDropsPureNumberTokens() {
        XCTAssertEqual(LinguisticTokenizer.tokenize("call me at 2024 ok"),
                       ["call", "me", "at", "ok"])
    }

    func testCurlyApostropheTreatedLikeStraight() {
        // U+2019 RIGHT SINGLE QUOTATION MARK
        XCTAssertEqual(LinguisticTokenizer.tokenize("I\u{2019}m good"), ["i\u{2019}m", "good"])
    }

    func testLeadingApostropheTrimmed() {
        // "'cause" — the leading apostrophe isn't flanked by word chars, so
        // it's a separator; the token becomes "cause".
        XCTAssertEqual(LinguisticTokenizer.tokenize("'cause i can"), ["cause", "i", "can"])
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(LinguisticTokenizer.tokenize(""), [])
        XCTAssertEqual(LinguisticTokenizer.tokenize("   \n  "), [])
    }

    func testBigrams() {
        XCTAssertEqual(LinguisticTokenizer.bigrams(["i", "love", "you"]),
                       ["i love", "love you"])
        XCTAssertEqual(LinguisticTokenizer.bigrams(["solo"]), [])
        XCTAssertEqual(LinguisticTokenizer.bigrams([]), [])
    }
}

final class LinguisticElongationTests: XCTestCase {

    func testDetectsAndCanonicalizesStretch() {
        XCTAssertEqual(LinguisticTokenizer.elongationCanonical("soooo"), "so")
        XCTAssertEqual(LinguisticTokenizer.elongationCanonical("yessss"), "yes")
        XCTAssertEqual(LinguisticTokenizer.elongationCanonical("lmaooo"), "lmao")
    }

    func testLegitDoublesNotElongated() {
        // "cool" has a real double-o (run length 2) — not a stretch.
        XCTAssertNil(LinguisticTokenizer.elongationCanonical("cool"))
        XCTAssertNil(LinguisticTokenizer.elongationCanonical("hello"))
        XCTAssertFalse(LinguisticTokenizer.isElongated("good"))
    }

    func testIsElongated() {
        XCTAssertTrue(LinguisticTokenizer.isElongated("ahhhh"))
        XCTAssertTrue(LinguisticTokenizer.isElongated("nooooo"))
        XCTAssertFalse(LinguisticTokenizer.isElongated("no"))
    }

    func testCollapsesMultipleRuns() {
        // "wooooahhh": two long runs (o and h) both collapse.
        XCTAssertEqual(LinguisticTokenizer.elongationCanonical("wooooahhh"), "woah")
    }
}

final class LinguisticStopwordTests: XCTestCase {

    func testCommonFunctionWordsAreStopwords() {
        for w in ["the", "and", "you", "i", "u", "im", "dont", "okay"] {
            XCTAssertTrue(LinguisticStopwords.isStopword(w), "\(w) should be a stopword")
        }
    }

    func testSlangIsNotStopword() {
        // The whole point: meaningful slang must NOT be filtered as a stopword.
        for w in ["lowkey", "deadass", "fr", "ngl", "bet", "bruh", "vibe"] {
            XCTAssertFalse(LinguisticStopwords.isStopword(w), "\(w) must survive")
        }
    }
}

final class LinguisticBaselineTests: XCTestCase {

    func testParsesTabSeparatedWithComments() {
        let text = """
        # a comment line
        # another
        the\t100
        and\t50
        lol\t2
        """
        let data = Data(text.utf8)
        let baseline = LinguisticBaseline.parse(data)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?.count(of: "the"), 100)
        XCTAssertEqual(baseline?.count(of: "and"), 50)
        XCTAssertEqual(baseline?.count(of: "lol"), 2)
        XCTAssertEqual(baseline?.totalCount, 152)
        XCTAssertFalse(baseline?.isPlaceholder ?? true)
    }

    func testParsesSpaceSeparated() {
        // The raw OpenSubtitles list is space-separated; parser accepts both.
        let baseline = LinguisticBaseline.parse(Data("you 28787591\ni 27086011\n".utf8))
        XCTAssertEqual(baseline?.count(of: "you"), 28_787_591)
        XCTAssertEqual(baseline?.count(of: "i"), 27_086_011)
    }

    func testUnseenTokenGetsSmoothingFloor() {
        let baseline = LinguisticBaseline.parse(Data("the\t100\n".utf8))!
        XCTAssertFalse(baseline.isKnown("zzzznotaword"))
        XCTAssertEqual(baseline.count(of: "zzzznotaword"), LinguisticBaseline.unseenCount)
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(LinguisticBaseline.parse(Data("# only comments\n".utf8)))
    }

    func testProbabilityInRange() {
        let baseline = LinguisticBaseline.parse(Data("the\t100\nand\t50\n".utf8))!
        let p = baseline.probability(of: "the")
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThanOrEqual(p, 1)
    }
}

final class LinguisticAnalyzerRankingTests: XCTestCase {

    /// A small hand-built baseline standing in for "normal English": the
    /// stopwords are very common, "weekend" is a normal-frequency content
    /// word, and slang is absent (so it reads as rare).
    private func makeBaseline() -> LinguisticBaseline {
        let counts: [String: Double] = [
            "the": 1_000_000, "and": 800_000, "you": 900_000, "i": 950_000,
            "to": 700_000, "a": 600_000, "is": 500_000, "it": 480_000,
            "for": 300_000, "so": 250_000, "good": 90_000, "weekend": 40_000,
            "really": 60_000, "going": 70_000, "yeah": 120_000, "ok": 110_000,
            "love": 80_000, "work": 75_000, "today": 55_000,
        ]
        return LinguisticBaseline(counts: counts)
    }

    /// Tiny corpus: a heavy texter who says "lowkey", "fr", "deadass", "bet"
    /// constantly, plus normal filler. The analyzer must surface the slang,
    /// NOT the stopwords ("the"/"and"/"you") and NOT normal words ("good").
    private func makeCorpus() -> [String] {
        var msgs: [String] = []
        // Stopwords appear a LOT (like any real corpus).
        for _ in 0..<40 { msgs.append("ok so i was going to the thing and it is good") }
        // Distinctive slang, repeated enough to clear minWordCount.
        for _ in 0..<18 { msgs.append("lowkey that was deadass the best fr") }
        for _ in 0..<14 { msgs.append("bet fr lowkey same") }
        for _ in 0..<10 { msgs.append("deadass bro fr fr") }
        // A normal content word at normal-ish rate (should NOT beat slang).
        for _ in 0..<8 { msgs.append("good weekend coming up") }
        return msgs
    }

    func testDistinctiveSlangBeatsStopwordsAndNormalWords() {
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: makeCorpus(),
            baseline: makeBaseline(),
            options: .init(minWordCount: 3, minWordLength: 2, topK: 8, priorMass: 500)
        )
        let topTerms = insights.distinctiveWords.map(\.term)
        XCTAssertFalse(topTerms.isEmpty, "should produce distinctive words")

        // Slang dominates the top of the ranking.
        XCTAssertTrue(topTerms.contains("lowkey"), "lowkey should be distinctive; got \(topTerms)")
        XCTAssertTrue(topTerms.contains("deadass"), "deadass should be distinctive; got \(topTerms)")
        XCTAssertTrue(topTerms.contains("fr"), "fr should be distinctive; got \(topTerms)")

        // Stopwords must NOT appear (filtered by the stopword backstop).
        for sw in ["the", "and", "you", "i", "it", "so", "ok"] {
            XCTAssertFalse(topTerms.contains(sw), "stopword \(sw) leaked into distinctive words")
        }
    }

    func testAbsentFromBaselineFlag() {
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: makeCorpus(),
            baseline: makeBaseline(),
            options: .init(minWordCount: 3, minWordLength: 2, topK: 12, priorMass: 500)
        )
        // "lowkey"/"deadass"/"fr"/"bet" are absent from the baseline.
        let lowkey = insights.distinctiveWords.first { $0.term == "lowkey" }
        XCTAssertNotNil(lowkey)
        XCTAssertTrue(lowkey?.absentFromBaseline ?? false,
                      "lowkey is not in the baseline, should be flagged absent")
    }

    func testRareTypoDoesNotTopRanking() {
        // One-off weird token must not beat repeated slang (the z-score
        // shrinks low-count terms). Add a single bizarre token.
        var corpus = makeCorpus()
        corpus.append("xqzptv")  // appears once
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: corpus,
            baseline: makeBaseline(),
            options: .init(minWordCount: 3, minWordLength: 2, topK: 8, priorMass: 500)
        )
        // minWordCount=3 means a once-seen token is ineligible entirely.
        XCTAssertFalse(insights.distinctiveWords.map(\.term).contains("xqzptv"))
    }

    func testEmptyCorpusYieldsEmptyInsights() {
        let insights = LinguisticAnalyzer.analyze(sentBodies: [], baseline: makeBaseline())
        XCTAssertTrue(insights.isEmpty)
        XCTAssertEqual(insights.totalSentMessages, 0)
        XCTAssertTrue(insights.distinctiveWords.isEmpty)
    }

    func testBlankBodiesIgnored() {
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: ["", "   ", "\n"],
            baseline: makeBaseline()
        )
        XCTAssertTrue(insights.isEmpty)
    }

    func testStyleStatsComputed() {
        let corpus = [
            "hey what's up",        // lowercase, question? no '?', has no end punct
            "going to the store!",  // exclamation
            "are you coming?",      // question
            "ok",                   // 1 word
        ]
        let insights = LinguisticAnalyzer.analyze(sentBodies: corpus, baseline: makeBaseline())
        XCTAssertEqual(insights.totalSentMessages, 4)
        // There should be an avg-words style stat present.
        XCTAssertTrue(insights.styleStats.contains { $0.key == "avg_words" })
        XCTAssertTrue(insights.styleStats.contains { $0.key == "questions" })
        XCTAssertTrue(insights.styleStats.contains { $0.key == "lowercase" })
    }

    func testOpenersAndClosersExtracted() {
        let corpus = Array(repeating: "hey did you see this", count: 6)
            + Array(repeating: "hey what time", count: 4)
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: corpus,
            baseline: makeBaseline(),
            options: .init(minWordCount: 3, minWordLength: 2)
        )
        // "hey" opens every message.
        XCTAssertEqual(insights.openers.first?.word, "hey")
        XCTAssertEqual(insights.openers.first?.count, 10)
    }

    func testElongationsSurfaced() {
        let corpus = Array(repeating: "omg sooo good", count: 6)
            + Array(repeating: "noooo why", count: 5)
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: corpus,
            baseline: makeBaseline(),
            options: .init(minWordCount: 3, minPhraseCount: 3, minWordLength: 2)
        )
        let canon = insights.elongations.map(\.canonical)
        XCTAssertTrue(canon.contains("so"), "sooo should canonicalize to so; got \(canon)")
        XCTAssertTrue(canon.contains("no"), "noooo should canonicalize to no; got \(canon)")
    }

    func testDistinctivePhrasesSurfaceCollocations() {
        // "no cap" used a lot; the bigram should surface as a signature phrase.
        let corpus = Array(repeating: "that was no cap the best", count: 12)
            + Array(repeating: "i went to the store", count: 30)
        let insights = LinguisticAnalyzer.analyze(
            sentBodies: corpus,
            baseline: makeBaseline(),
            options: .init(minWordCount: 5, minPhraseCount: 4, minWordLength: 2, topK: 10, priorMass: 500)
        )
        let phrases = insights.distinctivePhrases.map(\.term)
        XCTAssertTrue(phrases.contains("no cap"), "expected 'no cap' collocation; got \(phrases)")
    }

    func testDeterministic() {
        let corpus = makeCorpus()
        let baseline = makeBaseline()
        let a = LinguisticAnalyzer.analyze(sentBodies: corpus, baseline: baseline)
        let b = LinguisticAnalyzer.analyze(sentBodies: corpus, baseline: baseline)
        XCTAssertEqual(a, b, "analysis must be deterministic for identical inputs")
    }
}

final class LinguisticHelperTests: XCTestCase {

    func testIsEffectivelyLowercase() {
        XCTAssertTrue(LinguisticAnalyzer.isEffectivelyLowercase("hey what's up"))
        XCTAssertFalse(LinguisticAnalyzer.isEffectivelyLowercase("Hey"))
        XCTAssertFalse(LinguisticAnalyzer.isEffectivelyLowercase("123!"))  // no letters
    }

    func testEmojiCount() {
        XCTAssertEqual(LinguisticAnalyzer.emojiCount(in: "hello 😀 world 🎉"), 2)
        XCTAssertEqual(LinguisticAnalyzer.emojiCount(in: "no emoji here"), 0)
        // Plain digits must not count as emoji.
        XCTAssertEqual(LinguisticAnalyzer.emojiCount(in: "i have 3 cats and 2 dogs"), 0)
    }

    func testEndsWithSentencePunctuation() {
        XCTAssertTrue(LinguisticAnalyzer.endsWithSentencePunctuation("!"))
        XCTAssertTrue(LinguisticAnalyzer.endsWithSentencePunctuation("?"))
        XCTAssertFalse(LinguisticAnalyzer.endsWithSentencePunctuation("a"))
        XCTAssertFalse(LinguisticAnalyzer.endsWithSentencePunctuation(nil))
    }

    func testSingleCharRepeat() {
        XCTAssertTrue(LinguisticAnalyzer.isSingleCharRepeat("aaa"))
        XCTAssertFalse(LinguisticAnalyzer.isSingleCharRepeat("abc"))
        XCTAssertFalse(LinguisticAnalyzer.isSingleCharRepeat("a"))
    }
}
