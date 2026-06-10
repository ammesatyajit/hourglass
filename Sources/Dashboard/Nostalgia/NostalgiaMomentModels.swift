//
//  NostalgiaMomentModels.swift
//  Hourglass — Dashboard / Nostalgia (per-chat "notable moments")
//
//  The third generation of Nostalgia. The earlier two waves produced GENERIC,
//  cross-chat aggregates (On This Day, Beloved, Dormant, Milestones, Streaks,
//  Eras, Funny). This wave reframes everything as PER-CHAT "notable moments"
//  timelines — for each conversation worth reminiscing about (group OR 1:1), a
//  small ranked set of `NotableMoment`s arranged on a timeline (`ChatStory`).
//
//  Everything here is a plain `Sendable` value type so it crosses the
//  background-queue → main-actor boundary cleanly and keeps the builders pure +
//  unit-testable (no chat.db, no UI). Mirrors the conventions in
//  `NostalgiaModels.swift` / `NostalgiaDepthModels.swift`.
//
//  WHAT A MOMENT IS (and what was CUT to get here):
//    • origin             — the first message ever in this chat.
//    • longestConversation — the longest gap-bounded "sitting" (sessionized:
//                            split where a gap > ~45 min; longest by message
//                            count). REPLACES the old "N days straight" streak.
//    • biggestDay         — the calendar day with the most messages.
//    • peakReaction       — the single most-reacted GENUINE message (folds the
//                            old "funniest" + "beloved" into ONE; excludes
//                            coordination/RSVP-bait + URLs).
//    • joined / left / renamed — group membership events (groups only).
//
//    CUT (no longer surfaced anywhere): eras, day-streaks, generic milestones.
//

import Foundation

// MARK: - NotableMoment

/// One notable thing that happened in a chat — a single dot on the chat's
/// timeline. The kind drives the icon/treatment; `headline`/`detail`/`example`
/// are pre-rendered display strings so the view layer never re-derives copy
/// from raw counts. PURE value type.
public struct NotableMoment: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        /// First message ever exchanged in this chat.
        case origin
        /// The longest single uninterrupted conversation (gap-bounded session).
        case longestConversation
        /// The calendar day with the most messages.
        case biggestDay
        /// The single most-reacted genuine message.
        case peakReaction
        /// A person was added to the group.
        case joined
        /// A person left / was removed from the group.
        case left
        /// The group was renamed.
        case renamed

        /// SF Symbol for the timeline dot. (Design-agent may override; this is
        /// a sensible default so prototype UI renders.)
        public var symbol: String {
            switch self {
            case .origin: return "sparkles"
            case .longestConversation: return "bubble.left.and.bubble.right.fill"
            case .biggestDay: return "calendar.badge.exclamationmark"
            case .peakReaction: return "heart.fill"
            case .joined: return "person.badge.plus"
            case .left: return "person.badge.minus"
            case .renamed: return "pencil"
            }
        }
    }

    public let kind: Kind
    /// When the moment happened (local). The story sorts moments by this.
    public let date: Date
    /// One-line, already-formatted headline (e.g. "927 messages in one sitting").
    public let headline: String
    /// Optional secondary line (e.g. "over 4h 26m · Dec 26, 2024").
    public let detail: String?
    /// Optional decoded message body to quote (origin / peak-reaction). May be
    /// empty-string-was-attachment — the loader leaves it empty and the view
    /// shows an attachment marker.
    public let example: String?
    /// The person this moment is "about" when there is one — who sent the
    /// origin/peak message, who joined/left. Nil for biggest-day / longest-
    /// conversation (those are about the chat, not a person). Used for the
    /// hide-set filter (a hidden person's moments drop out).
    public let person: String?

    /// Stable id within a story. Combines kind + date + a discriminator so two
    /// joins on the same instant don't collide.
    public let id: String

    public init(
        kind: Kind,
        date: Date,
        headline: String,
        detail: String? = nil,
        example: String? = nil,
        person: String? = nil,
        idDiscriminator: String = ""
    ) {
        self.kind = kind
        self.date = date
        self.headline = headline
        self.detail = detail
        self.example = example
        self.person = person
        let stamp = String(Int64(date.timeIntervalSinceReferenceDate.rounded()))
        self.id = "\(kind.rawValue)-\(stamp)-\(idDiscriminator)"
    }
}

// MARK: - ChatStory

/// One conversation's worth of notable moments — the per-chat timeline. A
/// "story" can be a group OR a 1:1. Built by `ChatStoryBuilder` from chat.db.
/// PURE value type (the DB work is in the builder).
public struct ChatStory: Sendable, Equatable, Identifiable {
    /// The chat's `ROWID`. For merged recreated threads (same `display_name`),
    /// this is the EARLIEST/primary thread's ROWID; the rest fold in.
    public let chatRowID: Int64
    /// Display title — group `display_name`, the 1:1 contact name, or a
    /// participant list for an unnamed group.
    public let title: String
    public let isGroup: Bool
    /// Distinct participant count (excluding you). For 1:1 this is 1.
    public let participantCount: Int
    /// Total real messages across the chat (and any merged threads).
    public let messageCount: Int
    public let firstDate: Date
    public let lastDate: Date
    /// The chat's avatar feedstock — the 1:1 contact's photo, or the group
    /// chat photo when one exists (may be nil; the view falls back to a
    /// monogram / participant montage).
    public let avatarData: Data?
    /// Notable moments, SORTED BY DATE ascending (oldest → newest), so the
    /// timeline reads top-to-bottom chronologically.
    public let moments: [NotableMoment]

    public var id: Int64 { chatRowID }

    public init(
        chatRowID: Int64,
        title: String,
        isGroup: Bool,
        participantCount: Int,
        messageCount: Int,
        firstDate: Date,
        lastDate: Date,
        avatarData: Data?,
        moments: [NotableMoment]
    ) {
        self.chatRowID = chatRowID
        self.title = title
        self.isGroup = isGroup
        self.participantCount = participantCount
        self.messageCount = messageCount
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.avatarData = avatarData
        self.moments = moments
    }

    /// Copy with a different moment list (used when re-filtering by the hidden
    /// set drops a person's moments). Everything else preserved.
    public func withMoments(_ moments: [NotableMoment]) -> ChatStory {
        ChatStory(
            chatRowID: chatRowID,
            title: title,
            isGroup: isGroup,
            participantCount: participantCount,
            messageCount: messageCount,
            firstDate: firstDate,
            lastDate: lastDate,
            avatarData: avatarData,
            moments: moments
        )
    }
}
