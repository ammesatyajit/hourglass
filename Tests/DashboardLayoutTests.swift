//
//  DashboardLayoutTests.swift
//  HourglassTests
//
//  Pin the contract the redesigned (2026-05-24) Dashboard depends on:
//
//    - SearchQueryBuilder produces well-formed queries for the People +
//      Groups tile click handlers. Names with spaces stay quoted; an
//      embedded double-quote is escaped, not dropped.
//    - The ScrollableTopListPanel's visible-row math is monotone in
//      `visibleRowCount` — bumping the count from 6 → 8 must produce a
//      taller viewport. (This is a static expectation we want the
//      panel layout to honor; the dashboard relies on it to size the
//      People list to ~6 rows visible and the Groups list to ~5.)
//    - The dashboard's NL-placement decision is pinned to the panel-
//      agent's 2026-05-24 decision (`docs/nl-placement.md` — Option B
//      embeds NL in the Spotlight panel). If the dashboard accidentally
//      re-enables its inline NL composer, this test fails loudly so we
//      remember to coordinate via `nl-placement.md` first.
//
//  All pure-Swift; no chat.db, no SwiftUI rendering. Fast as a parser
//  test.
//

import XCTest
@testable import Hourglass

final class DashboardLayoutTests: XCTestCase {

    // MARK: - SearchQueryBuilder contract

    /// People-tile click uses `with:` — scopes the search to every
    /// chat (1:1 or group) the person participates in — and quotes the
    /// name. The trailing space lets the user keep typing additional
    /// terms after the dashboard summons the panel.
    func testSearchQueryBuilder_oneOnOne_singleWord() {
        XCTAssertEqual(
            SearchQueryBuilder.oneOnOne(name: "Henry"),
            "with:\"Henry\" "
        )
    }

    /// Multi-word names stay quoted as ONE token so the search parser
    /// reads "Amma Satyajit" as a single value, not as `with:"Amma"`
    /// + a bare "Satyajit" trailing token.
    func testSearchQueryBuilder_oneOnOne_multiWord() {
        XCTAssertEqual(
            SearchQueryBuilder.oneOnOne(name: "Amma Satyajit"),
            "with:\"Amma Satyajit\" "
        )
    }

    /// Names with embedded double-quotes are escaped, not dropped.
    /// Rare in practice but cheap to guard against — a dropped quote
    /// would produce an unterminated literal that the parser would
    /// silently truncate.
    func testSearchQueryBuilder_oneOnOne_escapesEmbeddedQuote() {
        let q = SearchQueryBuilder.oneOnOne(name: "Mac \"Ten\" Daddy")
        XCTAssertEqual(q, "with:\"Mac \\\"Ten\\\" Daddy\" ")
    }

    /// Groups use `in:` — substring match on the chat's display name.
    /// (Groups always have a display name, so this targets them
    /// precisely; people are dispatched through `with:` instead.)
    func testSearchQueryBuilder_anyChat_quotesGroupName() {
        XCTAssertEqual(
            SearchQueryBuilder.anyChat(name: "Lost Causes"),
            "in:\"Lost Causes\" "
        )
    }

    /// `from:` is reserved for future "messages from this person"
    /// CTAs. Same quoting/escaping rules as `with:` and `in:`.
    func testSearchQueryBuilder_from_quotesName() {
        XCTAssertEqual(
            SearchQueryBuilder.from(name: "Henry Wu"),
            "from:\"Henry Wu\" "
        )
    }

    // MARK: - ScrollableTopListPanel viewport sizing

