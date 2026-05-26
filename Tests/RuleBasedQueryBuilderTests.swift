//
//  RuleBasedQueryBuilderTests.swift
//  HourglassTests
//
//  Pin the contract of the NL agent's rule-based fallback. These tests
//  are the safety net for the case when the LLM planner fails — the
//  fallback must produce a query that has at least a chance of returning
//  the right thing, NOT a literal AND of all input words minus stopword
//  guessing (the previous broken behaviour).
//

import Foundation
import XCTest
@testable import Hourglass

final class RuleBasedQueryBuilderTests: XCTestCase {

    // The canonical query the user surfaced as broken in the bug report.
    func testCanonicalQuery_extractsAnnikaAndDate() {
        let contacts = ["Annika Knechtel", "Henry Park", "Erik Pukinskis", "Mom"]
        let r = RuleBasedQueryBuilder.build(
            from: "find my argument with annika that happened maybe 2 weeks ago",
            contactNames: contacts
        )
        XCTAssertEqual(r.person, "Annika Knechtel")
        XCTAssertNotNil(r.dateOperator)
        XCTAssertTrue(r.dateOperator!.hasPrefix("last:"))
        // Fuzzy ("maybe 2 weeks ago") should widen: 14 → ~21 days.
        XCTAssertTrue(
            r.query.contains("last:21d") || r.query.contains("last:20d") || r.query.contains("last:22d"),
            "expected widened ~21d for fuzzy '2 weeks ago', got query=\(r.query)"
        )
        XCTAssertTrue(r.query.contains("with:\"Annika Knechtel\""), "got: \(r.query)")
        XCTAssertTrue(r.concepts.contains("argument"), "got: \(r.concepts)")
        XCTAssertFalse(
            r.query.contains("maybe"),
            "fuzzy filler should not leak into the search query, got: \(r.query)"
        )
        XCTAssertFalse(
            r.query.contains("happened"),
            "stopword should be removed, got: \(r.query)"
        )
    }

    func testFromVerbRecognised() {
        let r = RuleBasedQueryBuilder.build(
            from: "show me messages from Henry about dinner",
            contactNames: ["Henry Park"]
        )
        XCTAssertEqual(r.person, "Henry Park")
        XCTAssertTrue(r.query.contains("from:\"Henry Park\""),
                      "should use from:, got: \(r.query)")
        XCTAssertTrue(r.concepts.contains("dinner"))
    }

    func testWithVerbRecognised() {
        let r = RuleBasedQueryBuilder.build(
            from: "what plans did Erik and I make about vegas",
            contactNames: ["Erik Pukinskis"]
        )
        XCTAssertEqual(r.person, "Erik Pukinskis")
        XCTAssertTrue(r.query.contains("with:\"Erik Pukinskis\""), "got: \(r.query)")
        XCTAssertTrue(r.concepts.contains("vegas"))
        XCTAssertTrue(r.concepts.contains("plans"))
    }

    func testFirstNameOnly_matches() {
        let r = RuleBasedQueryBuilder.build(
            from: "did Henry say anything",
            contactNames: ["Henry Park"]
        )
        XCTAssertEqual(r.person, "Henry Park")
    }

    func testLongestMatch_winsOverShorter() {
        // "Henry" is also a first-word of "Henry Park"; the full match should win.
        let r = RuleBasedQueryBuilder.build(
            from: "argument with Henry Park last week",
            contactNames: ["Henry", "Henry Park"]
        )
        XCTAssertEqual(r.person, "Henry Park", "should pick the longest match")
        XCTAssertEqual(r.dateOperator, "last:14d")
    }

    func testStopwords_dropped() {
        let r = RuleBasedQueryBuilder.build(
            from: "what did mom say about dinner this week",
            contactNames: ["Mom"]
        )
        XCTAssertEqual(r.person, "Mom")
        XCTAssertEqual(r.dateOperator, "last:7d")
        // "did", "say", "about", "this", "week" should all be dropped.
        XCTAssertFalse(r.query.contains("did"))
        XCTAssertFalse(r.query.contains("say"))
        XCTAssertFalse(r.query.contains("about"))
        XCTAssertFalse(r.query.contains(" this "))
        // "dinner" should survive.
        XCTAssertTrue(r.concepts.contains("dinner"))
    }

    // MARK: - Date extraction

    func testYesterday() {
        let r = RuleBasedQueryBuilder.build(from: "messages from yesterday", contactNames: [])
        XCTAssertEqual(r.dateOperator, "last:2d")
    }

    func testThisWeek() {
        let r = RuleBasedQueryBuilder.build(from: "messages this week", contactNames: [])
        XCTAssertEqual(r.dateOperator, "last:7d")
    }

