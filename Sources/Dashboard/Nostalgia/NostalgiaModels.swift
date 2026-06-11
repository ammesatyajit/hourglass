//
//  NostalgiaModels.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  Value types produced by the pure detectors (`DormancyDetector`,
//  `MilestoneDetector`, `OnThisDayMatcher`) and the data loaders
//  (`BelovedMessagesLoader`, `OnThisDayLoader`). Everything here is a plain
//  `Sendable` value type so it crosses the background-queue → main-actor
//  boundary cleanly and so the detectors stay trivially unit-testable
//  (no chat.db, no UI).
//
//  Naming convention: these are "memories" the panel resurfaces. The panel
//  groups them into four sections — On This Day, Beloved messages, People you
//  used to talk to (dormant), and Milestones.
//

import Foundation

// MARK: - On This Day

/// One anniversary window to look back at — "today, but N years/months ago".
/// `OnThisDayMatcher` produces these from `now`; `OnThisDayLoader` resolves
/// each to a small set of messages from that day.
public struct AnniversaryWindow: Sendable, Equatable, Identifiable {

    /// How far back this window reaches, in human terms. Drives the section
    /// label ("1 year ago today", "6 months ago").
    public enum Span: Sendable, Equatable, Hashable {
        case yearsAgo(Int)        // 1, 2, 3, …
        case monthsAgo(Int)       // 6 (we only surface the half-year mark)

        /// Short label for the memory card header.
        public var label: String {
            switch self {
            case .yearsAgo(1): return "1 year ago today"
            case .yearsAgo(let n): return "\(n) years ago today"
            case .monthsAgo(let n): return "\(n) months ago today"
            }
        }

        /// Ordering weight — smaller = closer to today. Used to sort the
        /// windows so the most recent memory leads (6 months, then 1 year,
        /// then 2 years, …).
        public var proximityRank: Int {
            switch self {
            case .monthsAgo(let n): return n            // 6 → 6
            case .yearsAgo(let n): return n * 12        // 1y → 12, 2y → 24
            }
        }
    }

    public let span: Span
    /// Local-midnight start of the anniversary day.
    public let dayStart: Date
    /// Exclusive end (start of the following local day).
    public let dayEnd: Date

    public var id: String { "\(span)" }

    public init(span: Span, dayStart: Date, dayEnd: Date) {
        self.span = span
        self.dayStart = dayStart
        self.dayEnd = dayEnd
    }

    /// Closed range usable as a `MessageSearch` `dateRange`.
    public var dateRange: ClosedRange<Date> { dayStart...dayEnd }
}

/// A resolved "on this day" memory — an anniversary window plus the handful
/// of messages we surface from it.
public struct OnThisDayMemory: Sendable, Equatable, Identifiable {
    public let window: AnniversaryWindow
    /// The most interesting messages from that day, already ranked + capped.
    public let messages: [MemoryMessage]
    /// How many real messages were exchanged that day in total (so the card
    /// can say "and 23 more").
    public let totalThatDay: Int

    public var id: String { window.id }

    public init(window: AnniversaryWindow, messages: [MemoryMessage], totalThatDay: Int) {
        self.window = window
        self.messages = messages
        self.totalThatDay = totalThatDay
    }
}

// MARK: - Beloved messages

/// A message that drew a lot of reactions — "remember this?". Ranked by the
/// number of distinct senders who reacted (loves + laughs weigh highest).
public struct BelovedMessage: Sendable, Equatable, Identifiable {
    public let message: MemoryMessage
    /// Total reactions across all senders + kinds.
    public let reactionCount: Int
    /// Score used for ranking (see `BelovedMessagesLoader.score`). Loves &
    /// laughs are weighted above likes so the warmest moments lead.
    public let warmthScore: Double

    public var id: Int64 { message.rowID }

    public init(message: MemoryMessage, reactionCount: Int, warmthScore: Double) {
        self.message = message
        self.reactionCount = reactionCount
        self.warmthScore = warmthScore
    }
}

// MARK: - Dormant friendships

