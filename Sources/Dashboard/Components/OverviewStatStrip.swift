//
//  OverviewStatStrip.swift
//  Hourglass — Dashboard components
//
//  Compact, horizontal, single-row summary of the four overview stats
//  (Total / Sent / Received / Conversations). Lives ABOVE the chart in
//  the redesigned vertical layout (2026-05-24, second pass).
//
//  Visual model — "low-key header strip", NOT a panel:
//
//      ┌──────────────────────────────────────────────────────────────────────┐
//      │ TOTAL  525,362  ·  SENT  178,955 (34.1%)  ·  RECEIVED  346,407 ...  │
//      └──────────────────────────────────────────────────────────────────────┘
//
//  Why we redesigned (user feedback 2026-05-24, second pass):
//    > "the 4 overview stats look pretty cluttered. show them in a diff way."
//
//  The previous version was a 2×2 grid inside a full `StatPanel` glass
//  card — it ate ~120pt of prime real estate and visually competed with
//  the chart underneath. The new version reads as a *subtitle row* above
//  the chart: still glanceable, but no panel chrome, no big numbers, no
//  competing visual weight.
//
//  Design tokens:
//    - One GlassCard (`.medium` radius, hairline border) — the same
//      navigation-layer treatment as the toolbar. Saves a panel-vs-content
//      ambiguity that pure "background fill" would introduce.
//    - Inline label/number pairs: SF Pro 11pt UPPERCASE labels + 17pt
//      monospaced numbers. Roughly the same visual density as a Finder
//      info inspector strip.
//    - Vertical-rule dividers (1pt × 16pt, hairline color) between groups
//      — telegraphs four discrete numbers without each one needing its
//      own card.
//    - Sent/Received include their share-of-total (e.g. "34.1%") inline
//      as a secondary muted caption, so the user gets the proportion
//      without us building a separate "ratio" tile.
//    - `.contentTransition(.numericText())` on each number so the digits
//      roll over during a brush drag — same Wallet/Fitness affordance the
//      old StatTile had.
//
//  Layout robustness:
//    - At 1200pt width the strip reads comfortably edge-to-edge.
//    - At ~900pt (the dashboard's minimum window width) the row stays
//      single-line; truncation policy on the value labels is `.tail`
//      with `.minimumScaleFactor(0.85)` so the numbers stay legible.
//    - On VoiceOver every cell is announced as a single phrase: "Total,
//      525,362 messages, all time."
//

import SwiftUI

struct OverviewStatStrip: View {

    let stats: DashboardStats.OverviewCounters?
    /// Optional context line rendered above the strip (e.g. "All time ·
    /// last refreshed just now"). Kept optional so the strip can be
    /// dropped in below a chart's subtitle without doubling up.
    var subtitle: String? = nil

    var body: some View {
        GlassCard(cornerRadius: Radius.medium, showsBorder: true) {
            row
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private var row: some View {
        HStack(alignment: .center, spacing: Space.md) {
            // No per-cell scope captions ("all time", "conversations")
            // — they were misleading once brushed ranges came online
            // (the labels would say "all time" while the numbers
            // reflected a 28-day window). The trailing subtitle now
            // carries the scope, and Sent/Received still show their
            // percentage caption because that's intrinsic to the
            // number, not its scope.
            cell(label: "Total",
                 number: formatBig(stats?.total),
                 caption: nil,
                 numericValue: Double(stats?.total ?? 0))
            divider
            cell(label: "Sent",
                 number: formatBig(stats?.sent),
                 caption: sentPct,
                 numericValue: Double(stats?.sent ?? 0))
            divider
            cell(label: "Received",
                 number: formatBig(stats?.received),
                 caption: receivedPct,
                 numericValue: Double(stats?.received ?? 0))
            divider
            cell(label: "Chats",
                 number: formatBig(stats?.chats),
                 caption: nil,
                 numericValue: Double(stats?.chats ?? 0))

            // Trailing subtitle — context line tucked at the right.
            // Soft, secondary, doesn't compete with the numbers.
            if let subtitle, !subtitle.isEmpty {
                Spacer(minLength: Space.md)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cell

    /// One stat cell — UPPERCASE label, big number, optional muted caption
    /// (percent share or scope tag). Numbers use `.contentTransition` so
    /// they roll over during a brush drag.
    @ViewBuilder
    private func cell(
        label: String,
        number: String,
        caption: String?,
        numericValue: Double
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(number)
                .font(.system(size: 17, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.numericText(value: numericValue))
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(number)\(caption.map { ", \($0)" } ?? "")")
    }

    /// Vertical hairline divider between cells. Short (16pt tall) so it
    /// reads as a typographic separator, not a panel boundary.
    private var divider: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }

    // MARK: - Computed captions

    private var sentPct: String? {
        guard let s = stats, s.total > 0 else { return nil }
        return String(format: "%.1f%%", Double(s.sent) / Double(s.total) * 100.0)
    }

    private var receivedPct: String? {
        guard let s = stats, s.total > 0 else { return nil }
        return String(format: "%.1f%%", Double(s.received) / Double(s.total) * 100.0)
    }

    private func formatBig(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number.grouping(.automatic))
    }
}

// MARK: - Previews

#Preview("OverviewStatStrip — populated", traits: .fixedLayout(width: 1100, height: 64)) {
    OverviewStatStrip(
        stats: DashboardStats.OverviewCounters(
            total: 525_362,
            sent: 178_955,
            received: 346_407,
            chats: 1_263,
            oldest: nil,
            newest: nil
        ),
        subtitle: "All time · refreshed just now"
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("OverviewStatStrip — narrow", traits: .fixedLayout(width: 900, height: 64)) {
    OverviewStatStrip(
        stats: DashboardStats.OverviewCounters(
            total: 184_392,
            sent: 92_304,
            received: 92_088,
            chats: 147,
            oldest: nil,
            newest: nil
        ),
        subtitle: nil
    )
    .padding(Space.lg)
    .background(Color.chromeBackground)
}

#Preview("OverviewStatStrip — loading", traits: .fixedLayout(width: 1100, height: 64)) {
    OverviewStatStrip(stats: nil, subtitle: "Loading…")
        .padding(Space.lg)
        .background(Color.chromeBackground)
}
