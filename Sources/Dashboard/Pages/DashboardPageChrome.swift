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
    /// When set, the header renders the prominent CENTERED search bar
    /// (the app's one route into the Spotlight panel). Lives in the chrome
    /// so every page gets the same bar in the same place; the trailing
    /// `accessory` stays for page-specific controls (e.g. Overview's
    /// time-range selector).
    var onSearchTap: (() -> Void)? = nil
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
        HStack(alignment: .center, spacing: Space.lg) {
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
        // The search bar is an OVERLAY centered on the header itself, so it
        // sits at the page's geometric center — identical position on every
        // page regardless of how wide "Overview"/"Vernacular"/"Nostalgia"
        // (or the trailing accessory) happens to be.
        .overlay {
            if let onSearchTap {
                DashboardSearchPill(action: onSearchTap, prominent: true)
                    .frame(maxWidth: 460)
            }
        }
    }
}

// Convenience: a page with no trailing accessory.
extension DashboardScrollPage where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        onSearchTap: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onSearchTap = onSearchTap
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
    /// Prominent = the header's centered search BAR: taller, field-like
    /// (icon + label left, hotkey badge pushed to the trailing edge), and
    /// it stretches to the width its container allows. The compact form
    /// remains for tight spots.
    var prominent: Bool = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: prominent ? Space.sm : Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: prominent ? 14 : 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(isHovering ? 1.0 : 0.85))
                    .frame(width: prominent ? 16 : 14)
                Text("Search or ask")
                    .font(prominent ? .body.weight(.medium) : .subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if prominent {
                    Spacer(minLength: Space.sm)
                }
                KeyboardShortcutBadge(
                    name: .toggleSpotlightPanel,
                    unsetBehavior: .hidden,
                    size: .compact
                )
                .padding(.leading, 2)
            }
            .padding(.horizontal, prominent ? 14 : 10)
            .padding(.vertical, prominent ? 9 : 6)
            .frame(maxWidth: prominent ? .infinity : nil)
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

                Text("Hourglass needs access to your chat.db. All analysis stays on this Mac, nothing requires the internet or is uploaded anywhere.")
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
