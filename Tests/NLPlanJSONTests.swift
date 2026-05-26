//
//  NLPlanJSONTests.swift
//  HourglassTests
//
//  Tests for `PlanJSON` decoding and `PlanJSONParser` recovery from
//  messy LLM outputs. Real Qwen 2.5 1.5B emits ~98% clean JSON but the
//  remaining 2% includes markdown fences, prose preamble, and partial
//  brackets — the parser handles all of those.
//

import Foundation
import XCTest
@testable import Hourglass

final class NLPlanJSONTests: XCTestCase {

    // MARK: - PlanJSON decode

    func testPlanJSON_canonicalQuery_decodesAllFields() throws {
        let raw = """
        {
          "intent": "find_cluster_start",
          "person": "Annika",
          "time_window": "last_14d",
          "padding_days": 3,
          "concept": "argument",
          "search_query": "with:\\"Annika\\" last:21d argument"
        }
        """
        let p = try PlanJSONParser.parse(raw)
        XCTAssertEqual(p.intent, .findClusterStart)
        XCTAssertEqual(p.person, "Annika")
        XCTAssertEqual(p.timeWindow, .last14d)
        XCTAssertEqual(p.paddingDays, 3)
        XCTAssertEqual(p.concept, "argument")
        XCTAssertEqual(p.searchQuery, "with:\"Annika\" last:21d argument")
    }

    func testPlanJSON_missingFields_useDefaults() throws {
        let raw = """
        { "search_query": "hello" }
        """
        let p = try PlanJSONParser.parse(raw)
        XCTAssertEqual(p.intent, .findMessages)
        XCTAssertNil(p.person)
        XCTAssertEqual(p.timeWindow, .allTime)
        XCTAssertEqual(p.paddingDays, 0)
        XCTAssertNil(p.concept)
        XCTAssertEqual(p.searchQuery, "hello")
    }

    func testPlanJSON_emptyStringFields_normalizeToNil() throws {
        let raw = """
        { "person": "", "concept": "", "search_query": "x" }
        """
        let p = try PlanJSONParser.parse(raw)
        XCTAssertNil(p.person)
        XCTAssertNil(p.concept)
    }

    // MARK: - LLM-emitted quirks

    func testParser_markdownFences_stillExtractsObject() throws {
        let raw = """
        ```json
        {
          "intent": "find_messages",
          "person": "Mom",
          "time_window": "last_7d",
          "search_query": "from:Mom"
        }
        ```
        """
        let p = try PlanJSONParser.parse(raw)
        XCTAssertEqual(p.person, "Mom")
        XCTAssertEqual(p.timeWindow, .last7d)
    }

    func testParser_prosePreamble_isIgnored() throws {
        let raw = """
        Sure! Here's the plan:
        {
          "intent": "find_messages",
          "person": null,
          "time_window": "all_time",
          "search_query": "vegas"
        }
        Let me know if you need anything else.
        """
        let p = try PlanJSONParser.parse(raw)
        XCTAssertEqual(p.intent, .findMessages)
        XCTAssertEqual(p.searchQuery, "vegas")
    }

    func testParser_stringContainingBraces_doesNotConfuseScanner() throws {
        let raw = #"""
        {
          "intent": "find_messages",
          "person": null,
          "time_window": "all_time",
          "search_query": "weird {curly} braces in text"
        }
        """#
        let p = try PlanJSONParser.parse(raw)
        XCTAssertEqual(p.searchQuery, "weird {curly} braces in text")
    }

    func testParser_noJSONFound_throws() {
        let raw = "I couldn't generate a plan, sorry."
        XCTAssertThrowsError(try PlanJSONParser.parse(raw)) { err in
            guard let e = err as? PlanJSONParser.ParseError else { return XCTFail() }
            if case .noJSONObjectFound = e { return }
            XCTFail("expected noJSONObjectFound, got \(e)")
        }
    }

    func testParser_unbalancedBraces_throws() {
        let raw = "{ \"intent\": \"find_messages\" "  // missing }
        XCTAssertThrowsError(try PlanJSONParser.parse(raw))
    }

    // MARK: - TimeWindow → range

    func testTimeWindow_last7d_resolvesTo7DayRange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary anchor
        let range = PlanJSON.TimeWindow.last7d.toDateRange(now: now)!
        XCTAssertEqual(range.upperBound, now)
        let delta = range.upperBound.timeIntervalSince(range.lowerBound)
        XCTAssertEqual(delta, 7 * 24 * 60 * 60, accuracy: 60)
    }

    func testTimeWindow_allTime_returnsNil() {
        XCTAssertNil(PlanJSON.TimeWindow.allTime.toDateRange(now: Date()))
    }

    // MARK: - Intent coverage

    func testIntent_allRawValuesParse() throws {
        for intent in PlanJSON.Intent.allCases {
            let raw = """
            { "intent": "\(intent.rawValue)", "search_query": "x" }
            """
            let p = try PlanJSONParser.parse(raw)
            XCTAssertEqual(p.intent, intent)
        }
    }
}
