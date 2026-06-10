//
//  FunnyMomentsLoader.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  "The funniest exchanges" — short bursts of messages that drew a dense
//  cluster of AMUSED reactions from other people. Loaded from chat.db: we need
//  the reaction join, message timing, and decoded bodies.
//
//  Amused reactions = love (2000), laugh (2003), emphasize (2004) added by
//  SOMEONE ELSE (is_from_me = 0). Those three are the "this is great / this is
//  hilarious" tapbacks; like/question/dislike aren't amusement.
//
//  Pipeline:
//    1. SQL: pull every amused tapback from others, joined back to its TARGET
//       message (chat, date, sender, body) by stripping the positional prefix
//       off `associated_message_guid` (substring after the last "/") and
//       matching `message.guid`. One pass; reaction count per target message
//       falls out of the GROUP BY.
//    2. Swift windowing (PURE, testable): within each chat, sort reacted
//       messages by time and greedily group those within ~30 min and ≤8
//       messages into a window. A window's score is the SUM of amused
//       reactions across its messages; its "trigger" is the single message
//       that earned the most.
//    3. Rank windows by amused-reaction density, keep the top N, one per
//       trigger.
//

import Foundation

public struct FunnyMomentsLoader: Sendable {

    public struct Config: Sendable, Equatable {
        /// How many funny moments to surface.
        public var maxResults: Int = 6
        /// Window width — messages this far apart (seconds) belong to different
        /// moments. ~30 minutes.
        public var windowSeconds: TimeInterval = 30 * 60
        /// Max reacted-messages grouped into one window. Keeps a long, steadily
        /// funny thread from collapsing into a single mega-moment.
        public var maxWindowMessages: Int = 8
        /// A window needs at least this many amused reactions total to count as
        /// a "moment" (one stray laugh isn't a story).
        public var minAmusedReactions: Int = 3
        /// Exclude coordination / RSVP-bait bodies (headcounts, "love the
        /// message if you're coming") — those collect ❤️ as votes, not laughs.
        /// On by default; reuses `BelovedMessagesLoader.isCoordination`.
        public var excludeCoordination: Bool = true

        public init() {}
    }

    // `internal` (not `private`) so the GRDB adapter in `FunnyMomentsLoader+DB`
    // — a separate file that keeps GRDB out of this core — can read them.
    let database: ChatDatabase
    let contacts: ResolvedContacts
    let config: Config

    public init(database: ChatDatabase, contacts: ResolvedContacts, config: Config = Config()) {
        self.database = database
        self.contacts = contacts
        self.config = config
    }

    // MARK: - A reacted message (intermediate, pre-windowing)

    /// One message that drew ≥1 amused reaction from others, with the count.
    /// PURE value type so the windowing logic is testable without chat.db.
    public struct ReactedMessage: Sendable, Equatable {
        public let rowID: Int64
        public let chatID: Int64
        public let date: Date
        public let amusedCount: Int
        public let body: String
        public let isFromMe: Bool
        public let senderHandle: String?
        public let chatStyle: Int?
        public let chatDisplayName: String?
        public let chatGUID: String?

        public init(
            rowID: Int64,
            chatID: Int64,
            date: Date,
            amusedCount: Int,
            body: String,
            isFromMe: Bool,
            senderHandle: String?,
            chatStyle: Int?,
            chatDisplayName: String?,
            chatGUID: String?
        ) {
            self.rowID = rowID
            self.chatID = chatID
            self.date = date
            self.amusedCount = amusedCount
            self.body = body
            self.isFromMe = isFromMe
            self.senderHandle = senderHandle
            self.chatStyle = chatStyle
            self.chatDisplayName = chatDisplayName
            self.chatGUID = chatGUID
        }
    }

    /// A grouped window of reacted messages — PURE intermediate. The trigger is
    /// the highest-amused message; `totalAmused` is the window density signal.
    public struct Window: Sendable, Equatable {
        public let chatID: Int64
        public let totalAmused: Int
        public let trigger: ReactedMessage
        public init(chatID: Int64, totalAmused: Int, trigger: ReactedMessage) {
            self.chatID = chatID
            self.totalAmused = totalAmused
            self.trigger = trigger
        }
    }

