//
//  SearchViewModel.swift
//  Hourglass
//
//  Observable view model that the UI (design-agent's territory) binds to.
//  Pure state holder + async search trigger; no SwiftUI views in this file.
//
//  Design contract
//  ---------------
//  - `query` is the user-typed phrase (supports `a+b` co-occurrence).
//  - `selectedContact` is the optional person filter.
//  - `dateRange` is the optional date filter.
//  - `results` is the current result set (sorted **descending** by date —
//    newest first, matching Spotlight expectations).
//  - Call `searchSoon()` to schedule a debounced search (typical for typing).
//  - Call `search()` to run immediately (Enter, submit, programmatic refresh).
//
//  Result accuracy
//  ---------------
//  Search is **exhaustive** — every matching message is returned. No silent
//  truncation. For typing latency we use a generation counter to discard
//  superseded results; the underlying engine still runs to completion for
//  each search but we ignore its output once a newer search has started.
//
//  Two-track engine
//  ----------------
//  The view model holds BOTH the INSTR-based `MessageSearch` engine (the
//  source-of-truth correctness path, always available) and the FTS5-based
//  `FTSSearcher` (an optimization that runs when the local mirror is fresh).
//  Routing per call:
//
//    1. If the FTS5 mirror is `.ready` (last-indexed ROWID >= chat.db MAX
//       ROWID), route to `FTSSearcher` — ~3ms per query on 525k rows.
//    2. Otherwise route to `MessageSearch` (INSTR path) — ~1s per query.
//       A background `IndexSync` task is catching the mirror up in parallel,
//       so the user transparently shifts to the fast path as soon as the
//       index reaches parity.
//
//  This means: search is always correct AND always available — even on a
//  cold launch with no index yet, even if the index file gets corrupted.
//  The FTS5 path is a pure perf win when present.
//
//  Indexing UX
//  -----------
//  On first launch we kick off `IndexBuilder.buildFullIndex` in the
//  background. `indexingProgress` is published to the UI so a non-blocking
//  banner can show "Indexing your messages…" with a progress bar. Search
//  works (via INSTR) while the banner is up.
//
//  Lifecycle
//  ---------
//  - The DB and contacts list are loaded on `init`. If either fails (e.g. no
//    Full Disk Access), `setupError` carries the message and `results` stays
//    empty.
//  - We DO NOT throw from init — the UI needs to present the error gracefully.
//

import Foundation
import Observation
import os

/// Logger for the "FDA grant → NL bar rendering" path. Filter in Console.app:
///   `subsystem == "com.satyajit.bettermessages" && category == "nl-bar-rendering"`
/// Every transition in the chain (retry attempts, agent build, view model
/// build, body re-eval) emits here so future TCC-timing bugs are diagnosable
/// without a code change.
private let nlBarLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-bar-rendering"
)

@Observable
@MainActor
public final class SearchViewModel {

    // MARK: - Bindable state

    public var query: String = ""
    public var selectedContact: Contact?
    public var dateRange: ClosedRange<Date>?
    /// When true, the phrase match is case-sensitive (GLOB + byte-exact INSTR
    /// instead of the default ASCII-folding LIKE + 3-variant INSTR). Driven
    /// by the `Aa` toggle in the search field.
    public var caseSensitive: Bool = false

    public private(set) var results: [MessageSearch.Result] = []
    public private(set) var allContacts: [Contact] = []
    public private(set) var allChats: [ChatInfo] = []
    public private(set) var isSearching: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var setupError: String?

    /// The open ChatDatabase, exposed so panel reveal logic can use it for
    /// participant lookups. nil if the DB failed to open at init time.
    public private(set) var database: ChatDatabase?

    /// Progress of the background first-launch indexer (or a catch-up that's
    /// trailing far enough behind to be worth showing). Nil when no indexing
    /// is in flight (the common steady state).
    public private(set) var indexingProgress: IndexingProgress?

    /// Whether the FTS5 fast path is currently in use. Surfaced for the UI's
    /// optional "Searching via index" footer hint and for tests. Recomputed
    /// at every `search()` call.
    public private(set) var usingIndex: Bool = false

    /// Diagnostic — the open `IndexStore`, if we managed to open one.
    public private(set) var indexStore: IndexStore?

    // MARK: - Engines

    private var instrEngine: MessageSearch?
    private var ftsEngine: FTSSearcher?

    /// Public accessor for the INSTR engine — used by the NL agent's
    /// tool surface so the LLM's structured queries route through the
    /// same engine the keyword Spotlight panel uses. Nil before the
    /// chat.db opens successfully.
    public var messageSearch: MessageSearch? { instrEngine }

