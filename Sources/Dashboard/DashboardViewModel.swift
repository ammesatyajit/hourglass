//
//  DashboardViewModel.swift
//  Hourglass
//
//  Owns the Dashboard window's state and orchestrates loads against
//  `DashboardLoader`. One instance lives for the lifetime of the dashboard
//  scene; it survives close/reopen so we don't repeatedly reopen chat.db.
//
//  Loading model — current:
//    - On first appear we kick off TWO loads:
//        1. A fast `loadSync` for the chosen window so the user sees the
//           initial stats inside ~500 ms.
//        2. A full `loadAllTimeAggregate` that preloads every per-day
//           bucket in chat.db. This is what powers brush-drag.
//      The aggregate load runs at lower priority + on a background queue
//      so it doesn't block first paint.
//
//  Unified range state (2026-05-24):
//    - `brushedRange: ClosedRange<Date>?` is the SOLE SOURCE OF TRUTH for
//      "what date range is the dashboard displaying right now." Every
//      rendered surface (tiles, frequency chart, top-people, top-groups,
//      the navigator pill itself) follows it.
//    - `window: DashboardLoader.Window` is the user's last-chosen segment
//      shortcut. Picking 30d/12m/All SETS `brushedRange` to that preset's
//      resolved anchored range, so navigator + segmented stay in lockstep
//      — the two controls share state, they just expose different
//      affordances onto it. (Direct navigator drags don't disturb
//      `window`, so the segmented highlight stays where the user last
//      clicked — segments are shortcuts, not states.)
//    - Bucketing follows the active range's LENGTH via
//      `DashboardLoader.Bucketing.forRange(_:)`, not the preset. A drag
//      crossing ~60 days re-bins the chart from daily to weekly without
//      the user touching a segment.
//    - On cold launch, `window = .last30Days` defaults. The moment the
//      all-time aggregate finishes preloading, the view-model derives
//      `brushedRange = rangeForPreset(.last30Days)` so both controls
//      reflect the same window from the first interactive frame.
//

import Foundation
import Observation

@MainActor
@Observable
public final class DashboardViewModel {

    /// The user's last-clicked segment in `WindowSelector`. Acts as a
    /// **shortcut** to a preset range, not as an independent piece of
    /// rendered state: clicking a segment sets `brushedRange` to that
    /// preset's anchored range, and the segmented highlight tracks the
    /// last click (manual navigator drags do NOT change which segment
    /// looks active — segments are shortcuts, not states).
    ///
    /// What the dashboard actually RENDERS is always driven by
    /// `brushedRange`. See the class docstring.
    public var window: DashboardLoader.Window = .last30Days {
        didSet {
            // No-op ONLY when the window value didn't change AND the
            // brush already matches the preset. The second clause is
            // critical: when the user drags the navigator off-preset,
            // `window` is still (say) `.last30Days` but `brushedRange`
            // doesn't match any more. Re-clicking the 30d pill SHOULD
            // re-snap the brush even though `window` itself is unchanged.
            // Without this, the greyed-out segmented selector pills are
            // visually clickable but functionally dead.
            if window == oldValue && brushMatchesPreset { return }
            // Picking a preset is "show me that preset's anchored range":
            // mirror it into `brushedRange` so both controls reflect the
            // same window from the next frame.
            //
            // Pre-aggregate: there's no `brushedRange` semantics yet
            // (the navigator strip is showing a placeholder), so just
            // fall through to the legacy SQL `reload()` path. Once the
            // aggregate lands, `applyAggregate` snaps `brushedRange` to
            // the current preset's range and the unified model kicks
            // in for every subsequent flip.
            if let aggregate = allTimeAggregate {
                brushedRange = resolveBrush(for: window, aggregate: aggregate)
                // `brushedRange` didSet fires `recomputeFromAggregateIfPossible`.
            } else {
                reload()
            }
        }
    }

    /// The date range every panel and the navigator pill currently
    /// reflect. Single source of truth — the segmented selector and the
    /// navigator are two affordances on top of this one value.
    ///
    /// `nil` only on cold launch, before the aggregate has finished
    /// preloading (in that window the legacy SQL `loadSync` path renders
    /// per `window`). Once `allTimeAggregate` lands, `brushedRange`
    /// transitions to a non-nil anchored range and stays non-nil for the
    /// rest of the session.
    ///
    /// Setting this triggers an in-memory recompute on the next
    /// observation cycle — no SQL — so dragging is zero-latency.
    public var brushedRange: ClosedRange<Date>? = nil {
        didSet {
            recomputeFromAggregateIfPossible()
        }
    }

