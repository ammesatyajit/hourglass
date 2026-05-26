//
//  ChatOperatorE2ETests.swift
//  Hourglass
//
//  End-to-end tests for the `in:` / `chat:` / `with:` filter semantics
//  that landed on 2026-05-25. Both the INSTR path (`MessageSearch.search`)
//  and the FTS5 path (`FTSSearcher.search`) are exercised against the
//  bundled fixture chat.db, and the FTS path is also expected to be in
//  parity with INSTR for every assertion below.
//
//  The point of these tests is to PIN the new semantics so they don't
//  silently regress:
//    - `in:NAME` / `chat:NAME` → substring match on `chat.display_name`
//      only. Does NOT match 1:1 chats by participant (they have empty
//      display_name) and does NOT match unnamed groups by participant.
//    - `with:NAME` → any chat (1:1 or group) where the named person
//      participates. NAME is resolved against contact display name OR
//      raw/normalized handle string.
//
//  Fixture inventory (built by Tests/Fixtures/build_fixture_chat_db.sh):
//
//  Per-chat ROW counts include tapbacks (associated_message_type != 0)
//  which `MessageSearch.search` correctly excludes via the
//  `m.associated_message_type = 0` predicate, so the test expectations
//  below count REAL TEXT MESSAGES — not raw `chat_message_join` rows.
//
//    Chat 1 (style 45, 1:1, no name):      +15551234567, friend@example.com
//                                          26 join rows · 17 text msgs (9 tapbacks)
//    Chat 2 (style 43, "Test Group"):      +15551234567, +15557654321
//                                          3 join rows · 2 text msgs (1 tapback)
//    Chat 3 (style 45, 1:1, no name):      +15558889999
//                                          1 join row · 1 text msg
//    Chat 4 (style 43, "Dashboard Group"): all three numbers
//                                          5 join rows · 5 text msgs
//
//  Total text messages: 17 + 2 + 1 + 5 = 25
//

import XCTest
@testable import Hourglass

final class ChatOperatorE2ETests: XCTestCase {

