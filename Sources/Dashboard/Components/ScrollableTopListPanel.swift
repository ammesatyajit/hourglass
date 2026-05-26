//
//  ScrollableTopListPanel.swift
//  Hourglass — Dashboard components
//
//  StatPanel-wrapped scrollable container for a TopList. The dashboard
//  was previously pushing the entire viewport into a single ScrollView,
//  which meant "scrolling to see your 12th most-messaged person" forced
//  the chart + stat tiles up off the page. This panel scrolls **inside
//  itself** — the page stays fixed, only the leaderboard moves.
//
//  Layout:
//
//      ┌── StatPanel ───────────────────────────────────┐
//      │ People you text the most                       │
//      │ Top 12 · 1:1 conversations · Last 30 days      │
//      │ ┌────────────────────────────────────────────┐ │
//      │ │ 1. Henry Wu             ▇▇▇▇▇▇▇▇▇   1,284 │ │
//      │ │ 2. Amma Satyajit        ▇▇▇▇▇▇▇▇    1,102 │ │
//      │ │ 3. Alex Chen            ▇▇▇▇▇▇        612 │ │
//      │ │ 4. +1415555…            ▇▇▇▇          308 │ │
//      │ │ 5. ...                  ↓ (scroll)         │ │
//      │ └────────────────────────────────────────────┘ │
//      │                ───── 12 of 12 ─────            │
//      └────────────────────────────────────────────────┘
//
//  Sizing rule: the visible area is sized to `visibleRowCount` rows
//  (default 6). The container locks `.frame(minHeight:idealHeight:)` —
//  not a hard maxHeight — so when the parent layout has *extra* vertical
//  space it can absorb it (taller panels look healthier than a fixed
//  280pt window with whitespace below). When the parent layout is
//  cramped the panel shrinks back to the ideal and the rows scroll.
//
//  Empty state: render the empty message at the same fixed height so the
//  two-column dashboard layout doesn't shift when one side has data and
//  the other doesn't.
//

import SwiftUI

struct ScrollableTopListPanel: View {

    let title: String
    var subtitle: String?
    let entries: [TopListEntry]
    let primaryLabel: String
    let secondaryLeftLabel: String?
    let secondaryRightLabel: String?
    let emptyMessage: String
    var onSelect: ((TopListEntry) -> Void)? = nil
    var actionTooltip: String? = nil
    /// Number of rows that should be visible without scrolling. Default
    /// 6 matches the brief's call-out ("Top People list shows ~6 rows;
    /// scrollable to reveal #7 through #N").
    var visibleRowCount: Int = 6
    /// Approximate height of one rendered TopList row (avatar + bar +
    /// labels). Measured empirically against the current row layout;
    /// kept as a constant rather than a GeometryReader so the panel
    /// height stays deterministic during data churn.
    var rowHeight: CGFloat = 60
    /// Spacing between rows inside the TopList — must match `TopList`'s
    /// internal `VStack(spacing: Space.sm)`. If TopList ever switches
    /// to a different spacing, update this to keep the math right.
    var rowSpacing: CGFloat = Space.sm

    var body: some View {
        StatPanel(
            title: title,
            subtitle: subtitle,
            content: { panelContent }
        )
    }

    /// Computed inner viewport height — sized to N rows + (N-1) gaps.
    /// Uses the rowSpacing constant so the math reflects whatever the
    /// inner TopList does. Adds a small buffer (8pt) so the last row
    /// doesn't graze the scroll fade.
    private var viewportHeight: CGFloat {
        let rows = CGFloat(max(1, visibleRowCount))
        let gaps = max(0, rows - 1) * rowSpacing
        return rows * rowHeight + gaps + 8
    }

    @ViewBuilder
    private var panelContent: some View {
        if entries.isEmpty {
            // Match the visible height so the two-column layout doesn't
            // jump when one side has data and the other doesn't.
            VStack(spacing: Space.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: viewportHeight)
        } else {
            VStack(spacing: Space.xs) {
                scrollViewport
                footerCount
            }
        }
    }

    /// The scrollable list itself. Pinned to the computed viewport
    /// height — when the list overflows, the ScrollView kicks in and the
    /// user can scroll INSIDE the panel without moving the page. The
    /// hard height pin (not `maxHeight: .infinity`) is important for the
    /// new side-by-side leaderboard layout: both panels need predictable
    /// equal heights, and "absorb all available space" would let one
    /// stretch when the other doesn't (the asymmetric-column-void bug we
    /// just fixed).
    ///
    /// Use `.scrollIndicators(.automatic)` so the indicator only
    /// appears when the list actually overflows — clean static state on
    /// short lists.
    private var scrollViewport: some View {
        ScrollView(.vertical) {
            TopList(
                entries: entries,
                primaryLabel: primaryLabel,
                secondaryLeftLabel: secondaryLeftLabel,
                secondaryRightLabel: secondaryRightLabel,
                emptyMessage: emptyMessage,
                onSelect: onSelect,
                actionTooltip: actionTooltip
            )
            // Inner padding so the rightmost edge of the rows doesn't
            // touch the scroll indicator track.
            .padding(.trailing, Space.xs)
        }
        .scrollIndicators(.automatic)
        // Hard height = viewportHeight. The panel never stretches with
        // available space; it always shows exactly `visibleRowCount`
        // rows and scrolls the rest. Symmetric heights = predictable
        // dashboard layout.
        .frame(height: viewportHeight, alignment: .top)
        // Subtle inset background so the scroll region reads as a
        // distinct "viewport into a longer list" — distinguishes the
        // scrollable content from the panel chrome around it.
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            // Top + bottom fades to telegraph overflow without dimming
            // the rows themselves. Only visible when the list overflows
            // (handled by the scroll indicator policy and the gradient's
            // own subtlety — at full visibility we still want the rows
            // legible).
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.contentBackground.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 6)
                .allowsHitTesting(false)
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.contentBackground.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 6)
                .allowsHitTesting(false)
            }
        )
    }

    /// Footer counts the hidden tail so the user knows how many more
    /// entries are scrollable inside the panel. Quiet, single line —
    /// Apple Spotlight / Finder "N more results" pattern.
    @ViewBuilder
    private var footerCount: some View {
        if entries.count > visibleRowCount {
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Scroll for \(entries.count - visibleRowCount) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Previews

#Preview("ScrollableTopListPanel — overflowing", traits: .fixedLayout(width: 420, height: 520)) {
    ScrollableTopListPanel(
        title: "People you text the most",
        subtitle: "Top 12 · 1:1 conversations · Last 30 days",
        entries: (1...12).map { i in
            .init(
                id: "p-\(i)",
                displayName: "Friend \(i)",
                primary: max(50, 1200 - i * 80),
                secondaryPair: .init(left: 600 - i * 30, right: 600 - i * 50),
                secondaryLabel: nil,
                avatar: .person(photo: nil)
            )
        },
        primaryLabel: "Total",
        secondaryLeftLabel: "Sent",
        secondaryRightLabel: "Received",
        emptyMessage: "No 1:1 chats in this window."
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("ScrollableTopListPanel — empty", traits: .fixedLayout(width: 420, height: 520)) {
    ScrollableTopListPanel(
        title: "Group chats you text the most",
        subtitle: "Top 12 · ranked by your sent count · Last 30 days",
        entries: [],
        primaryLabel: "Sent",
        secondaryLeftLabel: nil,
        secondaryRightLabel: nil,
        emptyMessage: "No group chats in this window."
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}
