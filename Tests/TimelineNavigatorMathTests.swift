//
//  TimelineNavigatorMathTests.swift
//  HourglassTests
//
//  Pure-function tests for `TimelineNavigatorMath` — the math that drives
//  the dashboard's range-navigator strip below the frequency chart.
//
//  Covers:
//    - pixel ↔ date round-trip across full + edge points
//    - clamping of out-of-range x → bounds
//    - pill-body translation preserves window width when clamped
//    - left/right handle drags resize the window correctly
//    - drag past the opposite edge swaps handle identity
//    - minimum window of N days is enforced (no collapse)
//    - keyboard arrow shifts apply correctly to either edge
//

import XCTest
@testable import Hourglass

final class TimelineNavigatorMathTests: XCTestCase {

    // MARK: - Test fixtures

    /// 365-day window starting at a known reference date — gives us
    /// easy round numbers for px-to-day conversions.
    private let oneYear: ClosedRange<Date> = {
        let lo = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        let hi = lo.addingTimeInterval(365 * 86_400)
        return lo...hi
    }()

    /// 365px-wide strip + 365-day range = 1 day per pixel. Math becomes
    /// trivial to reason about by hand.
    private let stripWidth: CGFloat = 365

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func math(width: CGFloat? = nil) -> TimelineNavigatorMath {
        TimelineNavigatorMath(
            fullRange: oneYear,
            width: width ?? stripWidth,
            calendar: calendar
        )
    }

    // MARK: - Pixel ↔ date round-trip

    func testPixelToDateAtBounds() {
        let m = math()
        XCTAssertEqual(m.date(forX: 0), oneYear.lowerBound)
        XCTAssertEqual(
            m.date(forX: stripWidth).timeIntervalSince(oneYear.upperBound),
            0,
            accuracy: 1.0,
            "Right edge should hit upper bound (within 1s of float error)."
        )
    }

    func testPixelToDateAtMidpoint() {
        let m = math()
        let midX: CGFloat = stripWidth / 2
        let midDate = m.date(forX: midX)
        let expected = oneYear.lowerBound.addingTimeInterval(365.0 / 2 * 86_400)
        XCTAssertEqual(
            midDate.timeIntervalSince(expected),
            0,
            accuracy: 1.0
        )
    }

    func testDateToPixelRoundTrip() {
        let m = math()
        // Forward then back
        for offset in stride(from: 0.0, through: 1.0, by: 0.25) {
            let x = CGFloat(offset) * stripWidth
            let d = m.date(forX: x)
            let xBack = m.x(for: d)
            XCTAssertEqual(xBack, x, accuracy: 0.5,
                           "Round trip at offset \(offset) drifted by more than 0.5pt.")
        }
    }

    func testOutOfRangeXClampsToBounds() {
        let m = math()
        XCTAssertEqual(m.date(forX: -100), oneYear.lowerBound)
        XCTAssertEqual(
            m.date(forX: stripWidth + 100).timeIntervalSince(oneYear.upperBound),
            0,
            accuracy: 1.0
        )
    }

    func testZeroWidthIsSafe() {
        let m = math(width: 0)
        XCTAssertEqual(m.date(forX: 0), oneYear.lowerBound)
        // x(for:) returns 0 when width=0 (no NaN / divide-by-zero).
        XCTAssertEqual(m.x(for: oneYear.lowerBound), 0)
    }

    // MARK: - Pill body translation

    func testTranslatedRangePreservesWidthInBounds() {
        let m = math()
        // 30-day window starting at day 100, translate by +50 pixels (=50 days).
        let start = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        let end = start.addingTimeInterval(30 * 86_400)
        let translated = m.translatedRange(
            start...end,
            by: 50,
            clampedTo: oneYear
        )
        let expectedStart = start.addingTimeInterval(50 * 86_400)
        let expectedEnd = end.addingTimeInterval(50 * 86_400)
        XCTAssertEqual(
            translated.lowerBound.timeIntervalSince(expectedStart),
            0,
            accuracy: 1.0
        )
        XCTAssertEqual(
            translated.upperBound.timeIntervalSince(expectedEnd),
            0,
            accuracy: 1.0
        )
    }

