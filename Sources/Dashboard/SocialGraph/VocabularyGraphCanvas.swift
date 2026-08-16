//
//  VocabularyGraphCanvas.swift
//  Hourglass — Dashboard / Social Graph (Vocabulary lens)
//
//  The "Vocabulary" view-mode of the social graph. It renders on the SAME
//  force-directed layout the `SocialGraphCanvas` uses (same `ScreenTransform`,
//  same node positions, same aesthetic) — Vocabulary is an ADDITIVE LENS, not
//  a rebuild. What changes vs. the default "Graph" mode:
//
//    • The co-membership web is DIMMED right back (it's context, not the point).
//    • Directed term-transmission edges are drawn from You(center) to each
//      person you traded vocab with:
//        – BLUE  = `.theyGaveYou`  (slang you picked UP from them), arrow → You
//        – ORANGE= `.youGaveThem`  (slang that spread FROM you), arrow → them
//      Edge thickness scales with the number of terms traded.
//    • People you never traded vocab with are dimmed to faint context dots.
//    • Selecting a trader opens a right-side inspector listing the FULL term list for
//      that relationship (each `VernacularGraph.Edge` carries the complete
//      `[TermFlow]` — we show ALL of them, with direction + example), grouped
//      incoming/outgoing.
//
//  DATA WIRING
//  ===========
//  The lens takes the social `SocialGraphResult` (for positions + the node set)
//  AND the published `VernacularGraph` (for the directed term flows). It matches
//  vernacular `edge.person` (a contact display name) to a `GraphNode` by name —
//  see `VocabularyOverlay.match(...)`. Names that don't resolve to a visible
//  node (capped out of the social graph) are quietly skipped; the footnote
//  surfaces how many traders are shown.
//
//  This file is owned by design-agent. It reads the published, read-only
//  `VernacularGraph` value type and the existing `SocialGraphResult`; it does
//  NOT touch the vernacular DATA layer or the social-graph build.
//

import SwiftUI

// MARK: - Palette (incoming = you absorbed · outgoing = spread from you)

/// Shared by the Vocabulary canvas, legend, and detail strip so the
/// blue/orange semantics are defined once.
enum VocabPalette {
    /// Slang you picked UP (they → you). A cool, "incoming" blue.
    static let incoming = Color.blue
    /// Slang that spread FROM you (you → them). A warm coral/orange.
    static let outgoing = Color.orange
    /// Bidirectional traders blend to a violet so the node reads "both".
    static let both = Color.purple

    static func color(for direction: VernacularGraph.Edge.Direction) -> Color {
        direction == .theyGaveYou ? incoming : outgoing
    }
}

// MARK: - Overlay model (the lens, resolved against the social layout)

/// A vernacular relationship resolved onto a social-graph node. Carries the
/// node id (so we can look up its screen position via the same transform) plus
/// the incoming/outgoing edges with their FULL term lists.
struct VocabTrader: Identifiable {
    let nodeID: String
    let displayName: String
    let incoming: VernacularGraph.Edge?      // they → you  (terms you picked up)
    let outgoing: VernacularGraph.Edge?      // you → them  (terms that spread)

    var id: String { nodeID }

    var incomingCount: Int { incoming?.terms.count ?? 0 }
    var outgoingCount: Int { outgoing?.terms.count ?? 0 }
    /// Total distinct terms traded — drives edge weight + ranking.
    var weight: Int { incomingCount + outgoingCount }
    var isBidirectional: Bool { incoming != nil && outgoing != nil }

    /// The disc tint for this trader's node.
    var tint: Color {
        if isBidirectional { return VocabPalette.both }
        return incoming != nil ? VocabPalette.incoming : VocabPalette.outgoing
    }
}

/// Resolves the `VernacularGraph` against the visible social `SocialGraph`,
/// producing the set of traders that map onto a visible node. Pure + cheap.
struct VocabularyOverlay {

    /// id → trader, for the nodes that have any vocab flow.
    let tradersByNodeID: [String: VocabTrader]
    /// How many vernacular relationships resolved onto a visible node.
    let matchedTraderCount: Int
    /// How many vernacular relationships existed in total (some may have been
    /// capped out of the visible social graph).
    let totalTraderCount: Int
    /// term label → the FULL set of visible node IDs that USE the term (everyone
    /// in the published per-term `users` roster who maps onto a visible node).
    /// This is the term's whole social footprint — a superset of the decisive
    /// source/adopter traders — and powers the light-up's NEUTRAL glow for users
    /// who aren't a source/adopter. Empty when no `users` rosters were supplied
    /// (e.g. preview/test paths), in which case the light-up keeps its prior
    /// source+adopter-only behavior. Keyed by the SAME label the cloud + graph
    /// `TermFlow.term` carry (a `VocabItem.token` / `SnowcloneTemplate.frame`).
    let usersByTerm: [String: Set<String>]
    /// Profile-spread decisive source/adopter rosters, resolved onto visible
    /// node IDs. These let the new spread chip bar light the same blue/orange
    /// roles even when the legacy graph's universe lacks that profile word.
    let spreadSourcesByTerm: [String: Set<String>]
    let spreadAdoptersByTerm: [String: Set<String>]

