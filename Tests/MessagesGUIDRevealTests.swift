//
//  MessagesGUIDRevealTests.swift
//  HourglassTests
//
//  Unit tests for the GUID-based reveal pipeline. These are pure tests over
//  the URL construction and AXDescription matching logic — the AX walk
//  itself can't run in CI without a real Messages.app, so we don't try.
//
//  What we DO cover here:
//   - `chatIdentifier(fromChatGUID:)`: strips `any;-;` / `any;+;` prefixes,
//     handles legacy iMessage; prefix, no-prefix passthrough, empty/nil.
//   - `chatOpenURL(forChatIdentifier:)`: produces a `sms://open?groupid=…`
//     URL, percent-encodes the identifier so `+` and other safe chars stay
//     literal.
//   - `expectedDescriptionNeedles`: produces the right substrings (sender,
//     body, time) for received vs sent / text vs attachment messages, with
//     locale + timezone pinned so tests are hermetic.
//

import XCTest
@testable import Hourglass

final class MessagesGUIDRevealTests: XCTestCase {

    // MARK: - chatIdentifier(fromChatGUID:)

    /// Modern 1:1 GUID: `any;-;<handle>` → just the handle.
    func testChatIdentifierFromModern1To1GUID() {
        let id = MessagesGUIDReveal.chatIdentifier(fromChatGUID: "any;-;+15551234567")
        XCTAssertEqual(id, "+15551234567")
    }

    /// Modern group GUID: `any;+;chat<digits>` → just the chat<digits>.
    func testChatIdentifierFromModernGroupGUID() {
        let id = MessagesGUIDReveal.chatIdentifier(
            fromChatGUID: "any;+;chat728778165720474941"
        )
        XCTAssertEqual(id, "chat728778165720474941")
    }

    /// Legacy iMessage; prefix is also stripped — same shape, different
    /// service name.
    func testChatIdentifierFromLegacyIMessageGUID() {
        let id = MessagesGUIDReveal.chatIdentifier(
            fromChatGUID: "iMessage;-;friend@example.com"
        )
        XCTAssertEqual(id, "friend@example.com")
    }

    /// No-prefix string passes through as-is — trust the caller.
    func testChatIdentifierPassthroughForBareIdentifier() {
        let id = MessagesGUIDReveal.chatIdentifier(fromChatGUID: "+15551234567")
        XCTAssertEqual(id, "+15551234567")
    }

    /// Empty / nil → nil.
    func testChatIdentifierNilOrEmpty() {
        XCTAssertNil(MessagesGUIDReveal.chatIdentifier(fromChatGUID: nil))
        XCTAssertNil(MessagesGUIDReveal.chatIdentifier(fromChatGUID: ""))
    }

    /// Empty identifier after stripping the prefix → nil (chat.guid was
    /// pathological).
    func testChatIdentifierEmptyAfterStrip() {
        XCTAssertNil(MessagesGUIDReveal.chatIdentifier(fromChatGUID: "any;-;"))
    }

    // MARK: - chatOpenURL(forChatIdentifier:)

    /// Builds `sms://open?groupid=<id>` with `+` preserved (it's URL-path-safe).
    func testChatOpenURLForPhoneHandle() {
        let url = MessagesGUIDReveal.chatOpenURL(forChatIdentifier: "+15551234567")
        XCTAssertEqual(url?.absoluteString, "sms://open?groupid=+15551234567")
    }

    /// `@` (in emails) is also URL-path-safe.
    func testChatOpenURLForEmailHandle() {
        let url = MessagesGUIDReveal.chatOpenURL(forChatIdentifier: "friend@example.com")
        XCTAssertEqual(url?.absoluteString, "sms://open?groupid=friend@example.com")
    }

    /// Group `chat<digits>` is all-ASCII-safe — passes through unchanged.
    func testChatOpenURLForGroupID() {
        let url = MessagesGUIDReveal.chatOpenURL(forChatIdentifier: "chat728778165720474941")
        XCTAssertEqual(
            url?.absoluteString,
            "sms://open?groupid=chat728778165720474941"
        )
    }

