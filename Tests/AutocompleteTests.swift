//
//  AutocompleteTests.swift
//  HourglassTests
//
//  QueryAutocomplete is pure — given a query + caret, decide what token (if
//  any) the user is typing. The tests pin the matching rules so we don't
//  accidentally break the popover when we extend the grammar.
//

import XCTest
@testable import Hourglass

final class AutocompleteTests: XCTestCase {

    func testEmptyQueryYieldsNothing() {
        XCTAssertNil(QueryAutocomplete.analyze(query: ""))
    }

    func testFreeTextYieldsNothing() {
        XCTAssertNil(QueryAutocomplete.analyze(query: "hello world"))
    }

    func testChatTokenAtEnd() {
        let ctx = QueryAutocomplete.analyze(query: "chat:am")
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.prefix, .chat)
        XCTAssertEqual(ctx?.partialValue, "am")
    }

    func testFromTokenWithEmptyValue() {
        let ctx = QueryAutocomplete.analyze(query: "from:")
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.prefix, .from)
        XCTAssertEqual(ctx?.partialValue, "")
    }

    func testTokenInMiddleOfQuery() {
        let q = "henry chat:am cactus"
        // Caret at end of "am" — index after the "m" in "chat:am".
        let caret = q.index(q.startIndex, offsetBy: 13) // after "henry chat:am"
        let ctx = QueryAutocomplete.analyze(query: q, caret: caret)
        XCTAssertEqual(ctx?.prefix, .chat)
        XCTAssertEqual(ctx?.partialValue, "am")
    }

    func testCaseInsensitivePrefix() {
        let ctx = QueryAutocomplete.analyze(query: "From:Mo")
        XCTAssertEqual(ctx?.prefix, .from)
        XCTAssertEqual(ctx?.partialValue, "Mo")
    }

    func testQuotedValue() {
        let q = #"chat:"Amme Sat"#
        let ctx = QueryAutocomplete.analyze(query: q)
        XCTAssertEqual(ctx?.prefix, .chat)
        XCTAssertEqual(ctx?.partialValue, "Amme Sat")
        XCTAssertTrue(ctx?.isQuoted ?? false)
    }

    func testApplyReplacesTokenWithoutQuotes() {
        let q = "henry chat:am"
        guard let ctx = QueryAutocomplete.analyze(query: q) else { return XCTFail() }
        let (newQuery, _) = QueryAutocomplete.apply(suggestion: "amme", to: q, in: ctx)
        XCTAssertEqual(newQuery, "henry chat:amme")
    }

    func testApplyQuotesValuesWithSpaces() {
        let q = "chat:am"
        guard let ctx = QueryAutocomplete.analyze(query: q) else { return XCTFail() }
        let (newQuery, _) = QueryAutocomplete.apply(suggestion: "Amme Satyajit", to: q, in: ctx)
        XCTAssertEqual(newQuery, #"chat:"Amme Satyajit""#)
    }

    func testRankPrefixHitsBeforeSubstring() {
        let values = ["Amme Satyajit", "Henry Group", "Pizza Plans", "Mom"]
        // Empty partial returns first N.
        let all = QueryAutocomplete.rank(values, partial: "", limit: 4)
        XCTAssertEqual(all.count, 4)

        // Prefix match first, then substring.
        let ranked = QueryAutocomplete.rank(values, partial: "P", limit: 5)
        XCTAssertEqual(ranked.first, "Pizza Plans")
    }

    func testRankIsCaseInsensitive() {
        let values = ["Amme Satyajit", "Henry"]
        let ranked = QueryAutocomplete.rank(values, partial: "henry", limit: 5)
        XCTAssertEqual(ranked, ["Henry"])
    }

    func testTokenPrefixMatching() {
        let matches = TokenPrefix.matching("fr")
        XCTAssertEqual(matches, [.from])
        let multi = TokenPrefix.matching("c")
        XCTAssertEqual(multi, [.chat])
    }
}
