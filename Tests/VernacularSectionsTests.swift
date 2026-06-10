//
//  VernacularSectionsTests.swift
//  HourglassTests
//
//  Pure-logic coverage for the remaining Vernacular DATA fixes (see plans.md):
//    Fix 1 — FUNNY: reacted gems key on the per-message `laughed` flag (😂 only,
//            NOT love/emphasize), exclude URL + coordination bodies, require
//            laughed ≥ floor, rank by laugh-RATE.
//    Fix 3 — EMPHATIC: case-sensitive shouted-word detection over original-case
//            text ("ts is NOT it" ⇒ NOT; "ts is not it" ⇒ nothing).
//    Fix 4 — URL exclusion shares one predicate (`VernacularLoader.containsURL`).
//
//  Small hand-built corpora — no chat.db, no model. Mirrors the assertions the
//  out-of-band `swiftc -O` harness checks against the real chat.db.
//
//  NOTE: `./scripts/test.sh` currently HANGS on the documented XCTest-host
//  model-load issue; these were verified via the harness in /tmp/vernfix. They
//  run normally once the host hang is fixed.
//

import XCTest
@testable import Hourglass

private func baselineFrom(_ counts: [String: Double]) -> LinguisticBaseline {
    LinguisticBaseline(counts: counts, isPlaceholder: false)
}

/// A sent/received message with optional `laughed` / `amused` flags + a chosen day.
private func vmsg(_ body: String, fromMe: Bool, who: String, day: Double,
                  laughed: Bool = false, amused: Bool = false) -> VernacularMessage {
    VernacularMessage(date: day * 86_400, chat: 1, fromMe: fromMe, who: who,
                      body: body, uptake: 0, amused: amused, laughed: laughed)
}

// MARK: - Fix 1: reacted gems ("funny") key on laughed, exclude URLs/coordination

final class VernacularReactedGemsTests: XCTestCase {

    /// A baseline where the gem's content word is rare (so the family clears the
    /// over-rep + scaffolding gates) but the scaffolding words are common.
    private func gemBaseline() -> LinguisticBaseline {
        baselineFrom(["my": 5_000_000, "on": 4_000_000, "not": 6_000_000, "was": 3_000_000,
                      "bingo": 30, "card": 20_000, "the": 9_000_000, "is": 8_000_000])
    }

    func testGemUsesLaughedNotLoveOrEmphasize() {
        var msgs: [VernacularMessage] = []
        // "was not on my bingo card": you use it 6×; 3 of those got a LAUGH.
        for i in 0..<3 { msgs.append(vmsg("that was not on my bingo card lol", fromMe: true, who: "You", day: Double(i), laughed: true)) }
        for i in 0..<3 { msgs.append(vmsg("was not on my bingo card fr", fromMe: true, who: "You", day: 10 + Double(i))) }
        // a LOVE-reacted phrase ("on my radar") with the SAME volume must NOT
        // count as funny (love means agree, not laugh).
        for i in 0..<6 { msgs.append(vmsg("that is on my radar", fromMe: true, who: "You", day: 30 + Double(i), amused: true)) }
        let gems = VernacularAnalyzer.buildReactedGems(messages: msgs, baseline: gemBaseline())
        XCTAssertTrue(gems.contains { $0.phrase.contains("bingo") }, "laughed phrase surfaces")
        XCTAssertFalse(gems.contains { $0.phrase.contains("radar") }, "love-only phrase is NOT a funny gem")
    }

    func testGemRankedByRateNotVolume() {
        var msgs: [VernacularMessage] = []
        // HIGH-RATE: "bingo card" 5 uses, 2 laughs (40%).
        for i in 0..<2 { msgs.append(vmsg("not on my bingo card", fromMe: true, who: "You", day: Double(i), laughed: true)) }
        for i in 0..<3 { msgs.append(vmsg("not on my bingo card again", fromMe: true, who: "You", day: 10 + Double(i))) }
        // LOW-RATE high-volume: "i was gonna" 100 uses, 2 laughs (2%).
        for i in 0..<2 { msgs.append(vmsg("i was gonna say", fromMe: true, who: "You", day: 50 + Double(i), laughed: true)) }
        for i in 0..<98 { msgs.append(vmsg("i was gonna go", fromMe: true, who: "You", day: 60 + Double(i))) }
        let base = baselineFrom(["i": 9e6, "was": 3e6, "gonna": 5e5, "say": 4e5, "go": 4e5,
                                 "not": 6e6, "on": 4e6, "my": 5e6, "bingo": 30, "card": 2e4, "again": 1e5])
        let gems = VernacularAnalyzer.buildReactedGems(messages: msgs, baseline: base)
        // The high-rate bingo phrase must rank ABOVE the 2%-rate high-volume one.
        let bingoIdx = gems.firstIndex { $0.phrase.contains("bingo") }
        let gonnaIdx = gems.firstIndex { $0.phrase.contains("gonna") }
        if let b = bingoIdx, let g = gonnaIdx {
            XCTAssertLessThan(b, g, "40%-rate phrase outranks 2%-rate high-volume phrase")
        } else {
            XCTAssertNotNil(bingoIdx, "the high-rate phrase must be present")
        }
    }

