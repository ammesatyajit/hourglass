//
//  VernacularTicsView.swift
//  Hourglass — Vernacular Analysis (the centerpiece: how you SHOUT + scaffold)
//
//  The rebuilt centerpiece of the Vernacular panel: "Vocative & emphatic tics."
//  The user rejected every guessing section (proper nouns, generic English,
//  confabulated AI labels). What's LEFT and good is the ground truth of how you
//  talk: the words you SHOUT for emphasis, and the little vocative/caps frames
//  you scaffold sentences with.
//
//  This view fuses TWO read-only, published sources:
//    1) `VernacularViewModel.emphaticConstructions` ([EmphaticItem]) — words you
//       type in ALL-CAPS for emphasis (NOT, SO, REALLY, WAIT, HELLA, MAY, BRO…),
//       each with a calm-vs-shouted ratio, a construction `frame` ("is NOT ___"),
//       and real example sentences.
//    2) `VernacularViewModel`'s engine `constructions: [VernacularConstruction]`
//       (family .construction / .tag) — the caps-vocative + trailing-tag frames
//       ("brother …", "… no?", "… lil bro") with their own counts + laugh-rate
//       (`uptakePerUse`).
//
//  RANKING blends frequency with how hard it LANDS (laugh-rate where available),
//  so an emphatic word that draws laughs floats above a merely-frequent one.
//
//  PROPER-NOUN / INSTITUTION FILTER (display side): the data layer already drops
//  most name/place acronyms (its "must appear lowercased + calm form dominates"
//  gates), but as a belt-and-suspenders for the *display*, this view drops any
//  shouted token that is a known institution/place/org acronym (UCLA, AWS, NYC,
//  USA, LA, MIT…) or whose lowercased form is itself a proper noun. Genuine
//  emphasis (NOT/SO/REALLY/WAIT/HELLA/MAY/BRO) sails through.
//
//  STYLE: matches `StatPanel` + the Vernacular inner cards (solid surface +
//  hairline border per the glass policy). Spacing/radius/tint from DesignTokens.
//  Dark-mode correct; reduce-motion respected. Owned by design-agent.
//

import SwiftUI

// MARK: - Display-side proper-noun / institution filter

/// A small denylist of all-caps tokens that are names/places/orgs typed in caps
/// WITHOUT being emphasis. The data layer already filters most of these (it
/// requires the calm lowercased form to dominate), but the user explicitly
/// called out leaked institution acronyms (UCLA, places like LA, CS, ESP) AND
/// contact-name tokens (AMMA = the user's mom), so this view guarantees they
/// never render even if the corpus produces an edge case.
enum EmphaticDisplayFilter {

    /// Institution / place / org / brand acronyms. Lowercased keys.
    static let denylist: Set<String> = [
        // schools / orgs / fields
        "ucla", "usc", "mit", "nyu", "ucsd", "ucsb", "ucb", "berkeley", "cmu",
        "aws", "gcp", "ibm", "nasa", "fbi", "cia", "nba", "nfl", "mlb", "espn",
        "cs", "ee", "ece", "stem", "phd", "mba", "ta", "ra", "rsi",
        // places / geo
        "usa", "uk", "us", "nyc", "la", "sf", "dc", "uae", "eu",
        // generic acronyms that aren't emphasis
        "tv", "ai", "ml", "nlp", "api", "ui", "ux", "id", "ceo", "cfo", "gpa",
        "pdf", "url", "faq", "diy", "atm", "gps", "rsvp", "asap", "esp", "etc",
        "fyi", "eta", "diy", "pst", "est", "pdt", "edt", "am", "pm",
        // texting acronyms (belt-and-suspenders; data layer also stoplists)
        "lol", "lmao", "lmfao", "idk", "idc", "tbh", "imo", "omg", "wtf", "smh",
        "fr", "ngl", "icl", "ts", "ong", "iirc", "irl", "dm", "pfp", "gg", "ok",
    ]

    /// Known first-name / proper-noun / kinship lowercased forms that appear
    /// all-caps when addressing someone (AMMA, NANA…). Small, high-precision;
    /// supplemented at the call site by the resolved-contact name tokens.
    static let properNouns: Set<String> = [
        "noah", "beck", "wei", "li", "annika", "mason", "ishir", "venkat",
        "howard", "king", "neve", "angeles",
        // kinship address terms the user shouts at family (AMMA = mom)
        "amma", "appa", "nana", "papa", "mama", "dada", "thatha", "patti",
    ]

