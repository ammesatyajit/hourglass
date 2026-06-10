//
//  NostalgiaStoryCards.swift
//  Hourglass — Dashboard / Nostalgia (per-chat "notable moments" UI)
//
//  The third-generation Nostalgia UI. The earlier waves rendered generic
//  cross-chat aggregates (beloved / streaks / eras / first-words / funny);
//  those are RETIRED. This wave renders two surfaces over the rebuilt
//  `NostalgiaViewModel` data:
//
//    • OnThisDayMomentCard  — one anniversary moment (event-gated; only shows
//      on a date that matches a real origin / biggest-day / peak-reaction). The
//      "N years ago today" framing is the hero; the headline + detail + example
//      + which-chat sit beneath.
//    • ChatStoryRow         — a browsable, EXPANDABLE row for one `ChatStory`
//      (avatar, title, message count, date span). Tapping it reveals that
//      chat's MomentTimeline — origin → longest conversation → biggest day →
//      peak reaction → (for groups) membership events — arranged as a vertical
//      timeline so it reads like the chat's story.
//
//  All content-layer (solid + hairline per the glass policy). `AvatarView` is
//  reused for people; group avatars fall back to a monogram of the title.
//  Owned by design-agent.
//

import SwiftUI

// MARK: - Moment visual treatment (icon + tint per kind)

/// The visual identity of a `NotableMoment.Kind` — its SF Symbol + tint. Kept
/// in the view layer (the data layer only ships a default `symbol`; the design
/// owns the final treatment + color).
enum MomentStyle {
    static func symbol(_ kind: NotableMoment.Kind) -> String {
        switch kind {
        case .origin: return "sparkles"
        case .longestConversation: return "bubble.left.and.bubble.right.fill"
        case .biggestDay: return "chart.bar.fill"
        case .peakReaction: return "heart.fill"
        case .joined: return "person.fill.badge.plus"
        case .left: return "person.fill.badge.minus"
        case .renamed: return "pencil.line"
        }
    }

    static func tint(_ kind: NotableMoment.Kind) -> Color {
        switch kind {
        case .origin: return .yellow
        case .longestConversation: return .blue
        case .biggestDay: return .orange
        case .peakReaction: return .pink
        case .joined: return .green
        case .left: return .secondary
        case .renamed: return .purple
        }
    }
}

// MARK: - On This Day card

/// One anniversary moment. The "N years ago today" framing is the hero strip;
/// then the moment's headline, optional detail, the chat it happened in, and an
/// optional quoted example. Carries a per-row hide affordance (any person can be
/// suppressed — the sensitivity guardrail).
struct OnThisDayMomentCard: View {
    let moment: NotableMoment
    /// Which chat this moment happened in (resolved by the panel — the moment
    /// itself doesn't carry the title).
    let chatTitle: String
    /// "now", used to compute the years-ago framing. Injected so it's stable.
    let now: Date
    let calendar: Calendar
    /// Hide affordance — hides the person the moment is about, if any.
    let onHide: (() -> Void)?

