//
//  DashboardStats.swift
//  Hourglass
//
//  Value types for the Dashboard window — overview counters, time series, and
//  top-N rankings for people and group chats.
//
//  Everything here is the *result* of an aggregation; the SQL lives in
//  `DashboardLoader.swift`. We keep the types small and `Sendable` so they
//  cross the Task boundary cleanly when the loader runs off-main.
//
//  Naming follows the spec in plans.md → "Dashboard window" task brief.
//

import Foundation

public struct DashboardStats: Sendable {

    /// Top-of-window counters. All-time scoped — the time selector affects the
    /// charts/lists below, not these.
    public struct OverviewCounters: Sendable, Equatable {
        public let total: Int
        public let sent: Int
        public let received: Int
        public let chats: Int
        public let oldest: Date?
        public let newest: Date?

        public init(total: Int, sent: Int, received: Int, chats: Int,
                    oldest: Date?, newest: Date?) {
            self.total = total
            self.sent = sent
            self.received = received
            self.chats = chats
            self.oldest = oldest
            self.newest = newest
        }
    }

    /// One bar in the frequency chart.
    public struct TimeBucket: Sendable, Equatable, Identifiable {
        /// The start-of-bucket date (start of day / week / month, local time).
        public let date: Date
        public let sent: Int
        public let received: Int

        public var total: Int { sent + received }

        public var id: Date { date }

        public init(date: Date, sent: Int, received: Int) {
            self.date = date
            self.sent = sent
            self.received = received
        }
    }

    /// One row in the "people you text the most" list.
    ///
    /// `avatarData` is the raw PNG/JPEG bytes of the contact's AddressBook
    /// photo (already decoded out of the framing-byte format — see
    /// `AvatarStorage.decode`). Nil when the contact has no photo or the
    /// handle isn't in AddressBook at all; callers render an initials
    /// monogram via `AvatarView`.
    public struct ContactStat: Sendable, Equatable, Identifiable {
        /// Stable key — resolved display name for known contacts; raw handle
        /// for unknowns. Used by SwiftUI for ForEach identity.
        public let key: String
        public let displayName: String
        public let sent: Int
        public let received: Int
        public let total: Int
        public let avatarData: Data?

        public var id: String { key }

        public init(key: String, displayName: String,
                    sent: Int, received: Int, total: Int,
                    avatarData: Data? = nil) {
            self.key = key
            self.displayName = displayName
            self.sent = sent
            self.received = received
            self.total = total
            self.avatarData = avatarData
        }
    }

    /// One row in the "group chats you text the most" list.
    ///
    /// `sentByYou` is the headline metric; `total` is the activity-floor (sent
    /// + received), shown as a secondary value. We rank by `sentByYou` per the
    /// spec — "groups you text the most" really means "groups where you talk".
    ///
    /// **Avatar contract**:
    /// - `chatAvatarData` is non-nil when the group has a custom photo (set
    ///   from inside Messages.app — stored as an attachment, looked up via
    ///   `chat.properties.groupPhotoGuid`). Raw PNG/JPEG bytes ready for
    ///   `NSImage(data:)`. See `docs/dashboard-avatars.md`.
    /// - `participantAvatars` is the fallback feedstock: 0..3 raw PNG/JPEG
    ///   blobs from the first few participants (a participant with no
    ///   AddressBook photo contributes nil; callers preserve nil slots so
    ///   the composite still shows a placeholder). Only populated when
    ///   `chatAvatarData` is nil — when the group has its own photo, we
    ///   don't compute the composite.
    public struct GroupStat: Sendable, Equatable, Identifiable {
        public let chatRowID: Int64
        public let displayName: String
        public let sentByYou: Int
        public let total: Int
        public let chatAvatarData: Data?
        public let participantAvatars: [Data?]

        public var id: Int64 { chatRowID }

        public init(chatRowID: Int64, displayName: String,
                    sentByYou: Int, total: Int,
                    chatAvatarData: Data? = nil,
                    participantAvatars: [Data?] = []) {
            self.chatRowID = chatRowID
            self.displayName = displayName
            self.sentByYou = sentByYou
            self.total = total
            self.chatAvatarData = chatAvatarData
            self.participantAvatars = participantAvatars
        }
    }

    public let overview: OverviewCounters
    public let timeSeries: [TimeBucket]
    public let topContacts: [ContactStat]
    public let topGroups: [GroupStat]

    public init(
        overview: OverviewCounters,
        timeSeries: [TimeBucket],
        topContacts: [ContactStat],
        topGroups: [GroupStat]
    ) {
        self.overview = overview
        self.timeSeries = timeSeries
        self.topContacts = topContacts
        self.topGroups = topGroups
    }
}
