//
//  ReactionCluster.swift
//  Hourglass
//
//  Inline cluster of reaction badges, shown next to a search result. Each
//  badge is a small pill with the reaction's emoji + a count (when more than
//  one sender added the same kind of reaction). Up to 4 badges are visible;
//  beyond that we collapse into a "+N" pill.
//
//  Why a separate component
//  ------------------------
//  Both the spotlight panel's `SpotlightResultRow` and the browse window's
//  `ResultRow` need to render the cluster. Sharing the implementation here
//  keeps the two surfaces visually identical without a copy/paste tax.
//
//  Visual decisions (see plans.md change log for the rationale):
//  - Background: subtle solid (tertiary-ish), NOT glass. The result rows are
//    content per Apple HIG — glass is reserved for the navigation layer.
//  - Pill capsule with the emoji and the count (omitted when count == 1).
//  - Tooltip on hover lists the sender names so you can see who reacted.
//  - Compact: 16pt emoji, tiny vertical padding, designed to ride next to a
//    timestamp without dominating the row.
//

import SwiftUI

/// A horizontal row of reaction badges for one message.
struct ReactionCluster: View {

    let reactions: [Reaction]

    /// Maximum number of distinct-kind badges to render before collapsing
    /// into a "+N" overflow pill.
    private let maxVisibleBadges = 4

    var body: some View {
        if grouped.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 3) {
                ForEach(visibleGroups, id: \.identifier) { group in
                    ReactionBadge(
                        emoji: group.emoji,
                        count: group.senderNames.count,
                        tooltip: tooltip(for: group)
                    )
                }
                if overflowCount > 0 {
                    OverflowBadge(count: overflowCount, tooltip: overflowTooltip)
                }
            }
        }
    }

    // MARK: - Grouping

    /// One badge represents all reactions that share a `Kind.identifier`
    /// (i.e. all loves on this message become one ❤️ ×N badge).
    private struct Group {
        let identifier: String
        let emoji: String
        let senderNames: [String]
        /// Earliest reaction in this group — used as a tie-breaker for
        /// ordering so the cluster's badge order is stable across renders.
        let firstDate: Date
    }

    /// Bucket the reactions by kind, preserving order-of-first-appearance for
    /// deterministic rendering.
    private var grouped: [Group] {
        var seen: [String: Int] = [:]
        var groups: [Group] = []
        for r in reactions {
            let key = r.kind.identifier
            if let idx = seen[key] {
                let existing = groups[idx]
                groups[idx] = Group(
                    identifier: existing.identifier,
                    emoji: existing.emoji,
                    senderNames: existing.senderNames + [r.senderName],
                    firstDate: existing.firstDate
                )
            } else {
                seen[key] = groups.count
                groups.append(Group(
                    identifier: key,
                    emoji: r.kind.emoji,
                    senderNames: [r.senderName],
                    firstDate: r.date
                ))
            }
        }
        // Sort by count descending so the dominant reaction leads the cluster
        // (matches the visual ordering iMessage uses on the message bubble).
        // Tie-break by firstDate so badge order is stable.
        return groups.sorted { (a, b) -> Bool in
            if a.senderNames.count != b.senderNames.count {
                return a.senderNames.count > b.senderNames.count
            }
            return a.firstDate < b.firstDate
        }
    }

    private var visibleGroups: [Group] {
        Array(grouped.prefix(maxVisibleBadges))
    }

    private var overflowCount: Int {
        max(0, grouped.count - maxVisibleBadges)
    }

    private var overflowTooltip: String {
        let hidden = grouped.dropFirst(maxVisibleBadges)
        return hidden
            .map { "\($0.emoji) by \($0.senderNames.joined(separator: ", "))" }
            .joined(separator: "\n")
    }

    private func tooltip(for group: Group) -> String {
        if group.senderNames.count == 1 {
            return "\(group.emoji) by \(group.senderNames[0])"
        }
        return "\(group.emoji) by " + group.senderNames.joined(separator: ", ")
    }
}

// MARK: - Sub-views

/// A single reaction badge — emoji optionally followed by ×N when more than
/// one sender added the same kind. Tooltip lists sender names.
private struct ReactionBadge: View {
    let emoji: String
    let count: Int
    let tooltip: String

    var body: some View {
        HStack(spacing: 1) {
            Text(emoji)
                .font(.system(size: 11))
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        )
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tooltip)
    }
}

/// Overflow indicator when more reaction kinds exist than we render inline.
private struct OverflowBadge: View {
    let count: Int
    let tooltip: String

    var body: some View {
        Text("+\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
            )
            .help(tooltip)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(count) more reaction types. \(tooltip)")
    }
}

// MARK: - Previews

#Preview("ReactionCluster — variants", traits: .fixedLayout(width: 540, height: 280)) {
    let nowDate = Date()
    return VStack(alignment: .leading, spacing: Space.md) {
        // Single love
        ReactionCluster(reactions: [
            Reaction(kind: .love, senderName: "Mom", senderHandle: "+15551112222", date: nowDate, isFromMe: false),
        ])

        // Two loves + one laugh + one like
        ReactionCluster(reactions: [
            Reaction(kind: .love, senderName: "Mom", senderHandle: "+15551112222", date: nowDate, isFromMe: false),
            Reaction(kind: .love, senderName: "Dad", senderHandle: "+15553334444", date: nowDate, isFromMe: false),
            Reaction(kind: .laugh, senderName: "Alex", senderHandle: "+15555556666", date: nowDate, isFromMe: false),
            Reaction(kind: .like, senderName: "You", senderHandle: nil, date: nowDate, isFromMe: true),
        ])

        // Lots — should overflow into "+N"
        ReactionCluster(reactions: [
            Reaction(kind: .love, senderName: "A", senderHandle: "+1", date: nowDate, isFromMe: false),
            Reaction(kind: .like, senderName: "B", senderHandle: "+2", date: nowDate, isFromMe: false),
            Reaction(kind: .laugh, senderName: "C", senderHandle: "+3", date: nowDate, isFromMe: false),
            Reaction(kind: .emphasize, senderName: "D", senderHandle: "+4", date: nowDate, isFromMe: false),
            Reaction(kind: .question, senderName: "E", senderHandle: "+5", date: nowDate, isFromMe: false),
            Reaction(kind: .dislike, senderName: "F", senderHandle: "+6", date: nowDate, isFromMe: false),
        ])

        // Custom emoji
        ReactionCluster(reactions: [
            Reaction(kind: .customEmoji("🤓"), senderName: "Alex", senderHandle: "+1", date: nowDate, isFromMe: false),
            Reaction(kind: .customEmoji("☠️"), senderName: "Sam", senderHandle: "+2", date: nowDate, isFromMe: false),
            Reaction(kind: .customEmoji("🤓"), senderName: "You", senderHandle: nil, date: nowDate, isFromMe: true),
        ])
    }
    .padding(Space.xl)
    .background(Color.chromeBackground)
}
