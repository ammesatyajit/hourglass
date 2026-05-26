//
//  Reaction.swift
//  Hourglass
//
//  A tapback / reaction on an iMessage message.
//
//  Tapbacks live in the `message` table, but they're not "real" messages —
//  they're rows whose `associated_message_type` is in the 2000-2999 range
//  (sent reactions) or 3000-3999 (removed reactions). The target of the
//  reaction is `associated_message_guid`, sometimes carrying a positional
//  prefix like `p:0/` or `bp:` that we strip when joining.
//
//  Mapping (empirically verified on the user's chat.db, 2026-05-22):
//    2000 → loved      (added by another person → ❤️ next to the bubble)
//    2001 → liked      (👍)
//    2002 → disliked   (👎)
//    2003 → laughed    (😂)
//    2004 → emphasized (‼️)
//    2005 → questioned (❓)
//    2006 → custom emoji — the actual emoji lives in `associated_message_emoji`
//    2007 → sticker reaction (no emoji column; we render a sticker glyph)
//    3000-3007 → removed reactions (history, not current state — we drop them
//      in the loader and never surface them to the UI)
//

import Foundation

public struct Reaction: Sendable, Hashable {

    public enum Kind: Sendable, Hashable {
        case love           // 2000
        case like           // 2001
        case dislike        // 2002
        case laugh          // 2003
        case emphasize      // 2004
        case question       // 2005
        /// 2006 — newer arbitrary-emoji tapback. Payload is the emoji string
        /// from `associated_message_emoji` (e.g. "🤓", "☠️").
        case customEmoji(String)
        /// 2007 — sticker reaction (no glyph in the DB; we fall back to a
        /// generic sticker marker).
        case sticker

        /// The display glyph for the badge. Single grapheme cluster — UI
        /// renders it as text inside a small pill.
        public var emoji: String {
            switch self {
            case .love: return "❤️"
            case .like: return "👍"
            case .dislike: return "👎"
            case .laugh: return "😂"
            case .emphasize: return "‼️"
            case .question: return "❓"
            case .customEmoji(let e): return e
            case .sticker: return "🏷️"
            }
        }

        /// Stable identifier for grouping & comparison. Two `.customEmoji("🤓")`
        /// share an identifier with each other but differ from `.customEmoji("☠️")`.
        public var identifier: String {
            switch self {
            case .love: return "love"
            case .like: return "like"
            case .dislike: return "dislike"
            case .laugh: return "laugh"
            case .emphasize: return "emphasize"
            case .question: return "question"
            case .customEmoji(let e): return "emoji:\(e)"
            case .sticker: return "sticker"
            }
        }

        /// Decode the kind from an `(associated_message_type, associated_message_emoji)`
        /// pair. Returns nil for non-reactions and for removed reactions
        /// (3000+) — we filter those out at the SQL level too.
        public static func fromRaw(type: Int, emoji: String?) -> Kind? {
            switch type {
            case 2000: return .love
            case 2001: return .like
            case 2002: return .dislike
            case 2003: return .laugh
            case 2004: return .emphasize
            case 2005: return .question
            case 2006:
                // Always carries a non-nil emoji in practice. Defensive fallback
                // to ❤️ if missing — better than dropping the reaction entirely.
                return .customEmoji(emoji?.isEmpty == false ? emoji! : "❤️")
            case 2007: return .sticker
            default: return nil
            }
        }
    }

    public let kind: Kind

    /// Resolved sender display name ("You" if `isFromMe`, contact name if
    /// known, raw handle otherwise).
    public let senderName: String

    /// Raw handle string from `handle.id`. nil iff the reaction was sent by
    /// the user (matches the `handle_id IS NULL` shape of sent messages).
    public let senderHandle: String?

    /// When the tapback was added. Mac-absolute-time decoded via `MessageDate`.
    public let date: Date

    public let isFromMe: Bool

    public init(
        kind: Kind,
        senderName: String,
        senderHandle: String?,
        date: Date,
        isFromMe: Bool
    ) {
        self.kind = kind
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.date = date
        self.isFromMe = isFromMe
    }
}

extension Reaction {

    /// Strip the `p:N/` or `bp:` positional prefix from an
    /// `associated_message_guid` so it matches the bare `guid` on the target
    /// message. Real-world prefixes seen in the user's DB:
    ///   - `p:0/<GUID>` (most common, ~92%)
    ///   - `p:1/<GUID>` … `p:19/<GUID>` (multi-part messages)
    ///   - `bp:<GUID>` (~5%, older reaction routing)
    ///   - bare `<GUID>` (rare — replies / threading rows in 2000-2999 land)
    ///
    /// We use a defensive regex-free approach: strip `bp:` if present, then
    /// strip `p:N/` (where N is one or more digits) if present. Anything else
    /// passes through unchanged.
    public static func stripGUIDPrefix(_ raw: String) -> String {
        if raw.hasPrefix("bp:") {
            return String(raw.dropFirst(3))
        }
        // Match `p:<digits>/`
        guard raw.hasPrefix("p:") else { return raw }
        let afterColon = raw.dropFirst(2)
        guard let slashIdx = afterColon.firstIndex(of: "/") else { return raw }
        let digits = afterColon[..<slashIdx]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) else { return raw }
        return String(afterColon[afterColon.index(after: slashIdx)...])
    }
}
