//
//  MessagesReveal.swift
//  Hourglass
//
//  "Open this message's chat in Messages.app." That's the whole feature.
//
//  This module is the *integration* layer. The actual deep-link work lives in
//  `MessagesGUIDReveal` (URL scheme + Accessibility walk + scroll-to-message
//  by GUID). Existing callers keep calling `MessagesReveal.reveal(_:)`; the
//  internals have been rewritten to:
//
//    1. Route through `MessagesGUIDReveal.reveal(...)` when the search result
//       carries a chat GUID. This uses `sms://open?groupid=<chat_identifier>`
//       (works for BOTH 1:1 and groups — supersedes the old
//       `imessage:<handle>` URL that failed on groups), and then walks
//       Messages.app's AX tree to scroll to the specific message bubble.
//    2. As a *fallback* (and additionally for the visual highlight that AX
//       can't draw on its own), synthesize ⌘F → ⌘V → ↵ so Messages.app's
//       own Find-in-chat draws its highlight box. This is the previous
//       implementation's whole approach, kept here because GUID-based scroll
//       alone can't visually highlight (AX `AXSelected` is not settable).
//    3. For the rare case where there's no chat GUID at all (very old DB
//       rows, or fixture data that didn't populate chat.guid), fall back to
//       the legacy `imessage:<handle>` URL — 1:1 chats only, foregrounding
//       Messages for groups.
//
//  See `docs/messages-deep-link.md` for empirical evidence behind every
//  decision here.
//
//  Design
//  ------
//  - `revealURL(for:)` is pure — it builds (or refuses to build) a URL from a
//    `MessageSearch.Result` plus its participant handles. Pure = testable.
//  - `reveal(_:)` is the side-effecting wrapper that asks `revealURL` for a
//    URL, opens it with `NSWorkspace.shared.open`, and falls back to launching
//    Messages.app when no URL is available (group chats).
//
//  Why pass participants in: groups don't carry a usable URL identifier, and
//  for 1:1 chats the "partner handle" lives in `chat_handle_join`, not in the
//  `Message` row itself. The caller (panel / browse window) already has access
//  to the `ChatDatabase` and looks up the handles on demand.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GRDB

/// Opens a chat from a search result in the native Messages.app.
public enum MessagesReveal {

    /// A lazily-opened, process-wide read-only handle on `chat.db`, used by
    /// `reveal(_:)` to resolve 1:1 partner handles for sent messages (the
    /// `Message` row itself doesn't carry the partner for `is_from_me=1`).
    ///
    /// `nil` if the DB can't be opened (FDA denied, file missing, etc.) — in
    /// that case we degrade to the foreground-only fallback. Tests inject
    /// their own DB via the explicit `database:` parameter on `reveal(_:)`.
    @MainActor
    private static var sharedDatabase: ChatDatabase? = {
        try? ChatDatabase()
    }()

    /// The strategy used to reveal a chat. Returned from `revealURL(for:)` so
    /// tests (and callers) can see exactly what we decided to do.
    public enum Strategy: Equatable, Sendable {
        /// 1:1 chat: open `imessage:<handle>`. The handle is the partner's
        /// (NOT the user's own).
        case oneToOne(handle: String)
        /// Group chat: no URL works, so we just bring Messages.app forward.
        case foregroundOnly
    }

    // MARK: - URL construction (pure)

    /// Build the URL we'd open for this result, given the chat's participant
    /// handles. Returns `nil` for groups (caller should fall back to
    /// foregrounding Messages.app — `strategy(for:participants:)` makes this
    /// explicit).
    ///
    /// - Parameters:
    ///   - result: The search result whose chat we want to open.
    ///   - participants: The OTHER parties in the chat (the user themselves is
    ///     NOT in this list — pass what `chat_handle_join` returns).
    public static func revealURL(
        for result: MessageSearch.Result,
        participants: [Handle]
    ) -> URL? {
        switch strategy(for: result.message, participants: participants) {
        case .oneToOne(let handle):
            return imessageURL(forHandle: handle)
        case .foregroundOnly:
            return nil
        }
    }

