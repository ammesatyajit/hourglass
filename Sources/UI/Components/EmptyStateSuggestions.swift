//
//  EmptyStateSuggestions.swift
//  Hourglass
//
//  The empty-state "quick filters" surface shown when the search field is
//  empty. Discoverability for the query grammar — clickable pills that
//  pre-populate the field with a working token.
//
//  Purpose
//  -------
//  A first-time user opens the panel and sees a search field and… nothing.
//  They might guess to type a word, but they have no idea that `from:Mom`,
//  `type:image`, or `reactions:>=3` exist. These pills are the
//  discoverability affordance: clicking one populates the field AND fires
//  the search, so a single tap demonstrates "yes, this is a thing."
//
//  Visual
//  ------
//  Solid pill chips, per Apple HIG (glass is reserved for navigation chrome,
//  not content-layer call-to-action buttons). Each pill tinted with its
//  category color from `FilterCategory` so the visual vocabulary is
//  consistent with the filter chips that appear once a query has tokens.
//
//  Layout — ONE row, ONE chip per category
//  ---------------------------------------
//  The previous version was 5 horizontal scroll rows (Content/Time/
//  Reactions/People/Combos), each with 4–6 pills, totaling 25–30 visible
//  affordances. User feedback was unambiguous: "you shouldn't have to
//  scroll through to choose options. It should just show you one example
//  from each category."
//
//  Solution: ONE example per category, FIVE pills total, in a single
//  flowing row. The chip count drops 5–6x. The whole empty state fits
//  in the panel's default viewport (720x520) with no scroll. The HelpSheet
//  is the long-tail reference for users who want to see every variant.
//
//  Sectioning headers, horizontal scroll rows, and dynamic personalized
//  people pills (which all the prior structure existed to support) are
//  REMOVED. Personalization moved into the chip's `token` slot: when a
//  top contact is available we still render the People chip as
//  `from:"Mom"` rather than the generic `from:`, so the chip is one tap
//  away from a useful search.
//
//  Recents (above) and HelpSheet (in the footer) cover the discovery and
//  re-run loops. The Try chips are now the FAST-PATH onboarding surface,
//  not the comprehensive reference.
//

import SwiftUI

/// Visual grouping for the empty-state pills. Pure UI concept — does not
/// affect the search engine in any way. We choose categories that map
/// naturally to the user's mental model ("what kind of thing am I looking
/// for") rather than the engine's parser tokens.
///
/// One chip per category — these enum cases are the surface of the empty
/// state.
enum SuggestionCategory: String, Hashable, CaseIterable, Sendable, Identifiable {
    case content
    case time
    case reactions
    case people
    case combos

    var id: String { rawValue }

    /// The header label (no longer rendered as a section header — kept
    /// because tests + accessibility labels still reference it).
    var headerLabel: String {
        switch self {
        case .content:   return "Content"
        case .time:      return "Time"
        case .reactions: return "Reactions"
        case .people:    return "People"
        case .combos:    return "Try this"
        }
    }

    /// Accessibility-friendly description of the section.
    var accessibilityLabel: String {
        "\(headerLabel) filter"
    }
}

/// A single quick-filter button in the empty state. Tapping it populates the
/// search field with the corresponding token and fires the search.
struct EmptyStateSuggestion: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let icon: String
    let token: String
    /// Filter-chip tint category (matches the chip that appears once the
    /// query has the corresponding token recognized).
    let category: FilterCategory
    /// Visual section grouping in the empty-state layout.
    let section: SuggestionCategory

    init(
        label: String,
        icon: String,
        token: String,
        category: FilterCategory,
        section: SuggestionCategory
    ) {
        // ID includes section so the same token (e.g. a free-text combo)
        // appearing in two sections doesn't collide. None of the canonical
        // pills currently double up, but the safer ID lets curators add
        // overlap later without breaking ForEach diffing.
        self.id = "\(section.rawValue):\(token)"
        self.label = label
        self.icon = icon
        self.token = token
        self.category = category
        self.section = section
    }
}

extension EmptyStateSuggestion {
    // MARK: - Compact one-per-category curation

