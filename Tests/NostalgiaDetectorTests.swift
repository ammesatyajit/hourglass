//
//  NostalgiaDetectorTests.swift
//  HourglassTests
//
//  Unit tests for the PURE Nostalgia & Milestones detectors — no chat.db, no
//  UI. Synthetic `ContactDailySeries` / `MemoryMessage` fixtures exercise:
//    - DormancyDetector: surfaces real dormant friendships, rejects active
//      contacts, low-volume acquaintances, recent contacts, AND short intense
//      bursts (the anti-romantic-shape guardrail).
//    - MilestoneDetector: first message, count crossings, ramp-up step-change,
//      yearly anniversaries.
//    - OnThisDayMatcher: anniversary-window dates + history-span clamping +
//      leap-year behavior.
//    - Beloved + OnThisDay ranking: warmth scoring + interest ordering.
//    - NostalgiaDismissals: persistence + filtering (isolated UserDefaults).
//

import XCTest
@testable import Hourglass

final class NostalgiaDetectorTests: XCTestCase {

    // A fixed, timezone-stable calendar so day-index math is reproducible on
    // any CI machine (mirrors the pattern in DashboardAllTimeAggregateTests).
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    /// Reference "now": 2026-06-02 12:00 PT. All fixtures are relative to this.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 12))!
    }

    // MARK: - Fixture helpers

    /// Day index in the SAME local-calendar scheme the detectors use.
    private func dayIndex(_ date: Date) -> Int32 {
        DormancyDetector.dayIndex(for: date, calendar: calendar)
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// Build a contact series from explicit (date, sent, received) triples.
    private func series(
        key: String,
        name: String? = nil,
        days: [(Date, Int, Int)]
    ) -> ContactDailySeries {
        let counts = days
            .map { DailyCount(dayIndex: dayIndex($0.0), sent: Int32($0.1), received: Int32($0.2)) }
            .sorted { $0.dayIndex < $1.dayIndex }
        return ContactDailySeries(key: key, displayName: name ?? key, avatarData: nil, days: counts)
    }

    /// A daily series spanning [start, start+spanDays) with `perDay` messages
    /// on each of `activeDays` evenly-spread days. Useful for shaping
    /// "friendship" vs "burst".
    private func spread(
        key: String,
        start: Date,
        spanDays: Int,
        activeDays: Int,
        perDay: Int
    ) -> ContactDailySeries {
        var triples: [(Date, Int, Int)] = []
        let step = max(1, spanDays / max(activeDays, 1))
        for i in 0..<activeDays {
            let offset = min(i * step, spanDays - 1)
            let d = calendar.date(byAdding: .day, value: offset, to: start)!
            // Split perDay across sent/received.
            triples.append((d, perDay - perDay / 2, perDay / 2))
        }
        return series(key: key, days: triples)
    }

    // MARK: - DormancyDetector — positive case

    func testDormancy_surfacesRealDormantFriend() {
        // High volume, broad days, long span, ALL historical (>90d ago), no
        // recent contact: a textbook dormant friendship.
        let start = date(year: 2022, month: 1, day: 1)   // 4+ years ago
        let friend = spread(key: "Old Friend", start: start, spanDays: 400, activeDays: 80, perDay: 6)
        let result = DormancyDetector.detect(series: [friend], now: now, calendar: calendar)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.key, "Old Friend")
        XCTAssertGreaterThan(result.first?.historicalTotal ?? 0, 120)
        XCTAssertEqual(result.first?.recentTotal, 0)
        XCTAssertGreaterThan(result.first?.daysSinceLastContact ?? 0, 45)
    }

    // MARK: - DormancyDetector — negative cases

    func testDormancy_rejectsStillActiveContact() {
        // Lots of history AND lots in the last 90 days → you still talk.
        let start = date(year: 2022, month: 1, day: 1)
        var triples: [(Date, Int, Int)] = []
        for i in 0..<80 {
            let d = calendar.date(byAdding: .day, value: i * 5, to: start)!
            triples.append((d, 3, 3))
        }
        // Recent activity inside the 90-day window.
        for i in 1...10 {
            let d = calendar.date(byAdding: .day, value: -i * 3, to: now)!
            triples.append((d, 2, 2))
        }
        let active = series(key: "Active Pal", days: triples)
        let result = DormancyDetector.detect(series: [active], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "A contact you still text should not be dormant")
    }

    func testDormancy_rejectsLowVolumeAcquaintance() {
        // Old, quiet, but never really texted (below minHistoricalMessages).
        let start = date(year: 2022, month: 1, day: 1)
        let acq = spread(key: "Acquaintance", start: start, spanDays: 300, activeDays: 8, perDay: 2)
        let result = DormancyDetector.detect(series: [acq], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "Low-volume acquaintance should not surface")
    }

    func testDormancy_rejectsShortIntenseBurst() {
        // The anti-romantic guardrail: high volume packed into a SHORT span
        // with few distinct days → looks like a fling/burst, must NOT surface.
        // 200+ messages but only over ~20 days and ~12 active days.
        let start = date(year: 2024, month: 1, day: 1)
        let burst = spread(key: "Brief Spark", start: start, spanDays: 20, activeDays: 12, perDay: 25)
        XCTAssertGreaterThan(
            burst.days.reduce(0) { $0 + Int($1.sent) + Int($1.received) },
            120,
            "fixture should clear the volume bar so the span/breadth gate is what rejects it"
        )
        let result = DormancyDetector.detect(series: [burst], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "Short intense burst must be filtered (sensitivity guardrail)")
    }

    func testDormancy_rejectsRecentlyContacted() {
        // Strong history, but messaged 10 days ago → not dormant.
        let start = date(year: 2022, month: 1, day: 1)
        var triples = spread(key: "Recent", start: start, spanDays: 400, activeDays: 80, perDay: 6).days
            .map { (DormancyDetector.dateFor(dayIndex: $0.dayIndex, calendar: calendar), Int($0.sent), Int($0.received)) }
        triples.append((calendar.date(byAdding: .day, value: -10, to: now)!, 1, 0))
        let s = series(key: "Recent", days: triples)
        let result = DormancyDetector.detect(series: [s], now: now, calendar: calendar)
        XCTAssertTrue(result.isEmpty, "Contacted 10 days ago is not dormant")
    }

    func testDormancy_emptySeriesProducesNothing() {
        let empty = ContactDailySeries(key: "Ghost", displayName: "Ghost", avatarData: nil, days: [])
        XCTAssertTrue(DormancyDetector.detect(series: [empty], now: now, calendar: calendar).isEmpty)
    }

    func testDormancy_respectsMaxResultsAndOrdering() {
        // Two dormant friends with different historical volume → higher volume
        // ranks first; maxResults caps the list.
        let start = date(year: 2022, month: 1, day: 1)
        let big = spread(key: "Big", start: start, spanDays: 400, activeDays: 90, perDay: 8)
        let small = spread(key: "Small", start: start, spanDays: 400, activeDays: 40, perDay: 4)
        var cfg = DormancyDetector.Config()
        cfg.maxResults = 1
        let result = DormancyDetector.detect(series: [small, big], now: now, calendar: calendar, config: cfg)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.key, "Big", "higher-volume dormant friend should rank first")
    }

    // MARK: - MilestoneDetector

    func testMilestone_firstMessageDate() {
        let s = series(key: "Pat", days: [
            (date(year: 2023, month: 3, day: 15), 2, 1),
            (date(year: 2023, month: 4, day: 1), 1, 1),
        ])
        let cm = MilestoneDetector.detect(series: s, now: now, calendar: calendar)
        XCTAssertNotNil(cm)
        let first = cm?.milestones.first
        XCTAssertEqual(first?.kind, .firstMessage)
        XCTAssertEqual(calendar.component(.year, from: first!.date), 2023)
        XCTAssertEqual(calendar.component(.month, from: first!.date), 3)
        XCTAssertEqual(calendar.component(.day, from: first!.date), 15)
    }

    func testMilestone_messageCountCrossing() {
        // 30 days × 40 msgs = 1200 total → crosses the 1,000 milestone on the
        // 25th active day (25 × 40 = 1000).
        let start = date(year: 2024, month: 1, day: 1)
        var triples: [(Date, Int, Int)] = []
        for i in 0..<30 {
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            triples.append((d, 20, 20))
        }
        let s = series(key: "Chatty", days: triples)
        let cm = MilestoneDetector.detect(series: s, now: now, calendar: calendar)
        let counts = cm!.milestones.filter {
            if case .messageCount = $0.kind { return true }; return false
        }
        XCTAssertTrue(counts.contains { $0.kind == .messageCount(1_000) })
        // The 1,000 crossing should land on day index 24 (0-based 25th day).
        let crossing = counts.first { $0.kind == .messageCount(1_000) }!
        let expectedDay = calendar.date(byAdding: .day, value: 24, to: start)!
        XCTAssertEqual(calendar.startOfDay(for: crossing.date), calendar.startOfDay(for: expectedDay))
    }

    func testMilestone_rampUpDetectedOnStepChange() {
        // 40 quiet days (1/day) then 40 busy days (10/day) — a clean step-up.
        let start = date(year: 2024, month: 1, day: 1)
        var triples: [(Date, Int, Int)] = []
        for i in 0..<40 {
            triples.append((calendar.date(byAdding: .day, value: i, to: start)!, 1, 0))
        }
        for i in 40..<80 {
            triples.append((calendar.date(byAdding: .day, value: i, to: start)!, 5, 5))
        }
        let s = series(key: "Ramped", days: triples)
        let cm = MilestoneDetector.detect(series: s, now: now, calendar: calendar)
        let ramp = cm?.milestones.first { $0.kind == .rampUp }
        XCTAssertNotNil(ramp, "a clear quiet→busy step-change should produce a rampUp milestone")
        // The boundary should be near day 40.
        if let ramp {
            let rampDay = calendar.dateComponents([.day], from: start, to: ramp.date).day ?? -1
            XCTAssertTrue((35...45).contains(rampDay), "ramp boundary should be near the step (got day \(rampDay))")
        }
    }

    func testMilestone_noRampUpOnFlatVolume() {
        // Constant volume → no step-change.
        let start = date(year: 2024, month: 1, day: 1)
        var triples: [(Date, Int, Int)] = []
        for i in 0..<80 {
            triples.append((calendar.date(byAdding: .day, value: i, to: start)!, 4, 4))
        }
        let s = series(key: "Flat", days: triples)
        let cm = MilestoneDetector.detect(series: s, now: now, calendar: calendar)
        XCTAssertNil(cm?.milestones.first { $0.kind == .rampUp }, "flat volume should not ramp")
    }

    func testMilestone_anniversaries() {
        // First message 3+ years before now → anniversaries for years 1,2,3.
        let s = series(key: "Long", days: [
            (date(year: 2022, month: 5, day: 10), 5, 5),
            (date(year: 2026, month: 1, day: 1), 1, 1),
        ])
        let cm = MilestoneDetector.detect(series: s, now: now, calendar: calendar)
        let annivs = cm!.milestones.compactMap { m -> Int? in
            if case .anniversary(let y) = m.kind { return y }; return nil
        }
        // now = 2026-06-02, first = 2022-05-10 → 4 full years elapsed; default
        // maxAnniversaries = 3 → years 2,3,4.
        XCTAssertEqual(Set(annivs), Set([2, 3, 4]))
    }

    func testMilestone_emptySeriesReturnsNil() {
        let s = ContactDailySeries(key: "None", displayName: "None", avatarData: nil, days: [])
        XCTAssertNil(MilestoneDetector.detect(series: s, now: now, calendar: calendar))
    }

    // MARK: - OnThisDayMatcher

    func testOnThisDay_windowsForFullHistory() {
        // History spans 2019→now, so all default spans (6mo,1y,2y,3y) qualify.
        let oldest = date(year: 2019, month: 1, day: 1)
        let windows = OnThisDayMatcher.windows(
            now: now, calendar: calendar, historyOldest: oldest, historyNewest: now
        )
        XCTAssertEqual(windows.count, 4)
        // Closest-first ordering: 6 months, then 1/2/3 years.
        XCTAssertEqual(windows.first?.span, .monthsAgo(6))
        XCTAssertEqual(windows.last?.span, .yearsAgo(3))
        // The 1-year window must land on the same month/day as now.
        let oneYear = windows.first { $0.span == .yearsAgo(1) }!
        XCTAssertEqual(calendar.component(.year, from: oneYear.dayStart), 2025)
        XCTAssertEqual(calendar.component(.month, from: oneYear.dayStart), 6)
        XCTAssertEqual(calendar.component(.day, from: oneYear.dayStart), 2)
        // Each window is exactly one day long.
        XCTAssertEqual(
            calendar.dateComponents([.day], from: oneYear.dayStart, to: oneYear.dayEnd).day, 1
        )
    }

    func testOnThisDay_clampsToYoungHistory() {
        // History only 8 months old → the 6-months window qualifies, but the
        // 1/2/3-year windows predate the history and must be dropped.
        let oldest = calendar.date(byAdding: .month, value: -8, to: now)!
        let windows = OnThisDayMatcher.windows(
            now: now, calendar: calendar, historyOldest: oldest, historyNewest: now
        )
        XCTAssertEqual(windows.map(\.span), [.monthsAgo(6)])
    }

    func testOnThisDay_dayStartArithmeticUsesCalendarNotFixed365() {
        // 2 years before 2026-06-02 is exactly 2024-06-02 (calendar add), not
        // a 730-day subtraction that would drift across leap years.
        let start = OnThisDayMatcher.anniversaryDayStart(span: .yearsAgo(2), now: now, calendar: calendar)!
        XCTAssertEqual(calendar.component(.year, from: start), 2024)
        XCTAssertEqual(calendar.component(.month, from: start), 6)
        XCTAssertEqual(calendar.component(.day, from: start), 2)
    }

    func testOnThisDay_leapDayClampsGracefully() {
        // now = Feb 29 2024 (leap). 1 year ago is Feb 2023 (non-leap) → Calendar
        // clamps to Feb 28. We just assert it resolves to a real Feb date and
        // doesn't crash / land in March.
        let leapNow = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 12))!
        let start = OnThisDayMatcher.anniversaryDayStart(span: .yearsAgo(1), now: leapNow, calendar: calendar)!
        XCTAssertEqual(calendar.component(.year, from: start), 2023)
        XCTAssertEqual(calendar.component(.month, from: start), 2)
        XCTAssertEqual(calendar.component(.day, from: start), 28)
    }

    // MARK: - Beloved ranking (pure)

    func testBeloved_warmthScoreWeightsLovesOverLikes() {
        let loves = makeReactions(.love, .love, .love)
        let likes = makeReactions(.like, .like, .like)
        XCTAssertGreaterThan(
            BelovedMessagesLoader.score(loves),
            BelovedMessagesLoader.score(likes),
            "three loves should outweigh three likes"
        )
    }

    func testBeloved_rankDropsZeroReactionMessagesAndCaps() {
        let m1 = memory(id: 1, body: "loved one", reactions: makeReactions(.love, .love))
        let m2 = memory(id: 2, body: "no reactions", reactions: [])
        let m3 = memory(id: 3, body: "one like", reactions: makeReactions(.like))
        let ranked = BelovedMessagesLoader.rank([m1, m2, m3], maxResults: 5)
        XCTAssertEqual(ranked.map(\.message.rowID), [1, 3], "zero-reaction message dropped, loves rank first")
        let capped = BelovedMessagesLoader.rank([m1, m3], maxResults: 1)
        XCTAssertEqual(capped.count, 1)
        XCTAssertEqual(capped.first?.message.rowID, 1)
    }

    // MARK: - OnThisDay ranking (pure)

    func testOnThisDay_interestRewardsReactionsAndLength() {
        let reacted = memory(id: 1, body: "hi", reactions: makeReactions(.love))
        let longish = memory(id: 2, body: String(repeating: "word ", count: 20), reactions: [])
        let tiny = memory(id: 3, body: "k", reactions: [])
        XCTAssertGreaterThan(OnThisDayLoader.interest(reacted), OnThisDayLoader.interest(tiny))
        XCTAssertGreaterThan(OnThisDayLoader.interest(longish), OnThisDayLoader.interest(tiny))
    }

    func testOnThisDay_rankReturnsChronologicalSurvivors() {
        // Three substantive messages at different times; perDay=2 keeps the two
        // most interesting, then re-sorts them chronologically.
        let early = memory(id: 1, body: "early but loved", date: date(year: 2025, month: 6, day: 2), reactions: makeReactions(.love, .love))
        let mid = memory(id: 2, body: "midday meh", date: addHours(2, to: date(year: 2025, month: 6, day: 2)), reactions: [])
        let late = memory(id: 3, body: "late and loved a lot", date: addHours(5, to: date(year: 2025, month: 6, day: 2)), reactions: makeReactions(.love, .laugh, .love))
        let ranked = OnThisDayLoader.rank([late, early, mid], perDay: 2)
        // Survivors are the two reacted ones; output chronological → early then late.
        XCTAssertEqual(ranked.map(\.rowID), [1, 3])
    }

    func testOnThisDay_rankFallsBackWhenAllEmpty() {
        // If every message is empty-bodied & unreacted, we don't return [] —
        // we still show something rather than a blank card.
        let a = memory(id: 1, body: "", reactions: [])
        let b = memory(id: 2, body: "   ", reactions: [])
        let ranked = OnThisDayLoader.rank([a, b], perDay: 4)
        XCTAssertEqual(ranked.count, 2)
    }

    // MARK: - Dismissals (isolated UserDefaults)

    func testDismissals_persistAndFilter() {
        let suite = "test.nostalgia.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NostalgiaDismissals(defaults: defaults)

        let alice = dormant(key: "Alice")
        let bob = dormant(key: "Bob")
        XCTAssertEqual(store.filter([alice, bob]).count, 2)

        store.dismiss("Alice")
        XCTAssertTrue(store.isDismissed("Alice"))
        XCTAssertEqual(store.filter([alice, bob]).map(\.key), ["Bob"])

        // Persists across a fresh store on the same suite.
        let store2 = NostalgiaDismissals(defaults: defaults)
        XCTAssertTrue(store2.isDismissed("Alice"))

        store2.reset()
        XCTAssertFalse(store2.isDismissed("Alice"))
        XCTAssertEqual(store2.filter([alice, bob]).count, 2)
    }

    // MARK: - NostalgiaFormat

    func testCompactNumberFormatting() {
        XCTAssertEqual(NostalgiaFormat.compact(999), "999")
        XCTAssertEqual(NostalgiaFormat.compact(1_000), "1k")
        XCTAssertEqual(NostalgiaFormat.compact(5_000), "5k")
        XCTAssertEqual(NostalgiaFormat.compact(12_500), "12.5k")
        XCTAssertEqual(NostalgiaFormat.compact(1_000_000), "1M")
    }

    // MARK: - MilestonesBuilder

    func testMilestonesBuilder_filtersLowVolumeAndRanks() {
        let start = date(year: 2023, month: 1, day: 1)
        let big = spread(key: "Big", start: start, spanDays: 200, activeDays: 60, perDay: 8)     // ~480
        let small = spread(key: "Small", start: start, spanDays: 50, activeDays: 5, perDay: 2)   // ~10, below min
        let built = MilestonesBuilder.build(series: [small, big], now: now, calendar: calendar)
        XCTAssertEqual(built.map(\.key), ["Big"], "low-volume contact filtered; big one kept")
    }

    // MARK: - StreakDetector (pure)

    func testStreak_findsLongestConsecutiveRun() {
        // 5-day run, gap, 3-day run → longest is 5.
        let s = date(year: 2024, month: 3, day: 1)
        var triples: [(Date, Int, Int)] = []
        for i in 0..<5 { triples.append((calendar.date(byAdding: .day, value: i, to: s)!, 1, 1)) }
        for i in 8..<11 { triples.append((calendar.date(byAdding: .day, value: i, to: s)!, 1, 1)) }
        let series = series(key: "Run", days: triples)
        let streaks = StreakDetector.detect(series: [series], calendar: calendar)
        XCTAssertEqual(streaks.count, 1)
        XCTAssertEqual(streaks.first?.length, 5)
        XCTAssertEqual(calendar.component(.day, from: streaks.first!.startDate), 1)
        XCTAssertEqual(calendar.component(.day, from: streaks.first!.endDate), 5)
    }

    func testStreak_dropsBelowMinLengthAndSortsTopFirst() {
        let s = date(year: 2024, month: 1, day: 1)
        // Contact A: 10-day run. Contact B: 2-day run (below default min 3).
        var a: [(Date, Int, Int)] = []
        for i in 0..<10 { a.append((calendar.date(byAdding: .day, value: i, to: s)!, 1, 0)) }
        let b: [(Date, Int, Int)] = [(s, 1, 0), (calendar.date(byAdding: .day, value: 1, to: s)!, 1, 0)]
        let streaks = StreakDetector.detect(
            series: [series(key: "A", days: a), series(key: "B", days: b)],
            calendar: calendar
        )
        XCTAssertEqual(streaks.map(\.key), ["A"], "2-day run dropped; only A surfaces")
    }

    // MARK: - EraDetector (pure)

    func testEra_picksTopContactPerQuarter() {
        // Q1 2024: Alice 50 vs Bob 10 → Alice. Q2 2024: Bob 40 vs Alice 5 → Bob.
        let q1 = date(year: 2024, month: 2, day: 1)
        let q2 = date(year: 2024, month: 5, day: 1)
        let alice = series(key: "Alice", days: [(q1, 30, 20), (q2, 3, 2)])
        let bob = series(key: "Bob", days: [(q1, 5, 5), (q2, 20, 20)])
        let eras = EraDetector.detect(series: [alice, bob], calendar: calendar)
        // Most recent first → Q2 then Q1.
        XCTAssertEqual(eras.map(\.topContactName), ["Bob", "Alice"])
        XCTAssertEqual(eras.first?.seasonLabel, "Spring 2024")
        XCTAssertEqual(eras.last?.seasonLabel, "Winter 2024")
    }

    func testEra_dropsQuartersBelowFloor() {
        // A quarter whose winner has < 30 messages is dropped.
        let q = date(year: 2023, month: 8, day: 1)   // Q3
        let sparse = series(key: "Sparse", days: [(q, 5, 5)])  // 10 < 30
        let eras = EraDetector.detect(series: [sparse], calendar: calendar)
        XCTAssertTrue(eras.isEmpty)
    }

    // MARK: - FunnyMomentsLoader windowing (pure)

    private func reacted(
        rowID: Int64, chatID: Int64, minutesFromBase: Int, amused: Int,
        body: String = "lol", isGroup: Bool = true
    ) -> FunnyMomentsLoader.ReactedMessage {
        FunnyMomentsLoader.ReactedMessage(
            rowID: rowID, chatID: chatID,
            date: calendar.date(byAdding: .minute, value: minutesFromBase, to: now)!,
            amusedCount: amused, body: body, isFromMe: false, senderHandle: "+15550000",
            chatStyle: isGroup ? 43 : 45, chatDisplayName: isGroup ? "Group" : nil, chatGUID: "cg"
        )
    }

    func testFunny_groupsWindowAndPicksTrigger() {
        // Three messages within 10 min in one chat → one window; trigger = the
        // 5-amused one; total = 2+5+1 = 8.
        let msgs = [
            reacted(rowID: 1, chatID: 100, minutesFromBase: 0, amused: 2),
            reacted(rowID: 2, chatID: 100, minutesFromBase: 5, amused: 5, body: "the funny one"),
            reacted(rowID: 3, chatID: 100, minutesFromBase: 10, amused: 1),
        ]
        let windows = FunnyMomentsLoader.windows(from: msgs, config: .init())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.totalAmused, 8)
        XCTAssertEqual(windows.first?.trigger.rowID, 2)
    }

    func testFunny_splitsAcrossTimeGapAndExcludesCoordination() {
        // Two clusters >30 min apart → two windows. A coordination message is
        // dropped before windowing even with a high amused count.
        var cfg = FunnyMomentsLoader.Config()
        cfg.minAmusedReactions = 3
        let msgs = [
            reacted(rowID: 1, chatID: 7, minutesFromBase: 0, amused: 4),
            reacted(rowID: 2, chatID: 7, minutesFromBase: 90, amused: 5),
            reacted(rowID: 3, chatID: 7, minutesFromBase: 95, amused: 30,
                    body: "headcount, please love the message if you can make it"),
        ]
        let windows = FunnyMomentsLoader.windows(from: msgs, config: cfg)
        // Window 1: msg1 (4). Window 2: msg2 (5) — msg3 excluded as coordination.
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Set(windows.map(\.totalAmused)), [4, 5])
        XCTAssertFalse(windows.contains { $0.trigger.rowID == 3 }, "coordination trigger excluded")
    }

    // MARK: - Beloved coordination exclusion + genuine-moment boosts (pure)

    func testBeloved_excludesCoordinationFromRanking() {
        let real = memory(id: 1, body: "that genuinely made me cry laughing", reactions: makeReactions(.love, .love, .love))
        let rsvp = memory(id: 2, body: "headcount — love the message if you can make it!", reactions: makeReactions(.love, .love, .love, .love, .love, .love))
        let ranked = BelovedMessagesLoader.rank([real, rsvp], maxResults: 8)
        XCTAssertEqual(ranked.map(\.message.rowID), [1], "coordination/RSVP-bait excluded despite more reactions")
    }

    func testBeloved_isCoordinationMatchesPhrases() {
        XCTAssertTrue(BelovedMessagesLoader.isCoordination("HEADCOUNT for the trip"))
        XCTAssertTrue(BelovedMessagesLoader.isCoordination("react if you're coming"))
        XCTAssertTrue(BelovedMessagesLoader.isCoordination("🤍 if you want in"))
        XCTAssertFalse(BelovedMessagesLoader.isCoordination("i love this photo of us"))
    }

    func testBeloved_scoreBoostsOneToOneAndRealBody() {
        let r = makeReactions(.love)
        // Same reactions: 1:1 with a real body should outscore a group one-liner.
        let oneToOneReal = BelovedMessagesLoader.score(r, body: "this is a real heartfelt message", isGroup: false)
        let groupShort = BelovedMessagesLoader.score(r, body: "k", isGroup: true)
        XCTAssertGreaterThan(oneToOneReal, groupShort)
    }

    func testBeloved_dislikeIsNegative() {
        // A dislike should drag the score below a like.
        XCTAssertLessThan(
            BelovedMessagesLoader.score(makeReactions(.dislike)),
            BelovedMessagesLoader.score(makeReactions(.like))
        )
    }

    // MARK: - NostalgiaDismissals — hide model + suggestions

    func testHideModel_hideUnhideAndSuggestionDismissal() {
        let suite = "test.nostalgia.hide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NostalgiaDismissals(defaults: defaults)

        XCTAssertTrue(store.hiddenKeys().isEmpty)
        store.hide("Anyone")
        XCTAssertTrue(store.isHidden("Anyone"))
        XCTAssertTrue(NostalgiaDismissals(defaults: defaults).isHidden("Anyone"), "persists")
        store.unhide("Anyone")
        XCTAssertFalse(store.isHidden("Anyone"))

        // Reset clears the hidden set.
        store.hide("Anyone")
        store.reset()
        XCTAssertTrue(store.hiddenKeys().isEmpty)
    }

    // MARK: - Reaction / MemoryMessage builders

    private func makeReactions(_ kinds: Reaction.Kind...) -> [Reaction] {
        kinds.enumerated().map { idx, kind in
            Reaction(
                kind: kind,
                senderName: "P\(idx)",
                senderHandle: "+1555000\(idx)",
                date: now,
                isFromMe: false
            )
        }
    }

    private func memory(
        id: Int64,
        body: String,
        date: Date? = nil,
        isFromMe: Bool = false,
        reactions: [Reaction] = []
    ) -> MemoryMessage {
        MemoryMessage(
            rowID: id,
            guid: "guid-\(id)",
            date: date ?? now,
            isFromMe: isFromMe,
            body: body,
            senderName: isFromMe ? "You" : "Friend",
            partnerName: "Friend",
            chatGUID: "chat-guid",
            isGroup: false,
            reactions: reactions,
            avatarData: nil
        )
    }

    private func dormant(key: String) -> DormantFriend {
        DormantFriend(
            key: key, displayName: key, avatarData: nil,
            historicalTotal: 200, recentTotal: 0, peakPeriod: nil,
            daysSinceLastContact: 200, dormancyScore: 1.0
        )
    }

    private func addHours(_ h: Int, to date: Date) -> Date {
        calendar.date(byAdding: .hour, value: h, to: date)!
    }

    // MARK: - ChatStoryBuilder — per-chat notable moments (PURE)

    private func rawMsg(
        _ id: Int64,
        _ date: Date,
        fromMe: Bool = false,
        sender: String = "Friend",
        body: String = "hey",
        rx: Int = 0,
        glyph: String? = nil
    ) -> ChatStoryBuilder.RawMessage {
        ChatStoryBuilder.RawMessage(
            rowID: id, date: date, isFromMe: fromMe, senderName: sender,
            body: body, reactionCount: rx, topReactionEmoji: glyph
        )
    }

    private func minutes(_ m: Int, from base: Date) -> Date {
        calendar.date(byAdding: .minute, value: m, to: base)!
    }

    /// Sessionization: two bursts separated by > 45 min split; the longer burst
    /// (by message count) wins, with the right duration.
    func testStory_longestSessionSplitsOnGap() {
        let base = date(year: 2024, month: 12, day: 26)
        var msgs: [ChatStoryBuilder.RawMessage] = []
        // Burst A: 3 messages, 5 min apart.
        for i in 0..<3 { msgs.append(rawMsg(Int64(i), minutes(i * 5, from: base))) }
        // Gap of 90 min, then Burst B: 6 messages, 10 min apart (60 min span).
        let bStart = minutes(90 + 10, from: base)
        for i in 0..<6 { msgs.append(rawMsg(Int64(100 + i), minutes(i * 10, from: bStart))) }

        let best = ChatStoryBuilder.longestSession(msgs, gap: 45 * 60)
        XCTAssertEqual(best?.count, 6, "longer burst (6) wins over the 3-message burst")
        XCTAssertEqual(best?.start, bStart)
        XCTAssertEqual(Int(best!.end.timeIntervalSince(best!.start) / 60), 50, "5 gaps × 10 min")
    }

    /// Biggest day picks the busiest calendar day and reports its count.
    func testStory_biggestDayPicksBusiestDay() {
        let d1 = date(year: 2025, month: 1, day: 10)
        let d2 = date(year: 2025, month: 1, day: 11)
        var msgs: [ChatStoryBuilder.RawMessage] = []
        for i in 0..<3 { msgs.append(rawMsg(Int64(i), addHours(i, to: d1))) }      // 3 on d1
        for i in 0..<7 { msgs.append(rawMsg(Int64(10 + i), addHours(i, to: d2))) } // 7 on d2
        let bd = ChatStoryBuilder.biggestDay(msgs, calendar: calendar)
        XCTAssertEqual(bd?.count, 7)
        XCTAssertEqual(bd?.dayStart, calendar.startOfDay(for: d2))
    }

    /// Peak reaction excludes coordination/RSVP-bait + bare URLs and picks the
    /// most-reacted GENUINE message.
    func testStory_peakReactionExcludesCoordinationAndURLs() {
        let base = date(year: 2025, month: 3, day: 1)
        let msgs = [
            rawMsg(1, base, body: "love the message if you can make it", rx: 20, glyph: "❤️"),
            rawMsg(2, addHours(1, to: base), body: "https://example.com/a", rx: 15, glyph: "❤️"),
            rawMsg(3, addHours(2, to: base), sender: "Beck", body: "this genuinely made my whole week haha", rx: 6, glyph: "😂"),
            rawMsg(4, addHours(3, to: base), body: "ok", rx: 1, glyph: "👍"),
        ]
        let chat = ChatStoryBuilder.RawChat(
            chatRowID: 1, title: "Beck", isGroup: false, participantCount: 1,
            avatarData: nil, messages: msgs, events: []
        )
        // Lower the floor so a 4-message fixture builds.
        var cfg = ChatStoryBuilder.Config(); cfg.minMessages = 1
        let story = ChatStoryBuilder.buildStory(from: chat, calendar: calendar, config: cfg)
        let peak = story?.moments.first { $0.kind == .peakReaction }
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak?.example, "this genuinely made my whole week haha",
                       "coordination (20 rx) + bare URL (15 rx) excluded; genuine 6-rx wins")
        XCTAssertEqual(peak?.person, "Beck")
        XCTAssertTrue(peak?.headline.contains("6") ?? false)
    }

    /// A full story carries origin + longestConversation + biggestDay +
    /// peakReaction, sorted by date, and respects the ≥200-message floor.
    func testStory_buildAssemblesSortedMomentsAndHonorsFloor() {
        let start = date(year: 2024, month: 1, day: 1)
        var msgs: [ChatStoryBuilder.RawMessage] = []
        // 250 messages, 1 per day (so the floor passes); one reacted.
        for i in 0..<250 {
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            msgs.append(rawMsg(Int64(i), d,
                               body: i == 5 ? "the funniest thing ever happened today wow" : "hi",
                               rx: i == 5 ? 5 : 0, glyph: i == 5 ? "😂" : nil))
        }
        let chat = ChatStoryBuilder.RawChat(
            chatRowID: 7, title: "Pal", isGroup: false, participantCount: 1,
            avatarData: nil, messages: msgs, events: []
        )
        let story = ChatStoryBuilder.buildStory(from: chat, calendar: calendar)
        XCTAssertNotNil(story)
        XCTAssertEqual(story?.messageCount, 250)
        let kinds = story!.moments.map(\.kind)
        XCTAssertTrue(kinds.contains(.origin))
        XCTAssertTrue(kinds.contains(.peakReaction))
        // Sorted ascending by date.
        let dates = story!.moments.map(\.date)
        XCTAssertEqual(dates, dates.sorted(), "moments sorted oldest → newest")

        // Floor: a 199-message chat yields no story.
        let small = ChatStoryBuilder.RawChat(
            chatRowID: 8, title: "Acq", isGroup: false, participantCount: 1,
            avatarData: nil, messages: Array(msgs.prefix(199)), events: []
        )
        XCTAssertNil(ChatStoryBuilder.buildStory(from: small, calendar: calendar))
    }

    /// Recreated same-named group threads double-log a membership event with
    /// distinct ROWIDs; membershipMoments collapses by (kind, person, day).
    func testStory_membershipDeduplicatesSameDayDuplicates() {
        let d = date(year: 2024, month: 2, day: 22)
        let events = [
            ChatStoryBuilder.RawEvent(rowID: 1, date: d, actor: "Mason", kind: .added(person: "Venkat Chitturi")),
            // Same event, different thread → different ROWID, same day.
            ChatStoryBuilder.RawEvent(rowID: 2, date: addHours(0, to: d), actor: "Mason", kind: .added(person: "Venkat Chitturi")),
            // A genuinely different person same day → kept.
            ChatStoryBuilder.RawEvent(rowID: 3, date: addHours(1, to: d), actor: "Mason", kind: .added(person: "Atul")),
        ]
        let moments = ChatStoryBuilder.membershipMoments(events, calendar: calendar)
        let joins = moments.filter { $0.kind == .joined }
        XCTAssertEqual(joins.count, 2, "duplicate Venkat add collapsed; Atul add kept")
        XCTAssertEqual(Set(joins.compactMap(\.person)), ["Venkat Chitturi", "Atul"])
    }

    /// A "left" moment must be SUPPRESSED for someone still in the chat —
    /// e.g. a person whose phone handle was removed but who remains via their
    /// email handle. Reported bug: "Arnav left" while Arnav is still in the
    /// group (his +1650… handle was removed; he stays via his @gmail handle,
    /// both resolving to "Arnav Swamy").
    func testStory_membershipSuppressesLeftForCurrentParticipant() {
        let d = date(year: 2023, month: 12, day: 27)
        let events = [
            ChatStoryBuilder.RawEvent(rowID: 10, date: d, actor: "Arnav Swamy",
                                      kind: .removed(person: "Arnav Swamy")),
            ChatStoryBuilder.RawEvent(rowID: 11, date: addHours(1, to: d), actor: "You",
                                      kind: .removed(person: "Gandharva")),
        ]
        let moments = ChatStoryBuilder.membershipMoments(
            events, calendar: calendar, currentParticipants: ["Arnav Swamy"])
        let lefts = moments.filter { $0.kind == .left }
        XCTAssertEqual(Set(lefts.compactMap(\.person)), ["Gandharva"],
                       "Arnav (still a participant) suppressed; Gandharva (gone) kept")
    }

    /// An UNRESOLVED removed handle must NOT be blamed on the actor who did the
    /// removing. The old code fell back to the actor's name → "<remover> left".
    func testStory_membershipUnknownRemovedNotBlamedOnActor() {
        let d = date(year: 2024, month: 3, day: 1)
        let events = [
            ChatStoryBuilder.RawEvent(rowID: 20, date: d, actor: "Arnav Swamy",
                                      kind: .removed(person: "?")),
        ]
        let moments = ChatStoryBuilder.membershipMoments(events, calendar: calendar)
        XCTAssertTrue(moments.filter { $0.kind == .left }.isEmpty,
                      "an unknown removed handle is not the actor leaving — emit nothing")
    }

    /// Group sort: stories ranked by message count desc.
    func testStory_buildStoriesSortsByMessageCountDesc() {
        func chat(_ id: Int64, _ title: String, _ n: Int) -> ChatStoryBuilder.RawChat {
            let start = date(year: 2024, month: 1, day: 1)
            let msgs = (0..<n).map { rawMsg(Int64($0), calendar.date(byAdding: .hour, value: $0, to: start)!) }
            return ChatStoryBuilder.RawChat(chatRowID: id, title: title, isGroup: false,
                                            participantCount: 1, avatarData: nil, messages: msgs, events: [])
        }
        let stories = ChatStoryBuilder.buildStories(
            from: [chat(1, "Small", 220), chat(2, "Big", 400), chat(3, "Mid", 300)],
            calendar: calendar
        )
        XCTAssertEqual(stories.map(\.title), ["Big", "Mid", "Small"])
    }

    func testStory_isURLOnly() {
        XCTAssertTrue(ChatStoryBuilder.isURLOnly("https://x.com/y"))
        XCTAssertTrue(ChatStoryBuilder.isURLOnly("  http://a.b  "))
        XCTAssertTrue(ChatStoryBuilder.isURLOnly("www.foo.com"))
        XCTAssertFalse(ChatStoryBuilder.isURLOnly("check this https://x.com"), "has surrounding text")
        XCTAssertFalse(ChatStoryBuilder.isURLOnly("hello world"))
        XCTAssertFalse(ChatStoryBuilder.isURLOnly(""))
    }

    // MARK: - Event-gated "On This Day"

    private func storyWithMoment(_ kind: NotableMoment.Kind, on date: Date) -> ChatStory {
        let m = NotableMoment(kind: kind, date: date, headline: "h", detail: "d")
        return ChatStory(chatRowID: 1, title: "C", isGroup: false, participantCount: 1,
                         messageCount: 300, firstDate: date, lastDate: date,
                         avatarData: nil, moments: [m])
    }

    /// Only moments on today's month/day (in a PRIOR year) surface; same-year is
    /// excluded; non-matching dates excluded.
    func testOnThisDay_eventGatedToAnniversaryOnly() {
        let lastYear = date(year: 2025, month: 6, day: 2)   // matches now's Jun 2
        let thisYear = date(year: 2026, month: 6, day: 2)   // same year → excluded
        let other = date(year: 2024, month: 7, day: 14)     // different day → excluded
        let stories = [
            storyWithMoment(.origin, on: lastYear),
            storyWithMoment(.biggestDay, on: thisYear),
            storyWithMoment(.peakReaction, on: other),
        ]
        let gated = NostalgiaViewModel.eventGatedMoments(from: stories, now: now, calendar: calendar)
        XCTAssertEqual(gated.count, 1)
        XCTAssertEqual(gated.first?.date, lastYear)
    }

    /// Membership events (joined/left/renamed) are NOT anniversaries — never
    /// surfaced by the event-gate even on a matching date.
    func testOnThisDay_excludesMembershipKinds() {
        let lastYear = date(year: 2025, month: 6, day: 2)
        let stories = [
            storyWithMoment(.joined, on: lastYear),
            storyWithMoment(.left, on: lastYear),
            storyWithMoment(.renamed, on: lastYear),
            storyWithMoment(.longestConversation, on: lastYear),
        ]
        let gated = NostalgiaViewModel.eventGatedMoments(from: stories, now: now, calendar: calendar)
        XCTAssertTrue(gated.isEmpty, "only origin/biggestDay/peakReaction are anniversaries")
    }
}
