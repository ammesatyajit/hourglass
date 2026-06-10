//
//  VibeGraphCanvas.swift
//  Hourglass — Dashboard / Social Graph (Vibe lens)
//
//  The "Vibe" view-mode of the social graph. Like the Vocabulary lens, it
//  renders on the SAME force-directed layout the `SocialGraphCanvas` uses (same
//  `ScreenTransform`, same node positions, same pan/zoom/hover model) — Vibe is
//  an ADDITIVE LENS, not a rebuild. What changes vs. the default "Graph" mode:
//
//    • Every node is RECOLORED by its dialect cluster — the way the person
//      texts, NOT the social circle they sit in. Two people in the same friend
//      group can light up different colors; two people in different circles can
//      share a color. That mismatch IS the point: speech-style cuts across
//      friend groups.
//    • People with no fingerprint (didn't clear the message gate) dim to a
//      muted grey.
//    • The co-membership web stays as faint scaffolding (it's the social
//      structure the dialect coloring is drawn ON TOP of — keeping it faint
//      lets the eye see a single circle holding two different dialects).
//    • "You" keeps the neutral center treatment but ALSO carries a thin ring in
//      your own dialect's color, so you can find your own speech-cluster.
//
//  DATA WIRING
//  ===========
//  The lens takes the social `SocialGraphResult` (positions + node set) AND the
//  published vibe data: `[VibeCluster]` (for the legend) + a `[String: Int]`
//  display-name → cluster-id lookup (`VernacularViewModel.vibeClusterByContact`).
//  Each `GraphNode.displayName` is matched DIRECTLY against that lookup (it's the
//  same string the clusterer keyed on, incl. "You"). No fuzzy matching needed.
//
//  This file is owned by design-agent. It reads published, read-only value types
//  and the existing `SocialGraphResult`; it does NOT touch the vernacular DATA
//  layer or the social-graph build.
//

import SwiftUI

// MARK: - Vibe palette (parallel to CommunityPalette, deliberately distinct)

/// A fixed palette for coloring DIALECT clusters. Kept SEPARATE from
/// `CommunityPalette` (and rotated to different hues) on purpose: when the user
/// toggles Graph → Vibe, the colors visibly SHIFT, which is what surfaces the
/// "your speech-style doesn't follow your friend groups" insight. Six entries
/// (k=6 clusters); wraps with a lightness shift past that.
enum VibePalette {

    /// Six well-separated hues tuned for both light + dark backgrounds. Ordered
    /// so the lower cluster ids (which the clusterer tends to seed first) get the
    /// most legible leads.
    static let hues: [Color] = [
        Color(hue: 0.55, saturation: 0.70, brightness: 0.95), // bright azure
        Color(hue: 0.95, saturation: 0.62, brightness: 0.95), // rose
        Color(hue: 0.13, saturation: 0.85, brightness: 0.97), // gold
        Color(hue: 0.42, saturation: 0.66, brightness: 0.82), // emerald
        Color(hue: 0.74, saturation: 0.60, brightness: 0.93), // violet
        Color(hue: 0.07, saturation: 0.80, brightness: 0.95), // tangerine
    ]

    /// Muted grey for contacts with no dialect fingerprint (didn't clear the
    /// message gate). Resolved to a concrete color so the Canvas can use it.
    static let unclustered = Color(nsColor: .tertiaryLabelColor)

    /// Neutral fill for the center "You" node — matches the other lenses so the
    /// user reads as the same anchor across modes.
    static let centerColor = Color.accentColor

    /// Color for a cluster id. Negative / out-of-range ids fall back to the
    /// muted grey. Wrapping (>6 clusters, shouldn't happen at k=6) reuses hues
    /// with a slight desaturation so wrapped clusters stay distinguishable.
    static func color(for clusterID: Int) -> Color {
        guard clusterID >= 0 else { return unclustered }
        let base = hues[clusterID % hues.count]
        if clusterID < hues.count { return base }
        return base.opacity(0.78)
    }
}

// MARK: - Overlay model (the lens, resolved against the social layout)

/// Resolves the published vibe-cluster lookup against the visible social graph.
/// Pure + cheap: for each node, look up its display name in the cluster lookup.
struct VibeOverlay {