    /// Decide how to reveal this chat. Pure — no side effects, no DB access.
    public static func strategy(
        for message: Message,
        participants: [Handle]
    ) -> Strategy {
        // chat.style == 45 is 1:1, 43 is group. If style is missing (older DBs
        // didn't always populate it), use participant count as a fallback:
        // exactly one OTHER party means 1:1.
        let isOneToOne: Bool
        if let style = message.chatStyle {
            isOneToOne = (style == 45)
        } else {
            isOneToOne = (participants.count == 1)
        }

        guard isOneToOne, let partner = participants.first else {
            return .foregroundOnly
        }

        // Prefer the raw handle exactly as it appears in chat.db. Messages.app
        // matches the URL handle to its known chats and accepts E.164 phones
        // and lowercased emails — both of which match `handle.id` directly.
        let raw = partner.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .foregroundOnly }
        return .oneToOne(handle: raw)
    }

    /// Construct an `imessage:<handle>` URL. Handles must be URL-safe; phone
    /// `+` and email `@` are fine in opaque URI bodies but we percent-encode
    /// defensively (some macOS builds choke on stray `?` / `#` in the handle).
    public static func imessageURL(forHandle handle: String) -> URL? {
        // RFC 3986: keep characters that are valid in a URI scheme-specific part.
        // `urlPathAllowed` accepts `+` `@` `.` `-` `_` and most printable ASCII
        // (it forbids `?` `#` `[` `]` etc., which is what we want to escape).
        let escaped = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? handle
        return URL(string: "imessage:\(escaped)")
    }

    // MARK: - Side-effecting wrapper

    /// Open the chat in Messages.app and scroll to the specific message.
    /// Returns `true` if we successfully invoked the system to open the chat.
    /// Whether the scroll-and-highlight actually landed depends on whether
    /// the message is in the current AX-rendered window (most-recent
    /// messages are; old ones may not be) and whether Accessibility
    /// permission was granted.
    ///
    /// **Routing**:
    /// - If the result carries a `chatGUID` (modern path — see
    ///   `MessagesGUIDReveal`), open via `sms://open?groupid=<chat_id>` and
    ///   then AX-scroll to the message, plus ⌘F highlight if there's a body.
    /// - Otherwise fall back to the legacy 1:1 `imessage:<handle>` URL +
    ///   keystroke find. Groups without a GUID just foreground Messages.app.
    ///
    /// `database` is the test-injection point. Production callers pass `nil`
    /// and we use the default user `chat.db`.
    @discardableResult
    @MainActor
    public static func reveal(_ result: MessageSearch.Result, database: ChatDatabase? = nil) -> Bool {
        // Prefer the GUID-based path when we have what it needs.
        if let chatGUID = result.chatGUID,
           let messageGUID = result.message.guid {
            Task { @MainActor in
                _ = await MessagesGUIDReveal.reveal(
                    messageGUID: messageGUID,
                    chatGUID: chatGUID,
                    body: result.message.body,
                    senderName: result.senderName,
                    isFromMe: result.message.isFromMe,
                    messageDate: result.message.date
                )
            }
            return true
        }

        // Legacy fallback: no chat GUID available (e.g. test fixture without
        // it, or extremely old DB rows). Open the right chat; nothing more.
        // (0.3.1: ALL keystroke/AX synthesis removed — the app must NEVER
        // take control of Messages. Reveal is deep-link only.)
        let db = database ?? sharedDatabase
        let participants = participants(for: result, database: db)
        if let url = revealURL(for: result, participants: participants) {
            return NSWorkspace.shared.open(url)
        }
        return openMessagesApp()
    }

    /// Bring `Messages.app` to the foreground without selecting any chat.
    /// Used as a fallback for groups (and as a graceful degradation when a
    /// 1:1's handle is unusable).
    @MainActor
    public static func openMessagesApp() -> Bool {
        // The system Messages bundle ID is com.apple.MobileSMS on macOS.
        // We try the bundle ID first (robust against renames in /Applications),
        // then fall back to opening the app bundle URL.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            return true
        }
        // Last-resort: open the iMessage URL with no handle. macOS routes empty
        // imessage: URLs to Messages.app, opening the app window.
        if let fallback = URL(string: "imessage:") {
            return NSWorkspace.shared.open(fallback)
        }
        return false
    }

    // MARK: - DB lookup (testable — DB injected)

    /// Resolve participant handles for a search result. Avoids a DB lookup
    /// when the result itself carries enough info (received 1:1 messages).
    /// Exposed as `internal` so tests can drive it directly with a fixture DB.
    static func participants(
        for result: MessageSearch.Result,
        database: ChatDatabase?
    ) -> [Handle] {
        // Received message in a 1:1 — the sender IS the (sole) partner.
        // We can short-circuit the DB lookup for this very common case.
        if !result.message.isFromMe,
           result.message.chatStyle == 45,
           let senderRaw = result.message.senderHandle,
           !senderRaw.isEmpty {
            return [Handle(raw: senderRaw)]
        }
        return participants(forChat: result.message.chatRowID, database: database)
    }

    /// Look up the participant handles for a chat row directly from the DB.
    /// Returns `[]` if the DB is nil or the query fails.
    static func participants(forChat chatID: Int64, database: ChatDatabase?) -> [Handle] {
        guard let database else { return [] }
        let rows: [String] = (try? database.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT h.id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                WHERE chj.chat_id = ?
                """, arguments: [chatID])
        }) ?? []
        return rows.map { Handle(raw: $0) }
    }
}