    /// Latest loaded stats, or nil while loading the first time.
    public private(set) var stats: DashboardStats?

    /// True iff a load is currently in flight (SQL only — the brush
    /// recompute is synchronous and never sets this).
    public private(set) var isLoading: Bool = false

    /// True iff the all-time aggregate has finished preloading. When
    /// true, brushing is zero-latency; when false the chart falls back
    /// to release-drag (recompute on mouse-up via SQL). The chart can
    /// poll this to decide whether to enable live updates or guard
    /// against missing data.
    public private(set) var allTimeAggregate: DashboardAllTimeAggregate?

    /// DB open / contacts load failure. Sticky — once set, the user has to
    /// fix permissions and relaunch.
    public private(set) var setupError: String?

    /// Most recent successful load timestamp — useful for a "Last updated"
    /// hint in the UI.
    public private(set) var lastLoadedAt: Date?

    /// The dashboard's open chat.db handle. Public-readable so other
    /// viewmodels (notably `SearchViewModel`, via `adoptOpenDatabase`)
    /// can attach to the SAME working handle instead of racing their
    /// own open against TCC's settle timing.
    public private(set) var database: ChatDatabase?
    /// Exposed (read-only) so dashboard panels that need contact
    /// resolution — Nostalgia (dormant friends, beloved-message senders)
    /// and Social Graph (handle→person merge, node labels) — can read the
    /// already-resolved set without re-running `ContactResolver.resolve()`.
    public private(set) var contacts: ResolvedContacts?
    private var generation: Int = 0

    /// Hook fired once when the dashboard's `bootstrapIfNeeded` first
    /// opens chat.db successfully. The dashboard's open is the most
    /// reliable signal for "FDA is granted in this process" (it fires
    /// after `.onAppear`, by which time TCC has settled even on
    /// rebuild-race launches). The AppDelegate sets this to a closure
    /// that calls `SearchViewModel.adoptOpenDatabase(_:)` so the NL bar
    /// stops being stuck on the "Grant FDA" placeholder. nil for tests
    /// that don't care.
    public var onDatabaseOpened: ((ChatDatabase) -> Void)?

    public init() {}

    /// Open the chat.db + AddressBook once and trigger the first load. Safe
    /// to call multiple times — subsequent calls are no-ops if setup already
    /// succeeded.
    public func bootstrapIfNeeded() {
        guard database == nil, setupError == nil else { return }
        do {
            let db = try ChatDatabase()
            let contacts = ContactResolver.resolve()
            self.database = db
            self.contacts = contacts
            // Tell anyone who's listening (e.g. AppDelegate) that we got
            // a working DB so they can attach their own state to it
            // without re-opening (and re-racing TCC).
            onDatabaseOpened?(db)
            reload()
            preloadAllTimeAggregate()
        } catch let err as ChatDatabase.OpenError {
            setupError = String(describing: err)
        } catch {
            setupError = error.localizedDescription
        }
    }

