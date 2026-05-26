//
//  DashboardView.swift
//  Hourglass
//
//  Top-level Dashboard window content. Composes the compact toolbar,
//  a low-key overview stats strip, the full-width texting-frequency chart
//  + timeline navigator, and the two top-N (people + groups) leaderboards
//  in a side-by-side row beneath the chart.
//
//  Layout (vertical stack inside the dashboard's ScrollView):
//
//    ┌──────────────────────────────────────────────────────────────────┐
//    │ Dashboard        [30d 12m All]              [⌘ Search ⌃⌥Space]   │ ← toolbar
//    │ Last 30 days · 525,362 messages                                  │
//    ├──────────────────────────────────────────────────────────────────┤
//    │ TOTAL 525,362 · SENT 178,955 (34.1%) · RECEIVED ... · CHATS 1,263│ ← compact strip
//    ├──────────────────────────────────────────────────────────────────┤
//    │ Texting frequency                                                │
//    │ ┌──────────────────────────────────────────────────────────────┐ │ ← full width
//    │ │ <Chart>                                                      │ │
//    │ │                                                              │ │
//    │ └──────────────────────────────────────────────────────────────┘ │
//    │ ┌──────────────────────────────────────────────────────────────┐ │
//    │ │ <Timeline navigator strip>                                   │ │
//    │ └──────────────────────────────────────────────────────────────┘ │
//    ├───────────────────────────────────┬──────────────────────────────┤
//    │ People you text the most          │ Group chats you text the most│
//    │ ┌───────────────────────────────┐ │ ┌──────────────────────────┐ │
//    │ │ 1. Henry             ↓ scroll │ │ │ 1. Dashboard …  ↓ scroll │ │
//    │ │ 2. Amma                       │ │ │ 2. ...                   │ │
//    │ │  …(internal scroll past 12)…  │ │ │  …(scroll past 12)…      │ │
//    │ └───────────────────────────────┘ │ └──────────────────────────┘ │
//    └───────────────────────────────────┴──────────────────────────────┘
//
//  Why vertical stack (2026-05-24 second pass — replaces the prior split
//  pane that put leaderboards in a right column):
//    - User feedback: "the dashboard looks slightly cooked. show the 4
//      overview stats in a diff way. it's pretty cluttered. the gcs and
//      the people should be below the graph and scrollable past 12
//      people. the graph might be better covering the entire screen
//      length."
//    - Symmetric column heights eliminate the "void on one side when
//      scrolling past the shorter column" bug the split-pane had.
//    - Chart-as-hero: stretching it edge-to-edge lets the user actually
//      read the daily/weekly densities at full resolution.
//    - Overview stats are visually demoted from a 2×2 GlassCard tile grid
//      to an inline header strip — see `OverviewStatStrip`.
//    - Each leaderboard scrolls INSIDE its panel (revealing the rest of
//      the top-50 entries) AND the whole page scrolls — two scroll axes,
//      one vertical: page-scroll for the entire dashboard, panel-internal
//      scroll for the leaderboard tail. The user explicitly asked to be
//      able to scroll past the 12th entry; the top-N cap is now 50.
//
//  NL bar placement:
//    - Per `docs/nl-placement.md` (panel-agent 2026-05-24), natural-
//      language lives in the Spotlight panel. The dashboard's `[Ask]`
//      affordance is hidden via `showsNLOnDashboard = false`. NLSearchBar
//      kept intact in the codebase per coordination contract; never
//      rendered here.
//

import AppKit
import os
import SwiftUI

/// Same logger surface used by SearchViewModel + AppDelegate. Filter in
/// Console.app:
///   subsystem == "com.satyajit.bettermessages" && category == "nl-bar-rendering"
private let nlBarLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-bar-rendering"
)

struct DashboardView: View {

    /// Reuse one VM across open/close cycles of the dashboard window so we
    /// don't re-open chat.db each time.
    @State private var viewModel = DashboardViewModel()

    /// Whether the inline NL composer is expanded under the toolbar.
    /// Closed by default — the dashboard's job is to show stats; NL is
    /// a tucked-away launcher.
    @State private var nlExpanded: Bool = false

