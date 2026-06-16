//
//  VernacularPage.swift
//  Hourglass — Dashboard / Vernacular page
//
//  ONE STORY: "The words that are uniquely yours — and the people you traded them
//  with." Vernacular IS the people graph, in the user's mental model — the graph
//  is the beloved, natural way to SEE who you traded words with — so the people
//  graph is the HERO/spine of this page, not a tucked-away lens.
//
//  TOP-TO-BOTTOM NARRATIVE (intuitive / uncluttered / human):
//    1. THE PEOPLE GRAPH (hero) — `SocialGraphPanel`, front + center. Its
//       Vocabulary lens IS the got↔gave-on-the-graph: selecting a trader opens
//       their full term list grouped "you picked up" / "spread from you". The
//       Vibe lens (how each person texts) stays as a lens.
//    2. THE WORDS THAT ARE YOURS — profile phrases, reclaimed words, sentence
//       frames, words, and circle slang from the new engine.
//    3. MORE ABOUT YOUR VOICE (progressive disclosure, collapsed by default) —
//       your group's dialect (`VernacularSharedVocabView`) + how you emphasize /
//       your funniest lines (the style sections). Tucked so the page ends calm.
//
//  DATA WIRING (Vocabulary lens)
//  =============================
//  This page OWNS the `VernacularViewModel` and kicks its analysis on `.task`
//  (so it runs only when this page is first shown — see lazy-loading below). The
//  VM publishes a `SpreadProfile`; the graph panel's Vocabulary lens consumes
//  that profile-backed graph and lazy per-person influence rows.
//
//  LAZY-LOADING
//  ============
//  The shell only builds this page when the user selects "Vernacular" in the
//  sidebar. At that point:
//    • the `VernacularViewModel` (owned here) begins its off-main analysis, and
//    • the `SocialGraphPanel` (owned by itself) begins its off-main build.
//  Neither runs while the user sits on Overview. The `@State` view models persist
//  across re-selection of this page, so flipping away and back does NOT redo the
//  work.
//

import SwiftUI
import Foundation

struct VernacularPage: View {

    private let database: ChatDatabase?
    private let contacts: ResolvedContacts?
    /// Summon the Spotlight panel (header pill).
    private let onSearchTap: () -> Void

    /// Owned here. The page is kept alive by the shell once first selected (see
    /// `DashboardView`'s keep-alive detail area), so this `@State` VM is created
    /// exactly once — the analysis runs on first appearance and then PERSISTS
    /// across sidebar page switches (selecting away and back does NOT re-run the
    /// 130k-message pass).
    @State private var vernacular: VernacularViewModel
    @State private var hiddenProfileSurfaces: Set<String> = VernacularProfileHiddenStore.load()

    init(
        database: ChatDatabase?,
        contacts: ResolvedContacts?,
        onSearchTap: @escaping () -> Void,
        labelerProvider: @escaping @Sendable () -> (any VernacularAILabeling)? = { nil }
    ) {
        self.database = database
        self.contacts = contacts
        self.onSearchTap = onSearchTap
        _vernacular = State(initialValue: VernacularViewModel(
            database: database,
            contacts: contacts,
            labelerProvider: labelerProvider
        ))
    }

    var body: some View {
        DashboardScrollPage(
            title: "Vernacular",
            subtitle: subtitle,
            accessory: { DashboardSearchPill(action: onSearchTap) },
            content: { content }
        )
        // Kick the vernacular analysis when the page first appears. Idempotent —
        // a re-appearance with an already-loaded VM is a no-op (the VM persists
        // because the shell keeps this page alive after first selection).
        .task { vernacular.loadIfNeeded() }
    }

