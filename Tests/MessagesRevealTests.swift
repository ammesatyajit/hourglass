//
//  MessagesRevealTests.swift
//  HourglassTests
//
//  Covers `Sources/Reveal/MessagesReveal.swift` — the "open this chat in
//  Messages.app" reveal logic. We exercise both URL construction (pure) and
//  participant-lookup against the fixture chat.db.
//
//  Coverage map
//  ------------
//  Fixture row 1 — sent in 1:1 (style=45), `senderHandle = NULL` →
//      forces a DB lookup → expect partner = `+15551234567`.
//  Fixture row 2 — received in 1:1, `senderHandle = "+15551234567"` →
//      short-circuit, no DB lookup → expect partner = `+15551234567`.
//  Fixture row 3 — received in GROUP (style=43) →
//      strategy = `.foregroundOnly`, URL = nil.
//
//  Tapback row 4 is excluded — `MessageSearch` already filters
//  `associated_message_type=0`, so reveal never sees one in practice.
//

import XCTest
@testable import Hourglass

final class MessagesRevealTests: XCTestCase {

    // MARK: - Fixture wiring

    /// Path to `Tests/Fixtures/chat.db`. The fixture is auto-discovered into
    /// `HourglassTests.xctest/Contents/Resources/chat.db` by XcodeGen
    /// (the test target's `sources: [Tests]` includes the `Fixtures/` subdir,
    /// and non-source files there end up in the bundle's Resources).
    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        return url
    }

    private func openFixture() throws -> ChatDatabase {
        try ChatDatabase(url: fixtureURL())
    }

    // MARK: - Pure URL construction

    /// `imessageURL(forHandle:)` percent-encodes safely. `+` and `@` are kept
    /// because they're allowed in `.urlPathAllowed`; we only escape characters
    /// that would actually break URL parsing.
    func testIMessageURLForPhoneHandle() {
        let url = MessagesReveal.imessageURL(forHandle: "+15551234567")
        XCTAssertEqual(url?.absoluteString, "imessage:+15551234567")
    }

    func testIMessageURLForEmailHandle() {
        let url = MessagesReveal.imessageURL(forHandle: "friend@example.com")
        XCTAssertEqual(url?.absoluteString, "imessage:friend@example.com")
    }

    // MARK: - Strategy decisions (pure, no DB)

    /// A 1:1 chat (style=45) with a known partner handle → `.oneToOne`.
    func testStrategyForOneToOne() {
        let msg = Self.makeMessage(chatStyle: 45, isFromMe: true)
        let s = MessagesReveal.strategy(
            for: msg,
            participants: [Handle(raw: "+15551234567")]
        )
        XCTAssertEqual(s, .oneToOne(handle: "+15551234567"))
    }

    /// A group chat (style=43) → `.foregroundOnly` regardless of how many
    /// participants we know about. Apple's imessage: URL doesn't open groups.
    func testStrategyForGroup() {
        let msg = Self.makeMessage(chatStyle: 43, isFromMe: false)
        let s = MessagesReveal.strategy(
            for: msg,
            participants: [
                Handle(raw: "+15551234567"),
                Handle(raw: "+15557654321"),
            ]
        )
        XCTAssertEqual(s, .foregroundOnly)
    }

    /// If `chatStyle` is missing, fall back to participant count — exactly
    /// one OTHER party means 1:1.
    func testStrategyFallsBackToParticipantCount() {
        let msg = Self.makeMessage(chatStyle: nil, isFromMe: false)

        let oneToOne = MessagesReveal.strategy(
            for: msg,
            participants: [Handle(raw: "friend@example.com")]
        )
        XCTAssertEqual(oneToOne, .oneToOne(handle: "friend@example.com"))

        let group = MessagesReveal.strategy(
            for: msg,
            participants: [
                Handle(raw: "a@x.com"),
                Handle(raw: "b@x.com"),
            ]
        )
        XCTAssertEqual(group, .foregroundOnly)
    }

    /// No participants at all (orphan chat, missing data) → `.foregroundOnly`.
    func testStrategyWithNoParticipants() {
        let msg = Self.makeMessage(chatStyle: 45, isFromMe: true)
        let s = MessagesReveal.strategy(for: msg, participants: [])
        XCTAssertEqual(s, .foregroundOnly)
    }

    // MARK: - revealURL — top-level URL builder

    func testRevealURLForOneToOne() {
        let msg = Self.makeMessage(chatStyle: 45, isFromMe: false)
        let result = MessageSearch.Result(
            message: msg, partnerName: "Friend", senderName: "Friend"
        )
        let url = MessagesReveal.revealURL(
            for: result,
            participants: [Handle(raw: "+15551234567")]
        )
        XCTAssertEqual(url?.absoluteString, "imessage:+15551234567")
    }

    func testRevealURLForGroupIsNil() {
        let msg = Self.makeMessage(chatStyle: 43, isFromMe: false)
        let result = MessageSearch.Result(
            message: msg, partnerName: "[group] Test Group", senderName: "Friend"
        )
        let url = MessagesReveal.revealURL(
            for: result,
            participants: [
                Handle(raw: "+15551234567"),
                Handle(raw: "+15557654321"),
            ]
        )
        XCTAssertNil(url, "Groups have no imessage: URL — caller falls back to foregrounding Messages.app.")
    }

    // MARK: - Participant lookup against the fixture DB

    /// Sent 1:1 message: `senderHandle` is NULL in the DB, so we must hit
    /// `chat_handle_join` to find the partner. The fixture's chat 1 has
    /// handles 1 (`+15551234567`) and 2 (`friend@example.com`).
    func testParticipantsForSentOneToOneHitsDB() throws {
        let db = try openFixture()
        let sent = MessageSearch.Result(
            message: Self.makeMessage(
                id: 1, chatRowID: 1, chatStyle: 45,
                isFromMe: true, senderHandle: nil
            ),
            partnerName: "+15551234567", senderName: "You"
        )

        let parts = MessagesReveal.participants(for: sent, database: db)
        let normalized = Set(parts.map(\.normalized))

        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.contains("+15551234567"))
        XCTAssertTrue(normalized.contains("friend@example.com"))
    }

    /// Received 1:1: `senderHandle` IS the partner. We short-circuit the DB
    /// lookup entirely — passing `database: nil` must still return the partner.
    func testParticipantsForReceivedOneToOneShortCircuits() {
        let received = MessageSearch.Result(
            message: Self.makeMessage(
                id: 2, chatRowID: 1, chatStyle: 45,
                isFromMe: false, senderHandle: "+15551234567"
            ),
            partnerName: "+15551234567", senderName: "+15551234567"
        )
        // database = nil — proves we don't need to touch the DB at all.
        let parts = MessagesReveal.participants(for: received, database: nil)
        XCTAssertEqual(parts.map(\.normalized), ["+15551234567"])
    }

    /// Group received message: DB lookup runs (sender alone isn't enough to
    /// reveal the chat). The fixture's group has handles 1 and 3.
    func testParticipantsForGroupReceivedHitsDB() throws {
        let db = try openFixture()
        let groupReceived = MessageSearch.Result(
            message: Self.makeMessage(
                id: 3, chatRowID: 2, chatStyle: 43,
                isFromMe: false, senderHandle: "+15557654321"
            ),
            partnerName: "[group] Test Group", senderName: "+15557654321"
        )

        let parts = MessagesReveal.participants(for: groupReceived, database: db)
        let normalized = Set(parts.map(\.normalized))

        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.contains("+15551234567"))
        XCTAssertTrue(normalized.contains("+15557654321"))
    }

    /// End-to-end: sent 1:1 message, real DB lookup, expect a usable URL.
    /// Picks the first participant — either phone or email is valid for the
    /// fixture's chat 1 (Messages.app accepts both).
    func testFixtureSentOneToOneProducesURL() throws {
        let db = try openFixture()
        let sent = MessageSearch.Result(
            message: Self.makeMessage(
                id: 1, chatRowID: 1, chatStyle: 45,
                isFromMe: true, senderHandle: nil
            ),
            partnerName: "+15551234567", senderName: "You"
        )

        let parts = MessagesReveal.participants(for: sent, database: db)
        let url = MessagesReveal.revealURL(for: sent, participants: parts)

        let urlString = try XCTUnwrap(url?.absoluteString)
        XCTAssertTrue(urlString.hasPrefix("imessage:"))
        // Whichever of the two handles came first in the join must appear.
        let body = String(urlString.dropFirst("imessage:".count))
        XCTAssertTrue(
            body == "+15551234567" || body == "friend@example.com",
            "Expected one of the chat-1 handles, got \(body)"
        )
    }

    // MARK: - Shared foreground boundary

    @MainActor
    func testOpenAndActivateRunsNavigationThenForegroundExactlyOnce() {
        var calls: [String] = []
        let result = MessagesReveal.openAndActivateMessages(
            open: {
                calls.append("open")
                return true
            },
            activate: {
                calls.append("activate")
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(calls, ["open", "activate"])
    }

    @MainActor
    func testOpenAndActivateStillForegroundsWhenNavigationFails() {
        var activated = false
        let result = MessagesReveal.openAndActivateMessages(
            open: { false },
            activate: {
                activated = true
                return true
            }
        )

        XCTAssertFalse(result)
        XCTAssertTrue(activated)
    }

    // MARK: - Helpers

    /// Build a `Message` with sensible defaults so tests only need to set the
    /// fields they care about.
    private static func makeMessage(
        id: Int64 = 1,
        chatRowID: Int64 = 1,
        chatStyle: Int? = 45,
        isFromMe: Bool = false,
        senderHandle: String? = nil,
        body: String = "hello"
    ) -> Message {
        Message(
            id: id,
            date: Date(timeIntervalSince1970: 1_718_452_800),
            isFromMe: isFromMe,
            chatRowID: chatRowID,
            senderHandle: senderHandle,
            chatStyle: chatStyle,
            chatDisplayName: nil,
            body: body,
            associatedMessageType: 0
        )
    }
}