    /// Should this shouted word be SHOWN, given an optional set of resolved
    /// contact name tokens (lowercased first/last names)? Drops institution /
    /// place / org acronyms, known proper nouns, contact-name tokens (a shouted
    /// token that's a known contact's name is address, not emphasis), and tokens
    /// that look like a hard acronym (no vowels, ≤4 letters — "CS"/"ESP"/"BBQ").
    static func shouldShow(_ word: String, contactNameTokens: Set<String> = []) -> Bool {
        let low = word.lowercased()
        if denylist.contains(low) { return false }
        if properNouns.contains(low) { return false }
        if contactNameTokens.contains(low) { return false }
        if looksLikeAcronym(low) { return false }
        return true
    }

    /// A heuristic for short, vowel-less ALL-CAPS acronyms that the curated
    /// denylist might miss ("BBQ", "TBD", "DJ", "PB"). Conservative: ≤4 letters
    /// AND no vowel (so genuine shouted words "SO"/"NOT"/"BRO"/"WAIT" — which all
    /// contain a vowel — always pass). "Y" is treated as a vowel so "WHY" isn't
    /// mis-flagged.
    private static func looksLikeAcronym(_ low: String) -> Bool {
        guard low.count >= 2, low.count <= 4 else { return false }
        guard low.allSatisfy({ $0.isLetter }) else { return false }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        return !low.contains(where: { vowels.contains($0) })
    }
}

// MARK: - Unified tic model (emphatic word OR vocative/tag construction)

/// A single "tic" surfaced in the centerpiece — either an ALL-CAPS emphatic word
/// or a vocative/caps/tag construction frame. Both carry a count, a display
/// frame, an optional laugh-rate, and (for emphatic words) example sentences.
private struct TicItem: Identifiable {
    enum Kind {
        case shout          // an ALL-CAPS emphatic word
        case vocative       // a caps/vocative scaffold ("brother …")
        case tag            // a trailing tag ("… no?")
    }

    let id: String
    let kind: Kind
    /// The headline display string. For shouts, the WORD in caps; for frames,
    /// the pattern ("brother …", "… no?").
    let display: String
    /// A secondary construction frame ("is NOT ___") — shouts only.
    let frame: String?
    /// How many times it occurs (shouted count / construction count).
    let count: Int
    /// Laugh-rate 0…1 if this tic drew laughs (uptakePerUse), else nil.
    let landRate: Double?
    /// Calm baseline (lowercased uses) — shouts only, for the ratio caption.
    let calmCount: Int?
    /// Real example sentences (shouts carry up to 2).
    let examples: [String]

    /// Blended rank score: frequency on a log scale, lifted hard by how often it
    /// LANDS (laughs). A tic that draws laughs floats above a merely-frequent one.
    var score: Double {
        let freq = log(Double(max(count, 1)) + 1)
        let landLift = 1.0 + 2.4 * (landRate ?? 0)
        // Shouts are the hero of this section — give them a gentle edge over the
        // scaffold frames so the page leads with NOT/SO/REALLY.
        let kindWeight: Double = (kind == .shout) ? 1.15 : 1.0
        return freq * landLift * kindWeight
    }
}

// MARK: - Public entry point — the centerpiece

/// "Vocative & emphatic tics." The rich, prominent top section: a hero band of
/// the words you SHOUT (with their frames + examples + laugh-rates) followed by
/// the vocative/caps/tag scaffolds you reach for.
struct VernacularTicsView: View {

    let emphatic: [EmphaticItem]
    let constructions: [VernacularConstruction]
    /// Lowercased first/last-name tokens of the user's resolved contacts, so a
    /// shouted token that's actually addressing someone (AMMA, a friend's name)
    /// is filtered out as address rather than emphasis. Empty when contacts
    /// aren't available — the curated denylist still applies.
    var contactNameTokens: Set<String> = []

    // The shouted words, filtered for proper nouns/institutions/contact names.
    private var shouts: [TicItem] {
        emphatic
            .filter { EmphaticDisplayFilter.shouldShow($0.word, contactNameTokens: contactNameTokens) }
            .map { e in
                TicItem(
                    id: "shout:\(e.word)",
                    kind: .shout,
                    display: e.word,
                    frame: cleanedFrame(e.frame, word: e.word),
                    count: e.shoutedCount,
                    landRate: nil,                  // emphatic items don't carry laughs
                    calmCount: e.lowercasedCount,
                    examples: e.examples
                )
            }
    }