    /// Public accessor for the FTS5 engine — used by the NL agent's
    /// tool surface for the fast-path routing decision. Nil when the
    /// index file couldn't be opened.
    public var ftsSearcher: FTSSearcher? { ftsEngine }

    /// Background sync actor. Polls chat.db for new ROWIDs and catches the
    /// mirror up incrementally. nil if the index couldn't be opened.
    private var indexSync: IndexSync?

    /// Monotonic counter — incremented on every search request.
    private var searchGeneration: Int = 0

    /// Max rows a LIVE (as-you-type) search materializes. Without a cap,
    /// a broad partial inside an operator (`with:"Be` on the way to "Beck")
    /// matched tens of thousands of rows and DECODED EVERY attributedBody
    /// per keystroke — seconds of pegged CPU per character, stacking with
    /// each keypress (the detached search isn't cancellable mid-query).
    /// 500 fills the panel many screens deep; the footer shows "500+" so
    /// the cap is never mistaken for an exact count.
    public nonisolated static let liveResultCap = 500

    /// The pending debounced search, if any.
    private var debounceTask: Task<Void, Never>?

    /// The in-flight detached search, if any. Held so a newer query can
    /// cancel the old scan mid-hydration (the engines check
    /// `Task.checkCancellation` every 256 rows) instead of letting
    /// discarded work finish and hog CPU behind the live search.
    private var activeSearchTask: Task<Result<[MessageSearch.Result], Error>, Never>?

    // MARK: - Pagination (reach EVERYTHING, one capped page at a time)

    /// True when the last loaded page came back full — older matches may
    /// exist beyond what's loaded. Drives the panel's infinite scroll.
    public private(set) var canLoadOlder: Bool = false
    /// True while an older page is being fetched (guards re-entrancy from
    /// repeated scroll-bottom triggers).
    public private(set) var isLoadingOlder: Bool = false

    /// Fetch the next (older) page of the CURRENT query and append it.
    ///
    /// Keyset pagination: the page window's upper bound is the oldest loaded
    /// result's date (inclusive, so equal-timestamp rows can't fall in the
    /// gap); rows already present are dropped by ROWID. Each page pays the
    /// same capped cost as a live search — everything is reachable without
    /// any single scan ambushing the UI.
    public func loadOlderResults() async {
        guard canLoadOlder, !isLoadingOlder, !isSearching,
              let oldest = results.last?.message.date,
              let instrEngine else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let myGen = searchGeneration
        let phrase = query
        let person = selectedContact
        let caseSensitive = self.caseSensitive
        // Intersect the user's own date filter with the page window.
        let lower = dateRange?.lowerBound ?? Date.distantPast
        guard lower <= oldest else { canLoadOlder = false; return }
        let pageRange = lower...oldest

        let useFTS = usingIndex
        let fts = ftsEngine
        let pageTask = Task.detached(priority: .userInitiated) {
            do {
                let res: [MessageSearch.Result]
                if useFTS, let fts {
                    res = try fts.search(
                        phrase: phrase, person: person, dateRange: pageRange,
                        limit: Self.liveResultCap, caseSensitive: caseSensitive
                    )
                } else {
                    res = try instrEngine.search(
                        phrase: phrase, person: person, dateRange: pageRange,
                        limit: Self.liveResultCap, caseSensitive: caseSensitive
                    )
                }
                return Result<[MessageSearch.Result], Error>.success(res)
            } catch {
                return .failure(error)
            }
        }
        let outcome = await pageTask.value

        // The query changed while we were paging — drop the stale page.
        guard searchGeneration == myGen else { return }
        switch outcome {
        case .success(let page):
            let seen = Set(results.map(\.message.id))
            let fresh = page.filter { !seen.contains($0.message.id) }
            results.append(contentsOf: fresh)
            // A full page (before dedupe) means there may be more below.
            canLoadOlder = page.count >= Self.liveResultCap
        case .failure(let err):
            if err is CancellationError { return }
            canLoadOlder = false
        }
    }

    // MARK: - Indexing progress type

    public struct IndexingProgress: Sendable, Equatable {
        public let indexed: Int64
        public let total: Int64?
        public let isFullIndex: Bool
        public init(indexed: Int64, total: Int64?, isFullIndex: Bool) {
            self.indexed = indexed
            self.total = total
            self.isFullIndex = isFullIndex
        }
    }

    /// Resolved contacts. Stashed so `retryOpenIfNeeded()` and
    /// `adoptOpenDatabase` can rebuild engines without re-resolving
    /// (cheap but not free — ~50 ms on the user's AddressBook).
    private let resolvedContacts: ResolvedContacts

