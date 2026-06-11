//
//  NostalgiaDismissals.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  Persists the user-controlled "hide from Nostalgia" set, so a person the user
//  hides NEVER comes back across ANY nostalgia/reminder surface (On This Day,
//  beloved, dormancy/rekindle, eras, streaks, first-messages, funniest
//  exchanges, and future notifications). This is the core sensitivity
//  guardrail (the user was explicit): one tap to hide, and it sticks forever,
//  for ANYONE — not just relationships we flag.
//
//  THE MODEL — user stays in control:
//    • `hiddenFromNostalgia` — the persisted set the user controls directly.
//      Add anyone (`hide`), remove anyone (`unhide`). Every surface filters on
//      it. This is the ONLY thing that actually suppresses people.
//
//  Nothing auto-hides, and nothing suggests hiding (the advisory prompt was
//  removed in 0.3.1 — people surface naturally; one tap hides anyone forever).
//
//  Keys are the `ContactDailySeries.key` (resolved display name when known,
//  raw handle otherwise) — the same identity the detectors rank on, so a hide
//  lands on the right person regardless of how their handles are merged.
//
//  Injectable `UserDefaults` (defaults to `.standard`) so tests run against an
//  isolated suite and never touch the real prefs.
//

import Foundation

public final class NostalgiaDismissals: @unchecked Sendable {

    /// UserDefaults key holding the array of hidden contact keys. (Named for
    /// the original dormant-only meaning; now the unified hidden set. Kept the
    /// same string so existing on-disk hides carry forward.)
    public static let storageKey = "hourglass.nostalgia.dismissedDormantKeys"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Hidden set (user-controlled, suppression-everywhere)

    /// Current set of hidden contact keys.
    public func hiddenKeys() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let arr = defaults.array(forKey: Self.storageKey) as? [String] ?? []
        return Set(arr)
    }

    /// True iff this contact key is hidden.
    public func isHidden(_ key: String) -> Bool {
        hiddenKeys().contains(key)
    }

    /// Hide a contact key everywhere. Idempotent.
    public func hide(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.array(forKey: Self.storageKey) as? [String] ?? [])
        guard !set.contains(key) else { return }
        set.insert(key)
        // Store sorted for deterministic on-disk order (easier debugging /
        // test assertions).
        defaults.set(set.sorted(), forKey: Self.storageKey)
    }

    /// Un-hide a contact key — the user changed their mind. Idempotent.
    public func unhide(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.array(forKey: Self.storageKey) as? [String] ?? [])
        guard set.contains(key) else { return }
        set.remove(key)
        defaults.set(set.sorted(), forKey: Self.storageKey)
    }

    // MARK: - Backward-compatible dormant aliases
    //
    // The original API spoke only of "dismissed dormant friends." Hiding a
    // dormant friend IS hiding them everywhere now, so these forward to the
    // unified hidden set. Kept so existing call sites / tests don't churn.

    public func dismissedKeys() -> Set<String> { hiddenKeys() }
    public func isDismissed(_ key: String) -> Bool { isHidden(key) }
    public func dismiss(_ key: String) { hide(key) }

    /// Filter a list of dormant friends, dropping any the user has hidden.
    public func filter(_ friends: [DormantFriend]) -> [DormantFriend] {
        let hidden = hiddenKeys()
        guard !hidden.isEmpty else { return friends }
        return friends.filter { !hidden.contains($0.key) }
    }


    // MARK: - Reset

    /// Clear ALL hides — exposed for a possible "reset" affordance and for
    /// test teardown.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }
}
