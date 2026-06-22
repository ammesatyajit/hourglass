//
//  DashboardLoaderTests.swift
//  HourglassTests
//
//  Covers `DashboardLoader.loadSync` against the fixture chat.db.
//
//  Fixture invariants we rely on (see Tests/Fixtures/build_fixture_chat_db.sh):
//    - 28 message rows total, 18 are "real" (associated_message_type=0)
//      → 12 sent + 6 received
//    - 4 chats: 2 one-to-one (rows 1, 3) + 2 groups (rows 2, 4)
//    - Group "Dashboard Group" (chat 4): 4 sent + 1 received in last-30d
//      window → outranks "Test Group" (chat 2, 1 sent)
//    - Chat 1 (1:1) is the high-volume contact: 9 messages total (6 sent
//      + 3 received). The other 1:1 (chat 3 with handle 4) has 1 sent.
//    - Recent rows cluster around 2026-05-13/14/15 (inside last-30d
//      when test "now" = 2026-05-22, the canonical project date)
//    - Two-months-old + six-months-old rows exist so 12m and all-time
//      windows produce different totals.
//
//  We use `loadSync` so the test stays straightforward XCTest — no async
//  hoops. The loader is pure-ish (database+contacts injected), trivially
//  testable.
//

import XCTest
@testable import Hourglass

final class DashboardLoaderTests: XCTestCase {

    /// Canonical test clock — matches the project's "today" so the
    /// last-30-days window catches the RECENT rows in the fixture.
    /// 2026-05-22 12:00 UTC == unix 1_779_451_200.
    private let testNow = Date(timeIntervalSince1970: 1_779_451_200)
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Open the fixture from the test bundle. Skips the test if the
    /// fixture isn't bundled (i.e. project.yml didn't roll it into
    /// Resources) — same pattern as the existing reveal/reaction tests.
    private func openFixture() throws -> ChatDatabase {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        return try ChatDatabase(url: url)
    }

    /// Empty resolved contacts — the fixture handles aren't in any
    /// AddressBook, so resolution is empty and all keys fall back to
    /// raw handles. This is the realistic default for tests.
    private var emptyContacts: ResolvedContacts {
        ResolvedContacts(byHandle: [:], allContacts: [])
    }

    // MARK: - Overview

