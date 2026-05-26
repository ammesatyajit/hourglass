//
//  HelpSheet.swift
//  Hourglass
//
//  A glanceable filter-syntax cheatsheet shown over the spotlight panel.
//
//  Why
//  ---
//  The empty state surfaces ONE example per category (5 chips total) to
//  keep the panel scannable. But the full grammar is rich — case
//  modifiers, co-occurrence, multi-word quotes, `to:` vs `from:`, the
//  named reaction kinds, the natural-language Ask mode — and a dense
//  reference is the only way to expose the long tail without bloating the
//  always-visible UI.
//
//  Trigger
//  -------
//  - A small `?` button visible IN the search field (right side) AND in
//    the panel footer.
//  - `⌘/` from anywhere in the panel (Slack / Linear convention).
//  - `⌘?` is the user-requested alternate (technically ⌘⇧/) — wired as
//    a secondary keyboard shortcut so both bindings work.
//
//  Visual
//  ------
//  Edge-to-edge overlay on the panel (not a separate window). Backed by
//  `.regularMaterial` — overlays are exactly the case where Apple's HIG
//  *does* permit material backing on a content layer because the overlay
//  IS chrome with respect to the content underneath. Escape dismisses.
//
//  Layout: TIGHT two-column grid. Header row, then 6 category sections
//  (People / Chat / Date / Reactions / Content / Free text) arranged
//  side-by-side so the sheet fits in the 520pt panel viewport without
//  internal scroll on the common cases. If a user's display is narrower
//  the columns gracefully collapse into a vertical stack with a single
//  scroll axis as a fallback.
//
//  Each token entry has a tinted token, a one-line description, and a
//  click-to-insert example. Clicking the example inserts it into the
//  search field, runs the search, and closes the sheet — turning the
//  cheatsheet into a launchpad as well as a reference.
//

import SwiftUI

/// One entry in the help sheet. Owns its category, prefix, description,
/// and a click-to-run example.
struct HelpEntry: Identifiable, Hashable {
    let id: String
    let token: String
    let description: String
    let example: String
    let category: FilterCategory

    init(token: String, description: String, example: String, category: FilterCategory) {
        self.id = token
        self.token = token
        self.description = description
        self.example = example
        self.category = category
    }
}

/// A section of the help sheet — title + entries.
struct HelpSection: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let entries: [HelpEntry]
}

extension HelpSection {
    /// The canonical reference list. Mirrors `MessageSearch.parseQuery`
    /// and `Sources/Search/QueryAutocomplete.swift::TokenPrefix`. When a
    /// new prefix lands there, add it here too.
    ///
    /// Each section is TRIMMED to the most useful 2–3 entries so the
    /// sheet fits the panel viewport. The reference is biased toward
    /// the most-common operators — the long tail (`type:audio`,
    /// `type:sticker`, `reactions:question`) is mentioned in the
    /// description text but not given its own row.
    static let allSections: [HelpSection] = [
        HelpSection(
            id: "people",
            title: "People",
            icon: "person.crop.circle",
            entries: [
                .init(
                    token: "from:NAME",
                    description: "Messages sent by NAME (contact or handle).",
                    example: "from:Mom",
                    category: .person
                ),
                .init(
                    token: "to:NAME",
                    description: "Messages YOU sent to NAME.",
                    example: "to:Alex",
                    category: .person
                ),
            ]
        ),
        HelpSection(
            id: "chat",
            title: "Chat",
            icon: "bubble.left.and.bubble.right",
            entries: [
                .init(
                    token: "with:NAME",
                    description: "Any chat (1:1 or group) with NAME as a participant.",
                    example: "with:\"Howard Xu\"",
                    category: .chat
                ),
                .init(
                    token: "chat:NAME",
                    description: "A specific chat — named chat or 1:1 with NAME.",
                    example: "chat:family",
                    category: .chat
                ),
                .init(
                    token: "in:NAME",
                    description: "Alias for chat:.",
                    example: "in:Vegas",
                    category: .chat
                ),
            ]
        ),
        HelpSection(
            id: "date",
            title: "Date",
            icon: "calendar",
            entries: [
                .init(
                    token: "last:7d",
                    description: "Relative window (d, w, mo, y).",
                    example: "last:7d",
                    category: .dateRange
                ),
                .init(
                    token: "after:DATE",
                    description: "On or after DATE. Natural or ISO.",
                    example: "after:2025-01-01",
                    category: .dateRange
                ),
                .init(
                    token: "before:DATE",
                    description: "Before DATE.",
                    example: "before:yesterday",
                    category: .dateRange
                ),
                .init(
                    token: "on:DATE",
                    description: "Single day. Sugar for after: + before:.",
                    example: "on:2025-12-25",
                    category: .dateRange
                ),
            ]
        ),
        HelpSection(
            id: "reactions",
            title: "Reactions",
            icon: "heart.fill",
            entries: [
                .init(
                    token: "reactions:>=N",
                    description: "At least N reactions. Also <=, >, <, =.",
                    example: "reactions:>=3",
                    category: .reaction
                ),
                .init(
                    token: "reactions:KIND",
                    description: "love · like · laugh · emphasize · question · dislike.",
                    example: "reactions:love",
                    category: .reaction
                ),
            ]
        ),
        HelpSection(
            id: "type",
            title: "Content type",
            icon: "doc.richtext",
            entries: [
                .init(
                    token: "type:image",
                    description: "Photos. Also video / link / audio / file / sticker.",
                    example: "type:image",
                    category: .type
                ),
                .init(
                    token: "type:attachment",
                    description: "Any non-text content.",
                    example: "type:attachment",
                    category: .type
                ),
            ]
        ),
        HelpSection(
            id: "free-text",
            title: "Text",
            icon: "text.magnifyingglass",
            entries: [
                .init(
                    token: "A+B",
                    description: "AND — both terms in the same message.",
                    example: "vacation+flight",
                    category: .freeText
                ),
                .init(
                    token: "A|B or A OR B",
                    description: "OR — either term matches. Lower precedence than +.",
                    example: "cactus|saguaro",
                    category: .freeText
                ),
                .init(
                    token: "*term*",
                    description: "Substring — matches inside words. Default is word-bounded.",
                    example: "*cactus*",
                    category: .freeText
                ),
                .init(
                    token: "/regex/",
                    description: "Regex match. Add /i for case-insensitive.",
                    example: "/cact.*/",
                    category: .freeText
                ),
                .init(
                    token: "\"two words\"",
                    description: "Multi-word phrase. Toggle Aa for case sensitivity.",
                    example: "\"happy birthday\"",
                    category: .freeText
                ),
            ]
        ),
    ]

