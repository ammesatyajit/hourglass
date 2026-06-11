//
//  ChatStoryBuilder.swift
//  Hourglass — Dashboard / Nostalgia (per-chat "notable moments")
//
//  The PURE core that turns a chat's raw rows into a `ChatStory` of
//  `NotableMoment`s. No chat.db, no GRDB, no UI — value types in, value types
//  out — so every heuristic (sessionization, biggest-day, peak-reaction
//  selection, membership folding) is unit-testable against synthetic fixtures.
//  The DB scan that produces the inputs lives in `ChatStoryBuilder+DB.swift`.
//
//  Validated against the reference prototypes:
//    • Longest conversation = `/tmp/convo/main.swift` — sessionize a chat's
//      messages where a gap > 45 min splits a session; the longest session by
//      message count, plus its wall-clock duration.
//    • Membership timeline = `/tmp/haotl/main.swift` — `item_type = 1`
//      add/remove (`group_action_type` 0 = add / 1 = remove,
//      `other_handle → handle.id → name`) + `item_type = 3` renames, deduped by
//      message ROWID; recreated same-named threads merged into one story.
//

import Foundation

public enum ChatStoryBuilder {

    public struct Config: Sendable, Equatable {
        /// A chat needs at least this many real messages to get a story. Below
        /// this it isn't a conversation worth reminiscing about.
        public var minMessages: Int = 200
        /// Sessionization gap: a silence longer than this splits one "sitting"
        /// from the next. 45 min, matching the `/tmp/convo` prototype.
        public var sessionGap: TimeInterval = 45 * 60
        /// A peak-reaction message must clear this many reactions to surface (a
        /// single stray tapback isn't "the" reacted moment).
        public var minPeakReactions: Int = 2

        public init() {}
    }

    // MARK: - Raw inputs (PURE intermediates — produced by the DB adapter)

    /// One real message in a chat, decoded + flattened. The builder needs the
    /// instant, who, body, and reaction count; nothing chat.db-specific.
    public struct RawMessage: Sendable, Equatable {
        public let rowID: Int64
        public let date: Date
        public let isFromMe: Bool
        /// Resolved sender name ("You" / contact name / raw handle).
        public let senderName: String
        public let body: String
        /// Number of GENUINE reactions on this message (already excludes
        /// removed reactions; the builder applies the coordination/URL filter).
        public let reactionCount: Int
        /// The single warmest reaction glyph on the message (for the peak
        /// headline, e.g. "❤️"). Nil when no reactions.
        public let topReactionEmoji: String?
        /// `message.guid` — carries through to the moment so the UI can
        /// deep-link the exact message in Messages.app. Nil in old fixtures.
        public let guid: String?

        public init(
            rowID: Int64,
            date: Date,
            isFromMe: Bool,
            senderName: String,
            body: String,
            reactionCount: Int,
            topReactionEmoji: String?,
            guid: String? = nil
        ) {
            self.rowID = rowID
            self.date = date
            self.isFromMe = isFromMe
            self.senderName = senderName
            self.body = body
            self.reactionCount = reactionCount
            self.topReactionEmoji = topReactionEmoji
            self.guid = guid
        }
    }

