//
//  OnThisDayLoader.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  For each anniversary window (today, but 6 months / 1 / 2 / 3 years ago),
//  fetch that day's messages and surface the most interesting handful.
//
//  The DB calls live in `load`; window-building is delegated to the pure
//  `OnThisDayMatcher`, and the per-day ranking is the PURE `rank`/`interest`
//  functions — both unit-testable without chat.db.
//

import Foundation

public struct OnThisDayLoader: Sendable {

    public struct Config: Sendable, Equatable {
        /// How many messages to surface per anniversary day.
        public var perDay: Int = 4
        /// SQL cap on candidates fetched per day before ranking. A single
        /// day rarely exceeds this; it bounds the worst case (a heavy group
        /// day) so reaction-loading stays cheap.
        public var candidateLimit: Int = 300
        /// Which look-backs to surface.
        public var spans: [AnniversaryWindow.Span] = OnThisDayMatcher.defaultSpans

        public init() {}
    }

    private let search: MessageSearch
    private let calendar: Calendar
    private let config: Config

    public init(search: MessageSearch, calendar: Calendar, config: Config = Config()) {
        self.search = search
        self.calendar = calendar
        self.config = config
    }

    /// Resolve every anniversary window to its memory. Synchronous + throwing
    /// — call off the main thread. Skips windows with no messages.
    ///
    /// - Parameters:
    ///   - now: reference instant (injected for tests).
    ///   - historyOldest / historyNewest: data span used to drop windows that
    ///     predate the user's history.
    public func load(
        now: Date,
        historyOldest: Date?,
        historyNewest: Date?
    ) throws -> [OnThisDayMemory] {
        let windows = OnThisDayMatcher.windows(
            now: now,
            calendar: calendar,
            historyOldest: historyOldest,
            historyNewest: historyNewest,
            spans: config.spans
        )

        var out: [OnThisDayMemory] = []
        out.reserveCapacity(windows.count)
        for window in windows {
            // Empty phrase + an explicit date range = "every real message that
            // day." MessageSearch drops tapbacks (associated_message_type = 0)
            // and splices reactions onto each row.
            let results = try search.search(
                phrase: "",
                dateRange: window.dateRange,
                limit: config.candidateLimit,
                now: now,
                order: .descending
            )
            guard !results.isEmpty else { continue }
            let memories = results.map { MemoryMessage(result: $0) }
            let picked = Self.rank(memories, perDay: config.perDay)
            guard !picked.isEmpty else { continue }
            out.append(OnThisDayMemory(
                window: window,
                messages: picked,
                totalThatDay: memories.count
            ))
        }
        return out
    }

    // MARK: - Pure ranking

    /// Pick the most interesting `perDay` messages from a day's worth, then
    /// return them in chronological order (so a card reads like the day did).
    public static func rank(_ messages: [MemoryMessage], perDay: Int) -> [MemoryMessage] {
        // Drop pure-noise rows (empty body AND no reactions) — these are
        // attachment placeholders / tapback artifacts that read as blanks.
        let substantive = messages.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.reactions.isEmpty }
        let pool = substantive.isEmpty ? messages : substantive

        let top = pool
            .sorted { interest($0) > interest($1) }
            .prefix(perDay)
        // Re-sort the survivors chronologically for display.
        return top.sorted { $0.date < $1.date }
    }

    /// Interest score for a single message. Rewards: reactions (someone cared),
    /// substantive length (a real sentence beats "ok"), being received (the
    /// memory of what THEY said tends to land better than your own one-liners,
    /// but only mildly). Penalizes: very short / empty bodies.
    public static func interest(_ m: MemoryMessage) -> Double {
        var s = 0.0
        // Reactions are the strongest "this mattered" signal.
        s += Double(m.reactions.count) * 4.0
        // Length, with diminishing returns (log) so a paragraph doesn't
        // dominate every card.
        let len = m.body.trimmingCharacters(in: .whitespacesAndNewlines).count
        if len > 0 {
            s += min(log2(Double(len) + 1), 8.0)   // caps ~8 around 255 chars
        } else {
            s -= 2.0
        }
        // Tiny nudge toward received messages (memories of what others said).
        if !m.isFromMe { s += 0.5 }
        return s
    }
}
