//
//  QuerySuggestionsProvider.swift
//  Hourglass
//
//  Given an autocomplete context + the available pool of chats/contacts,
//  return the suggestions to show in the popover. Pure (apart from reading
//  the in-memory pools) so the view stays dumb.
//

import Foundation

public enum QuerySuggestionsProvider {

    /// Maximum suggestions to surface at once. Tight enough to stay
    /// Spotlight-density, generous enough that scrolling is rarely needed.
    public static let maxSuggestions = 10

    /// Fixed date suggestions, ordered most-likely first.
    static let dateSuggestions: [String] = [
        "today", "yesterday", "last 7 days", "last 30 days",
        "this week", "last week", "this month", "last month",
        "this year", "last year",
        "2026", "2025", "2024", "2023",
    ]

    /// Fixed reaction suggestions. Threshold comparators come first (these
    /// are the most useful — "show me the messages with lots of reactions"),
    /// then the named kinds.
    static let reactionSuggestions: [String] = [
        ">=1", ">=3", ">=5", ">=10",
        "any",
        "love", "like", "laugh", "emphasize", "question", "dislike",
    ]

    /// Fixed content-type suggestions. Common-first ordering — most users
    /// reach for image / video, link comes next (link previews are very
    /// common in modern chats), then the long tail.
    static let typeSuggestions: [String] = [
        "image", "video", "link", "audio", "sticker",
        "file", "text", "attachment",
    ]

    /// Build the suggestion list. Returns an empty list when the context
    /// can't be completed (or the partial value matches nothing).
    /// Internal visibility — `QuerySuggestion` (declared in
    /// `QuerySuggestionsPopover.swift`) is internal, and Swift 6 requires
    /// matching visibility. (Was `public`; downgraded by features-agent to
    /// unblock the build during the reveal-in-Messages work — see plans.md.)
    static func suggestions(
        for context: AutocompleteContext,
        contacts: [Contact],
        chats: [ChatInfo]
    ) -> [QuerySuggestion] {
        switch context.prefix {
        case .chat, .in:
            return chatSuggestions(partial: context.partialValue, chats: chats)
        case .with:
            // `with:` accepts a person's name — scopes the search to any
            // chat (1:1 or group) that person participates in. Use the
            // person suggester so contacts auto-complete cleanly.
            return personSuggestions(partial: context.partialValue, contacts: contacts)
        case .from:
            return personSuggestions(
                partial: context.partialValue,
                contacts: contacts,
                includeMe: true
            )
        case .to:
            return personSuggestions(partial: context.partialValue, contacts: contacts)
        case .before, .after, .on, .last:
            return dateSuggestions(partial: context.partialValue)
        case .reactions:
            return reactionSuggestions(partial: context.partialValue)
        case .type:
            return typeSuggestions(partial: context.partialValue)
        }
    }

    // MARK: - chat / in

    static func chatSuggestions(partial: String, chats: [ChatInfo]) -> [QuerySuggestion] {
        let labels = chats.map(\.label)
        // Use a Set for de-dup — multiple chats can share a name (rare but
        // possible — e.g. two 1:1s with the same contact across handles).
        var seen: Set<String> = []
        var ranked: [String] = []
        for label in QueryAutocomplete.rank(labels, partial: partial, limit: maxSuggestions * 2) {
            if seen.insert(label).inserted {
                ranked.append(label)
            }
            if ranked.count >= maxSuggestions { break }
        }
        return ranked.enumerated().map { idx, value in
            QuerySuggestion(id: idx, value: value, kind: .chat, subtitle: nil)
        }
    }

    // MARK: - from / to

    static func personSuggestions(
        partial: String,
        contacts: [Contact],
        includeMe: Bool = false
    ) -> [QuerySuggestion] {
        // `me` is offered only for `from:` (not `to:`) — it expands to
        // `is_from_me = 1`. We prepend it when the partial value is empty
        // or prefix-matches "me" so it stays in front of any contact named
        // "Melissa" etc.
        var leading: [QuerySuggestion] = []
        if includeMe {
            let p = partial.lowercased()
            if p.isEmpty || "me".hasPrefix(p) {
                leading.append(QuerySuggestion(
                    id: -1, value: "me", kind: .person,
                    subtitle: "messages you sent"
                ))
            }
        }

        let names = contacts.map(\.displayName)
        let remaining = max(0, maxSuggestions - leading.count)
        let ranked = QueryAutocomplete.rank(names, partial: partial, limit: remaining)
        let tail: [QuerySuggestion] = ranked.enumerated().map { idx, value in
            // Build a subtitle from the first 1-2 handles of that contact so
            // the user can disambiguate e.g. multiple "Alex Chen"s.
            var subtitle: String? = nil
            if let c = contacts.first(where: { $0.displayName == value }) {
                let handles = Array(c.handles.prefix(2)).map(\.normalized)
                if !handles.isEmpty {
                    subtitle = handles.joined(separator: " · ")
                }
            }
            return QuerySuggestion(id: idx, value: value, kind: .person, subtitle: subtitle)
        }
        return leading + tail
    }

    // MARK: - date

    static func dateSuggestions(partial: String) -> [QuerySuggestion] {
        let ranked = QueryAutocomplete.rank(dateSuggestions, partial: partial, limit: maxSuggestions)
        return ranked.enumerated().map { idx, value in
            QuerySuggestion(id: idx, value: value, kind: .date, subtitle: nil)
        }
    }

    // MARK: - reactions

    static func reactionSuggestions(partial: String) -> [QuerySuggestion] {
        let ranked = QueryAutocomplete.rank(reactionSuggestions, partial: partial, limit: maxSuggestions)
        return ranked.enumerated().map { idx, value in
            QuerySuggestion(id: idx, value: value, kind: .reaction, subtitle: subtitle(forReaction: value))
        }
    }

    private static func subtitle(forReaction value: String) -> String? {
        switch value {
        case ">=1": return "at least 1 reaction"
        case ">=3": return "at least 3 reactions"
        case ">=5": return "at least 5 reactions"
        case ">=10": return "at least 10 reactions"
        case "any": return "messages with any reaction"
        case "love": return "❤️ loved"
        case "like": return "👍 liked"
        case "laugh": return "😂 laughed"
        case "emphasize": return "‼️ emphasized"
        case "question": return "❓ questioned"
        case "dislike": return "👎 disliked"
        default: return nil
        }
    }

    // MARK: - type

    static func typeSuggestions(partial: String) -> [QuerySuggestion] {
        let ranked = QueryAutocomplete.rank(typeSuggestions, partial: partial, limit: maxSuggestions)
        return ranked.enumerated().map { idx, value in
            QuerySuggestion(id: idx, value: value, kind: .type, subtitle: subtitle(forType: value))
        }
    }

    private static func subtitle(forType value: String) -> String? {
        switch value {
        case "image": return "photos · image/*"
        case "video": return "videos · video/*"
        case "audio": return "voice notes · audio/*"
        case "sticker": return "peel-and-stick stickers"
        case "link": return "URL link previews"
        case "file": return "PDFs, docs, other files"
        case "text": return "plain text only — no attachments"
        case "attachment": return "any non-text content"
        default: return nil
        }
    }
}
