//
//  VernacularStyleSections.swift
//  Hourglass — Vernacular Analysis ("How you emphasize" + "Your shorthand")
//
//  Two read-only "how you talk" surfaces over the published VM props:
//
//   1) EmphasisDevicesView — generalizes "how you emphasize" beyond ALL-CAPS so
//      a user who never shouts still sees their style. It presents, TOGETHER and
//      each ordered by count:
//        • CAPS shouts        — from `emphaticConstructions` ([EmphaticItem])
//        • Stretched words    — `emphasisSignals` where kind == .elongation
//          ("noooo", "ahhh")
//        • Repeated punctuation — `emphasisSignals` where kind ==
//          .repeatedPunctuation ("!!", "??")
//      Each device family is a ranked row of chips (the device + its count). The
//      caps shouts get the big hero treatment in `VernacularTicsView` above; here
//      they appear as a compact ranked chip row so all three emphasis registers
//      live in ONE place.
//
//   2) DistinctiveVocabView — "your shorthand & slang." Renders the discovered
//      `distinctiveTokens` ([VocabItem]) as a ranked chip cloud by count
//      (ur×5645, rn×2537, abt×2410, …), with a transparent abbreviation/slang
//      split (clippings vs longer slang). Drops apostrophe-contraction leakage
//      at the VIEW layer (doesn't/she's/isn't — tokens whose apostrophe-stripped
//      form is a normal word) as a belt-and-suspenders over the data filter.
//
//  STYLE: matches `StatPanel` + the Vernacular inner cards (solid surface +
//  hairline border — glass is navigation-only). Spacing / radius / tint from
//  `DesignTokens`. Dark-mode correct; reduce-motion respected. Owned by
//  design-agent.
//

import SwiftUI

// MARK: - Display filters (view layer, belt-and-suspenders over the data layer)

/// View-layer cleanup for the distinctive-vocab chips. The data layer already
/// drops contractions whose apostrophe-stripped form is a dictionary word, but
/// the tokenizer occasionally leaks an apostrophe form through (or a baseline
/// gap lets one slip); this guarantees no contraction renders as "slang".
enum DistinctiveVocabFilter {

    /// A small set of contraction STEMS — if a token, with apostrophes removed,
    /// equals one of these (or ends in "nt"/"s"/"ll"/"ve"/"re"/"d" off a real
    /// word), it's ordinary English, not distinctive vocab. We keep this tight:
    /// the real guard is "contains an apostrophe AND its stripped form is a
    /// normal contraction shape".
    private static let contractionStripped: Set<String> = [
        "doesnt", "dont", "didnt", "isnt", "arent", "wasnt", "werent", "havent",
        "hasnt", "hadnt", "wont", "wouldnt", "couldnt", "shouldnt", "cant",
        "cannot", "mustnt", "shes", "hes", "its", "thats", "whats", "theres",
        "heres", "wheres", "whos", "lets", "im", "ive", "ill", "id", "youre",
        "youve", "youll", "youd", "were", "weve", "well", "wed", "theyre",
        "theyve", "theyll", "theyd", " id", "aint", "yall", "gonna", "wanna",
    ]

    /// Should this discovered token render as distinctive vocab? Drops tokens
    /// that are really apostrophe-contractions of ordinary words.
    static func shouldShow(_ token: String) -> Bool {
        let hasApostrophe = token.contains("'") || token.contains("\u{2019}")
        guard hasApostrophe else { return true }
        let stripped = token
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .lowercased()
        // A bare apostrophe-form whose stripped body is a known contraction is
        // leakage; drop it. Genuine clippings ("y'all" is borderline but the
        // data layer keeps it as a word — here we treat the contraction set as
        // the denylist, so "y'all" survives unless explicitly listed).
        return !contractionStripped.contains(stripped)
    }
}

// MARK: - "How you emphasize" — caps + stretch + punctuation, together

