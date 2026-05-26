//
//  MessageDateTests.swift
//  HourglassTests
//
//  Covers the Mac-absolute-time disambiguation in `Sources/Data/MessageDate.swift`.
//  Every chat.db query touches this — getting it wrong silently shifts every
//  message by 31 years (Unix epoch vs Mac epoch) or by a factor of 1e9 (ns
//  treated as s).
//
//  Test inputs match the fixture chat.db built by
//  `Tests/Fixtures/build_fixture_chat_db.sh` — the nanosecond rows there use
//  the same 2024-06-15 12:00:00 UTC value tested here, and the legacy row
//  uses the same 2010-06-15 12:00:00 UTC seconds value.
//

import XCTest
@testable import Hourglass

final class MessageDateTests: XCTestCase {

    // MARK: - Anchors

    /// 2001-01-01 00:00:00 UTC as a Unix timestamp. Anything off by 978307200
    /// in either direction is the classic Mac-epoch / Unix-epoch confusion.
    private let macEpochAsUnix: TimeInterval = 978_307_200

    /// 2024-06-15 12:00:00 UTC.
    /// - Unix: 1_718_452_800
    /// - Mac seconds: 740_145_600
    /// - Mac nanoseconds: 740_145_600_000_000_000
    private let modernRawNs: Int64 = 740_145_600_000_000_000
    private let modernExpectedUnix: TimeInterval = 1_718_452_800

    /// 2010-06-15 12:00:00 UTC.
    /// - Unix: 1_276_603_200
    /// - Mac seconds: 298_296_000
    private let legacyRawS: Int64 = 298_296_000
    private let legacyExpectedUnix: TimeInterval = 1_276_603_200

    // MARK: - Nanosecond branch

    /// A modern (post-10.13) `message.date` value, stored in nanoseconds,
    /// converts to the right `Date` (year 2024-ish).
    func testNanosecondScaleDecodesToCorrectDate() {
        let date = MessageDate.date(fromRaw: modernRawNs)
        XCTAssertEqual(date.timeIntervalSince1970, modernExpectedUnix, accuracy: 0.001,
                       "Nanosecond date should round-trip to 2024-06-15 12:00:00 UTC.")

        // Spot-check the year so a 1e9 misinterpretation (treating ns as s)
        // would fail loudly rather than silently pass an accuracy check.
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 12)
    }

    // MARK: - Seconds branch

    /// A legacy `message.date` value, stored in seconds, converts correctly
    /// (year ~2010).
    func testSecondScaleDecodesToCorrectDate() {
        let date = MessageDate.date(fromRaw: legacyRawS)
        XCTAssertEqual(date.timeIntervalSince1970, legacyExpectedUnix, accuracy: 0.001,
                       "Seconds date should round-trip to 2010-06-15 12:00:00 UTC.")

        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual(comps.year, 2010)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 12)
    }

    // MARK: - Boundary

    /// The threshold (`date > 1_000_000_000_000`) must not flip on values
    /// adjacent to the boundary. Anything `<=` 1e12 is seconds, anything `>`
    /// is nanoseconds — same rule as the reference Python scripts.
    func testDisambiguationBoundary() {
        let threshold = MessageDate.nanosecondThreshold
        XCTAssertEqual(threshold, 1_000_000_000_000)

        // Exactly the threshold → seconds branch (i.e. value used as seconds).
        let atThreshold = MessageDate.date(fromRaw: threshold)
        let expectedAtThresholdAsSeconds =
            TimeInterval(threshold) + MessageDate.macEpochOffset
        XCTAssertEqual(atThreshold.timeIntervalSince1970,
                       expectedAtThresholdAsSeconds,
                       accuracy: 0.001,
                       "Value == nanosecondThreshold must be interpreted as seconds.")

        // One below → still seconds.
        let belowThreshold = MessageDate.date(fromRaw: threshold - 1)
        let expectedBelowAsSeconds =
            TimeInterval(threshold - 1) + MessageDate.macEpochOffset
        XCTAssertEqual(belowThreshold.timeIntervalSince1970,
                       expectedBelowAsSeconds,
                       accuracy: 0.001,
                       "Value just below threshold must be seconds.")

        // One above → nanoseconds. With raw = threshold+1, ns→s gives ~1000s
        // since the Mac epoch.
        let aboveThreshold = MessageDate.date(fromRaw: threshold + 1)
        let expectedAboveAsNs =
            (TimeInterval(threshold + 1) / 1_000_000_000.0) + MessageDate.macEpochOffset
        XCTAssertEqual(aboveThreshold.timeIntervalSince1970,
                       expectedAboveAsNs,
                       accuracy: 0.001,
                       "Value just above threshold must be nanoseconds.")
    }

    // MARK: - Round trip

    /// `Date → mac-absolute → Date` (via nanoseconds) is identity within 1ms.
    /// 1ms is well above floating-point error for this conversion and well
    /// below any precision we care about for a chat message.
    ///
    /// NOTE: this only tests dates AFTER ~2001-01-01 00:16:40 UTC. Anything
    /// within ~1000 s of the Mac epoch encodes to a ns value below the
    /// disambiguation threshold and would round-trip through the seconds
    /// branch (still correct, just a different code path). iMessage didn't
    /// exist before 2011, so this edge case doesn't affect real chat.db data.
    /// Logged as a known quirk in the change log.
    func testRoundTripDateThroughNanoseconds() {
        let samples: [Date] = [
            Date(timeIntervalSince1970: 1_718_452_800),  // 2024-06-15 12:00 UTC
            Date(timeIntervalSince1970: 1_400_000_000),  // 2014-05-13 16:53 UTC
            Date(timeIntervalSince1970: 2_000_000_000),  // 2033-05-18 03:33 UTC
        ]

        for original in samples {
            let raw = MessageDate.nanosecondsSinceMacEpoch(from: original)
            // Sanity: the raw value should be above the disambiguation
            // threshold (otherwise `date(fromRaw:)` would treat it as
            // seconds and the round-trip would explode by 1e9).
            XCTAssertGreaterThan(raw, MessageDate.nanosecondThreshold,
                                 "Modern dates encoded to ns must land in the ns branch.")
            let restored = MessageDate.date(fromRaw: raw)
            XCTAssertEqual(restored.timeIntervalSince1970,
                           original.timeIntervalSince1970,
                           accuracy: 0.001,
                           "Round trip for \(original) failed.")
        }
    }

    /// `Date → mac-absolute seconds → Date` (the legacy branch) is also identity.
    /// Uses the seconds encoder so values land below the disambiguation
    /// threshold and are read back through the seconds branch.
    func testRoundTripDateThroughSeconds() {
        // Pick a date that, when encoded as seconds-since-Mac-epoch, lands
        // BELOW the disambiguation threshold (10^12) so it goes through the
        // seconds branch on the way back. 10^12 seconds since 2001 lands in
        // year ~33700 AD, so essentially any realistic legacy date works.
        let original = Date(timeIntervalSince1970: 1_276_603_200)  // 2010-06-15 12:00
        let rawSeconds = MessageDate.secondsSinceMacEpoch(from: original)
        XCTAssertLessThanOrEqual(Int64(rawSeconds), MessageDate.nanosecondThreshold,
                                 "Legacy seconds value must stay below threshold.")
        let restored = MessageDate.date(fromRaw: Int64(rawSeconds))
        XCTAssertEqual(restored.timeIntervalSince1970,
                       original.timeIntervalSince1970,
                       accuracy: 1.0,  // Int64 truncation loses sub-second precision.
                       "Seconds round trip for \(original) failed.")
    }
}
