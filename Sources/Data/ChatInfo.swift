//
//  ChatInfo.swift
//  Hourglass
//
//  A lightweight value type describing one chat (conversation). Used by the
//  search-autocomplete layer to suggest chat names when the user types
//  `chat:` or `in:`.
//
//  We DON'T mirror the full schema here — just enough for "given a partial
//  chat name, return matches". Heavy chat browsing (timeline, count by chat,
//  etc.) belongs to a future enrichment.
//

import Foundation

public struct ChatInfo: Sendable, Hashable, Identifiable {

    /// `chat.ROWID`.
    public let rowID: Int64

    /// `chat.style` — 45 = 1:1, 43 = group.
    public let style: Int?

    /// `chat.display_name`. Possibly empty for 1:1 chats and for groups that
    /// never got a name.
    public let rawDisplayName: String?

    /// Resolved participant display names — what AddressBook calls each
    /// participant, falling back to raw handle. Used to compose a synthetic
    /// label when `rawDisplayName` is empty.
    public let participantNames: [String]

    /// Most recent message date in this chat, or nil if the chat has no
    /// messages (rare but possible). Used for sorting.
    public let lastMessageDate: Date?

    public var id: Int64 { rowID }

    public var isGroup: Bool { style == 43 }

    /// The label to show in autocomplete suggestions:
    /// - Named chat: use the display name as-is.
    /// - Group without a name: "You, Alice, Bob" (first 4 + "+N")
    /// - 1:1 chat: the other participant's resolved name.
    public var label: String {
        if let dn = rawDisplayName, !dn.isEmpty {
            return dn
        }
        if participantNames.isEmpty {
            return "(unknown chat)"
        }
        if style == 43 {
            // Group, no name — list participants.
            let preview = participantNames.prefix(4).joined(separator: ", ")
            let suffix = participantNames.count > 4 ? " +\(participantNames.count - 4)" : ""
            return preview + suffix
        }
        return participantNames.first ?? "(unknown)"
    }
}
