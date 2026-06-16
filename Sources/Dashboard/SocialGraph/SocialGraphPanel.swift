//
//  SocialGraphPanel.swift
//  Hourglass — Dashboard / Social Graph
//
//  The entry-point dashboard panel: a node-link visualization of who-talks-
//  to-who across the user's conversations, centered on the user, with their
//  distinct social *circles* surfaced via community detection + per-circle
//  color.
//
//  ENTRY POINT (what lead wires into DashboardView)
//  ================================================
//      SocialGraphPanel(database: ChatDatabase, contacts: ResolvedContacts)
//
//  Both come straight from `DashboardViewModel` (which already opens chat.db
//  + resolves contacts once). The panel owns its own `SocialGraphViewModel`
//  and kicks the off-main build on `.task`. No other state required.
//
//  STRUCTURE
//  =========
//    StatPanel(title: "Your circles")                       ← solid + hairline
//      ├─ view-mode Picker:  Graph  |  Circles  |  Vocabulary
//      ├─ SocialGraphCanvas (force-directed) — the primary view
//      │     • center = you, spokes = 1:1 volume, web = shared group chats
//      │     • nodes colored + clustered by community
//      │     • drag to pan, scroll/pinch to zoom, hover/tap to label
//      ├─ CirclesView (alternate) — communities as packed clusters
//      ├─ VocabularyGraphCanvas (Vocabulary lens) — SAME layout, but the
//      │     co-membership web dims back and directed term-transmission edges
//      │     (blue = you picked up · orange = spread from you) are drawn from
//      │     You to the people you traded vocab with. Driven by the published
//      │     `VernacularGraph` passed in via `vernacularGraph`. Only offered
//      │     when that graph is non-empty.
//      └─ legend + "showing top N of M people" footnote
//

import SwiftUI

public struct SocialGraphPanel: View {

    private let database: ChatDatabase?
    private let contacts: ResolvedContacts?

    /// The published vernacular trade graph, fed in by the Vernacular page so
    /// the Vocabulary lens has its directed term-transmission data. Nil/empty
    /// while the (separate, slower) vernacular analysis is still running — the
    /// Vocabulary mode only appears in the picker once it's available, so the
    /// graph never shows an empty lens.
    private let vernacularGraph: VernacularGraph?

    /// The published vernacular universe (anomalous words ∪ snowclone frames),
    /// each carrying its per-term `users` roster. Fed in alongside the graph so
    /// the Vocabulary lens's term light-up can give a NEUTRAL glow to EVERYONE
    /// who uses a term — not just the decisive source/adopter the graph records.
    /// Empty until the analysis publishes; an empty roster simply keeps the prior
    /// source+adopter-only light-up.
    private let vernacularWords: [VocabItem]
    private let vernacularTemplates: [SnowcloneTemplate]
    /// Live analysis-stage line for the Vocabulary lens's loading state, fed in by
    /// the Vernacular page from the SAME `VernacularViewModel.phase` that drives
    /// the words section — so both surfaces advance their copy in lockstep. Nil
    /// before the first stage reports; the loading state then shows its default.
    private let vernacularLoadingMessage: String?
    private let spreadProfile: SpreadProfile?
    private let pinnedInfluence: PersonInfluence?
    private let onPersonInfluence: (String) -> Void

    /// The published dialect/vibe clusters, fed in by the Vernacular page so the
    /// Vibe lens can recolor the graph by HOW people text. Nil/empty until the
    /// (separate, slower) vibe clustering completes — the Vibe mode only appears
    /// in the picker once it's available.
    private let vibeClusters: [VibeCluster]?
    /// Display-name → cluster-id lookup (incl. "You"), keyed by the same string
    /// `GraphNode.displayName` carries. Drives the Vibe lens recoloring.
    private let vibeClusterByContact: [String: Int]?