    private var subtitle: String {
        switch vernacular.state {
        case .loaded:
            return "The words that are uniquely yours — and the people you traded them with"
        case .loading, .idle:
            return "Finding the words that are uniquely yours…"
        case .empty:
            return "Not enough messages yet"
        case .failed:
            return "The words that are uniquely yours — and the people you traded them with"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let db = database, let contacts {
            VStack(alignment: .leading, spacing: Space.xl) {
                // 1 ── HERO: the people graph. The beloved, natural way to SEE the
                // people you traded words with. Its Vocabulary lens IS the
                // got↔gave-on-the-graph (select a trader → their full term list);
                // the Vibe lens colors people by how they text. Front + center.
                // Builds itself off-main; the Vocabulary/Vibe lenses light up once
                // `spreadProfile` / `vibeClusters` are published.
                SocialGraphPanel(
                    database: db,
                    contacts: contacts,
                    vernacularGraph: nil,
                    vernacularWords: [],
                    vernacularTemplates: [],
                    vernacularLoadingMessage: vernacular.phase?.message,
                    spreadProfile: vernacular.spreadProfile,
                    pinnedInfluence: vernacular.pinnedInfluence,
                    onPersonInfluence: { vernacular.personInfluence(for: $0) },
                    vibeClusters: vernacular.vibeClusters,
                    vibeClusterByContact: vernacular.vibeClusterByContact
                )
                .frame(maxWidth: .infinity)

                // 2 ── THE WORDS THAT ARE YOURS: phrases, reclaimed words,
                // sentence frames, words, and circle slang from the profile.
                wordsThatAreYours

                // 3 ── MORE ABOUT YOUR VOICE: progressive disclosure (collapsed) —
                // your group's dialect + how you emphasize / funniest lines. The
                // lower-value style bits, tucked so the page ends calm.
                moreAboutYourVoice
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            DashboardAccessPrompt(message: "Database unavailable")
        }
    }

    /// Profile-backed "Your vernacular" lists.
    @ViewBuilder
    private var wordsThatAreYours: some View {
        switch vernacular.state {
        case .idle, .loading:
            universeLoadingState
        case .failed(let msg):
            VernMessageState(
                icon: "exclamationmark.triangle",
                title: "Couldn’t analyze your messages",
                detail: msg
            )
        case .empty, .loaded:
            if let profile = vernacular.profile, profile.isEnabled {
                VernacularProfileListsView(
                    profile: profile,
                    hiddenSurfaces: hiddenProfileSurfaces,
                    onHide: hideProfileSurface
                )
            } else {
                VernMessageState(
                    icon: "quote.bubble",
                    title: "Profile lists are off",
                    detail: "Turn on vernacular.profile.enabled to render words, phrases, reclaimed words, and sentence frames."
                )
            }
        }
    }

    private func hideProfileSurface(_ surface: String) {
        var next = hiddenProfileSurfaces
        next.insert(VernacularProfileHiddenStore.normalized(surface))
        hiddenProfileSurfaces = next
        VernacularProfileHiddenStore.save(next)
    }

    /// A first-paint placeholder for the words section while Phase 1 runs. The
    /// subtitle tracks the live analysis stage (`vernacular.phase`) so the user
    /// sees honest progress instead of one frozen line for minutes; it falls back
    /// to a sensible default before the first stage reports.
    private var universeLoadingState: some View {
        StatPanel(title: "The words that are yours",
                  subtitle: vernacular.phase?.message ?? "Finding the words that are uniquely yours…") {
            VStack(spacing: Space.md) {
                // Determinate bar — advances through decode → analyze → rank.
                if let phase = vernacular.phase {
                    ProgressView(value: Double(phase.step + 1),
                                 total: Double(VernacularViewModel.LoadPhase.total))
                        .progressViewStyle(.linear)
                        .tint(.purple)
                        .frame(maxWidth: 300)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text("Reading every message on this Mac — the first pass takes a few minutes. It's all on-device; nothing leaves your computer. This page fills in by itself when it's done.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity).frame(height: 200)
        }
    }

    /// Lowercased first/last-name tokens of the user's resolved contacts. Used to
    /// drop shouted tokens that are really addressing someone (AMMA, a friend's
    /// name) from the emphatic display. Empty when contacts are unavailable.
    private var contactNameTokens: Set<String> {
        guard let contacts else { return [] }
        var tokens = Set<String>()
        for c in contacts.allContacts {
            for part in c.displayName.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" || $0 == "," }) {
                let low = part.lowercased()
                if low.count >= 2 { tokens.insert(low) }
            }
        }
        return tokens
    }

    /// 4 — "More about your voice": progressive disclosure for the lower-value
    /// supporting material, so the page's spine stays the graph + the words you
    /// traded + the words that are yours. Each group is COLLAPSED by default and
    /// opens on tap. We only build a group when it actually has content (so the
    /// page can simply end after the words when there's nothing more), and only
    /// once `.loaded` (the idle/loading/failed states are owned above — no second
    /// spinner here). Two groups:
    ///   • Your group's dialect — the slang you + your friends all share.
    ///   • How you talk — the words you SHOUT / stretch, and your funniest lines.
    @ViewBuilder
    private var moreAboutYourVoice: some View {
        if case .loaded(let insights) = vernacular.state, hasMoreContent(insights) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("More about your voice")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xs)

                if let shared = vernacular.sharedVocabulary, !shared.isEmpty {
                    VernDisclosure(
                        icon: "person.3.fill",
                        tint: .indigo,
                        title: "Your group’s dialect",
                        subtitle: "The slang you and your friends all reach for"
                    ) {
                        VernacularSharedVocabView(terms: shared, chromeless: true)
                    }
                }

                if hasStyleContent(insights) {
                    VernDisclosure(
                        icon: "quote.bubble.fill",
                        tint: .pink,
                        title: "How you talk",
                        subtitle: "The words you SHOUT or stretch — and the lines that made people laugh"
                    ) {
                        styleContent(insights)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The body of the "How you talk" disclosure — the style sections (emphasis +
    /// funniest lines), each with its own warm sub-heading. Unchanged content,
    /// just relocated under progressive disclosure and reframed in plainer words.
    @ViewBuilder
    private func styleContent(_ insights: VernacularInsights) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if vernacular.usedPlaceholderBaseline { placeholderBaselineNote }

            // 🗣️ The words you SHOUT + the little frames you reach for.
            if hasTics(insights) {
                VernPageSection(
                    emoji: "🗣️", title: "How you land a point",
                    caption: "The words you put in CAPS, and the little frames you reach for. Bigger = louder; 😂 = it gets a laugh."
                ) {
                    VernacularTicsView(
                        emphatic: vernacular.emphaticConstructions ?? [],
                        constructions: insights.constructions,
                        contactNameTokens: contactNameTokens
                    )
                }
            }

            // 📣 How you emphasize — caps + stretched words + punctuation, together,
            // so even a non-caps style reads.
            if hasEmphasisDevices {
                VernPageSection(
                    emoji: "📣", title: "How you emphasize",
                    caption: "Every register you reach for — the words you SHOUT, the ones you stretch out, and how hard you hit the punctuation."
                ) {
                    EmphasisDevicesView(
                        emphatic: vernacular.emphaticConstructions ?? [],
                        signals: vernacular.emphasisSignals ?? []
                    )
                }
            }

            // 😂 Your funniest lines (laugh-only).
            if let gems = vernacular.reactedGems, !gems.isEmpty {
                VernPageSection(
                    emoji: "😂", title: "Your funniest lines",
                    caption: "The things you said that landed — ranked by how often they got a laugh."
                ) {
                    ReactedGemsGrid(gems: gems)
                }
            }
        }
    }

    /// True when there's any emphasis device to show (caps shouts OR non-caps
    /// elongation/punctuation signals) — gates the "How you emphasize" section.
    private var hasEmphasisDevices: Bool {
        !(vernacular.emphaticConstructions ?? []).isEmpty
            || !(vernacular.emphasisSignals ?? []).isEmpty
    }

    /// The tics section needs either shouted words or the caps/vocative
    /// constructions the insights carry.
    private func hasTics(_ insights: VernacularInsights) -> Bool {
        !(vernacular.emphaticConstructions ?? []).isEmpty
            || !insights.constructions.isEmpty
    }

    /// Whether the "How you talk" disclosure has ANY content.
    private func hasStyleContent(_ insights: VernacularInsights) -> Bool {
        hasTics(insights) || hasEmphasisDevices || !(vernacular.reactedGems ?? []).isEmpty
    }

    /// Whether the "More about your voice" area has ANY content at all — gates the
    /// whole disclosure region (and its heading) so the page can simply end after
    /// the words when there's nothing more to show.
    private func hasMoreContent(_ insights: VernacularInsights) -> Bool {
        !(vernacular.sharedVocabulary ?? []).isEmpty || hasStyleContent(insights)
    }

    private var placeholderBaselineNote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Using a fallback word list — phrase quality is reduced.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Section header (within the tics/funny panel)

/// An emoji + title + caption header strip, then the section's content. Plain
/// typographic divider — no nested glass (glass is navigation-only).
private struct VernPageSection<Content: View>: View {
    let emoji: String
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(emoji).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Profile-driven Stage A lists

/// Profile renderer: list surfaces come from `VernacularProfile` when the
/// profile flag is enabled. The people graph is driven by `SpreadProfile`.
private struct VernacularProfileListsView: View {
    let profile: VernacularProfile
    let hiddenSurfaces: Set<String>
    let onHide: (String) -> Void

    private var visibleReclaimedWords: [VernacularProfileReclaimedWord] {
        profile.reclaimedWords.filter { isVisible($0.surface) }
    }
    private var visibleWords: [VernacularProfilePhrase] {
        profile.words.filter { isVisible($0.surface) }
    }
    private var visibleCircleSlang: [VernacularProfilePhrase] {
        profile.circleSlang.filter { isVisible($0.surface) }
    }
    private var visiblePhrases: [VernacularProfilePhrase] {
        profile.phrases.filter { isVisible($0.surface) }
    }
    private var visibleTemplates: [VernacularProfileTemplate] {
        profile.templates.filter { isVisible($0.pattern) }
    }
    private var rawCount: Int {
        profile.words.count + profile.circleSlang.count + profile.phrases.count
            + profile.reclaimedWords.count + profile.templates.count
    }
    private var visibleCount: Int {
        visibleWords.count + visibleCircleSlang.count + visiblePhrases.count
            + visibleReclaimedWords.count + visibleTemplates.count
    }

    /// Height of each side-by-side vocabulary column. Each column scrolls
    /// internally (same pattern as Overview's leaderboards), so the page stays
    /// one screen tall instead of 80 stacked phrase rows.
    private let columnHeight: CGFloat = 480

    var body: some View {
        StatPanel(title: "Your vernacular", subtitle: subtitle) {
            if visibleCount > 0 {
                VStack(alignment: .leading, spacing: Space.lg) {
                    // The hero three — Sentence frames | Words | Expressions —
                    // side by side like Overview's leaderboards, each an
                    // internally-scrollable column. (0.3.1 naming for the
                    // general public: "Words" = repurposed normal English
                    // (was "Reclaimed words"; tint moved off orange so it no
                    // longer collides with the gave-to-someone arrows);
                    // "Expressions" = the invented/slang tokens (was "Words").)
                    HStack(alignment: .top, spacing: Space.lg) {
                        if !visibleTemplates.isEmpty {
                            VernProfileFacet(
                                glyph: "square.dashed",
                                title: "Sentence frames",
                                count: visibleTemplates.count,
                                tint: .mint
                            ) {
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: Space.sm) {
                                        ForEach(visibleTemplates) { item in
                                            VernProfileSurfaceRow(
                                                title: item.pattern,
                                                metric: "\(item.counts.userMessages.formatted())x",
                                                subtitle: templateSubtitle(item),
                                                detail: templateDetail(item),
                                                examples: item.examples,
                                                pills: item.topFills.prefix(5).map { ($0.fill, $0.count) },
                                                tint: .mint,
                                                onHide: { onHide(item.pattern) }
                                            )
                                        }
                                    }
                                }
                                .frame(height: columnHeight)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        if !visibleReclaimedWords.isEmpty {
                            VernProfileFacet(
                                glyph: "arrow.triangle.2.circlepath",
                                title: "Words",
                                count: visibleReclaimedWords.count,
                                tint: .yellow
                            ) {
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: Space.sm) {
                                        ForEach(visibleReclaimedWords) { item in
                                            VernProfileSurfaceRow(
                                                title: item.surface,
                                                metric: "\(item.counts.userMessages.formatted())x",
                                                subtitle: reclaimedSubtitle(item),
                                                detail: reclaimedDetail(item),
                                                examples: item.examples,
                                                pills: item.topCollocationPartner.map { [($0, Int((item.collocation * 100).rounded()))] } ?? [],
                                                tint: .yellow,
                                                onHide: { onHide(item.surface) }
                                            )
                                        }
                                    }
                                }
                                .frame(height: columnHeight)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }

                        if !visibleWords.isEmpty {
                            phraseFacet(
                                title: "Expressions",
                                glyph: "quote.bubble.fill",
                                tint: .purple,
                                items: visibleWords,
                                scrollHeight: columnHeight
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    // The quieter lists — common phrases + circle slang —
                    // tucked behind a disclosure so the panel ends calm.
                    if !visiblePhrases.isEmpty || !visibleCircleSlang.isEmpty {
                        VernDisclosure(
                            icon: "text.quote",
                            tint: .teal,
                            title: "More of your words",
                            subtitle: "Common phrases and the slang your circle shares"
                        ) {
                            VStack(alignment: .leading, spacing: Space.lg) {
                                if !visiblePhrases.isEmpty {
                                    phraseFacet(
                                        title: "Common phrases",
                                        glyph: "text.quote",
                                        tint: .teal,
                                        items: visiblePhrases
                                    )
                                }

                                if !visibleCircleSlang.isEmpty {
                                    phraseFacet(
                                        title: "Circle slang",
                                        glyph: "person.3.fill",
                                        tint: .indigo,
                                        items: visibleCircleSlang
                                    )
                                }
                            }
                        }
                    }
                }
            } else if rawCount > 0 {
                VernProfileEmptyNote(
                    icon: "eye.slash",
                    text: "Everything in the profile list is hidden."
                )
            } else {
                VernProfileEmptyNote(
                    icon: "sparkle.magnifyingglass",
                    text: "No standout words, phrases, reclaimed words, or sentence frames surfaced yet."
                )
            }
        }
    }

    private var subtitle: String {
        let who = profile.stats.subjectName
        // "You" reads as "Your …", a contact as "Annika's …".
        let possessive = who.caseInsensitiveCompare("You") == .orderedSame ? "Your" : "\(who)'s"
        if let caveat = profile.stats.caveat, !caveat.isEmpty {
            return "\(possessive) phrases, reclaimed words, sentence frames, words, and circle slang. \(caveat)"
        }
        return "\(possessive) phrases, reclaimed words, sentence frames, words, and circle slang"
    }

    /// One facet of phrase-shaped items. With `scrollHeight` the list becomes a
    /// fixed-height, internally-scrolling column (the side-by-side layout);
    /// without it the rows stack at their natural height (the disclosure lists).
    private func phraseFacet(
        title: String,
        glyph: String,
        tint: Color,
        items: [VernacularProfilePhrase],
        scrollHeight: CGFloat? = nil
    ) -> some View {
        VernProfileFacet(glyph: glyph, title: title, count: items.count, tint: tint) {
            if let scrollHeight {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Space.sm) {
                        phraseRows(items: items, tint: tint)
                    }
                }
                .frame(height: scrollHeight)
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    phraseRows(items: items, tint: tint)
                }
            }
        }
    }

    private func phraseRows(items: [VernacularProfilePhrase], tint: Color) -> some View {
        ForEach(items) { item in
            VernProfileSurfaceRow(
                title: item.surface,
                metric: "\(item.counts.userMessages.formatted())x",
                subtitle: phraseSubtitle(item),
                detail: phraseDetail(item),
                examples: item.examples,
                tint: tint,
                onHide: { onHide(item.surface) }
            )
        }
    }

    private func isVisible(_ surface: String) -> Bool {
        !hiddenSurfaces.contains(VernacularProfileHiddenStore.normalized(surface))
    }

    private func phraseSubtitle(_ item: VernacularProfilePhrase) -> String {
        let days = item.counts.distinctUserDays
        return "said \(item.counts.userMessages.formatted())x · across \(days.formatted()) day\(days == 1 ? "" : "s")"
    }

    private func phraseDetail(_ item: VernacularProfilePhrase) -> String {
        let recv = item.counts.receivedMessages
        return "You said it \(item.counts.userMessages.formatted())x · \(recv.formatted())x around you"
    }

    private func reclaimedSubtitle(_ item: VernacularProfileReclaimedWord) -> String {
        var parts = ["a normal word you made your own"]
        if let partner = item.topCollocationPartner, !partner.isEmpty {
            parts.append("often with \(partner)")
        }
        return parts.joined(separator: " · ")
    }

    private func reclaimedDetail(_ item: VernacularProfileReclaimedWord) -> String {
        "You said it \(item.counts.userMessages.formatted())x · \(item.counts.receivedMessages.formatted())x around you"
    }

    private func templateSubtitle(_ item: VernacularProfileTemplate) -> String {
        "\(item.slotCount) blank\(item.slotCount == 1 ? "" : "s") · \(item.topFills.count) ways you filled it"
    }

    private func templateDetail(_ item: VernacularProfileTemplate) -> String {
        "You said it \(item.counts.userMessages.formatted())x · \(item.counts.receivedMessages.formatted())x around you"
    }
}

private struct VernProfileFacet<Content: View>: View {
    let glyph: String
    let title: String
    let count: Int
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.14)))
            }

            content()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }
}

private struct VernProfileSurfaceRow: View {
    let title: String
    let metric: String
    let subtitle: String
    let detail: String
    let examples: [String]
    var pills: [(String, Int)] = []
    let tint: Color
    let onHide: () -> Void

    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? Space.sm : 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(metric)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tint.opacity(0.13)))
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: Space.sm)

                Button(action: onHide) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Hide")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("Hide \(title) from this profile list")

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .bmDefault) {
                    expanded.toggle()
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !pills.isEmpty {
                        FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                            ForEach(Array(pills.prefix(6).enumerated()), id: \.offset) { _, pill in
                                HStack(spacing: 3) {
                                    Text(pill.0)
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                    if pill.1 > 0 {
                                        Text("\(pill.1)")
                                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(tint)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tint.opacity(0.10)))
                                .overlay(Capsule().strokeBorder(tint.opacity(0.20), lineWidth: 0.75))
                            }
                        }
                    }

                    if examples.isEmpty {
                        Text("No example captured.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(examples.prefix(3).enumerated()), id: \.offset) { _, example in
                            Text("\"\(example)\"")
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Space.sm)
                                .padding(.vertical, Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                    .fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
                .padding(.top, Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.055 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(hovering ? tint.opacity(0.26) : Color.hairline, lineWidth: 1))
        .onHover { inside in withAnimation(reduceMotion ? nil : .bmHover) { hovering = inside } }
    }
}

private struct VernProfileEmptyNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }
}

private enum VernacularProfileHiddenStore {
    private static let key = "vernacular.profile.hidden"

    static func normalized(_ surface: String) -> String {
        surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func load(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).map(normalized))
    }

    static func save(_ surfaces: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(surfaces.sorted(), forKey: key)
    }
}

// MARK: - Progressive-disclosure group

/// A collapsible group for the page's lower-value supporting material, so the
/// spine (graph + words you traded + words that are yours) stays the surface and
/// the depth is one tap away. Solid card + hairline + chevron — structure, not a
/// new material (glass is navigation-only; this is a content container). Starts
/// COLLAPSED. Smooth spring on toggle; reduce-motion respected.
private struct VernDisclosure<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .bmDefault) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.top, Space.md)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(hovering && !expanded ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
        .onHover { inside in withAnimation(reduceMotion ? nil : .bmHover) { hovering = inside } }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
        .contentShape(Rectangle())
    }
}

/// A graceful empty/error placeholder for the vernacular universe region.
private struct VernMessageState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        StatPanel(title: "The words that are yours") {
            VStack(spacing: Space.sm) {
                Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 160).padding(.vertical, Space.sm)
        }
    }
}