    init(vernacular: VernacularGraph, social: SocialGraph,
         words: [VocabItem] = [], templates: [SnowcloneTemplate] = [],
         spreadProfile: SpreadProfile? = nil) {
        // Build a name → nodeID index over the visible social nodes. We match
        // case-insensitively on the full display name first, then fall back to
        // first-name when that's unambiguous, so "Venkat" lines up with
        // "Venkat Reddy" if only one node starts with it.
        var byFullName: [String: String] = [:]          // lowercased name → id
        var byFirstName: [String: [String]] = [:]        // lowercased first → [id]
        for node in social.nodes where !node.isMe {
            let full = node.displayName.lowercased()
            byFullName[full] = node.id
            if let first = node.displayName
                .split(whereSeparator: { $0 == " " || $0 == "," }).first {
                byFirstName[String(first).lowercased(), default: []].append(node.id)
            }
        }

        // Group vernacular edges by person, keeping the full term list intact.
        let edgesByPerson = Dictionary(grouping: vernacular.edges, by: \.person)
        var traders: [String: VocabTrader] = [:]
        var total = 0
        for (person, edges) in edgesByPerson {
            total += 1
            guard let nodeID = Self.match(
                person: person, byFullName: byFullName, byFirstName: byFirstName
            ) else { continue }
            let incoming = edges.first { $0.direction == .theyGaveYou }
            let outgoing = edges.first { $0.direction == .youGaveThem }
            // Prefer the social node's display name for the label so it reads
            // consistently with the rest of the graph.
            let name = social.nodes.first { $0.id == nodeID }?.displayName ?? person
            traders[nodeID] = VocabTrader(
                nodeID: nodeID, displayName: name,
                incoming: incoming, outgoing: outgoing
            )
        }
        self.tradersByNodeID = traders
        self.matchedTraderCount = traders.count
        self.totalTraderCount = total

        // Resolve each universe item's per-term `users` roster onto visible nodes
        // using the SAME name match, so the canvas only ever deals in node IDs.
        var byTerm: [String: Set<String>] = [:]
        for w in words where !w.users.isEmpty {
            var ids = Set<String>()
            for u in w.users {
                if let id = Self.match(person: u.person, byFullName: byFullName,
                                       byFirstName: byFirstName) { ids.insert(id) }
            }
            if !ids.isEmpty { byTerm[w.token] = ids }
        }
        for t in templates where !t.users.isEmpty {
            var ids = byTerm[t.frame] ?? Set<String>()
            for u in t.users {
                if let id = Self.match(person: u.person, byFullName: byFullName,
                                       byFirstName: byFirstName) { ids.insert(id) }
            }
            if !ids.isEmpty { byTerm[t.frame] = ids }
        }
        var spreadSources: [String: Set<String>] = [:]
        var spreadAdopters: [String: Set<String>] = [:]
        if let spreadProfile {
            for term in spreadProfile.terms {
                let key = term.selectionKey
                if !term.users.isEmpty {
                    var ids = byTerm[key] ?? Set<String>()
                    for u in term.users {
                        if let id = Self.match(person: u, byFullName: byFullName,
                                               byFirstName: byFirstName) { ids.insert(id) }
                    }
                    if !ids.isEmpty { byTerm[key] = ids }
                }

                for source in term.sources {
                    if let id = Self.match(person: source, byFullName: byFullName,
                                           byFirstName: byFirstName) {
                        spreadSources[key, default: []].insert(id)
                    }
                }
                for adopter in term.adopters {
                    if let id = Self.match(person: adopter, byFullName: byFullName,
                                           byFirstName: byFirstName) {
                        spreadAdopters[key, default: []].insert(id)
                    }
                }
            }
        }
        self.usersByTerm = byTerm
        self.spreadSourcesByTerm = spreadSources
        self.spreadAdoptersByTerm = spreadAdopters
    }

    /// Match a vernacular person name to a visible node id, or nil.
    private static func match(
        person: String,
        byFullName: [String: String],
        byFirstName: [String: [String]]
    ) -> String? {
        let key = person.lowercased()
        if let exact = byFullName[key] { return exact }
        // First-name fallback only when unambiguous.
        if let first = person.split(whereSeparator: { $0 == " " || $0 == "," }).first {
            let candidates = byFirstName[String(first).lowercased()] ?? []
            if candidates.count == 1 { return candidates[0] }
        }
        return nil
    }

    var isEmpty: Bool {
        tradersByNodeID.isEmpty && usersByTerm.isEmpty
            && spreadSourcesByTerm.isEmpty && spreadAdoptersByTerm.isEmpty
    }
}

// MARK: - Canvas

/// The Vocabulary lens render. Mirrors `SocialGraphCanvas`'s interaction model
/// (pan / zoom / hover / tap-to-pin) and uses the identical `ScreenTransform`
/// so toggling modes keeps every node exactly where it was — only the edges +
/// emphasis change.
struct VocabularyGraphCanvas: View {

    let result: SocialGraphResult
    let overlay: VocabularyOverlay
    let pinnedInfluence: PersonInfluence?
    let onPersonSelected: (String) -> Void
    /// The SIGNATURE interaction: when a term is selected (from the cloud above
    /// the canvas), every person who traded it lights up — the source you GOT it
    /// from glows blue, the adopters who took it from YOU glow orange, everyone
    /// else dims back. Nil = the normal per-person lens (node hover/tap). Bound
    /// from `SocialGraphPanel` so the cloud + the canvas share one selection.
    @Binding var selectedTerm: String?

    @State private var zoom: CGFloat = 1.0
    @State private var committedZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var committedPan: CGSize = .zero
    @State private var hoveredID: String?
    @State private var pinnedID: String?
    /// Canvas size captured via `onGeometryChange` so the transform stays STABLE
    /// during scroll. A `GeometryReader` re-publishes its frame on EVERY scroll
    /// position change → re-evaluates the body → re-draws the whole Canvas every
    /// frame (measured: ViewUpdater×409 + Path×109 during scroll = the Vernacular
    /// scroll lag). This updates only when the size genuinely changes, so
    /// scrolling no longer touches the graph.
    @State private var canvasSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var graph: SocialGraph { result.graph }
    private var layout: GraphLayout { result.layout }
    private var meID: String? { graph.nodes.first(where: { $0.isMe })?.id }

