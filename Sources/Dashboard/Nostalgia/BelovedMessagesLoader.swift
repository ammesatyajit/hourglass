//
//  BelovedMessagesLoader.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  Finds the most-reacted messages — "remember this?". Uses `MessageSearch`
//  with the `reactions:>=N` operator so the heavy filter (only messages with
//  ≥N tapbacks) runs in SQL; we then rank in Swift by a WARMTH score so genuine
//  warm moments lead, not group-coordination RSVP-bait.
//
//  Why warmth, not raw count: raw reaction count is dominated by
//  coordination/headcount messages ("please love this if you can make it",
//  "🤍 if you're coming") — everyone taps the same tapback to vote, so these
//  pile up reactions while meaning nothing as a memory. The fix has three
//  parts, all in the PURE `rank`:
//    1. EXCLUDE reaction-soliciting / coordination bodies outright (see
//       `isCoordination`).
//    2. WARMTH-WEIGHT instead of counting: love > laugh > emphasize > like;
//       question barely counts; dislike is negative (see `score`).
//    3. PREFER genuine moments: a small boost for 1:1 chats and for messages
//       with a real text body (≥15 chars); pure-logistics get nothing extra.
//
//  The DB call lives in `load`; the ranking is the PURE `rank`/`score`/
//  `isCoordination` functions so they're unit-testable against synthetic
//  `MemoryMessage`s with no chat.db.
//

import Foundation

public struct BelovedMessagesLoader: Sendable {

    public struct Config: Sendable, Equatable {
        /// Minimum reaction count to even be a candidate. 3 keeps it to
        /// genuinely-beloved messages, not every single tapback.
        public var minReactions: Int = 3
        /// How many beloved messages the panel shows.
        public var maxResults: Int = 8
        /// SQL candidate cap — we fetch the most recent N matching the
        /// reaction threshold, then re-rank by warmth. Generous so a great
        /// older message isn't excluded just by recency, but bounded so the
        /// in-process reaction grouping stays cheap.
        public var candidateLimit: Int = 400

        public init() {}
    }

    private let search: MessageSearch
    private let config: Config

    public init(search: MessageSearch, config: Config = Config()) {
        self.search = search
        self.config = config
    }

    /// Fetch + rank beloved messages. Synchronous + throwing — call from a
    /// background queue (the VM does). Returns warmth-ranked, capped results.
    public func load() throws -> [BelovedMessage] {
        // `reactions:>=N` pushes the "has at least N reactions" filter into
        // SQL (see MessageSearch.reactionsClause). We pull recent candidates
        // and re-rank; MessageSearch already splices the per-message reaction
        // list onto each result via the batched ReactionLoader.
        let query = "reactions:>=\(config.minReactions)"
        let results = try search.search(
            phrase: query,
            limit: config.candidateLimit,
            order: .descending
        )
        let memories = results.map { MemoryMessage(result: $0) }
        return Self.rank(memories, maxResults: config.maxResults)
    }

    // MARK: - Pure ranking

    /// Rank decoded messages by warmth: exclude coordination/RSVP-bait, drop
    /// rows with no reactions, score by warmth (+ genuine-moment boosts), cap
    /// to `maxResults`.
    public static func rank(_ messages: [MemoryMessage], maxResults: Int) -> [BelovedMessage] {
        let scored: [BelovedMessage] = messages.compactMap { m in
            let count = totalReactions(m.reactions)
            guard count > 0 else { return nil }
            // Coordination / reaction-soliciting messages are the RSVP-bait we
            // explicitly don't want surfaced as "beloved," no matter how many
            // tapbacks they piled up.
            if isCoordination(m.body) { return nil }
            return BelovedMessage(
                message: m,
                reactionCount: count,
                warmthScore: score(m.reactions, body: m.body, isGroup: m.isGroup)
            )
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.warmthScore != rhs.warmthScore { return lhs.warmthScore > rhs.warmthScore }
            if lhs.reactionCount != rhs.reactionCount { return lhs.reactionCount > rhs.reactionCount }
            // Tie-break newest-first so the list is deterministic + fresh.
            return lhs.message.date > rhs.message.date
        }
        return Array(sorted.prefix(maxResults))
    }

    /// Total reaction count across all senders/kinds on a message.
    public static func totalReactions(_ reactions: [Reaction]) -> Int {
        reactions.count
    }

    /// Phrases that mark a message as coordination / reaction-soliciting rather
    /// than a genuine moment. Case-insensitive substring match on the decoded
    /// body. These are the "vote with a tapback" / headcount messages that
    /// otherwise dominate a raw reaction-count ranking.
    static let coordinationPhrases: [String] = [
        "react to this", "react if", "like this message",
        "love the message", "love this message",
        "headcount", "head count",
        "if you can make it", "if u are coming", "if you're coming", "if youre coming",
        "rsvp", "final count", "react ❤️", "🤍 if",
    ]

    /// True iff the body looks like coordination / RSVP-bait. PURE.
    public static func isCoordination(_ body: String) -> Bool {
        let low = body.lowercased()
        for phrase in coordinationPhrases where low.contains(phrase) {
            return true
        }
        return false
    }

    /// Warmth score for ranking. Reaction weights (per the tuned spec):
    ///   love 3, laugh 2.5, emphasize 2, like 1, question 0.3, dislike −2.
    /// Custom-emoji / stickers count as mildly warm (someone cared enough to
    /// pick one). On top of the reaction sum we add small GENUINE-MOMENT
    /// boosts: a 1:1 chat (more personal than a group blast) and a real text
    /// body (≥15 chars — an actual thing said, not a logistics one-liner).
    ///
    /// `body` / `isGroup` default so the older two-arg call sites + tests that
    /// only care about reaction weighting still compile.
    public static func score(_ reactions: [Reaction], body: String = "", isGroup: Bool = false) -> Double {
        var s = 0.0
        for r in reactions {
            switch r.kind {
            case .love:        s += 3.0
            case .laugh:       s += 2.5
            case .emphasize:   s += 2.0
            case .customEmoji: s += 1.8
            case .sticker:     s += 1.5
            case .like:        s += 1.0
            case .question:    s += 0.3
            case .dislike:     s -= 2.0
            }
        }
        // Genuine-moment boosts.
        if !isGroup { s += 1.0 }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 15 { s += 1.5 }
        return s
    }
}