/// A person you used to text a lot and have gone quiet with. Framed neutrally
/// and positively — never with romantic / intimacy language — and always
/// dismissable (see `NostalgiaDismissals`). See `DormancyDetector` for the
/// (deliberately conservative) heuristic + the sensitivity rationale.
public struct DormantFriend: Sendable, Equatable, Identifiable {
    /// The `ContactDailySeries.key` — resolved display name when known, raw
    /// handle otherwise. This is also the dismissal key.
    public let key: String
    public let displayName: String
    public let avatarData: Data?

    /// Total messages exchanged across the whole "active" history window.
    public let historicalTotal: Int
    /// Total messages exchanged in the recent window.
    public let recentTotal: Int
    /// Peak daily-volume month (local), for the "you used to talk a lot
    /// around <month>" copy. Nil if indeterminate.
    public let peakPeriod: Date?
    /// Days since the last message exchanged with this person.
    public let daysSinceLastContact: Int
    /// Ranking strength — higher means a more pronounced fall-off from a
    /// higher historical base. Used to order + cap the list.
    public let dormancyScore: Double

    public var id: String { key }

    public init(
        key: String,
        displayName: String,
        avatarData: Data?,
        historicalTotal: Int,
        recentTotal: Int,
        peakPeriod: Date?,
        daysSinceLastContact: Int,
        dormancyScore: Double
    ) {
        self.key = key
        self.displayName = displayName
        self.avatarData = avatarData
        self.historicalTotal = historicalTotal
        self.recentTotal = recentTotal
        self.peakPeriod = peakPeriod
        self.daysSinceLastContact = daysSinceLastContact
        self.dormancyScore = dormancyScore
    }
}

// MARK: - Rekindle reminders

/// A gentle "you haven't texted <name> in a while" reminder, surfaced ONLY for
/// people who used to be a HEAVY 1:1 correspondent (upper-quartile by message
/// volume) and have gone quiet for ≥1 month. The user asked to be reminded "to
/// text ppl you haven't texted, every month you haven't texted them — only for
/// people that used to be in the top 10 / upper quartile by volume."
///
/// Computed by `RekindleBuilder` over 1:1 chats (`chat.style = 45`). Like every
/// Nostalgia surface it is SUPPRESSED by the user-controlled `hiddenFromNostalgia`
/// set — one tap hides anyone, permanently (no automatic flagging).
/// with a "say hi?" nudge is exactly what the hide model exists to prevent.
public struct RekindleReminder: Sendable, Equatable, Identifiable {
    /// Resolved contact display name — the SAME key scheme the hidden set /
    /// `DormantFriend.key` uses, so suppression reconciles
    /// directly.
    public let name: String
    /// Avatar bytes (raw PNG/JPEG) of the contact, when a photo exists.
    public let avatarData: Data?
    /// Total 1:1 messages exchanged with this person (real messages only —
    /// `associated_message_type = 0`).
    public let volume: Int
    /// Date of the last message exchanged in the 1:1 chat.
    public let lastDate: Date
    /// Whole months since `lastDate` (floor(days / 30), ≥ 1). Drives the
    /// "~N months ago" copy and the monthly re-nudge cadence.
    public let monthsSince: Int

    public var id: String { name }

    public init(name: String, avatarData: Data?, volume: Int, lastDate: Date, monthsSince: Int) {
        self.name = name
        self.avatarData = avatarData
        self.volume = volume
        self.lastDate = lastDate
        self.monthsSince = monthsSince
    }
}

// MARK: - Milestones

/// A detectable structural event in your history with a person (or group).
/// Surfaced as a timeline of "firsts" and "anniversaries".
public struct Milestone: Sendable, Equatable, Identifiable {

    public enum Kind: Sendable, Equatable, Hashable {
        /// First message ever exchanged with this person/chat.
        case firstMessage
        /// Crossed a round message count (1k, 5k, 10k, …).
        case messageCount(Int)
        /// Texting ramped UP sharply and stayed up — a sustained step-change.
        case rampUp
        /// A full-year anniversary of the first message ("3 years of texting").
        case anniversary(years: Int)