    // The vocative/caps/tag frames from the engine's construction analysis.
    private var frames: [TicItem] {
        constructions.map { c in
            TicItem(
                id: c.id,
                kind: c.family == .tag ? .tag : .vocative,
                display: c.pattern,
                frame: nil,
                count: c.count,
                landRate: c.uptakePerUse > 0.05 ? c.uptakePerUse : nil,
                calmCount: nil,
                examples: []
            )
        }
    }

    /// Hero shouts (top, by blended score) — the ones that get the big treatment.
    private var heroShouts: [TicItem] {
        Array(shouts.sorted { $0.score > $1.score }.prefix(6))
    }

    /// Everything else (remaining shouts + all frames), ranked together for the
    /// "more tics" strip.
    private var moreTics: [TicItem] {
        let heroIDs = Set(heroShouts.map(\.id))
        return (shouts + frames)
            .filter { !heroIDs.contains($0.id) }
            .sorted { $0.score > $1.score }
    }

    private var hasAnything: Bool { !shouts.isEmpty || !frames.isEmpty }

    var body: some View {
        if hasAnything {
            VStack(alignment: .leading, spacing: Space.lg) {
                if !heroShouts.isEmpty {
                    HeroShoutBand(shouts: heroShouts)
                }
                if !moreTics.isEmpty {
                    MoreTicsCard(tics: moreTics)
                }
            }
        } else {
            EmptyTicsNote()
        }
    }

    /// A frame like "is NOT ___" is good; "___ NOT ___" is degenerate — strip it
    /// to nil so we just show the word. Also drop a frame that's only the word.
    private func cleanedFrame(_ frame: String?, word: String) -> String? {
        guard let frame else { return nil }
        let trimmed = frame.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // "___ WORD ___" carries no information — both slots blank.
        if trimmed == "___ \(word) ___" { return nil }
        if trimmed == word { return nil }
        return trimmed
    }
}

// MARK: - Hero band: the words you SHOUT, given the big treatment

/// A responsive grid of large "shout cards." Each card leads with the word in
/// big caps, then its construction frame, a calm-vs-shouted ratio, and a real
/// example sentence. This is the visual centerpiece of the whole panel.
private struct HeroShoutBand: View {
    let shouts: [TicItem]

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Space.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // The single biggest shout gets a full-width feature treatment.
            if let top = shouts.first {
                FeatureShoutCard(tic: top)
            }
            // The rest tile in a responsive grid.
            let rest = Array(shouts.dropFirst())
            if !rest.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Space.md) {
                    ForEach(rest) { tic in
                        ShoutCard(tic: tic)
                    }
                }
            }
        }
    }
}

/// The #1 shouted word — full width, the loudest thing on the page.
private struct FeatureShoutCard: View {
    let tic: TicItem
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            // The shouted word — huge, in the accent tint.
            VStack(alignment: .leading, spacing: 2) {
                Text(tic.display)
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("\(tic.count.formatted())× shouted")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: Space.sm) {
                if let frame = tic.frame {
                    FramePill(frame: frame, word: tic.display, large: true)
                }
                if let calm = tic.calmCount {
                    CalmRatioBar(shouted: tic.count, calm: calm)
                }
                if let ex = tic.examples.first {
                    ExampleQuote(text: ex, highlight: tic.display, lineLimit: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .scaleEffect(appeared ? 1 : 0.98)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .none : .bmGlassMorph) { appeared = true }
        }
        .help("You shouted “\(tic.display)” \(tic.count) times for emphasis.")
    }
}

/// A secondary shouted word card in the hero grid.
private struct ShoutCard: View {
    let tic: TicItem
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(tic.display)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: Space.xs)
                Text("\(tic.count.formatted())×")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let frame = tic.frame {
                FramePill(frame: frame, word: tic.display, large: false)
            }
            if let ex = tic.examples.first {
                ExampleQuote(text: ex, highlight: tic.display, lineLimit: 2)
            } else if let calm = tic.calmCount {
                CalmRatioBar(shouted: tic.count, calm: calm)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 1)
        )
        .onHover { inside in withAnimation(reduceMotion ? .none : .bmHover) { hovering = inside } }
        .help("You shouted “\(tic.display)” \(tic.count) times.")
    }
}

// MARK: - The vocative / caps / tag scaffolds