    func testTranslatedRangeClampsLeftEdge() {
        let m = math()
        // Start near the beginning: 5-day window starting day 5.
        let start = oneYear.lowerBound.addingTimeInterval(5 * 86_400)
        let end = start.addingTimeInterval(7 * 86_400)
        // Drag 20px (=20 days) LEFT. Should pin to oneYear.lowerBound and
        // keep the original 7-day width.
        let translated = m.translatedRange(
            start...end,
            by: -20,
            clampedTo: oneYear
        )
        XCTAssertEqual(translated.lowerBound, oneYear.lowerBound)
        let width = translated.upperBound.timeIntervalSince(translated.lowerBound)
        XCTAssertEqual(width, 7 * 86_400, accuracy: 1.0)
    }

    func testTranslatedRangeClampsRightEdge() {
        let m = math()
        // Start near the end: 7-day window ending at day 360.
        let start = oneYear.lowerBound.addingTimeInterval(353 * 86_400)
        let end = start.addingTimeInterval(7 * 86_400)
        let translated = m.translatedRange(
            start...end,
            by: 100,
            clampedTo: oneYear
        )
        XCTAssertEqual(
            translated.upperBound.timeIntervalSince(oneYear.upperBound),
            0,
            accuracy: 1.0
        )
        // The window should keep its width (clamps to the right edge).
        let width = translated.upperBound.timeIntervalSince(translated.lowerBound)
        XCTAssertEqual(width, 7 * 86_400, accuracy: 1.0)
    }

    // MARK: - Handle drag (resize without swap)

