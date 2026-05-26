//
//  EmptyStateSuggestionsTests.swift
//  HourglassTests
//
//  Pin the contract the spotlight panel's empty state relies on:
//
//    - The compact row is ALWAYS 5 pills, ONE per category, in a fixed
//      order so the layout doesn't reshuffle between launches.
//    - The People slot personalizes when a top contact is supplied and
//      degrades gracefully when none is available.
//    - Whitespace in contact names is quoted so the resulting `from:`
//      token round-trips through the parser as a single value.
//    - Every suggestion has a unique id (ForEach diffing depends on this).
//    - Every suggestion includes a non-empty label, icon, and token.
//
//  These are pure-data assertions — no SwiftUI rendering, no chat.db,
//  fast as a parser test.
//

import XCTest
@testable import Hourglass

final class EmptyStateSuggestionsTests: XCTestCase {

    // MARK: - Compact-row contract (one pill per category)

    /// The compact row always has EXACTLY 5 pills — one per category. The
    /// whole point of the redesign is to fit the empty state in a single
    /// viewport without scrolling; regressing back to N pills per category
    /// is a deliberate design change and should require an explicit edit.
    func testCompactRow_alwaysHasFivePills() {
        XCTAssertEqual(EmptyStateSuggestion.compactRow().count, 5)
        XCTAssertEqual(EmptyStateSuggestion.compactRow(topContactNames: ["Mom"]).count, 5)
        XCTAssertEqual(EmptyStateSuggestion.compactRow(topContactNames: ["A", "B", "C", "D"]).count, 5)
    }

    /// The five sections appear in the documented order. The spotlight
    /// panel relies on this for the visual flow (Content → Time →
    /// Reactions → People → Combos); regressing the order is a visible
    /// design change and should require an explicit decision.
    func testCompactRow_categoriesInFixedOrder() {
        let row = EmptyStateSuggestion.compactRow()
        let order = row.map { $0.section }
        XCTAssertEqual(order, [.content, .time, .reactions, .people, .combos],
                       "Section order is part of the design contract — update intentionally")
    }

    /// `curatedSections(topContactNames:)` is the legacy section-wrapped
    /// shape — each section returns exactly one suggestion, the same as
    /// `compactRow`. Kept so legacy callers still type-check.
    func testCuratedSections_wrapsCompactRowAsOnePerSection() {
        let sections = EmptyStateSuggestion.curatedSections()
        XCTAssertEqual(sections.count, 5)
        for entry in sections {
            XCTAssertEqual(entry.suggestions.count, 1,
                           "\(entry.section.rawValue) returns one example in the compact layout")
        }
    }

    // MARK: - Per-category exemplar pills

    /// The Content slot is the Photos pill (`type:image`) — most-used
    /// attachment type in real chat.dbs by a wide margin.
    func testCompactRow_contentSlotIsPhotos() {
        let row = EmptyStateSuggestion.compactRow()
        let content = row.first(where: { $0.section == .content })
        XCTAssertEqual(content?.token, "type:image")
        XCTAssertEqual(content?.category, .type)
    }

    /// The Time slot is "Last 30 days" — most-common recent-window slice.
    func testCompactRow_timeSlotIsLast30Days() {
        let row = EmptyStateSuggestion.compactRow()
        let time = row.first(where: { $0.section == .time })
        XCTAssertEqual(time?.token, "last:30d")
        XCTAssertEqual(time?.category, .dateRange)
    }

    /// The Reactions slot is `reactions:>=3` — surfaces popular messages
    /// without forcing the user to pick a specific kind.
    func testCompactRow_reactionsSlotIsHighThreshold() {
        let row = EmptyStateSuggestion.compactRow()
        let reactions = row.first(where: { $0.section == .reactions })
        XCTAssertEqual(reactions?.token, "reactions:>=3")
        XCTAssertEqual(reactions?.category, .reaction)
    }

    /// The Combo slot chains two filters (`type:image last:7d`). This is
    /// the "show me the pattern" pill — the user sees that filters can
    /// be combined.
    func testCompactRow_comboSlotChainsTwoFilters() {
        let row = EmptyStateSuggestion.compactRow()
        let combo = row.first(where: { $0.section == .combos })
        XCTAssertNotNil(combo)
        let tokens = combo?.token.split(separator: " ").filter { $0.contains(":") }
        XCTAssertEqual(tokens?.count, 2,
                       "Combo slot should chain two filters so the user sees the composability pattern")
    }

