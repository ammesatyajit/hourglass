//
//  DormancyDetector.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  PURE function over per-contact daily series. Finds "people you used to text
//  a lot and have gone quiet with." No DB, no UI — takes value types, returns
//  value types, fully unit-testable.
//
//  ────────────────────────────────────────────────────────────────────────
//  SENSITIVITY — read this before changing the thresholds.
//  ────────────────────────────────────────────────────────────────────────
//  The user was explicit: we CANNOT reliably tell an ex / romantic partner
//  from a friend, and resurfacing an ex would be hurtful. So this detector is
//  deliberately conservative and shaped to PREFER platonic-looking, positive
//  friendships:
//
//    1. NEUTRAL FRAMING ONLY. We compute "you used to talk a lot" — volume and
//       recency. We never infer relationship type, never use intimacy signals,
//       and the copy in the view is positive + low-pressure ("say hi?").
//    2. PREFER SUSTAINED BREADTH OVER INTENSE BURSTS. A short, very intense
//       burst of daily messaging that then stops cold is the shape most likely
//       to be a fling / dating phase. We require the historical activity to be
//       spread across MANY distinct days (`minActiveDays`) over a LONG span
//       (`minActiveSpanDays`), and we DOWN-WEIGHT high day-concentration. A
//       steady years-long friendship that tapered off scores far higher than a
//       six-week everyday blitz.
//    3. HIGH BAR TO APPEAR AT ALL. Minimum historical volume, minimum recent
//       quiet period, minimum gap since last contact. When a contact is even
//       borderline, we DROP it rather than guess.
//    4. EVERY RESULT IS DISMISSABLE (handled in the VM via `NostalgiaDismissals`
//       → UserDefaults). Dismissed people never come back. This detector just
//       provides candidates; the VM filters dismissals out.
//
//  When in doubt: make it more conservative, not more clever.
//

import Foundation

public enum DormancyDetector {

    /// Tunable thresholds. Defaults are intentionally strict. All day counts
    /// are in calendar days.
    public struct Config: Sendable, Equatable {
        /// The trailing window treated as "now / recent". A friendship is
        /// dormant only if the recent window is nearly silent.
        public var recentWindowDays: Int = 90
        /// Max messages allowed in the recent window for the person to still
        /// count as "gone quiet". A handful of messages (birthday text, a
        /// one-off) is fine; anything above this means you still talk.
        public var maxRecentMessages: Int = 6
        /// Minimum total messages over the historical (pre-recent) era. Filters
        /// out acquaintances you never really texted.
        public var minHistoricalMessages: Int = 120
        /// Minimum number of DISTINCT days with at least one message in the
        /// historical era. Enforces "this was a real, recurring thread" rather
        /// than a single big day. (Sustained-breadth guardrail.)
        public var minActiveDays: Int = 25
        /// Minimum span (first→last historical message) in days. A real
        /// friendship plays out over months; a fling/burst is compressed.
        /// (Sustained-breadth guardrail — the key anti-romantic shaper.)
        public var minActiveSpanDays: Int = 90
        /// Minimum days since the last message exchanged. Don't resurface
        /// someone you texted last week.
        public var minDaysSinceLastContact: Int = 45
        /// Cap on results returned (the panel shows a small, calm set).
        public var maxResults: Int = 6
        /// Maximum allowed ratio of (historical messages / active days). A very
        /// high per-active-day rate over a short span is the burst/fling shape
        /// we de-prioritize; above this hard cap we DROP the candidate entirely
        /// unless its span is long. Belt-and-suspenders on the span guard.
        public var maxBurstMessagesPerActiveDay: Double = 40

        public init() {}
    }