    /// Build the canonical 5-chip row, one example per category, optionally
    /// personalized with a top contact's name for the People slot.
    ///
    /// - `topContactNames`: most-recent 1:1 chat partners, ordered most-recent
    ///    -first. Only the first entry is used — the personalized chip
    ///    becomes `from:"<Name>"` instead of the generic `from:` token.
    ///    Pass `[]` to render the generic People pill.
    ///
    /// Order is locked: Content → Time → Reactions → People → Combo.
    /// Tests pin this so the visual flow doesn't reshuffle between launches.
    static func compactRow(
        topContactNames: [String] = []
    ) -> [EmptyStateSuggestion] {
        [
            contentExample,
            timeExample,
            reactionsExample,
            peopleExample(topContactName: topContactNames.first),
            comboExample,
        ]
    }

    /// Section-wrapped variant — same five pills, returned as
    /// `(section, [suggestion])` pairs so tests that pin per-section ordering
    /// keep working without restructuring.
    static func curatedSections(
        topContactNames: [String] = []
    ) -> [(section: SuggestionCategory, suggestions: [EmptyStateSuggestion])] {
        let row = compactRow(topContactNames: topContactNames)
        return row.map { (section: $0.section, suggestions: [$0]) }
    }

    /// Flattened list — same as `compactRow`. Kept as a name-alias for
    /// existing callers (tests, accessibility audits).
    static func allCurated(topContactNames: [String] = []) -> [EmptyStateSuggestion] {
        compactRow(topContactNames: topContactNames)
    }

    /// Backward-compatible canonical "Try these" list. Six pills — distinct
    /// from `compactRow` (5 pills, one per category). Preserved so legacy
    /// callers and previews keep compiling.
    static let defaults: [EmptyStateSuggestion] = [
        .init(label: "Photos", icon: "photo.on.rectangle", token: "type:image", category: .type, section: .content),
        .init(label: "Videos", icon: "video", token: "type:video", category: .type, section: .content),
        .init(label: "Links", icon: "link", token: "type:link", category: .type, section: .content),
        .init(label: "Most-reacted", icon: "heart.fill", token: "reactions:>=3", category: .reaction, section: .reactions),
        .init(label: "Last 7 days", icon: "calendar", token: "last:7d", category: .dateRange, section: .time),
        .init(label: "Last 30 days", icon: "calendar.badge.clock", token: "last:30d", category: .dateRange, section: .time),
    ]

    // MARK: - One canonical example per category
    //
    // These are the SINGLE most-useful pill from each category. The
    // HelpSheet covers the long tail; these are the discovery surface.

    /// Content: photos. Most-used attachment type by an order of magnitude.
    static let contentExample = EmptyStateSuggestion(
        label: "Photos",
        icon: "photo.on.rectangle",
        token: "type:image",
        category: .type,
        section: .content
    )

    /// Time: last 30 days. The most-common "recent stuff" window.
    static let timeExample = EmptyStateSuggestion(
        label: "Last 30 days",
        icon: "calendar.badge.clock",
        token: "last:30d",
        category: .dateRange,
        section: .time
    )

    /// Reactions: at least 3. Distinguishes "popular" messages without
    /// requiring the user to pick a specific kind.
    static let reactionsExample = EmptyStateSuggestion(
        label: "≥ 3 reactions",
        icon: "heart.fill",
        token: "reactions:>=3",
        category: .reaction,
        section: .reactions
    )

    /// People: personalized if a top contact name is supplied, generic
    /// `from:` prompt otherwise. The personalized variant is the killer
    /// "this app knows YOUR data" moment — a single tap finds messages
    /// from someone the user actually talks to.
    static func peopleExample(topContactName: String?) -> EmptyStateSuggestion {
        if let name = topContactName, !name.isEmpty {
            let body = name.contains(where: { $0.isWhitespace }) ? "\"\(name)\"" : name
            return EmptyStateSuggestion(
                label: "From \(name)",
                icon: "person.crop.circle",
                token: "from:\(body)",
                category: .person,
                section: .people
            )
        }
        return EmptyStateSuggestion(
            label: "From a name",
            icon: "person.crop.circle",
            token: "from:",
            category: .person,
            section: .people
        )
    }

    /// Combo: photos in the last 7 days. Concrete enough to feel useful
    /// at a glance; combines two prefix types so the user sees the
    /// chain-filters pattern modeled.
    static let comboExample = EmptyStateSuggestion(
        label: "Photos this week",
        icon: "photo.stack",
        token: "type:image last:7d",
        category: .type,
        section: .combos
    )