    // MARK: - Helpers (mirrors FTSSearcherTests pattern)

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("Tests/Fixtures/chat.db not bundled — run build_fixture_chat_db.sh")
        }
        return url
    }

    private func tempIndexURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "Hourglass-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "index.sqlite", directoryHint: .notDirectory)
    }

    private struct Env {
        let chatDB: ChatDatabase
        let store: IndexStore
        let instr: MessageSearch
        let fts: FTSSearcher
        let cleanup: () -> Void
    }

    private func makeEnv() throws -> Env {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        let chatDB = try ChatDatabase(url: chatDBURL)
        let contacts = ResolvedContacts(byHandle: [:], allContacts: [])
        let store = try IndexStore(url: indexURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let instr = MessageSearch(database: chatDB, contacts: contacts)
        let fts = FTSSearcher(store: store, chatDB: chatDB, contacts: contacts)
        return Env(
            chatDB: chatDB,
            store: store,
            instr: instr,
            fts: fts,
            cleanup: { try? FileManager.default.removeItem(at: indexURL) }
        )
    }

    private func chatNames(_ results: [MessageSearch.Result]) -> Set<String> {
        Set(results.compactMap { $0.message.chatDisplayName })
    }

    private func chatIDs(_ results: [MessageSearch.Result]) -> Set<Int64> {
        Set(results.map { $0.message.chatRowID })
    }

    // MARK: - in: / chat: — substring match on display_name only

    /// `in:Test` should match every text message in the chat whose
    /// display_name contains "Test" (case-insensitive). The fixture has
    /// one such chat — "Test Group" with 2 text messages (1 tapback excluded).
    func test_in_namedGroup_matchesDisplayName() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:Test")
        XCTAssertEqual(hits.count, 2, "Expected 2 text messages in 'Test Group' (1 tapback excluded).")
        XCTAssertEqual(chatNames(hits), ["Test Group"])
    }

    /// `chat:Dashboard` — alias of `in:` — must match the same way.
    func test_chat_namedGroup_matchesDisplayName() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "chat:Dashboard")
        XCTAssertEqual(hits.count, 5, "Expected 5 messages in 'Dashboard Group'.")
        XCTAssertEqual(chatNames(hits), ["Dashboard Group"])
    }

    /// `in:` is case-insensitive — `in:test` matches "Test Group".
    /// SQLite's LIKE is case-insensitive for ASCII by default.
    func test_in_caseInsensitive() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let lowercase = try env.instr.search(phrase: "in:test")
        let uppercase = try env.instr.search(phrase: "in:TEST")
        XCTAssertEqual(lowercase.count, 2)
        XCTAssertEqual(chatIDs(lowercase), chatIDs(uppercase))
    }

    /// `in:Group` (substring shared by both named chats) returns the
    /// union of "Test Group" and "Dashboard Group".
    func test_in_substringMatchesMultipleNamedChats() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:Group")
        XCTAssertEqual(hits.count, 2 + 5, "Expected 2 (Test Group text) + 5 (Dashboard Group) messages.")
        XCTAssertEqual(chatNames(hits), ["Test Group", "Dashboard Group"])
    }

    /// `in:` on a substring that NO chat's display_name contains
    /// returns zero results. **Crucially**, this includes substrings
    /// that match participant handles — `in:` must NOT broaden into
    /// participant-based matching the way the pre-2026-05-25
    /// `chatClause` did.
    func test_in_nonexistentName_returnsZero() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:nonexistent")
        XCTAssertEqual(hits.count, 0)
    }

    /// `in:888` should match the **1:1 chat** whose participant
    /// handle contains "888" (Chat 3 — handle `+15558889999`). It must
    /// NOT match Chat 4 ("Dashboard Group") even though that group ALSO
    /// has handle 888 as a participant — `in:` only does participant
    /// matching for style=45 (1:1). Groups go through `with:` for
    /// participant-based matching.
    func test_in_handleSubstring_matches1to1Only() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:888")
        XCTAssertEqual(hits.count, 1, "Chat 3 has 1 text message; group Chat 4 is excluded by style=45 gate.")
        XCTAssertEqual(chatIDs(hits), [3])
    }

    /// `in:friend@example.com` should pick up the 1:1 with the user's
    /// two-handle contact (Chat 1) by participant matching.
    func test_in_emailHandle_matches1to1() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:friend@example.com")
        XCTAssertEqual(hits.count, 17, "Chat 1 has 17 text messages (9 tapbacks excluded).")
        XCTAssertEqual(chatIDs(hits), [1])
    }

    /// `in:7654321` — handle `+15557654321` participates in groups Chat 2
    /// and Chat 4, but NEITHER is a 1:1. So `in:` finds zero rows even
    /// though `with:7654321` would find them. This is the crucial
    /// invariant that distinguishes `in:` from `with:`.
    func test_in_groupOnlyHandle_returnsZero() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:7654321")
        XCTAssertEqual(
            hits.count, 0,
            "in:7654321 must NOT match groups by participant — handle 7654321 has no 1:1, only groups."
        )
        // Sanity: with: should pick the same handle up.
        let withHits = try env.instr.search(phrase: "with:7654321")
        XCTAssertEqual(withHits.count, 2 + 5, "with: should find Test Group + Dashboard Group.")
    }

    // MARK: - with: — participant-based, ANY chat (1:1 OR group)

    /// `with:` against a raw handle substring resolves the participant
    /// and matches every chat that participant is in.
    ///
    /// Handle `+15558889999` appears in:
    ///   - Chat 3 (1:1, no name) — 1 text msg
    ///   - Chat 4 ("Dashboard Group") — 5 text msgs
    /// Total = 6 text messages.
    func test_with_handleSubstring_matches1to1AndGroup() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "with:888")
        XCTAssertEqual(
            hits.count, 1 + 5,
            "with:888 must include both the 1:1 (chat 3) and the named group (chat 4)."
        )
        XCTAssertEqual(chatIDs(hits), [3, 4])
    }

    /// Handle `+15557654321` participates only in named groups (chats 2 and 4),
    /// not in any 1:1 → `with:7654321` must return Test Group + Dashboard Group.
    func test_with_namedGroupsOnly() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "with:7654321")
        XCTAssertEqual(hits.count, 2 + 5, "Expected Test Group (2 text) + Dashboard Group (5).")
        XCTAssertEqual(chatIDs(hits), [2, 4])
    }

    /// `with:friend@example.com` — the email handle is only in chat 1
    /// (the 1:1 with the user's two-handle contact). Test that `with:`
    /// correctly hits 1:1 chats even though their display_name is empty.
    /// Chat 1 has 26 join rows but 9 are tapbacks → 17 text messages.
    func test_with_email_matches1to1() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "with:friend@example.com")
        XCTAssertEqual(hits.count, 17, "Expected 17 text messages in chat 1 (9 tapbacks excluded).")
        XCTAssertEqual(chatIDs(hits), [1])
    }

    // MARK: - FTS parity

    /// The FTS path and the INSTR path must return the same set of
    /// message IDs for every chat-operator query. This is the regression
    /// guard that catches issues like the FTS path silently dropping
    /// rows due to a stale index or a missing JOIN.
    func test_parity_in_namedGroup() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let instrHits = try env.instr.search(phrase: "in:Test")
        let ftsHits = try env.fts.search(phrase: "in:Test")
        XCTAssertEqual(
            Set(instrHits.map(\.message.id)),
            Set(ftsHits.map(\.message.id)),
            "INSTR vs FTS parity for in:Test."
        )
    }

    func test_parity_with_handle() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let instrHits = try env.instr.search(phrase: "with:888")
        let ftsHits = try env.fts.search(phrase: "with:888")
        XCTAssertEqual(
            Set(instrHits.map(\.message.id)),
            Set(ftsHits.map(\.message.id)),
            "INSTR vs FTS parity for with:888."
        )
    }

    func test_parity_in_substringMultiple() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let instrHits = try env.instr.search(phrase: "in:Group")
        let ftsHits = try env.fts.search(phrase: "in:Group")
        XCTAssertEqual(
            Set(instrHits.map(\.message.id)),
            Set(ftsHits.map(\.message.id)),
            "INSTR vs FTS parity for in:Group."
        )
    }

    // MARK: - Composition

    /// `in:` AND `with:` together — both filters must hold. `in:Dashboard
    /// with:888` keeps only messages in "Dashboard Group" that also
    /// involve handle 888 → all 5 Dashboard messages (handle 888 is a
    /// participant).
    func test_in_and_with_together() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:Dashboard with:888")
        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(chatIDs(hits), [4])
    }

    /// Two `in:` filters AND together: a chat's display_name must
    /// contain both substrings. The fixture has no chat matching this,
    /// so result is empty.
    func test_in_andIn_intersection() throws {
        let env = try makeEnv(); defer { env.cleanup() }
        let hits = try env.instr.search(phrase: "in:Test in:Dashboard")
        XCTAssertEqual(
            hits.count, 0,
            "Multiple in: filters AND together — no chat's name contains both substrings."
        )
    }
}
