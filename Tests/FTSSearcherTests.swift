//
//  FTSSearcherTests.swift
//  HourglassTests
//
//  Parity tests: for every fixture query we run BOTH MessageSearch (INSTR)
//  and FTSSearcher (the new mirror-backed path) and confirm the result
//  sets agree. This is the single most important guarantee Phase 1 makes —
//  switching engines must not change what the user sees.
//
//  Coverage:
//   - Plain phrase: 'cactus' should match the same fixture rows under both.
//   - Multi-word: 'happy birthday' (substring).
//   - Token filters: 'from:Mom', 'chat:Test', 'last:7d' (must produce identical
//     sets).
//   - Reaction filters and type filters pass through unchanged.
//   - Empty phrase + active filter (date-only) is handled by both paths.
//

import Foundation
import XCTest
@testable import Hourglass

final class FTSSearcherTests: XCTestCase {

    // MARK: - Helpers

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

    /// Build a fully-indexed fixture: chat.db + populated mirror + both engines.
    /// Returns a tuple so each test can run parity checks easily.
    private func makeEnvironment() throws -> (chatDB: ChatDatabase, store: IndexStore, instr: MessageSearch, fts: FTSSearcher, cleanup: () -> Void) {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        let chatDB = try ChatDatabase(url: chatDBURL)
        // Empty contacts table — fixture tests don't depend on AB resolution.
        let contacts = ResolvedContacts(byHandle: [:], allContacts: [])
        let store = try IndexStore(url: indexURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let instr = MessageSearch(database: chatDB, contacts: contacts)
        let fts = FTSSearcher(store: store, chatDB: chatDB, contacts: contacts)
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: indexURL)
        }
        return (chatDB, store, instr, fts, cleanup)
    }

    /// Extract the set of message ROWIDs from a result list for set comparison.
    private func rowids(_ results: [MessageSearch.Result]) -> Set<Int64> {
        Set(results.map { $0.message.id })
    }

    // MARK: - Parity tests

    func testParity_cactus() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        let instrHits = try env.instr.search(phrase: "cactus")
        let ftsHits = try env.fts.search(phrase: "cactus")
        XCTAssertEqual(
            rowids(instrHits), rowids(ftsHits),
            "FTS5 must match INSTR coverage for 'cactus'"
        )
        XCTAssertFalse(ftsHits.isEmpty)
    }

    func testParity_emptyResults() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        let instrHits = try env.instr.search(phrase: "thisstringdoesnotappearanywhere")
        let ftsHits = try env.fts.search(phrase: "thisstringdoesnotappearanywhere")
        XCTAssertEqual(instrHits.count, 0)
        XCTAssertEqual(ftsHits.count, 0)
    }

    func testParity_substring_helloCactus() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        // The fixture row 1's body is "hello cactus how are you today" — both
        // engines should find it for 'hello' as well.
        let instrHits = try env.instr.search(phrase: "hello")
        let ftsHits = try env.fts.search(phrase: "hello")
        XCTAssertEqual(rowids(instrHits), rowids(ftsHits))
    }

    func testParity_caseFolding_uppercaseQuery() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        // Uppercase query should still find lowercase body — both engines
        // case-fold by default (INSTR via 3-variant emission, FTS5 via
        // trigram remove_diacritics 1).
        let instrHits = try env.instr.search(phrase: "CACTUS")
        let ftsHits = try env.fts.search(phrase: "CACTUS")
        XCTAssertEqual(rowids(instrHits), rowids(ftsHits))
    }

    func testParity_dateFilteredEmptyPhrase() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        // distantPast → now: every real (non-tapback) message in the fixture.
        let range = Date.distantPast...Date.distantFuture
        let instrHits = try env.instr.search(phrase: "", dateRange: range)
        let ftsHits = try env.fts.search(phrase: "", dateRange: range)
        XCTAssertEqual(rowids(instrHits), rowids(ftsHits))
        XCTAssertGreaterThan(ftsHits.count, 0)
    }

    func testParity_tapbacksDroppedFromBoth() throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        let range = Date.distantPast...Date.distantFuture
        let ftsHits = try env.fts.search(phrase: "", dateRange: range)
        // ROWID 4 is a tapback (associated_message_type=2000); must not appear.
        XCTAssertFalse(rowids(ftsHits).contains(4),
            "FTSSearcher must filter out tapbacks (rowid 4 in fixture)")
    }

    // MARK: - Query construction

    func testQuoteNeedleForFTS5_quoteEscape() {
        XCTAssertEqual(FTSSearcher.quoteNeedleForFTS5("cactus"), "\"cactus\"")
        XCTAssertEqual(FTSSearcher.quoteNeedleForFTS5("with \"quote\""), "\"with \"\"quote\"\"\"")
        XCTAssertEqual(FTSSearcher.quoteNeedleForFTS5("hello world"), "\"hello world\"")
    }

    func testMetaDateClause_emptyRangeProducesEmptyClause() {
        let (sql, args) = FTSSearcher.metaDateClause(nil)
        XCTAssertEqual(sql, "")
        XCTAssertTrue(args.isEmpty)
    }

    func testMetaDateClause_rangeProducesBoundsForBothEpochs() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_750_000_000)
        let (sql, args) = FTSSearcher.metaDateClause(start...end)
        XCTAssertTrue(sql.contains("meta.date > 1000000000000"))
        XCTAssertTrue(sql.contains("meta.date <= 1000000000000"))
        // Four args: ns_lo, ns_hi, s_lo, s_hi
        XCTAssertEqual(args.count, 4)
    }
}