    /// The Ask-mode (NL) reference — surfaced as a single section at the
    /// top of the help sheet. Different visual treatment (purple tint,
    /// sparkles icon) so the user sees it as a distinct mode rather than
    /// another set of operators.
    static let askSection = HelpSection(
        id: "ask",
        title: "Ask anything (Tab)",
        icon: "sparkles",
        entries: [
            .init(
                token: "natural questions",
                description: "Press Tab to toggle Ask mode, then ask in plain English.",
                example: "who did I text the most this year?",
                category: .freeText
            ),
        ]
    )
}

struct HelpSheet: View {
    let onClose: () -> Void
    let onInsert: (String) -> Void

    @State private var hoveringClose = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            sectionsGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        // Escape dismisses — matches the panel's own dismiss-on-escape and
        // keeps the help sheet from "trapping" the keyboard.
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Search syntax")
                .font(.headline)
            Spacer()
            Text("⌘/ or ⌘?  ·  esc to close")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(
                        Circle().fill(
                            hoveringClose
                                ? Color.primary.opacity(0.12)
                                : Color.primary.opacity(0.06)
                        )
                    )
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Close (esc)")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    /// Two-column grid of sections. Compact enough to fit the panel's
    /// 520pt viewport without internal scroll on common machines. The
    /// `ViewThatFits` fallback collapses to a single column + scroll for
    /// very narrow displays (e.g. user manually shrunk the panel).
    private var sectionsGrid: some View {
        ViewThatFits(in: .vertical) {
            twoColumnGrid
            ScrollView {
                twoColumnGrid
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var twoColumnGrid: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Ask-mode banner — purple tint, sparkles, full-width.
            // First because it's a different mode entirely, not another
            // operator, and we want the user to see the toggle exists.
            askBanner
                .padding(.horizontal, Space.lg)

            // Two columns of 3 sections each. At the panel's default 720pt
            // width each column is ~340pt wide, plenty for the tokens.
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Array(HelpSection.allSections.prefix(3))) { section in
                        sectionView(section)
                    }
                }
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(Array(HelpSection.allSections.suffix(3))) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
        }
        .padding(.top, Space.md)
    }

    private var askBanner: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Ask anything")
                        .font(.subheadline.weight(.semibold))
                    Text("Tab")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.purple.opacity(0.15))
                        )
                        .foregroundStyle(.purple)
                }
                Text("Type a question like ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                + Text("who did I text the most this year?")
                    .font(.caption.monospaced())
                    .foregroundStyle(.purple)
                + Text(" — press Tab to switch to Ask mode first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .fill(Color.purple.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.20), lineWidth: 0.5)
        )
    }

    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.xs) {
                Image(systemName: section.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { idx, entry in
                    HelpRow(entry: entry, onInsert: { onInsert(entry.example) })
                    if idx < section.entries.count - 1 {
                        Divider().opacity(0.15)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .stroke(Color.hairline, lineWidth: 0.5)
            )
        }
    }
}

private struct HelpRow: View {
    let entry: HelpEntry
    let onInsert: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onInsert) {
            VStack(alignment: .leading, spacing: 1) {
                // Token + description on the same line — keeps each row
                // to ~28pt tall so the whole sheet fits the viewport.
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(entry.token)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(entry.category.tint)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(entry.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(entry.category.tint.opacity(isHovering ? 0.9 : 0.5))
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(entry.category.tint.opacity(isHovering ? 0.08 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bmHover) { isHovering = hovering }
        }
        .help("Insert \(entry.example) into the search field")
        .accessibilityLabel("\(entry.token): \(entry.description)")
        .accessibilityHint("Inserts \(entry.example) into the search field")
    }
}

// MARK: - Previews

#Preview("HelpSheet — light", traits: .fixedLayout(width: 720, height: 520)) {
    HelpSheet(onClose: {}, onInsert: { _ in })
}

#Preview("HelpSheet — dark", traits: .fixedLayout(width: 720, height: 520)) {
    HelpSheet(onClose: {}, onInsert: { _ in })
        .preferredColorScheme(.dark)
}