    /// Take a chat.db handle that ANOTHER viewmodel already opened
    /// successfully (typically `DashboardViewModel`'s, which opens lazily
    /// on `.onAppear` and therefore wins races against init-time opens
    /// that fire before TCC settles). Bypasses the
    /// `retryOpenIfNeeded` ceremony — the caller has already proven the
    /// DB opens in this process, so we just need to attach.
    ///
    /// Idempotent: if we already have a database, this is a no-op (we
    /// don't clobber a working state with someone else's handle, just to
    /// avoid two handles to the same file).
    ///
    /// This is the user-suggested fix for the "NL bar stuck on Grant FDA
    /// even though dashboard stats load" bug — the dashboard's check IS
    /// the signal we should use, so just share its working handle.
    public func adoptOpenDatabase(_ db: ChatDatabase) {
        if database != nil {
            nlBarLogger.debug("adoptOpenDatabase: already have a database, ignoring")
            return
        }
        nlBarLogger.info("adoptOpenDatabase: attaching pre-opened ChatDatabase from caller")
        self.instrEngine = MessageSearch(database: db, contacts: resolvedContacts)
        self.setupError = nil
        if let chats = try? ChatListing.allChats(database: db, contacts: resolvedContacts) {
            self.allChats = chats
        }
        // Write `database` LAST — that's the observable other views
        // condition on; everything else should be ready when the
        // observation fires.
        self.database = db
        // Same FTS5 backfill as `retryOpenIfNeeded`'s success path so
        // post-attach searches use the fast index instead of INSTR.
        let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
        if !isUnderTest, indexStore == nil, ftsEngine == nil {
            Task { [weak self] in
                await self?.bootstrapIndexAfterRetry(chatDB: db)
            }
        }
    }

