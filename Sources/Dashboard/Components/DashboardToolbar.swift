//
//  DashboardToolbar.swift
//  Hourglass — Dashboard components
//
//  Compact unified header for the Dashboard window. Replaces the giant
//  vertically-stacked "title + segmented selector + SearchHeroCTA +
//  NLSearchBar + stat tiles" section that forced the page into a long
//  scroll.
//
//  Layout (left → right, single ~52pt-tall row):
//
//      ┌──────────────────────────────────────────────────────────────────┐
//      │ Dashboard            [30d 12m All]   [⌘ Search ⌃⌥Space] [✦ Ask] │
//      │ <span / subtitle>                                                 │
//      └──────────────────────────────────────────────────────────────────┘
//
//  The toolbar's job is to telegraph **what window the dashboard is
//  showing** and to provide **discoverable but non-dominant** routes to
//  search and natural-language. The user told us: "the dashboard is for
//  stats; search should be present but not the visual hero" — so we
//  shrunk both bars from full-width pills to single-line toolbar
//  affordances anchored to the trailing edge.
//
//  Visual contract:
//    - Navigation layer (per HIG / design-notes.md). The whole toolbar
//      sits on the dashboard's glass chrome — affordances inside are
//      compact pills, not stretched rounded rects.
//    - Search affordance: blue accent dot + "Search messages" label +
//      live hotkey badge. One click summons the floating Spotlight
//      panel (same path the old hero CTA used).
//    - NL affordance: purple sparkles + "Ask" label. One click flips
//      the toolbar's `nlExpanded` binding so the parent dashboard can
//      show the inline NL composer beneath the toolbar. Stays present
//      but compact — it's a launcher, not the hero.
//    - Hover state on each pill: light accent fill + subtle border;
//      mirrors the affordances scattered across the app.
//
//  Wiring:
//    - `selection` binds to `DashboardViewModel.window`.
//    - `subtitle` is the dashboard's existing span / loading line.
//    - `onSearchTap` summons the Spotlight panel.
//    - `nlExpanded` toggles the NL composer in the parent.
//    - `hotkeyName` drives the trailing badge on the search pill.
//

import SwiftUI
import KeyboardShortcuts

struct DashboardToolbar: View {

    /// The dashboard title text. Single string so a future "Dashboard ·
    /// All time" composite reads cleanly.
    var title: String = "Dashboard"

    /// One-line subtitle below the title (date range / loading / etc.).
    /// Optional so the empty/error states can suppress it cleanly.
    var subtitle: String? = nil

    /// Selected window for the segmented control.
    @Binding var selection: DashboardLoader.Window

    /// True when the current view is a manually-brushed custom range that
    /// doesn't match any preset. Passed through to `WindowSelector` so it
    /// desaturates the active pill — none of 30d/12m/All accurately
    /// describes the view, so claiming one of them is selected misleads.
    var customRangeActive: Bool = false

    /// Whether the NL composer is open beneath the toolbar. We expose this
    /// as a binding so the toolbar's pill can show an "asking" state
    /// (filled vs outlined) without owning the composer.
    @Binding var nlExpanded: Bool

    /// Whether the NL composer affordance should be rendered at all. The
    /// parent passes `false` when panel-agent's decision moves NL to the
    /// Spotlight panel — in that mode the dashboard hides the affordance
    /// entirely rather than leaving a dead chip.
    var showsNLAffordance: Bool = true

    /// Fires when the user clicks the search pill. Wires to the
    /// floating-panel summon path (same as the old hero CTA).
    var onSearchTap: () -> Void

    /// Shortcut name surfaced on the trailing badge. Reads live from
    /// `KeyboardShortcutBadge`'s UserDefaults observer.
    var hotkeyName: KeyboardShortcuts.Name = .toggleSpotlightPanel

    var body: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            titleColumn

            Spacer(minLength: Space.md)

            // `.fixedSize(horizontal: true, vertical: false)` keeps the
            // segmented control at its intrinsic width regardless of how
            // much pressure the parent HStack puts on it. Without this,
            // when FDA is denied (no subtitle text → title column has
            // minimal content) SwiftUI somehow still squeezed the
            // selector's segments into a vertical stack. Pin both pills
            // the same way for safety.
            WindowSelector(
                selection: $selection,
                customRangeActive: customRangeActive
            )
            .fixedSize(horizontal: true, vertical: false)

            searchPill
                .fixedSize(horizontal: true, vertical: false)

            if showsNLAffordance {
                askPill
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: - Title column

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        // Don't .frame(maxWidth: .infinity) the title column — that was
        // claiming all available horizontal space and starving the
        // trailing controls. The Spacer below handles spreading the
        // title from the trailing pills; titleColumn just sizes to its
        // own intrinsic content.
    }

