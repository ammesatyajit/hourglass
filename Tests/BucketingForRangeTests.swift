//
//  BucketingForRangeTests.swift
//  Hourglass — pinning the length-based bucketing policy that
//  drives chart density for BOTH the segmented selector and the
//  navigator drag.
//
//  Thresholds (see `DashboardLoader.Bucketing.forRange`):
//    - ≤  60 days → .day
//    - ≤ 395 days → .week
//    - > 395 days → .month
//
//  These tests pin the boundary behavior precisely so a future agent
//  tweaking the thresholds (or the rounding rule) trips a red test
//  before the user trips the chart-density flicker.
//

import XCTest
@testable import Hourglass

final class BucketingForRangeTests: XCTestCase {

    // A Gregorian calendar pinned to the SAME zone as `anchor` (Pacific).
    // `day(at:)` does calendar-day arithmetic, so the calendar's zone MUST
    // match the anchor's — otherwise a machine in a European-DST zone spans
    // the European spring-forward when stepping back 60 days, making a
    // 60-day span measure 60d−1h. That flips the daily↔weekly boundary
    // tests (see testJustOverSixtyDaysIsWeeklyNotDaily, which adds −1s
    // expecting ceil→61 days). Pinning here keeps day arithmetic and the
    // anchor in one zone on every machine, regardless of TimeZone.current.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return c
    }()
    private lazy var anchor: Date = {
        // 2026-05-24 12:00 Pacific (`cal` is already pinned to LA).
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 24
        comps.hour = 12
        return cal.date(from: comps) ?? Date()
    }()

    // MARK: - Daily band (≤ 60 days)

    func testOneDayRangeIsDaily() {
        let range = day(at: -1)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .day)
    }

    func testThirtyDayRangeIsDaily() {
        let range = day(at: -30)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .day)
    }

    func testSixtyDayRangeIsDaily() {
        // 60 days exactly — still inside the daily band.
        let range = day(at: -60)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .day)
    }

    // MARK: - Daily → Weekly boundary

    func testSixtyOneDayRangePromotesToWeekly() {
        let range = day(at: -61)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .week,
                       "61 days crosses the 60-day daily ceiling; chart should re-bin to weekly.")
    }

    func testJustOverSixtyDaysIsWeeklyNotDaily() {
        // 60d + 1 second past midnight → still weekly (the `ceil` rule
        // protects against fluttering at the boundary).
        let range = day(at: -60).addingTimeInterval(-1)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .week)
    }

    // MARK: - Weekly band (61–395 days)

    func testNinetyDayRangeIsWeekly() {
        let range = day(at: -90)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .week)
    }

    func testOneYearRangeIsWeekly() {
        // 365 days — the "12m" preset's anchored span. Expected weekly.
        let range = day(at: -365)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .week,
                       "12-month preset should bin to weekly (~52 bars).")
    }

    func testThreeHundredNinetyFiveDayRangeIsWeekly() {
        // 13 months exactly — still inside the weekly band.
        let range = day(at: -395)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .week)
    }

    // MARK: - Weekly → Monthly boundary

    func testThreeHundredNinetySixDayRangePromotesToMonthly() {
        let range = day(at: -396)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .month,
                       "Just past the 13-month weekly ceiling; should be monthly.")
    }

    func testTwoYearRangeIsMonthly() {
        let range = day(at: -730)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .month)
    }

    func testFiveYearRangeIsMonthly() {
        let range = day(at: -1825)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .month)
    }

    // MARK: - Degenerate ranges

    func testZeroLengthRangeIsDaily() {
        // Lower == upper — degenerate but legal (no SQL would scan it
        // either way). Daily is the safest default at sub-day spans.
        let range = anchor...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .day)
    }

    func testSubDayRangeIsDaily() {
        let range = anchor.addingTimeInterval(-3600)...anchor
        XCTAssertEqual(DashboardLoader.Bucketing.forRange(range), .day)
    }

    // MARK: - Helpers

    private func day(at offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: anchor) ?? anchor
    }
}