/// The "more tics" card: a tidy list of the remaining shouted words and the
/// vocative/caps/tag scaffolds you reach for. Each row reads as a frame with its
/// count and a laugh chip when it lands.
private struct MoreTicsCard: View {
    let tics: [TicItem]

    var body: some View {
        VernTicsCard(title: "More of your tics", systemImage: "quote.bubble",
                     caption: "Vocative address, caps emphasis, and the little tags you end on.") {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(tics.prefix(12)) { tic in
                    TicRow(tic: tic)
                }
            }
        }
    }
}

/// One row in the "more tics" list.
private struct TicRow: View {
    let tic: TicItem
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tic.kind == .shout ? Color.accentColor : .secondary)
                .frame(width: 16)

            // The frame / word.
            if tic.kind == .shout {
                Text(tic.display)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Text("“\(tic.display)”")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.sm)

            if let rate = tic.landRate, rate > 0 {
                Text("😂 \(percent(rate))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, Space.xs + 1).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            Text("\(tic.count.formatted())×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Space.xs + 1)
        .padding(.horizontal, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.04 : 0))
        )
        .onHover { inside in withAnimation(reduceMotion ? .none : .bmHover) { hovering = inside } }
        .help(helpText)
    }

    private var glyph: String {
        switch tic.kind {
        case .shout: return "a.square.fill"
        case .vocative: return "person.wave.2"
        case .tag: return "questionmark.bubble"
        }
    }

    private var helpText: String {
        var s = "“\(tic.display)” — \(tic.count) times"
        if let r = tic.landRate, r > 0 { s += ", got a laugh \(percent(r)) of the time" }
        return s
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

// MARK: - Small shared pieces

/// A construction-frame pill, e.g. "is NOT ___", with the shouted word in the
/// accent tint and the blanks de-emphasized.
private struct FramePill: View {
    let frame: String
    let word: String
    let large: Bool

    var body: some View {
        // Render the frame with the WORD highlighted; "___" rendered as a soft
        // underscored blank.
        HStack(spacing: 4) {
            ForEach(Array(frame.split(separator: " ").map(String.init).enumerated()), id: \.offset) { _, tok in
                token(tok)
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.10)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private func token(_ tok: String) -> some View {
        let size: CGFloat = large ? 15 : 12
        if tok == "___" {
            Text("⎵")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.tertiary)
        } else if tok == word {
            Text(tok)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
        } else {
            Text(tok)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A tiny stacked bar that contrasts how often you SHOUT a word vs. say it calmly
/// — the genuine signal that this is emphasis, not how you always write it.
private struct CalmRatioBar: View {
    let shouted: Int
    let calm: Int

    private var shoutFrac: Double {
        let total = Double(shouted + calm)
        return total > 0 ? Double(shouted) / total : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(3, w * shoutFrac))
                }
            }
            .frame(height: 5)
            Text("\(shouted.formatted()) shouted · \(calm.formatted()) calm")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// A real example sentence in quotes, with the shouted word emphasized inline.
private struct ExampleQuote: View {
    let text: String
    let highlight: String
    var lineLimit: Int = 2

    var body: some View {
        (Text("“") + highlighted() + Text("”"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Build an AttributedString-ish composed Text with the caps word bolded in
    /// the accent tint. We split on the (case-sensitive) shouted token so only
    /// the genuine SHOUT is highlighted, not a calm occurrence.
    private func highlighted() -> Text {
        guard !highlight.isEmpty, text.contains(highlight) else {
            return Text(text).italic()
        }
        var result = Text("")
        var remainder = Substring(text)
        while let range = remainder.range(of: highlight) {
            let before = remainder[remainder.startIndex..<range.lowerBound]
            if !before.isEmpty { result = result + Text(String(before)).italic() }
            result = result + Text(highlight)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
            remainder = remainder[range.upperBound...]
        }
        if !remainder.isEmpty { result = result + Text(String(remainder)).italic() }
        return result
    }
}

/// Empty/loading-adjacent note when no tics were found (graceful, on-brand).
private struct EmptyTicsNote: View {
    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "a.square")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No standout emphasis tics yet — keep texting and they'll surface here.")
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

// MARK: - Local card chrome (matches the panel's inner-card language)

/// Inner card chrome — a solid rounded surface + hairline border + small header.
/// Local copy so this file is self-contained (matches `VernCard`/`InsightCard`).
private struct VernTicsCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var caption: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
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