    /// AppDelegate-owned SearchViewModel, injected explicitly at scene
    /// declaration time (see `HourglassApp.swift`). The view body
    /// reads `searchViewModel.database` to register SwiftUI observation
    /// — any write (e.g. `retryOpenIfNeeded` flipping the DB from nil
    /// → non-nil) re-runs the body so the NL composer can swap its
    /// placeholder for the real bar. See the prior file's history for
    /// the full diagnosis of the NL bar's race condition.
    let searchViewModel: SearchViewModel

    /// Direct reference to the AppDelegate so the NL composer can access
    /// `nlSearchViewModel` without going through `NSApp.delegate` (which
    /// can still be nil at first body evaluation). Same race-avoidance
    /// pattern that fixed the placeholder bug on 2026-05-24.
    let appDelegate: AppDelegate

    init(searchViewModel: SearchViewModel, appDelegate: AppDelegate) {
        self.searchViewModel = searchViewModel
        self.appDelegate = appDelegate
    }

    var body: some View {
        // Force an observation dependency on the SearchViewModel's
        // `database` property. The read is the entire point — we don't
        // care about the value. See the searchViewModel docstring.
        _ = searchViewModel.database

        // Outer ScrollView restored. We tried the "everything fits in
        // one viewport with internally-scrollable panels" model
        // (2026-05-24 split-pane redesign) and it didn't survive contact
        // with the user's actual window sizes — the chart had to absorb
        // all slack and got clipped, the leaderboards' fixed visible-row
        // count felt cramped, and the toolbar kept losing its space to
        // its neighbors. Natural document-scroll is the right model: the
        // dashboard is a long page of stats, the user scrolls when they
        // want more. Each leaderboard now renders ALL its rows inline
        // (no "Scroll to see all 12" footer), and the chart sits at its
        // natural ~360pt height instead of trying to fill the viewport.
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                DashboardToolbar(
                    title: "Dashboard",
                    subtitle: spanLabel,
                    selection: $viewModel.window,
                    // Grey out the segmented selector whenever the
                    // user is on a manually-brushed range — clicking
                    // a pill still snaps back to its preset.
                    customRangeActive: viewModel.brushedRange != nil
                        && !viewModel.brushMatchesPreset,
                    nlExpanded: $nlExpanded,
                    showsNLAffordance: showsNLOnDashboard,
                    onSearchTap: openSpotlightPanel
                )

                // Inline NL composer — only renders when the [Ask] pill
                // is toggled on. Sliding in here keeps the natural-
                // language surface attached to its trigger while keeping
                // the dashboard compact when the user just wants stats.
                if nlExpanded && showsNLOnDashboard {
                    nlBar
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                content
            }
            .padding(.horizontal, Space.xl)
            // Extra top padding to clear the macOS traffic-light buttons.
            // `.windowStyle(.hiddenTitleBar)` removes the visible title
            // bar but the close/min/max buttons still occupy the top
            // ~28pt of the content area; 44pt is the standard macOS
            // toolbar height.
            .padding(.top, 44)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.chromeBackground)
        .animation(.bmDefault, value: nlExpanded)
        .onAppear {
            // BEFORE bootstrap fires: wire the hand-off so the moment
            // the dashboard opens chat.db successfully, we hand the
            // same open handle to SearchViewModel. This is the user's
            // suggested fix — use the dashboard's working DB instead of
            // making SearchViewModel race its own open.
            viewModel.onDatabaseOpened = { [searchViewModel] db in
                nlBarLogger.info("dashboard.onDatabaseOpened: handing DB to SearchViewModel.adoptOpenDatabase")
                searchViewModel.adoptOpenDatabase(db)
            }
            viewModel.bootstrapIfNeeded()
            nlBarLogger.info("dashboard.onAppear: fired")
            // CRITICAL: bootstrapIfNeeded early-returns when the dashboard
            // VM was already bootstrapped (re-show of an existing window,
            // SwiftUI re-rendering, etc.) — and in that early-return path
            // the onDatabaseOpened closure NEVER fires. So if the
            // dashboard already has an open DB right now, hand it over
            // directly. This is what was making my "hand-off" fix not
            // work the first time: it relied on bootstrap actually firing
            // the closure, but on a warm dashboard it doesn't.
            if let existingDB = viewModel.database {
                nlBarLogger.info("dashboard.onAppear: dashboard ALREADY had an open DB, adopting it")
                searchViewModel.adoptOpenDatabase(existingDB)
            } else {
                // Belt-and-suspenders: if the dashboard's open also
                // failed (FDA actually denied), fall back to the
                // SearchViewModel's own retry. No-op when DB is open.
                let didOpen = searchViewModel.retryOpenIfNeeded()
                nlBarLogger.info("dashboard.onAppear: SearchViewModel.retryOpenIfNeeded() = \(didOpen)")
            }
        }
    }

    // MARK: - NL placement decision

    /// Whether the dashboard renders its own inline NL affordance.
    ///
    /// **Decided 2026-05-24** by panel-agent — `docs/nl-placement.md`
    /// shipped Option B: NL search lives **inside the Spotlight panel**
    /// (auto-detected from query shape, Tab-to-toggle, sparkles pill
    /// affordance). Per panel-agent's recommendation in that doc, the
    /// dashboard collapses its NL surface to a vestigial entry-point —
    /// the toolbar's "Search messages" pill telegraphs dual-mode in its
    /// label and tooltip, and clicking it summons the panel (where NL
    /// is available with one keypress).
    ///
    /// Set to `false` so:
    /// - The toolbar hides the `[✦ Ask]` pill (no redundant second
    ///   route into NL — the spec's "two-mental-models problem" goes
    ///   away).
    /// - The inline NL composer never renders, removing a 60pt+ surface
    ///   from the dashboard's top.
    ///
    /// `NLSearchBar.swift` is kept intact in `Sources/Dashboard/Components/`
    /// per the coordination contract — the panel may reuse pieces, and
    /// the inline composer is one flip away if we want to bring it back
    /// for power users.
    private var showsNLOnDashboard: Bool { false }

    // MARK: - Subtitle helpers

    /// One-line subtitle the toolbar renders beneath the title. Same
    /// logic as the prior dashboard's `spanLabel`, kept verbatim so
    /// existing tests / docstrings still apply.
    private var spanLabel: String? {
        // The subtitle always reflects the unified active range — the
        // navigator and segmented selector both write to the same
        // brushedRange, so there's exactly ONE thing to describe here.
        // Drop the "Custom:" prefix when the brush exactly matches a
        // preset (cleaner reading; the segment highlight already
        // telegraphs which preset is active).
        if let brushed = viewModel.brushedRange {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            let lo = formatter.string(from: brushed.lowerBound)
            let hi = formatter.string(from: brushed.upperBound)
            let days = max(
                1,
                Calendar.current.dateComponents(
                    [.day], from: brushed.lowerBound, to: brushed.upperBound
                ).day ?? 0
            )
            let suffix = "\(lo) → \(hi) · \(days) day\(days == 1 ? "" : "s")"
            return viewModel.brushMatchesPreset ? suffix : "Custom: \(suffix)"
        }
        guard let stats = viewModel.stats,
              let oldest = stats.overview.oldest,
              let newest = stats.overview.newest else {
            return viewModel.isLoading ? "Loading…" : nil
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "All time: \(formatter.string(from: oldest)) → \(formatter.string(from: newest))"
    }

    // MARK: - Content area (split-pane)

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.setupError {
            errorPanel(error)
        } else if viewModel.stats == nil && viewModel.isLoading {
            // Loading takeover — only while we have nothing to show.
            // Once `stats` is non-nil we render the split-pane even
            // mid-reload so the user sees their numbers while the next
            // window resolves.
            ProgressView("Loading dashboard…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let stats = viewModel.stats {
            verticalStack(stats: stats)
        } else {
            // No stats, no error, not loading — degenerate first-run.
            // Render a quiet placeholder rather than a blank screen so
            // the UI still feels alive.
            Spacer()
        }
    }

    /// Vertical stack — the new layout (2026-05-24 second pass). One
    /// column, edge-to-edge:
    ///
    ///   1. Compact `OverviewStatStrip` (low-key inline header).
    ///   2. Full-width `frequencyPanel` (chart + timeline navigator).
    ///   3. Side-by-side `peoplePanel` | `groupsPanel`, each taking
    ///      half the width with equal weight, each with its own
    ///      internal scroll for entries past the visible row count.
    ///
    /// This collapses the previous split-pane (which put the right
    /// column on the side of the chart) into a strictly vertical flow.
    /// The chart is the visual hero; the leaderboards are equal-weight
    /// companions beneath it; the stats are a glanceable subtitle row
    /// above. Symmetric column heights mean no asymmetric-scroll-void
    /// bug the split-pane had.
    private func verticalStack(stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            OverviewStatStrip(
                stats: stats.overview,
                subtitle: overviewSubtitle
            )

            // Full-width chart panel — chart + navigator beneath.
            frequencyPanel(stats: stats)
                .frame(maxWidth: .infinity)

            // Leaderboards live BELOW the chart, side by side.
            // `.frame(maxWidth: .infinity)` on each panel + equal-weight
            // HStack splits the row 50/50. Both panels expose internal
            // scroll past `visibleRowCount` rows so the user can
            // scroll past the 12th entry without the whole dashboard
            // moving.
            HStack(alignment: .top, spacing: Space.lg) {
                peoplePanel(stats: stats)
                    .frame(maxWidth: .infinity)
                groupsPanel(stats: stats)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Frequency panel (left column)

    private func frequencyPanel(stats: DashboardStats) -> some View {
        // Unified bucketing policy (2026-05-24): pick density from
        // the active range's LENGTH, not from which control set it.
        // A 30d preset → daily, a 12m preset → weekly, an all-time
        // preset → monthly, AND a navigator drag uses the same
        // thresholds so the chart density is consistent across both
        // controls. See `DashboardLoader.Bucketing.forRange`.
        let bucketing = viewModel.activeBucketing
        // The visible domain the main chart pins to. Drives the
        // "zoom into the windowed range" promise of the navigator.
        let visible: ClosedRange<Date>? = viewModel.activeRange
        return StatPanel(
            title: "Texting frequency",
            subtitle: frequencySubtitle,
            accessory: {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Space.md) {
                    FrequencyChart(
                        buckets: stats.timeSeries,
                        bucketing: bucketing,
                        visibleRange: visible
                    )
                    // Compact chart height — user feedback said the
                    // chart was too tall at 360pt and was pushing the
                    // leaderboards too far down the page. 240pt still
                    // gives the daily / weekly densities enough room
                    // to read while leaving more visual real estate
                    // for the stats below.
                    .frame(height: 240)

                    // Navigator strip — pinned to the same horizontal
                    // padding so it aligns edge-to-edge with the chart.
                    // Content-layer styling (solid + hairline) per
                    // design-notes.md.
                    if let aggregate = viewModel.allTimeAggregate {
                        TimelineNavigator(
                            daily: aggregate.dailyOverview,
                            calendar: aggregate.calendar,
                            brushedRange: $viewModel.brushedRange,
                            enabled: true
                        )
                    } else {
                        // Slim placeholder while the all-time aggregate
                        // is still preloading. Same height so the
                        // dashboard doesn't reflow when the strip
                        // materializes.
                        navigatorPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        )
    }

    /// Slim, non-interactive placeholder that holds the navigator's
    /// height before the aggregate finishes loading. Keeps the layout
    /// stable on cold launch.
    private var navigatorPlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.contentBackground.opacity(0.3))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
            .frame(height: TimelineNavigator.stripHeight + 18)
            .overlay(
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .opacity(0.6)
            )
    }

    /// Subtitle telegraphing what the chart is showing + how to refine.
    /// In the unified model the navigator + segmented selector point at
    /// the same range, so:
    ///   - Pre-aggregate: legacy preset hint ("Last 30 days · daily").
    ///   - Brush matches preset (default): preset hint, dynamically
    ///     adapted to the resolved bucketing, with a "drag the strip"
    ///     affordance.
    ///   - Brush is a custom drag: "Custom range · drag handles to
    ///     refine · ESC to clear".
    private var frequencySubtitle: String {
        if viewModel.allTimeAggregate == nil {
            return subtitle(for: viewModel.window)
        }
        if viewModel.brushMatchesPreset {
            return resolvedPresetSubtitle + " · drag the strip below to refine"
        }
        return "Custom range · drag handles to refine · ESC to clear"
    }

    /// Like `subtitle(for: window)` but with the resolved bucketing
    /// label so the hint matches what the chart actually drew (e.g. a
    /// drag that crossed the 60-day threshold flips the hint from
    /// "daily" to "weekly").
    private var resolvedPresetSubtitle: String {
        let bucketLabel = bucketingLabel(viewModel.activeBucketing)
        switch viewModel.window {
        case .last30Days:   return "Last 30 days · \(bucketLabel)"
        case .last12Months: return "Last 12 months · \(bucketLabel)"
        case .allTime:      return "All time · \(bucketLabel)"
        }
    }

    private func bucketingLabel(_ b: DashboardLoader.Bucketing) -> String {
        switch b {
        case .day:   return "daily"
        case .week:  return "weekly"
        case .month: return "monthly"
        }
    }

    // MARK: - Right column subtitle

    /// Trailing context line on the overview strip. Stays muted and
    /// short — the strip's job is to display four numbers; the
    /// "frequency" panel's subtitle and the toolbar own the active-
    /// window context. The overview counters are computed across the
    /// entire database (they don't track `brushedRange`), so the
    /// context line just says "All time."
    private var overviewSubtitle: String? {
        if viewModel.isLoading && viewModel.stats == nil {
            return "Loading…"
        }
        guard viewModel.stats != nil else { return nil }
        // Reflect the actual window the stats describe. When the user
        // is on a preset, label it with the preset name. When they're
        // on a custom brushed range, say "Custom range". Saying
        // "All time" while the numbers describe a 28-day window is
        // the bug the user just reported.
        if let brushed = viewModel.brushedRange, !viewModel.brushMatchesPreset {
            let days = max(
                1,
                Calendar.current.dateComponents(
                    [.day], from: brushed.lowerBound, to: brushed.upperBound
                ).day ?? 0
            )
            return "Custom · \(days) day\(days == 1 ? "" : "s")"
        }
        switch viewModel.window {
        case .last30Days: return "Last 30 days"
        case .last12Months: return "Last 12 months"
        case .allTime: return "All time"
        }
    }

    // MARK: - People / Groups panels (right column)

    private func peoplePanel(stats: DashboardStats) -> some View {
        ScrollableTopListPanel(
            title: "People you text the most",
            subtitle: peopleSubtitle(stats: stats),
            entries: stats.topContacts.map { stat in
                TopListEntry(
                    id: stat.key,
                    displayName: stat.displayName,
                    primary: stat.total,
                    secondaryPair: .init(left: stat.sent, right: stat.received),
                    secondaryLabel: nil,
                    avatar: .person(photo: stat.avatarData)
                )
            },
            primaryLabel: "Total",
            secondaryLeftLabel: "Sent",
            secondaryRightLabel: "Received",
            emptyMessage: "No 1:1 chats in this window.",
            onSelect: { entry in
                // People rows: scope the search to every chat the person
                // participates in via `with:"Name"`. Includes their 1:1
                // AND any group they're in. (As of 2026-05-25 `with:` is
                // the broad operator; the old "1:1 only" semantics — and
                // the Option-click fallback that produced `in:` — were
                // dropped because they made the two operators redundant.)
                runSearch(query: SearchQueryBuilder.oneOnOne(name: entry.displayName))
            },
            actionTooltip: "Search every chat with this person",
            // Show ~8 rows visible; the rest of the top-50 scrolls
            // INSIDE the panel. The user explicitly asked to be able to
            // scroll past the 12th entry without the whole dashboard
            // moving — internal panel scroll is the affordance.
            visibleRowCount: 8
        )
    }

    private func groupsPanel(stats: DashboardStats) -> some View {
        ScrollableTopListPanel(
            title: "Group chats you text the most",
            subtitle: groupsSubtitle(stats: stats),
            entries: stats.topGroups.map { stat in
                TopListEntry(
                    id: "group:\(stat.chatRowID)",
                    displayName: stat.displayName,
                    primary: stat.sentByYou,
                    secondaryPair: nil,
                    secondaryLabel: "\(stat.sentByYou.formatted(.number)) sent · \(stat.total.formatted(.number)) total",
                    avatar: groupAvatar(for: stat)
                )
            },
            primaryLabel: "Sent by you",
            secondaryLeftLabel: nil,
            secondaryRightLabel: nil,
            emptyMessage: "No group chats in this window.",
            onSelect: { entry in
                // Groups: scope by chat display name via `in:"Name"`.
                // (`chat:` and `in:` are aliases; we use `in:` for
                // visual consistency with the people-row Option-click
                // fallback.)
                runSearch(query: SearchQueryBuilder.anyChat(name: entry.displayName))
            },
            actionTooltip: "Search this group",
            // Same ~8-rows-visible policy as the people panel — AND
            // same rowHeight (60pt default). Previously this panel set
            // rowHeight: 64 for denser group rows, but the difference
            // (8×60=480 vs 8×64=512 = 32pt) made the two side-by-side
            // panels' bottoms misalign in the dashboard layout. Visual
            // symmetry beats a marginally tighter row.
            visibleRowCount: 8
        )
    }

    /// Pick the right `TopListEntry.Avatar` case for a group stat. A custom
    /// group photo wins; otherwise we render a stacked composite of the
    /// first few participants' avatars.
    private func groupAvatar(for stat: DashboardStats.GroupStat) -> TopListEntry.Avatar {
        if let bytes = stat.chatAvatarData {
            return .groupPhoto(bytes)
        }
        return .groupComposite(participants: stat.participantAvatars)
    }

    private func errorPanel(_ message: String) -> some View {
        // `message` is accepted but intentionally not surfaced — the
        // diagnostic line (`SQLite error 23: authorization denied`,
        // file path) was noise users wouldn't act on and read as
        // alarming. Kept in the signature so callers don't need to
        // change and so future logging can still consume it.
        _ = message
        return GlassCard(cornerRadius: Radius.large, showsBorder: true) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Allow access to Messages")
                        .font(.headline)
                }

                // Privacy-first lede. Nobody reads walls of text; the
                // ONE thing the user needs to be sure of before they
                // grant a sensitive permission is "nothing leaves my
                // Mac." That single line carries the whole pitch; the
                // button labels say what to do next.
                Text("Everything stays on this Mac. Hourglass searches and analyzes your iMessage history locally — nothing is uploaded, sent, or shared.")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.sm) {
                    Button("Grant Full Disk Access") {
                        openFullDiskAccessSettingsAndRevealApp()
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Opens System Settings and reveals Hourglass.app in Finder so you can drag it into the Full Disk Access list.")

                    Button("Relaunch") {
                        relaunchApp()
                    }
                    .buttonStyle(.bordered)
                    .help("Quit and reopen Hourglass after you've toggled Full Disk Access on.")
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Subtitle helpers

    private func subtitle(for window: DashboardLoader.Window) -> String {
        switch window {
        case .last30Days:   return "Last 30 days · daily"
        case .last12Months: return "Last 12 months · monthly"
        case .allTime:      return "All time · monthly"
        }
    }

    private func peopleSubtitle(stats: DashboardStats) -> String {
        let scope = activeWindowLabel
        if stats.topContacts.isEmpty { return "Top 50 · 1:1 conversations" }
        return "Top \(stats.topContacts.count) · 1:1 · \(scope)"
    }

    private func groupsSubtitle(stats: DashboardStats) -> String {
        let scope = activeWindowLabel
        if stats.topGroups.isEmpty { return "Top 50 · ranked by your sent count" }
        return "Top \(stats.topGroups.count) · by sent · \(scope)"
    }

    /// Short label for the currently-active window. Shows the segment
    /// label when the brush matches one of the presets (the default
    /// after picking a segment); flips to "Custom" only when the user
    /// has dragged the navigator off any preset boundary.
    private var activeWindowLabel: String {
        if viewModel.brushedRange == nil {
            return viewModel.window.label
        }
        if viewModel.brushMatchesPreset {
            return viewModel.window.label
        }
        return "Custom"
    }

    // MARK: - Panel summoning

    /// Summon the floating Spotlight panel. Routes via the AppDelegate
    /// singleton — the same path the menu bar's "Search…" entry uses.
    private func openSpotlightPanel() {
        appDelegate.showPanel()
    }

    /// Pre-populate a query, then summon the panel. The panel binds to
    /// the AppDelegate's shared SearchViewModel, so setting `.query`
    /// before showing the panel means the user sees the populated
    /// query (and its derived filter chips) the instant the panel
    /// appears.
    private func runSearch(query: String) {
        appDelegate.viewModel.query = query
        Task { await appDelegate.viewModel.search() }
        appDelegate.showPanel()
    }

    // MARK: - NL bar (inline composer below the toolbar)

    /// Natural-language search bar. Same component the user already
    /// knows; rendered here only when [✦ Ask] in the toolbar is toggled
    /// on. Lazy-binds to the AppDelegate-owned NLSearchViewModel.
    @ViewBuilder
    private var nlBar: some View {
        if let nlVM = appDelegate.nlSearchViewModel {
            let _ = nlBarLogger.debug("nlBar body: rendering REAL NLSearchBar (vm available)")
            NLSearchBar(
                viewModel: nlVM,
                onRevealMessage: { guid in
                    _ = MessagesGUIDReveal.sendSpotlightOpenURL(messageGUID: guid)
                },
                onEscalateToSpotlight: { query in
                    self.runSearch(query: query)
                }
            )
        } else {
            let _ = nlBarLogger.notice("nlBar body: rendering PLACEHOLDER (no vm — db not open yet)")
            nlBarPlaceholder
                .task {
                    // Polls for FDA grant while the placeholder is on
                    // screen. As soon as `retryOpenIfNeeded` succeeds
                    // (the user opened System Settings, dragged in the
                    // app, toggled FDA on), `database` flips non-nil,
                    // the body re-renders, and the placeholder gets
                    // replaced by the real bar — at which point this
                    // .task is auto-cancelled by SwiftUI.
                    nlBarLogger.info("nlBar placeholder.task: started — polling for FDA grant")
                    while !Task.isCancelled {
                        let opened = searchViewModel.retryOpenIfNeeded()
                        nlBarLogger.debug("nlBar placeholder.task: retry returned \(opened)")
                        if opened {
                            nlBarLogger.info("nlBar placeholder.task: SUCCESS — database is now open, body will re-render")
                            return
                        }
                        try? await Task.sleep(for: .seconds(1.5))
                    }
                }
        }
    }

    /// Non-interactive preview of the NL bar shown when chat.db isn't
    /// readable yet. Same visual treatment as the live bar (purple
    /// liquid-glass, sparkles glyph) so the user understands the feature
    /// is there waiting; the body just tells them to grant FDA.
    private var nlBarPlaceholder: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.purple.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask anything")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Grant Full Disk Access to enable natural-language search.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.shield")
                .font(.callout)
                .foregroundStyle(.orange.opacity(0.75))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassOrMaterial(
            tint: Color.purple,
            tintOpacity: 0.06,
            in: RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xlarge, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.10), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask anything — requires Full Disk Access.")
    }
}

// MARK: - Query builder

/// Tiny helper for building well-formed search queries from row data.
/// Centralized so the call sites read declaratively and the quoting
/// rules live in one place.
///
/// We always wrap the value in quotes — names commonly contain spaces
/// ("Henry Wu", "Amma Satyajit") and the parser's quote handling is
/// well-tested. The trailing space lets the user keep typing
/// additional terms (e.g. `chat:"Henry" cactus`).
enum SearchQueryBuilder {
    /// `with:"<name>"` — scopes the search to **any chat (1:1 OR group)
    /// the named person participates in**. Used for the people-row click.
    ///
    /// Historical note: this used to mean "1:1 only" and the dashboard
    /// had an Option-click fallback that produced `in:"Name"` for the
    /// broader view. As of 2026-05-25 the `with:` operator IS the broader
    /// view — the function name is kept (it's the dashboard's people-row
    /// CTA, and "oneOnOne" is the colloquial label users use for "a
    /// person" even when groups are included).
    static func oneOnOne(name: String) -> String {
        let escaped = quoteEscape(name)
        return "with:\"\(escaped)\" "
    }

    /// `in:"<name>"` — scopes to a **specific named chat** by
    /// case-insensitive substring on its display name. Used for the
    /// groups-row click (groups are always named; their `display_name`
    /// is what the user typed when they named the group).
    static func anyChat(name: String) -> String {
        let escaped = quoteEscape(name)
        return "in:\"\(escaped)\" "
    }

    /// `from:"<name>"` — limits to messages received from this person.
    static func from(name: String) -> String {
        let escaped = quoteEscape(name)
        return "from:\"\(escaped)\" "
    }

    private static func quoteEscape(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

#Preview("DashboardView — empty state") {
    DashboardView(
        searchViewModel: SearchViewModel(),
        appDelegate: AppDelegate()
    )
    .frame(width: 1200, height: 800)
}