/// One unified emphasis surface: CAPS shouts, stretched words, and repeated
/// punctuation, each as a ranked chip row. So even a user who never shouts in
/// caps sees their elongation / punctuation style.
struct EmphasisDevicesView: View {

    /// The caps shouts — already proper-noun/acronym-filtered by the caller's
    /// shared `EmphaticDisplayFilter` (we re-apply it defensively).
    let emphatic: [EmphaticItem]
    /// The non-caps devices (elongation + repeated punctuation).
    let signals: [EmphasisSignal]

    private var caps: [EmphaticItem] {
        emphatic
            .filter { EmphaticDisplayFilter.shouldShow($0.word) }
            .sorted { $0.shoutedCount > $1.shoutedCount }
    }
    private var stretched: [EmphasisSignal] {
        signals.filter { $0.kind == .elongation }
            .sorted { $0.count > $1.count }
    }
    private var punctuation: [EmphasisSignal] {
        signals.filter { $0.kind == .repeatedPunctuation }
            .sorted { $0.count > $1.count }
    }

    private var hasAnything: Bool {
        !caps.isEmpty || !stretched.isEmpty || !punctuation.isEmpty
    }

    var body: some View {
        if hasAnything {
            VStack(alignment: .leading, spacing: Space.md) {
                if !caps.isEmpty {
                    EmphasisFamilyRow(
                        glyph: "a.square.fill",
                        title: "In caps",
                        caption: "Words you SHOUT for emphasis",
                        tint: .accentColor
                    ) {
                        VernChipFlow(items: caps.map {
                            VernChip(text: $0.word.uppercased(), count: $0.shoutedCount,
                                     mono: false, tint: .accentColor)
                        })
                    }
                }
                if !stretched.isEmpty {
                    EmphasisFamilyRow(
                        glyph: "arrow.left.and.right.text.vertical",
                        title: "Stretched out",
                        caption: "Words you drag out for feeling — “noooo”, “ahhh”",
                        tint: .pink
                    ) {
                        VernChipFlow(items: stretched.map {
                            VernChip(text: $0.example, count: $0.count, mono: false, tint: .pink)
                        })
                    }
                }
                if !punctuation.isEmpty {
                    EmphasisFamilyRow(
                        glyph: "exclamationmark.2",
                        title: "Punctuation",
                        caption: "How hard you hit the keys — “!!”, “??”",
                        tint: .orange
                    ) {
                        VernChipFlow(items: punctuation.map {
                            VernChip(text: $0.example, count: $0.count, mono: true, tint: .orange)
                        })
                    }
                }
            }
        } else {
            VernStyleEmptyNote(
                glyph: "exclamationmark.bubble",
                text: "No standout emphasis style yet — keep texting and it’ll surface here."
            )
        }
    }
}

/// A labeled family within "How you emphasize": a small tinted header + the
/// ranked chip content for that register (caps / stretch / punctuation).
private struct EmphasisFamilyRow<Content: View>: View {
    let glyph: String
    let title: String
    let caption: String
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }
}

// MARK: - "Your shorthand & slang" — discovered vocab as ranked chips

/// The distinctive single-token vocabulary the user actually sends, as a ranked
/// chip cloud by count. Transparent abbreviation/slang split (clippings vs
/// longer slang). Drops apostrophe-contraction leakage at the view layer.
struct DistinctiveVocabView: View {

    /// The unified discovered list (ordered by count desc by the data layer).
    let tokens: [VocabItem]

    /// Filtered + re-sorted (defensive) clean list.
    private var clean: [VocabItem] {
        tokens
            .filter { DistinctiveVocabFilter.shouldShow($0.token) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.token < $1.token }
    }

    /// Transparent length split — short clippings vs longer slang — mirroring
    /// the data layer's `splitVocab` (≤4 chars = abbreviation).
    private var abbreviations: [VocabItem] { clean.filter { $0.token.count <= 4 } }
    private var slang: [VocabItem] { clean.filter { $0.token.count > 4 } }