    func testLeftHandleDragShrinksWindow() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(150 * 86_400)
        // Move the LEFT handle right by 30 days (window becomes 70 days).
        let target = oneYear.lowerBound.addingTimeInterval(80 * 86_400)
        let result = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        XCTAssertEqual(result.activeTarget, .leftHandle)
        XCTAssertEqual(result.newRange.lowerBound, target)
        XCTAssertEqual(result.newRange.upperBound, end)
    }

    func testRightHandleDragGrowsWindow() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(150 * 86_400)
        // Move the RIGHT handle right by 50 days (window becomes 150 days).
        let target = oneYear.lowerBound.addingTimeInterval(200 * 86_400)
        let result = m.applyHandleDrag(
            target: .rightHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        XCTAssertEqual(result.newRange.lowerBound, start)
        XCTAssertEqual(result.newRange.upperBound, target)
    }

    // MARK: - Minimum window enforcement

    func testLeftHandleDragSnapsToMinWindow() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(57 * 86_400)
        // Try to crush LEFT into the right edge — should snap to upper - 7d.
        let crushAttempt = oneYear.lowerBound.addingTimeInterval(56 * 86_400)
        let result = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: crushAttempt,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        // Window should be exactly 7 days.
        let width = result.newRange.upperBound.timeIntervalSince(result.newRange.lowerBound)
        XCTAssertEqual(width, 7 * 86_400, accuracy: 1.0)
    }

    func testRightHandleDragSnapsToMinWindow() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(57 * 86_400)
        // Try to crush RIGHT into the left edge.
        let crushAttempt = oneYear.lowerBound.addingTimeInterval(51 * 86_400)
        let result = m.applyHandleDrag(
            target: .rightHandle,
            startRange: start...end,
            toDate: crushAttempt,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        let width = result.newRange.upperBound.timeIntervalSince(result.newRange.lowerBound)
        XCTAssertEqual(width, 7 * 86_400, accuracy: 1.0)
    }

    // MARK: - Swap (cross-over)

    func testLeftHandleCrossingRightEdgeSwaps() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Drag LEFT handle past the right edge — should swap.
        let target = oneYear.lowerBound.addingTimeInterval(150 * 86_400)
        let result = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertTrue(result.swapped)
        XCTAssertEqual(result.activeTarget, .rightHandle)
        // New range: lower = old upper, upper = drag target.
        XCTAssertEqual(result.newRange.lowerBound, end)
        XCTAssertEqual(result.newRange.upperBound, target)
    }

    func testRightHandleCrossingLeftEdgeSwaps() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Drag RIGHT handle past the left edge.
        let target = oneYear.lowerBound.addingTimeInterval(20 * 86_400)
        let result = m.applyHandleDrag(
            target: .rightHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertTrue(result.swapped)
        XCTAssertEqual(result.activeTarget, .leftHandle)
        XCTAssertEqual(result.newRange.lowerBound, target)
        XCTAssertEqual(result.newRange.upperBound, start)
    }

    /// Regression: after a swap, the view rebases its `startRange` to
    /// the post-swap range and continues dragging the new active handle.
    /// This test simulates that two-tick sequence and verifies that the
    /// second tick produces the expected post-swap behavior.
    ///
    /// Bug it pins (2026-05-26): pre-fix, the view's `dragContext.startRange`
    /// stayed at the pre-swap value, so a left handle dragged from day 50
    /// past day 100 and on to day 150 produced [50, 150] on tick 2 instead
    /// of the correct [100, 150] — the window expanded back to include the
    /// original lower bound rather than staying on the swapped track.
    func testDragContinuesCorrectlyAfterSwap_leftToRight() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Tick 1: LEFT handle dragged past RIGHT to day 120 → swap.
        let firstTarget = oneYear.lowerBound.addingTimeInterval(120 * 86_400)
        let firstResult = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: firstTarget,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertTrue(firstResult.swapped)
        XCTAssertEqual(firstResult.activeTarget, .rightHandle)
        XCTAssertEqual(firstResult.newRange.lowerBound, end)
        XCTAssertEqual(firstResult.newRange.upperBound, firstTarget)

        // Tick 2: continue dragging right to day 150. The view rebases
        // startRange to firstResult.newRange = [100, 120] and target to
        // .rightHandle. We expect [100, 150], NOT [50, 150].
        let secondTarget = oneYear.lowerBound.addingTimeInterval(150 * 86_400)
        let secondResult = m.applyHandleDrag(
            target: firstResult.activeTarget,
            startRange: firstResult.newRange,
            toDate: secondTarget,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(secondResult.swapped)
        XCTAssertEqual(secondResult.activeTarget, .rightHandle)
        XCTAssertEqual(
            secondResult.newRange.lowerBound, end,
            "Lower bound should stay at the post-swap left edge (day 100), NOT revert to the pre-swap left edge (day 50)."
        )
        XCTAssertEqual(secondResult.newRange.upperBound, secondTarget)
    }

    /// Mirror of the left→right swap regression, but for a right handle
    /// dragged past the left edge and then continued further left.
    func testDragContinuesCorrectlyAfterSwap_rightToLeft() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(150 * 86_400)
        // Tick 1: RIGHT handle dragged past LEFT to day 80 → swap.
        let firstTarget = oneYear.lowerBound.addingTimeInterval(80 * 86_400)
        let firstResult = m.applyHandleDrag(
            target: .rightHandle,
            startRange: start...end,
            toDate: firstTarget,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertTrue(firstResult.swapped)
        XCTAssertEqual(firstResult.activeTarget, .leftHandle)
        XCTAssertEqual(firstResult.newRange.lowerBound, firstTarget)
        XCTAssertEqual(firstResult.newRange.upperBound, start)

        // Tick 2: continue dragging left to day 60. Expect [60, 100], NOT
        // [60, 150].
        let secondTarget = oneYear.lowerBound.addingTimeInterval(60 * 86_400)
        let secondResult = m.applyHandleDrag(
            target: firstResult.activeTarget,
            startRange: firstResult.newRange,
            toDate: secondTarget,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(secondResult.swapped)
        XCTAssertEqual(secondResult.activeTarget, .leftHandle)
        XCTAssertEqual(secondResult.newRange.lowerBound, secondTarget)
        XCTAssertEqual(
            secondResult.newRange.upperBound, start,
            "Upper bound should stay at the post-swap right edge (day 100), NOT revert to the pre-swap right edge (day 150)."
        )
    }

    /// When swapping but the resulting window is below minWindow, the
    /// dragged edge should extend past the cursor to maintain at least
    /// minWindow days.
    func testSwapEnforcesMinWindow() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Drag LEFT just one day past RIGHT — swap, but the new window
        // (1 day) is below the 7d minimum. The right edge should extend
        // to compensate.
        let justBeyond = oneYear.lowerBound.addingTimeInterval(101 * 86_400)
        let result = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: justBeyond,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertTrue(result.swapped)
        let width = result.newRange.upperBound.timeIntervalSince(result.newRange.lowerBound)
        XCTAssertGreaterThanOrEqual(width, 7 * 86_400 - 1)
    }

    // MARK: - Clamping to full range

    func testLeftHandleClampsToFullRangeLower() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Drag LEFT handle to BEFORE the full range start.
        let target = oneYear.lowerBound.addingTimeInterval(-30 * 86_400)
        let result = m.applyHandleDrag(
            target: .leftHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        XCTAssertEqual(result.newRange.lowerBound, oneYear.lowerBound)
        XCTAssertEqual(result.newRange.upperBound, end)
    }

    func testRightHandleClampsToFullRangeUpper() {
        let m = math()
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        // Drag RIGHT handle past the full range end.
        let target = oneYear.upperBound.addingTimeInterval(50 * 86_400)
        let result = m.applyHandleDrag(
            target: .rightHandle,
            startRange: start...end,
            toDate: target,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertFalse(result.swapped)
        XCTAssertEqual(result.newRange.lowerBound, start)
        XCTAssertEqual(result.newRange.upperBound, oneYear.upperBound)
    }

    // MARK: - Keyboard shift

    func testShiftedRangeMovesRightEdge() {
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        let shifted = TimelineNavigatorMath.shiftedRange(
            start...end,
            edge: .rightHandle,
            byDays: 3,
            calendar: calendar,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertNotNil(shifted)
        XCTAssertEqual(shifted!.lowerBound, start)
        let expectedEnd = end.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(
            shifted!.upperBound.timeIntervalSince(expectedEnd),
            0,
            accuracy: 1.0
        )
    }

    func testShiftedRangeMovesLeftEdge() {
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(100 * 86_400)
        let shifted = TimelineNavigatorMath.shiftedRange(
            start...end,
            edge: .leftHandle,
            byDays: -7,
            calendar: calendar,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertNotNil(shifted)
        let expectedStart = start.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(
            shifted!.lowerBound.timeIntervalSince(expectedStart),
            0,
            accuracy: 1.0
        )
        XCTAssertEqual(shifted!.upperBound, end)
    }

    func testShiftedRangeEnforcesMinWindowOnRightShrink() {
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(60 * 86_400) // 10-day window
        // Pull RIGHT in by 5 — would yield a 5-day window. Should clamp
        // to start + 7d.
        let shifted = TimelineNavigatorMath.shiftedRange(
            start...end,
            edge: .rightHandle,
            byDays: -5,
            calendar: calendar,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertNotNil(shifted)
        let width = shifted!.upperBound.timeIntervalSince(shifted!.lowerBound)
        XCTAssertEqual(width, 7 * 86_400, accuracy: 1.0)
    }

    func testShiftedRangeClampsToFullRange() {
        let start = oneYear.lowerBound.addingTimeInterval(5 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        // Pull LEFT before the full range.
        let shifted = TimelineNavigatorMath.shiftedRange(
            start...end,
            edge: .leftHandle,
            byDays: -100,
            calendar: calendar,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertNotNil(shifted)
        XCTAssertEqual(shifted!.lowerBound, oneYear.lowerBound)
    }

    func testShiftedRangeTranslatesPillBody() {
        let start = oneYear.lowerBound.addingTimeInterval(50 * 86_400)
        let end = oneYear.lowerBound.addingTimeInterval(80 * 86_400)
        let shifted = TimelineNavigatorMath.shiftedRange(
            start...end,
            edge: .pillBody,
            byDays: 5,
            calendar: calendar,
            fullRange: oneYear,
            minWindowDays: 7
        )
        XCTAssertNotNil(shifted)
        let width = shifted!.upperBound.timeIntervalSince(shifted!.lowerBound)
        XCTAssertEqual(width, 30 * 86_400, accuracy: 1.0, "Body translate keeps width")
        // Both edges moved by 5 days.
        XCTAssertEqual(
            shifted!.lowerBound.timeIntervalSince(start),
            5 * 86_400,
            accuracy: 1.0
        )
    }
}
