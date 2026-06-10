//
//  VernacularSharedVocabView.swift
//  Hourglass — Vernacular Analysis (the group dialect / inside-jokes section)
//
//  Renders `VernacularViewModel.sharedVocabulary` ([SharedTerm]) — the slang
//  YOU and your friends ALL use. This is a DIFFERENT thing from the personal
//  universe above (your rare slang) and from the 1:1 trade ledger (who handed a
//  term to whom): it's the COMMON TONGUE of the friend group.
//
//  ORDERING / EMPHASIS (per the brief — "inside-jokes first"):
//    • INSIDE JOKES lead — terms with a HIGH share width (`peopleCount`) that are
//      ALSO heavily YOUR-driven (high `yourUses` share of `totalUses`). These are
//      the phrases the whole group says and that you say a lot ("traffic cone",
//      "of my soul") — the warmest, most "ours" signal.
//    • Then the rest of the group dialect, by share width (`peopleCount`) desc —
//      the data layer's own order.
//  Within a term we surface the share width, your share, and the top users (as
//  initials monograms) so "who all says this" reads at a glance.
//
//  STYLE: matches `StatPanel` + the Vernacular inner cards — solid surfaces +
//  hairline borders (glass is navigation-only per the HIG). Tints + spacing from
//  `DesignTokens`. Dark-mode correct; reduce-motion respected. Owned by
//  design-agent.
//

import SwiftUI

/// "Your group's dialect": the shared in-group vocabulary, inside-jokes first.
struct VernacularSharedVocabView: View {

    /// Ranked by `peopleCount` desc by the data layer.
    let terms: [SharedTerm]
    /// When `true`, drop the surrounding `StatPanel` (title/subtitle/card) and
    /// render just the facets — for when an outer container (e.g. the Vernacular
    /// page's progressive-disclosure group) already provides the titled chrome,
    /// so the title isn't doubled and glass isn't nested. Defaults `false`
    /// (standalone use is unchanged).
    var chromeless: Bool = false

    /// An inside joke is a widely-shared term that's ALSO heavily yours — the
    /// whole group says it and you lean on it. Threshold: shared by ≥4 people
    /// (the data layer's own floor for surfacing) AND your uses are a meaningful
    /// slice of the total (≥35%). These lead.
    private var insideJokes: [SharedTerm] {
        terms
            .filter { $0.totalUses > 0 && Double($0.yourUses) / Double($0.totalUses) >= 0.35 }
            .sorted { yourShare($0) > yourShare($1) }
    }
    private var insideJokeIDs: Set<String> { Set(insideJokes.map(\.id)) }
    /// The rest — the broad group dialect, in the data layer's share-width order.
    private var dialect: [SharedTerm] {
        terms.filter { !insideJokeIDs.contains($0.id) }
    }

    private func yourShare(_ t: SharedTerm) -> Double {
        t.totalUses > 0 ? Double(t.yourUses) / Double(t.totalUses) : 0
    }

    var body: some View {
        if terms.isEmpty {
            EmptyView()
        } else if chromeless {
            // An outer container (the Vernacular page's disclosure) already
            // supplies the titled chrome — render just the facets.
            facets
        } else {
            StatPanel(
                title: "Your group’s dialect",
                subtitle: "The slang you and your friends all share — the inside jokes you lean on most, first"
            ) {
                facets
            }
        }
    }

    @ViewBuilder
    private var facets: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if !insideJokes.isEmpty {
                SharedFacet(
                    glyph: "face.smiling.inverse",
                    title: "Inside jokes",
                    caption: "Shared across the group — and yours through and through.",
                    tint: .pink,
                    terms: insideJokes,
                    highlightYours: true
                )
            }
            if !dialect.isEmpty {
                SharedFacet(
                    glyph: "person.3.fill",
                    title: "Group dialect",
                    caption: "The common tongue — words your circle reaches for together.",
                    tint: .indigo,
                    terms: dialect,
                    highlightYours: false
                )
            }
        }
    }
}

// MARK: - One facet (inside jokes OR the broad dialect)

