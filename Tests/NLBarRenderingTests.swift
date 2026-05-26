//
//  NLBarRenderingTests.swift
//  HourglassTests
//
//  Locks in the reactive contract between
//  `SearchViewModel.retryOpenIfNeeded()` and the dashboard NL bar's
//  placeholder → real-bar swap.
//
//  The user reported the same "NL bar stuck on 'Grant FDA' placeholder
//  even after granting FDA" bug twice. Root cause history:
//
//    1. `SearchViewModel.init()` opens chat.db ONCE. If TCC hasn't
//       settled yet (common race on cold launch of an ad-hoc-signed
//       binary), the single attempt fails and `database` stays nil.
//    2. `AppDelegate.nlSearchViewModel` returns nil when `database`
//       is nil (because the agent's tool surface needs a ChatDatabase).
//    3. The dashboard's `nlBar` view renders the placeholder when
//       `nlSearchViewModel` is nil.
//    4. AppDelegate is NOT @Observable, so SwiftUI doesn't know to
//       re-render when `_nlSearchViewModel` flips. The conditional
//       `if let nlVM = (NSApp.delegate as? AppDelegate)?...` is
//       invisible to the observation graph.
//
//  Fix shape: the dashboard reads `searchViewModel?.database` (which
//  IS @Observable on SearchViewModel) in its body, AND calls
//  `retryOpenIfNeeded()` from `.onAppear` and from the placeholder's
//  `.task`. The reactive edge into the observation graph is the
//  `database` read; the retry is what flips it.
//
//  These tests cover the observable contract:
//    - retryOpenIfNeeded is idempotent (no-op when db already open).
//    - retryOpenIfNeeded SUCCEEDS when given a valid (fixture) URL,
//      flipping database nil → non-nil and clearing setupError.
//    - retryOpenIfNeeded FAILS gracefully when given a bad URL,
//      leaving database nil and setupError set.
//    - retryOpenIfNeeded triggers SwiftUI observation: an explicit
//      Observation registration sees the database write.
//    - The `messageSearch` (instrEngine) accessor is also rebuilt by
//      the retry (the AppDelegate.nlAgent getter depends on it).
//
//  All tests are pure-Swift and don't require chat.db / FDA on the
//  test runner: they use the bundled fixture chat.db.
//

import Foundation
import Observation
import XCTest
@testable import Hourglass

@MainActor
final class NLBarRenderingTests: XCTestCase {

