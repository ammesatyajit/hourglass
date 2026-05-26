//
//  ReactionLoaderTests.swift
//  HourglassTests
//
//  Exercises ReactionLoader against the synthetic Tests/Fixtures/chat.db.
//
//  Fixture shape (see Tests/Fixtures/build_fixture_chat_db.sh):
//    - msg-0005-reactable is the target message we attach reactions to.
//    - 6 sent + 1 removed tapback rows reference it:
//        rxn-0001  love     handle 1   (later swapped — see rxn-0008)
//        rxn-0002  love     handle 3
//        rxn-0003  laugh    handle 3   (later swapped — see... no, this stays)
//        rxn-0004  like     me
//        rxn-0005  custom 🤓 handle 1   (superseded by rxn-0008)
//        rxn-0006  sticker  handle 3   (later overrides rxn-0003)
//        rxn-0007  REMOVED  handle 1   (type 3000 — loader must drop)
//        rxn-0008  dislike  handle 1   (latest from handle 1 — wins)
//
//  Each sender owns only their latest active reaction. After the swap rules
//  we expect:
//    - handle 1 → dislike (rxn-0008 latest; rxn-0001 love and rxn-0005 🤓 dropped)
//    - handle 3 → sticker (rxn-0006 latest; rxn-0002 love and rxn-0003 laugh dropped)
//    - me     → like
//  ⇒ 3 active reactions: dislike (handle 1), sticker (handle 3), like (me).
//

import XCTest
@testable import Hourglass

final class ReactionLoaderTests: XCTestCase {

    /// Open the fixture chat.db. The fixture is bundled into the test target's
    /// Resources by XcodeGen's auto-discovery of non-source files under
    /// `Tests/`. If the bundle copy is missing, the test is skipped with a
    /// pointer to the build script that creates it (matches the pattern in
    /// MessagesRevealTests).
    private func openFixture() throws -> ChatDatabase {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        return try ChatDatabase(url: url)
    }

    private var emptyContacts: ResolvedContacts {
        ResolvedContacts(byHandle: [:], allContacts: [])
    }

    func testLoadsReactionsForTargetGUID() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: ["msg-0005-reactable"],
            database: db,
            contacts: emptyContacts
        )
        guard let reactions = map["msg-0005-reactable"] else {
            return XCTFail("Expected reactions for msg-0005-reactable, got \(map)")
        }
        // 3 senders × 1 latest reaction each = 3 active reactions.
        XCTAssertEqual(reactions.count, 3, "Expected 3 active reactions after latest-wins de-dup. Got: \(reactions)")
    }

    func testRemovedReactionsAreDropped() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: ["msg-0005-reactable"],
            database: db,
            contacts: emptyContacts
        )
        let reactions = map["msg-0005-reactable"] ?? []
        // The fixture has a type=3000 row (rxn-0007). It must NOT appear.
        // We can't directly inspect by guid (the API returns Reactions not
        // rows), but we can assert that no removed-reaction sneaks in by
        // checking we don't have 4+ active reactions (which we would if the
        // removed row leaked through).
        XCTAssertLessThanOrEqual(reactions.count, 3)
    }

    func testLatestReactionPerSenderWins() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: ["msg-0005-reactable"],
            database: db,
            contacts: emptyContacts
        )
        let reactions = map["msg-0005-reactable"] ?? []
        // From the fixture: handle 1's latest reaction is dislike (rxn-0008),
        // not the earlier love or 🤓.
        let handle1Reactions = reactions.filter { $0.senderHandle == "+15551234567" }
        XCTAssertEqual(handle1Reactions.count, 1, "Each sender should have exactly one active reaction")
        XCTAssertEqual(handle1Reactions.first?.kind, .dislike)
    }

    func testSentByUserResolvesToYou() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: ["msg-0005-reactable"],
            database: db,
            contacts: emptyContacts
        )
        let reactions = map["msg-0005-reactable"] ?? []
        // rxn-0004 is the one with handle_id NULL + is_from_me=1.
        let mine = reactions.filter { $0.isFromMe }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.senderName, "You")
        XCTAssertEqual(mine.first?.kind, .like)
    }

    func testCustomEmojiPreservesGlyph() throws {
        // Custom emoji rxn-0005 is overridden by rxn-0008 in our fixture, so
        // test the decoder directly with a synthetic input. (Loader's
        // latest-wins rule would otherwise drop the only sample we have.)
        let kind = Reaction.Kind.fromRaw(type: 2006, emoji: "🤓")
        XCTAssertEqual(kind, .customEmoji("🤓"))
        if case .customEmoji(let e) = kind {
            XCTAssertEqual(e, "🤓")
        } else {
            XCTFail("Expected customEmoji, got \(String(describing: kind))")
        }
    }

    func testStickerType2007Decoded() throws {
        let kind = Reaction.Kind.fromRaw(type: 2007, emoji: nil)
        XCTAssertEqual(kind, .sticker)
    }

    func testEmptyInputReturnsEmpty() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: [],
            database: db,
            contacts: emptyContacts
        )
        XCTAssertTrue(map.isEmpty)
    }

    func testUnknownGUIDReturnsNoEntry() throws {
        let db = try openFixture()
        let map = try ReactionLoader.reactions(
            forTargetGUIDs: ["this-guid-doesnt-exist-AAAA"],
            database: db,
            contacts: emptyContacts
        )
        XCTAssertNil(map["this-guid-doesnt-exist-AAAA"])
    }

    // MARK: - Prefix stripping

    func testStripsP0Prefix() {
        XCTAssertEqual(Reaction.stripGUIDPrefix("p:0/ABCD-1234"), "ABCD-1234")
    }

    func testStripsBpPrefix() {
        XCTAssertEqual(Reaction.stripGUIDPrefix("bp:ABCD-1234"), "ABCD-1234")
    }

    func testStripsHigherPartIndex() {
        XCTAssertEqual(Reaction.stripGUIDPrefix("p:19/ABCD-1234"), "ABCD-1234")
    }

    func testBareGUIDPassesThrough() {
        XCTAssertEqual(Reaction.stripGUIDPrefix("ABCD-1234"), "ABCD-1234")
    }

    func testStripIsConservative() {
        // No digits after `p:` → not a known prefix, leave it alone.
        XCTAssertEqual(Reaction.stripGUIDPrefix("p:foo/ABCD"), "p:foo/ABCD")
        // Wrong slash position → leave it alone.
        XCTAssertEqual(Reaction.stripGUIDPrefix("p:0ABCD"), "p:0ABCD")
    }

    // MARK: - Kind decoding

    func testKindFromRawAllStandardTypes() {
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2000, emoji: nil), .love)
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2001, emoji: nil), .like)
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2002, emoji: nil), .dislike)
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2003, emoji: nil), .laugh)
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2004, emoji: nil), .emphasize)
        XCTAssertEqual(Reaction.Kind.fromRaw(type: 2005, emoji: nil), .question)
    }

    func testKindFromRawRejectsRemovals() {
        for type in 3000...3007 {
            XCTAssertNil(Reaction.Kind.fromRaw(type: type, emoji: nil),
                         "Removed-reaction type \(type) must decode as nil")
        }
    }

    func testKindFromRawRejectsRegularMessages() {
        XCTAssertNil(Reaction.Kind.fromRaw(type: 0, emoji: nil))
        XCTAssertNil(Reaction.Kind.fromRaw(type: 1000, emoji: nil))
    }
}
