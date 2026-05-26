//
//  DateParserTests.swift
//  HourglassTests
//
//  Covers DateParser.parse — the pure-Foundation date language used by
//  `before:`, `after:`, `on:`, `last:` and standalone natural-date strings.
//

import XCTest
@testable import Hourglass

final class DateParserTests: XCTestCase {

    /// 2026-05-22 12:00:00 UTC — a Friday.
    private let referenceNow = Date(timeIntervalSince1970: 1_779_786_000)

    // MARK: - Relative deltas

    func testSevenDays() {
        guard case .range(let r)? = DateParser.parse("7d", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        XCTAssertEqual(r.upperBound, referenceNow)
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertEqual(delta, 7 * 86400, accuracy: 60)
    }

    func testTwentyFourHours() {
        guard case .range(let r)? = DateParser.parse("24h", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertEqual(delta, 24 * 3600, accuracy: 60)
    }

    func testOneYear() {
        guard case .range(let r)? = DateParser.parse("1y", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        // ~365 days, allow leap-year wiggle.
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertGreaterThan(delta, 364 * 86400)
        XCTAssertLessThan(delta, 367 * 86400)
    }

    func testThreeMonths() {
        guard case .range? = DateParser.parse("3mo", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
    }

    func testBareNumberIsDays() {
        guard case .range(let r)? = DateParser.parse("7", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertEqual(delta, 7 * 86400, accuracy: 60)
    }

    func testZeroIsRejected() {
        XCTAssertNil(DateParser.parse("0d", now: referenceNow))
    }

    func testNegativeIsRejected() {
        // Our grammar doesn't support negative deltas (use "after:" instead).
        XCTAssertNil(DateParser.parse("-3d", now: referenceNow))
    }

    // MARK: - Natural phrases

    func testToday() {
        guard case .range(let r)? = DateParser.parse("today", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        // Today must include referenceNow.
        XCTAssertLessThanOrEqual(r.lowerBound, referenceNow)
        XCTAssertGreaterThan(r.upperBound, referenceNow)
    }

    func testYesterday() {
        guard case .range(let r)? = DateParser.parse("yesterday", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        // Yesterday's range ends at start of today.
        XCTAssertLessThan(r.upperBound, referenceNow)
        // And spans ~24h.
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertEqual(delta, 86400, accuracy: 3600)
    }

    func testThisYear() {
        guard case .range(let r)? = DateParser.parse("this year", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        XCTAssertLessThanOrEqual(r.lowerBound, referenceNow)
    }

    func testYearShortcut() {
        guard case .range(let r)? = DateParser.parse("2024", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        // Should span ~1 year (2024 is a leap year so 366 days).
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertGreaterThan(delta, 365 * 86400)
        XCTAssertLessThan(delta, 367 * 86400)
    }

    // MARK: - ISO and US date

    func testISODate() {
        guard case .range(let r)? = DateParser.parse("2024-06-15", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
        // The range should span ~1 day.
        let delta = r.upperBound.timeIntervalSince(r.lowerBound)
        XCTAssertEqual(delta, 86400, accuracy: 3600)
    }

    func testUSDate() {
        guard case .range? = DateParser.parse("06/15/2024", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
    }

    // MARK: - Month-name dates

    func testFullMonthNameWithYear() {
        guard case .range? = DateParser.parse("May 8 2026", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
    }

    func testShortMonthNameWithoutYear() {
        guard case .range? = DateParser.parse("Jan 1", now: referenceNow) else {
            return XCTFail("Expected a range")
        }
    }

    // MARK: - Invalid inputs

    func testGarbageReturnsNil() {
        XCTAssertNil(DateParser.parse("blarg", now: referenceNow))
        XCTAssertNil(DateParser.parse("", now: referenceNow))
        XCTAssertNil(DateParser.parse("99/99/9999", now: referenceNow))
    }
}