    public init() {
        let contacts = ContactResolver.resolve()
        self.resolvedContacts = contacts
        self.allContacts = contacts.allContacts

        // chat.db open — required for ANY search to work.
        let chatDB: ChatDatabase?
        do {
            let db = try ChatDatabase()
            chatDB = db
            self.database = db
            self.instrEngine = MessageSearch(database: db, contacts: contacts)
        } catch let err as ChatDatabase.OpenError {
            self.setupError = String(describing: err)
            chatDB = nil
        } catch {
            self.setupError = "Failed to open chat.db: \(error)"
            chatDB = nil
        }

        // Chats enumeration (non-fatal).
        if let db = chatDB,
           let chats = try? ChatListing.allChats(database: db, contacts: contacts) {
            self.allChats = chats
        }

        // Index file — best-effort. Failure here is silent; we just stay on
        // the INSTR path.
        //
        // We skip the auto-indexer in test contexts. xctest sets
        // `XCTestConfigurationFilePath` in the test host's environment; under
        // that signal we never spin up a background polling task. Tests that
        // exercise the index code path build their own IndexStore + Builder
        // directly and don't go through this constructor.
        let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil

        if let chatDB, !isUnderTest {
            do {
                let store = try IndexStore()
                self.indexStore = store
                self.ftsEngine = FTSSearcher(store: store, chatDB: chatDB, contacts: contacts)
                let sync = IndexSync(store: store, chatDBURL: chatDB.url)
                self.indexSync = sync

                // Kick off the appropriate first-launch action based on
                // freshness. We do this in a Task so init returns promptly.
                Task { [weak self] in
                    await self?.bootstrapIndexIfNeeded(store: store, chatDB: chatDB)
                    await sync.start()
                }
            } catch {
                // Index file unavailable — log + stay on INSTR path.
                #if DEBUG
                print("IndexStore open failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Recovery from initially-denied FDA

    /// Retry opening chat.db if the init-time open failed (e.g. FDA was
    /// denied at process start; user granted it WHILE the app was
    /// running). Idempotent — no-op if `database` is already non-nil.
    ///
    /// Why this exists: each ChatDatabase instance lives in its own
    /// SQLite handle; the process-wide TCC grant changes don't
    /// retroactively rescue an already-stored nil. Without a retry path
    /// the user has to ⌘Q + relaunch the app to recover, which they
    /// already do via the Relaunch button — BUT in practice
    /// rebuild-and-launch sequences race the grant evaluation: the
    /// AppDelegate's SearchViewModel is constructed before TCC settles,
    /// the dashboard's DashboardViewModel is constructed later (on
    /// `.onAppear`) and lands on the good side. This made the dashboard
    /// stats populate while the NL bar's placeholder kept claiming "no
    /// FDA". Calling this on `nlAgent` access fixes that disconnect.
    ///
    /// Returns true iff the database is now available (either because it
    /// already was, or because the retry succeeded).
    @discardableResult
    public func retryOpenIfNeeded(url: URL = ChatDatabase.defaultURL) -> Bool {
        if database != nil {
            nlBarLogger.debug("retryOpenIfNeeded: db already open, no-op")
            return true
        }
        nlBarLogger.info("retryOpenIfNeeded: attempting fresh ChatDatabase open at \(url.path, privacy: .public)")
        do {
            let db = try ChatDatabase(url: url)
            // Order of writes matters for SwiftUI observation: we set
            // `database` LAST so any observer waiting on the nil → non-nil
            // transition sees the engines + chats already populated when
            // it re-renders. (Observable batches notifications per
            // microtask, but defensive ordering is still cleaner.)
            self.instrEngine = MessageSearch(database: db, contacts: resolvedContacts)
            // Now that the DB is open, clear the setup error so any UI
            // bound to it stops showing the "Can't open Messages" panel.
            self.setupError = nil
            // Best-effort: also surface the chats list so autocomplete
            // (which depends on `allChats`) works for NL/keyword queries.
            if let chats = try? ChatListing.allChats(database: db, contacts: resolvedContacts) {
                self.allChats = chats
            }
            self.database = db
            nlBarLogger.info("retryOpenIfNeeded: SUCCESS — db opened, instrEngine built")
            // Kick the FTS5 index up as well so post-retry searches can
            // still benefit from the fast path. Fire-and-forget Task: the
            // index bootstrap runs on a background queue and won't block
            // the dashboard's first paint. We DO skip this when under
            // XCTest to match init's behavior.
            let isUnderTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
            if !isUnderTest, indexStore == nil, ftsEngine == nil {
                Task { [weak self] in
                    await self?.bootstrapIndexAfterRetry(chatDB: db)
                }
            }
            return true
        } catch let err as ChatDatabase.OpenError {
            self.setupError = String(describing: err)
            nlBarLogger.error("retryOpenIfNeeded: FAILED — \(String(describing: err), privacy: .public)")
            return false
        } catch {
            self.setupError = "Failed to open chat.db: \(error)"
            nlBarLogger.error("retryOpenIfNeeded: FAILED — \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Same pipeline as init's index setup, but invoked after a successful
    /// `retryOpenIfNeeded`. Defensive: any throw is swallowed (we already
    /// have INSTR search working; FTS5 is purely a perf upgrade).
    private func bootstrapIndexAfterRetry(chatDB: ChatDatabase) async {
        do {
            let store = try IndexStore()
            self.indexStore = store
            self.ftsEngine = FTSSearcher(store: store, chatDB: chatDB, contacts: resolvedContacts)
            let sync = IndexSync(store: store, chatDBURL: chatDB.url)
            self.indexSync = sync
            await bootstrapIndexIfNeeded(store: store, chatDB: chatDB)
            await sync.start()
            nlBarLogger.info("retryOpenIfNeeded: FTS5 bootstrap complete (post-retry path)")
        } catch {
            nlBarLogger.error("retryOpenIfNeeded: FTS5 bootstrap failed — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Index bootstrap

    /// Decide whether we need a full index, a catch-up, or nothing — and run
    /// it in the background. Updates `indexingProgress` as work proceeds so
    /// the UI banner can render.
    private func bootstrapIndexIfNeeded(store: IndexStore, chatDB: ChatDatabase) async {
        let freshness: IndexStore.Freshness
        do {
            freshness = try store.freshness(against: chatDB)
        } catch {
            #if DEBUG
            print("Freshness check failed: \(error)")
            #endif
            return
        }

        switch freshness {
        case .ready:
            return    // Nothing to do.

        case .behind(let n):
            // Already-built index, just needs catch-up. The sync loop will
            // pick this up next tick (within 5s); we don't show progress for
            // small catch-ups (<5000 rows) so we don't flash a banner for
            // routine sync.
            if n >= 5000 {
                self.indexingProgress = IndexingProgress(
                    indexed: 0, total: n, isFullIndex: false
                )
                await runCatchUp(store: store, chatDB: chatDB)
            }

        case .missing:
            // First launch (or schema bump deleted the file). Run the full
            // index in the background; INSTR keeps search alive in the
            // meantime.
            self.indexingProgress = IndexingProgress(
                indexed: 0, total: nil, isFullIndex: true
            )
            await runFullIndex(store: store, chatDB: chatDB)
        }
    }

    private func runFullIndex(store: IndexStore, chatDB: ChatDatabase) async {
        let url = chatDB.url
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .utility) {
                do {
                    let progressCb: @Sendable (IndexProgress) -> Void = { p in
                        Task { @MainActor in
                            // Throttle UI updates — only update when count
                            // changes by ≥1% to avoid SwiftUI redraw storms.
                            // (Simple gate: always update, the underlying
                            // emit is already per-batch / per-5000.)
                            // We are intentionally not in this thread on
                            // MainActor, so this is the route to the UI.
                        }
                    }
                    _ = try IndexBuilder.buildFullIndex(
                        chatDBURL: url,
                        store: store,
                        progress: { p in
                            Task { @MainActor [weak self] in
                                self?.indexingProgress = IndexingProgress(
                                    indexed: p.indexed,
                                    total: p.total,
                                    isFullIndex: true
                                )
                            }
                        }
                    )
                    _ = progressCb  // silence unused
                } catch {
                    #if DEBUG
                    print("buildFullIndex failed: \(error)")
                    #endif
                }
                Task { @MainActor [weak self] in
                    self?.indexingProgress = nil
                }
                cont.resume()
            }
        }
    }

    private func runCatchUp(store: IndexStore, chatDB: ChatDatabase) async {
        let url = chatDB.url
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task.detached(priority: .utility) {
                do {
                    _ = try IndexBuilder.catchUp(
                        chatDBURL: url,
                        store: store,
                        progress: { p in
                            Task { @MainActor [weak self] in
                                self?.indexingProgress = IndexingProgress(
                                    indexed: p.indexed,
                                    total: p.total,
                                    isFullIndex: false
                                )
                            }
                        }
                    )
                } catch {
                    #if DEBUG
                    print("catchUp failed: \(error)")
                    #endif
                }
                Task { @MainActor [weak self] in
                    self?.indexingProgress = nil
                }
                cont.resume()
            }
        }
    }

    // MARK: - Search

    /// Schedule a debounced search.
    public func searchSoon(debounceMilliseconds: Int = 150) {
        debounceTask?.cancel()
        // Kill the in-flight search's WORK, not just its (already
        // generation-guarded) result — a superseded scan should stop
        // hydrating rows the moment the query changes, so keystrokes
        // never queue up behind each other's discarded searches.
        activeSearchTask?.cancel()
        let trimmedPhrase = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPhrase.isEmpty && selectedContact == nil && dateRange == nil {
            searchGeneration += 1
            self.results = []
            self.isSearching = false
            self.errorMessage = nil
            self.canLoadOlder = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled, let self else { return }
            await self.search()
        }
    }

    /// Run the search immediately.
    public func search() async {
        debounceTask?.cancel()
        activeSearchTask?.cancel()
        guard let instrEngine else { return }

        searchGeneration += 1
        let myGen = searchGeneration

        let phrase = query
        let person = selectedContact
        let range = dateRange
        let caseSensitive = self.caseSensitive

        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPhrase.isEmpty && person == nil && range == nil {
            self.results = []
            self.isSearching = false
            self.errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil

        // Decide which engine to use. Cheap (microsecond) freshness check.
        let useFTS: Bool
        if let store = indexStore, let chatDB = database {
            switch (try? store.freshness(against: chatDB)) ?? .missing {
            case .ready:                  useFTS = true
            case .behind, .missing:       useFTS = false
            }
        } else {
            useFTS = false
        }
        self.usingIndex = useFTS

        // Capture engines for the detached task. Both are Sendable so this
        // is safe across the actor boundary.
        let fts = ftsEngine

        let searchTask = Task.detached(priority: .userInitiated) {
            do {
                let res: [MessageSearch.Result]
                if useFTS, let fts {
                    res = try fts.search(
                        phrase: phrase,
                        person: person,
                        dateRange: range,
                        limit: Self.liveResultCap,
                        caseSensitive: caseSensitive
                    )
                } else {
                    res = try instrEngine.search(
                        phrase: phrase,
                        person: person,
                        dateRange: range,
                        limit: Self.liveResultCap,
                        caseSensitive: caseSensitive
                    )
                }
                return .success(res)
            } catch {
                return .failure(error)
            }
        } as Task<Result<[MessageSearch.Result], Error>, Never>
        activeSearchTask = searchTask
        let outcome = await searchTask.value

        guard searchGeneration == myGen else { return }

        switch outcome {
        case .success(let res):
            self.results = res
            // A full first page means older matches may exist — arm the
            // panel's infinite scroll.
            self.canLoadOlder = res.count >= Self.liveResultCap
        case .failure(let err):
            // A cancelled scan is the SUCCESSOR search's doing, never an
            // error the user should see — the newer search owns the UI now.
            if err is CancellationError { return }
            self.results = []
            self.errorMessage = "\(err)"
        }
        self.isSearching = false
    }
}
