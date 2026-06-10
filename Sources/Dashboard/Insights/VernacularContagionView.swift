//
//  VernacularContagionView.swift
//  Hourglass — Vernacular Analysis (Most Funny)
//
//  ReactedGemsGrid — "Most Funny / Reacted-to." Cards from `reactedGems`:
//     the phrase (big), a laugh-rate chip ("landed N% of the time" from
//     amusedRate), `yourUses`, and the `example` in quotes.
//
//  STYLE: matches `StatPanel` + the existing Vernacular inner cards (solid
//  surface + hairline border per the glass policy). All spacing/radius/tint
//  pulled from `DesignTokens`. Dark-mode correct; reduce-motion respected.
//  Deployment floor is macOS 15 — TimelineView + Canvas are fine.
//

import SwiftUI

// MARK: - Reacted gems

/// "Most Funny / Reacted-to": cards from `reactedGems`. The phrase is the hero;
/// a laugh-rate chip + your-uses + a real example flesh it out.
struct ReactedGemsGrid: View {
    let gems: [ReactedGem]

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Space.md)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
            ForEach(gems.prefix(8)) { gem in
                ReactedGemCard(gem: gem)
            }
        }
    }
}

private struct ReactedGemCard: View {
    let gem: ReactedGem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // The phrase — the hero of the card.
            Text("“\(gem.phrase)”")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.xs) {
                Text("😂 landed \(percent(gem.amusedRate)) of the time")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Space.xs + 1).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                Spacer(minLength: Space.xs)
                Text("\(gem.yourUses)× said")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let ex = gem.example, !ex.isEmpty {
                Text("“\(ex)”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
        .help("“\(gem.phrase)” — \(gem.amusedCount) amused reactions across \(gem.yourUses) uses")
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
