//
//  QueryAutocomplete.swift
//  Hourglass
//
//  Pure logic for query autocomplete. Given a query string and a caret
//  position, decide what suggestions to offer.
//
//  Why a separate file?
//    - Trivial to unit test (no SwiftUI, no DB, no clock).
//    - Reused by the popover view + future inline highlighting.
//    - Keeps `MessageSearch` focused on running searches, not editing them.
//
//  The grammar this matches must stay in sync with `MessageSearch.parseQuery`.
//  Add a new prefix here AND there together — there's no shared list (yet).
//

import Foundation

/// Result of analyzing a query at the caret. If `prefix == nil`, the caret is
/// not inside a token we know how to autocomplete and the popover should hide.
public struct AutocompleteContext: Equatable, Sendable {
    /// The token prefix (lowercased, including the colon), e.g. `from:`.
    public let prefix: TokenPrefix
    /// The partial value the user has typed AFTER the colon, possibly empty.
    /// Stripped of surrounding quotes if any.
    public let partialValue: String
    /// The substring range of the WHOLE token (`<prefix><partial>` plus any
    /// quotes/closing-quote) in the original query string. Used to replace
    /// the token when the user accepts a suggestion.
    public let tokenRange: Range<String.Index>
    /// Whether the partial value is inside a quoted string. Affects how we
    /// emit the replacement (and the parser will understand the quotes).
    public let isQuoted: Bool
}

/// All token prefixes we recognize in the query language. Used by both the
/// parser (`MessageSearch.parseQuery`) and the autocomplete UI.
///
/// Adding a new one? Add it here, add it in `MessageSearch.parseQuery`, and
/// add a SQL clause that consumes its values.
public enum TokenPrefix: String, CaseIterable, Sendable, Hashable {
    case chat = "chat:"
    case `in` = "in:"
    /// `with:"Name"` — scope to **any chat (1:1 OR group) that the named
    /// person participates in**. Different from `chat:`/`in:` which match
    /// either a chat's `display_name` substring OR a 1:1 chat by its
    /// participant (no group-by-participant matching). Different from
    /// `from:`/`to:` which restrict by sender direction (received vs.
    /// sent).
    case with = "with:"
    case from = "from:"
    case to = "to:"
    case before = "before:"
    case after = "after:"
    case on = "on:"
    case last = "last:"
    /// Reaction filter — accepts comparators (`>=3`, `<=1`, `>0`, `5`),
    /// the literal `any`, or a kind name (`love`, `like`, `laugh`,
    /// `emphasize`, `question`, `dislike`). See `MessageSearch.parseQuery`.
    case reactions = "reactions:"
    /// Content-type filter — `image`, `video`, `audio`, `sticker`, `link`,
    /// `file`, `text`, `attachment`. See `MessageSearch.TypeFilter`.
    case type = "type:"

    /// Display category for tinting/icons in the chip layer.
    public var category: TokenCategory {
        switch self {
        case .chat, .in, .with: return .chat
        case .from, .to: return .person
        case .before, .after, .on, .last: return .date
        case .reactions: return .reaction
        case .type: return .type
        }
    }

    /// All prefixes that start with the given lowercased substring. Used by
    /// the popover to suggest token prefixes themselves once the user types
    /// e.g. just "fr".
    public static func matching(_ partial: String) -> [TokenPrefix] {
        guard !partial.isEmpty else { return [] }
        let lower = partial.lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(lower) }
    }
}

/// Coarse-grained category for chip tinting in the UI.
public enum TokenCategory: Sendable, Hashable {
    case chat, person, date, reaction, type
}

public enum QueryAutocomplete {

