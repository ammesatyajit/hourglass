//
//  SocialGraphCanvas.swift
//  Hourglass — Dashboard / Social Graph
//
//  The force-directed render. Draws the precomputed `GraphLayout` into a
//  SwiftUI `Canvas` and layers interactivity on top:
//
//    • drag empty space → pan
//    • scroll / pinch   → zoom about the cursor
//    • hover a node     → highlight + floating label
//    • tap a node       → pin its label (tap again / tap empty space to clear)
//    • biggest nodes are always labeled so the graph reads at a glance
//
//  The simulation already ran off-main (`ForceLayout`); this view only maps
//  layout coords → screen and paints. Hover hit-testing is a cheap O(n) scan
//  over the (capped) node set per mouse move — negligible.
//
//  Rendering policy: the graph canvas may use the accent palette + per-circle
//  tints (per the panel brief). The containing `StatPanel` keeps the solid +
//  hairline content-layer styling.
//

import SwiftUI

struct SocialGraphCanvas: View {

    let result: SocialGraphResult

    // Interaction state.
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
        // Base transform: fit the layout's bounding box into the canvas
        // with padding, then apply user zoom + pan on top.
        let transform = ScreenTransform(
            layout: layout,
            canvas: canvasSize,
            zoom: zoom,
            pan: pan
        )

