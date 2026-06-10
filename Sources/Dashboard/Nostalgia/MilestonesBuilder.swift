//
//  MilestonesBuilder.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  Orchestrates `MilestoneDetector` over the per-contact series in the
//  all-time aggregate, selecting the user's most-significant relationships
//  (top by all-time volume) and returning a small, ordered set of
//  `ContactMilestones` for the timeline section.
//
//  PURE — it only reads the aggregate's `contactSeries` (value types) and runs
//  the detector. No DB, no UI. Unit-testable with a synthetic aggregate.
//

import Foundation

public enum MilestonesBuilder {

    public struct Config: Sendable, Equatable {
        /// How many contacts' milestone timelines to surface.
        public var maxContacts: Int = 6
        /// A contact must have at least this many all-time messages to earn a
        /// milestone timeline (filters out one-off threads).
        public var minTotalMessages: Int = 200
        public var detector: MilestoneDetector.Config = .init()

        public init() {}
    }

    /// Build milestone timelines for the top relationships.
    ///
    /// - Parameters:
    ///   - series: per-contact daily timelines (from the aggregate).
    ///   - now / calendar: passed through to the detector.
    ///   - config: thresholds.
    /// - Returns: `ContactMilestones`, ordered by all-time volume descending,
    ///   each with milestones sorted ascending by date.
    public static func build(
        series: [ContactDailySeries],
        now: Date,
        calendar: Calendar,
        config: Config = Config()
    ) -> [ContactMilestones] {
        // Rank contacts by all-time volume so the timeline shows the
        // relationships that actually matter to the user.
        let ranked = series
            .map { (s: $0, total: $0.days.reduce(0) { $0 + Int($1.sent) + Int($1.received) }) }
            .filter { $0.total >= config.minTotalMessages }
            .sorted { $0.total > $1.total }
            .prefix(config.maxContacts)

        var out: [ContactMilestones] = []
        out.reserveCapacity(ranked.count)
        for entry in ranked {
            if let cm = MilestoneDetector.detect(
                series: entry.s,
                now: now,
                calendar: calendar,
                config: config.detector
            ), !cm.milestones.isEmpty {
                out.append(cm)
            }
        }
        return out
    }
}