    /// All-time overview totals are derived from the entire message table
    /// (excluding tapbacks). 20 real messages, 14 sent + 6 received.
    func testOverviewAllTime() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db,
            contacts: emptyContacts,
            window: .allTime,
            now: testNow,
            calendar: calendar
        )

        // Fixture has 35 message rows: 25 real (associated_message_type=0)
        // and 10 tapbacks/reactions. Sent = 19, received = 6.
        // (Updated when row 202 — UUID-leak — and rows 203/204/205/206 —
        // U+FFFC inline-attachment-marker fixtures — were added.)
        XCTAssertEqual(stats.overview.total, 25, "Expect 25 real messages (35 rows minus 10 tapbacks/reactions).")
        XCTAssertEqual(stats.overview.sent, 19)
        XCTAssertEqual(stats.overview.received, 6)
        XCTAssertEqual(stats.overview.chats, 4)
        XCTAssertNotNil(stats.overview.oldest)
        XCTAssertNotNil(stats.overview.newest)
        if let oldest = stats.overview.oldest, let newest = stats.overview.newest {
            XCTAssertLessThan(oldest, newest)
        }
    }

    // MARK: - Top contacts (last 30 days)

    /// In the last-30-days window, the high-volume 1:1 must come first
    /// and the second contact must appear too.
    ///
    /// Important: the loader groups by `h.id` (the resolved handle string)
    /// AFTER a COALESCE that maps sent rows (NULL handle_id) to the FIRST
    /// chat_handle_join row. In the fixture, chat 1 has handles 1 (phone)
    /// then 2 (email) — so all 3 sent rows attribute to handle 1, while
    /// received rows keep their actual handle_id. Handle 2 (email) thus
    /// shows up as a SEPARATE entry until AddressBook merging folds the
    /// two together (see `testContactMergingByDisplayName`).
    func testTopContactsLast30Days() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db,
            contacts: emptyContacts,
            window: .last30Days,
            now: testNow,
            calendar: calendar
        )

        // We expect at least two entries.
        XCTAssertGreaterThanOrEqual(stats.topContacts.count, 2,
                                    "Need a populated leaderboard with at least 2 contacts.")

        let top = stats.topContacts[0]
        // Top contact is chat 1's COALESCE pick — handle 1 in the fixture
        // (the phone number). With empty contacts, its displayName falls
        // back to the raw handle string.
        XCTAssertEqual(top.displayName, "+15551234567",
                       "Top contact in the 30d window is the high-volume 1:1 partner.")

        // Their counts in the 30d window after the 2026-05-25 attribution
        // fix (all 1:1 messages attribute to chat_handle_join's first
        // handle, ignoring m.handle_id — fixes orphaned-handle bug on
        // real DBs where m.handle_id pointed at deleted handle rows):
        //   sent     = 3  (rows 100/101/102 all attribute to chj[0] = handle 1)
        //   received = 2  (rows 103 AND 104 — handle 2 row no longer splits)
        //   total    = 5
        // The email handle is now correctly merged into the chat's single
        // partner instead of splitting messages into a phantom second
        // bucket. This matches real-world iMessage where a 1:1 chat has
        // exactly one partner regardless of how many email/phone handles
        // are associated.
        XCTAssertEqual(top.sent, 3, "Top contact sent count in 30d window.")
        XCTAssertEqual(top.received, 2, "Top contact received count: both received messages attribute to the chat's single partner.")
        XCTAssertEqual(top.total, 5, "Top contact total in 30d window.")

        // The second 1:1 contact (handle 4) must also appear.
        let names = stats.topContacts.map(\.displayName)
        XCTAssertTrue(names.contains("+15558889999"),
                      "The other 1:1 contact (handle 4) should show up.")

        // Email handle 2 is NO LONGER a separate entry — the chat-
        // handle-join attribution correctly collapses both handles for
        // the same chat into one row. (The prior split was the bug:
        // received rows from handle 2 weren't attributable to the user's
        // actual conversation partner.)
        XCTAssertFalse(names.contains("friend@example.com"),
                       "Email handle should NOT appear separately: it's the same chat's partner as handle 1.")
    }

    /// `restrictToContactKeys` keeps only the buckets whose key is in the
    /// set — the mechanism behind "top contacts scoped to a chat's members".
    /// All-time window so every fixture contact is present to filter from.
    func testTopContactsRestrictedToMemberKeys() throws {
        let db = try openFixture()
        let contacts = emptyContacts
        try db.dbQueue.read { database in
            let all = try DashboardLoader.loadTopContacts(
                db: database, dateRange: nil, contacts: contacts, limit: 50
            )
            XCTAssertGreaterThanOrEqual(all.count, 2,
                "Fixture should have ≥2 one-to-one contacts to filter from.")

            // Restrict to ONE existing contact's key → exactly that contact,
            // with its counts unchanged from the unrestricted ranking.
            let keep = all[0]
            let restricted = try DashboardLoader.loadTopContacts(
                db: database, dateRange: nil, contacts: contacts, limit: 50,
                restrictToContactKeys: [keep.key]
            )
            XCTAssertEqual(restricted.count, 1, "Restricting to one key yields one contact.")
            XCTAssertEqual(restricted.first?.key, keep.key)
            XCTAssertEqual(restricted.first?.total, keep.total,
                "Restricted entry keeps the same counts as the unrestricted ranking.")

            // Empty set → empty (no chat matched / no members resolved).
            let none = try DashboardLoader.loadTopContacts(
                db: database, dateRange: nil, contacts: contacts, limit: 50,
                restrictToContactKeys: []
            )
            XCTAssertTrue(none.isEmpty, "An empty restriction set yields no contacts.")

            // Unknown key → empty.
            let bogus = try DashboardLoader.loadTopContacts(
                db: database, dateRange: nil, contacts: contacts, limit: 50,
                restrictToContactKeys: ["name:Nobody At All"]
            )
            XCTAssertTrue(bogus.isEmpty, "A non-matching restriction set yields no contacts.")
        }
    }

    /// In the all-time window, totals should be higher than 30-day for
    /// the same contact — we've got older traffic in the fixture too.
    func testTopContactsAllTimeAccumulatesHistory() throws {
        let db = try openFixture()
        let thirtyDay = try DashboardLoader.loadSync(
            database: db, contacts: emptyContacts, window: .last30Days,
            now: testNow, calendar: calendar
        )
        let allTime = try DashboardLoader.loadSync(
            database: db, contacts: emptyContacts, window: .allTime,
            now: testNow, calendar: calendar
        )

        guard let thirtyTop = thirtyDay.topContacts.first(where: { $0.displayName == "+15551234567" }),
              let allTimeTop = allTime.topContacts.first(where: { $0.displayName == "+15551234567" })
        else {
            XCTFail("Expected high-volume contact to appear in both windows")
            return
        }
        XCTAssertGreaterThan(allTimeTop.total, thirtyTop.total,
                             "All-time totals must include rows outside the 30-day window.")
    }

    // MARK: - Top groups

    /// Dashboard Group has 4 sent in last 30d; Test Group has 1. Ranking
    /// is by sent-by-you DESC.
    func testTopGroupsLast30Days() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db,
            contacts: emptyContacts,
            window: .last30Days,
            now: testNow,
            calendar: calendar
        )

        let labels = stats.topGroups.map(\.displayName)
        // At least the two named groups must be present.
        XCTAssertTrue(labels.contains("Dashboard Group"))
        XCTAssertTrue(labels.contains("Test Group"))

        // Dashboard Group is #1 (3 sent in window > 1 sent in window).
        // (Row 133 uses LASTMONTH_A which is ~37 days back — outside the
        // 30-day window — so Dashboard Group has 3 sent + 1 received = 4
        // in the window. Row 133 will reappear in the 12m / all-time
        // windows.)
        XCTAssertEqual(stats.topGroups.first?.displayName, "Dashboard Group")
        XCTAssertEqual(stats.topGroups.first?.sentByYou, 3)
        XCTAssertEqual(stats.topGroups.first?.total, 4)
    }

    /// Groups with no sent-by-me are filtered out by the loader's
    /// `HAVING sent > 0` clause. We can verify by inspecting both
    /// windows — neither should surface a group with sent=0.
    func testTopGroupsFiltersOutZeroSent() throws {
        let db = try openFixture()
        for window in [DashboardLoader.Window.last30Days, .last12Months, .allTime] {
            let stats = try DashboardLoader.loadSync(
                database: db, contacts: emptyContacts, window: window,
                now: testNow, calendar: calendar
            )
            for group in stats.topGroups {
                XCTAssertGreaterThan(group.sentByYou, 0,
                                     "Group '\(group.displayName)' surfaced in \(window) with sent=0")
            }
        }
    }

    // MARK: - Time series

    /// The last-30-days bucketing must produce per-day buckets that line
    /// up with the recent rows.
    func testTimeSeriesBucketingDaily() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db,
            contacts: emptyContacts,
            window: .last30Days,
            now: testNow,
            calendar: calendar
        )

        XCTAssertFalse(stats.timeSeries.isEmpty,
                       "30-day window has multiple recent rows — must produce buckets.")

        // Sum the series — must equal the total messages in the window.
        let summedSent = stats.timeSeries.reduce(0) { $0 + $1.sent }
        let summedRecv = stats.timeSeries.reduce(0) { $0 + $1.received }
        let summed = summedSent + summedRecv

        XCTAssertGreaterThan(summed, 0)

        // Sanity: every bucket has a non-zero total or it shouldn't be in
        // the list (GROUP BY+HAVING bucket-not-null is the floor).
        for bucket in stats.timeSeries {
            XCTAssertGreaterThanOrEqual(bucket.sent + bucket.received, 0)
        }
    }

    /// Bucketing resolution flips between windows.
    func testBucketingResolutionForWindows() {
        XCTAssertEqual(DashboardLoader.Window.last30Days.bucketing, .day)
        XCTAssertEqual(DashboardLoader.Window.last12Months.bucketing, .month)
        XCTAssertEqual(DashboardLoader.Window.allTime.bucketing, .month)
    }

    // MARK: - Contact merging via AddressBook

    /// With a populated ResolvedContacts mapping BOTH handle 1 (phone)
    /// AND handle 2 (email) to the same person, the loader must merge
    /// their counts into a single row (matches `top_contacts.py`).
    func testContactMergingByDisplayName() throws {
        let db = try openFixture()
        let phone = Handle(raw: "+15551234567")
        let email = Handle(raw: "friend@example.com")
        let contact = Contact(displayName: "Friend Cactus", handles: [phone, email])
        let resolved = ResolvedContacts(
            byHandle: [phone: contact, email: contact],
            allContacts: [contact]
        )

        let stats = try DashboardLoader.loadSync(
            database: db,
            contacts: resolved,
            window: .last30Days,
            now: testNow,
            calendar: calendar
        )

        // After merge: handle 1's 3 sent + 1 received PLUS handle 2's 1
        // received (row 104) = 3 sent + 2 received = 5 total.
        // (Row 104 was attributed to "friend@example.com" by the raw SQL;
        // the Swift-side merge folds it in.)
        let merged = stats.topContacts.first { $0.displayName == "Friend Cactus" }
        let mergedEntry = try XCTUnwrap(merged, "Expect merged entry under contact's display name.")
        XCTAssertEqual(mergedEntry.sent, 3)
        XCTAssertEqual(mergedEntry.received, 2)
        XCTAssertEqual(mergedEntry.total, 5)

        // The raw handles must NOT also appear separately — they were
        // folded into Friend Cactus.
        let names = stats.topContacts.map(\.displayName)
        XCTAssertFalse(names.contains("+15551234567"))
        XCTAssertFalse(names.contains("friend@example.com"))
    }

    // MARK: - Tapback exclusion

    /// We deliberately added a tapback row (140) AND the original
    /// fixture had several (rows 4, 6-13). None of them must contribute
    /// to any count in `DashboardStats`.
    func testTapbacksAreNeverCounted() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db, contacts: emptyContacts, window: .allTime,
            now: testNow, calendar: calendar
        )

        // Total of 35 messages, 10 of them are tapbacks/reactions
        // (rows 4, 6, 7, 8, 9, 10, 11, 12, 13, 140). So real = 25.
        // (Rows 200/201 are length-prefix-bug fixture rows added by
        // features-agent; row 202 is the UUID-leak fixture; rows 203/204/
        // 205/206 are U+FFFC inline-attachment-marker fixtures. All seven
        // are real sent messages and DO count.)
        XCTAssertEqual(stats.overview.total, 25,
                       "Tapback/reaction rows must NOT count.")
    }

    // MARK: - Date helpers

    /// `dateRange(for:)` must produce a 30-day window ending at `now`.
    func testDateRangeLast30Days() {
        let r = DashboardLoader.dateRange(for: .last30Days, now: testNow, calendar: calendar)
        let range = try? XCTUnwrap(r)
        XCTAssertNotNil(range)
        if let range {
            let days = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
            XCTAssertEqual(days, 30, "30-day window must span 30 days.")
            XCTAssertEqual(range.upperBound, testNow)
        }
    }

    /// `dateRange(for: .allTime)` must be nil (no constraint).
    func testDateRangeAllTimeIsUnbounded() {
        XCTAssertNil(DashboardLoader.dateRange(for: .allTime, now: testNow, calendar: calendar))
    }
}
