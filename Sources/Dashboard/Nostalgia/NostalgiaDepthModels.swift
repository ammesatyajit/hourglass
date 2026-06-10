//
//  NostalgiaDepthModels.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  "Depth detector" value types — the second wave of Nostalgia surfaces beyond
//  the original four (On This Day, Beloved, Dormant, Milestones):
//
//    • Streak       — your longest run of consecutive days texting one person.
//    • FirstMessage — the very first thing you ever said to someone.
//    • Era          — who you talked to most, season by season.
//    • FunnyMoment  — the densest bursts of amused reactions.
//
//  Everything here is a plain `Sendable` value type so it crosses the
//  background-queue → main-actor boundary cleanly and keeps the pure builders
//  (`StreakDetector`, `EraDetector`, …) trivially unit-testable (no chat.db,
//  no UI). Mirrors the conventions in `NostalgiaModels.swift`.
//

import Foundation

// MARK: - Longest streaks

/// The longest run of consecutive calendar days on which you exchanged at
/// least one message with a single contact. Produced by `StreakDetector` from
/// the per-contact daily series — pure, no DB.
public struct Streak: Sendable, Equatable, Identifiable {
    /// `ContactDailySeries.key` — resolved display name when known, raw handle
    /// otherwise.
    public let key: String
    public let displayName: String
    public let avatarData: Data?
    /// Length of the longest consecutive-day run, in days (≥ 1).
    public let length: Int
    /// Local-midnight date of the first day in the run.
    public let startDate: Date
    /// Local-midnight date of the last day in the run.
    public let endDate: Date

    public var id: String { key }

    public init(
        key: String,
        displayName: String,
        avatarData: Data?,
        length: Int,
        startDate: Date,
        endDate: Date
    ) {
        self.key = key
        self.displayName = displayName
        self.avatarData = avatarData
        self.length = length
        self.startDate = startDate
        self.endDate = endDate
    }
}

// MARK: - First message with each person

/// The very first message exchanged with a contact — "your first words." Loaded
/// from chat.db (we need the decoded body + exact instant) for the user's top
/// contacts by all-time volume.
public struct FirstMessage: Sendable, Equatable, Identifiable {
    /// Resolved contact display name (the loader only surfaces resolved
    /// contacts so this is a real name, never a raw handle).
    public let displayName: String
    public let avatarData: Data?
    /// Decoded body of the first message. May be empty for an attachment-only
    /// opener — the loader still surfaces it (with an attachment marker handled
    /// at display time) because "the first thing" is the point.
    public let body: String
    /// True if YOU sent the opener, false if they did.
    public let isFromMe: Bool
    /// When the first message was sent.
    public let date: Date
    /// Total all-time messages with this contact (for ordering / a headline).
    public let totalMessages: Int

    public var id: String { displayName }

    public init(
        displayName: String,
        avatarData: Data?,
        body: String,
        isFromMe: Bool,
        date: Date,
        totalMessages: Int
    ) {
        self.displayName = displayName
        self.avatarData = avatarData
        self.body = body
        self.isFromMe = isFromMe
        self.date = date
        self.totalMessages = totalMessages
    }
}

// MARK: - Eras ("your person" each season)

/// One season/quarter of your history and the person you exchanged the most
/// messages with during it — a timeline of "your person" over time. Produced
/// by `EraDetector` from the per-contact daily series, pure.
public struct Era: Sendable, Equatable, Identifiable {
    /// First calendar year of the quarter (e.g. 2024).
    public let year: Int
    /// Quarter index 1…4 (Q1 = Jan–Mar). Drives the season label.
    public let quarter: Int
    /// Local-midnight start of the quarter.
    public let startDate: Date
    /// `ContactDailySeries.key` of the most-messaged contact this quarter.
    public let topContactKey: String
    public let topContactName: String
    public let topContactAvatar: Data?
    /// Messages exchanged with the top contact during the quarter.
    public let messageCount: Int

    public var id: String { "\(year)-Q\(quarter)" }

    /// Season label — "Winter 2024", "Spring 2024", etc. Northern-hemisphere
    /// meteorological seasons keyed off the quarter (Q1=Winter, Q2=Spring,
    /// Q3=Summer, Q4=Fall). A neutral, broadly-recognizable framing.
    public var seasonLabel: String {
        let season: String
        switch quarter {
        case 1: season = "Winter"
        case 2: season = "Spring"
        case 3: season = "Summer"
        default: season = "Fall"
        }
        return "\(season) \(year)"
    }

    public init(
        year: Int,
        quarter: Int,
        startDate: Date,
        topContactKey: String,
        topContactName: String,
        topContactAvatar: Data?,
        messageCount: Int
    ) {
        self.year = year
        self.quarter = quarter
        self.startDate = startDate
        self.topContactKey = topContactKey
        self.topContactName = topContactName
        self.topContactAvatar = topContactAvatar
        self.messageCount = messageCount
    }
}

// MARK: - Funniest exchanges

/// A short window of messages (a handful within ~30 min) that drew a dense
/// cluster of amused reactions (loves / laughs / emphasis from OTHERS). The
/// "trigger" is the message that earned the most amused tapbacks in the
/// window. Loaded from chat.db (raw reaction join + windowing).
public struct FunnyMoment: Sendable, Equatable, Identifiable {
    /// `message.ROWID` of the trigger message (stable id within a DB).
    public let triggerRowID: Int64
    /// Decoded body of the trigger message. May be empty (an attachment that
    /// made everyone laugh) — handled at display time.
    public let body: String
    /// "You" / contact name / raw handle — who sent the funny thing.
    public let senderName: String
    public let senderAvatar: Data?
    /// Resolved chat label (partner name for 1:1, group name for groups).
    public let partnerName: String
    public let isGroup: Bool
    /// When the trigger message was sent.
    public let date: Date
    /// Count of amused reactions across the WINDOW (the density signal).
    public let amusedReactionCount: Int
    /// `chat.guid` for reveal-in-Messages.
    public let chatGUID: String?

    public var id: Int64 { triggerRowID }

    public init(
        triggerRowID: Int64,
        body: String,
        senderName: String,
        senderAvatar: Data?,
        partnerName: String,
        isGroup: Bool,
        date: Date,
        amusedReactionCount: Int,
        chatGUID: String?
    ) {
        self.triggerRowID = triggerRowID
        self.body = body
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.partnerName = partnerName
        self.isGroup = isGroup
        self.date = date
        self.amusedReactionCount = amusedReactionCount
        self.chatGUID = chatGUID
    }
}