    @State private var viewModel: SocialGraphViewModel
    @State private var mode: ViewMode = .circles
    /// The SIGNATURE interaction's shared selection: the term currently lit up
    /// across the Vocabulary lens (picked from the term cloud above the canvas).
    /// Lives here so the cloud and the canvas stay in sync. Cleared whenever we
    /// leave the Vocabulary lens.
    @State private var selectedVocabTerm: String?

    // 0.3.1: two lenses only. "Circles" IS the force graph (the old separate
    // cluster view and the Vibe lens were cut — neither earned its tab).
    enum ViewMode: String, CaseIterable, Identifiable {
        case circles = "Circles"
        case vocabulary = "Vocabulary"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .circles: return "point.3.connected.trianglepath.dotted"
            case .vocabulary: return "quote.bubble"
            }
        }
    }

    /// Primary init — lead passes the dashboard's open handle + contacts, plus
    /// (optionally) the vernacular trade graph for the Vocabulary lens and the
    /// dialect clusters for the Vibe lens.
    public init(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        vernacularGraph: VernacularGraph? = nil,
        vernacularWords: [VocabItem] = [],
        vernacularTemplates: [SnowcloneTemplate] = [],
        vernacularLoadingMessage: String? = nil,
        spreadProfile: SpreadProfile? = nil,
        pinnedInfluence: PersonInfluence? = nil,
        onPersonInfluence: @escaping (String) -> Void = { _ in },
        vibeClusters: [VibeCluster]? = nil,
        vibeClusterByContact: [String: Int]? = nil,
        nodeCap: Int = SocialGraphBuilder.defaultNodeCap
    ) {
        self.database = database
        self.contacts = contacts
        self.vernacularGraph = vernacularGraph
        self.vernacularWords = vernacularWords
        self.vernacularTemplates = vernacularTemplates
        self.vernacularLoadingMessage = vernacularLoadingMessage
        self.spreadProfile = spreadProfile
        self.pinnedInfluence = pinnedInfluence
        self.onPersonInfluence = onPersonInfluence
        self.vibeClusters = vibeClusters
        self.vibeClusterByContact = vibeClusterByContact
        _viewModel = State(initialValue: SocialGraphViewModel(nodeCap: nodeCap))
    }

    /// Preview / test init — inject a prebuilt view model (e.g. seeded with
    /// `setResultForPreview`). No DB handle; the panel renders whatever the
    /// view model already has.
    init(
        previewModel: SocialGraphViewModel,
        vernacularGraph: VernacularGraph? = nil,
        vernacularWords: [VocabItem] = [],
        vernacularTemplates: [SnowcloneTemplate] = [],
        vernacularLoadingMessage: String? = nil,
        spreadProfile: SpreadProfile? = nil,
        pinnedInfluence: PersonInfluence? = nil,
        onPersonInfluence: @escaping (String) -> Void = { _ in },
        vibeClusters: [VibeCluster]? = nil,
        vibeClusterByContact: [String: Int]? = nil
    ) {
        self.database = nil
        self.contacts = nil
        self.vernacularGraph = vernacularGraph
        self.vernacularWords = vernacularWords
        self.vernacularTemplates = vernacularTemplates
        self.vernacularLoadingMessage = vernacularLoadingMessage
        self.spreadProfile = spreadProfile
        self.pinnedInfluence = pinnedInfluence
        self.onPersonInfluence = onPersonInfluence
        self.vibeClusters = vibeClusters
        self.vibeClusterByContact = vibeClusterByContact
        _viewModel = State(initialValue: previewModel)
    }

    public var body: some View {
        StatPanel(
            title: "Your circles",
            subtitle: subtitle,
            accessory: {
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                } else if viewModel.result != nil {
                    Picker("View", selection: $mode) {
                        ForEach(availableModes) { m in
                            Label(m.rawValue, systemImage: m.icon).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            },
            content: {
                content
            }
        )
        .task {
            // Kick the build once when the panel first appears, using the
            // dashboard's handle. Preview models already have a result.
            if viewModel.result == nil, !viewModel.isLoading,
               let database, let contacts {
                viewModel.load(database: database, contacts: contacts)
            }
        }
        // If a lens's data arrives/leaves while the panel is up, keep the
        // selected mode valid — never strand the picker on a lens with no data.
        .onChange(of: hasVocabulary) { _, hasVocab in
            if !hasVocab, mode == .vocabulary { mode = .circles }
        }
        // Leaving the Vocabulary lens clears any lit-up term so it doesn't
        // linger when the user comes back via another mode.
        .onChange(of: mode) { _, newMode in
            if newMode != .vocabulary { selectedVocabTerm = nil }
        }
    }

    /// True once the vernacular trade graph is available + non-empty — the gate
    /// for offering the Vocabulary lens.
    private var hasVocabulary: Bool {
        if let g = vernacularGraph, !g.isEmpty { return true }
        return spreadProfile?.isEmpty == false
    }

    private var effectiveVernacularGraph: VernacularGraph {
        if let g = vernacularGraph, !g.isEmpty { return g }
        return spreadProfile?.graph ?? .empty
    }

    /// Modes offered in the picker. Vocabulary appears WITH a loading state
    /// before its data is in (0.3.1: the lens used to pop in silently when
    /// the vernacular build finished — now the tab is always there and shows
    /// progress instead).
    private var availableModes: [ViewMode] {
        [.circles, .vocabulary]
    }

    private var subtitle: String {
        if mode == .vocabulary {
            if !hasVocabulary {
                return "Finding the words you trade — this takes a couple of minutes on first open"
            }
            return "The slang you traded — blue came in to you, orange spread out from you"
        }
        if let result = viewModel.result {
            let circles = result.graph.communityCount
            let shown = result.graph.nodes.count - 1 // minus center
            let total = result.graph.totalContactsConsidered
            var parts: [String] = []
            if circles > 0 {
                parts.append("\(circles) circle\(circles == 1 ? "" : "s")")
            }
            if total > shown {
                parts.append("top \(shown) of \(total) people")
            } else {
                parts.append("\(shown) people")
            }
            return parts.joined(separator: " · ")
        }
        return "Who you talk to, and the circles they form"
    }

    @ViewBuilder
    private var content: some View {
        if let message = viewModel.errorMessage {
            errorState(message)
        } else if let result = viewModel.result, !result.graph.nodes.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                Group {
                    switch mode {
                    case .circles:
                        SocialGraphCanvas(result: result)
                    case .vocabulary:
                        if hasVocabulary {
                            vocabularyContent(result: result)
                        } else {
                            vocabularyLoadingState
                        }
                    }
                }
                // The Vocabulary lens stacks a term cloud above the canvas, so
                // it gets extra room — the graph itself stays as generous as the
                // other modes' 460pt.
                .frame(height: mode == .vocabulary ? 560 : 460)
                .frame(maxWidth: .infinity)

                // The community legend names circles by their biggest member —
                // meaningful in Circles. The Vocabulary lens recolors nodes by
                // trade direction and draws its OWN legend inside the canvas.
                if mode != .vocabulary {
                    legend(for: result.graph)
                }
            }
        } else if viewModel.isLoading {
            loadingState
        } else {
            emptyState
        }
    }

    /// The Vocabulary lens. Resolves the vernacular trade graph against the
    /// visible social layout; if nothing maps onto a visible node (e.g. all the
    /// traders were capped out) it shows a graceful note instead of an empty
    /// canvas.
    @ViewBuilder
    private func vocabularyContent(result: SocialGraphResult) -> some View {
        let vern = effectiveVernacularGraph
        if !vern.isEmpty || spreadProfile?.isEmpty == false {
            let overlay = VocabularyOverlay(
                vernacular: vern, social: result.graph,
                words: vernacularWords, templates: vernacularTemplates,
                spreadProfile: spreadProfile
            )
            if overlay.isEmpty {
                vocabularyEmptyState
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    // The term cloud — the click targets for the signature
                    // light-up. Only terms that actually mapped onto a visible
                    // node (i.e. have people to light up) are offered.
                    VocabTermCloud(
                        terms: litUpTerms(vernacular: vern, overlay: overlay),
                        selected: $selectedVocabTerm
                    )
                    VocabularyGraphCanvas(
                        result: result, overlay: overlay,
                        pinnedInfluence: pinnedInfluence,
                        onPersonSelected: onPersonInfluence,
                        selectedTerm: $selectedVocabTerm
                    )
                }
            }
        } else {
            vocabularyEmptyState
        }
    }

    /// The traded terms whose source/adopters resolve onto a VISIBLE node — the
    /// only ones a tap can light up. Built from the resolved overlay (so a term
    /// whose people all capped out of the graph isn't offered as a dead chip).
    /// Each carries its trade direction(s) for the chip's tint + a sort weight
    /// (how many people it touched) so the most-connected words lead.
    private func litUpTerms(vernacular: VernacularGraph, overlay: VocabularyOverlay) -> [VocabCloudTerm] {
        var bySurface: [String: VocabCloudTerm] = [:]
        for trader in overlay.tradersByNodeID.values {
            if let inc = trader.incoming {
                for flow in inc.terms {
                    var t = bySurface[flow.term] ?? VocabCloudTerm(term: flow.term)
                    t.gotCount += 1
                    bySurface[flow.term] = t
                }
            }
            if let out = trader.outgoing {
                for flow in out.terms {
                    var t = bySurface[flow.term] ?? VocabCloudTerm(term: flow.term)
                    t.gaveCount += 1
                    bySurface[flow.term] = t
                }
            }
        }
        // Most-connected first (people touched), then alphabetical for stability.
        return bySurface.values.sorted {
            $0.peopleTouched != $1.peopleTouched
                ? $0.peopleTouched > $1.peopleTouched
                : $0.term < $1.term
        }
    }

    private var vocabularyEmptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No vocabulary trades to map yet")
                .font(.headline)
            Text("This lens lights up once Hourglass detects slang travelling between you and the people in your graph.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown inside the Vocabulary tab while the vernacular build is still
    /// running (0.3.1: the tab used to appear only after the data landed,
    /// which read as the feature not existing — now the wait is explicit).
    private var vocabularyLoadingState: some View {
        VStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.large)
            // Tracks the same analysis stage as the words section; falls back to
            // the static line before the first phase reports.
            Text(vernacularLoadingMessage ?? "Reading how your circle talks")
                .font(.headline)
            Text("Finding the words you trade takes a couple of minutes the first time — it's scanning every message on this Mac, nothing leaves your computer. The graph fills in by itself when it's done.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Legend

    @ViewBuilder
    private func legend(for graph: SocialGraph) -> some View {
        let circles = communityOrder(graph)
        if !circles.isEmpty {
            // Wrapping row of circle swatches, each labeled by its biggest
            // member so the user can name their own circles.
            CircleFlowLayout(spacing: Space.sm) {
                ForEach(circles, id: \.id) { circle in
                    HStack(spacing: Space.xs) {
                        Circle()
                            .fill(CommunityPalette.color(for: circle.id))
                            .frame(width: 9, height: 9)
                        Text(circle.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.contentBackground.opacity(0.6))
                    )
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
                }
            }
        }
    }

    /// Communities sorted by size (id order already encodes that), each tagged
    /// with the display name of its highest-volume member as a human label.
    private func communityOrder(_ graph: SocialGraph) -> [(id: Int, label: String)] {
        var members: [Int: [GraphNode]] = [:]
        for node in graph.nodes where !node.isMe && node.communityID >= 0 {
            members[node.communityID, default: []].append(node)
        }
        // Only label circles with ≥2 members — singletons are "1:1-only"
        // contacts and would flood the legend.
        return members
            .filter { $0.value.count >= 2 }
            .map { (id, nodes) in
                let lead = nodes.max(by: { $0.weightScore < $1.weightScore })
                return (id, lead?.displayName ?? "Circle \(id + 1)")
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Space.md) {
            ProgressView()
            Text("Mapping your conversations…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Not enough group activity yet")
                .font(.headline)
            Text("Your social graph appears once you share group chats with people you also text directly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn't build the graph")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Vocabulary term cloud (the light-up click targets)

/// One clickable term in the cloud, with how it travelled (so its chip can be
/// tinted by direction) and how many people it touched (the sort weight).
struct VocabCloudTerm: Identifiable, Equatable {
    let term: String                 // raw published label (may be "surface#sense")
    var gotCount: Int = 0            // # people you picked it up from (≤1 in practice)
    var gaveCount: Int = 0           // # people who took it from you
    var id: String { term }
    var peopleTouched: Int { gotCount + gaveCount }

    /// Direction tint — blue if you only caught it, orange if it only spread,
    /// purple if both. Mirrors the node tint policy so chip ↔ node read alike.
    var tint: Color {
        if gotCount > 0 && gaveCount > 0 { return VocabPalette.both }
        return gotCount > 0 ? VocabPalette.incoming : VocabPalette.outgoing
    }
}

/// A compact, tappable cloud of the words you traded. Tapping a chip lights that
/// term's people up on the graph beside it (and tapping again clears). Stays
/// spare at rest — shows the most-connected terms first and tucks the long tail
/// behind a "more" toggle so it never crowds the graph.
struct VocabTermCloud: View {
    let terms: [VocabCloudTerm]
    @Binding var selected: String?

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Keep the resting state calm: a couple of rows' worth of the top terms,
    /// the rest one tap away.
    private let collapsedCount = 14

    private var visible: [VocabCloudTerm] {
        expanded ? terms : Array(terms.prefix(collapsedCount))
    }
    private var hiddenCount: Int { max(0, terms.count - collapsedCount) }

    var body: some View {
        if terms.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("Tap a word to see who you traded it with")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                    ForEach(visible) { term in
                        VocabCloudChip(
                            term: term,
                            isSelected: selected == term.term,
                            reduceMotion: reduceMotion
                        ) {
                            withAnimation(reduceMotion ? nil : .bmGlassMorph) {
                                selected = (selected == term.term) ? nil : term.term
                            }
                        }
                    }
                    if hiddenCount > 0 && !expanded {
                        Button {
                            withAnimation(reduceMotion ? nil : .bmDefault) { expanded = true }
                        } label: {
                            Text("+\(hiddenCount) more")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.sm)
                                .padding(.vertical, Space.xs)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.75))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single term chip in the cloud — the clean surface (no raw `#sense`), tinted
/// by trade direction, lifted + filled when it's the lit term.
private struct VocabCloudChip: View {
    let term: VocabCloudTerm
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var hovering = false

    private var surface: String { SenseLabel(raw: term.term).surface }
    private var tint: Color { term.tint }
    private var fillOpacity: Double {
        isSelected ? 0.22 : (hovering ? 0.13 : 0.07)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(surface)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.sm + 1)
            .padding(.vertical, Space.xs + 1)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Capsule(style: .continuous).fill(tint.opacity(fillOpacity)))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isSelected ? tint.opacity(0.55) : (hovering ? tint.opacity(0.30) : Color.hairline),
                              lineWidth: isSelected ? 1.25 : 1)
        )
        .onHover { inside in withAnimation(reduceMotion ? nil : .bmHover) { hovering = inside } }
        .help("“\(surface)” — light up the people you traded it with")
        .accessibilityLabel("\(surface), tap to light up who you traded it with")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
