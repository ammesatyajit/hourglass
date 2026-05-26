//
//  DateExpression.swift
//  Hourglass
//
//  Parse date-ish strings into either a specific calendar day or a Date.
//  Used by `MessageSearch.parseQuery` to interpret `before:`/`after:`/`on:`/
//  `last:` tokens and natural-language relative dates like "yesterday".
//
//  Why a separate file?
//    - The parsing rules are big enough to deserve their own tests.
//    - Doesn't depend on the search engine or any database — pure Foundation.
//    - Easy to evolve (add new natural phrases) without churning MessageSearch.
//
//  Grammar accepted (case-insensitive):
//    Specific day:
//      YYYY-MM-DD              ISO 8601 canonical
//      MM/DD/YYYY              US-style
//      MMM D YYYY              "May 8 2026", "Jan 1 2024"
//      MMM D                   "May 8" (current year)
//      today
//      yesterday
//
//    Open-ended:
//      last:Nd / last:Nh / last:Nm / last:Nw / last:Nmo / last:Ny
//                              N is a positive integer.
//                              d=days, h=hours, m=minutes, w=weeks,
//                              mo=months, y=years. Default unit = days.
//
//    Multi-day natural ranges (resolve to closed range):
//      last week               7 days inclusive, ending today
//      this week
//      this month / this year
//      last month / last year
//      <YYYY>                  whole calendar year
//
//  Anything else: returns nil.
//

import Foundation

/// Resolved date filter for one operator.
public enum DateExpression: Equatable, Sendable {
    /// A single instant — anchor for "before" / "after".
    case instant(Date)
    /// A closed range of dates (e.g. "yesterday" = midnight..midnight+1d).
    case range(ClosedRange<Date>)
}

public enum DateParser {

    /// Parse `s` into a `DateExpression`. Uses `Calendar.current` (user's
    /// calendar/timezone) so "today" matches what the user expects.
    /// Pass `now` for deterministic testing.
    public static func parse(_ raw: String, now: Date = Date()) -> DateExpression? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let cal = Calendar.current

        // MARK: "2024", "2025", etc. — whole year.
        //
        // This MUST run before parseRelativeDelta — otherwise "2024" looks
        // like a bare integer and gets parsed as "2024 days ago", a 5.5-year
        // delta. Year shortcuts get first dibs on 4-digit numbers in the
        // realistic-year band.
        if lower.count == 4, lower.allSatisfy({ $0.isNumber }),
           let yearValue = Int(lower), yearValue > 1900 && yearValue < 2200 {
            if let range = year(yearValue, calendar: cal) {
                return .range(range)
            }
        }

        // MARK: relative deltas (e.g. "7d", "24h", "2w", "3mo", "1y")
        if let range = parseRelativeDelta(lower, now: now, calendar: cal) {
            return .range(range)
        }

        // MARK: Natural phrases
        switch lower {
        case "today":
            let day = cal.startOfDay(for: now)
            let end = cal.date(byAdding: .day, value: 1, to: day) ?? now
            return .range(day...end)
        case "yesterday":
            let today = cal.startOfDay(for: now)
            let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
            return .range(yesterday...today)
        case "this week":
            if let range = currentWeek(now: now, calendar: cal) { return .range(range) }
        case "last week":
            if let range = previousWeek(now: now, calendar: cal) { return .range(range) }
        case "this month":
            if let range = currentMonth(now: now, calendar: cal) { return .range(range) }
        case "last month":
            if let range = previousMonth(now: now, calendar: cal) { return .range(range) }
        case "this year":
            if let range = currentYear(now: now, calendar: cal) { return .range(range) }
        case "last year":
            if let range = previousYear(now: now, calendar: cal) { return .range(range) }
        default:
            break
        }

        // MARK: ISO date YYYY-MM-DD
        if let d = parseISO(lower, calendar: cal) {
            let end = cal.date(byAdding: .day, value: 1, to: d) ?? d
            return .range(d...end)
        }

        // MARK: US date MM/DD/YYYY
        if let d = parseUS(lower, calendar: cal) {
            let end = cal.date(byAdding: .day, value: 1, to: d) ?? d
            return .range(d...end)
        }

        // MARK: "May 8 2026", "Jan 1 2024", "May 8"
        if let d = parseMonthNameDate(trimmed, now: now, calendar: cal) {
            let end = cal.date(byAdding: .day, value: 1, to: d) ?? d
            return .range(d...end)
        }

