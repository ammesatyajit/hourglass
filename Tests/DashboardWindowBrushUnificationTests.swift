//
//  DashboardWindowBrushUnificationTests.swift
//  Hourglass — pins the contract that `DashboardViewModel.window`
//  and `DashboardViewModel.brushedRange` are TWO AFFORDANCES ON THE SAME
//  LOGICAL STATE.
//
//  Bugs this contract prevents (both reported by the user 2026-05-24):
//    1. Dragging the navigator showed daily bars across a 1-year window,
//       while the `12m` preset uses monthly bars → inconsistent density.
//       FIX: bucketing now follows the active range's LENGTH via
//       `Bucketing.forRange`, so segmented-click and drag produce the
//       same chart density at the same span.
//    2. Clicking `30d / 12m / All` didn't move the navigator's pill —
//       it stayed on whatever the last drag set.
//       FIX: picking a segment now writes the preset's anchored range
//       into `brushedRange`, so the navigator pill auto-updates.
//

import XCTest
@testable import Hourglass

@MainActor
final class DashboardWindowBrushUnificationTests: XCTestCase {

    // MARK: - Fixture

    /// 800-day synthetic aggregate ending today. Enough span to
    /// exercise all three preset windows (30d / 12m / All).
    private func makeAggregate(today: Date = Date()) -> DashboardAllTimeAggregate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let endIdx = DashboardAllTimeAggregate.dayIndex(for: today)
        let startIdx = endIdx - 800

        let dailyOverview: [DailyCount] = (startIdx...endIdx).map {
            DailyCount(dayIndex: $0, sent: 3, received: 2)
        }

