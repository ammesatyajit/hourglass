//
//  MessageDate.swift
//  Hourglass
//
//  Pure functions for converting between Mac-absolute-time (as stored in
//  `message.date` in chat.db) and Foundation.Date.
//
//  Background — the gotcha:
//    - `message.date` is Mac absolute time: time since 2001-01-01 00:00:00 UTC.
//    - On macOS 10.13+, new rows store NANOSECONDS. Older rows store SECONDS.
//    - The cutoff used everywhere (Apple's own code, our reference scripts,
//      and here): values greater than 1_000_000_000_000 are nanoseconds,
//      otherwise seconds.
//
//  Mac → Unix: add 978307200 (seconds between 2001-01-01 and 1970-01-01 UTC).
//
//  This file has zero dependencies (only Foundation) so it's trivial to unit
//  test in isolation.
//

import Foundation

public enum MessageDate {

    /// Seconds between the Unix epoch (1970-01-01) and the Mac absolute-time
    /// epoch (2001-01-01), in UTC. Add this to a Mac-epoch time (in seconds)
    /// to get a Unix timestamp.
    public static let macEpochOffset: TimeInterval = 978_307_200

    /// Anything strictly greater than this value is interpreted as nanoseconds.
    /// Matches the disambiguation logic in `reference/scripts/*.py`.
    public static let nanosecondThreshold: Int64 = 1_000_000_000_000

    /// Convert a raw `message.date` value (which may be either nanoseconds or
    /// seconds since the Mac epoch) into a `Date`.
    public static func date(fromRaw raw: Int64) -> Date {
        let secondsSinceMacEpoch: TimeInterval
        if raw > nanosecondThreshold {
            secondsSinceMacEpoch = TimeInterval(raw) / 1_000_000_000.0
        } else {
            secondsSinceMacEpoch = TimeInterval(raw)
        }
        return Date(timeIntervalSince1970: secondsSinceMacEpoch + macEpochOffset)
    }

    /// Convert a `Date` to a Mac-absolute-time value in **nanoseconds**.
    /// Use this when writing range predicates against modern (post-10.13) rows.
    ///
    /// Saturates at Int64.min / Int64.max for dates outside the representable
    /// range. `Date.distantPast` and `Date.distantFuture` are common range
    /// bounds (e.g. the FTS5 path uses them to mean "unbounded"); without
    /// saturation the multiplication overflows Int64 and crashes.
    public static func nanosecondsSinceMacEpoch(from date: Date) -> Int64 {
        let secondsSinceMacEpoch = date.timeIntervalSince1970 - macEpochOffset
        let scaled = secondsSinceMacEpoch * 1_000_000_000.0
        // Saturate. We bound by the Int64 representable range as Doubles —
        // Int64.max as Double has rounding error so use a comfortably-smaller
        // power-of-two literal that's exactly representable AND well outside
        // any plausible date (year ~290 billion AD).
        let intMax: Double = Double(Int64.max - 1_000_000)
        let intMin: Double = Double(Int64.min + 1_000_000)
        if !scaled.isFinite || scaled >= intMax { return Int64.max }
        if scaled <= intMin { return Int64.min }
        return Int64(scaled)
    }

    /// Convert a `Date` to Mac-absolute-time in **seconds**.
    /// Use this when writing predicates that should also catch pre-10.13 rows.
    public static func secondsSinceMacEpoch(from date: Date) -> TimeInterval {
        return date.timeIntervalSince1970 - macEpochOffset
    }
}