    // MARK: - People-slot personalization

    /// No top contacts → People slot falls back to the generic `from:`
    /// prompt. The chip stays visible — the empty state should never
    /// drop a section just because the user is unindexed.
    func testCompactRow_peopleSlot_withNoTopContacts_isGeneric() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: [])
        let people = row.first(where: { $0.section == .people })
        XCTAssertEqual(people?.token, "from:")
        XCTAssertEqual(people?.label, "From a name")
    }

    /// One top contact → People slot becomes `from:Mom` and reads as
    /// "From Mom" — the "this app knows YOUR data" moment.
    func testCompactRow_peopleSlot_withOneContact_personalizes() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: ["Mom"])
        let people = row.first(where: { $0.section == .people })
        XCTAssertEqual(people?.token, "from:Mom")
        XCTAssertEqual(people?.label, "From Mom")
        XCTAssertEqual(people?.category, .person)
    }

    /// Many top contacts → People slot uses only the FIRST one (not a
    /// stack of pills). Compact layout means one personalized pill, not
    /// a leaderboard.
    func testCompactRow_peopleSlot_withManyContacts_usesFirstOnly() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: ["Mom", "Dad", "Alex"])
        let peopleCount = row.filter({ $0.section == .people }).count
        XCTAssertEqual(peopleCount, 1, "Compact layout uses one personalized pill")
        XCTAssertEqual(row.first(where: { $0.section == .people })?.label, "From Mom")
    }

    /// Multi-word names get quoted in the emitted token so the parser
    /// receives them as a single value (matches `MessageSearch.parseQuery`'s
    /// quote handling). The visible label keeps the unquoted spelling.
    func testCompactRow_peopleSlot_quotesMultiWordName() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: ["Howard Hao Hao Xu"])
        let people = row.first(where: { $0.section == .people })
        XCTAssertEqual(people?.token, "from:\"Howard Hao Hao Xu\"")
        XCTAssertEqual(people?.label, "From Howard Hao Hao Xu",
                       "The visible label keeps the unquoted spelling")
    }

    // MARK: - Identity + integrity

    /// Every suggestion id is unique across the compact row. SwiftUI
    /// `ForEach` diffing depends on this — duplicate ids cause silent
    /// rendering bugs (rows go missing, wrong rows update).
    func testCompactRow_uniqueIDs() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: ["Alice"])
        let ids = row.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count,
                       "Duplicate suggestion ids in compact row")
    }

    /// Sanity: every suggestion in the compact row has a non-empty label,
    /// icon, token. Catches future curator typos.
    func testCompactRow_allFieldsNonEmpty() {
        let row = EmptyStateSuggestion.compactRow(topContactNames: ["Alice"])
        for s in row {
            XCTAssertFalse(s.label.isEmpty, "Empty label on suggestion \(s.id)")
            XCTAssertFalse(s.icon.isEmpty, "Empty icon on suggestion \(s.id)")
            XCTAssertFalse(s.token.isEmpty, "Empty token on suggestion \(s.id)")
        }
    }

    // MARK: - Legacy compatibility

    /// `peoplePills(topContactNames:)` is the legacy helper for the OLD
    /// sectioned layout (multi-pill row per section). Still exposed
    /// because some test fixtures + the HelpSheet's people-section logic
    /// reference it. The compact layout doesn't call this; it uses
    /// `peopleExample(topContactName:)` instead.
    func testLegacyPeoplePills_stillExposed() {
        let pills = EmptyStateSuggestion.peoplePills(topContactNames: ["Mom", "Dad", "Alex"])
        // Cap at 2 dynamic + 3 static.
        XCTAssertEqual(pills.count, 5)
        XCTAssertEqual(pills.prefix(2).map(\.label), ["Mom", "Dad"])
    }

    /// The pre-existing `EmptyStateSuggestion.defaults` (the flat 6-pill
    /// list) is still available — old callers (previews, legacy tests)
    /// keep compiling.
    func testLegacyDefaults_stillContainsSixPills() {
        XCTAssertEqual(EmptyStateSuggestion.defaults.count, 6,
                       "Legacy flat defaults must keep their 6-pill shape")
    }
}
