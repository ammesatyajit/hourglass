//
//  MessagesGUIDReveal.swift
//  Hourglass
//
//  GUID-based reveal — opens a specific chat AND scrolls Messages.app to
//  the specific message identified by its `message.guid` in chat.db.
//
//  See `docs/messages-deep-link.md` for the empirical research that informs
//  this design. Short version:
//
//  - **No public mechanism takes a message GUID and jumps to it.**
//  - `sms://open?groupid=<chat_identifier>` opens the chat for both 1:1 and
//    group conversations — a meaningful improvement over the old
//    `imessage:<handle>` URL which fails on groups.
//  - Once the chat is open we can walk Messages.app's Accessibility tree,
//    find the specific message bubble (matched by sender + body + time
//    derived from chat.db), and call `AXScrollToVisible` on it.
//  - For text messages we additionally synthesize ⌘F + paste + ↵ so
//    Messages.app's own Find-in-chat draws its highlight box on the match —
//    AX cannot set selection itself. For attachments / empty-body messages
//    the scroll alone is the deliverable.
//
//  Why this lives alongside `MessagesReveal` rather than replacing it
//  outright: `MessagesReveal` exposes a stable `reveal(_:)` API the rest of
//  the app calls. We surgically swap its insides to call into here, while
//  keeping the keystroke synthesis primitives reusable (they cover the
//  highlight-after-scroll step).
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
public enum MessagesGUIDReveal {

    /// What happened during reveal. Returned for tests + diagnostics.
    public enum Outcome: Equatable, Sendable {
        /// Chat opened AND the message row was found in the AX tree AND
        /// `AXScrollToVisible` succeeded. The highlight may or may not have
        /// landed (only fires for non-empty-body messages).
        case scrolledToMessage(viaHighlight: Bool)
        /// Chat opened but the target message wasn't visible in the AX tree
        /// (likely off-screen / not yet rendered by the virtualized
        /// transcript). For text messages we still try ⌘F to find by body.
        case chatOpenedFindOnly
        /// Chat opened, no further targeting attempted (e.g. no body, no AX
        /// match — user lands at most-recent position).
        case chatOpenedOnly
        /// Couldn't even open the chat (URL failed, no chat GUID, etc.).
        case chatOpenFailed
    }

    // MARK: - Public entry point

    /// Reveal the message identified by `messageGUID` in the chat identified
    /// by `chatGUID`. `body` is used both for AX matching and for the ⌘F
    /// highlight fallback. `senderName` and `messageDate` are used to build
    /// the expected `AXDescription` substring; pass exactly what the
    /// `MessageSearch.Result` carries (the resolved display name).
    ///
    /// Returns an `Outcome` describing what actually happened so callers can
    /// observe and tests can assert.
    @discardableResult
    public static func reveal(
        messageGUID: String,
        chatGUID: String?,
        body: String,
        senderName: String,
        isFromMe: Bool,
        messageDate: Date
    ) async -> Outcome {
        // Spotlight-equivalent path (reverse-engineered 2026-05-22 by tailing
        // Messages.app's log while clicking a Spotlight Messages result):
        //
        //   Apple Event:  GURL / GURL
        //   URL:          sms://open?message-guid=<GUID>
        //   Target:       com.apple.MobileSMS
        //
        // This is the SAME path the system Spotlight uses to deep-link a
        // specific message in Messages.app. Messages.app's ChatRegistry
        // resolves the chat from the message GUID alone (no chatGUID needed),
        // loads the transcript around that message, and scrolls + highlights.
        //
        // Confirmed end-to-end on macOS 26.5 against the user's real chat.db.
        if reveal(messageGUID: messageGUID) {
            return .scrolledToMessage(viaHighlight: true)
        }

        // Fallback: open the right chat — NOTHING more. (0.3.1: the old
        // AX-scroll + synthesized-keystroke fallback was removed wholesale;
        // the app must never take control of Messages. Deep links only.)
        guard let chatID = chatIdentifier(fromChatGUID: chatGUID),
              let openURL = chatOpenURL(forChatIdentifier: chatID),
              MessagesReveal.openAndActivateMessages(open: {
                  NSWorkspace.shared.open(openURL)
              }) else {
            return .chatOpenFailed
        }
        return .chatOpenedOnly
    }

    /// Spotlight-grade message navigation for callers that only carry the
    /// message GUID. The shared reveal boundary always foregrounds Messages
    /// after sending the Apple Event.
    @discardableResult
    public static func reveal(messageGUID: String) -> Bool {
        MessagesReveal.openAndActivateMessages {
            sendSpotlightOpenURL(messageGUID: messageGUID)
        }
    }

    // MARK: - Spotlight-equivalent deep link