    /// Analyze the query at the caret. Returns nil when no completable token
    /// is at the caret position (free text, no token-prefix typed yet, etc.).
    ///
    /// MVP shortcut for the call site: when you don't have caret info, pass
    /// `query.endIndex` — autocomplete will be driven by the LAST token typed,
    /// which matches "user is currently typing at the end" intuition.
    public static func analyze(
        query: String,
        caret: String.Index? = nil
    ) -> AutocompleteContext? {
        let caretIdx = caret ?? query.endIndex

        // Compute the quote state at each position via a single left-to-right
        // pass: `inQuote[i]` is true iff the character at position `i` is
        // INSIDE a quoted span (i.e. an even-numbered following quote will
        // close it). Walking left from caret without this would break on a
        // partial-open quote — `chat:"Amme Sat` would stop at the space
        // between "Amme" and "Sat" because the left-scan never sees the
        // opening `"` to flip its state.
        var inQuote = [Bool]()
        inQuote.reserveCapacity(query.count)
        var state = false
        for ch in query {
            if ch == "\"" { state.toggle() }
            inQuote.append(state)
        }

        // Find the start of the token containing the caret: walk left from
        // caret to either string start or the previous unquoted whitespace.
        var i = caretIdx
        while i > query.startIndex {
            let before = query.index(before: i)
            let offset = query.distance(from: query.startIndex, to: before)
            let ch = query[before]
            if ch.isWhitespace && !inQuote[offset] {
                break
            }
            i = before
        }
        let tokenStart = i

        // Find the end of the token: walk right from caret until unquoted
        // whitespace or string end.
        var j = caretIdx
        while j < query.endIndex {
            let ch = query[j]
            let offset = query.distance(from: query.startIndex, to: j)
            if ch.isWhitespace && !inQuote[offset] {
                break
            }
            j = query.index(after: j)
        }
        let tokenEnd = j

        let token = String(query[tokenStart..<tokenEnd])
        guard !token.isEmpty else { return nil }

        // Match a known prefix (case-insensitive).
        let lower = token.lowercased()
        for prefix in TokenPrefix.allCases where lower.hasPrefix(prefix.rawValue) {
            var value = String(token.dropFirst(prefix.rawValue.count))
            var quoted = false
            if value.hasPrefix("\"") {
                quoted = true
                value.removeFirst()
                if value.hasSuffix("\"") {
                    value.removeLast()
                }
            }
            return AutocompleteContext(
                prefix: prefix,
                partialValue: value,
                tokenRange: tokenStart..<tokenEnd,
                isQuoted: quoted
            )
        }
        return nil
    }

    /// Replace the active token in `query` with `prefix + value`. Quotes the
    /// value if it contains whitespace. Returns the new query string AND the
    /// caret position to set after replacement (just past the inserted token).
    public static func apply(
        suggestion value: String,
        to query: String,
        in context: AutocompleteContext
    ) -> (newQuery: String, caret: String.Index) {
        let needsQuotes = value.contains(where: { $0.isWhitespace })
        let body = needsQuotes ? "\"\(value)\"" : value
        let replacement = context.prefix.rawValue + body

        var newQuery = query
        newQuery.replaceSubrange(context.tokenRange, with: replacement)

        // Compute the new caret position. The replacement starts at
        // context.tokenRange.lowerBound; the new caret is that + replacement length.
        // We translate back to a String.Index in the new string.
        let lowerOffset = query.distance(from: query.startIndex, to: context.tokenRange.lowerBound)
        let newCaret = newQuery.index(newQuery.startIndex, offsetBy: lowerOffset + replacement.count)
        return (newQuery, newCaret)
    }

    /// Substring-match `values` against `partial` (case-insensitive). Returns
    /// up to `limit` matches, prefix-matches first, then substring matches.
    public static func rank(
        _ values: [String],
        partial: String,
        limit: Int = 10
    ) -> [String] {
        guard !values.isEmpty else { return [] }
        if partial.isEmpty { return Array(values.prefix(limit)) }
        let lower = partial.lowercased()
        var prefixHits: [String] = []
        var substringHits: [String] = []
        for v in values {
            let vlow = v.lowercased()
            if vlow.hasPrefix(lower) {
                prefixHits.append(v)
            } else if vlow.contains(lower) {
                substringHits.append(v)
            }
            if prefixHits.count >= limit { break }
        }
        let combined = prefixHits + substringHits
        return Array(combined.prefix(limit))
    }
}