    /// node id → cluster id (only nodes that have a fingerprint appear here).
    let clusterByNodeID: [String: Int]
    /// The clusters present in this lens, in the order they should appear in the
    /// legend (largest visible membership first), each tagged with whether it's
    /// "your" cluster (contains You).
    let legendClusters: [LegendCluster]
    /// How many visible nodes (excluding You) carry a dialect color.
    let coloredCount: Int
    /// How many visible nodes (excluding You) are muted (no fingerprint).
    let mutedCount: Int

    struct LegendCluster: Identifiable {
        let id: Int
        let label: String
        let visibleMemberCount: Int
        let containsYou: Bool
    }

    init(clusters: [VibeCluster], clusterByContact: [String: Int], social: SocialGraph) {
        var byNode: [String: Int] = [:]
        var visibleCountByCluster: [Int: Int] = [:]
        var youCluster: Int? = nil
        var colored = 0
        var muted = 0

        for node in social.nodes {
            if node.isMe {
                // "You" is keyed in the lookup as its display name (the clusterer
                // uses "You"); resolve it for the ring + the legend's "yours" tag.
                youCluster = clusterByContact[node.displayName]
                if let yc = youCluster { byNode[node.id] = yc }
                continue
            }
            if let cid = clusterByContact[node.displayName] {
                byNode[node.id] = cid
                visibleCountByCluster[cid, default: 0] += 1
                colored += 1
            } else {
                muted += 1
            }
        }

        // Build the legend from the published clusters, keeping only those with
        // at least one visible member (or that contain You), sorted by visible
        // membership desc so the dominant dialect leads.
        let legend: [LegendCluster] = clusters.compactMap { cluster in
            let visible = visibleCountByCluster[cluster.id] ?? 0
            let isYours = (youCluster == cluster.id)
            guard visible > 0 || isYours else { return nil }
            return LegendCluster(
                id: cluster.id,
                label: cluster.label.isEmpty ? "Cluster \(cluster.id + 1)" : cluster.label,
                visibleMemberCount: visible,
                containsYou: isYours
            )
        }
        .sorted { lhs, rhs in
            if lhs.visibleMemberCount != rhs.visibleMemberCount {
                return lhs.visibleMemberCount > rhs.visibleMemberCount
            }
            return lhs.id < rhs.id
        }

        self.clusterByNodeID = byNode
        self.legendClusters = legend
        self.coloredCount = colored
        self.mutedCount = muted
    }

    /// Nothing useful to show if no visible node carries a color.
    var isEmpty: Bool { coloredCount == 0 }
}

// MARK: - Canvas

/// The Vibe lens render. Mirrors `SocialGraphCanvas`'s interaction model (pan /
/// zoom / hover / tap-to-pin) and uses the identical `ScreenTransform` so
/// toggling modes keeps every node exactly where it was — only the node COLORS
/// and the legend change.
struct VibeGraphCanvas: View {

    let result: SocialGraphResult
    let overlay: VibeOverlay

    @State private var zoom: CGFloat = 1.0
    @State private var committedZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    @State private var hoveredID: String?
    @State private var pinnedID: String?
    /// Canvas size captured via `onGeometryChange` so the transform stays STABLE
    /// during scroll. A `GeometryReader` re-publishes its frame on EVERY scroll
    /// position change → re-evaluates the body → re-draws the whole Canvas every
    /// frame (the Vernacular scroll lag). This updates only when the size
    /// genuinely changes, so scrolling no longer touches the graph.
    @State private var canvasSize: CGSize = .zero

    private var graph: SocialGraph { result.graph }
    private var layout: GraphLayout { result.layout }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            legend

