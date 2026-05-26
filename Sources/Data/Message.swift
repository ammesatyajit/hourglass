//
//  Message.swift
//  Hourglass
//
//  Domain type for a single iMessage row, post-decode.
//
//  The DB columns we surface (from `message` and a join on `chat_message_join`
//  → `chat`):
//    - ROWID         : primary key
//    - guid          : the canonical, stable, UUID-like message identifier
//                      that Apple's own systems use. Persists across DB
//                      restores. Used for GUID-based reveal in Messages.app.
//    - date          : Mac absolute time (see `MessageDate.swift`)
//    - is_from_me    : 1 if sent, 0 if received
//    - chat_id       : from chat_message_join.chat_id (used for grouping)
//    - handle_id     : the sender's handle. NULL for sent messages. For 1:1
//                      received messages we still look this up so we know who
//                      sent it. For sent messages, callers should display "You".
//    - text          : the easy case (NULL for most modern messages)
//    - attributedBody: the hard case — binary blob decoded by AttributedBodyDecoder
//    - associated_message_type : 0 for "real" messages, non-zero for tapbacks/etc.
//
//  We materialize the decoded body at fetch time so downstream code (search,
//  display) never has to think about attributedBody parsing.
//

import Foundation

public struct Message: Identifiable, Hashable, Sendable {

    /// `message.ROWID` from chat.db.
    public let id: Int64

    /// `message.guid` — Apple's canonical, UUID-like identifier for the
    /// message (e.g. `"ABCDEF12-3456-..."` or `"p:0/ABCDEF12-..."`). Stable
    /// across DB restores and the same value Apple's own systems use for
    /// message-level routing. Used to target a specific message in
    /// Messages.app via the Accessibility/keystroke reveal pipeline.
    /// Nullable because pathological / very old rows may not have one,
    /// though every modern row does.
    public let guid: String?

    /// When the message was sent (decoded from Mac-absolute-time).
    public let date: Date

    /// True iff `is_from_me = 1`.
    public let isFromMe: Bool

    /// `chat_message_join.chat_id` — links this message to its conversation.
    /// Multiple messages can share a chat_id; the chat could be 1:1 or group.
    public let chatRowID: Int64

    /// The raw handle string of the sender (`handle.id`), if any. NULL in DB
    /// for sent messages; callers translate to "You" via `isFromMe`.
    public let senderHandle: String?

    /// `chat.style` — 45 = 1:1, 43 = group. Useful for partner resolution
    /// without re-querying.
    public let chatStyle: Int?

    /// `chat.display_name` — set for some group chats, null otherwise.
    public let chatDisplayName: String?

    /// The message body, decoded. Comes from `text` if set, otherwise from
    /// `attributedBody` via `AttributedBodyDecoder`.
    public let body: String

    /// `message.associated_message_type` — non-zero means tapback/etc.
    public let associatedMessageType: Int

    public init(
        id: Int64,
        guid: String? = nil,
        date: Date,
        isFromMe: Bool,
        chatRowID: Int64,
        senderHandle: String?,
        chatStyle: Int?,
        chatDisplayName: String?,
        body: String,
        associatedMessageType: Int
    ) {
        self.id = id
        self.guid = guid
        self.date = date
        self.isFromMe = isFromMe
        self.chatRowID = chatRowID
        self.senderHandle = senderHandle
        self.chatStyle = chatStyle
        self.chatDisplayName = chatDisplayName
        self.body = body
        self.associatedMessageType = associatedMessageType
    }

    /// Is this a real user message (not a tapback / sticker / etc.)?
    public var isRealMessage: Bool {
        associatedMessageType == 0
    }
}