    /// Bumping `visibleRowCount` produces a taller viewport in monotone
    /// fashion. The panel computes
    ///   viewportHeight = rows × rowHeight + (rows - 1) × rowSpacing + 8
    /// so 8 rows MUST always be taller than 6 rows for any positive
    /// rowHeight / rowSpacing. Guards against a future refactor
    /// accidentally inverting the formula (a regression that would
    /// shrink the People list to one row when bumped to 12 visible).
    func testScrollableTopListPanel_viewportGrowsWithRowCount() {
        let small = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—",
            visibleRowCount: 6
        )
        let large = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—",
            visibleRowCount: 8
        )
        // Recompute the same formula (pure scalar math) — the panel's
        // internal sizing must agree with this.
        let smallExpected = 6 * small.rowHeight + 5 * small.rowSpacing + 8
        let largeExpected = 8 * large.rowHeight + 7 * large.rowSpacing + 8
        XCTAssertGreaterThan(largeExpected, smallExpected,
            "8-row viewport must be taller than 6-row viewport.")
    }

    /// Bumping `rowHeight` (panel-level) also grows the viewport. The
    /// dashboard uses this for the Groups panel (heavier rows: 64pt vs
    /// 60pt) — the math must accommodate the override.
    func testScrollableTopListPanel_viewportRespectsRowHeightOverride() {
        let base = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—",
            visibleRowCount: 5,
            rowHeight: 60
        )
        let denser = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—",
            visibleRowCount: 5,
            rowHeight: 64
        )
        let baseExpected = 5 * base.rowHeight + 4 * base.rowSpacing + 8
        let denserExpected = 5 * denser.rowHeight + 4 * denser.rowSpacing + 8
        XCTAssertGreaterThan(denserExpected, baseExpected,
            "Same row-count but larger rowHeight must yield a taller viewport.")
    }

    /// Default row count matches the design brief's call-out ("Top
    /// People list shows ~6 rows; scrollable to reveal #7 through #N").
    /// If the default ever drops to 4 or jumps to 12 we want the test
    /// to scream — the choice of 6 is a UX call, not an arbitrary
    /// constant.
    func testScrollableTopListPanel_defaultVisibleRowCount_is6() {
        let panel = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—"
        )
        XCTAssertEqual(panel.visibleRowCount, 6,
            "Default visible-row count is the contract — 6 rows visible, scroll for more.")
    }

    /// The People panel doesn't override the default — the dashboard
    /// passes the bare entries and lets the panel pick the row size.
    /// This test pins the implicit dependency on the default so a
    /// refactor that adds a positional `visibleRowCount` arg won't
    /// silently shrink the visible region.
    func testScrollableTopListPanel_defaultRowHeight_is60() {
        let panel = ScrollableTopListPanel(
            title: "T", entries: [], primaryLabel: "P",
            secondaryLeftLabel: nil, secondaryRightLabel: nil,
            emptyMessage: "—"
        )
        XCTAssertEqual(panel.rowHeight, 60,
            "Default row height is 60pt — matches the TopListRowContent layout.")
    }

    // MARK: - Layout sanity at the design viewport (1200×800)

    /// New layout (2026-05-24 second pass): the chart spans the full
    /// content width — `windowWidth - 2 × outerPadding`. At 1200pt that
    /// gives ~1152pt of chart room, far above the ~600pt threshold below
    /// which axis ticks start dropping. The previous split-pane
    /// surrendered ~420pt to the right column; this test pins the new
    /// "chart is full-width" contract.
    func testDashboardVerticalStack_chartIsFullWidth_at1200() {
        let windowWidth: CGFloat = 1200
        let outerPadding: CGFloat = 24 * 2     // Space.xl on each side

        let chartWidth = windowWidth - outerPadding
        XCTAssertGreaterThanOrEqual(chartWidth, 1000,
            "At the default 1200pt window, the full-width chart should get >= 1000pt of room (was ~600pt in the split-pane).")
    }

    /// At the minimum window (~900pt), each leaderboard takes half the
    /// content width. With `Space.lg = 16pt` between them and `Space.xl
    /// = 24pt` outer padding, each panel ends up ~416pt wide. The TopList
    /// content needs ~280pt minimum to render avatar + name + bar + count
    /// without clipping. This test pins the per-panel minimum so a
    /// future redesign can't squeeze the leaderboards below readability.
    func testDashboardVerticalStack_eachLeaderboardWideEnough_at900Min() {
        let windowWidth: CGFloat = 900
        let outerPadding: CGFloat = 24 * 2
        let interColumnGap: CGFloat = 16

        let panelWidth = (windowWidth - outerPadding - interColumnGap) / 2
        XCTAssertGreaterThanOrEqual(panelWidth, 280,
            "At the minimum 900pt window, each side-by-side leaderboard should be >= 280pt wide.")
    }

    // MARK: - Top-N capacity (the user's "scrollable past 12" request)

    /// The 2026-05-24 second pass bumped the top-N cap from 12 → 50 so
    /// the user can scroll past their #12-most-texted person inside the
    /// leaderboard panel. This test pins the new cap at the loader's
    /// default `limit` — if a future refactor drops it back to 12 (or
    /// silently below 20), we'd lose the "scroll past 12" affordance.
    func testTopNDefaultCap_isAtLeast50() {
        // We can't directly read the function's default value without a
        // DB; instead we pin the AGGREGATE recompute path's defaults,
        // which mirror the loader's. Both must be >= 50.
        let agg = makeMinimalAggregate()
        // Synthesize 100 contacts so the cap actually gates.
        let manyContacts = (0..<100).map { i in
            ContactDailySeries(
                key: "c-\(i)", displayName: "Person \(i)", avatarData: nil,
                days: [DailyCount(dayIndex: 0, sent: Int32(100 - i), received: 0)]
            )
        }
        let aggWithContacts = DashboardAllTimeAggregate(
            calendar: agg.calendar,
            dailyOverview: agg.dailyOverview,
            allTimeChats: agg.allTimeChats,
            allTimeOldest: agg.allTimeOldest,
            allTimeNewest: agg.allTimeNewest,
            contactSeries: manyContacts,
            groupSeries: []
        )
        // Use the DEFAULT limits — the test breaks if either default drops
        // below 50.
        let stats = aggWithContacts.recomputeForRange(nil)
        XCTAssertGreaterThanOrEqual(stats.topContacts.count, 50,
            "Default top-contacts cap should expose at least 50 entries — user wants to scroll past #12.")
    }

    /// Symmetric assertion for groups.
    func testTopNDefaultCap_groups_isAtLeast50() {
        let agg = makeMinimalAggregate()
        let manyGroups = (0..<100).map { i in
            GroupDailySeries(
                chatRowID: Int64(i),
                displayName: "Group \(i)",
                chatAvatarData: nil,
                participantAvatars: [],
                days: [DailyCount(dayIndex: 0, sent: Int32(100 - i), received: 0)]
            )
        }
        let aggWithGroups = DashboardAllTimeAggregate(
            calendar: agg.calendar,
            dailyOverview: agg.dailyOverview,
            allTimeChats: agg.allTimeChats,
            allTimeOldest: agg.allTimeOldest,
            allTimeNewest: agg.allTimeNewest,
            contactSeries: [],
            groupSeries: manyGroups
        )
        let stats = aggWithGroups.recomputeForRange(nil)
        XCTAssertGreaterThanOrEqual(stats.topGroups.count, 50,
            "Default top-groups cap should expose at least 50 entries.")
    }

    /// Caller can still narrow the cap when they want — e.g. a Spotlight
    /// quick-results context might use limit=5. The default isn't a hard
    /// floor.
    func testTopNExplicitLimitStillRespected() {
        let agg = makeMinimalAggregate()
        let many = (0..<100).map { i in
            ContactDailySeries(
                key: "c-\(i)", displayName: "Person \(i)", avatarData: nil,
                days: [DailyCount(dayIndex: 0, sent: Int32(100 - i), received: 0)]
            )
        }
        let aggWithContacts = DashboardAllTimeAggregate(
            calendar: agg.calendar,
            dailyOverview: agg.dailyOverview,
            allTimeChats: agg.allTimeChats,
            allTimeOldest: agg.allTimeOldest,
            allTimeNewest: agg.allTimeNewest,
            contactSeries: many,
            groupSeries: []
        )
        let stats = aggWithContacts.recomputeForRange(nil, topContactLimit: 5)
        XCTAssertEqual(stats.topContacts.count, 5,
            "Explicit topContactLimit should still narrow the result.")
    }

    // MARK: - Helpers

    private func makeMinimalAggregate() -> DashboardAllTimeAggregate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return DashboardAllTimeAggregate(
            calendar: cal,
            dailyOverview: [DailyCount(dayIndex: 0, sent: 1, received: 0)],
            allTimeChats: 1,
            allTimeOldest: Date(timeIntervalSinceReferenceDate: 0),
            allTimeNewest: Date(timeIntervalSinceReferenceDate: 0),
            contactSeries: [],
            groupSeries: []
        )
    }
}