            let transform = ScreenTransform(
                layout: layout, canvas: canvasSize, zoom: zoom, pan: pan
            )
            ZStack {
                Canvas { ctx, size in
                    guard canvasSize != .zero else { return }
                    drawComembership(ctx: ctx, transform: transform)
                    drawNodes(ctx: ctx, transform: transform, size: size)
                }
                .contentShape(Rectangle())

                labelOverlay(transform: transform)
            }
            .background(canvasBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoveredID = nearestNode(to: p, transform: transform)?.id
                case .ended:
                    hoveredID = nil
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        pan = CGSize(
                            width: committedPan.width + value.translation.width,
                            height: committedPan.height + value.translation.height
                        )
                    }
                    .onEnded { _ in committedPan = pan }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = clampZoom(committedZoom * value.magnification) }
                    .onEnded { _ in committedZoom = zoom }
            )
            .onTapGesture { location in
                if let hit = nearestNode(to: location, transform: transform) {
                    pinnedID = (pinnedID == hit.id) ? nil : hit.id
                } else {
                    pinnedID = nil
                }
            }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { newSize in
                if canvasSize != newSize { canvasSize = newSize }
            }
        }
    }

    // MARK: - Background (identical to the default graph mode)

    private var canvasBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .textBackgroundColor),
                Color(nsColor: .textBackgroundColor).opacity(0.94)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: - Edges: faint co-membership scaffolding

    /// Draw the social web VERY faintly — it's the structure the dialect colors
    /// are painted over. The whole point of the lens is to see speech-style cut
    /// across these ties, so they stay as quiet context.
    private func drawComembership(ctx: GraphicsContext, transform: ScreenTransform) {
        for edge in graph.edges where edge.kind == .coMembership {
            guard let p1 = transform.point(forNodeID: edge.a),
                  let p2 = transform.point(forNodeID: edge.b) else { continue }
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            ctx.stroke(path, with: .color(Color.primary.opacity(0.055)), lineWidth: 0.6)
        }
    }

    // MARK: - Nodes (recolored by dialect cluster)

    private func drawNodes(ctx: GraphicsContext, transform: ScreenTransform, size: CGSize) {
        let highlight = hoveredID ?? pinnedID

        for node in graph.nodes {
            guard let p = transform.point(forNodeID: node.id) else { continue }
            let r = nodeRadius(node)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            let clusterID = overlay.clusterByNodeID[node.id]
            let isClustered = clusterID != nil
            let isActive = (node.id == highlight)
            let dimByHighlight = (highlight != nil) && !isActive
                && !isNeighbor(node.id, of: highlight)

            // Color policy: You stays the neutral center accent; clustered nodes
            // take their DIALECT color; everyone else is muted grey.
            let fill: Color
            if node.isMe {
                fill = VibePalette.centerColor
            } else if let cid = clusterID {
                fill = VibePalette.color(for: cid)
            } else {
                fill = VibePalette.unclustered
            }

            // Opacity: unclustered nodes sit back as context; clustered nodes are
            // solid (and dim slightly when another node is highlighted).
            let baseOpacity: Double = isClustered || node.isMe ? 1.0 : 0.34
            let opacity = dimByHighlight ? baseOpacity * 0.30 : baseOpacity

            // Soft halo for the center + the active node.
            if node.isMe || isActive {
                let haloR = r + (node.isMe ? 6 : 4)
                let haloRect = CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)
                ctx.fill(Circle().path(in: haloRect), with: .color(fill.opacity(0.18)))
            }

            ctx.fill(Circle().path(in: rect), with: .color(fill.opacity(opacity)))

            // Ring. "You" carries a ring in YOUR dialect's color (if you have
            // one) so you can spot your own speech cluster against the neutral
            // disc; everyone else gets the standard white hairline.
            if node.isMe, let yc = clusterID {
                ctx.stroke(Circle().path(in: rect),
                           with: .color(VibePalette.color(for: yc)),
                           lineWidth: 2.5)
            } else {
                ctx.stroke(
                    Circle().path(in: rect),
                    with: .color(Color.white.opacity(dimByHighlight ? 0.10
                                                     : (isClustered || node.isMe ? 0.55 : 0.18))),
                    lineWidth: node.isMe ? 2 : 1
                )
            }

            // Labels: always label You + the biggest clustered nodes; the active
            // node gets its label in the overlay layer instead.
            if (node.isMe || (isClustered && isBigEnoughToLabel(node)))
                && !isActive && !dimByHighlight {
                drawLabel(
                    ctx: ctx, text: node.displayName, at: p, radius: r,
                    emphasized: node.isMe
                )
            }
        }
    }

    private func drawLabel(
        ctx: GraphicsContext, text: String, at p: CGPoint, radius: CGFloat,
        emphasized: Bool
    ) {
        let resolved = ctx.resolve(
            Text(shortLabel(text))
                .font(emphasized ? .caption.weight(.semibold) : .caption2.weight(.medium))
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
        )
        let textSize = resolved.measure(in: CGSize(width: 120, height: 40))
        let origin = CGPoint(x: p.x - textSize.width / 2, y: p.y + radius + 2)
        ctx.draw(resolved, in: CGRect(origin: origin, size: textSize))
    }

    // MARK: - Active-node label overlay

    @ViewBuilder
    private func labelOverlay(transform: ScreenTransform) -> some View {
        let activeID = hoveredID ?? pinnedID
        if let activeID, let node = node(activeID), let p = transform.point(forNodeID: activeID) {
            let r = nodeRadius(node)
            VStack(spacing: 1) {
                Text(node.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail = detailLine(for: node) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            )
            .fixedSize()
            .position(x: p.x, y: max(p.y - r - 18, 14))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The tooltip line for the Vibe lens: which dialect cluster the person sits
    /// in (its marker label), or "no dialect read yet" for muted nodes.
    private func detailLine(for node: GraphNode) -> String? {
        if let cid = overlay.clusterByNodeID[node.id],
           let cluster = overlay.legendClusters.first(where: { $0.id == cid }) {
            if node.isMe { return "your dialect · \(cluster.label)" }
            return cluster.label
        }
        if node.isMe { return "you" }
        return "not enough messages to read a dialect"
    }

    // MARK: - Legend (the cluster key — the heart of this lens)

    private var legend: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            CircleFlowLayout(spacing: Space.sm) {
                ForEach(overlay.legendClusters) { cluster in
                    HStack(spacing: Space.xs) {
                        Circle()
                            .fill(VibePalette.color(for: cluster.id))
                            .frame(width: 9, height: 9)
                        Text(cluster.label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if cluster.containsYou {
                            Text("you")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(VibePalette.color(for: cluster.id))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(VibePalette.color(for: cluster.id).opacity(0.16)))
                        }
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.contentBackground.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                }

                if overlay.mutedCount > 0 {
                    HStack(spacing: Space.xs) {
                        Circle().fill(VibePalette.unclustered).frame(width: 9, height: 9)
                        Text("not enough to read")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.contentBackground.opacity(0.6)))
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                }
            }
        }
    }

    // MARK: - Zoom controls (identical affordance to the default mode)

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus") { setZoom(committedZoom / 1.3) }
            zoomButton("arrow.counterclockwise") { resetView() }
            zoomButton("plus") { setZoom(committedZoom * 1.3) }
        }
        .padding(4)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
        .padding(Space.sm)
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.bmDefault) { committedZoom = clampZoom(z); zoom = committedZoom }
    }

    private func resetView() {
        withAnimation(.bmDefault) {
            zoom = 1; committedZoom = 1
            pan = .zero; committedPan = .zero
            pinnedID = nil
        }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.4), 6.0) }

    // MARK: - Geometry / hit-testing (matches SocialGraphCanvas)

    private func nodeRadius(_ node: GraphNode) -> CGFloat {
        if node.isMe { return 16 }
        let s = node.weightScore
        let r = 5.0 + 5.0 * log10(s + 1)
        return CGFloat(min(max(r, 4.5), 22))
    }

    /// Label only the larger clustered nodes so the canvas stays readable; the
    /// smaller ones reveal their name on hover.
    private func isBigEnoughToLabel(_ node: GraphNode) -> Bool {
        nodeRadius(node) >= 9
    }

    private func node(_ id: String) -> GraphNode? { graph.nodes.first { $0.id == id } }

    private func isNeighbor(_ id: String, of other: String?) -> Bool {
        guard let other else { return false }
        for e in graph.edges {
            if (e.a == other && e.b == id) || (e.b == other && e.a == id) { return true }
        }
        return false
    }

    private func nearestNode(to point: CGPoint, transform: ScreenTransform) -> GraphNode? {
        var best: GraphNode?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for node in graph.nodes {
            guard let p = transform.point(forNodeID: node.id) else { continue }
            let dx = p.x - point.x, dy = p.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            let hitR = max(nodeRadius(node) + 6, 12)
            if d <= hitR && d < bestDist { bestDist = d; best = node }
        }
        return best
    }

    private func shortLabel(_ name: String) -> String {
        if let first = name.split(whereSeparator: { $0 == " " || $0 == "," }).first {
            return String(first)
        }
        return name
    }
}
