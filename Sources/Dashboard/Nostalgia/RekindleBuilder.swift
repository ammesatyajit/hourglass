//
//  RekindleBuilder.swift
//  Hourglass — Dashboard / Nostalgia (rekindle reminders)
//
//  Builds `RekindleReminder`s: gentle "you haven't texted <name> in a while"
//  nudges for people who USED to be a heavy 1:1 correspondent (upper-quartile
//  by message volume) and have gone quiet for ≥ 1 month. Validated against the
//  user's real chat.db via the `/tmp/rekindle` prototype.
//
//  DESIGN (mirrors the prototype exactly):
//    • Per 1:1 chat (`chat.style = 45`): map the chat to its resolved contact
//      (via `chat_handle_join`), then count every real message
//      (`associated_message_type = 0`) in that chat + track the last message
//      date. Aggregate by resolved contact NAME (a person can have multiple
//      handles → multiple 1:1 chats; merge by name, like the rest of Nostalgia).
//    • Among contacts with ≥ 100 messages (a real relationship), the activation
//      threshold is the UPPER-QUARTILE (Q3) volume — COMPUTED from the data, not
//      hardcoded (validated ≈ 1781 on the dev corpus, but it must adapt).
//    • Eligible = `volume >= Q3 AND (now - lastDate) >= 30 days`.
//      `monthsSince = floor(days / 30)` (≥ 1). Sorted by volume desc.
//
//  SUPPRESSION is NOT done here — it flows through `NostalgiaViewModel.refilter`,
//  which drops anyone in the user-controlled `hiddenFromNostalgia` set AND anyone
//  the user has hidden. This builder returns the FULL
//  eligible list so the VM can apply the same hide controls as every other
//  surface.
//
//  The pure threshold + eligibility math (`eligible(from:now:config:)`) is split
//  from the chat.db scan so it's unit-testable without GRDB.
//
//  chat.db gotchas honored (see plans.md → Critical Technical Knowledge):
//    • `m.date` is Mac-absolute nanoseconds → `MessageDate.date(fromRaw:)`.
//    • style=45 chats have exactly one participant row in `chat_handle_join`, so
//      joining it doesn't fan out message rows.
//    • Only RESOLVED contacts can be reminders (a raw handle wouldn't reconcile
//      with the hidden set / romantic flags, which key on display names).
//

import Foundation
import GRDB

public enum RekindleBuilder {

    /// Tunables. Defaults mirror the validated `/tmp/rekindle` prototype.
    public struct Config: Sendable, Equatable {
        /// Minimum 1:1 messages for a contact to count as a "real relationship"
        /// (and thus enter the quartile computation). Prototype: 100.
        public var minMessagesForRelationship: Int = 100
        /// Dormancy threshold: a contact must have gone quiet for at least this
        /// long to fire. Prototype: 30 days.
        public var dormancyDays: Double = 30
        /// Days-per-month for the `monthsSince` floor. Prototype: 30.
        public var daysPerMonth: Double = 30

        public init() {}
    }

    /// One contact's aggregated 1:1 history. PURE value type — the DB adapter
    /// builds the map, `eligible(from:now:config:)` applies the thresholds, so
    /// the activation logic is testable with synthetic data.
    public struct Volume: Sendable, Equatable {
        public var total: Int
        public var lastDate: Date
        public var avatarData: Data?
        public init(total: Int, lastDate: Date, avatarData: Data? = nil) {
            self.total = total
            self.lastDate = lastDate
            self.avatarData = avatarData
        }
    }

    // MARK: - Pure eligibility

    /// The UPPER-QUARTILE (Q3) volume over the relationships clearing the
    /// `minMessagesForRelationship` floor — computed from the data. Matches the
    /// prototype's `pct(0.75)`: sort the totals ascending and index at
    /// `floor(count * 0.75)` (clamped). Returns 0 when there are no qualifying
    /// relationships. PURE.
    public static func upperQuartileVolume(
        from byContact: [String: Volume],
        config: Config = Config()
    ) -> Int {
        let totals = byContact.values
            .filter { $0.total >= config.minMessagesForRelationship }
            .map { $0.total }
            .sorted()
        guard !totals.isEmpty else { return 0 }
        let idx = min(totals.count - 1, Int(Double(totals.count) * 0.75))
        return totals[idx]
    }

    /// Reduce the per-contact aggregate to the SORTED eligible reminders
    /// (volume desc), applying the quartile + dormancy gates. NO suppression
    /// here — the VM applies the hidden set + romantic flags. PURE.
    public static func eligible(
        from byContact: [String: Volume],
        now: Date,
        config: Config = Config()
    ) -> [RekindleReminder] {
        let q3 = upperQuartileVolume(from: byContact, config: config)
        // No quartile (no real relationships) → nothing to remind about.
        guard q3 > 0 else { return [] }
        let dormancySeconds = config.dormancyDays * 86_400
        var out: [RekindleReminder] = []
        for (name, v) in byContact {
            guard v.total >= config.minMessagesForRelationship else { continue }
            guard v.total >= q3 else { continue }
            let dormantFor = now.timeIntervalSince(v.lastDate)
            guard dormantFor >= dormancySeconds else { continue }
            let months = max(1, Int(dormantFor / (config.daysPerMonth * 86_400)))
            out.append(RekindleReminder(
                name: name, avatarData: v.avatarData, volume: v.total,
                lastDate: v.lastDate, monthsSince: months))
        }
        // Heaviest correspondents first; deterministic tie-break by name.
        out.sort {
            if $0.volume != $1.volume { return $0.volume > $1.volume }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return out
    }
}
