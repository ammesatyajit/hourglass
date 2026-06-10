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
        if sendSpotlightOpenURL(messageGUID: messageGUID) {
            // The GURL Apple Event makes Messages load + highlight the message
            // but does NOT bring the app forward — with another app focused,
            // the reveal happened invisibly behind it. Activate explicitly.
            _ = MessagesReveal.openMessagesApp()
            return .scrolledToMessage(viaHighlight: true)
        }

        // Fallback (legacy AX-scroll + keystroke): only fires when the
        // Spotlight URL path fails (e.g. AppleScript rejected, Messages.app
        // not running). Kept for safety; expected to rarely trigger.
        guard let chatID = chatIdentifier(fromChatGUID: chatGUID),
              let openURL = chatOpenURL(forChatIdentifier: chatID),
              NSWorkspace.shared.open(openURL) else {
            return .chatOpenFailed
        }
        try? await Task.sleep(for: .milliseconds(450))
        let needles = expectedDescriptionNeedles(
            body: body, senderName: senderName,
            isFromMe: isFromMe, messageDate: messageDate
        )
        let scrolledViaAX = scrollToMessage(matchingDescriptionNeedles: needles)
        let hadHighlight = !body.isEmpty && MessagesReveal.scrollToMessage(
            body: body, chatJustOpened: false
        )
        switch (scrolledViaAX, hadHighlight) {
        case (true, true):   return .scrolledToMessage(viaHighlight: true)
        case (true, false):  return .scrolledToMessage(viaHighlight: false)
        case (false, true):  return .chatOpenedFindOnly
        case (false, false): return .chatOpenedOnly
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
    static func sendSpotlightOpenURL(messageGUID: String) -> Bool {
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

    // MARK: - AX walk (side-effecting)

    /// Walk Messages.app's AX tree and call `AXScrollToVisible` on the first
    /// message bubble whose `AXDescription` contains **all** of the supplied
    /// needles (case-insensitive). Returns `true` if we found and scrolled
    /// to a match.
    ///
    /// Why all-needles-AND: AX inserts unpredictable text between our known
    /// anchors (attachment phrases, reactions, "Your iMessage" prefix). A
    /// single concatenated substring would miss those rows; an AND of
    /// shorter anchors hits them naturally.
    ///
    /// Requires Accessibility permission. If not granted, returns `false`
    /// silently — the chat is still open at most-recent position.
    static func scrollToMessage(matchingDescriptionNeedles needles: [String]) -> Bool {
        // Drop empty needles; if nothing useful is left, bail.
        let active = needles.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !active.isEmpty else { return false }
        guard MessagesReveal.ensureAccessibilityTrust() else { return false }
        guard let messagesPID = messagesProcessID() else { return false }

        let app = AXUIElementCreateApplication(messagesPID)
        // Find the focused window (most recently activated by our `open` call).
        guard let window = axChild(app, attr: kAXFocusedWindowAttribute as CFString)
                      ?? axChild(app, attr: kAXMainWindowAttribute as CFString) else {
            return false
        }

        // Find the transcript collection view.
        guard let transcript = findFirst(window, identifier: "TranscriptCollectionView")
        else { return false }

        // Enumerate Sticker descendants; match by ALL-needles-AND description.
        let bubbles = findAll(transcript, identifier: "Sticker")
        for bubble in bubbles {
            let desc = (axString(bubble, attr: kAXDescriptionAttribute as CFString) ?? "")
                .lowercased()
            let allPresent = active.allSatisfy { desc.contains($0) }
            if allPresent {
                // `AXScrollToVisible` is a documented Carbon constant but
                // Swift 6 strict concurrency refuses to bridge the C global
                // — use the documented string value directly. Empirically
                // verified action on Messages.app message bubbles (macOS 26.5).
                _ = AXUIElementPerformAction(bubble, "AXScrollToVisible" as CFString)

                // After `sms://open?…` the OS gives Messages.app focus but
                // the *first responder* lands on the sidebar's universal
                // search field by default — so a subsequent ⌘F lands there
                // instead of inside the chat. Explicitly move keyboard focus
                // into the transcript before any keystroke synthesis runs.
                //
                // We focus the transcript container, not the bubble itself —
                // bubbles aren't first-responder-eligible, but the transcript
                // collection view is, and focusing it puts ⌘F in the right
                // "Find in Conversation" context.
                _ = AXUIElementSetAttributeValue(
                    transcript,
                    "AXFocused" as CFString,
                    kCFBooleanTrue
                )
                return true
            }
        }
        return false
    }

    // MARK: - AX helpers

    private static func messagesProcessID() -> pid_t? {
        let running = NSWorkspace.shared.runningApplications
        return running.first { $0.bundleIdentifier == "com.apple.MobileSMS" }?.processIdentifier
    }

    private static func axChild(_ elem: AXUIElement, attr: CFString) -> AXUIElement? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(elem, attr, &value)
        if err == .success, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }
        return nil
    }

    private static func axString(_ elem: AXUIElement, attr: CFString) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(elem, attr, &value)
        if err == .success, let s = value as? String { return s }
        return nil
    }

    private static func axChildren(_ elem: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            elem, kAXChildrenAttribute as CFString, &value
        )
        guard err == .success, let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    /// Depth-first search for the first descendant whose `AXIdentifier`
    /// equals `identifier`. Bounded to avoid runaway walks if Messages.app
    /// ever introduces a cycle (it shouldn't).
    private static func findFirst(
        _ root: AXUIElement,
        identifier: String,
        maxDepth: Int = 30
    ) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (elem, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            if let id = axString(elem, attr: kAXIdentifierAttribute as CFString),
               id == identifier {
                return elem
            }
            for child in axChildren(elem) {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    /// Collect every descendant whose `AXIdentifier` equals `identifier`.
    private static func findAll(
        _ root: AXUIElement,
        identifier: String,
        maxDepth: Int = 30
    ) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (elem, depth) = stack.popLast() {
            if depth > maxDepth { continue }
            if let id = axString(elem, attr: kAXIdentifierAttribute as CFString),
               id == identifier {
                out.append(elem)
            }
            for child in axChildren(elem) {
                stack.append((child, depth + 1))
            }
        }
        return out
    }
}
