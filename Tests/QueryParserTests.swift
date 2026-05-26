//
//  QueryParserTests.swift
//  HourglassTests
//
//  Covers MessageSearch.parseQuery — the grammar that turns a typed string
//  into structured filters. The parser must be:
//    - permissive about casing on the prefix ("From:Foo" works)
//    - tolerant of empty values ("from:" should not crash)
//    - smart enough to bundle quoted values as one token
//    - happy to leave unknown prefixes as free text
//
//  Bug catches: it's easy to accidentally make `parseQuery` greedy or to
//  silently drop tokens. These tests pin the contract.
//

import XCTest
@testable import Hourglass

final class QueryParserTests: XCTestCase {

    /// Reference "now" so date-related parses are deterministic.
    /// 2026-05-22 12:00:00 UTC.
    private let referenceNow = Date(timeIntervalSince1970: 1_779_786_000)

    /// Empty contact set for tests that don't care about person resolution.
    private let emptyContacts = ResolvedContacts(byHandle: [:], allContacts: [])

    // MARK: - Empty / free text

    func testEmptyInputParsesToEmpty() {
        let p = MessageSearch.parseQuery("", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.freeText, "")
        XCTAssertTrue(p.chatFilters.isEmpty)
        XCTAssertTrue(p.fromFilters.isEmpty)
        XCTAssertTrue(p.toFilters.isEmpty)
        XCTAssertNil(p.dateRange)
        XCTAssertTrue(p.tokens.isEmpty)
    }

    func testFreeTextOnly() {
        let p = MessageSearch.parseQuery("henry cactus", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.freeText, "henry cactus")
        XCTAssertTrue(p.chatFilters.isEmpty)
        XCTAssertTrue(p.tokens.isEmpty)
    }

    // MARK: - chat: / in:

    func testSingleChatToken() {
        let p = MessageSearch.parseQuery("chat:amme", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.chatFilters, ["amme"])
        XCTAssertEqual(p.freeText, "")
    }

    func testInTokenIsAliasForChat() {
        let p = MessageSearch.parseQuery("in:amme", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.chatFilters, ["amme"])
    }

    func testMixedFreeTextAndChat() {
        let p = MessageSearch.parseQuery("henry chat:amme cactus", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.freeText, "henry cactus")
        XCTAssertEqual(p.chatFilters, ["amme"])
    }

    func testMultipleChatTokensAccumulate() {
        let p = MessageSearch.parseQuery("chat:amme chat:vegas", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.chatFilters, ["amme", "vegas"])
    }