    var body: some View {
        if clean.isEmpty {
            VernStyleEmptyNote(
                glyph: "textformat.abc",
                text: "No distinctive shorthand surfaced yet — keep texting and it’ll show up here."
            )
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                if !abbreviations.isEmpty {
                    VocabFamilyCard(
                        glyph: "textformat.abc.dottedunderline",
                        title: "Shorthand & abbreviations",
                        caption: "The clippings you type instead of the full word",
                        tint: .teal,
                        items: abbreviations
                    )
                }
                if !slang.isEmpty {
                    VocabFamilyCard(
                        glyph: "quote.bubble.fill",
                        title: "Slang & internet-speak",
                        caption: "The longer slang that’s distinctly yours",
                        tint: .purple,
                        items: slang
                    )
                }
            }
        }
    }
}

/// One family card of vocab chips (abbreviations OR slang), ranked by count.
private struct VocabFamilyCard: View {
    let glyph: String
    let title: String
    let caption: String
    let tint: Color
    let items: [VocabItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VernChipFlow(items: items.map {
                VernChip(text: $0.token, count: $0.count, mono: false, tint: tint)
            })
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Shared chip + flow layout

/// One ranked vocab/emphasis chip: the term + a monospaced count. Chip SIZE
/// scales subtly with count so the heaviest terms read first (a light "cloud"
/// feel without sacrificing the explicit count).
private struct VernChip: Identifiable {
    let text: String
    let count: Int
    /// Render the term in a monospaced face (punctuation runs read better mono).
    let mono: Bool
    let tint: Color
    var id: String { "\(text)#\(count)" }
}

/// A wrapping flow of `VernChip`s, ranked by their natural array order (the
/// caller pre-sorts by count desc). Chips scale gently by count within the row.
private struct VernChipFlow: View {
    let items: [VernChip]

    /// Max count in the row — drives the gentle size ramp.
    private var maxCount: Int { items.map(\.count).max() ?? 1 }

    var body: some View {
        CircleFlowLayout(spacing: Space.xs) {
            ForEach(items) { chip in
                VernChipView(chip: chip, fraction: fraction(chip.count))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 0…1 weight of this chip's count vs the row max (log-tempered so a 5000×
    /// term isn't visually 50× a 100× term).
    private func fraction(_ count: Int) -> Double {
        guard maxCount > 1 else { return 1 }
        let lo = log(2.0)
        let hi = log(Double(maxCount) + 1)
        let v = log(Double(count) + 1)
        return hi > lo ? max(0, min(1, (v - lo) / (hi - lo))) : 1
    }
}

/// A single chip view — the term + count, sized by `fraction`.
private struct VernChipView: View {
    let chip: VernChip
    /// 0…1 → drives font size + fill strength so heavy chips pop.
    let fraction: Double

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fontSize: CGFloat { 12 + 4 * CGFloat(fraction) }      // 12…16
    private var fillOpacity: Double { 0.10 + 0.10 * fraction }        // 0.10…0.20
    private var borderOpacity: Double { 0.20 + 0.15 * fraction }      // 0.20…0.35

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(chip.text)
                .font(.system(size: fontSize,
                              weight: fraction > 0.6 ? .semibold : .medium,
                              design: chip.mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(chip.count.formatted())")
                .font(.system(size: max(9, fontSize - 4), weight: .semibold).monospacedDigit())
                .foregroundStyle(chip.tint)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(
            Capsule(style: .continuous)
                .fill(chip.tint.opacity(hovering ? fillOpacity + 0.06 : fillOpacity))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(chip.tint.opacity(borderOpacity), lineWidth: 1)
        )
        .onHover { inside in
            withAnimation(reduceMotion ? .none : .bmHover) { hovering = inside }
        }
        .help("“\(chip.text)” — \(chip.count.formatted())×")
    }
}

// MARK: - Shared empty note

/// A graceful, on-brand empty note for a style section.
private struct VernStyleEmptyNote: View {
    let glyph: String
    let text: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: glyph)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
    }
}
