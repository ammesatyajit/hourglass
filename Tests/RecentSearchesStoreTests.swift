//
//  RecentSearchesStoreTests.swift
//  HourglassTests
//
//  Pure-logic tests for the recents store. Pin the contract the UI relies
//  on: dedup, ordering, cap, persistence-across-instances, minimum length.
//

import XCTest
@testable import Hourglass

final class RecentSearchesStoreTests: XCTestCase {

    /// Make an isolated UserDefaults suite per test so persistence is real
    /// but doesn't leak between tests or into the user's actual defaults.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "Hourglass.RecentSearchesStoreTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testRecordAddsToFront() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("alpha")
        store.record("beta")
        store.record("gamma")
        XCTAssertEqual(store.entries, ["gamma", "beta", "alpha"])
    }

    func testRepeatBumpsToFrontWithoutDuplicating() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("alpha")
        store.record("beta")
        store.record("alpha")
        XCTAssertEqual(store.entries, ["alpha", "beta"],
                       "repeating a query should bump it to the front, not duplicate")
    }

    func testCaseInsensitiveDedup() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("Cactus")
        store.record("beta")
        store.record("cactus")
        XCTAssertEqual(store.entries, ["cactus", "beta"],
                       "case-insensitive dedup should treat Cactus and cactus as the same")
    }

    func testCapEnforced() {
        let store = RecentSearchesStore(defaults: makeDefaults(), maxEntries: 3)
        // Min length is 2 so single-char strings are dropped; use ≥2 chars
        // so the cap behavior is what's actually under test here.
        store.record("aa")
        store.record("bb")
        store.record("cc")
        store.record("dd")
        XCTAssertEqual(store.entries, ["dd", "cc", "bb"],
                       "older entries should fall off when the cap is exceeded")
    }

    func testMinLengthIgnored() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("x")        // too short
        store.record("")         // empty
        store.record("  ")       // whitespace only
        store.record("ok")
        XCTAssertEqual(store.entries, ["ok"])
    }

    func testWhitespaceTrimmed() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("  cactus from:Mom  ")
        XCTAssertEqual(store.entries, ["cactus from:Mom"])
    }

    func testRemoveByExactMatch() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("alpha")
        store.record("beta")
        store.record("gamma")
        store.remove("beta")
        XCTAssertEqual(store.entries, ["gamma", "alpha"])
    }

    func testClearWipesAll() {
        let store = RecentSearchesStore(defaults: makeDefaults())
        store.record("alpha")
        store.record("beta")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistenceAcrossInstances() {
        let defaults = makeDefaults()
        let first = RecentSearchesStore(defaults: defaults)
        first.record("alpha")
        first.record("beta")

        let second = RecentSearchesStore(defaults: defaults)
        XCTAssertEqual(second.entries, ["beta", "alpha"],
                       "a fresh store should load entries persisted by the previous instance")
    }

    func testCorruptedPersistedEntriesFilteredOnLoad() {
        let defaults = makeDefaults()
        // Simulate an older version that stored some sub-min-length junk.
        defaults.set(["", "x", "real query", "  ", "another one"],
                     forKey: RecentSearchesStore.defaultsKey)
        let store = RecentSearchesStore(defaults: defaults)
        XCTAssertEqual(store.entries, ["real query", "another one"])
    }
}
