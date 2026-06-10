//
//  StreakDetector.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  PURE function over the per-contact daily series. For each contact, finds the
//  LONGEST run of consecutive calendar days on which at least one message was
//  exchanged ("you & Noah: 87 days straight"). No DB, no UI — value types in,
//  value types out, fully unit-testable.
//
//  The per-contact `DailyCount.dayIndex` values are days-since-2001 in the
//  app's local calendar (the aggregate guarantees this and sorts ascending), so
//  "consecutive calendar days" is just "consecutive dayIndex integers" — a
//  single linear scan per contact, no Calendar math in the hot loop.
//

import Foundation

public enum StreakDetector {

    public struct Config: Sendable, Equatable {
        /// How many top streaks to surface.
        public var maxResults: Int = 5
        /// A streak must be at least this long to be worth surfacing (a 2-day
        /// "streak" isn't a story). Calendar days.
        public var minLength: Int = 3

        public init() {}
    }

    /// Find the longest consecutive-day streak per contact, then return the top
    /// `maxResults` across all contacts, longest first.
    public static func detect(
        series: [ContactDailySeries],
        calendar: Calendar,
        config: Config = Config()
    ) -> [Streak] {
        var out: [Streak] = []
        out.reserveCapacity(series.count)

        for s in series {
            guard let best = longestStreak(in: s.days) else { continue }
            guard best.length >= config.minLength else { continue }
            out.append(Streak(
                key: s.key,
                displayName: s.displayName,
                avatarData: s.avatarData,
                length: best.length,
                startDate: dateFor(dayIndex: best.startIndex, calendar: calendar),
                endDate: dateFor(dayIndex: best.endIndex, calendar: calendar)
            ))
        }

        out.sort { lhs, rhs in
            if lhs.length != rhs.length { return lhs.length > rhs.length }
            // Tie-break: more recent streak first, then name for determinism.
            if lhs.endDate != rhs.endDate { return lhs.endDate > rhs.endDate }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        if out.count > config.maxResults {
            out = Array(out.prefix(config.maxResults))
        }
        return out
    }

    // MARK: - Pure run-length core

    /// The longest run of consecutive `dayIndex` values among days that carry
    /// at least one real message. Returns the run length + its first/last day
    /// indices, or nil if the contact has no active days. PURE.
    public static func longestStreak(
        in days: [DailyCount]
    ) -> (length: Int, startIndex: Int32, endIndex: Int32)? {
        // Distinct active day indices, ascending. The aggregate already sorts
        // and never duplicates a (contact, day), but we don't rely on it: we
        // sort + de-dup defensively so synthetic test fixtures are forgiving.
        var active = days
            .filter { Int($0.sent) + Int($0.received) > 0 }
            .map { $0.dayIndex }
        guard !active.isEmpty else { return nil }
        active.sort()

        var bestLen = 1
        var bestStart = active[0]
        var bestEnd = active[0]

        var runLen = 1
        var runStart = active[0]
        var prev = active[0]

        for i in 1..<active.count {
            let d = active[i]
            if d == prev {
                continue                     // duplicate day — ignore.
            } else if d == prev + 1 {
                runLen += 1                  // consecutive — extend.
            } else {
                runLen = 1                   // gap — reset.
                runStart = d
            }
            prev = d
            if runLen > bestLen {
                bestLen = runLen
                bestStart = runStart
                bestEnd = d
            }
        }

        return (bestLen, bestStart, bestEnd)
    }

    // MARK: - Day-index helper (matches the aggregate / sibling detectors)

    static func dateFor(dayIndex: Int32, calendar: Calendar) -> Date {
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        return calendar.date(byAdding: .day, value: Int(dayIndex), to: anchor) ?? anchor
    }
}