    /// Send Messages.app the exact Apple Event Spotlight sends when the user
    /// clicks a Messages search result: `aevt/GURL` carrying
    /// `sms://open?message-guid=<GUID>`. Messages.app's `CKMessagesSceneDelegate`
    /// handles this by resolving the chat from ChatRegistry, loading the
    /// transcript around the target message, scrolling, and highlighting.
    ///
    /// Returns `true` if the AppleScript completed without error. We do NOT
    /// try to introspect Messages.app's response — the navigation itself is
    /// the success signal; ChatRegistry misses (rare, for very stale GUIDs)
    /// would still return `true` here but visibly do nothing, in which case
    /// the legacy AX fallback above kicks in via a follow-up reveal call.
    @MainActor
    private static func sendSpotlightOpenURL(messageGUID: String) -> Bool {
        // The GUID is opaque UUID-style ASCII; no escaping needed beyond
        // defensive quote-escape.
        let safeGUID = messageGUID.replacingOccurrences(of: "\"", with: "")
        let url = "sms://open?message-guid=\(safeGUID)"
        // Apple Event GURL/GURL via `«event GURLGURL»` — the raw four-char
        // code syntax. Compiled by AppleScript. Works regardless of whether
        // Messages.app is running (it gets launched).
        let script = "tell application \"Messages\" to «event GURLGURL» \"\(url)\""
        var err: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil
    }

    // MARK: - URL construction (pure, testable)

    /// Strip the `"any;-;"` / `"any;+;"` prefix (or legacy `"iMessage;-;"`
    /// variants) from a `chat.guid` to get the bare `chat_identifier` that
    /// `sms://open?groupid=` accepts.
    ///
    /// Returns `nil` if the input doesn't look like a chat GUID we can parse.
    public nonisolated static func chatIdentifier(fromChatGUID guid: String?) -> String? {
        guard let guid, !guid.isEmpty else { return nil }
        // Format: `<service>;<separator>;<identifier>`
        // service ∈ { any, iMessage, SMS }; separator ∈ { -, + }
        let parts = guid.split(separator: ";", omittingEmptySubsequences: false)
        if parts.count == 3 {
            let id = String(parts[2])
            return id.isEmpty ? nil : id
        }
        // No semicolons — assume it's already a chat_identifier (handle or
        // chat<digits>). Trust the caller.
        return guid
    }

    /// Build the `sms://open?groupid=<id>` URL.
    public nonisolated static func chatOpenURL(forChatIdentifier identifier: String) -> URL? {
        // `sms` accepts both handle ("+15551234567") and chat IDs
        // ("chat0123456789012345678"). Both are safe for URL inclusion when
        // percent-encoded.
        let escaped = identifier.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? identifier
        return URL(string: "sms://open?groupid=\(escaped)")
    }

    // MARK: - AXDescription matching (pure, testable)

    /// Build the set of substrings that ALL must appear inside the target
    /// message bubble's `AXDescription`. We do CONTAINS matching for each
    /// element — robust to:
    ///
    ///   - Trailing reaction info: `", 3 reactions, Latest: …"`.
    ///   - Sent-message prefixes: Messages.app prefixes sent rows with
    ///     `"Your iMessage, "` (or `"Your SMS, "`) — observed empirically.
    ///     By dropping our `"You"` sender from the needles for sent
    ///     messages, the remaining `<body>` and `<time>` needles still hit.
    ///   - Attachment-specific phrases: `"Includes picture"`, `"Image
    ///     attached, IMG_xxxx.heic, Image · 1.2 MB"`, etc. — by using a
    ///     SET of needles instead of a single concatenated substring, we
    ///     match even when AX inserts unpredictable text between our
    ///     known anchors (sender, time).
    ///
    /// Needles produced:
    ///   - Text from received: `[<Sender>, <body>, <H:MM AM/PM>]`
    ///   - Text sent: `[<body>, <H:MM AM/PM>]`
    ///   - Attachment received: `[<Sender>, <H:MM AM/PM>]`
    ///   - Attachment sent: `[<H:MM AM/PM>]` — time alone may match multiple
    ///     rows; we still try, but accept that targeting is best-effort.
    ///   - Whitespace-only body is treated as empty (attachment case).
    ///
    /// Empty needles are filtered out; callers should `&&` (all-needles-
    /// present) for matching.
    public nonisolated static func expectedDescriptionNeedles(
        body: String,
        senderName: String,
        isFromMe: Bool,
        messageDate: Date,
        locale: Locale = .current,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> [String] {
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeString = Self.formatTime(messageDate, locale: locale, timeZone: timeZone)

        var needles: [String] = []
        if !isFromMe && !senderName.isEmpty {
            // Received: include sender. (Sent messages get Messages.app's
            // own prefix "Your iMessage, " which we can't predict reliably
            // across SMS vs iMessage, so we skip the sender.)
            needles.append(senderName)
        }
        if !cleanBody.isEmpty {
            needles.append(cleanBody)
        }
        if !timeString.isEmpty {
            needles.append(timeString)
        }
        return needles
    }


    /// Format a date the way Messages.app renders its AX time stamps:
    /// `H:MM AM/PM` in en_US (12-hour with non-breaking space narrow gap
    /// before AM/PM — U+202F), locale-aware otherwise. We use a `.short`
    /// `DateFormatter`.
    nonisolated static func formatTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    // (0.3.1: the AX-walk scroll machinery was deleted — the app never
    // drives Messages via Accessibility. Reveal is deep-link only.)

}