    // MARK: - Term light-up roles (the signature interaction)

    /// The role a node plays for the currently-selected term.
    ///   • `.source`  — the decisive person you GOT the term from (blue).
    ///   • `.adopter` — a decisive adopter who took it FROM you (orange).
    ///   • `.user`    — anyone else who USES the term (a soft NEUTRAL glow); the
    ///     term's wider social footprint, from the published per-term roster.
    private enum TermRole { case source, adopter, user }

    /// nodeID → role for `selectedTerm`. The decisive trade edges assign `.source`
    /// (its `.theyGaveYou` edge carries the term, blue) and `.adopter` (its
    /// `.youGaveThem` edge carries the term, orange). Then EVERY other person in
    /// the term's published `users` roster (`overlay.usersByTerm`) who isn't
    /// already a source/adopter gets `.user` — the full set of people who use the
    /// term, lit with a neutral glow. Only TRUE non-users (no role) dim. Empty
    /// when no term is selected. Honest: source/adopter are the graph's decisive
    /// trades; `.user` is the per-sense roster the data layer publishes.
    private var termRoles: [String: TermRole] {
        guard let term = selectedTerm else { return [:] }
        var roles: [String: TermRole] = [:]
        for (nodeID, trader) in overlay.tradersByNodeID {
            if trader.incoming?.terms.contains(where: { $0.term == term }) == true {
                roles[nodeID] = .source
            } else if trader.outgoing?.terms.contains(where: { $0.term == term }) == true {
                roles[nodeID] = .adopter
            }
        }
        if let sourceIDs = overlay.spreadSourcesByTerm[term] {
            for id in sourceIDs { roles[id] = .source }
        }
        if let adopterIDs = overlay.spreadAdoptersByTerm[term] {
            for id in adopterIDs where roles[id] == nil { roles[id] = .adopter }
        }
        // Soft neutral glow for everyone else who USES the term (not already a
        // decisive source/adopter). Skips "You" / off-graph names by construction
        // (the overlay only stored visible, non-you node IDs).
        if let userIDs = overlay.usersByTerm[term] {
            for id in userIDs where roles[id] == nil { roles[id] = .user }
        }
        return roles
    }

    /// True while a term is lit up (drives the dim-everyone-else policy).
    private var isTermActive: Bool { selectedTerm != nil && !termRoles.isEmpty }

