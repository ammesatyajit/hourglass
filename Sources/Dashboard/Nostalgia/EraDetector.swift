//
//  EraDetector.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  PURE function over the per-contact daily series. Buckets your whole history
//  into calendar quarters (seasons) and, for each quarter, finds the single
//  contact you exchanged the most messages with — a timeline of "your person"
//  season by season ("Spring 2024: Beck", "Fall 2024: Venkat"). No DB, no UI.
//
//  Quarter = Q1 Jan–Mar, Q2 Apr–Jun, Q3 Jul–Sep, Q4 Oct–Dec, in the app's
//  local calendar (so the season boundaries match what the user sees). We map
//  each `DailyCount.dayIndex` to its quarter via the calendar, summing per
//  (quarter, contact). A quarter only appears if its top contact cleared a
//  small floor — otherwise a single stray text becomes "your person," which
//  reads as noise.
//

import Foundation

public enum EraDetector {

    public struct Config: Sendable, Equatable {
        /// A quarter's winner must have at least this many messages for the
        /// quarter to surface. Filters out near-empty early/late quarters.
        public var minMessagesForEra: Int = 30
        /// Cap on eras returned (most recent first). 0 = no cap.
        public var maxResults: Int = 0

        public init() {}
    }

    /// Build the season-by-season "your person" timeline.
    ///
    /// - Returns: one `Era` per qualifying quarter, ordered MOST RECENT FIRST
    ///   (the timeline reads newest → oldest, matching the rest of Nostalgia).
    public static func detect(
        series: [ContactDailySeries],
        calendar: Calendar,
        config: Config = Config()
    ) -> [Era] {
        // (year, quarter) -> contactKey -> message count.
        // Plus per (year, quarter) we cache the quarter's local-midnight start.
        struct QuarterKey: Hashable { let year: Int; let quarter: Int }
        var counts: [QuarterKey: [String: Int]] = [:]
        // contactKey -> (displayName, avatar) for the winner lookup.
        var meta: [String: (name: String, avatar: Data?)] = [:]

        for s in series {
            meta[s.key] = (s.displayName, s.avatarData)
            for c in s.days {
                let n = Int(c.sent) + Int(c.received)
                guard n > 0 else { continue }
                let date = dateFor(dayIndex: c.dayIndex, calendar: calendar)
                let comps = calendar.dateComponents([.year, .month], from: date)
                guard let year = comps.year, let month = comps.month else { continue }
                let quarter = (month - 1) / 3 + 1     // 1…12 → 1…4
                let qk = QuarterKey(year: year, quarter: quarter)
                counts[qk, default: [:]][s.key, default: 0] += n
            }
        }

        var eras: [Era] = []
        eras.reserveCapacity(counts.count)
        for (qk, perContact) in counts {
            // Winner = most messages this quarter; deterministic tie-break by
            // name so the same data always yields the same "person."
            guard let winner = perContact.max(by: { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                let ln = meta[lhs.key]?.name ?? lhs.key
                let rn = meta[rhs.key]?.name ?? rhs.key
                // We want the MAX, so "smaller name wins ties" means it should
                // compare as the larger element here.
                return ln.localizedCaseInsensitiveCompare(rn) == .orderedDescending
            }) else { continue }
            guard winner.value >= config.minMessagesForEra else { continue }

            let m = meta[winner.key]
            eras.append(Era(
                year: qk.year,
                quarter: qk.quarter,
                startDate: quarterStart(year: qk.year, quarter: qk.quarter, calendar: calendar),
                topContactKey: winner.key,
                topContactName: m?.name ?? winner.key,
                topContactAvatar: m?.avatar,
                messageCount: winner.value
            ))
        }

        // Most recent first.
        eras.sort { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.quarter > rhs.quarter
        }
        if config.maxResults > 0 && eras.count > config.maxResults {
            eras = Array(eras.prefix(config.maxResults))
        }
        return eras
    }

    // MARK: - Helpers

    /// Local-midnight start of the first day of a quarter.
    static func quarterStart(year: Int, quarter: Int, calendar: Calendar) -> Date {
        let month = (quarter - 1) * 3 + 1     // Q1→1, Q2→4, Q3→7, Q4→10
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
            ?? (calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
                ?? Date(timeIntervalSinceReferenceDate: 0))
    }

    static func dateFor(dayIndex: Int32, calendar: Calendar) -> Date {
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        return calendar.date(byAdding: .day, value: Int(dayIndex), to: anchor) ?? anchor
    }
}