    /// A membership / rename event in a group chat (`item_type` 1 or 3).
    public struct RawEvent: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case added(person: String)      // group_action_type 0
            case removed(person: String)    // group_action_type 1
            case renamed(title: String)     // item_type 3
        }
        public let rowID: Int64
        public let date: Date
        /// Who performed the action ("You" / name). For the headline.
        public let actor: String
        public let kind: Kind

        public init(rowID: Int64, date: Date, actor: String, kind: Kind) {
            self.rowID = rowID
            self.date = date
            self.actor = actor
            self.kind = kind
        }
    }

    /// Everything the builder needs about one chat (possibly the union of
    /// several recreated same-named threads). Identity + metadata + the raw
    /// message/event streams.
    public struct RawChat: Sendable, Equatable {
        public let chatRowID: Int64
        public let title: String
        public let isGroup: Bool
        public let participantCount: Int
        public let avatarData: Data?
        public let messages: [RawMessage]
        public let events: [RawEvent]

        public init(
            chatRowID: Int64,
            title: String,
            isGroup: Bool,
            participantCount: Int,
            avatarData: Data?,
            messages: [RawMessage],
            events: [RawEvent]
        ) {
            self.chatRowID = chatRowID
            self.title = title
            self.isGroup = isGroup
            self.participantCount = participantCount
            self.avatarData = avatarData
            self.messages = messages
            self.events = events
        }
    }

    // MARK: - Build one story

    /// Build a `ChatStory` from one chat's raw inputs, or nil if it doesn't
    /// clear the activity floor. PURE.
    public static func buildStory(
        from chat: RawChat,
        calendar: Calendar,
        config: Config = Config(),
        globalRange: ClosedRange<Date>? = nil
    ) -> ChatStory? {
        let msgs = chat.messages.sorted { $0.date < $1.date }
        guard msgs.count >= config.minMessages, let first = msgs.first, let last = msgs.last else {
            return nil
        }

        var moments: [NotableMoment] = []

        // 1) origin — the first message.
        moments.append(originMoment(first))

        // 2) longestConversation — the longest gap-bounded session.
        if let lc = longestConversationMoment(msgs, config: config) {
            moments.append(lc)
        }

        // 3) biggestDay — the calendar day with the most messages.
        if let bd = biggestDayMoment(msgs, calendar: calendar) {
            moments.append(bd)
        }

        // 4) peakReaction — the single most-reacted GENUINE message.
        if let pr = peakReactionMoment(msgs, isGroup: chat.isGroup, config: config) {
            moments.append(pr)
        }

        // 5) groups only: membership / rename events.
        if chat.isGroup {
            moments.append(contentsOf: membershipMoments(chat.events, calendar: calendar))
        }

        moments.sort { $0.date < $1.date }

        return ChatStory(
            chatRowID: chat.chatRowID,
            title: chat.title,
            isGroup: chat.isGroup,
            participantCount: chat.participantCount,
            messageCount: msgs.count,
            firstDate: first.date,
            lastDate: last.date,
            avatarData: chat.avatarData,
            moments: moments,
            activity: activityHistogram(
                msgs, range: globalRange ?? (first.date...last.date)
            )
        )
    }

    /// Message counts in `Config.activityBuckets` equal time buckets over
    /// `range` — the row-background sparkline. The range is the GLOBAL corpus
    /// span so every row shares one x-axis.
    static func activityHistogram(
        _ msgs: [RawMessage],
        range: ClosedRange<Date>,
        buckets: Int = 80
    ) -> [Double] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0, !msgs.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: buckets)
        for m in msgs {
            let t = m.date.timeIntervalSince(range.lowerBound) / span
            let idx = min(buckets - 1, max(0, Int(t * Double(buckets))))
            out[idx] += 1
        }
        return out
    }

    /// Build + rank stories for many chats. Sorted by `messageCount` desc — the
    /// chats worth reminiscing about lead.
    public static func buildStories(
        from chats: [RawChat],
        calendar: Calendar,
        config: Config = Config()
    ) -> [ChatStory] {
        // One shared x-axis for every sparkline: the whole corpus's span.
        let allDates = chats.lazy.flatMap(\.messages).map(\.date)
        let globalRange: ClosedRange<Date>? = allDates.min().flatMap { lo in
            allDates.max().map { hi in lo...hi }
        }
        var out = chats.compactMap {
            buildStory(from: $0, calendar: calendar, config: config, globalRange: globalRange)
        }
        out.sort { lhs, rhs in
            if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            // Tie-break: more recent activity first, then title for determinism.
            if lhs.lastDate != rhs.lastDate { return lhs.lastDate > rhs.lastDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return out
    }

    // MARK: - Individual moment builders (PURE)

    static func originMoment(_ first: RawMessage) -> NotableMoment {
        let who = first.isFromMe ? "You" : first.senderName
        return NotableMoment(
            kind: .origin,
            date: first.date,
            headline: "It started here",
            detail: "\(who) · \(MomentFormat.day(first.date))",
            example: first.body,
            person: first.isFromMe ? nil : first.senderName,
            messageGUID: first.guid
        )
    }

    /// The longest gap-bounded session. Ported from `/tmp/convo`: walk the
    /// time-sorted messages, extend a session while consecutive gaps are
    /// ≤ `sessionGap`, track the session with the most messages. Returns nil for
    /// a trivial (single-message) best — not a "conversation."
    static func longestConversationMoment(
        _ msgs: [RawMessage],
        config: Config
    ) -> NotableMoment? {
        guard let best = longestSession(msgs, gap: config.sessionGap), best.count >= 2 else {
            return nil
        }
        let minutes = Int((best.end.timeIntervalSince(best.start)) / 60)
        let durationText = MomentFormat.duration(minutes: minutes)
        return NotableMoment(
            kind: .longestConversation,
            date: best.start,
            headline: "\(best.count) messages in one sitting",
            detail: "over \(durationText) · \(MomentFormat.day(best.start))"
        )
    }

    /// PURE sessionization core. Returns the highest-message-count session as
    /// (count, start, end), or nil for empty input. Exposed for unit tests.
    public static func longestSession(
        _ msgs: [RawMessage],
        gap: TimeInterval
    ) -> (count: Int, start: Date, end: Date)? {
        guard !msgs.isEmpty else { return nil }
        // Defensive sort — callers pass sorted, tests may not.
        let ms = msgs.sorted { $0.date < $1.date }
        var bestCount = 0
        var bestStart = ms[0].date
        var bestEnd = ms[0].date

        var i = 0
        while i < ms.count {
            var j = i
            while j + 1 < ms.count && ms[j + 1].date.timeIntervalSince(ms[j].date) <= gap {
                j += 1
            }
            let count = j - i + 1
            if count > bestCount {
                bestCount = count
                bestStart = ms[i].date
                bestEnd = ms[j].date
            }
            i = j + 1
        }
        return (bestCount, bestStart, bestEnd)
    }

    /// The calendar day with the most messages. Buckets by local day; the
    /// moment's date is local-midnight of that day.
    static func biggestDayMoment(
        _ msgs: [RawMessage],
        calendar: Calendar
    ) -> NotableMoment? {
        guard let (dayStart, count) = biggestDay(msgs, calendar: calendar), count >= 2 else {
            return nil
        }
        return NotableMoment(
            kind: .biggestDay,
            date: dayStart,
            headline: "\(count) messages in a day",
            detail: MomentFormat.day(dayStart)
        )
    }

    /// PURE biggest-day core. Returns (local-midnight day, message count) of the
    /// busiest day, or nil for empty input. Exposed for unit tests.
    public static func biggestDay(
        _ msgs: [RawMessage],
        calendar: Calendar
    ) -> (dayStart: Date, count: Int)? {
        guard !msgs.isEmpty else { return nil }
        var counts: [Date: Int] = [:]
        for m in msgs {
            let day = calendar.startOfDay(for: m.date)
            counts[day, default: 0] += 1
        }
        guard let winner = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // Tie-break: earlier day wins (more deterministic; "first time it
            // got that busy"). max() keeps the LARGER element, so the earlier
            // date must compare as larger.
            return lhs.key > rhs.key
        }) else { return nil }
        return (winner.key, winner.value)
    }

    /// The single most-reacted GENUINE message. Excludes coordination/RSVP-bait
    /// (reusing `BelovedMessagesLoader.isCoordination`) and URL-only bodies.
    /// Among ties, prefers a real text body. PURE.
    static func peakReactionMoment(
        _ msgs: [RawMessage],
        isGroup: Bool,
        config: Config
    ) -> NotableMoment? {
        let candidates = msgs.filter { m in
            guard m.reactionCount >= config.minPeakReactions else { return false }
            if BelovedMessagesLoader.isCoordination(m.body) { return false }
            if isURLOnly(m.body) { return false }
            return true
        }
        guard let top = candidates.max(by: { lhs, rhs in
            if lhs.reactionCount != rhs.reactionCount { return lhs.reactionCount < rhs.reactionCount }
            // Tie-break: prefer a substantive text body, then newer.
            let lText = lhs.body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 15
            let rText = rhs.body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 15
            if lText != rText { return rText }          // want the textful one as max
            return lhs.date < rhs.date
        }) else { return nil }

        let who = top.isFromMe ? "You" : top.senderName
        let glyph = top.topReactionEmoji ?? "❤️"
        let countWord = top.reactionCount == 1 ? "reaction" : "reactions"
        return NotableMoment(
            kind: .peakReaction,
            date: top.date,
            headline: "\(glyph) \(top.reactionCount) \(countWord)",
            detail: "\(who) · \(MomentFormat.day(top.date))",
            example: top.body,
            person: top.isFromMe ? nil : top.senderName,
            messageGUID: top.guid,
            idDiscriminator: String(top.rowID)
        )
    }

    /// Group membership + rename moments. Deduped by event ROWID upstream, AND
    /// collapsed by (semantic kind + subject + calendar day) here: recreated
    /// same-named threads each log the SAME real-world event with a DIFFERENT
    /// ROWID, so folding threads otherwise double-counts every join/leave. We
    /// keep the first occurrence per (kind, subject, day). PURE.
    static func membershipMoments(_ events: [RawEvent], calendar: Calendar) -> [NotableMoment] {
        var out: [NotableMoment] = []
        out.reserveCapacity(events.count)
        var seenSemantic = Set<String>()
        // Process oldest-first so the kept occurrence is the earliest.
        for e in events.sorted(by: { $0.date < $1.date }) {
            let dayKey = String(Int(calendar.startOfDay(for: e.date).timeIntervalSinceReferenceDate))
            let semanticKey: String
            switch e.kind {
            case .added(let p): semanticKey = "add|\(p)|\(dayKey)"
            case .removed(let p): semanticKey = "rem|\(p)|\(dayKey)"
            case .renamed(let t): semanticKey = "ren|\(t)|\(dayKey)"
            }
            guard seenSemantic.insert(semanticKey).inserted else { continue }
            switch e.kind {
            case .added(let person):
                // Skip self-adds that carry no useful "who" (actor adding
                // themselves / unknown) — they read as noise.
                guard !person.isEmpty, person != "?" else { continue }
                let headline = e.actor == "You"
                    ? "You added \(person)"
                    : (e.actor.isEmpty || e.actor == "?"
                        ? "\(person) joined"
                        : "\(e.actor) added \(person)")
                out.append(NotableMoment(
                    kind: .joined,
                    date: e.date,
                    headline: headline,
                    detail: MomentFormat.day(e.date),
                    person: person,
                    idDiscriminator: String(e.rowID)
                ))
            case .removed(let person):
                let subject = (person.isEmpty || person == "?") ? e.actor : person
                guard !subject.isEmpty, subject != "?" else { continue }
                out.append(NotableMoment(
                    kind: .left,
                    date: e.date,
                    headline: "\(subject) left",
                    detail: MomentFormat.day(e.date),
                    person: subject,
                    idDiscriminator: String(e.rowID)
                ))
            case .renamed(let title):
                guard !title.isEmpty else { continue }
                let headline = e.actor == "You"
                    ? "You renamed it \u{201C}\(title)\u{201D}"
                    : "Renamed \u{201C}\(title)\u{201D}"
                out.append(NotableMoment(
                    kind: .renamed,
                    date: e.date,
                    headline: headline,
                    detail: MomentFormat.day(e.date),
                    idDiscriminator: String(e.rowID)
                ))
            }
        }
        return out
    }

    // MARK: - Text helpers (PURE)

    /// True if the body is nothing but a URL (or whitespace + a URL). A reacted
    /// link is rarely "the moment" we want to resurface as a memory.
    static func isURLOnly(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let low = trimmed.lowercased()
        guard low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("www.") else {
            return false
        }
        // A single token (no internal whitespace) starting with a scheme ⇒
        // URL-only. "check this http://…" has a space and is kept.
        return !trimmed.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" })
    }
}

// MARK: - Formatting

/// Date / duration formatting shared by the moment builders. Centralized so the
/// strings are consistent and the builders stay readable.
enum MomentFormat {

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// "4h 26m" / "47m" / "2h". 0 minutes → "under a minute".
    static func duration(minutes: Int) -> String {
        guard minutes > 0 else { return "under a minute" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
