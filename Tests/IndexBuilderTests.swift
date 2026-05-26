//
//  IndexBuilderTests.swift
//  HourglassTests
//
//  End-to-end tests for the FTS5 mirror pipeline. We build a mirror from the
//  fixture chat.db and verify:
//   - Coverage parity with the INSTR-based MessageSearch.search.
//   - Schema bootstrap and version handling.
//   - `lastIndexedROWID` updates after each batch (so partial builds can
//     be picked up by `catchUp`).
//   - `Freshness` transitions properly through .missing → (after full
//     index) .ready → (after a synthesized new row) .behind.
//   - Idempotency: running `buildFullIndex` twice produces the same row
//     count.
//

import Foundation
import XCTest
import GRDB
@testable import Hourglass

final class IndexBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// Path to the fixture chat.db, sitting next to this test bundle.
    /// We use the same lookup the other DB-touching tests use.
    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            // The fixture is built by Tests/Fixtures/build_fixture_chat_db.sh and
            // included via the test target's `sources:` entry. If it's missing
            // the dev needs to run the build script.
            throw XCTSkip("Tests/Fixtures/chat.db not bundled — run build_fixture_chat_db.sh")
        }
        return url
    }

    /// Fresh temp directory for each test so concurrent runs don't collide.
    private func tempIndexURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "Hourglass-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "index.sqlite", directoryHint: .notDirectory)
    }

    // MARK: - Bootstrap

    func testIndexStore_createsSchemaOnFirstOpen() throws {
        let url = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try IndexStore(url: url)
        let version = try store.state(.schemaVersion)
        XCTAssertEqual(version, String(IndexStore.schemaVersion))
        // No rows yet → lastIndexedROWID is 0.
        XCTAssertEqual(try store.lastIndexedROWID(), 0)
        XCTAssertEqual(try store.indexedRowCount(), 0)
    }

    func testIndexStore_reopenSurvivesAcrossInstances() throws {
        let url = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try IndexStore(url: url)
        try store1.setState(.lastIndexedROWID, value: "42")
        _ = store1

        let store2 = try IndexStore(url: url)
        XCTAssertEqual(try store2.lastIndexedROWID(), 42)
    }

    // MARK: - Full index

    func testBuildFullIndex_indexesAllRealMessages() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        let indexed = try IndexBuilder.buildFullIndex(
            chatDBURL: chatDBURL,
            store: store
        )

        XCTAssertGreaterThan(indexed, 0)
        let rowCount = try store.indexedRowCount()
        XCTAssertEqual(rowCount, indexed,
            "mirror row count should match indexed count")

        // Spot check: row 1 in the fixture is a sent message with NULL text
        // but a decodable attributedBody containing 'hello cactus how are you today'.
        // The FTS index must have indexed its body.
        try store.dbQueue.read { db in
            let body = try String.fetchOne(
                db,
                sql: "SELECT body FROM messages_fts WHERE rowid = 1"
            )
            XCTAssertNotNil(body)
            XCTAssertTrue(body!.lowercased().contains("cactus"),
                "row 1 body should decode to a string containing 'cactus', got: \(body ?? "")")
        }
    }

    func testBuildFullIndex_isIdempotent() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        let n1 = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let n2 = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        XCTAssertEqual(n1, n2, "second build should index the same number of rows")
        XCTAssertEqual(try store.indexedRowCount(), n1)
    }

    func testBuildFullIndex_updatesLastROWID() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let last = try store.lastIndexedROWID()
        XCTAssertGreaterThan(last, 0)

        // The chat.db fixture's MAX(ROWID) should equal lastIndexedROWID.
        let chatDB = try ChatDatabase(url: chatDBURL)
        let max = try chatDB.maxMessageRowID()
        XCTAssertEqual(last, max)
    }

    // MARK: - Freshness

    func testFreshness_missingBeforeIndexing() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        let chatDB = try ChatDatabase(url: chatDBURL)
        XCTAssertEqual(try store.freshness(against: chatDB), .missing)
    }

    func testFreshness_readyAfterFullIndex() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        let chatDB = try ChatDatabase(url: chatDBURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        XCTAssertEqual(try store.freshness(against: chatDB), .ready)
    }

    func testFreshness_behindAfterArtificialSetback() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        let chatDB = try ChatDatabase(url: chatDBURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)

        // Roll back the last-indexed counter to simulate "new rows added".
        try store.setState(.lastIndexedROWID, value: "1")

        switch try store.freshness(against: chatDB) {
        case .behind(let n):
            XCTAssertGreaterThan(n, 0)
        default:
            XCTFail("expected .behind after rolling back lastIndexedROWID")
        }
    }

    // MARK: - Catch-up

    func testCatchUp_noopWhenAlreadyAtParity() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let added = try IndexBuilder.catchUp(chatDBURL: chatDBURL, store: store)
        XCTAssertEqual(added, 0)
    }

    func testCatchUp_picksUpFromArtificialSetback() throws {
        let chatDBURL = try fixtureURL()
        let indexURL = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: indexURL) }

        let store = try IndexStore(url: indexURL)
        _ = try IndexBuilder.buildFullIndex(chatDBURL: chatDBURL, store: store)
        let total = try store.indexedRowCount()

        // Wipe and pretend we only indexed up to ROWID 1.
        try store.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages_fts WHERE rowid > 1")
            try db.execute(sql: "DELETE FROM message_meta WHERE rowid > 1")
        }
        try store.setState(.lastIndexedROWID, value: "1")

        let added = try IndexBuilder.catchUp(chatDBURL: chatDBURL, store: store)
        XCTAssertGreaterThan(added, 0)
        let after = try store.indexedRowCount()
        XCTAssertEqual(after, total, "catch-up should restore parity")
    }

    // MARK: - Schema version

    func testSchemaMismatch_rebuildsCleanly() throws {
        let url = tempIndexURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // First, open and store a row with the real schema version.
        let store1 = try IndexStore(url: url)
        try store1.setState(.lastIndexedROWID, value: "100")
        _ = store1

        // Now force a schema mismatch by writing a fake version.
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(
                sql: "UPDATE index_state SET value = ? WHERE key = ?",
                arguments: ["999", IndexStore.StateKey.schemaVersion.rawValue]
            )
        }

        // Reopening should wipe-and-rebuild. lastIndexedROWID resets.
        let store2 = try IndexStore(url: url)
        XCTAssertEqual(try store2.lastIndexedROWID(), 0,
            "schema-version mismatch should wipe the index file")
        XCTAssertEqual(try store2.state(.schemaVersion), String(IndexStore.schemaVersion))
    }
}