    /// Detect dormant friendships from the per-contact daily series.
    ///
    /// - Parameters:
    ///   - series: per-contact timelines (from `DashboardAllTimeAggregate`).
    ///   - now: reference instant (injected for tests).
    ///   - calendar: the app's calendar (for day-index math + peak-month).
    ///   - config: thresholds (defaults are conservative).
    /// - Returns: dormant friends, strongest-signal first, capped at
    ///   `config.maxResults`.
    public static func detect(
        series: [ContactDailySeries],
        now: Date,
        calendar: Calendar,
        config: Config = Config()
    ) -> [DormantFriend] {
        let recentCutoffIndex = dayIndex(
            for: calendar.date(byAdding: .day, value: -config.recentWindowDays, to: now) ?? now,
            calendar: calendar
        )
        let nowIndex = dayIndex(for: now, calendar: calendar)

        var candidates: [DormantFriend] = []

        for s in series {
            guard !s.days.isEmpty else { continue }

            // Split into historical (< recentCutoff) vs recent (>= recentCutoff).
            var historicalTotal = 0
            var recentTotal = 0
            var activeDays = 0
            var firstActiveIndex: Int32?
            var lastActiveIndex: Int32?
            // For peak-period: bucket historical volume by (year, month).
            var monthVolume: [DateComponents: Int] = [:]

            for c in s.days {
                let count = Int(c.sent) + Int(c.received)
                guard count > 0 else { continue }
                if c.dayIndex >= recentCutoffIndex {
                    recentTotal += count
                } else {
                    historicalTotal += count
                    activeDays += 1
                    if firstActiveIndex == nil { firstActiveIndex = c.dayIndex }
                    lastActiveIndex = c.dayIndex
                    let date = dateFor(dayIndex: c.dayIndex, calendar: calendar)
                    let key = calendar.dateComponents([.year, .month], from: date)
                    monthVolume[key, default: 0] += count
                }
            }

            // Last contact across the WHOLE series (recent or historical).
            guard let lastEverIndex = s.days.last(where: { Int($0.sent) + Int($0.received) > 0 })?.dayIndex else {
                continue
            }
            let daysSinceLast = Int(nowIndex - lastEverIndex)

            // ---- Conservative gates (ALL must pass) ----

            // Still actively talking? Not dormant.
            if recentTotal > config.maxRecentMessages { continue }
            // Texted recently? Not dormant.
            if daysSinceLast < config.minDaysSinceLastContact { continue }
            // Never really texted historically? Not a "used to talk a lot".
            if historicalTotal < config.minHistoricalMessages { continue }
            // Not enough distinct active days → could be a single-day blip.
            if activeDays < config.minActiveDays { continue }

            guard let firstIdx = firstActiveIndex, let lastIdx = lastActiveIndex else { continue }
            let spanDays = Int(lastIdx - firstIdx) + 1
            // Too compressed → looks like a burst/fling, not a friendship.
            if spanDays < config.minActiveSpanDays { continue }

            // Hard burst cap: very high messages-per-active-day is the intense
            // shape we avoid unless it's spread over a long span.
            let perActiveDay = Double(historicalTotal) / Double(max(activeDays, 1))
            if perActiveDay > config.maxBurstMessagesPerActiveDay
                && spanDays < config.minActiveSpanDays * 2 {
                continue
            }

            // ---- Score (higher = stronger, calmer resurfacing) ----
            //
            // Reward: high historical volume, broad active-day count, long
            // span (the "real friendship" signals). Penalize: residual recent
            // chatter (you sort of still talk) and extreme day-concentration
            // (burst shape). Recency of last contact contributes mildly — a
            // friend you haven't talked to in a year is a stronger "say hi"
            // than one from two months ago, but we cap its influence so the
            // list isn't just "oldest silence first".
            let volumeScore = log10(Double(historicalTotal) + 1)            // ~2.1–3+
            let breadthScore = log10(Double(activeDays) + 1)                // ~1.4–2.5
            let spanScore = log10(Double(spanDays) + 1) * 0.5              // mild
            let burstPenalty = min(perActiveDay / config.maxBurstMessagesPerActiveDay, 1.0)
            let recentPenalty = Double(recentTotal) / Double(max(config.maxRecentMessages, 1))
            let recencyBonus = min(Double(daysSinceLast) / 365.0, 1.0) * 0.5

            let dormancyScore =
                volumeScore + breadthScore + spanScore + recencyBonus
                - burstPenalty - recentPenalty

            // Peak month = the historical month with the most volume.
            let peak = monthVolume.max { $0.value < $1.value }?.key
            let peakDate = peak.flatMap { calendar.date(from: $0) }

            candidates.append(DormantFriend(
                key: s.key,
                displayName: s.displayName,
                avatarData: s.avatarData,
                historicalTotal: historicalTotal,
                recentTotal: recentTotal,
                peakPeriod: peakDate,
                daysSinceLastContact: daysSinceLast,
                dormancyScore: dormancyScore
            ))
        }

        candidates.sort { lhs, rhs in
            if lhs.dormancyScore != rhs.dormancyScore {
                return lhs.dormancyScore > rhs.dormancyScore
            }
            // Tie-break deterministically by name so output is stable.
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        if candidates.count > config.maxResults {
            candidates = Array(candidates.prefix(config.maxResults))
        }
        return candidates
    }

    // MARK: - Day-index helpers (local-calendar, matching the aggregate)

    /// Count of LOCAL calendar days from 2001-01-01 to `date`. Mirrors
    /// `DashboardAllTimeAggregate.dayIndex(for:)` so the indices line up with
    /// the `DailyCount.dayIndex` values we're slicing.
    static func dayIndex(for date: Date, calendar: Calendar) -> Int32 {
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        let comps = calendar.dateComponents([.day], from: anchor, to: date)
        return Int32(comps.day ?? 0)
    }

    /// Inverse — local-midnight Date for a day index.
    static func dateFor(dayIndex: Int32, calendar: Calendar) -> Date {
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
            ?? Date(timeIntervalSinceReferenceDate: 0)
        return calendar.date(byAdding: .day, value: Int(dayIndex), to: anchor) ?? anchor
    }
}
