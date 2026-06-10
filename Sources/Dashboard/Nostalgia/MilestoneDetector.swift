//
//  MilestoneDetector.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  PURE function over a single contact's daily series. Extracts a timeline of
//  structural "firsts" and anniversaries:
//
//    • firstMessage      — the day you first exchanged a message.
//    • messageCount(N)    — the day your running total crossed 1k / 5k / 10k …
//    • rampUp             — a sustained step-change UP in daily volume (you
//                           started talking a lot more, and it stuck).
//    • anniversary(years) — full-year anniversaries of the first message that
//                           have already passed.
//
//  No DB, no UI; takes value types and `now`, returns value types. Fully
//  unit-testable with synthetic `ContactDailySeries`.
//
//  Ramp-up heuristic (deliberately simple + robust):
//    Slide a boundary across the active timeline. At each candidate boundary,
//    compare the mean daily volume of the `window` days BEFORE vs the `window`
//    days AFTER. A ramp-up fires when the after-mean is both (a) at least
//    `minRatio`× the before-mean AND (b) at least `minAfterDailyMean` in
//    absolute terms (so noise near zero doesn't trigger it) AND (c) the
//    before-mean is low enough that this is a genuine step, not a small bump
//    on an already-busy thread. We keep only the SINGLE most pronounced
//    ramp-up per contact — the panel wants the one defining "we got close"
//    moment, not every wobble.
//

import Foundation

public enum MilestoneDetector {

    public struct Config: Sendable, Equatable {
        /// Round message-count milestones to surface.
        public var countMilestones: [Int] = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000]
        /// Trailing/leading window (in active-day samples) for the ramp-up
        /// before/after means.
        public var rampWindow: Int = 21
        /// After-mean must be at least this multiple of the before-mean.
        public var rampMinRatio: Double = 3.0
        /// After-mean must clear this absolute daily volume (anti-noise).
        public var rampMinAfterDailyMean: Double = 3.0
        /// Before-mean must be at or below this for the jump to read as a
        /// genuine step-up rather than a bump on an already-busy thread.
        public var rampMaxBeforeDailyMean: Double = 4.0
        /// Cap on anniversaries surfaced (most recent N).
        public var maxAnniversaries: Int = 3

