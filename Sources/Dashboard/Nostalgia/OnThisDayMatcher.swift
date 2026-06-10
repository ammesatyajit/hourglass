//
//  OnThisDayMatcher.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  PURE date logic. Given "now" and the span of the user's history, produce
//  the set of anniversary windows we want to look back at — today's month-day
//  in prior years (1y, 2y, 3y), plus the 6-months-ago mark. No DB, no UI;
//  trivially unit-testable.
//
//  Why calendar arithmetic and not "subtract 365 days":
//    - 365-day subtraction drifts across leap years, so "1 year ago today"
//      slowly slides off the real calendar date. We use
//      `Calendar.date(byAdding: .year, value: -n)` so Feb-29 / month-length
//      edges resolve the way a human reading a calendar would.
//    - Each window is a full LOCAL day [startOfDay, startOfNextDay), so a
//      `MessageSearch` date-range pulls exactly that day's messages
//      regardless of timezone (the search clause uses the same local-day
//      semantics as the rest of the app).
//
//  Leap-day note: Feb 29 → "1 year ago" lands on Feb 28 of a non-leap prior
//  year (Calendar clamps the day component). That's the desired, least-
//  surprising behavior — the user still sees a memory rather than a gap.
//

import Foundation

public enum OnThisDayMatcher {

    /// The spans we surface, in the order the panel should consider them.
    /// 6-months-ago leads (closest), then 1/2/3 years.
    public static let defaultSpans: [AnniversaryWindow.Span] = [
        .monthsAgo(6),
        .yearsAgo(1),
        .yearsAgo(2),
        .yearsAgo(3),
    ]

    /// Build anniversary windows for `now`, keeping only those that fall
    /// within `[historyOldest, historyNewest]` (so we never offer a "2 years
    /// ago" card to a user whose history is 8 months old).
    ///
    /// - Parameters:
    ///   - now: reference instant (injected for tests).
    ///   - calendar: the app's calendar (carries the right timezone).
    ///   - historyOldest / historyNewest: the data span. When nil, no
    ///     clamping is applied (used by tests that want the raw windows).
    ///   - spans: which look-backs to compute. Defaults to `defaultSpans`.
    /// - Returns: windows sorted by proximity (closest to today first).
    public static func windows(
        now: Date,
        calendar: Calendar,
        historyOldest: Date?,
        historyNewest: Date?,
        spans: [AnniversaryWindow.Span] = defaultSpans
    ) -> [AnniversaryWindow] {
        var out: [AnniversaryWindow] = []
        out.reserveCapacity(spans.count)

        for span in spans {
            guard let dayStart = anniversaryDayStart(span: span, now: now, calendar: calendar) else {
                continue
            }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }

            // Clamp to the data span: the anniversary DAY must overlap the
            // window of dates we actually have messages for. We compare the
            // day's [start, end) against [oldest-day-start, newest-day-end).
            if let oldest = historyOldest {
                // The anniversary day must not end before our oldest data.
                if dayEnd <= calendar.startOfDay(for: oldest) { continue }
            }
            if let newest = historyNewest {
                // The anniversary day must not start after our newest data.
                // (Also drops any future/degenerate window — anniversaries are
                // always strictly in the past, but this guards the edge where
                // `now` is past the newest message.)
                let newestDayEnd = calendar.date(
                    byAdding: .day, value: 1, to: calendar.startOfDay(for: newest)
                ) ?? newest
                if dayStart >= newestDayEnd { continue }
            }

            out.append(AnniversaryWindow(span: span, dayStart: dayStart, dayEnd: dayEnd))
        }

        // De-dupe by resolved day — e.g. on a freshly-installed history the
        // 6-months and 1-year windows can't collide, but defensive against a
        // future span set that might. Keep the closest-proximity entry.
        var seen: Set<Date> = []
        out.sort { $0.span.proximityRank < $1.span.proximityRank }
        out = out.filter { seen.insert($0.dayStart).inserted }
        return out
    }

    /// Resolve the local-midnight start of the day that is `span` before
    /// `now`. Returns nil only if calendar math fails (it never does for the
    /// Gregorian-derived calendars we use).
    public static func anniversaryDayStart(
        span: AnniversaryWindow.Span,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let target: Date?
        switch span {
        case .yearsAgo(let n):
            target = calendar.date(byAdding: .year, value: -n, to: now)
        case .monthsAgo(let n):
            target = calendar.date(byAdding: .month, value: -n, to: now)
        }
        return target.map { calendar.startOfDay(for: $0) }
    }
}