    /// Fill tint per role: source = incoming blue, adopter = outgoing orange,
    /// user = a calm neutral (so the glow reads as "also uses it" without
    /// claiming a trade direction).
    private func termTint(_ role: TermRole) -> Color {
        switch role {
        case .source: return VocabPalette.incoming
        case .adopter: return VocabPalette.outgoing
        case .user: return Color.secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                legend
                let transform = ScreenTransform(
                    layout: layout, canvas: canvasSize, zoom: zoom, pan: pan
                )
                ZStack {
                    Canvas { ctx, size in
                        guard canvasSize != .zero else { return }
                        drawComembership(ctx: ctx, transform: transform)
                        drawTradeEdges(ctx: ctx, transform: transform)
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
                    // ANYONE with enough history is tappable — not just the
                    // traders/term-lit nodes. The per-person inspector builds
                    // their vernacular lazily. "Enough history" = a real 1:1
                    // thread or at least one shared group.
                    if let hit = nearestNode(to: location, transform: transform),
                       !hit.isMe,
                       overlay.tradersByNodeID[hit.id] != nil
                           || termRoles[hit.id] != nil
                           || hit.directMessageCount >= 30
                           || hit.sharedGroupCount >= 1 {
                        let willPin = pinnedID != hit.id
                        withAnimation(reduceMotion ? nil : .bmGlassMorph) {
                            // A person selection and a word trace are mutually
                            // exclusive, keeping the center graph unambiguous.
                            selectedTerm = nil
                            pinnedID = willPin ? hit.id : nil
                        }
                        if willPin {
                            onPersonSelected(overlay.tradersByNodeID[hit.id]?.displayName
                                             ?? hit.displayName)
                        }
                    } else {
                        withAnimation(reduceMotion ? nil : .bmGlassMorph) {
                            pinnedID = nil
                            selectedTerm = nil
                        }
                    }
                }
                .animation(reduceMotion ? nil : .bmGlassMorph, value: selectedTerm)
                .overlay(alignment: .topLeading) { termBanner }
                .overlay(alignment: .bottomTrailing) { zoomControls }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self) { proxy in proxy.size } action: { newSize in
                    if canvasSize != newSize { canvasSize = newSize }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            // Person details now use the otherwise-empty right side instead of
            // compressing every section into a 128pt strip below the graph.
            detailRegion
                .frame(width: 310)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: selectedTerm) { _, term in
            if term != nil { pinnedID = nil }
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

    // MARK: - Edges: dimmed co-membership web (context)

    private func drawComembership(ctx: GraphicsContext, transform: ScreenTransform) {
        for edge in graph.edges where edge.kind == .coMembership {
            guard let p1 = transform.point(forNodeID: edge.a),
                  let p2 = transform.point(forNodeID: edge.b) else { continue }
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            // Dimmed way back — it's faint scaffolding under the trade flows.
            ctx.stroke(path, with: .color(Color.primary.opacity(0.05)), lineWidth: 0.6)
        }
    }

    // MARK: - Edges: directed term transmission (the point)

    private func drawTradeEdges(ctx: GraphicsContext, transform: ScreenTransform) {
        guard let meID, let center = transform.point(forNodeID: meID) else { return }

        // TERM LIGHT-UP takes over: draw ONLY the single directional edge that
        // carried the selected term to/from each DECISIVE trader, brightly; every
        // other trade edge is suppressed so the term's social path is the only
        // thing lit. The arrow direction encodes who got it from whom. A neutral
        // `.user` (uses the term, but no decisive trade) gets NO arrow — only its
        // node glows softly — so we never imply a trade that didn't happen.
        if isTermActive {
            for (nodeID, role) in termRoles {
                let direction: VernacularGraph.Edge.Direction
                switch role {
                case .source: direction = .theyGaveYou
                case .adopter: direction = .youGaveThem
                case .user: continue              // neutral glow only, no trade arrow
                }
                guard let p = transform.point(forNodeID: nodeID) else { continue }
                drawDirectedEdge(
                    ctx: ctx, center: center, node: p,
                    direction: direction, termCount: 1, active: true
                )
            }
            return
        }

        let active = hoveredID ?? pinnedID
        // Draw incoming (blue) and outgoing (orange) as separate bowed curves so
        // a bidirectional trader reads as two distinct arrows.
        for (nodeID, trader) in overlay.tradersByNodeID {
            guard let p = transform.point(forNodeID: nodeID) else { continue }
            let isActive = (active == nil) || (active == nodeID)
            if let inc = trader.incoming {
                drawDirectedEdge(
                    ctx: ctx, center: center, node: p,
                    direction: .theyGaveYou, termCount: inc.terms.count,
                    active: isActive
                )
            }
            if let out = trader.outgoing {
                drawDirectedEdge(
                    ctx: ctx, center: center, node: p,
                    direction: .youGaveThem, termCount: out.terms.count,
                    active: isActive
                )
            }
        }
    }

    /// One directed, bowed curve between You(center) and a trader, with an
    /// arrowhead pointing at the RECIPIENT of the terms.
    private func drawDirectedEdge(
        ctx: GraphicsContext, center: CGPoint, node: CGPoint,
        direction: VernacularGraph.Edge.Direction, termCount: Int, active: Bool
    ) {
        let color = VocabPalette.color(for: direction)
        // Bow incoming one way, outgoing the other, so the two never overlap.
        let bowSign: CGFloat = direction == .theyGaveYou ? 1 : -1
        let bow: CGFloat = 16

        let mid = CGPoint(x: (center.x + node.x) / 2, y: (center.y + node.y) / 2)
        let dx = node.x - center.x, dy = node.y - center.y
        let len = max(1, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len
        let ctrl = CGPoint(x: mid.x + nx * bow * bowSign, y: mid.y + ny * bow * bowSign)

        // Stop short of both discs so the curve meets the rim.
        let start = pointToward(from: center, toward: ctrl, by: 18)
        let end = pointToward(from: node, toward: ctrl, by: 12)

        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: ctrl)

        // Thickness ∝ term count (log-tempered so a 7-term edge isn't 7× a
        // 1-term edge but still reads heavier). The "spread feel" for outgoing
        // is preserved by a slightly fanned bow + a touch more weight.
        let w = 1.4 + 1.5 * log10(CGFloat(max(termCount, 1)) + 1)
        let lineWidth = min(max(w, 1.0), 6.0)
        let opacity = active ? 0.92 : 0.10
        ctx.stroke(
            path, with: .color(color.opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )

        // Arrowhead at the recipient: incoming → points at You (start); outgoing
        // → points at the person (end).
        let tip = direction == .theyGaveYou ? start : end
        drawArrowhead(
            ctx: ctx, at: tip, comingFrom: ctrl,
            color: color.opacity(active ? 0.95 : 0.16),
            size: 5 + min(4, CGFloat(termCount))
        )
    }

    private func drawArrowhead(
        ctx: GraphicsContext, at tip: CGPoint, comingFrom from: CGPoint,
        color: Color, size: CGFloat
    ) {
        let ang = atan2(tip.y - from.y, tip.x - from.x)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: tip.x - size * cos(ang - spread), y: tip.y - size * sin(ang - spread))
        let p2 = CGPoint(x: tip.x - size * cos(ang + spread), y: tip.y - size * sin(ang + spread))
        var head = Path()
        head.move(to: tip); head.addLine(to: p1); head.addLine(to: p2); head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }

    // MARK: - Nodes

    private func drawNodes(ctx: GraphicsContext, transform: ScreenTransform, size: CGSize) {
        let active = hoveredID ?? pinnedID
        let termActive = isTermActive
        let roles = termActive ? termRoles : [:]

        for node in graph.nodes {
            guard let p = transform.point(forNodeID: node.id) else { continue }
            let role = roles[node.id]
            // The decisive source/adopter are the "loud" hits — they scale up a
            // touch so the light-up reads as a physical "brighten + grow". A
            // neutral `.user` glows softly in place (no grow), so it reads as
            // "also uses it" without competing with the trade direction.
            let isLoudRole = role == .source || role == .adopter
            let baseR = nodeRadius(node)
            let r = (termActive && isLoudRole && !node.isMe) ? baseR + 2.5 : baseR
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)

            let trader = overlay.tradersByNodeID[node.id]
            let isTrader = trader != nil
            let isActive = (node.id == active)

            // Color policy. In TERM mode: the term's source glows blue, its
            // adopters orange, You stays the center accent, everyone else fades
            // to faint grey context. Otherwise the standard per-person lens:
            // traders take their direction tint, others are dimmed grey.
            let fill: Color
            if node.isMe {
                fill = CommunityPalette.centerColor
            } else if termActive {
                fill = role.map(termTint) ?? Color.secondary
            } else if let trader {
                fill = trader.tint
            } else {
                fill = Color.secondary
            }

            // Dim policy. In term mode: source/adopter are full-bright, a neutral
            // `.user` glows softly (clearly lit but secondary to the trade), and
            // only TRUE non-users fade right back.
            let dim: Double
            if node.isMe {
                dim = 1.0
            } else if termActive {
                switch role {
                case .source, .adopter: dim = 1.0
                case .user: dim = 0.5            // soft neutral glow — "also uses it"
                case nil: dim = 0.10             // true non-users fade right back
                }
            } else if isTrader {
                dim = (active == nil || isActive) ? 1.0 : 0.5
            } else {
                dim = 0.22
            }

            // Halo for center + the term's loud (source/adopter) people + the
            // (non-term) active trader. A neutral `.user` gets a fainter halo so
            // it's lit but doesn't compete with the decisive hits.
            let haloed = node.isMe || (termActive ? role != nil : (isTrader && isActive))
            if haloed {
                let isSoftUser = termActive && role == .user
                let haloBump: CGFloat = node.isMe ? 6 : (isSoftUser ? 3 : (termActive ? 6 : 4))
                let haloR = r + haloBump
                let haloRect = CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)
                let haloOpacity = isSoftUser ? 0.12 : (termActive && !node.isMe ? 0.26 : 0.18)
                ctx.fill(Circle().path(in: haloRect), with: .color(fill.opacity(haloOpacity)))
            }

            ctx.fill(Circle().path(in: rect), with: .color(fill.opacity(dim)))
            // Loud term-people + traders + You get a crisp rim; a neutral `.user`
            // gets a soft rim; faded context is barely outlined.
            let rimOpacity: Double
            if node.isMe || (termActive ? isLoudRole : isTrader) {
                rimOpacity = 0.55
            } else if termActive && role == .user {
                rimOpacity = 0.30
            } else {
                rimOpacity = 0.12
            }
            ctx.stroke(
                Circle().path(in: rect),
                with: .color(Color.white.opacity(rimOpacity)),
                lineWidth: node.isMe ? 2 : 1
            )

            // Labels. EVERY node gets a name (0.3.1 — clicking someone you
            // can't identify is useless; the gray context people are exactly
            // the ones you might want to open). Emphasis still distinguishes:
            // You bold, traders/term-people normal, faded context dimmed.
            // The hover/tap active node draws its label in the overlay layer.
            let shouldLabel = !(isActive && !termActive)
            if shouldLabel {
                drawLabel(
                    ctx: ctx, text: node.displayName, at: p, radius: r,
                    emphasized: node.isMe,
                    dimmed: termActive ? (role == nil && !node.isMe) : (dim < 0.9 || (!isTrader && !node.isMe))
                )
            }
        }
    }

    private func drawLabel(
        ctx: GraphicsContext, text: String, at p: CGPoint, radius: CGFloat,
        emphasized: Bool, dimmed: Bool
    ) {
        let resolved = ctx.resolve(
            Text(shortLabel(text))
                .font(emphasized ? .caption.weight(.semibold) : .caption2.weight(.medium))
                .foregroundStyle(emphasized ? Color.primary : (dimmed ? Color.tertiaryLabelColor : Color.secondary))
        )
        let textSize = resolved.measure(in: CGSize(width: 120, height: 40))
        let origin = CGPoint(x: p.x - textSize.width / 2, y: p.y + radius + 2)
        ctx.draw(resolved, in: CGRect(origin: origin, size: textSize))
    }

    // MARK: - Active-node label overlay

    @ViewBuilder
    private func labelOverlay(transform: ScreenTransform) -> some View {
        let activeID = hoveredID ?? pinnedID
        if let activeID, let node = node(activeID), let p = transform.point(forNodeID: activeID),
           let trader = overlay.tradersByNodeID[activeID] {
            let r = nodeRadius(node)
            VStack(spacing: 1) {
                Text(node.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(traderSummary(trader))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private func traderSummary(_ t: VocabTrader) -> String {
        var parts: [String] = []
        let first = t.displayName.split(separator: " ").first.map(String.init) ?? t.displayName
        if t.incomingCount > 0 { parts.append("\(t.incomingCount) from \(first)") }
        if t.outgoingCount > 0 { parts.append("\(t.outgoingCount) from you") }
        return parts.joined(separator: " · ") + " · click for details"
    }

    // MARK: - Right-side inspector (selected person's FULL term list)

    /// Driven by `pinnedID` ONLY (an explicit click). Hover just highlights the
    /// graph. The fixed-width inspector keeps graph geometry stable while its
    /// vertical scroll finally leaves enough room for both people's word lists.
    @ViewBuilder
    private var detailRegion: some View {
        if let id = pinnedID {
            ScrollView(.vertical) {
                if let trader = overlay.tradersByNodeID[id],
                   let influence = pinnedInfluence,
                   influence.person.caseInsensitiveCompare(trader.displayName) == .orderedSame {
                    VocabPersonPanel(influence: influence, trader: trader)
                } else if let trader = overlay.tradersByNodeID[id] {
                    // The quick trade data renders immediately; the person's
                    // full vocabulary profile is still building. Say so —
                    // without the banner this read as a broken half-panel
                    // that silently mutated seconds later.
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Reading \(trader.displayName.split(separator: " ").first.map(String.init) ?? trader.displayName)'s messages — their words land here in a moment…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VocabTraderDetail(trader: trader)
                    }
                } else if let name = node(id)?.displayName,
                          let influence = pinnedInfluence,
                          influence.person.caseInsensitiveCompare(name) == .orderedSame {
                    VocabPersonPanel(influence: influence, trader: nil)
                } else {
                    VocabPersonLoadingPanel(name: node(id)?.displayName ?? "Person")
                }
            }
            .scrollIndicators(.visible)
            .transition(reduceMotion ? .opacity
                        : .asymmetric(insertion: .opacity, removal: .opacity))
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Person details", systemImage: "person.text.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Choose someone in the graph to compare the words they use with the words that moved between you.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(Space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1))
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Space.md) {
            VocabLegendSwatch(color: VocabPalette.incoming, glyph: "arrow.down.left",
                              text: "they used it before you")
            VocabLegendSwatch(color: VocabPalette.outgoing, glyph: "arrow.up.right",
                              text: "you used it before them")
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    // MARK: - Term light-up banner (clear affordance)

    /// A small pill, top-left of the canvas, naming the lit term and how many
    /// people it touched, with an ✕ to clear. Only present while a term is lit.
    @ViewBuilder
    private var termBanner: some View {
        if let term = selectedTerm, !termRoles.isEmpty {
            let sources = termRoles.values.filter { $0 == .source }.count
            let adopters = termRoles.values.filter { $0 == .adopter }.count
            let users = termRoles.values.filter { $0 == .user }.count
            Button {
                withAnimation(reduceMotion ? nil : .bmGlassMorph) { selectedTerm = nil }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    Text("“\(SenseLabel(raw: term).surface)”")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(lightUpSummary(sources: sources, adopters: adopters, users: users))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
            .padding(Space.sm)
            .help("Clear — show every trade again")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func lightUpSummary(sources: Int, adopters: Int, users: Int) -> String {
        // The trade story (caught / spread) leads; the wider "+N also use it"
        // footprint (the neutral glow) is appended when present.
        let trade: String
        switch (sources, adopters) {
        case (1, 0): trade = "· where you caught it"
        case (0, let a) where a > 0: trade = "· spread to \(a)"
        case (1, let a) where a > 0: trade = "· caught + spread to \(a)"
        default: trade = ""
        }
        guard users > 0 else { return trade }
        let also = "· +\(users) also use it"
        return trade.isEmpty ? also : "\(trade) \(also)"
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

    private func node(_ id: String) -> GraphNode? { graph.nodes.first { $0.id == id } }

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

    private func pointToward(from origin: CGPoint, toward: CGPoint, by radius: CGFloat) -> CGPoint {
        let dx = toward.x - origin.x, dy = toward.y - origin.y
        let len = max(1, hypot(dx, dy))
        return CGPoint(x: origin.x + dx / len * radius, y: origin.y + dy / len * radius)
    }
}

// MARK: - Detail strip

/// Lists the FULL term list for a selected trader, grouped into "you picked up"
/// (blue) and "spread from you" (orange). Each row shows the term (phrases read
/// larger), the before-count, the date, and the real example message.
private struct VocabTraderDetail: View {
    let trader: VocabTrader

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
            if let inc = trader.incoming {
                VocabTermBlock(edge: inc, personName: trader.displayName)
            }
            if let out = trader.outgoing {
                VocabTermBlock(edge: out, personName: trader.displayName)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            ZStack {
                Circle().fill(trader.tint.gradient.opacity(0.9))
                Text(initials).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(trader.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(summaryLine).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if trader.incomingCount > 0 {
            parts.append("\(trader.incomingCount) from \(shortName)")
        }
        if trader.outgoingCount > 0 {
            parts.append("\(trader.outgoingCount) from you")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var shortName: String {
        trader.displayName.split(separator: " ").first.map(String.init) ?? trader.displayName
    }

    private var initials: String {
        let comps = trader.displayName.split(separator: " ")
        let first = comps.first?.first.map(String.init) ?? ""
        let last = comps.count > 1 ? comps.last?.first.map(String.init) ?? "" : ""
        return (first + last).uppercased()
    }
}

private struct VocabPersonLoadingPanel: View {
    let name: String

    var body: some View {
        HStack(spacing: Space.sm) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Building their word-spread profile")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }
}

/// Profile-backed person panel shown after a graph-node click once the lazy
/// influence payload is ready. It keeps the old trader detail as fallback while
/// loading; this view is only the richer replacement data strip.
private struct VocabPersonPanel: View {
    let influence: PersonInfluence
    /// The graph edge is the exact result shown while the richer person profile
    /// loads. Keep it as an input so those rows cannot disappear at handoff.
    let trader: VocabTrader?

    @State private var showsAllWords = false
    private let compactLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header

            if wordRows.isEmpty {
                Text("No strong word patterns yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Space.sm)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Word map")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: Space.xs)
                        Text("traded first · strongest first")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(visibleRows) { row in
                        PersonWordRowView(
                            row: row,
                            shortName: shortName,
                            maximumStrength: maximumStrength
                        )
                    }

                    if hiddenWordCount > 0 || showsAllWords {
                        Button {
                            withAnimation(.bmDefault) { showsAllWords.toggle() }
                        } label: {
                            HStack(spacing: Space.xs) {
                                Image(systemName: showsAllWords ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                Text(showsAllWords ? "Show top \(compactLimit)" : "Show \(hiddenWordCount) more")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            ZStack {
                Circle().fill(Color.accentColor.gradient.opacity(0.9))
                Text(initials).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(influence.person)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(headerSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var visibleRows: [PersonWordRow] {
        showsAllWords ? wordRows : Array(wordRows.prefix(compactLimit))
    }

    private var hiddenWordCount: Int {
        showsAllWords ? 0 : max(0, wordRows.count - compactLimit)
    }

    private var maximumStrength: Int {
        max(wordRows.map(\.strength).max() ?? 1, 1)
    }

    private var headerSummary: String {
        guard let trader else { return "\(wordRows.count) words" }
        var parts: [String] = []
        if trader.incomingCount > 0 {
            parts.append("\(trader.incomingCount) from \(shortName)")
        }
        if trader.outgoingCount > 0 {
            parts.append("\(trader.outgoingCount) from you")
        }
        return parts.joined(separator: " · ")
    }

    /// One deduplicated list replaces four stacked category lists. A term that is
    /// both part of the person's idiolect and part of a detected exchange appears
    /// once; the exchange relationship wins the badge and keeps its earlier-use
    /// evidence, while the person's total-use count remains available for terms
    /// that are only part of their broader vocabulary.
    private var wordRows: [PersonWordRow] {
        var bySurface: [String: PersonWordRow] = [:]

        for ref in influence.theirIdiolect {
            let key = normalized(ref.surface)
            guard !key.isEmpty else { continue }
            if var existing = bySurface[key] {
                existing.personUses = max(existing.personUses ?? 0, ref.count)
                existing.strength = max(existing.strength, ref.count)
                existing.example = existing.example ?? ref.example
                existing.isReclaimed = existing.isReclaimed || ref.kind == .reclaimed
                bySurface[key] = existing
            } else {
                bySurface[key] = PersonWordRow(
                    id: key,
                    surface: ref.surface,
                    relationship: .theirs,
                    strength: ref.count,
                    personUses: ref.count,
                    earlierUses: nil,
                    lagDays: nil,
                    example: ref.example,
                    senseTag: nil,
                    isReclaimed: ref.kind == .reclaimed
                )
            }
        }

        merge(influence.independentCoUse, as: .shared, into: &bySurface)
        merge(influence.theyToYou, as: .fromThem, into: &bySurface)
        merge(influence.youToThem, as: .fromYou, into: &bySurface)

        // `PersonInfluence` is a wider, independently-ranked analysis. Merge the
        // exact graph terms shown in VocabTraderDetail last so the completed
        // panel is a true superset of its loading state rather than a replacement.
        merge(trader?.incoming, as: .fromThem, into: &bySurface)
        merge(trader?.outgoing, as: .fromYou, into: &bySurface)

        return bySurface.values.sorted {
            if $0.relationship.isTraded != $1.relationship.isTraded {
                return $0.relationship.isTraded
            }
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            if $0.relationship.sortPriority != $1.relationship.sortPriority {
                return $0.relationship.sortPriority < $1.relationship.sortPriority
            }
            return $0.surface.localizedCaseInsensitiveCompare($1.surface) == .orderedAscending
        }
    }

    private func merge(
        _ terms: [InfluencedTerm],
        as relationship: PersonWordRelationship,
        into rows: inout [String: PersonWordRow]
    ) {
        for term in terms {
            let key = normalized(term.surface)
            guard !key.isEmpty else { continue }
            if var existing = rows[key] {
                existing.relationship = relationship
                existing.earlierUses = max(existing.earlierUses ?? 0, term.headstart)
                existing.strength = existing.earlierUses ?? term.headstart
                existing.lagDays = existing.lagDays ?? term.lagDays
                existing.example = existing.example ?? term.example
                existing.senseTag = existing.senseTag ?? term.senseTag
                rows[key] = existing
            } else {
                rows[key] = PersonWordRow(
                    id: key,
                    surface: term.surface,
                    relationship: relationship,
                    strength: term.headstart,
                    personUses: nil,
                    earlierUses: term.headstart,
                    lagDays: term.lagDays,
                    example: term.example,
                    senseTag: term.senseTag,
                    isReclaimed: false
                )
            }
        }
    }

    private func merge(
        _ edge: VernacularGraph.Edge?,
        as relationship: PersonWordRelationship,
        into rows: inout [String: PersonWordRow]
    ) {
        guard let edge else { return }
        for term in edge.terms {
            let isVocative = term.term.hasPrefix("voc:")
            let surface = isVocative ? String(term.term.dropFirst(4)) : term.term
            let key = normalized(surface)
            guard !key.isEmpty else { continue }
            let lagDays = Int(abs(term.yourFirstUse.timeIntervalSince(term.theirFirstUse)) / 86_400)
            if var existing = rows[key] {
                existing.relationship = relationship
                existing.earlierUses = max(existing.earlierUses ?? 0, term.count)
                existing.strength = existing.earlierUses ?? term.count
                existing.lagDays = existing.lagDays ?? lagDays
                existing.example = term.example ?? existing.example
                if isVocative { existing.senseTag = "as address" }
                rows[key] = existing
            } else {
                rows[key] = PersonWordRow(
                    id: key,
                    surface: surface,
                    relationship: relationship,
                    strength: term.count,
                    personUses: nil,
                    earlierUses: term.count,
                    lagDays: lagDays,
                    example: term.example,
                    senseTag: isVocative ? "as address" : nil,
                    isReclaimed: false
                )
            }
        }
    }

    private func normalized(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var shortName: String {
        influence.person.split(separator: " ").first.map(String.init) ?? influence.person
    }

    private var initials: String {
        let comps = influence.person.split(separator: " ")
        let first = comps.first?.first.map(String.init) ?? ""
        let last = comps.count > 1 ? comps.last?.first.map(String.init) ?? "" : ""
        return (first + last).uppercased()
    }
}

private enum PersonWordRelationship: Int, Equatable {
    case fromThem
    case fromYou
    case shared
    case theirs

    var sortPriority: Int { rawValue }
    var isTraded: Bool { self != .theirs }

    var color: Color {
        switch self {
        case .fromThem: return VocabPalette.incoming
        case .fromYou: return VocabPalette.outgoing
        case .shared: return .secondary
        case .theirs: return .yellow
        }
    }

    var glyph: String {
        switch self {
        case .fromThem: return "arrow.down.left"
        case .fromYou: return "arrow.up.right"
        case .shared: return "circle.lefthalf.filled"
        case .theirs: return "person.fill"
        }
    }

    func label(shortName: String) -> String {
        switch self {
        case .fromThem: return "from \(shortName)"
        case .fromYou: return "from you"
        case .shared: return "both"
        case .theirs: return "\(shortName)'s"
        }
    }
}

private struct PersonWordRow: Identifiable {
    let id: String
    let surface: String
    var relationship: PersonWordRelationship
    var strength: Int
    var personUses: Int?
    var earlierUses: Int?
    var lagDays: Int?
    var example: String?
    var senseTag: String?
    var isReclaimed: Bool
}

private struct PersonWordRowView: View {
    let row: PersonWordRow
    let shortName: String
    let maximumStrength: Int

    private var tint: Color { row.relationship.color }
    private var frequencyFraction: CGFloat {
        guard row.strength > 0, maximumStrength > 0 else { return 0 }
        return CGFloat(log(Double(row.strength) + 1) / log(Double(maximumStrength) + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(row.surface)
                    .font(.system(size: 11, weight: row.isReclaimed ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let senseTag = row.senseTag, !senseTag.isEmpty {
                    Text(senseTag)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.13)))
                }
                Spacer(minLength: 4)
                Text(countLabel)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }

            HStack(spacing: 4) {
                Image(systemName: row.relationship.glyph)
                    .font(.system(size: 8, weight: .bold))
                Text(row.relationship.label(shortName: shortName))
                    .font(.system(size: 9, weight: .medium))
                if let lag = row.lagDays, row.relationship == .fromThem || row.relationship == .fromYou {
                    Text("· \(abs(lag))d lead")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(tint)

            GeometryReader { proxy in
                Capsule()
                    .fill(tint.opacity(0.42))
                    .frame(width: max(6, proxy.size.width * frequencyFraction))
            }
            .frame(height: 2)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(tint.opacity(0.055)))
        .help(helpText)
    }

    private var countLabel: String {
        if row.relationship == .shared, let earlierUses = row.earlierUses {
            return "≥\(earlierUses) each"
        }
        if row.relationship.isTraded, let earlierUses = row.earlierUses {
            return "\(earlierUses) earlier"
        }
        if let personUses = row.personUses { return "\(personUses.formatted()) uses" }
        return "\(row.strength.formatted()) uses"
    }

    private var helpText: String {
        var parts = [row.relationship.label(shortName: shortName), countLabel]
        if let example = row.example, !example.isEmpty { parts.append("“\(example)”") }
        return parts.joined(separator: " · ")
    }
}

/// One directional block of traded terms — shows ALL terms on the edge (no
/// truncation; an edge carrying 7 terms lists all 7).
private struct VocabTermBlock: View {
    let edge: VernacularGraph.Edge
    let personName: String

    private var color: Color { VocabPalette.color(for: edge.direction) }
    private var isIncoming: Bool { edge.direction == .theyGaveYou }
    private var shortName: String {
        personName.split(separator: " ").first.map(String.init) ?? personName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: isIncoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                Text(isIncoming ? "\(shortName) → you" : "you → \(shortName)")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(color)

            ForEach(Array(edge.terms.enumerated()), id: \.offset) { _, term in
                VocabTermRow(term: term, color: color, isIncoming: isIncoming, personName: shortName)
            }
        }
    }
}

/// A single traded-term row.
private struct VocabTermRow: View {
    let term: VernacularGraph.TermFlow
    let color: Color
    let isIncoming: Bool
    let personName: String

    /// Sense-namespaced ids ("voc:brother" = the vocative sense) read as the
    /// bare word plus a sense chip — the raw id is an internal key.
    private var displayTerm: String {
        term.term.hasPrefix("voc:") ? String(term.term.dropFirst(4)) : term.term
    }
    private var senseTag: String? {
        term.term.hasPrefix("voc:") ? "as address" : nil
    }

    private var wordCount: Int { max(1, displayTerm.split(separator: " ").count) }
    private var isPhrase: Bool { wordCount >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: isIncoming ? "arrowshape.left.fill" : "arrowshape.right.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(color.opacity(0.8))
                Text("“\(displayTerm)”")
                    .font(.system(size: isPhrase ? 14 : 12, weight: isPhrase ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let senseTag {
                    Text(senseTag)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.14)))
                } else if isPhrase {
                    Text("phrase")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.14)))
                }
                Spacer(minLength: Space.sm)
                Text(countLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Space.xs) {
                Text(dateLabel).font(.system(size: 9)).foregroundStyle(.tertiary)
                if let ex = term.example, !ex.isEmpty {
                    Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text("“\(ex)”")
                        .font(.system(size: 9)).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(color.opacity(0.05)))
    }

    private var countLabel: String {
        "\(term.count) earlier uses"
    }

    private var dateLabel: String {
        let date = isIncoming ? term.theirFirstUse : term.yourFirstUse
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}

// MARK: - Legend swatch

private struct VocabLegendSwatch: View {
    let color: Color
    let glyph: String
    let text: String
    var body: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                Capsule().fill(color.opacity(0.9)).frame(width: 16, height: 3)
                Image(systemName: glyph)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(color)
                    .offset(x: 9)
            }
            .frame(width: 26)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Color helper

private extension Color {
    /// A tertiary-label grey for dimmed labels in the Canvas (Canvas can't use
    /// the `.tertiary` hierarchical style, so we resolve a concrete color).
    static var tertiaryLabelColor: Color { Color(nsColor: .tertiaryLabelColor) }
}