    func testGemExcludesURLAndCoordination() {
        var msgs: [VernacularMessage] = []
        // A laughed phrase that ALSO contains a URL in one body → excluded.
        for i in 0..<2 { msgs.append(vmsg("try this on my mac www.messageswrapped.com", fromMe: true, who: "You", day: Double(i), laughed: true)) }
        for i in 0..<3 { msgs.append(vmsg("try this on my mac now", fromMe: true, who: "You", day: 10 + Double(i))) }
        // A laughed coordination phrase → excluded.
        for i in 0..<3 { msgs.append(vmsg("react if you are coming to my thing", fromMe: true, who: "You", day: 30 + Double(i), laughed: true)) }
        let base = baselineFrom(["try": 1e5, "this": 8e6, "on": 4e6, "my": 5e6, "mac": 50,
                                 "now": 5e5, "react": 100, "coming": 5e4, "thing": 8e4])
        let gems = VernacularAnalyzer.buildReactedGems(messages: msgs, baseline: base)
        XCTAssertFalse(gems.contains { ($0.example ?? "").lowercased().contains("messageswrapped") },
                       "URL-bearing phrase is never a gem")
        XCTAssertFalse(gems.contains { BelovedMessagesLoader.isCoordination($0.example ?? "") },
                       "coordination phrase is never a gem")
    }

    func testContainsURLPredicate() {
        XCTAssertTrue(VernacularLoader.containsURL("try this www.messageswrapped.com"))
        XCTAssertTrue(VernacularLoader.containsURL("see https://x.org"))
        XCTAssertTrue(VernacularLoader.containsURL("foo.net bar"))
        XCTAssertFalse(VernacularLoader.containsURL("just a normal message"))
        XCTAssertFalse(VernacularLoader.containsURL("dot com is two words"))
    }
}

// MARK: - Fix 3: emphatic (case-sensitive) constructions

final class EmphaticDetectorTests: XCTestCase {

    private let one = VernacularAnalyzer.SectionsOptions(emphaticMinShouted: 1)

    func testShoutedWordIsEmphatic() {
        let items = EmphaticDetector.detect(
            sentBodies: ["ts is NOT it", "this is not it", "no it is not"], options: one)
        XCTAssertTrue(items.contains { $0.word == "NOT" }, "'ts is NOT it' yields NOT")
    }

    func testLowercaseIsNotEmphatic() {
        let items = EmphaticDetector.detect(
            sentBodies: ["ts is not it", "this is not it", "no it is not"], options: one)
        XCTAssertFalse(items.contains { $0.word == "NOT" }, "'ts is not it' yields nothing")
    }

    func testMayEmphaticWithFrame() {
        let items = EmphaticDetector.detect(
            sentBodies: ["he MAY be a traffic cone", "he may be right", "i may go"], options: one)
        let may = items.first { $0.word == "MAY" }
        XCTAssertNotNil(may, "'he MAY be a traffic cone' yields MAY")
        XCTAssertNotNil(may?.frame)
    }

    func testAcronymStoplisted() {
        let items = EmphaticDetector.detect(
            sentBodies: ["LOL that is wild", "LOL ok", "lol again"], options: one)
        XCTAssertFalse(items.contains { $0.word == "LOL" }, "LOL is stoplisted")
    }

    func testNeverLowercasedAcronymExcluded() {
        // all-caps token that NEVER appears lowercased is not a shoutable word.
        let items = EmphaticDetector.detect(
            sentBodies: ["my ZYX is broken", "the ZYX again"], options: one)
        XCTAssertFalse(items.contains { $0.word == "ZYX" })
    }

    func testCalmFormMustDominate() {
        // shouted MORE than lowercased ⇒ looks like an acronym, not emphasis.
        let acronymish = EmphaticDetector.detect(
            sentBodies: ["NLP is hard", "NLP again", "i like nlp"], options: one)
        XCTAssertFalse(acronymish.contains { $0.word == "NLP" },
                       "shouted (×2) more than lowercased (×1) → excluded")
        // shouted occasionally, lowercased often ⇒ genuine emphasis word.
        let emph = EmphaticDetector.detect(
            sentBodies: ["that is SO good", "so cool", "so fun", "so nice"], options: one)
        XCTAssertTrue(emph.contains { $0.word == "SO" })
    }

    func testWholeMessageYellingNotEmphasis() {
        // a fully-capslocked message is yelling, not per-word emphasis.
        let items = EmphaticDetector.detect(
            sentBodies: ["WE NEED YOU ON THE BASS DRUM", "we need you", "the bass", "on the drum"],
            options: one)
        XCTAssertFalse(items.contains { $0.word == "THE" }, "function words in all-caps msgs are not emphatic")
    }

    func testIsShoutTokenRules() {
        XCTAssertTrue(EmphaticDetector.isShoutToken("NOT"))
        XCTAssertTrue(EmphaticDetector.isShoutToken("MAY"))
        XCTAssertFalse(EmphaticDetector.isShoutToken("A"), "single letter is not a shout")
        XCTAssertFalse(EmphaticDetector.isShoutToken("Not"), "mixed case is not a shout")
        XCTAssertFalse(EmphaticDetector.isShoutToken("not"), "lowercase is not a shout")
        XCTAssertFalse(EmphaticDetector.isShoutToken("123"), "digits are not letters")
    }
}
