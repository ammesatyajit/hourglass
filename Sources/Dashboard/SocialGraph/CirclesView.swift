//
//  CirclesView.swift
//  Hourglass — Dashboard / Social Graph
//
//  The ALTERNATE visualization (the brief asked for "different ways of
//  visualizing this"). Where the force graph shows the topology, this view
//  makes the *circles* themselves the unit: each detected community becomes a
//  card with its members packed inside as colored dots (sized by volume), the
//  biggest member naming the card. It answers "what circles am I in, and who's
//  in each?" at a glance — complementary to the graph's "how do they connect?"
//
//  Pure presentation over the already-clustered `SocialGraph`. No simulation,
//  no chat.db — it just groups nodes by `communityID` and lays each group out
//  on a small phyllotaxis spiral inside its card (deterministic, no overlap
//  for the counts we cap at).
//

import SwiftUI

struct CirclesView: View {

    let graph: SocialGraph

    private var circles: [CircleGroup] {
        CircleGroup.from(graph: graph)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: Space.md)],
                spacing: Space.md
            ) {
                ForEach(circles) { circle in
                    circleCard(circle)
                }
            }
            .padding(Space.xs)
        }
    }

    private func circleCard(_ circle: CircleGroup) -> some View {
        let tint = CommunityPalette.color(for: circle.id)
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Circle().fill(tint).frame(width: 10, height: 10)
                Text(circle.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(circle.members.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Packed dots. The `Canvas` supplies its own `size`, so no
            // `GeometryReader` is needed — wrapping it in one only made the
            // closure re-evaluate its (unused) proxy on every scroll frame.
            Canvas { ctx, size in
                drawPack(ctx: ctx, size: size, members: circle.members, tint: tint)
            }
            .frame(height: 120)

            // A couple of named members for context.
            Text(circle.memberSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.contentBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }

    /// Phyllotaxis (sunflower) packing — deterministic, evenly spread, no
    /// overlap at our member counts. Biggest members near the center.
    private func drawPack(ctx: GraphicsContext, size: CGSize, members: [GraphNode], tint: Color) {
        guard !members.isEmpty else { return }
        let sorted = members.sorted { $0.weightScore > $1.weightScore }
        let cx = size.width / 2
        let cy = size.height / 2
        let golden = Double.pi * (3.0 - 5.0.squareRoot()) // ~2.39996 rad
        let maxR = min(size.width, size.height) / 2 - 10
        let n = sorted.count

        for (i, node) in sorted.enumerated() {
            let frac = n <= 1 ? 0 : Double(i) / Double(n - 1)
            let radius = maxR * frac.squareRoot()
            let theta = Double(i) * golden
            let x = cx + CGFloat(radius * cos(theta))
            let y = cy + CGFloat(radius * sin(theta))
            let dotR = dotRadius(node)
            let rect = CGRect(x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
            ctx.fill(Circle().path(in: rect), with: .color(tint.opacity(0.85)))
            ctx.stroke(Circle().path(in: rect), with: .color(.white.opacity(0.5)), lineWidth: 0.75)
        }
    }

    private func dotRadius(_ node: GraphNode) -> CGFloat {
        let r = 3.0 + 3.5 * log10(node.weightScore + 1)
        return CGFloat(min(max(r, 3), 13))
    }
}

// MARK: - CircleGroup

/// A community grouped for the Circles view: its members + a human title
/// (its highest-volume member) + a one-line member summary.
struct CircleGroup: Identifiable {
    let id: Int
    let members: [GraphNode]
    let title: String
    let memberSummary: String

    /// Group `graph`'s contact nodes by community, keep groups with ≥2
    /// members (singletons are 1:1-only contacts — not a "circle"), and sort
    /// by size descending (matching the palette's lead-color ordering).
    static func from(graph: SocialGraph) -> [CircleGroup] {
        var byCommunity: [Int: [GraphNode]] = [:]
        for node in graph.nodes where !node.isMe && node.communityID >= 0 {
            byCommunity[node.communityID, default: []].append(node)
        }
        return byCommunity
            .filter { $0.value.count >= 2 }
            .map { (id, nodes) in
                let sorted = nodes.sorted { $0.weightScore > $1.weightScore }
                let title = sorted.first?.displayName ?? "Circle \(id + 1)"
                let names = sorted.prefix(4).map(\.displayName).joined(separator: ", ")
                let extra = sorted.count > 4 ? " +\(sorted.count - 4) more" : ""
                return CircleGroup(
                    id: id,
                    members: sorted,
                    title: title,
                    memberSummary: names + extra
                )
            }
            .sorted { $0.id < $1.id }
    }
}

// MARK: - CircleFlowLayout

/// A minimal wrapping HStack (left-to-right, wrap to next line). Used by the
/// legend so circle swatches reflow to the panel width. Dependency-free
/// `Layout` conformance — no third-party flow-layout package.
struct CircleFlowLayout: Layout {
    var spacing: CGFloat = Space.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.isEmpty ? 0 : rows.map(\.height).reduce(0, +) + spacing * CGFloat(rows.count - 1)
        let width: CGFloat = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && !current.items.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.items.append(i)
            x += size.width + spacing
            current.width = max(current.width, x - spacing)
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