    /// Build the funniest-moments list. Synchronous + throwing — call off-main.
    public func load() throws -> [FunnyMoment] {
        let reacted = try fetchReactedMessages()
        let windows = Self.windows(from: reacted, config: config)
        return windows.prefix(config.maxResults).map { window in
            let t = window.trigger
            let senderName: String
            let senderAvatar: Data?
            if t.isFromMe {
                senderName = "You"
                senderAvatar = nil
            } else if let raw = t.senderHandle {
                senderName = contacts.name(forRawHandle: raw)
                senderAvatar = contacts.avatarData(forRawHandle: raw)
            } else {
                senderName = "(unknown)"
                senderAvatar = nil
            }
            let isGroup = t.chatStyle == 43
            let partner = Self.partnerLabel(
                isGroup: isGroup,
                chatDisplayName: t.chatDisplayName,
                senderName: senderName,
                isFromMe: t.isFromMe
            )
            return FunnyMoment(
                triggerRowID: t.rowID,
                body: t.body,
                senderName: senderName,
                senderAvatar: senderAvatar,
                partnerName: partner,
                isGroup: isGroup,
                date: t.date,
                amusedReactionCount: window.totalAmused,
                chatGUID: t.chatGUID
            )
        }
    }

    // MARK: - Pure windowing

    /// Group reacted messages into time/size-bounded windows per chat, score
    /// each by total amused reactions, and return windows ranked by density
    /// (highest first), de-duplicated so the same chat doesn't dominate the
    /// list with overlapping windows. PURE — no DB, fully testable.
    public static func windows(
        from reacted: [ReactedMessage],
        config: Config
    ) -> [Window] {
        // Drop coordination / RSVP-bait BEFORE windowing. A "headcount, please
        // love the message if you can make it" rakes in dozens of ❤️ tapbacks
        // as VOTES, not amusement — exactly the false positive the beloved
        // ranker also excludes. Reuse that exclusion so a logistics blast never
        // masquerades as the funniest exchange.
        let candidates = config.excludeCoordination
            ? reacted.filter { !BelovedMessagesLoader.isCoordination($0.body) }
            : reacted

        // Bucket by chat.
        var byChat: [Int64: [ReactedMessage]] = [:]
        for r in candidates { byChat[r.chatID, default: []].append(r) }

        var result: [Window] = []
        for (chatID, msgsUnsorted) in byChat {
            let msgs = msgsUnsorted.sorted { $0.date < $1.date }
            var i = 0
            while i < msgs.count {
                // Greedily extend a window from msgs[i] while within the time
                // span AND under the size cap.
                var j = i
                var total = msgs[i].amusedCount
                var trigger = msgs[i]
                let windowStart = msgs[i].date
                while j + 1 < msgs.count {
                    let next = msgs[j + 1]
                    if next.date.timeIntervalSince(windowStart) > config.windowSeconds { break }
                    if (j - i + 1) >= config.maxWindowMessages { break }
                    j += 1
                    total += next.amusedCount
                    // Trigger = the message with the most amused reactions;
                    // ties broken toward the earlier message (it started it).
                    if next.amusedCount > trigger.amusedCount { trigger = next }
                }
                if total >= config.minAmusedReactions {
                    result.append(Window(chatID: chatID, totalAmused: total, trigger: trigger))
                }
                i = j + 1
            }
        }

        result.sort { lhs, rhs in
            if lhs.totalAmused != rhs.totalAmused { return lhs.totalAmused > rhs.totalAmused }
            // Tie-break: newer trigger first, then rowID for determinism.
            if lhs.trigger.date != rhs.trigger.date { return lhs.trigger.date > rhs.trigger.date }
            return lhs.trigger.rowID > rhs.trigger.rowID
        }
        return result
    }

    /// Display label for the chat the moment happened in. PURE.
    static func partnerLabel(
        isGroup: Bool,
        chatDisplayName: String?,
        senderName: String,
        isFromMe: Bool
    ) -> String {
        if isGroup, let name = chatDisplayName, !name.isEmpty { return name }
        if isGroup { return "Group" }
        // 1:1 — the partner is the sender (when received) or the person you
        // sent to. For received we already have their name; for sent we don't
        // carry the partner handle here, so fall back to a neutral label.
        if !isFromMe { return senderName }
        return ""
    }

}
