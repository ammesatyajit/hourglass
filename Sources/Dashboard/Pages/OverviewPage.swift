//
//  OverviewPage.swift
//  Hourglass — Dashboard / Overview page
//
//  The "Overview" sidebar page: the quick-glance home. Hosts the content that
//  used to live at the top of the single-scroll dashboard —
//
//    1. OverviewStatStrip      — all-time aggregate counters.
//    2. Frequency panel        — the texting-frequency chart + timeline
//                                navigator/brush.
//    3. Leaderboards           — people you text the most | group chats, side
//                                by side, each internally scrollable.
//
//  ("How you talk" / linguistic style now lives on the Vernacular page, not here.)
//
//  This page reads the SHARED `DashboardViewModel` (db/contacts/stats are
//  opened + resolved once by the dashboard shell) and renders synchronously
//  from the already-loaded stats. It runs no heavy analysis of its own beyond
//  what the shared VM already preloads — so sitting on Overview does NOT kick
//  the Vernacular / Social / Nostalgia builds (those live on their own pages
//  and load on appear).
//
//  Selecting a person/group row escalates into the Spotlight panel via the
//  injected `runSearch` closure (same behavior as the old dashboard).
//

import SwiftUI

struct OverviewPage: View {

    @Bindable var viewModel: DashboardViewModel
    /// Pre-populate a query + summon the Spotlight panel (people/group rows).
    let runSearch: (String) -> Void
    /// Summon the Spotlight panel with no pre-populated query (header pill).
    let onSearchTap: () -> Void

    var body: some View {
        DashboardScrollPage(
            title: "Overview",
            subtitle: spanLabel,
            accessory: {
                HStack(spacing: Space.md) {
                    // The time-range selector lives on Overview because this is
                    // the only page whose numbers + chart respond to it.
                    WindowSelector(
                        selection: $viewModel.window,
                        customRangeActive: viewModel.brushedRange != nil
                            && !viewModel.brushMatchesPreset
                    )
                    DashboardSearchPill(action: onSearchTap)
                }
            },
            content: {
                content
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.setupError {
            DashboardAccessPrompt(message: error)
        } else if viewModel.stats == nil && viewModel.isLoading {
            ProgressView("Loading dashboard…")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if let stats = viewModel.stats {
            loaded(stats: stats)
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func loaded(stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            OverviewStatStrip(stats: stats.overview, subtitle: overviewSubtitle)

            frequencyPanel(stats: stats)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: Space.lg) {
                peoplePanel(stats: stats).frame(maxWidth: .infinity)
                groupsPanel(stats: stats).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Frequency panel

    private func frequencyPanel(stats: DashboardStats) -> some View {
        let bucketing = viewModel.activeBucketing
        let visible: ClosedRange<Date>? = viewModel.activeRange
        return StatPanel(
            title: "Texting frequency",
            subtitle: frequencySubtitle,
            accessory: {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Space.md) {
                    FrequencyChart(
                        buckets: stats.timeSeries,
                        bucketing: bucketing,
                        visibleRange: visible
                    )
                    .frame(height: 240)

                    if let aggregate = viewModel.allTimeAggregate {
                        TimelineNavigator(
                            daily: aggregate.dailyOverview,
                            calendar: aggregate.calendar,
                            brushedRange: $viewModel.brushedRange,
                            enabled: true
                        )
                    } else {
                        navigatorPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        )
    }

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

    // MARK: - Leaderboards

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
                runSearch(SearchQueryBuilder.oneOnOne(name: entry.displayName))
            },
            actionTooltip: "Search every chat with this person",
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
                runSearch(SearchQueryBuilder.anyChat(name: entry.displayName))
            },
            actionTooltip: "Search this group",
            visibleRowCount: 8
        )
    }

    private func groupAvatar(for stat: DashboardStats.GroupStat) -> TopListEntry.Avatar {
        if let bytes = stat.chatAvatarData {
            return .groupPhoto(bytes)
        }
        return .groupComposite(participants: stat.participantAvatars)
    }

    // MARK: - Subtitle copy (verbatim from the prior DashboardView)

    private var spanLabel: String? {
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

    private var frequencySubtitle: String {
        if viewModel.allTimeAggregate == nil {
            return subtitle(for: viewModel.window)
        }
        if viewModel.brushMatchesPreset {
            return resolvedPresetSubtitle + " · drag the strip below to refine"
        }
        return "Custom range · drag handles to refine · ESC to clear"
    }

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

    private var overviewSubtitle: String? {
        if viewModel.isLoading && viewModel.stats == nil {
            return "Loading…"
        }
        guard viewModel.stats != nil else { return nil }
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

    private var activeWindowLabel: String {
        if viewModel.brushedRange == nil { return viewModel.window.label }
        if viewModel.brushMatchesPreset { return viewModel.window.label }
        return "Custom"
    }
}