private struct SharedFacet: View {
    let glyph: String
    let title: String
    let caption: String
    let tint: Color
    let terms: [SharedTerm]
    /// Inside jokes draw the "mostly you" emphasis; the broad dialect doesn't.
    let highlightYours: Bool

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Space.md, alignment: .top)]

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
                Text("\(terms.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.14)))
                Text("·").foregroundStyle(.tertiary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
                ForEach(terms) { term in
                    SharedTermCard(term: term, tint: tint, highlightYours: highlightYours)
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }
}

// MARK: - One shared-term card

/// A single shared term: the term (hero), a "shared by N" badge, your-share, and
/// the top users as initials monograms — so "who all says this" reads instantly.
private struct SharedTermCard: View {
    let term: SharedTerm
    let tint: Color
    let highlightYours: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var yourSharePercent: Int {
        guard term.totalUses > 0 else { return 0 }
        return Int((Double(term.yourUses) / Double(term.totalUses) * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // The term, hero.
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text("“\(term.term)”")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                // Share-width badge — the sort key, surfaced.
                Label("\(term.peopleCount)", systemImage: "person.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, Space.xs + 1).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.14)))
                    .help("\(term.peopleCount) people use “\(term.term)”")
            }

            // Top users — initials monograms (the "who all says this" glance).
            if !term.topUsers.isEmpty {
                HStack(spacing: -6) {
                    ForEach(Array(term.topUsers.prefix(5).enumerated()), id: \.offset) { idx, user in
                        SharedUserMonogram(user: user, tint: tint, zIndex: Double(5 - idx))
                    }
                    if !topUsersSummary.isEmpty {
                        Text(topUsersSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Space.sm)
                    }
                }
            }

            // Your-share — emphasized for inside jokes, quiet for the dialect.
            HStack(spacing: Space.xs) {
                Image(systemName: highlightYours ? "heart.fill" : "person.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(highlightYours ? tint : Color.secondary.opacity(0.6))
                Text(yourShareText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(tint.opacity(hovering ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(hovering ? tint.opacity(0.30) : Color.hairline, lineWidth: 1))
        .onHover { inside in withAnimation(reduceMotion ? .none : .bmHover) { hovering = inside } }
    }

    private var topUsersSummary: String {
        let extra = term.peopleCount - min(term.topUsers.count, 5)
        return extra > 0 ? "+\(extra)" : ""
    }

    private var yourShareText: String {
        highlightYours
            ? "You drive it — \(yourSharePercent)% of \(term.totalUses.formatted()) uses"
            : "\(term.yourUses.formatted()) of your messages · \(yourSharePercent)% yours"
    }
}

// MARK: - One overlapping user monogram (extracted to keep the card type-check fast)

/// A single top-user initials disc in the overlapping monogram stack. Extracted
/// so the parent card's `body` stays within the type-checker's budget.
private struct SharedUserMonogram: View {
    let user: SharedTerm.TopUser
    let tint: Color
    let zIndex: Double

    private var initials: String {
        let comps = user.name.split(separator: " ")
        let first = comps.first?.first.map(String.init) ?? ""
        let last = comps.count > 1 ? comps.last?.first.map(String.init) ?? "" : ""
        let r = (first + last).uppercased()
        return r.isEmpty ? "?" : r
    }

    var body: some View {
        ZStack {
            Circle().fill(tint.gradient.opacity(0.85))
            Text(initials)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().strokeBorder(Color.contentBackground, lineWidth: 1.5))
        .zIndex(zIndex)
        .help("\(user.name) — \(user.count)×")
    }
}

// MARK: - Previews

#Preview("Group dialect", traits: .fixedLayout(width: 640, height: 520)) {
    let terms: [SharedTerm] = [
        SharedTerm(term: "traffic cone", peopleCount: 6, totalUses: 30, yourUses: 18,
                   topUsers: [.init(name: "Noah Cylich", count: 7), .init(name: "Annika Renganathan", count: 5),
                              .init(name: "Beck", count: 3)]),
        SharedTerm(term: "of my soul", peopleCount: 4, totalUses: 12, yourUses: 7,
                   topUsers: [.init(name: "Venkat Rao", count: 3), .init(name: "Mason", count: 2)]),
        SharedTerm(term: "bet", peopleCount: 9, totalUses: 74, yourUses: 14,
                   topUsers: [.init(name: "Anshul", count: 22), .init(name: "Shreya", count: 18),
                              .init(name: "Atul", count: 11)]),
        SharedTerm(term: "lowkey", peopleCount: 7, totalUses: 48, yourUses: 9,
                   topUsers: [.init(name: "Melina Noras", count: 15), .init(name: "David Kim", count: 10)]),
    ]
    return ScrollView {
        VernacularSharedVocabView(terms: terms)
            .padding(Space.lg)
    }
    .frame(width: 640, height: 520)
    .background(Color.chromeBackground)
}
