//
//  QuerySuggestionsPopover.swift
//  Hourglass
//
//  Spotlight-style autocomplete list shown below the search field while the
//  user is typing a recognized token (e.g. `chat:`, `from:`, `last:`).
//
//  Behavior
//  --------
//  - Driven by `QueryAutocomplete.analyze(query:)` — pure logic decides what
//    to suggest; this view just renders.
//  - ↑ / ↓ select between rows; ⏎ / Tab accept; Escape hides.
//  - Tap-to-accept also works.
//  - When the popover is hidden (no completable token), this view returns an
//    `EmptyView` so it costs nothing in the parent layout.
//
//  Visual
//  ------
//  - `.regularMaterial` background + hairline border, same family as the
//    spotlight panel itself.
//  - Selected row uses the accent tint at low opacity — same vocabulary as
//    SidebarItem so users can tell what's interactive at a glance.
//
//  Not in this file (intentional):
//  - Suggestion *generation* (matching contacts/chats/dates against the
//    partial). That's in `QuerySuggestionsProvider`, which takes the view
//    model as input and produces strings.
//

import SwiftUI

/// One row in the suggestions list. Identifiable by its string value plus the
/// index to keep collisions impossible if two contacts share a display name.
struct QuerySuggestion: Identifiable, Hashable {
    let id: Int
    let value: String
    let kind: SuggestionKind
    let subtitle: String?

    enum SuggestionKind: Hashable {
        case chat
        case person
        case date
        case reaction
        case type
    }
}

struct QuerySuggestionsPopover: View {

    let suggestions: [QuerySuggestion]
    let selectedIndex: Int
    let onSelect: (QuerySuggestion) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            // Wrap in a ScrollView so long suggestion lists don't push the
            // panel's layout around. `ScrollViewReader` lets us programmatically
            // keep the highlighted row visible as ↑/↓ moves it.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, s in
                            SuggestionRow(
                                suggestion: s,
                                isSelected: idx == selectedIndex
                            )
                            .id(s.id)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { onHover(idx) }
                            }
                            .onTapGesture { onSelect(s) }
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selectedIndex) { _, newIndex in
                    guard suggestions.indices.contains(newIndex) else { return }
                    // Anchor `.center` so a selected item near the edge gets
                    // pulled into the middle — feels like Spotlight's behavior.
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(suggestions[newIndex].id, anchor: .center)
                    }
                }
            }
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .stroke(Color.hairline, lineWidth: 0.5)
            )
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: QuerySuggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.value)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let sub = suggestion.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                .padding(.horizontal, Space.xs)
        )
    }

    private var icon: String {
        switch suggestion.kind {
        case .chat: return "bubble.left.and.bubble.right"
        case .person: return "person.crop.circle"
        case .date: return "calendar"
        case .reaction: return "heart.fill"
        case .type: return "doc.richtext"
        }
    }

    private var tint: Color {
        switch suggestion.kind {
        case .chat: return .orange
        case .person: return .blue
        case .date: return .purple
        case .reaction: return .pink
        case .type: return .teal
        }
    }
}