        public var label: String {
            switch self {
            case .firstMessage: return "First message"
            case .messageCount(let n): return "\(NostalgiaFormat.compact(n)) messages"
            case .rampUp: return "Started talking a lot more"
            case .anniversary(let y): return y == 1 ? "1 year of messages" : "\(y) years of messages"
            }
        }

        /// SF Symbol for the timeline dot.
        public var symbol: String {
            switch self {
            case .firstMessage: return "sparkles"
            case .messageCount: return "number"
            case .rampUp: return "chart.line.uptrend.xyaxis"
            case .anniversary: return "gift"
            }
        }
    }

    public let kind: Kind
    /// When the milestone occurred (local).
    public let date: Date
    /// For ordering when two milestones land the same instant.
    public let secondarySort: Int

    public var id: String { "\(kind)-\(date.timeIntervalSinceReferenceDate)" }

    public init(kind: Kind, date: Date, secondarySort: Int = 0) {
        self.kind = kind
        self.date = date
        self.secondarySort = secondarySort
    }
}

/// All milestones for one contact, with the contact's identity for display.
public struct ContactMilestones: Sendable, Equatable, Identifiable {
    public let key: String
    public let displayName: String
    public let avatarData: Data?
    /// Sorted ascending by date.
    public let milestones: [Milestone]
    /// Total messages exchanged all-time (for the headline).
    public let totalMessages: Int

    public var id: String { key }

    public init(
        key: String,
        displayName: String,
        avatarData: Data?,
        milestones: [Milestone],
        totalMessages: Int
    ) {
        self.key = key
        self.displayName = displayName
        self.avatarData = avatarData
        self.milestones = milestones
        self.totalMessages = totalMessages
    }
}

// MARK: - MemoryMessage (a display-ready, decoded message row)

/// A decoded message ready to render in a memory card. A thin projection of
/// `MessageSearch.Result` so the view layer never touches chat.db rows. Kept
/// `Sendable` so it crosses actor boundaries.
public struct MemoryMessage: Sendable, Equatable, Identifiable {
    public let rowID: Int64
    public let guid: String?
    public let date: Date
    public let isFromMe: Bool
    /// Decoded body text. May be empty for attachment-only messages.
    public let body: String
    /// "You" / contact name / raw handle.
    public let senderName: String
    /// Resolved name of the other party / chat label.
    public let partnerName: String
    /// `chat.guid` for reveal-in-Messages.
    public let chatGUID: String?
    /// True for group chats (style 43).
    public let isGroup: Bool
    /// Reactions on this message (already loaded by `MessageSearch`).
    public let reactions: [Reaction]
    public let avatarData: Data?

    public var id: Int64 { rowID }

    public init(
        rowID: Int64,
        guid: String?,
        date: Date,
        isFromMe: Bool,
        body: String,
        senderName: String,
        partnerName: String,
        chatGUID: String?,
        isGroup: Bool,
        reactions: [Reaction],
        avatarData: Data?
    ) {
        self.rowID = rowID
        self.guid = guid
        self.date = date
        self.isFromMe = isFromMe
        self.body = body
        self.senderName = senderName
        self.partnerName = partnerName
        self.chatGUID = chatGUID
        self.isGroup = isGroup
        self.reactions = reactions
        self.avatarData = avatarData
    }

    /// Build from a `MessageSearch.Result`.
    public init(result: MessageSearch.Result) {
        self.rowID = result.message.id
        self.guid = result.message.guid
        self.date = result.message.date
        self.isFromMe = result.message.isFromMe
        self.body = result.message.body
        self.senderName = result.senderName
        self.partnerName = result.partnerName
        self.chatGUID = result.chatGUID
        self.isGroup = result.message.chatStyle == 43
        self.reactions = result.reactions
        self.avatarData = result.senderAvatar
    }
}

// MARK: - Number formatting

/// Compact number formatting shared by the milestone labels + counts.
public enum NostalgiaFormat {
    /// 1000 → "1k", 5000 → "5k", 12500 → "12.5k", 1_000_000 → "1M".
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000:
            return "\(n)"
        case ..<1_000_000:
            let k = Double(n) / 1_000
            // Whole thousands print without a decimal.
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        default:
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }
}
