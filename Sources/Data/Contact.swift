//
//  Contact.swift
//  Hourglass
//
//  A `Contact` is a person resolved from the macOS AddressBook database,
//  potentially carrying multiple handles (one phone, one email — or three of
//  each). The `ContactResolver` owns the lookup map; this type is the value.
//

import Foundation

public struct Contact: Hashable, Sendable, Identifiable {

    /// Stable identity within this app session. We use the resolved display
    /// name as the merge key (per reference scripts: "merge by resolved name"),
    /// so this id is deterministic per name.
    public var id: String { displayName }

    /// "First Last" (or just one of them when the other is missing).
    public let displayName: String

    /// All normalized handles known to belong to this contact.
    public let handles: Set<Handle>

    /// The contact's profile photo, decoded from `ZABCDRECORD.ZIMAGEDATA` or
    /// `ZTHUMBNAILIMAGEDATA`, with AddressBook's `0x01`/`0x02` framing byte
    /// stripped (and external `_EXTERNAL_DATA/<UUID>` references resolved).
    /// Always raw PNG / JPEG bytes when non-nil — directly consumable by
    /// `NSImage(data:)`. Nil when the contact has no photo, has only a
    /// monogram/memoji, or the bytes failed to decode.
    ///
    /// See `docs/contact-avatars.md` for the storage format.
    public let avatarData: Data?

    public init(displayName: String, handles: Set<Handle>, avatarData: Data? = nil) {
        self.displayName = displayName
        self.handles = handles
        self.avatarData = avatarData
    }
}