        return DashboardAllTimeAggregate(
            calendar: cal,
            dailyOverview: dailyOverview,
            allTimeChats: 5,
            allTimeOldest: Date(
                timeIntervalSinceReferenceDate: Double(startIdx) * 86_400
            ),
            allTimeNewest: today,
            contactSeries: [],
            groupSeries: []
        )
    }

    // MARK: - Test 1: aggregate landing snaps the brush to the preset

    /// When the aggregate first loads, `brushedRange` snaps to the
    /// current preset's anchored range. This is what makes the
    /// navigator pill render the right window on the very first
    /// interactive frame.
    func testAggregateLandingSnapsBrushToPreset() {
        let vm = DashboardViewModel()
        XCTAssertNil(vm.brushedRange,
                     "Pre-aggregate: no brush yet — legacy SQL path drives the first paint.")

        vm._setAggregateForTests(makeAggregate())

        XCTAssertNotNil(vm.brushedRange,
                        "Post-aggregate: brush should be snapped to the preset (30 days).")
        // Should be within a couple of days of the 30-day window.
        // (We can't pin exact equality because the test compares to
        // `Date()` evaluated inside _setAggregateForTests.)
        if let brush = vm.brushedRange {
            let days = abs(brush.upperBound.timeIntervalSince(brush.lowerBound) / 86_400)
            XCTAssertEqual(days, 30, accuracy: 1.5,
                           "Brushed range after snap should span ~30 days for the .last30Days preset.")
        }
    }

    // MARK: - Test 2: segmented click mirrors into the brush

    /// Picking a different segment mirrors that preset's anchored
    /// range into `brushedRange` — so the navigator pill follows
    /// the segmented selector automatically.
    func testWindowFlipMirrorsIntoBrushedRange() {
        let vm = DashboardViewModel()
        vm._setAggregateForTests(makeAggregate())

        // 30d preset → brush ~30 days
        if let r30 = vm.brushedRange {
            let days30 = r30.upperBound.timeIntervalSince(r30.lowerBound) / 86_400
            XCTAssertEqual(days30, 30, accuracy: 1.5, "Initial 30d preset span.")
        } else {
            XCTFail("Brush should be set after aggregate landing.")
        }

        // 12m preset → brush ~365 days
        vm.window = .last12Months
        guard let r12m = vm.brushedRange else {
            XCTFail("Brush should auto-update when window flips to 12m.")
            return
        }
        let days12m = r12m.upperBound.timeIntervalSince(r12m.lowerBound) / 86_400
        XCTAssertEqual(days12m, 365, accuracy: 3,
                       "12m preset should write a ~365-day brush range.")

        // All preset → brush ~aggregate-span days (clamped to data)
        vm.window = .allTime
        guard let rAll = vm.brushedRange else {
            XCTFail("Brush should auto-update when window flips to All.")
            return
        }
        let daysAll = rAll.upperBound.timeIntervalSince(rAll.lowerBound) / 86_400
        // Aggregate spans ~800 days; "all time" should resolve to the
        // aggregate's clamped span — but at minimum bigger than 12m.
        XCTAssertGreaterThan(daysAll, 365,
                             "All preset should cover at least the aggregate's full span (~800 days).")
    }

    // MARK: - Test 3: dragging brush DOES NOT change `window`

    /// Manually setting `brushedRange` (as a drag would) must NOT
    /// change the segmented selection. Segments are shortcuts the
    /// user clicks; the segment highlight should reflect the LAST
    /// click, not the brushed range. (Otherwise, dragging the
    /// navigator would orphan the segmented highlight.)
    func testNavigatorDragDoesNotMoveSegmentedSelection() {
        let vm = DashboardViewModel()
        vm._setAggregateForTests(makeAggregate())

        XCTAssertEqual(vm.window, .last30Days,
                       "Initial preset before any interaction.")

        // Drag to a different range (a 90-day window in the middle of
        // history — wouldn't match any preset).
        let now = Date()
        let lo = now.addingTimeInterval(-180 * 86_400)
        let hi = now.addingTimeInterval(-90 * 86_400)
        vm.brushedRange = lo...hi

        XCTAssertEqual(vm.window, .last30Days,
                       "Brush drag must NOT change the segmented selection.")
    }

    // MARK: - Test 4: bucketing follows length, not preset

    /// After a navigator drag, `activeBucketing` reflects the dragged
    /// range's length, not the segmented preset. A 1-year drag with
    /// the segment still on `30d` should bin weekly.
    func testActiveBucketingFollowsRangeLength() {
        let vm = DashboardViewModel()
        vm._setAggregateForTests(makeAggregate())
        XCTAssertEqual(vm.window, .last30Days)
        XCTAssertEqual(vm.activeBucketing, .day,
                       "30d preset → daily bucketing.")

        // Drag to a 1-year window. Segmented selector unchanged.
        let now = Date()
        vm.brushedRange = now.addingTimeInterval(-365 * 86_400)...now
        XCTAssertEqual(vm.window, .last30Days,
                       "Drag must not move segmented selection.")
        XCTAssertEqual(vm.activeBucketing, .week,
                       "Year-long brush should re-bin to weekly, regardless of segment.")

        // Drag to a 3-year window.
        vm.brushedRange = now.addingTimeInterval(-1095 * 86_400)...now
        XCTAssertEqual(vm.activeBucketing, .month,
                       "Multi-year brush should re-bin to monthly.")
    }

    // MARK: - Test 5: brushMatchesPreset is sensitive to dragged drift

    /// `brushMatchesPreset` is the predicate the subtitle uses to drop
    /// the "Custom:" prefix. After picking 30d, it's true; after
    /// dragging the brush off the preset boundary by >1 day, it
    /// flips to false.
    func testBrushMatchesPresetReflectsDragDrift() {
        let vm = DashboardViewModel()
        vm._setAggregateForTests(makeAggregate())
        XCTAssertTrue(vm.brushMatchesPreset,
                      "After preset snap, brush should match the preset exactly.")

        // Drag the lower bound back by a week (out of preset alignment).
        if let brush = vm.brushedRange {
            vm.brushedRange = brush.lowerBound.addingTimeInterval(-7 * 86_400)...brush.upperBound
            XCTAssertFalse(vm.brushMatchesPreset,
                           "Dragged brush should NOT match preset; subtitle adopts 'Custom:'.")
        }
    }

    // MARK: - Test 6: clicking segment AFTER drag re-snaps brush to preset

    /// Repro of the user's reported bug: drag the navigator to a
    /// custom range, then click `12m` — the pill must IMMEDIATELY
    /// jump to the 12m preset, not stay on the dragged range.
    func testSegmentedClickRecoversFromDraggedBrush() {
        let vm = DashboardViewModel()
        vm._setAggregateForTests(makeAggregate())

        // Drag to a 90-day window centered way back in time.
        let now = Date()
        let dragLo = now.addingTimeInterval(-400 * 86_400)
        let dragHi = now.addingTimeInterval(-310 * 86_400)
        vm.brushedRange = dragLo...dragHi
        let dragged = vm.brushedRange
        XCTAssertNotNil(dragged)

        // Click 12m — brush should jump to the rightmost ~year.
        vm.window = .last12Months

        guard let brush = vm.brushedRange else {
            XCTFail("Brush should be set after 12m click.")
            return
        }
        XCTAssertNotEqual(brush, dragged,
                          "Clicking 12m must replace the dragged brush, not keep it.")
        // 12m brush spans ~365 days. Clamping to the aggregate's
        // day-resolved span can shave up to a day off either end
        // (aggregate.date(forDayIndex:) returns startOfDay), so
        // tolerate ~1 day of drift in the span.
        let days = brush.upperBound.timeIntervalSince(brush.lowerBound) / 86_400
        XCTAssertEqual(days, 365, accuracy: 3,
                       "12m click should produce a ~365-day brush.")
        // upperBound should anchor at ~now (within a day — the
        // aggregate's upper edge is `startOfDay(today)` which can be
        // up to 24 hours before `Date()`).
        XCTAssertLessThan(abs(brush.upperBound.timeIntervalSinceNow), 86_400 + 60,
                          "12m brush's upper bound should anchor at ~now (within a day).")
    }
}
