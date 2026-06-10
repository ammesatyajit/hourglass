//
//  DashboardView.swift
//  Hourglass
//
//  Top-level Dashboard window content. A System-Settings-style
//  `NavigationSplitView`: a native sidebar on the left (Overview / Vernacular /
//  Nostalgia) and a detail pane on the right that swaps in the selected page.
//
//  Layout:
//
//    ┌───────────────┬──────────────────────────────────────────────────────┐
//    │  ▸ Overview   │  Overview                       [30d 12m All] [Search] │
//    │    Vernacular │  ─────────────────────────────────────────────────────│
//    │    Nostalgia  │  TOTAL · SENT · RECEIVED · CHATS                       │
//    │               │  <texting-frequency chart + timeline navigator>       │
//    │               │  People you text │ Group chats                        │
//    │               │  <How you talk — style stat cards + elongations>      │
//    └───────────────┴──────────────────────────────────────────────────────┘
//
//  WHY a sidebar (2026-06-02 restructure — replaces the single long-scroll
//  dashboard that stacked every analysis panel vertically):
//    - The single scroll instantiated ALL four analysis panels on open
//      (Linguistic + Vernacular + Nostalgia + Social Graph), each kicking its
//      own off-main analysis. That's a big perf/battery hit just to land on the
//      numbers. Paginating into a sidebar lets each page's heavy work load
//      ONLY when that page is first shown (the detail pane is built lazily from
//      the selection — see `detail(for:)`).
//    - Native macOS navigation: `NavigationSplitView` gives us the sidebar
//      material + collapse behavior for free, matching System Settings / Mail.
//
//  LAZY-LOADING CONTRACT:
//    - The SHARED, cheap setup (open chat.db + resolve contacts once, preload
//      the all-time aggregate) lives in `DashboardViewModel.bootstrapIfNeeded`
//      and runs on `.onAppear` regardless of page. It's what powers Overview's
//      numbers + chart and is needed by every page anyway.
//    - The PER-PAGE heavy analyses (vernacular, social graph, nostalgia) are
//      owned by view models inside the page views (`VernacularPage`,
//      `SocialGraphPanel`, `NostalgiaPanel`). Those views are only constructed
//      when their sidebar item is selected, and they `.task`-kick their work on
//      appear. So opening the app and sitting on Overview does NOT run any of
//      them. (Verified: only `DashboardViewModel.reload` +
//      `preloadAllTimeAggregate` + Overview's `LinguisticInsightsPanel` fire on
//      cold launch.)
//
//  NL placement (unchanged): per `docs/nl-placement.md`, natural-language lives
//  in the Spotlight panel. Every page header carries a "Search or ask" pill that
//  summons it; there's no inline NL composer on the dashboard.
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
    /// don't re-open chat.db each time. Holds the shared db/contacts/stats —
    /// the cheap, once-only setup every page depends on.
    @State private var viewModel = DashboardViewModel()

    /// Which sidebar page is showing. The detail pane is built lazily from this,
    /// so a page's heavy analysis only starts when it's first selected.
    @State private var selection: DashboardPage = .overview

    /// Pages that have been selected at least once. A page only enters the
    /// detail area (and thus only kicks its `.task`/`.onAppear` analysis) AFTER
    /// it's first selected — that's the lazy-load. Once visited it STAYS in the
    /// tree (just hidden when another page is showing), so its view models +
    /// computed results persist: re-selecting a page does NOT re-run its
    /// analysis. `.overview` is pre-seeded since it's the landing page.
    @State private var visited: Set<DashboardPage> = [.overview]

    /// AppDelegate-owned SearchViewModel, injected at scene declaration time.
    /// The body reads `searchViewModel.database` to register SwiftUI
    /// observation — any write (e.g. `retryOpenIfNeeded` flipping the DB from
    /// nil → non-nil) re-runs the body. See the prior file history for the full
    /// diagnosis of the NL bar's race condition.
    let searchViewModel: SearchViewModel

    /// Direct reference to the AppDelegate so we can summon the Spotlight panel
    /// + reach the vernacular labeler without going through `NSApp.delegate`
    /// (which can still be nil at first body evaluation).
    let appDelegate: AppDelegate

    init(searchViewModel: SearchViewModel, appDelegate: AppDelegate) {
        self.searchViewModel = searchViewModel
        self.appDelegate = appDelegate
    }

    var body: some View {
        // Force an observation dependency on the SearchViewModel's `database`
        // property. The read is the entire point — we don't care about the
        // value. See the searchViewModel docstring.
        _ = searchViewModel.database

        return NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 300)
        } detail: {
            detailArea
                .background(Color.chromeBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: bootstrap)
        // Record every page the user lands on so it stays alive after the first
        // visit (the laziness + persistence contract — see `visited`).
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(DashboardPage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(page)
                }
            } header: {
                Text("Hourglass")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.top, Space.lg)
            }
        }
        .listStyle(.sidebar)
        // Use the native sidebar selection treatment — `NavigationSplitView` +
        // `.sidebar` list style paints the glass/material + the selection pill
        // for us (the SidebarItem component's hand-rolled highlight is for
        // non-List sidebars). Tinting follows the system accent.
        .tint(.accentColor)
    }

    // MARK: - Detail area (lazy first build + persist after)

    /// The detail pane. Only pages that have been VISITED are placed in the
    /// tree, and once placed they stay (hidden when another page is showing).
    /// This gives us both halves of the contract:
    ///   • LAZY: an unvisited page isn't built, so its `.task`/`.onAppear`
    ///     analysis never runs — sitting on Overview kicks nothing else.
    ///   • PERSISTENT: a visited page isn't torn down on navigate-away, so its
    ///     `@State` view models + their computed results survive — re-selecting
    ///     a page is instant and re-runs nothing.
    /// A plain `switch`-in-the-detail-closure would satisfy LAZY but break
    /// PERSISTENT (SwiftUI tears the matched view down on selection change,
    /// resetting its `@State`). The ZStack-of-visited-pages keeps identity
    /// stable per page.
    private var detailArea: some View {
        ZStack {
            ForEach(DashboardPage.allCases) { p in
                if visited.contains(p) {
                    page(for: p)
                        .opacity(selection == p ? 1 : 0)
                        .allowsHitTesting(selection == p)
                        // Don't let hidden pages claim the accessibility tree or
                        // affect layout focus.
                        .accessibilityHidden(selection != p)
                        .zIndex(selection == p ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func page(for page: DashboardPage) -> some View {
        switch page {
        case .overview:
            OverviewPage(
                viewModel: viewModel,
                runSearch: runSearch,
                onSearchTap: openSpotlightPanel
            )
        case .vernacular:
            VernacularPage(
                database: viewModel.database,
                contacts: viewModel.contacts,
                onSearchTap: openSpotlightPanel,
                labelerProvider: { [appDelegate] in
                    // The VM invokes this on the main actor; AppDelegate is
                    // @MainActor too.
                    MainActor.assumeIsolated { appDelegate.vernacularLabeler }
                }
            )
        case .nostalgia:
            NostalgiaPage(
                database: viewModel.database,
                contacts: viewModel.contacts,
                aggregate: viewModel.allTimeAggregate,
                onSearchTap: openSpotlightPanel
            )
        }
    }

    // MARK: - Bootstrap (shared, cheap, once)

    private func bootstrap() {
        // BEFORE bootstrap fires: wire the hand-off so the moment the dashboard
        // opens chat.db successfully, we hand the same open handle to
        // SearchViewModel. (Use the dashboard's working DB instead of making
        // SearchViewModel race its own open.)
        viewModel.onDatabaseOpened = { [searchViewModel] db in
            nlBarLogger.info("dashboard.onDatabaseOpened: handing DB to SearchViewModel.adoptOpenDatabase")
            searchViewModel.adoptOpenDatabase(db)
        }
        viewModel.bootstrapIfNeeded()
        nlBarLogger.info("dashboard.onAppear: fired")
        // CRITICAL: bootstrapIfNeeded early-returns when the VM was already
        // bootstrapped (re-show of an existing window, SwiftUI re-rendering,
        // etc.) — and in that early-return path the onDatabaseOpened closure
        // NEVER fires. So if the dashboard already has an open DB right now,
        // hand it over directly.
        if let existingDB = viewModel.database {
            nlBarLogger.info("dashboard.onAppear: dashboard ALREADY had an open DB, adopting it")
            searchViewModel.adoptOpenDatabase(existingDB)
        } else {
            // Belt-and-suspenders: if the dashboard's open also failed (FDA
            // actually denied), fall back to the SearchViewModel's own retry.
            // No-op when DB is open.
            let didOpen = searchViewModel.retryOpenIfNeeded()
            nlBarLogger.info("dashboard.onAppear: SearchViewModel.retryOpenIfNeeded() = \(didOpen)")
        }
    }

    // MARK: - Panel summoning

    /// Summon the floating Spotlight panel. Routes via the AppDelegate
    /// singleton — the same path the menu bar's "Search…" entry uses.
    private func openSpotlightPanel() {
        appDelegate.showPanel()
    }

    /// Pre-populate a query, then summon the panel. The panel binds to the
    /// AppDelegate's shared SearchViewModel, so setting `.query` before showing
    /// the panel means the user sees the populated query (and its derived filter
    /// chips) the instant the panel appears.
    private func runSearch(query: String) {
        appDelegate.viewModel.query = query
        Task { await appDelegate.viewModel.search() }
        appDelegate.showPanel()
    }
}

// MARK: - Sidebar pages

/// The three sidebar pages. `Identifiable` + `Hashable` so it drives a
/// `List(selection:)`; `CaseIterable` to enumerate the sidebar rows.
enum DashboardPage: String, CaseIterable, Identifiable, Hashable {
    case overview
    case vernacular
    case nostalgia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:   return "Overview"
        case .vernacular: return "Vernacular"
        case .nostalgia:  return "Nostalgia"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:   return "chart.bar.xaxis"
        case .vernacular: return "quote.bubble"
        case .nostalgia:  return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Query builder

/// Tiny helper for building well-formed search queries from row data.
/// Centralized so the call sites read declaratively and the quoting rules live
/// in one place.
///
/// We always wrap the value in quotes — names commonly contain spaces ("Henry
/// Wu", "Amma Satyajit") and the parser's quote handling is well-tested. The
/// trailing space lets the user keep typing additional terms (e.g. `chat:"Henry"
/// cactus`).
enum SearchQueryBuilder {
    /// `with:"<name>"` — scopes the search to **any chat (1:1 OR group) the
    /// named person participates in**. Used for the people-row click.
    static func oneOnOne(name: String) -> String {
        let escaped = quoteEscape(name)
        return "with:\"\(escaped)\" "
    }

    /// `in:"<name>"` — scopes to a **specific named chat** by case-insensitive
    /// substring on its display name. Used for the groups-row click.
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