    // MARK: - Legacy per-section pill lists
    //
    // The old sectioned layout populated horizontal-scroll rows from these
    // lists. The new compact layout uses ONE pill per category; we keep
    // these lists around because (a) the legacy flat init still references
    // `defaults`, and (b) the HelpSheet's reference grid is conceptually
    // the same surface.

    static let contentPills: [EmptyStateSuggestion] = [
        contentExample,
        .init(label: "Videos", icon: "video", token: "type:video", category: .type, section: .content),
        .init(label: "Links", icon: "link", token: "type:link", category: .type, section: .content),
    ]

    static let timePills: [EmptyStateSuggestion] = [
        .init(label: "Today", icon: "clock", token: "on:today", category: .dateRange, section: .time),
        .init(label: "Last 7 days", icon: "calendar", token: "last:7d", category: .dateRange, section: .time),
        timeExample,
    ]

    static let reactionPills: [EmptyStateSuggestion] = [
        reactionsExample,
        .init(label: "Hearted", icon: "heart", token: "reactions:love", category: .reaction, section: .reactions),
        .init(label: "Funny", icon: "face.smiling.inverse", token: "reactions:laugh", category: .reaction, section: .reactions),
    ]

    /// People pills — legacy helper retained for tests that assert the
    /// shape of dynamically-injected pills. The new compact layout uses
    /// ONLY `peopleExample(topContactName:)` for visible rendering.
    static func peoplePills(topContactNames: [String]) -> [EmptyStateSuggestion] {
        var out: [EmptyStateSuggestion] = []
        for name in topContactNames.prefix(2) {
            let body = name.contains(where: { $0.isWhitespace }) ? "\"\(name)\"" : name
            out.append(.init(
                label: name,
                icon: "person.crop.circle",
                token: "from:\(body)",
                category: .person,
                section: .people
            ))
        }
        out.append(contentsOf: [
            .init(label: "From a name", icon: "person.text.rectangle",
                  token: "from:", category: .person, section: .people),
            .init(label: "Sent to a name", icon: "paperplane",
                  token: "to:", category: .person, section: .people),
            .init(label: "1:1 chats with", icon: "person.2",
                  token: "with:", category: .person, section: .people),
        ])
        return out
    }

    static let comboPills: [EmptyStateSuggestion] = [
        comboExample,
        .init(label: "Links this month", icon: "link.circle",
              token: "type:link last:30d", category: .type, section: .combos),
        .init(label: "Loved photos", icon: "heart.text.square",
              token: "type:image reactions:love", category: .reaction, section: .combos),
    ]
}

// MARK: - View

/// The visual surface — a single horizontal row of 5 pills (one per
/// category) sitting above a small "Try" caption. Fits in the panel's
/// default viewport without scrolling.
struct EmptyStateSuggestions: View {
    /// The compact row to render. Each pill carries its own category tint.
    let pills: [EmptyStateSuggestion]
    let onSelect: (EmptyStateSuggestion) -> Void

    /// Legacy single-row flat init. Renders the supplied suggestions as a
    /// FlowingHStack (wraps to multiple rows when the parent is narrow).
    /// Kept so existing previews + tests work; new callers should use the
    /// compact init with `topContactNames`.
    let flatSuggestions: [EmptyStateSuggestion]?

    /// Default initializer — the compact 5-chip row.
    init(
        topContactNames: [String] = [],
        onSelect: @escaping (EmptyStateSuggestion) -> Void
    ) {
        self.pills = EmptyStateSuggestion.compactRow(topContactNames: topContactNames)
        self.flatSuggestions = nil
        self.onSelect = onSelect
    }

    /// Legacy initializer — kept so existing callers that pass a flat list
    /// (e.g. previews, tests) keep working. Renders the single-row
    /// flowing layout exactly as before.
    init(
        suggestions: [EmptyStateSuggestion],
        onSelect: @escaping (EmptyStateSuggestion) -> Void
    ) {
        self.pills = []
        self.flatSuggestions = suggestions
        self.onSelect = onSelect
    }

    var body: some View {
        if let flat = flatSuggestions {
            legacyFlatLayout(flat)
        } else {
            compactLayout
        }
    }

    /// One horizontal row of 5 pills. We render them in a `FlowingHStack`
    /// so they wrap gracefully if the panel is ever narrower than the
    /// pill row (e.g. user dragged the resize handle). At the default
    /// 720pt width all 5 pills fit comfortably on one line.
    private var compactLayout: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Try")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.horizontal, Space.xs)