        ZStack {
            Canvas { ctx, size in
                guard canvasSize != .zero else { return }
                drawEdges(ctx: ctx, transform: transform)
                drawNodes(ctx: ctx, transform: transform, size: size)
            }
            // Flatten the whole edges+nodes+labels draw into ONE offscreen GPU
            // texture. This is a complex vector Canvas (per-node circles, halos,
            // and expensive per-label `ctx.resolve(Text)`); without this, the
            // page ScrollView re-rasterizes it as it moves, making the graph a
            // big contributor to page-scroll lag. Flattened, scrolling just
            // translates the cached texture. The live hover label sits OUTSIDE
            // this (labelOverlay in the ZStack) so it stays interactive.
            .drawingGroup()
            .contentShape(Rectangle())

            // Floating label for the active (hovered or pinned) node, if
            // it isn't already an always-on label.
            labelOverlay(transform: transform)
        }
        .background(canvasBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
        )
        // Hover hit-testing.
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hoveredID = nearestNode(to: p, transform: transform)?.id
            case .ended:
                hoveredID = nil
            }
        }
        // Pan.
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
        // Zoom (trackpad pinch).
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = clampZoom(committedZoom * value.magnification)
                }
                .onEnded { _ in committedZoom = zoom }
        )
        // Tap to pin / clear a label.
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

    // MARK: - Background

    private var canvasBackground: some View {
        // A very subtle vertical wash so the colored nodes pop without the
        // panel turning into a glass surface (content-layer stays solid).
        LinearGradient(
            colors: [
                Color(nsColor: .textBackgroundColor),
                Color(nsColor: .textBackgroundColor).opacity(0.94)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Drawing — edges

    private func drawEdges(ctx: GraphicsContext, transform: ScreenTransform) {
        let highlight = hoveredID ?? pinnedID
        for edge in graph.edges {
            guard let p1 = transform.point(forNodeID: edge.a),
                  let p2 = transform.point(forNodeID: edge.b) else { continue }

            let touchesHighlight = (highlight == nil) || (edge.a == highlight) || (edge.b == highlight)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            let baseColor: Color
            switch edge.kind {
            case .direct:
                // Spokes from the center: neutral, thin, weight-scaled.
                baseColor = Color.primary.opacity(highlight == nil ? 0.10 : (touchesHighlight ? 0.22 : 0.04))
            case .coMembership:
                // The circle web: tint by the community of the heavier-degree
                // endpoint so intra-circle ties echo the node color.
                let cid = communityID(forEdge: edge)
                baseColor = CommunityPalette.color(for: cid)
                    .opacity(highlight == nil ? 0.22 : (touchesHighlight ? 0.42 : 0.05))
            }

            let lineWidth = edgeWidth(edge)
            ctx.stroke(path, with: .color(baseColor), lineWidth: lineWidth)
        }
    }

    /// Pick the community to tint a co-membership edge by — use whichever
    /// endpoint has a real (non-negative) community; fall back to the first.
    private func communityID(forEdge edge: GraphEdge) -> Int {
        let ca = node(edge.a)?.communityID ?? -1
        let cb = node(edge.b)?.communityID ?? -1
        if ca >= 0 { return ca }
        return cb
    }

    private func edgeWidth(_ edge: GraphEdge) -> CGFloat {
        // Log-scaled so a 9000-message tie isn't 300× a 30-message tie.
        let w = 0.6 + 0.7 * log10(max(edge.weight, 1) + 1)
        return min(max(w, 0.5), 3.5)
    }

    // MARK: - Drawing — nodes

    private func drawNodes(ctx: GraphicsContext, transform: ScreenTransform, size: CGSize) {
        let highlight = hoveredID ?? pinnedID
        // Pre-compute the always-labeled set (biggest nodes) once.
        let labeled = alwaysLabeledIDs()

        for node in graph.nodes {
            guard let p = transform.point(forNodeID: node.id) else { continue }
            let r = nodeRadius(node)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            let fill: Color = node.isMe
                ? CommunityPalette.centerColor
                : CommunityPalette.color(for: node.communityID)

            let isActive = (node.id == highlight)
            let dim = (highlight != nil) && !isActive && !isNeighbor(node.id, of: highlight)

            // Soft halo for the center + active node.
            if node.isMe || isActive {
                let haloR = r + (node.isMe ? 6 : 4)
                let haloRect = CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)
                ctx.fill(Circle().path(in: haloRect), with: .color(fill.opacity(0.18)))
            }

            ctx.fill(Circle().path(in: rect), with: .color(fill.opacity(dim ? 0.28 : 1.0)))
            // Hairline ring.
            ctx.stroke(
                Circle().path(in: rect),
                with: .color(Color.white.opacity(dim ? 0.10 : 0.55)),
                lineWidth: node.isMe ? 2 : 1
            )

            // Always-on label for the biggest nodes + the center; the active
            // node gets its label in the overlay layer (so it can sit above
            // everything and stay legible).
            if (labeled.contains(node.id) || node.isMe) && !isActive && !dim {
                drawLabel(ctx: ctx, text: node.displayName, at: p, radius: r, emphasized: node.isMe)
            }
        }
    }

    private func drawLabel(ctx: GraphicsContext, text: String, at p: CGPoint, radius: CGFloat, emphasized: Bool) {
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

    private func detailLine(for node: GraphNode) -> String? {
        if node.isMe { return "you" }
        var parts: [String] = []
        if node.directMessageCount > 0 {
            parts.append("\(node.directMessageCount.formatted()) messages")
        }
        if node.sharedGroupCount > 0 {
            parts.append("\(node.sharedGroupCount) shared group\(node.sharedGroupCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Zoom controls

    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomButton("minus") { setZoom(committedZoom / 1.3) }
            zoomButton("arrow.counterclockwise") { resetView() }
            zoomButton("plus") { setZoom(committedZoom * 1.3) }
        }
        .padding(4)
        .background(
            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        )
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
        withAnimation(.bmDefault) {
            committedZoom = clampZoom(z)
            zoom = committedZoom
        }
    }

    private func resetView() {
        withAnimation(.bmDefault) {
            zoom = 1; committedZoom = 1
            pan = .zero; committedPan = .zero
            pinnedID = nil
        }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, 0.4), 6.0) }

    // MARK: - Node geometry

    /// Node radius from `weightScore`, gently log-scaled into a legible band.
    private func nodeRadius(_ node: GraphNode) -> CGFloat {
        if node.isMe { return 16 }
        let s = node.weightScore
        let r = 5.0 + 5.0 * log10(s + 1)
        return CGFloat(min(max(r, 4.5), 22))
    }

    /// The set of node ids that always carry a label — the center plus the top
    /// few contacts by weight, so the graph reads without hovering.
    private func alwaysLabeledIDs() -> Set<String> {
        let top = graph.nodes
            .filter { !$0.isMe }
            .sorted { $0.weightScore > $1.weightScore }
            .prefix(12)
            .map(\.id)
        return Set(top)
    }

    // MARK: - Hit testing / lookups

    private func node(_ id: String) -> GraphNode? {
        graph.nodes.first { $0.id == id }
    }

    private func isNeighbor(_ id: String, of other: String?) -> Bool {
        guard let other else { return false }
        for e in graph.edges {
            if (e.a == other && e.b == id) || (e.b == other && e.a == id) { return true }
        }
        return false
    }

    /// Nearest node within its hit radius to a screen point, else nil.
    private func nearestNode(to point: CGPoint, transform: ScreenTransform) -> GraphNode? {
        var best: GraphNode?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for node in graph.nodes {
            guard let p = transform.point(forNodeID: node.id) else { continue }
            let dx = p.x - point.x
            let dy = p.y - point.y
            let d = (dx * dx + dy * dy).squareRoot()
            let hitR = max(nodeRadius(node) + 6, 12)
            if d <= hitR && d < bestDist {
                bestDist = d
                best = node
            }
        }
        return best
    }

    // MARK: - Label shortening

    private func shortLabel(_ name: String) -> String {
        // First name (or first token) keeps the canvas uncluttered; the full
        // name shows in the hover tooltip.
        if let first = name.split(whereSeparator: { $0 == " " || $0 == "," }).first {
            return String(first)
        }
        return name
    }
}

// MARK: - Screen transform

/// Maps layout-space coordinates (centered on origin, from `GraphLayout`) into
/// canvas/screen points, honoring a fit-to-box base scale plus user zoom/pan.
struct ScreenTransform {
    let positions: [String: LayoutPoint]
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    init(layout: GraphLayout, canvas: CGSize, zoom: CGFloat, pan: CGSize) {
        self.positions = layout.positions
        let padding: CGFloat = 48
        let availW = max(canvas.width - padding * 2, 1)
        let availH = max(canvas.height - padding * 2, 1)
        // Layout is centered on origin; its half-extent in each axis:
        let halfW = max(layout.width / 2, 1e-3)
        let halfH = max(layout.height / 2, 1e-3)
        let fit = min(availW / CGFloat(halfW * 2), availH / CGFloat(halfH * 2))
        self.scale = fit * zoom
        // Center of canvas + user pan. Layout origin (0,0) maps to canvas
        // center because positions are centered on their centroid.
        self.offsetX = canvas.width / 2 + pan.width
        self.offsetY = canvas.height / 2 + pan.height
    }

    func point(forNodeID id: String) -> CGPoint? {
        guard let lp = positions[id] else { return nil }
        return CGPoint(
            x: offsetX + CGFloat(lp.x) * scale,
            y: offsetY + CGFloat(lp.y) * scale
        )
    }
}
