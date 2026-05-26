//
//  MessageType.swift
//  Hourglass
//
//  The kind of content a message carries — text, image, video, etc. Used by
//  the type filter (`type:image`) and by the result-row UI to badge messages
//  whose body is empty or generic ("[Image]" etc.).
//
//  Derivation order (see `AttachmentLoader.types(forMessageGUIDs:database:)`):
//    1. balloon_bundle_id signals — these are precise classifiers when set:
//       - `com.apple.messages.URLBalloonProvider`             → .linkPreview
//       - `…MSMessageExtensionBalloonPlugin:…PeerPayment…`    → .applePay
//       - `…MSMessageExtensionBalloonPlugin:…FindMyMessages…` → .location
//    2. attachment row(s) joined via `message_attachment_join`:
//       - is_sticker = 1          → .sticker
//       - mime_type LIKE 'image/%'→ .image
//       - mime_type LIKE 'video/%'→ .video
//       - mime_type LIKE 'audio/%'→ .audio
//       - other non-null mime    → .file
//       - blank mime + UTI dyn.*  → fall through (plugin payload, often
//                                    covered by balloon_bundle_id rule above;
//                                    if not, treat as .file)
//    3. otherwise → .text
//
//  Schema verified empirically on the user's chat.db (2026-05-22):
//    attachment columns include `mime_type`, `uti`, `is_sticker`, `filename`,
//    `transfer_name` exactly as documented. message has `balloon_bundle_id`
//    (col 53). message_attachment_join is the (message_id, attachment_id) pair.
//

import Foundation

public enum MessageType: Sendable, Hashable {
    /// Plain text, no attachment, no preview.
    case text
    /// `image/*` MIME (jpeg, heic, png, gif, …) and not a sticker.
    case image
    /// `video/*` MIME (mp4, quicktime, 3gpp, …).
    case video
    /// `audio/*` MIME (m4a, mp3, wav, …).
    case audio
    /// `attachment.is_sticker = 1` — peel-and-stick from Messages.app.
    case sticker
    /// URL preview (LPLinkMetadata in attributedBody / URLBalloonProvider).
    case linkPreview
    /// Generic attachment we couldn't classify more specifically (pdf, vcard,
    /// docx, zip, source files, etc.).
    case file
    /// Apple Pay / Apple Cash transfer.
    case applePay
    /// Location share (Find My / Maps).
    case location
    /// Unknown / unrecognized balloon plugin (GamePigeon, polls, handwriting,
    /// digital touch, …). Distinct from `.text` so the UI can still show a
    /// hint even when we don't have a name for the bundle.
    case other

    /// Short user-facing label. Used as the body-area suffix when the message
    /// has no decoded text ("Image", "Video", …) AND as the value for the
    /// `type:` autocomplete suggestion list.
    public var displayLabel: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .sticker: return "Sticker"
        case .linkPreview: return "Link"
        case .file: return "File"
        case .applePay: return "Apple Pay"
        case .location: return "Location"
        case .other: return "Attachment"
        }
    }

    /// SF Symbol for the small inline badge in result rows.
    public var sfSymbol: String {
        switch self {
        case .text: return "text.bubble"
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "music.note"
        case .sticker: return "face.smiling.inverse"
        case .linkPreview: return "link"
        case .file: return "doc"
        case .applePay: return "applelogo"
        case .location: return "location"
        case .other: return "shippingbox"
        }
    }
}