    func testQuotedChatValue() {
        let p = MessageSearch.parseQuery(#"chat:"Amme Satyajit" cactus"#, contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.chatFilters, ["Amme Satyajit"])
        XCTAssertEqual(p.freeText, "cactus")
    }

    // MARK: - Casing

    func testPrefixIsCaseInsensitive() {
        let p1 = MessageSearch.parseQuery("From:Mom", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p1.fromFilters, ["Mom"])

        let p2 = MessageSearch.parseQuery("FROM:mom", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p2.fromFilters, ["mom"])

        let p3 = MessageSearch.parseQuery("Chat:Amme", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p3.chatFilters, ["Amme"])
    }

    // MARK: - with: (any chat with this person)

    /// `with:` collects its value into `withFilters`, separate from `chat:`/
    /// `in:` which collect into `chatFilters`. Semantically: `with:` is
    /// "any chat (1:1 or group) this person participates in"; `chat:`/`in:`
    /// is a substring match on the chat's `display_name` only — used for
    /// targeting a specific named chat.
    func testWithToken() {
        let p = MessageSearch.parseQuery("with:howard hello", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.withFilters, ["howard"])
        XCTAssertTrue(p.chatFilters.isEmpty,
                      "`with:` must NOT spill into chatFilters — they have different meanings (participant vs. chat name).")
        XCTAssertEqual(p.freeText, "hello")
    }

    func testWithTokenQuoted() {
        let p = MessageSearch.parseQuery(#"with:"Howard Hao Hao Xu" type:image"#,
                                         contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.withFilters, ["Howard Hao Hao Xu"])
        XCTAssertTrue(p.chatFilters.isEmpty)
    }

    func testWithAndChatTokensCoexist() {
        // Edge case: the user types both. Each must land in its own bucket.
        let p = MessageSearch.parseQuery("with:howard chat:family hi",
                                         contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.withFilters, ["howard"])
        XCTAssertEqual(p.chatFilters, ["family"])
        XCTAssertEqual(p.freeText, "hi")
    }

    func testMultipleWithTokensAccumulate() {
        let p = MessageSearch.parseQuery("with:henry with:mom", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.withFilters, ["henry", "mom"])
    }

    func testWithTokenIsCaseInsensitivePrefix() {
        let p = MessageSearch.parseQuery("With:Howard", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.withFilters, ["Howard"])
    }

    func testWithColonWithNoValueIsHarmless() {
        let p = MessageSearch.parseQuery("with: hello", contacts: emptyContacts, now: referenceNow)
        XCTAssertTrue(p.withFilters.isEmpty)
        XCTAssertEqual(p.freeText, "hello")
    }

    // MARK: - from: / to:

    func testFromToken() {
        let p = MessageSearch.parseQuery("from:satyajit hello", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.fromFilters, ["satyajit"])
        XCTAssertEqual(p.freeText, "hello")
    }

    func testToToken() {
        let p = MessageSearch.parseQuery("to:mom remember", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.toFilters, ["mom"])
        XCTAssertEqual(p.freeText, "remember")
    }

    func testFromAndToCombine() {
        let p = MessageSearch.parseQuery("from:mom to:dad hi", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.fromFilters, ["mom"])
        XCTAssertEqual(p.toFilters, ["dad"])
        XCTAssertEqual(p.freeText, "hi")
    }

    // MARK: - Empty / malformed token values

    func testFromColonWithNoValueIsHarmless() {
        // Graceful handling — empty `from:` is recognized but contributes
        // no filter. The token is still recorded for UI highlighting.
        let p = MessageSearch.parseQuery("from: hi", contacts: emptyContacts, now: referenceNow)
        XCTAssertTrue(p.fromFilters.isEmpty)
        XCTAssertEqual(p.freeText, "hi")
    }

    func testUnknownPrefixFallsThroughToFreeText() {
        // Unknown token prefix is treated as free text — no error, no drop.
        let p = MessageSearch.parseQuery("foo:bar hi", contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.freeText, "foo:bar hi")
        XCTAssertTrue(p.chatFilters.isEmpty)
        XCTAssertTrue(p.fromFilters.isEmpty)
    }

    // MARK: - Dates: relative deltas

    func testLastWithDayUnit() {
        let p = MessageSearch.parseQuery("last:7d", contacts: emptyContacts, now: referenceNow)
        guard let range = p.dateRange else { return XCTFail("Expected a date range") }
        let expected = referenceNow.addingTimeInterval(-7 * 86400)
        XCTAssertEqual(range.lowerBound.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(range.upperBound.timeIntervalSince1970, referenceNow.timeIntervalSince1970, accuracy: 1.0)
    }

    func testLastWithHourUnit() {
        let p = MessageSearch.parseQuery("last:24h", contacts: emptyContacts, now: referenceNow)
        guard let range = p.dateRange else { return XCTFail("Expected a date range") }
        XCTAssertEqual(range.lowerBound.timeIntervalSince1970,
                       referenceNow.addingTimeInterval(-24 * 3600).timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testLastWithWeekUnit() {
        let p = MessageSearch.parseQuery("last:2w", contacts: emptyContacts, now: referenceNow)
        XCTAssertNotNil(p.dateRange)
    }

    func testLastWithMonthUnit() {
        let p = MessageSearch.parseQuery("last:3mo", contacts: emptyContacts, now: referenceNow)
        XCTAssertNotNil(p.dateRange)
    }

    func testLastWithYearUnit() {
        let p = MessageSearch.parseQuery("last:1y", contacts: emptyContacts, now: referenceNow)
        XCTAssertNotNil(p.dateRange)
    }

    func testBareNumberDefaultsToDays() {
        let p = MessageSearch.parseQuery("last:7", contacts: emptyContacts, now: referenceNow)
        guard let range = p.dateRange else { return XCTFail("Expected a date range") }
        XCTAssertEqual(range.lowerBound.timeIntervalSince1970,
                       referenceNow.addingTimeInterval(-7 * 86400).timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // MARK: - Dates: natural phrases

    func testBeforeYesterday() {
        let p = MessageSearch.parseQuery("before:yesterday hello", contacts: emptyContacts, now: referenceNow)
        XCTAssertNotNil(p.dateRange)
        XCTAssertEqual(p.freeText, "hello")
    }

    func testOnToday() {
        let p = MessageSearch.parseQuery("on:today", contacts: emptyContacts, now: referenceNow)
        guard let range = p.dateRange else { return XCTFail("Expected a date range") }
        // Today should encompass referenceNow.
        XCTAssertLessThanOrEqual(range.lowerBound, referenceNow)
        XCTAssertGreaterThanOrEqual(range.upperBound, referenceNow)
    }

    func testQuotedNaturalDate() {
        let p = MessageSearch.parseQuery(#"before:"last week" cactus"#, contacts: emptyContacts, now: referenceNow)
        XCTAssertNotNil(p.dateRange)
        XCTAssertEqual(p.freeText, "cactus")
    }

    // MARK: - Combination

    func testEverythingTogether() {
        let p = MessageSearch.parseQuery(
            "henry from:mom in:amme last:30d cactus",
            contacts: emptyContacts,
            now: referenceNow
        )
        XCTAssertEqual(p.freeText, "henry cactus")
        XCTAssertEqual(p.fromFilters, ["mom"])
        XCTAssertEqual(p.chatFilters, ["amme"])
        XCTAssertNotNil(p.dateRange)
    }

    // MARK: - Token ranges for highlighting

    func testTokensReportTheirRanges() {
        let q = "henry chat:amme cactus"
        let p = MessageSearch.parseQuery(q, contacts: emptyContacts, now: referenceNow)
        XCTAssertEqual(p.tokens.count, 1)
        guard let token = p.tokens.first else { return XCTFail() }
        XCTAssertEqual(token.prefix, .chat)
        XCTAssertEqual(token.value, "amme")
        // The token's range should slice "chat:amme" out of the query.
        XCTAssertEqual(String(q[token.range]), "chat:amme")
    }

    // MARK: - Regression battery
    //
    // The four-feature parser upgrade (word-boundary default, *substring*
    // opt-out, /regex/, OR) added new syntax. None of it can break any
    // of the operator-prefix grammar. Each test below exercises a
    // pre-existing token combined with a simple AND query. If any one
    // regresses, this battery lights up.

    func testRegression_withSimpleAndQuery() {
        let p = MessageSearch.parseQuery(
            "with:howard cactus",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.withFilters, ["howard"])
        XCTAssertEqual(p.freeText, "cactus")
    }

    func testRegression_fromWithCoOccurrence() {
        let p = MessageSearch.parseQuery(
            "from:mom cactus+water",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.fromFilters, ["mom"])
        XCTAssertEqual(p.freeText, "cactus+water")
    }

    func testRegression_chatLastWithText() {
        let p = MessageSearch.parseQuery(
            "in:family last:7d dinner",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.chatFilters, ["family"])
        XCTAssertNotNil(p.dateRange)
        XCTAssertEqual(p.freeText, "dinner")
    }

    func testRegression_reactionsWithText() {
        let p = MessageSearch.parseQuery(
            "reactions:love hello",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.reactionFilters.count, 1)
        XCTAssertEqual(p.freeText, "hello")
    }

    func testRegression_typeWithText() {
        let p = MessageSearch.parseQuery(
            "type:image vacation",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.typeFilters, [.image])
        XCTAssertEqual(p.freeText, "vacation")
    }

    func testRegression_complexCombination() {
        // Same query the existing testEverythingTogether used. Added
        // here too as a regression seal — if a parser refactor breaks
        // any operator while passing the new tests, this catches it.
        let p = MessageSearch.parseQuery(
            "henry from:mom in:amme last:30d cactus",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.freeText, "henry cactus")
        XCTAssertEqual(p.fromFilters, ["mom"])
        XCTAssertEqual(p.chatFilters, ["amme"])
        XCTAssertNotNil(p.dateRange)
    }

    func testRegression_newOperators_doNotShowAsTokens() {
        // The new phrase operators (`|`, `*foo*`, `/regex/`) live in
        // freeText, NOT as recognized colon-prefix tokens. The token
        // list (used by the UI highlighter) should stay empty for a
        // pure-text query.
        let p = MessageSearch.parseQuery(
            "cactus|saguaro",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.freeText, "cactus|saguaro",
                       "OR-pipe is free-text — phrase-parser owns it.")
        XCTAssertTrue(p.tokens.isEmpty)
    }

    func testRegression_regexInFreeText() {
        let p = MessageSearch.parseQuery(
            "/cact.*/",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.freeText, "/cact.*/")
        XCTAssertTrue(p.tokens.isEmpty)
    }

    func testRegression_substringOptOut() {
        let p = MessageSearch.parseQuery(
            "*cactus*",
            contacts: emptyContacts, now: referenceNow
        )
        XCTAssertEqual(p.freeText, "*cactus*")
    }
}
