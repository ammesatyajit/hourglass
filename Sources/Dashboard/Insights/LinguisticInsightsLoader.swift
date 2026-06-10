//
//  LinguisticInsightsLoader.swift
//  Hourglass — Linguistic Insights
//
//  Bridges chat.db → the pure `LinguisticAnalyzer`. This is the ONLY impure
//  part of the feature: it runs one read-only SQL query to pull the user's
//  own sent message bodies, decodes each via `AttributedBodyDecoder`, then
//  hands the `[String]` off to the analyzer on a background queue.
//
//  chat.db gotchas respected (see plans.md "Critical Technical Knowledge"):
//    - READ-ONLY handle (the shared `ChatDatabase` is already opened RO).
//    - `is_from_me = 1` → the user's OWN messages only.
//    - `associated_message_type = 0` → drop tapbacks / stickers / edits.
//    - `m.text` is NULL for most modern messages → decode `m.attributedBody`
//      with the canonical typedstream decoder. We bind/return the blob as
//      `Data` (never CAST/LIKE — those silently fail on the blob).
//    - `message.date` is Mac-absolute nanoseconds (post-10.13) — we only
//      need it for the optional recency cap, handled via `MessageDate`.
//
//  Performance: even the user's ~525k-message chat.db has only a fraction
//  sent BY them, and a plain `is_from_me = 1` scan with an ORDER BY date
//  LIMIT is fast (date is indexed). We cap at `maxMessages` most-recent
//  sent messages by default so the analysis stays well under a second of
//  decode + a few hundred ms of pure analysis. The whole thing runs off the
//  main actor.
//

import Foundation
import GRDB
import Observation
import os

public enum LinguisticInsightsLoader {

    private static let logger = Logger(subsystem: "com.satyajit.hourglass",
                                       category: "LinguisticInsights")

    /// Fetch up to `maxMessages` most-recent SENT message bodies (decoded,
    /// non-empty). Pure-ish: reads chat.db read-only, no writes, no global
    /// state. Throws on DB error.
    public static func fetchSentBodies(
        database: ChatDatabase,
        maxMessages: Int = 60_000
    ) throws -> [String] {
        // Pull text + attributedBody for the user's own real messages, most
        // recent first, capped. We decode in-process.
        let sql = """
            SELECT m.text AS text, m.attributedBody AS attributedBody
            FROM message m
            WHERE m.is_from_me = 1
              AND m.associated_message_type = 0
              AND (m.text IS NOT NULL OR m.attributedBody IS NOT NULL)
            ORDER BY m.date DESC
            LIMIT ?
            """
        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [maxMessages])
        }

        var bodies: [String] = []
        bodies.reserveCapacity(rows.count)
        for row in rows {
            let text: String? = row["text"]
            if let text, !text.isEmpty {
                bodies.append(text)
                continue
            }
            let blob: Data? = row["attributedBody"]
            let decoded = AttributedBodyDecoder.decode(blob)
            if !decoded.isEmpty { bodies.append(decoded) }
        }
        logger.debug("fetchSentBodies: \(rows.count, privacy: .public) rows → \(bodies.count, privacy: .public) non-empty bodies")
        return bodies
    }

    /// Convenience: fetch + analyze in one synchronous call (off-main only).
    /// Used by the view-model's background task and by smoke scripts.
    public static func computeInsights(
        database: ChatDatabase,
        baseline: LinguisticBaseline,
        maxMessages: Int = 60_000,
        options: LinguisticAnalyzer.Options = .default
    ) throws -> LinguisticInsights {
        let bodies = try fetchSentBodies(database: database, maxMessages: maxMessages)
        return LinguisticAnalyzer.analyze(sentBodies: bodies, baseline: baseline, options: options)
    }
}

// MARK: - View model

/// Drives the `LinguisticInsightsPanel`. Owns the async load lifecycle and
/// caches the result so re-rendering the dashboard doesn't recompute. One
/// instance per panel; constructed with the already-open `ChatDatabase`.
///
/// The heavy work (SQL fetch + decode + analysis) runs in a detached task at
/// utility priority so it never blocks the dashboard's first paint. The
/// baseline corpus is loaded once on the same background task.
@MainActor
@Observable
public final class LinguisticInsightsViewModel {

    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded(LinguisticInsights)
        case failed(String)
        /// Loaded, but there wasn't enough sent text to analyze.
        case empty
    }

    public private(set) var state: LoadState = .idle

    /// Set true when the analysis ran against the embedded PLACEHOLDER
    /// baseline (the bundled corpus failed to load). Surfaced so the UI can
    /// show a quiet note and lead knows it's a bundling bug.
    public private(set) var usedPlaceholderBaseline = false

    private let database: ChatDatabase?
    private let maxMessages: Int
    private var generation = 0

    public init(database: ChatDatabase?, maxMessages: Int = 60_000) {
        self.database = database
        self.maxMessages = maxMessages
    }

    /// Kick off the analysis if it hasn't started. Idempotent — safe to call
    /// from `.task`/`.onAppear` repeatedly.
    public func loadIfNeeded() {
        guard case .idle = state else { return }
        guard let database else { state = .failed("Database unavailable"); return }
        state = .loading
        let myGen = generation &+ 1
        generation = myGen
        let cap = maxMessages

        Task.detached(priority: .utility) { [weak self] in
            let baseline = LinguisticBaseline.load()
            do {
                let insights = try LinguisticInsightsLoader.computeInsights(
                    database: database,
                    baseline: baseline,
                    maxMessages: cap
                )
                await self?.apply(insights, placeholder: baseline.isPlaceholder, generation: myGen)
            } catch {
                await self?.fail(error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Force a fresh recompute (e.g. a manual refresh button).
    public func reload() {
        state = .idle
        loadIfNeeded()
    }

    private func apply(_ insights: LinguisticInsights, placeholder: Bool, generation: Int) {
        guard generation == self.generation else { return }
        usedPlaceholderBaseline = placeholder
        state = insights.isEmpty ? .empty : .loaded(insights)
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation else { return }
        state = .failed(message)
    }
}
