//
//  IndexSync.swift
//  Hourglass
//
//  Long-running background sync that watches chat.db and keeps the FTS5
//  mirror at parity. Two trigger modes:
//
//  1. Polling (default) — every 5 seconds we hit `SELECT MAX(ROWID)` against
//     chat.db. Microsecond-cheap; if it's higher than `lastIndexedROWID` we
//     run `IndexBuilder.catchUp`.
//  2. Explicit (`syncNow`) — on app foreground / panel open so a returning
//     user sees the freshest possible index.
//
//  Why polling over FSEvents
//  -------------------------
//  FSEvents on `~/Library/Messages/` fires for WAL rotations, journal flushes,
//  and TCC-mediated reads in ways that are noisy and hard to debounce. Polling
//  with a microsecond-cheap query is robust and simple. We can revisit if a
//  user reports "I sent a message, did a search, my new message wasn't there"
//  more than 5 seconds later.
//

import Foundation

public actor IndexSync {

    /// Active sync timer task. We keep one alive at a time.
    private var timerTask: Task<Void, Never>?
    /// Separate utility-priority semantic pass. Lexical windows are ready
    /// immediately; this continuously fills compact dense vectors without
    /// making users wait two hours at 96 rows per five-second poll.
    private var semanticTask: Task<Void, Never>?

    private let store: IndexStore
    private let chatDBURL: URL
    /// When we last ran `refreshRecentWindow`. Codex M3 fix — we re-emit
    /// the last 30 days of rows on a slower cadence to catch edits /
    /// deletions / metadata updates that the rowid-incremental path
    /// alone misses. Hourly is plenty; the work is small and bounded.
    private var lastRecentRefresh: Date = .distantPast

    public init(store: IndexStore, chatDBURL: URL = ChatDatabase.defaultURL) {
        self.store = store
        self.chatDBURL = chatDBURL
    }

    /// Start polling on the configured cadence (default 5s). Idempotent —
    /// calling start while a timer is already running is a no-op.
    public func start(cadence: Duration = .seconds(5)) {
        if timerTask != nil { return }
        timerTask = Task { [chatDBURL, store] in
            while !Task.isCancelled {
                do {
                    _ = try IndexBuilder.catchUp(chatDBURL: chatDBURL, store: store)
                } catch {
                    // Non-fatal: log and keep going. A persistent failure
                    // (e.g. mirror file corrupted) will surface to the user
                    // through the freshness check at query time, where
                    // we fall back to INSTR.
                    #if DEBUG
                    print("IndexSync.catchUp failed: \(error)")
                    #endif
                }
                // Slower-cadence re-emit of the last 30 days to catch
                // mutations to already-indexed rows. Codex M3.
                self.maybeRefreshRecentWindow()
                do {
                    try await Task.sleep(for: cadence)
                } catch {
                    // Task was cancelled mid-sleep. Exit the loop.
                    return
                }
            }
        }
        semanticTask = Task.detached(priority: .utility) { [store] in
            // Reuse one bounded-cache encoder so repeated conversational words
            // do not trigger the same NaturalLanguage lookup thousands of
            // times. The cache is capped in AppleWordSemanticEncoder (~5 MB).
            let encoder = AppleWordSemanticEncoder()
            // First launch and panel-open searches are latency-sensitive.
            // Lexical + already-indexed dense retrieval is immediately ready;
            // let that work finish before opportunistic vector backfill starts.
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            while !Task.isCancelled {
                do {
                    let interactiveDelay = SemanticIndexWorkload.backgroundDelay()
                    if interactiveDelay > 0 {
                        try await Task.sleep(for: .seconds(interactiveDelay))
                        continue
                    }
                    let processed = try ConversationWindowIndexer.backfillEmbeddings(
                        store: store,
                        limit: 64,
                        encoder: encoder
                    )
                    if processed == 0 {
                        try await Task.sleep(for: .seconds(30))
                    } else {
                        // Keep each CPU/DB burst short and yield between them.
                        try await Task.sleep(for: .milliseconds(250))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    #if DEBUG
                    print("IndexSync.semanticBackfill failed: \(error)")
                    #endif
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    /// Run `refreshRecentWindow` at most once per hour. Bounded cost
    /// (~30 days of rows × INSERT OR REPLACE).
    private func maybeRefreshRecentWindow() {
        let now = Date()
        guard now.timeIntervalSince(lastRecentRefresh) > 3_600 else { return }
        lastRecentRefresh = now
        do {
            _ = try IndexBuilder.refreshRecentWindow(
                chatDBURL: chatDBURL,
                store: store,
                days: 30
            )
        } catch {
            #if DEBUG
            print("IndexSync.refreshRecentWindow failed: \(error)")
            #endif
        }
    }

    /// Cancel the polling loop.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        semanticTask?.cancel()
        semanticTask = nil
    }

    /// Run one immediate catch-up pass. Returns the number of rows that were
    /// indexed (0 if nothing new). Synchronous against the index file from
    /// the caller's perspective — the actor serializes it.
    @discardableResult
    public func syncNow() throws -> Int64 {
        try IndexBuilder.catchUp(chatDBURL: chatDBURL, store: store)
    }
}