        public init() {}
    }

    /// Detect milestones for one contact series.
    ///
    /// - Parameters:
    ///   - series: one contact's daily timeline.
    ///   - now: reference instant (for anniversary "has it passed yet").
    ///   - calendar: app calendar (day-index ↔ date).
    ///   - config: thresholds.
    /// - Returns: `ContactMilestones`, milestones sorted ascending by date,
    ///   or nil if the series is empty / has zero real messages.
    public static func detect(
        series: ContactDailySeries,
        now: Date,
        calendar: Calendar,
        config: Config = Config()
    ) -> ContactMilestones? {
        // Keep only days with real volume, sorted (the aggregate guarantees
        // sort, but we don't rely on it here).
        let active = series.days
            .filter { Int($0.sent) + Int($0.received) > 0 }
            .sorted { $0.dayIndex < $1.dayIndex }
        guard let first = active.first else { return nil }

        let total = active.reduce(0) { $0 + Int($1.sent) + Int($1.received) }
        guard total > 0 else { return nil }

        var milestones: [Milestone] = []

        // 1) First message.
        let firstDate = dateFor(dayIndex: first.dayIndex, calendar: calendar)
        milestones.append(Milestone(kind: .firstMessage, date: firstDate, secondarySort: 0))

        // 2) Running-total count crossings. Walk active days accumulating the
        //    total; the first day the cumulative sum reaches a milestone is
        //    when it was "crossed".
        var running = 0
        var nextMilestoneIdx = 0
        let sortedMilestones = config.countMilestones.sorted()
        for c in active {
            running += Int(c.sent) + Int(c.received)
            while nextMilestoneIdx < sortedMilestones.count,
                  running >= sortedMilestones[nextMilestoneIdx] {
                let m = sortedMilestones[nextMilestoneIdx]
                let date = dateFor(dayIndex: c.dayIndex, calendar: calendar)
                milestones.append(Milestone(kind: .messageCount(m), date: date, secondarySort: m))
                nextMilestoneIdx += 1
            }
        }

        // 3) Ramp-up step-change (single strongest).
        if let ramp = detectRampUp(active: active, calendar: calendar, config: config) {
            milestones.append(ramp)
        }

        // 4) Anniversaries of the first message that have already passed.
        milestones.append(contentsOf: anniversaries(
            firstMessageDate: firstDate, now: now, calendar: calendar, config: config
        ))

        milestones.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.secondarySort < rhs.secondarySort
        }

        return ContactMilestones(
            key: series.key,
            displayName: series.displayName,
            avatarData: series.avatarData,
            milestones: milestones,
            totalMessages: total
        )
    }

    // MARK: - Ramp-up

    /// Find the single most pronounced sustained step-up in daily volume.
    /// Compares before/after means across a sliding boundary over the ACTIVE
    /// day samples. Returns nil when no boundary clears the thresholds.
    static func detectRampUp(
        active: [DailyCount],
        calendar: Calendar,
        config: Config
    ) -> Milestone? {
        let w = config.rampWindow
        // Need at least a full window on each side.
        guard active.count >= w * 2 else { return nil }

        let volumes = active.map { Double(Int($0.sent) + Int($0.received)) }

        var bestRatio = 0.0
        var bestBoundary: Int? = nil

        // Boundary i means: before = [i-w, i), after = [i, i+w).
        for i in w...(active.count - w) {
            let before = volumes[(i - w)..<i]
            let after = volumes[i..<(i + w)]
            let beforeMean = before.reduce(0, +) / Double(w)
            let afterMean = after.reduce(0, +) / Double(w)

            // Genuine step-up gates.
            guard beforeMean <= config.rampMaxBeforeDailyMean else { continue }
            guard afterMean >= config.rampMinAfterDailyMean else { continue }
            // Ratio with a small epsilon so a near-zero before-mean doesn't
            // produce infinities; the absolute after-mean gate already
            // protects against noise.
            let ratio = afterMean / max(beforeMean, 0.5)
            guard ratio >= config.rampMinRatio else { continue }

            if ratio > bestRatio {
                bestRatio = ratio
                bestBoundary = i
            }
        }

        guard let boundary = bestBoundary else { return nil }
        let date = dateFor(dayIndex: active[boundary].dayIndex, calendar: calendar)
        return Milestone(kind: .rampUp, date: date, secondarySort: 1)
    }

    // MARK: - Anniversaries

    /// Full-year anniversaries of the first message that fall on or before
    /// `now`. Returns the most recent `maxAnniversaries`, ascending by date.
    static func anniversaries(
        firstMessageDate: Date,
        now: Date,
        calendar: Calendar,
        config: Config
    ) -> [Milestone] {
        let startOfFirst = calendar.startOfDay(for: firstMessageDate)
        let yearsElapsed = calendar.dateComponents([.year], from: startOfFirst, to: now).year ?? 0
        guard yearsElapsed >= 1 else { return [] }

        var out: [Milestone] = []
        let lowest = max(1, yearsElapsed - config.maxAnniversaries + 1)
        for y in lowest...yearsElapsed {
            guard let annivDate = calendar.date(byAdding: .year, value: y, to: startOfFirst) else { continue }
            // Defensive: only surface anniversaries that have actually passed.
            guard annivDate <= now else { continue }
            out.append(Milestone(kind: .anniversary(years: y), date: annivDate, secondarySort: y))
        }
        return out
    }

    // MARK: - Day-index helpers

    static func dateFor(dayIndex: Int32, calendar: Calendar) -> Date {
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        return calendar.date(byAdding: .day, value: Int(dayIndex), to: anchor) ?? anchor
    }
}