    /// Kick off a load with the current `window`. Cancels in-flight loads via
    /// the generation counter — slow returns are discarded.
    public func reload() {
        guard let database, let contacts else { return }

        // Fast path: if the all-time aggregate is loaded and the current
        // window resolves to a closed date range (or to nil = all-time),
        // we can derive `stats` synchronously without any SQL. Same
        // applies to brushed ranges. This is what makes window-toggle
        // and brush-drag both feel instant.
        if recomputeFromAggregateIfPossible() {
            return
        }

        let myGen = generation &+ 1
        generation = myGen
        isLoading = true
        let window = self.window

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let stats = try DashboardLoader.loadSync(
                    database: database,
                    contacts: contacts,
                    window: window
                )
                await self?.apply(stats: stats, generation: myGen)
            } catch {
                await self?.fail(message: error.localizedDescription, generation: myGen)
            }
        }
    }

    /// Preload the all-time aggregate. Runs at lower priority than
    /// `reload()` so the user gets their initial dashboard view first;
    /// the aggregate lands a few hundred ms later and brushing becomes
    /// available.
    private func preloadAllTimeAggregate() {
        guard let database, let contacts, allTimeAggregate == nil else { return }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let aggregate = try DashboardLoader.loadAllTimeAggregateSync(
                    database: database,
                    contacts: contacts
                )
                await self?.applyAggregate(aggregate)
            } catch {
                // Non-fatal — the dashboard still works on the SQL
                // path, just without zero-latency brush. We don't
                // surface the error to the user UI; if SQL fails,
                // `reload()` will surface the same error.
            }
        }
    }

    /// Pure synchronous fast-path. Returns true iff we successfully
    /// rebound `stats` from the cached aggregate.
    ///
    /// The unified model (2026-05-24): `brushedRange` drives EVERY
    /// rendered surface — tile sums, frequency chart, leaderboards,
    /// and the navigator pill itself. When the brush is nil, we fall
    /// back to the segment preset's anchored range (cold-launch case,
    /// before the brush has been snapped).
    @discardableResult
    private func recomputeFromAggregateIfPossible() -> Bool {
        guard let aggregate = allTimeAggregate else { return false }
        let calendar = aggregate.calendar
        let now = Date()
        // Single source of truth: brushedRange. Defer to the preset's
        // anchored range only on the very first frame after preload
        // (before `applyAggregate` snaps the brush).
        let range: ClosedRange<Date>?
        if let brushedRange {
            range = brushedRange
        } else {
            range = DashboardLoader.dateRange(for: window, now: now, calendar: calendar)
        }
        // Bucketing follows LENGTH, not preset — same policy whether
        // the user got here by clicking a segment or by dragging the
        // navigator. `forRange` picks ~30-bar density at common spans:
        // ≤60d daily, ≤395d weekly, >395d monthly.
        let bucketing: DashboardLoader.Bucketing
        if let range {
            bucketing = DashboardLoader.Bucketing.forRange(range)
        } else {
            // All-time with no concrete range (= aggregate not loaded
            // OR `dateRange(for: .allTime, …) == nil`). The aggregate's
            // own span will drive bucketing below; default to monthly.
            bucketing = .month
        }
        let next = aggregate.recomputeForRange(range, bucketing: bucketing)
        self.stats = next
        self.lastLoadedAt = Date()
        self.isLoading = false
        return true
    }

    /// Apply a result on the main actor, but only if it's still current.
    private func apply(stats: DashboardStats, generation: Int) {
        guard generation == self.generation else { return }
        self.stats = stats
        self.lastLoadedAt = Date()
        self.isLoading = false
    }

    private func fail(message: String, generation: Int) {
        guard generation == self.generation else { return }
        self.setupError = message
        self.isLoading = false
    }

    /// Set the all-time aggregate, then re-bind `stats` so the user sees
    /// the cached data take over immediately.
    ///
    /// **Snap `brushedRange` to the current preset's anchored range**
    /// when the brush is nil. After this moment the navigator strip
    /// becomes interactive, the pill needs a concrete range to render,
    /// and from here on `brushedRange` is the single source of truth.
    /// If a brush was already manually set (e.g. user dragged the
    /// navigator the instant the strip appeared), we honor it.
    private func applyAggregate(_ aggregate: DashboardAllTimeAggregate) {
        self.allTimeAggregate = aggregate
        if brushedRange == nil {
            brushedRange = resolveBrush(for: window, aggregate: aggregate)
            // `brushedRange` didSet fires `recomputeFromAggregateIfPossible`.
            return
        }
        // A brush was already set — recompute against it.
        recomputeFromAggregateIfPossible()
    }

    /// Resolve `window` against `aggregate` to a concrete range the
    /// navigator pill can render. Used by `window`'s didSet AND by
    /// `applyAggregate` so the snap behavior is identical whether the
    /// user picked a segment first OR the aggregate loaded first.
    ///
    /// `.allTime` resolves to the aggregate's span (not nil), so the
    /// navigator pill covers the entire strip — matching what the
    /// chart actually draws.
    private func resolveBrush(
        for window: DashboardLoader.Window,
        aggregate: DashboardAllTimeAggregate
    ) -> ClosedRange<Date>? {
        let presetRange = DashboardLoader.dateRange(
            for: window,
            now: Date(),
            calendar: aggregate.calendar
        )
        if let presetRange {
            // Clamp to the aggregate's span so a preset that reaches
            // back farther than the user's history (an empty chat.db,
            // fresh install) still renders a valid pill.
            return clampToAggregateSpan(presetRange, aggregate: aggregate)
        }
        // `.allTime` → no preset range; fall back to the aggregate's
        // full span. The pill covers the strip end-to-end.
        return spanFromAggregate(aggregate)
    }

    /// Clamp a preset range to the aggregate's actual data span — a
    /// `last30Days` window on a 5-day-old chat.db should resolve to
    /// the 5 days that exist, not 30 days of empty padding.
    private func clampToAggregateSpan(
        _ range: ClosedRange<Date>,
        aggregate: DashboardAllTimeAggregate
    ) -> ClosedRange<Date> {
        guard let span = spanFromAggregate(aggregate) else { return range }
        let lo = max(range.lowerBound, span.lowerBound)
        let hi = min(range.upperBound, span.upperBound)
        if lo >= hi { return span }
        return lo...hi
    }

    private func spanFromAggregate(_ aggregate: DashboardAllTimeAggregate) -> ClosedRange<Date>? {
        guard let first = aggregate.dailyOverview.first,
              let last = aggregate.dailyOverview.last else { return nil }
        return aggregate.date(forDayIndex: first.dayIndex)
            ... aggregate.date(forDayIndex: last.dayIndex)
    }

    // MARK: - Test seam

    /// Install a pre-built aggregate without running the SQL preload
    /// path. Used by unit tests that want to exercise the unified
    /// `brushedRange` ↔ `window` behavior without owning a chat.db.
    /// The flow is identical to what `preloadAllTimeAggregate` ends
    /// up doing — same `applyAggregate` snap, same recompute, same
    /// observation cycle.
    internal func _setAggregateForTests(_ aggregate: DashboardAllTimeAggregate) {
        applyAggregate(aggregate)
    }

    // MARK: - Range helpers (exposed for the view)

    /// Convenience: the date range every dashboard panel currently
    /// reflects. Single source of truth, exposed for subtitle copy +
    /// the chart's x-axis pin.
    ///
    /// Once the aggregate is loaded this is always == `brushedRange`.
    /// Before then (cold-launch window) we fall back to the segmented
    /// preset's resolved range so the legacy SQL `loadSync` path has
    /// something to advertise.
    public var activeRange: ClosedRange<Date>? {
        if let brushedRange { return brushedRange }
        return DashboardLoader.dateRange(for: window, now: Date(), calendar: .current)
    }

    /// Bucketing the active range should use for chart display.
    /// Convenience for the view — saves callers from re-deriving it.
    /// Returns the preset's hard-coded bucketing when no concrete
    /// range is known yet (cold launch, all-time preset before
    /// preload).
    public var activeBucketing: DashboardLoader.Bucketing {
        if let range = activeRange {
            return DashboardLoader.Bucketing.forRange(range)
        }
        return window.bucketing
    }

    /// Does `brushedRange` exactly match the currently selected
    /// segment's preset range? Used by the subtitle copy: when true the
    /// subtitle says "Last 30 days · daily"; when false it adopts the
    /// "Custom: …" prefix.
    ///
    /// "Exactly" matches with day-resolution tolerance (the navigator
    /// snaps to day boundaries and the preset uses `Date()` for `now`,
    /// so a sub-second jitter shouldn't flip the subtitle).
    ///
    /// `.allTime`: matches when the brush covers the aggregate's full
    /// span (within tolerance) — since `.allTime` has no concrete
    /// preset range, we compare against the aggregate's data span.
    public var brushMatchesPreset: Bool {
        guard let brushedRange,
              let aggregate = allTimeAggregate else { return false }
        let tolerance: TimeInterval = 86_400 // one day
        // Compare against the SAME range `resolveBrush` would produce
        // for this preset — i.e. the CLAMPED-to-aggregate-span value,
        // not the raw `[now - 30d, now]`. The raw preset's upper bound
        // is `Date()`, but the actual brush is clamped to the
        // aggregate's `upperBound` (which is the date of the last
        // message — possibly a few days ago). Without matching the
        // clamp here, a user clicking `30d` on a DB whose most recent
        // message is 3 days old would see the pill grey out
        // immediately, because brush.upperBound (3 days ago) differs
        // from preset.upperBound (now) by more than the 1-day
        // tolerance. (This is the bug that made 30d and 12m never
        // show the blue selection pill while `.allTime` did — `.allTime`
        // already used the aggregate span on both sides.)
        let target = resolveBrush(for: window, aggregate: aggregate)
        guard let target else { return false }
        return abs(brushedRange.lowerBound.timeIntervalSince(target.lowerBound)) <= tolerance
            && abs(brushedRange.upperBound.timeIntervalSince(target.upperBound)) <= tolerance
    }

    /// Span of the all-time aggregate, used by the chart x-axis. Returns
    /// nil while the aggregate is preloading.
    public var aggregateSpan: ClosedRange<Date>? {
        guard let aggregate = allTimeAggregate else { return nil }
        return spanFromAggregate(aggregate)
    }
}
