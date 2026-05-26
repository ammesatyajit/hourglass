//
//  ReactionParserTests.swift
//  HourglassTests
//
//  Covers MessageSearch.parseQuery's `reactions:` token handling and the
//  ReactionFilter.parse value parser. These are pure functions; no DB.
//

import XCTest
@testable import Hourglass

final class ReactionParserTests: XCTestCase {

    /// 2026-05-22 12:00:00 UTC — deterministic clock for date-token combos.
    private let referenceNow = Date(timeIntervalSince1970: 1_779_786_000)
    private let emptyContacts = ResolvedContacts(byHandle: [:], allContacts: [])

    // MARK: - ReactionFilter.parse direct

    func testParseAny() {
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("any"), .any)
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("ANY"), .any)
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("Any"), .any)
    }

    func testParseKinds() {
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("love"), .kind(.love))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("like"), .kind(.like))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("laugh"), .kind(.laugh))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("emphasize"), .kind(.emphasize))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("question"), .kind(.question))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("dislike"), .kind(.dislike))
    }

    func testParseComparators() {
        XCTAssertEqual(MessageSearch.ReactionFilter.parse(">=3"), .count(.greaterEqual, 3))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("<=1"), .count(.lessEqual, 1))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse(">0"), .count(.greater, 0))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("<10"), .count(.less, 10))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("=5"), .count(.equal, 5))
    }

    func testParseBareNumberIsEqual() {
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("3"), .count(.equal, 3))
        XCTAssertEqual(MessageSearch.ReactionFilter.parse("0"), .count(.equal, 0))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(MessageSearch.ReactionFilter.parse("hearts"))
        XCTAssertNil(MessageSearch.ReactionFilter.parse(">=abc"))
        XCTAssertNil(MessageSearch.ReactionFilter.parse("=="))
        XCTAssertNil(MessageSearch.ReactionFilter.parse(""))
        XCTAssertNil(MessageSearch.ReactionFilter.parse(">"))
    }

    // MARK: - parseQuery integration

    func testReactionsTokenAlone() {
        let p = MessageSearch.parseQuery("reactions:>=3", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.reactionFilters, [.count(.greaterEqual, 3)])
        XCTAssertEqual(p.freeText, "")
    }

    func testReactionsAny() {
        let p = MessageSearch.parseQuery("reactions:any cactus", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.reactionFilters, [.any])
        XCTAssertEqual(p.freeText, "cactus")
    }

    func testReactionsByKind() {
        let p = MessageSearch.parseQuery("reactions:love henry", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.reactionFilters, [.kind(.love)])
        XCTAssertEqual(p.freeText, "henry")
    }

    func testMultipleReactionTokensAndTogether() {
        let p = MessageSearch.parseQuery(
            "reactions:>=3 reactions:love",
            contacts: emptyContacts,
            now: referenceNow
        )
        XCTAssertEqual(p.reactionFilters, [.count(.greaterEqual, 3), .kind(.love)])
    }

    func testReactionsCombinedWithOtherFilters() {
        let p = MessageSearch.parseQuery(
            "reactions:>=2 from:mom last:30d hello",
            contacts: emptyContacts,
            now: referenceNow
        )
        XCTAssertEqual(p.reactionFilters, [.count(.greaterEqual, 2)])
        XCTAssertEqual(p.fromFilters, ["mom"])
        XCTAssertNotNil(p.dateRange)
        XCTAssertEqual(p.freeText, "hello")
    }

    func testReactionsCaseInsensitivePrefix() {
        let p = MessageSearch.parseQuery("Reactions:>=3", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.reactionFilters, [.count(.greaterEqual, 3)])
    }

    func testReactionsGarbageValueFallsThroughToFreeText() {
        // `reactions:` with an unrecognized value preserves the token text in
        // freeText so the user sees what they typed and can edit it.
        let p = MessageSearch.parseQuery("reactions:lol", contacts: emptyContacts, now: referenceNow)
        XCTAssertTrue(p.reactionFilters.isEmpty)
        XCTAssertEqual(p.freeText, "reactions:lol")
    }

    func testReactionsEmptyValueIsHarmless() {
        // Bare `reactions:` is recognized as a token but adds no filter, just
        // like `from:` and the other prefixes.
        let p = MessageSearch.parseQuery("reactions:", contacts: emptyContacts, now: referenceNow)
        XCTAssertTrue(p.reactionFilters.isEmpty)
        XCTAssertEqual(p.freeText, "")
    }

    // MARK: - Token range reporting

    func testReactionsTokenReportsItsRange() {
        let q = "hello reactions:love world"
        let p = MessageSearch.parseQuery(q, contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.tokens.count, 1)
        guard let token = p.tokens.first else { return XCTFail() }
        XCTAssertEqual(token.prefix, .reactions)
        XCTAssertEqual(token.value, "love")
        XCTAssertEqual(String(q[token.range]), "reactions:love")
    }
}
