//
//  RecentSearchesStore.swift
//  Hourglass
//
//  Persists a small list of recently-run search queries so the empty
//  state can offer them as one-tap re-entry. Single-process, single-user,
//  no concurrency — `@MainActor` keeps it simple.
//
//  Storage contract
//  ----------------
//  - Backed by `UserDefaults`. Keyed by a single string array.
//  - Most-recent-first ordering. A repeated query moves to the front
//    instead of duplicating.
//  - Cap at `maxEntries` (default 8). Older entries fall off the end.
//  - Minimum length 2 — we don't store one-character noise.
//  - Trimmed of surrounding whitespace before storing.
//
//  Intent contract
//  ---------------
//  We only record a query when the user has *committed* to it — pressed
//  Enter or opened a result — not on every keystroke. That avoids
//  polluting the list with typos and partial drafts and matches the
//  Spotlight/Raycast convention for "Recent" lists. The call site
//  signals this by invoking `record(_:)` from the submit / reveal
//  handlers, not the typing path.
//

import Foundation
import Observation

/// Persisted history of committed search queries. Observable so SwiftUI
/// views can read `entries` directly and re-render when it changes.
///
/// Not `@MainActor`-isolated even though SwiftUI calls it from the main
/// actor — `UserDefaults` is documented thread-safe and the in-memory
/// `entries` array is mutated only from the call sites that already run
/// on the main actor (the panel's button handlers). Leaving the class
/// non-isolated keeps tests synchronous (no Sendable / async hops) and
/// preserves the `@Observable` macro's tracking when consumed from a
/// SwiftUI view body.
@Observable
public final class RecentSearchesStore: @unchecked Sendable {

    /// Maximum entries to keep. Tighter than typical "recents" caps
    /// because the panel is dense — more than ~6 visible items
    /// overwhelms the empty state.
    public static let defaultMaxEntries = 8

    /// Minimum query length to record. Anything shorter is treated as
    /// noise (single-char typos, accidental Enter keypresses).
    public static let minLength = 2

    /// UserDefaults key. Namespaced so we don't collide with anything
    /// else in `UserDefaults.standard`.
    static let defaultsKey = "Hourglass.RecentSearches.v1"

    private let defaults: UserDefaults
    private let maxEntries: Int

    public private(set) var entries: [String]

    /// Initialize with a `UserDefaults` instance (default `.standard`).
    /// Tests can pass an isolated suite to avoid leaking state.
    public init(defaults: UserDefaults = .standard, maxEntries: Int = RecentSearchesStore.defaultMaxEntries) {
        self.defaults = defaults
        self.maxEntries = maxEntries
        // Load on construction — small array, cheap to materialize.
        let raw = (defaults.array(forKey: Self.defaultsKey) as? [String]) ?? []
        // Defensive: filter out garbage that might be present (empty
        // strings from older versions, anything shorter than minLength).
        self.entries = raw.filter { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count >= Self.minLength
        }
    }

    /// Record a committed query at the top of the list. Trims whitespace,
    /// dedupes (case-insensitively — "cactus" and "Cactus" are the same
    /// search), enforces the cap.
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minLength else { return }

        // Remove any existing entry that matches case-insensitively so
        // the new one rises to the top without duplicating. Comparing
        // case-insensitively is the right intent — the user thinks of
        // "Cactus" and "cactus" as the same search even though the
        // engine treats `case:sensitive` differently when present.
        let lowered = trimmed.lowercased()
        entries.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowered }

        entries.insert(trimmed, at: 0)
        if entries.count > maxEntries {
            entries.removeSubrange(maxEntries..<entries.count)
        }
        persist()
    }

    /// Remove a single entry by exact-match string. Used by the per-row
    /// delete control in the UI.
    public func remove(_ query: String) {
        let before = entries.count
        entries.removeAll { $0 == query }
        if entries.count != before {
            persist()
        }
    }

    /// Wipe all entries. Used by Settings → "Clear recent searches" (not
    /// yet wired in UI; method exists so the contract is clear).
    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(entries, forKey: Self.defaultsKey)
    }
}