    // MARK: - Search pill

    /// Trailing search affordance. Compact pill with magnifying glass +
    /// label + live hotkey badge. Demoted from the old 60pt hero CTA
    /// — present but not the visual hero. The whole pill is clickable
    /// (whole-row `Button(action:)`) and summons the Spotlight panel.
    ///
    /// Label copy ("Search or ask") reflects panel-agent's 2026-05-24
    /// decision (`docs/nl-placement.md`): the Spotlight panel now hosts
    /// BOTH keyword search and natural-language ask, auto-routed from
    /// query shape (a `?` or a question-word leading token routes to
    /// NL). So this single pill is the dashboard's one route into both
    /// modes — no dedicated NL pill needed.
    private var searchPill: some View {
        ToolbarPill(
            systemImage: "magnifyingglass",
            tint: .accentColor,
            label: "Search or ask",
            trailing: {
                KeyboardShortcutBadge(
                    name: hotkeyName,
                    unsetBehavior: .hidden,
                    size: .compact
                )
            },
            action: onSearchTap
        )
        .help("Open the search panel — type keywords or ask a question")
        .accessibilityLabel("Search or ask")
        .accessibilityHint("Opens the floating Spotlight panel — type keywords or ask a question")
    }

    // MARK: - Ask pill

    /// Trailing NL affordance. Compact pill that toggles `nlExpanded`
    /// in the parent — the parent renders the inline NL composer below
    /// the toolbar when expanded. Demoted from the old 60pt purple
    /// bar; same mental model (sparkles + "Ask") but tucked into the
    /// toolbar so the chart and stat tiles read first.
    private var askPill: some View {
        ToolbarPill(
            systemImage: nlExpanded ? "sparkles" : "sparkles",
            tint: .purple,
            label: "Ask",
            isActive: nlExpanded,
            trailing: {
                Image(systemName: nlExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            },
            action: {
                withAnimation(.bmDefault) { nlExpanded.toggle() }
            }
        )
        .help(nlExpanded
            ? "Hide the natural-language composer"
            : "Ask a natural-language question")
        .accessibilityLabel(nlExpanded ? "Hide ask composer" : "Open ask composer")
        .accessibilityAddTraits(nlExpanded ? .isSelected : [])
    }
}

// MARK: - ToolbarPill

/// Small, hoverable pill shaped like Apple's toolbar buttons — leading
/// SF Symbol in the pill's tint, label in primary text, optional trailing
/// slot for a hotkey badge or chevron. Hover state nudges the fill +
/// border up. The hot zone is the whole pill so the hotkey badge isn't
/// a click-through dead spot.
///
/// Why not `.buttonStyle(.bordered)`: the system style ignores tint
/// per-button and doesn't compose with our hover treatment cleanly.
/// This stays a thin wrapper around `Button` with our `bm*` motion
/// tokens.
private struct ToolbarPill<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let label: String
    var isActive: Bool = false
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.opacity(isHovering || isActive ? 1.0 : 0.85))
                    .frame(width: 14)

                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                trailing()
                    // 1pt nudge so the badge / chevron sits visually with
                    // the label's x-height. Native toolbar look.
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(
                    tint.opacity(isActive ? 0.16 : (isHovering ? 0.10 : 0.06))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(
                    tint.opacity(isActive ? 0.32 : (isHovering ? 0.22 : 0.12)),
                    lineWidth: 0.75
                )
        )
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        .animation(.bmHover, value: isActive)
    }
}

// MARK: - Previews

#Preview("DashboardToolbar — bound hotkey", traits: .fixedLayout(width: 1180, height: 96)) {
    StatefulPreviewWrapper(DashboardLoader.Window.last30Days) { selection in
        StatefulPreviewWrapper(false) { expanded in
            DashboardToolbar(
                title: "Dashboard",
                subtitle: "Last 30 days · 184,392 messages",
                selection: selection,
                nlExpanded: expanded,
                onSearchTap: {}
            )
            .padding(Space.lg)
            .background(Color.chromeBackground)
        }
    }
}

#Preview("DashboardToolbar — NL hidden", traits: .fixedLayout(width: 1180, height: 96)) {
    StatefulPreviewWrapper(DashboardLoader.Window.allTime) { selection in
        StatefulPreviewWrapper(false) { expanded in
            DashboardToolbar(
                title: "Dashboard",
                subtitle: "All time · daily",
                selection: selection,
                nlExpanded: expanded,
                showsNLAffordance: false,
                onSearchTap: {}
            )
            .padding(Space.lg)
            .background(Color.chromeBackground)
        }
    }
}

/// Tiny preview-only helper that wraps state so Previews can drive a Binding.
/// Duplicated from `WindowSelector.swift` because that one is `fileprivate`.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content($value)
    }
}