        return nil
    }

    /// Parse a relative-delta string. Allowed forms (case-insensitive):
    ///   7        → 7 days (bare number defaults to days)
    ///   7d, 24h, 30m, 2w, 3mo, 1y
    /// Returns the range `[now - delta, now]`.
    static func parseRelativeDelta(_ s: String, now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        // Match optional sign-less integer + optional unit. We allow whitespace
        // between number and unit ("7 days" parses too).
        var numEnd = s.startIndex
        while numEnd < s.endIndex, s[numEnd].isNumber {
            numEnd = s.index(after: numEnd)
        }
        guard numEnd > s.startIndex,
              let value = Int(s[s.startIndex..<numEnd]),
              value > 0 else { return nil }

        // Unit suffix
        let unitRaw = String(s[numEnd...]).trimmingCharacters(in: .whitespaces)
        let component: Calendar.Component
        switch unitRaw {
        case "", "d", "day", "days":
            component = .day
        case "h", "hr", "hrs", "hour", "hours":
            component = .hour
        case "m", "min", "mins", "minute", "minutes":
            component = .minute
        case "w", "wk", "wks", "week", "weeks":
            component = .weekOfYear
        case "mo", "mon", "month", "months":
            component = .month
        case "y", "yr", "yrs", "year", "years":
            component = .year
        default:
            return nil
        }

        guard let start = cal.date(byAdding: component, value: -value, to: now) else { return nil }
        return start...now
    }

    // MARK: - Calendar helpers

    static func currentWeek(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let interval = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
        return interval.start...interval.end
    }

    static func previousWeek(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now),
              let interval = cal.dateInterval(of: .weekOfYear, for: lastWeek) else { return nil }
        return interval.start...interval.end
    }

    static func currentMonth(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let interval = cal.dateInterval(of: .month, for: now) else { return nil }
        return interval.start...interval.end
    }

    static func previousMonth(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let lastMonth = cal.date(byAdding: .month, value: -1, to: now),
              let interval = cal.dateInterval(of: .month, for: lastMonth) else { return nil }
        return interval.start...interval.end
    }

    static func currentYear(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let interval = cal.dateInterval(of: .year, for: now) else { return nil }
        return interval.start...interval.end
    }

    static func previousYear(now: Date, calendar cal: Calendar) -> ClosedRange<Date>? {
        guard let lastYear = cal.date(byAdding: .year, value: -1, to: now),
              let interval = cal.dateInterval(of: .year, for: lastYear) else { return nil }
        return interval.start...interval.end
    }

    static func year(_ year: Int, calendar cal: Calendar) -> ClosedRange<Date>? {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        guard let start = cal.date(from: comps) else { return nil }
        var endComps = DateComponents()
        endComps.year = year + 1
        endComps.month = 1
        endComps.day = 1
        guard let end = cal.date(from: endComps) else { return nil }
        return start...end
    }

    // MARK: - Numeric parsers

    static func parseISO(_ s: String, calendar cal: Calendar) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), parts[0].count == 4,
              let m = Int(parts[1]), m >= 1 && m <= 12,
              let d = Int(parts[2]), d >= 1 && d <= 31 else { return nil }
        return dateFrom(year: y, month: m, day: d, calendar: cal)
    }

    static func parseUS(_ s: String, calendar cal: Calendar) -> Date? {
        let parts = s.split(separator: "/")
        guard parts.count == 3,
              let m = Int(parts[0]), m >= 1 && m <= 12,
              let d = Int(parts[1]), d >= 1 && d <= 31,
              let y = Int(parts[2]) else { return nil }
        // Allow 2- or 4-digit year (20 → 2020).
        let year = parts[2].count == 2 ? (y >= 70 ? 1900 + y : 2000 + y) : y
        return dateFrom(year: year, month: m, day: d, calendar: cal)
    }

    /// Parse "May 8 2026" / "May 8" / "Jan 1 2024" / "January 1, 2024".
    /// Strips punctuation; case-insensitive.
    static func parseMonthNameDate(_ raw: String, now: Date, calendar cal: Calendar) -> Date? {
        // Normalize: replace punctuation with space, collapse whitespace.
        let cleaned = raw
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard cleaned.count == 2 || cleaned.count == 3 else { return nil }

        let monthRaw = cleaned[0].lowercased()
        guard let m = monthIndex(monthRaw) else { return nil }
        guard let d = Int(cleaned[1]), d >= 1 && d <= 31 else { return nil }
        let y: Int
        if cleaned.count == 3 {
            guard let yy = Int(cleaned[2]) else { return nil }
            y = yy
        } else {
            y = cal.component(.year, from: now)
        }
        return dateFrom(year: y, month: m, day: d, calendar: cal)
    }

    static func monthIndex(_ s: String) -> Int? {
        let names: [(short: String, long: String, index: Int)] = [
            ("jan", "january", 1), ("feb", "february", 2), ("mar", "march", 3),
            ("apr", "april", 4), ("may", "may", 5), ("jun", "june", 6),
            ("jul", "july", 7), ("aug", "august", 8), ("sep", "september", 9),
            ("oct", "october", 10), ("nov", "november", 11), ("dec", "december", 12),
        ]
        for n in names where s == n.short || s == n.long || s == n.short + "." {
            return n.index
        }
        return nil
    }

    static func dateFrom(year: Int, month: Int, day: Int, calendar cal: Calendar) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        // `Calendar.date(from:)` is LENIENT — it normalizes invalid
        // components silently: 2024-02-31 becomes 2024-03-02, 2025-13-01
        // becomes 2026-01-01, etc. Codex audit M1 (2026-05-25) caught
        // this — a bad date in a user query was returning the wrong
        // search window instead of being rejected.
        //
        // Round-trip the year/month/day components and require an exact
        // match. If the calendar's normalization changed any of them,
        // the input wasn't a valid calendar date and we return nil.
        guard let candidate = cal.date(from: comps) else { return nil }
        let roundTrip = cal.dateComponents([.year, .month, .day], from: candidate)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else { return nil }
        return candidate
    }
}