            FlowingHStack(spacing: Space.xs) {
                ForEach(pills) { pill in
                    QuickFilterPill(suggestion: pill, action: { onSelect(pill) })
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick filters — one example per category")
    }

    private func legacyFlatLayout(_ suggestions: [EmptyStateSuggestion]) -> some View {
        VStack(spacing: Space.md) {
            Text("Try one of these")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            FlowingHStack(spacing: Space.xs) {
                ForEach(suggestions) { suggestion in
                    QuickFilterPill(suggestion: suggestion, action: { onSelect(suggestion) })
                }
            }
            .frame(maxWidth: 520)
        }
    }
}

/// A solid (not-glass) pill button. Per HIG, glass is for navigation chrome;
/// these are content-layer CTAs — solid fills + hairline border, tinted by
/// the filter category so the visual vocabulary matches the filter chips
/// that will appear once the user has typed a query.
private struct QuickFilterPill: View {
    let suggestion: EmptyStateSuggestion
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: suggestion.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(suggestion.category.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(suggestion.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(suggestion.category.tint.opacity(isHovering ? 0.18 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(suggestion.category.tint.opacity(isHovering ? 0.45 : 0.20),
                                  lineWidth: 0.5)
            )
            .scaleEffect(isHovering ? 1.025 : 1.0)
            .animation(.bmHover, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Apply \(suggestion.token)")
        // The accessibility label is the visible name + the operator the
        // pill applies — so a VoiceOver user knows both "this is the
        // Photos button" AND "it applies the type:image filter".
        .accessibilityLabel("\(suggestion.label), applies \(suggestion.token)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Minimal flowing-HStack: wraps items into multiple rows when the available
/// width is exceeded. Used by both the compact 5-pill layout and the legacy
/// flat init — at the default panel width (720pt) the 5 pills fit in a
/// single line; at the minimum width (640pt) one or two may wrap.
private struct FlowingHStack: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = Space.xs) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let needsSpace = !(rows.last?.isEmpty ?? true)
            let advance = size.width + (needsSpace ? spacing : 0)
            if rowWidth + advance > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += advance
            }
        }
        var totalHeight: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            let rowHeight = row.map(\.height).max() ?? 0
            totalHeight += rowHeight
            if idx < rows.count - 1 {
                totalHeight += spacing
            }
        }
        var totalWidth: CGFloat = 0
        for row in rows {
            let itemsWidth = row.map(\.width).reduce(0, +)
            let gaps = CGFloat(max(0, row.count - 1)) * spacing
            let rowWidth = itemsWidth + gaps
            if rowWidth > totalWidth { totalWidth = rowWidth }
        }
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var rows: [[(idx: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        for (idx, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needsSpace = !(rows.last?.isEmpty ?? true)
            let advance = size.width + (needsSpace ? spacing : 0)
            if rowWidth + advance > maxWidth, !(rows.last?.isEmpty ?? true) {
                rows.append([(idx, size)])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append((idx, size))
                rowWidth += advance
            }
        }

        var y = bounds.minY
        for row in rows {
            let rowContentWidth = row.map(\.size.width).reduce(0, +)
                + CGFloat(max(0, row.count - 1)) * spacing
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for entry in row {
                subviews[entry.idx].place(
                    at: CGPoint(x: x, y: y + (rowHeight - entry.size.height) / 2),
                    proposal: ProposedViewSize(width: entry.size.width, height: entry.size.height)
                )
                x += entry.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

// MARK: - Previews

#Preview("EmptyStateSuggestions — compact (personalized)", traits: .fixedLayout(width: 640, height: 200)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        EmptyStateSuggestions(
            topContactNames: ["Mom"],
            onSelect: { _ in }
        )
        .padding(Space.xl)
    }
}

#Preview("EmptyStateSuggestions — compact (generic)", traits: .fixedLayout(width: 640, height: 200)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        EmptyStateSuggestions(onSelect: { _ in })
            .padding(Space.xl)
    }
    .preferredColorScheme(.dark)
}

#Preview("EmptyStateSuggestions — legacy flat layout", traits: .fixedLayout(width: 640, height: 200)) {
    ZStack {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        EmptyStateSuggestions(
            suggestions: EmptyStateSuggestion.defaults,
            onSelect: { _ in }
        )
        .padding(Space.xl)
    }
}