    private var tint: Color { MomentStyle.tint(moment.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // Kind glyph in a tinted disc.
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: MomentStyle.symbol(moment.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: Space.xs) {
                // Years-ago framing — the hero of the card.
                Text(yearsAgoText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text(moment.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = moment.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Which chat — anchors the memory to a conversation.
                HStack(spacing: Space.xs) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 9))
                    Text(chatTitle)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)

                if let quote = quoteText {
                    QuoteBlock(text: quote, isAttachment: isAttachment, tint: tint)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onHide, let person = moment.person {
                HidePersonButton(name: person, action: onHide)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(tint.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }

    private var yearsAgoText: String {
        let years = calendar.dateComponents([.year], from: moment.date, to: now).year ?? 0
        if years <= 0 { return "Today" }
        if years == 1 { return "1 year ago today" }
        return "\(years) years ago today"
    }

    private var isAttachment: Bool {
        guard let ex = moment.example else { return false }
        return ex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var quoteText: String? {
        guard let ex = moment.example else { return nil }
        let t = ex.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (moment.kind == .peakReaction || moment.kind == .origin ? "Attachment" : nil) : t
    }
}

// MARK: - Chat story row (browsable + expandable)

/// One `ChatStory` as a browsable row that expands to reveal its moment
/// timeline. Collapsed: avatar + title + message count + date span + a
/// disclosure chevron. Expanded: the `MomentTimeline`. Carries a per-row hide
/// affordance (for 1:1s, hides the partner; the whole story then drops).
struct ChatStoryRow: View {
    let story: ChatStory
    let onHide: ((String) -> Void)?
    /// Initial expansion state. Defaults to collapsed (the in-app behavior — the
    /// user expands a chat to reveal its timeline); a non-default value is only
    /// used by render previews/harnesses that want the expanded layout on screen.
    var startExpanded: Bool = false

    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(story: ChatStory, onHide: ((String) -> Void)?, startExpanded: Bool = false) {
        self.story = story
        self.onHide = onHide
        self.startExpanded = startExpanded
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider()
                    .padding(.horizontal, Space.md)
                MomentTimeline(story: story, onHide: onHide)
                    .padding(.horizontal, Space.md)
                    .padding(.top, Space.md)
                    .padding(.bottom, Space.md)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .fill(Color.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
        .animation(reduceMotion ? nil : .bmDefault, value: expanded)
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .bmDefault) { expanded.toggle() }
        } label: {
            HStack(spacing: Space.md) {
                StoryAvatar(story: story)

                VStack(alignment: .leading, spacing: 2) {
                    Text(story.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Message count, as a quiet hero number.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(NostalgiaFormat.compact(story.messageCount))
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("messages")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                if let onHide, !story.isGroup {
                    HidePersonButton(name: story.title, action: { onHide(story.title) })
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(story.title), \(story.messageCount) messages")
        .accessibilityHint(expanded ? "Collapse story" : "Expand story")
    }

    private var metaLine: String {
        var parts: [String] = []
        if story.isGroup {
            parts.append("\(story.participantCount) people")
        }
        parts.append(spanText)
        return parts.joined(separator: " · ")
    }

    /// Shared formatter — `DateFormatter()` allocation is milliseconds-scale,
    /// and this runs on every body evaluation of every visible row (hover,
    /// scroll-driven re-renders), so a per-call instance hitches scrolling.
    private static let spanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    private var spanText: String {
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: story.firstDate) == cal.component(.year, from: story.lastDate)
        let f = Self.spanFormatter
        if sameYear {
            return f.string(from: story.firstDate)
        }
        return "\(f.string(from: story.firstDate)) – \(f.string(from: story.lastDate))"
    }
}

/// The avatar for a story — the 1:1 contact / group photo when present, else a
/// monogram of the title (groups read as their name's initials).
private struct StoryAvatar: View {
    let story: ChatStory

    var body: some View {
        if story.isGroup && story.avatarData == nil {
            // Group with no photo: a distinct group glyph so it doesn't read as
            // a person, tinted by the title for a little per-chat identity.
            ZStack {
                Circle().fill(groupTint.opacity(0.22))
                Image(systemName: "person.3.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(groupTint)
            }
            .frame(width: 40, height: 40)
            .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.5))
        } else {
            AvatarView(
                imageData: story.avatarData,
                initials: NostalgiaInitials.of(story.title),
                size: 40,
                tint: groupTint.opacity(0.28)
            )
        }
    }

    /// A stable per-title hue so each group has a faint identity color.
    private var groupTint: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .purple, .pink, .orange, .green]
        var hash = 0
        for scalar in story.title.unicodeScalars { hash = (hash &* 31) &+ Int(scalar.value) }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - Moment timeline (the story)

/// A chat's moments arranged on a vertical timeline (date order, oldest → newest
/// — `ChatStory.moments` already arrives sorted). One connected rail with a
/// tinted dot per moment, the moment's headline / detail / example beside it.
struct MomentTimeline: View {
    let story: ChatStory
    let onHide: ((String) -> Void)?

    var body: some View {
        if story.moments.isEmpty {
            Text("No notable moments in this chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(story.moments.enumerated()), id: \.element.id) { idx, moment in
                    MomentTimelineRow(
                        moment: moment,
                        isFirst: idx == 0,
                        isLast: idx == story.moments.count - 1,
                        onHide: hideAction(for: moment)
                    )
                }
            }
        }
    }

    /// Only offer a per-moment hide when the moment is about a hidable person
    /// (a join/leave/peak by someone) AND a hide handler exists.
    private func hideAction(for moment: NotableMoment) -> (() -> Void)? {
        guard let onHide, let person = moment.person else { return nil }
        return { onHide(person) }
    }
}

/// One dot on a chat's timeline.
private struct MomentTimelineRow: View {
    let moment: NotableMoment
    let isFirst: Bool
    let isLast: Bool
    let onHide: (() -> Void)?

    private var tint: Color { MomentStyle.tint(moment.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // Rail + dot.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.hairline)
                    .frame(width: 1.5, height: 14)
                ZStack {
                    Circle().fill(Color.contentBackground)
                    Circle().fill(tint.opacity(0.18))
                    Image(systemName: MomentStyle.symbol(moment.kind))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                Rectangle()
                    .fill(isLast ? Color.clear : Color.hairline)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 24)

            // Moment content.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(moment.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.xs)
                    Text(dateText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                    if let onHide {
                        HidePersonButton(name: moment.person ?? "", action: onHide)
                    }
                }

                if let detail = moment.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let quote = quoteText {
                    QuoteBlock(text: quote, isAttachment: isAttachment, tint: tint)
                }
            }
            .padding(.bottom, isLast ? 0 : Space.lg)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dateText: String { NostalgiaDateText.medium(moment.date) }

    private var isAttachment: Bool {
        guard let ex = moment.example else { return false }
        return ex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var quoteText: String? {
        guard let ex = moment.example else { return nil }
        let t = ex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        // Empty body on a quotable kind == an attachment; mark it.
        return (moment.kind == .peakReaction || moment.kind == .origin) ? "Attachment" : nil
    }
}

// MARK: - Shared quote block

/// A quoted message body inside a moment/anniversary card. Attachment-only
/// bodies render italicized + secondary so they read as "a photo/file", not a
/// missing string.
private struct QuoteBlock: View {
    let text: String
    let isAttachment: Bool
    let tint: Color

    var body: some View {
        Text(isAttachment ? text : "“\(text)”")
            .font(.subheadline)
            .italic(isAttachment)
            .foregroundStyle(isAttachment ? .secondary : .primary)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(tint.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(tint.opacity(0.12), lineWidth: 0.5)
            )
    }
}
