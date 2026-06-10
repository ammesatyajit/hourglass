//
//  DashboardPageChrome.swift
//  Hourglass — Dashboard / page chrome
//
//  Shared chrome for the NavigationSplitView detail pages (Overview /
//  Vernacular / Nostalgia). Every page is a vertically-scrolling document with
//  a consistent header (large title + optional subtitle + optional trailing
//  accessory) sitting above the page body. Centralizing it here keeps the three
//  pages visually identical in their framing and means the traffic-light
//  clearance + horizontal insets live in exactly one place.
//
//  Why a header per page rather than the window toolbar: the sidebar is the
//  primary navigation surface now (System-Settings style), and each page wants
//  its own contextual title — and, for Overview, its own time-range selector.
//  A SwiftUI `.toolbar` would force one shared title across pages; an in-content
//  header lets each page own its framing while the sidebar owns navigation.
//

import SwiftUI
import KeyboardShortcuts

/// A scrolling page with a standard header. `accessory` is the trailing control
/// cluster (e.g. the time-range selector + search pill on Overview).
struct DashboardScrollPage<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header
                content()
            }
            .padding(.horizontal, Space.xl)
            // Clear the macOS traffic-light buttons — the window uses
            // `.hiddenTitleBar`, so the content area starts at the very top and
            // the close/min/max buttons occupy the first ~28pt. 44pt is the
            // standard toolbar height and gives the title comfortable air.
            .padding(.top, 44)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.md)
            accessory()
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 44)
    }
}

// Convenience: a page with no trailing accessory.
extension DashboardScrollPage where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
        self.content = content
    }
}

// MARK: - Search pill (page header affordance)

/// The dashboard's one route into the floating Spotlight panel — a compact
/// accent pill with a magnifying glass, "Search or ask", and the live hotkey
/// badge. Present in every page header so search is reachable from anywhere,
/// matching panel-agent's decision that the Spotlight panel hosts both keyword
/// search and natural-language ask (`docs/nl-placement.md`).
struct DashboardSearchPill: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(isHovering ? 1.0 : 0.85))
                    .frame(width: 14)
                Text("Search or ask")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                KeyboardShortcutBadge(
                    name: .toggleSpotlightPanel,
                    unsetBehavior: .hidden,
                    size: .compact
                )
                .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.accentColor.opacity(isHovering ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isHovering ? 0.22 : 0.12), lineWidth: 0.75)
        )
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        .help("Open the search panel — type keywords or ask a question")
        .accessibilityLabel("Search or ask")
        .accessibilityHint("Opens the floating Spotlight panel")
    }
}

// MARK: - Full Disk Access prompt

/// The privacy-first "allow access to Messages" panel, shown when chat.db can't
/// be opened. Extracted from the old `DashboardView.errorPanel` so any page can
/// surface it.
struct DashboardAccessPrompt: View {
    /// Diagnostic detail — accepted but intentionally not surfaced (the SQLite
    /// error string read as alarming and wasn't actionable). Kept so future
    /// logging can consume it.
    let message: String

    var body: some View {
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
}