    func testThisMonth() {
        let r = RuleBasedQueryBuilder.build(from: "what happened this month", contactNames: [])
        XCTAssertEqual(r.dateOperator, "last:30d")
    }

    func testThisYear() {
        let r = RuleBasedQueryBuilder.build(from: "all messages this year", contactNames: [])
        XCTAssertEqual(r.dateOperator, "last:365d")
    }

    func testNumberAndUnitAgo() {
        let r = RuleBasedQueryBuilder.build(from: "3 weeks ago", contactNames: [])
        // 21 days exact + 25% widening for non-fuzzy = ~26.
        XCTAssertNotNil(r.dateOperator)
        let op = r.dateOperator!
        XCTAssertTrue(op.hasPrefix("last:"))
        // Should be between 21 and 30.
        let n = Int(op.dropFirst("last:".count).dropLast()) ?? 0
        XCTAssertTrue(n >= 21 && n <= 30, "expected ~21-30 days, got \(n) (op=\(op))")
    }

    func testFuzzyWidensWindow() {
        let exact = RuleBasedQueryBuilder.build(from: "2 weeks ago", contactNames: [])
        let fuzzy = RuleBasedQueryBuilder.build(from: "around 2 weeks ago", contactNames: [])
        let exactN = Int(exact.dateOperator!.dropFirst("last:".count).dropLast()) ?? 0
        let fuzzyN = Int(fuzzy.dateOperator!.dropFirst("last:".count).dropLast()) ?? 0
        XCTAssertGreaterThan(fuzzyN, exactN, "fuzzy should widen relative to exact (\(exactN) vs \(fuzzyN))")
    }

    func testWordNumbersWork() {
        let r = RuleBasedQueryBuilder.build(from: "three weeks ago", contactNames: [])
        XCTAssertNotNil(r.dateOperator)
    }

    // MARK: - Empty / pathological inputs

    func testEmpty_returnsEmpty() {
        let r = RuleBasedQueryBuilder.build(from: "", contactNames: [])
        XCTAssertEqual(r.query, "")
    }

    func testOnlyStopwords_fallsBackToOriginal() {
        // No structure, no concepts — should fall back to the input.
        let r = RuleBasedQueryBuilder.build(from: "what the about", contactNames: [])
        XCTAssertEqual(r.query, "what the about")
    }

    func testNoContacts_recognisesNone() {
        let r = RuleBasedQueryBuilder.build(
            from: "find my argument with Annika yesterday",
            contactNames: []
        )
        XCTAssertNil(r.person)
        XCTAssertEqual(r.dateOperator, "last:2d")
        XCTAssertTrue(r.concepts.contains("argument"))
    }

    // MARK: - Composition

    func testFullCompose_personDateConcept() {
        let r = RuleBasedQueryBuilder.build(
            from: "find my argument with annika that happened maybe 2 weeks ago",
            contactNames: ["Annika"]
        )
        // Order matters: person, then date, then concept.
        XCTAssertTrue(r.query.contains("with:\"Annika\""))
        XCTAssertTrue(r.query.contains("last:"))
        XCTAssertTrue(r.query.contains("argument"))
    }

    func testQuotedNameForMultiWordContacts() {
        let r = RuleBasedQueryBuilder.build(
            from: "messages with John Smith yesterday",
            contactNames: ["John Smith"]
        )
        XCTAssertTrue(r.query.contains("with:\"John Smith\""),
                      "multi-word names must be quoted, got: \(r.query)")
    }

    // MARK: - The previous broken behaviour shouldn't reappear

    func testNotJustANDOfAllInputWords() {
        // The previous fallback produced "last:21d argument annika maybe"
        // which never co-occurred in real messages.
        let r = RuleBasedQueryBuilder.build(
            from: "find my argument with annika that happened maybe 2 weeks ago",
            contactNames: ["Annika"]
        )
        // "annika" should NOT appear as a raw search term — it should be in
        // the with: operator.
        XCTAssertFalse(
            r.query.lowercased().split(whereSeparator: { $0.isWhitespace }).contains("annika"),
            "annika should be in with:\"Annika\", not a bare keyword, got: \(r.query)"
        )
        XCTAssertFalse(r.query.contains("maybe"), "filler word leak, got: \(r.query)")
        XCTAssertFalse(r.query.contains("happened"), "stopword leak, got: \(r.query)")
        // Only ONE meaningful keyword for the concept (engine has no OR).
        let words = r.query.split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.contains(":") }  // drop operators
        XCTAssertLessThanOrEqual(words.count, 2,
            "fallback should emit minimal keywords; engine AND's. got: \(r.query)")
    }
}