    /// Fixed reference date for deterministic time formatting.
    /// 2024-06-15 14:30:00 PST = 21:30:00 UTC.
    private var referenceDate: Date {
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 15
        c.hour = 14; c.minute = 30; c.second = 0
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - expectedDescriptionNeedles (the actual matching primitive)

    /// Received text message → `[sender, body, time]`.
    func testNeedlesForReceivedTextMessage() {
        let needles = MessagesGUIDReveal.expectedDescriptionNeedles(
            body: "hello world",
            senderName: "Atul",
            isFromMe: false,
            messageDate: referenceDate,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertEqual(needles.count, 3)
        XCTAssertEqual(needles[0], "Atul")
        XCTAssertEqual(needles[1], "hello world")
        XCTAssertTrue(needles[2].contains("2:30"))
    }

    /// Sent text → `[body, time]`. No "You" needle — Messages.app renders
    /// `"Your iMessage, "` which doesn't contain "You" verbatim in our
    /// resolved sender name.
    func testNeedlesForSentTextMessage() {
        let needles = MessagesGUIDReveal.expectedDescriptionNeedles(
            body: "see you soon",
            senderName: "You",
            isFromMe: true,
            messageDate: referenceDate,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertEqual(needles.count, 2)
        XCTAssertEqual(needles[0], "see you soon")
        XCTAssertTrue(needles[1].contains("2:30"))
        XCTAssertFalse(needles.contains("You"))
    }

    /// Received attachment (no body) → `[sender, time]`. Robust to AX
    /// inserting attachment phrases between the two.
    func testNeedlesForReceivedAttachment() {
        let needles = MessagesGUIDReveal.expectedDescriptionNeedles(
            body: "",
            senderName: "Mason Funaki",
            isFromMe: false,
            messageDate: referenceDate,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertEqual(needles.count, 2)
        XCTAssertEqual(needles[0], "Mason Funaki")
        XCTAssertTrue(needles[1].contains("2:30"))
    }

    /// Sent attachment (no body, isFromMe=true) → `[time]` alone.
    /// Best-effort matching — time may not uniquely identify, but it's all
    /// we have.
    func testNeedlesForSentAttachment() {
        let needles = MessagesGUIDReveal.expectedDescriptionNeedles(
            body: "",
            senderName: "You",
            isFromMe: true,
            messageDate: referenceDate,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertEqual(needles.count, 1)
        XCTAssertTrue(needles[0].contains("2:30"))
    }

    /// Whitespace-only body normalizes to empty (attachment case).
    func testNeedlesTreatWhitespaceBodyAsEmpty() {
        let needles = MessagesGUIDReveal.expectedDescriptionNeedles(
            body: "   \n\t ",
            senderName: "Atul",
            isFromMe: false,
            messageDate: referenceDate,
            locale: Locale(identifier: "en_US"),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        // No body needle — only sender + time
        XCTAssertEqual(needles.count, 2)
        XCTAssertEqual(needles[0], "Atul")
        XCTAssertFalse(needles.contains(where: { $0.isEmpty || $0.trimmingCharacters(in: .whitespaces).isEmpty }))
    }

    // MARK: - formatTime (internal)

    /// The internal time formatter agrees with what Messages.app renders.
    /// Pinned locale + timezone for reproducibility.
    func testFormatTimeRendersShortStyle() {
        let s = MessagesGUIDReveal.formatTime(
            referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        // The string should be a 12-hour time with AM/PM marker. Don't
        // hard-code the NBSP variant Apple uses — just assert structural
        // properties.
        XCTAssertTrue(s.contains("2:30"))
        XCTAssertTrue(s.lowercased().contains("pm"))
    }

    /// 24-hour locale (e.g. en_GB) produces a 24-hour rendering — no AM/PM.
    func testFormatTimeRespectsLocale() {
        let s = MessagesGUIDReveal.formatTime(
            referenceDate,
            locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!
        )
        XCTAssertTrue(s.contains("14:30") || s.contains("2:30 pm"),
                      "Expected 24-hour or pm-suffixed time in en_GB, got: \(s)")
    }
}