    /// Open the bundled fixture for the success-path test.
    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        return url
    }

    /// A URL guaranteed to fail open (no file there). For the failure-path test.
    private var badURL: URL {
        URL(fileURLWithPath: "/var/tmp/Hourglass — does-not-exist-\(UUID().uuidString).db")
    }

    // MARK: - Idempotency

    /// Once the database is open, repeated calls to `retryOpenIfNeeded()`
    /// are cheap no-ops. This matters because `nlBar` calls it on every
    /// placeholder render and `nlAgent` calls it on every getter access.
    func testRetryIsIdempotent_whenAlreadyOpen() throws {
        let vm = SearchViewModel()
        // Force a successful open via fixture so we have a known state.
        let url = try fixtureURL()
        let first = vm.retryOpenIfNeeded(url: url)
        // Note: SearchViewModel.init() ALSO tries to open the real chat.db.
        // It may have succeeded (returns true on first call) or failed; we
        // assert only the post-condition that's invariant.
        XCTAssertTrue(first, "First retry against the fixture URL must succeed (file exists, readable).")
        XCTAssertNotNil(vm.database, "Database must be non-nil after a successful retry.")
        XCTAssertNotNil(vm.messageSearch, "INSTR engine must be built post-retry.")
        XCTAssertNil(vm.setupError, "setupError must be cleared on success.")

        // Second call is a no-op (database non-nil).
        let second = vm.retryOpenIfNeeded(url: url)
        XCTAssertTrue(second, "Idempotent retry should still report ready.")
        XCTAssertNotNil(vm.database, "Database stays non-nil after idempotent retry.")
    }

    // MARK: - Failure path

    /// Bad URL → retry returns false, database stays nil, setupError is set.
    /// This mirrors the no-FDA case where the file is inaccessible.
    ///
    /// Note: we can't reliably get the vm into "no db, never tried"
    /// state under XCTest (init() always tries the real chat.db). So
    /// we test the failure path by re-trying with a known-bad URL only
    /// when init() already failed (the test runner doesn't have FDA).
    func testRetryFailsGracefully_whenURLIsBad() throws {
        let vm = SearchViewModel()
        // If init() somehow succeeded against the real chat.db (test
        // runner has FDA), retry is a no-op and we can't exercise the
        // bad-URL path from here. Skip in that case.
        try XCTSkipIf(
            vm.database != nil,
            "Test runner has FDA-granted access to real chat.db; init() succeeded. The bad-URL retry path is unreachable from this state."
        )
        let didOpen = vm.retryOpenIfNeeded(url: badURL)
        XCTAssertFalse(didOpen, "Retry against a non-existent URL must return false.")
        XCTAssertNil(vm.database, "Database must remain nil after failed retry.")
        XCTAssertNil(vm.messageSearch, "INSTR engine must stay nil after failed retry.")
        XCTAssertNotNil(vm.setupError, "setupError must be set after a failed retry so the UI can surface it.")
    }

    // MARK: - Reactive edge — the load-bearing fix

    /// The whole point of the dashboard fix: SwiftUI views that read
    /// `SearchViewModel.database` MUST be notified when retryOpenIfNeeded
    /// flips it from nil → non-nil. We verify this by using the
    /// Observation framework directly — same machinery SwiftUI uses.
    ///
    /// `withObservationTracking` registers the closure's reads with the
    /// observation graph; the onChange callback fires once on the next
    /// mutation of any tracked property.
    func testDatabaseWriteTriggersObservation() throws {
        let vm = SearchViewModel()
        let url = try fixtureURL()

        // If init() already succeeded (FDA granted on the test runner),
        // skip — we can't test the transition from a state we can't reach.
        if vm.database != nil {
            throw XCTSkip("Init succeeded — can't test the nil → non-nil transition from this state.")
        }

        let didFire = expectation(description: "Observation fires when database flips nil → non-nil")
        withObservationTracking {
            // Read the property we care about. Any subsequent write to it
            // will fire the onChange closure exactly once.
            _ = vm.database
        } onChange: {
            // This runs on the writer's actor; we just signal the
            // expectation. The test's main actor pulls it from the
            // shared expectation pool.
            didFire.fulfill()
        }

        // Trigger the transition.
        let ok = vm.retryOpenIfNeeded(url: url)
        XCTAssertTrue(ok)

        wait(for: [didFire], timeout: 1.0)
    }

    // MARK: - Post-retry: engines and chats are populated

    /// After a successful retry, the dependencies the AppDelegate.nlAgent
    /// getter checks (`viewModel.database` AND `viewModel.messageSearch`)
    /// must BOTH be non-nil. If either stays nil, the agent build fails
    /// and the placeholder keeps showing.
    func testRetrySucceeds_bothDatabaseAndMessageSearchPopulated() throws {
        let vm = SearchViewModel()
        let url = try fixtureURL()

        let ok = vm.retryOpenIfNeeded(url: url)
        XCTAssertTrue(ok)
        // These are the EXACT two reads the AppDelegate.nlAgent getter
        // performs. If both are non-nil, the agent will build and the
        // bar will render.
        XCTAssertNotNil(vm.database, "AppDelegate.nlAgent reads `viewModel.database`.")
        XCTAssertNotNil(vm.messageSearch, "AppDelegate.nlAgent reads `viewModel.messageSearch`.")
    }

    // MARK: - allChats refresh (autocomplete dependency)

    /// `allChats` is read by autocomplete and by the empty-state
    /// suggestion builder. retryOpenIfNeeded should populate it so the
    /// dashboard's "Try this" pills don't stay empty after a delayed
    /// FDA grant.
    func testRetryPopulatesAllChats() throws {
        let vm = SearchViewModel()
        let url = try fixtureURL()
        _ = vm.retryOpenIfNeeded(url: url)
        // The fixture has 4 chats per Tests/Fixtures/README.md.
        XCTAssertGreaterThan(vm.allChats.count, 0, "allChats should be populated post-retry.")
    }
}
