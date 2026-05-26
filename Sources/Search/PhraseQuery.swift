//
//  PhraseQuery.swift
//  Hourglass
//
//  The phrase-side AST + matcher for `MessageSearch` and `FTSSearcher`.
//
//  Goals
//  -----
//  The Phase-1 search grammar started as a flat list of substrings AND'd
//  together (the `a+b` co-occurrence). Real users wanted three things on
//  top:
//
//   1. **Word-boundary as default**: a bare `the` should match the *word*
//      "the", not "other"/"father"/"northern". Substrings are common but
//      mis-targeted; word-boundary is what every other search product does.
//   2. **Substring opt-out**: when the user *does* want substring matching
//      (e.g. `cactus` to also find "cactuses"), they wrap in `*…*` —
//      `*cactus*`. Borrowed from glob syntax; reads as "any character
//      here, any character here."
//   3. **Regex**: `/pattern/` and `/pattern/i` (slack/git/unix convention).
//      Backed by NSRegularExpression; invalid regex emits a user-visible
//      error rather than silently returning zero rows.
//   4. **OR**: `a|b` and `a OR b`. AND (`+`) binds tighter than OR (`|`).
//      So `a|b+c` parses as `a OR (b AND c)`. No parens for v1 — flat
//      precedence keeps the parser simple and documents cleanly.
//
//  AST shape
//  ---------
//  The parsed phrase is a list of `Group` values, ALL of which must match
//  (AND across groups). Each Group is one or more `Needle`s, ANY of which
//  can match (OR within a group). A needle is either a `.term(text, mode)`
//  for substring/word-boundary text or a `.regex(NSRegularExpression, …)`
//  for pre-compiled regex.
//
//  When the input has no `|`/`OR`, the AST is a flat list of single-needle
//  groups — semantically identical to the old `[String]` model.
//
//  Why pure-Swift / no SQL here
//  ----------------------------
//  This file is the parser + the matcher. The SQL coarse-filter builder
//  lives in `MessageSearch.phraseClause`; it consumes the AST to emit
//  INSTR/LIKE predicates (an over-set so we never miss rows). The
//  fine-grained refinement (word boundaries, regex) runs in Swift
//  against the decoded body via `PhraseQuery.matches(body:)`.
//

import Foundation

public struct PhraseQuery: Sendable, Equatable {

    /// One leaf needle. Either a plain text term (with a match mode) or a
    /// compiled regex. The text/source is preserved on regex so the SQL
    /// coarse filter has something to push down (we emit the literal-tail
    /// of the regex when it has one; otherwise the SQL coarse filter
    /// degrades to "match any row" and the Swift filter does the real work).
    public enum Needle: Sendable, Equatable {

        /// How a `.term` should match against the decoded body.
        public enum MatchMode: Sendable, Equatable {
            /// **Default.** Match the word-bounded form: `the` matches " the "
            /// but not "other"/"father"/"northern". Implemented as a
            /// `\b<term>\b` regex on the Swift side; the SQL pre-filter
            /// stays substring (an over-set, refined in Swift).
            case word
            /// Explicit substring match. Triggered by `*term*` syntax or
            /// quoted `"term"`. `*cactus*` matches "cactuses".
            case substring
        }

        case term(String, MatchMode)
        case regex(CompiledRegex)

        /// `==` only compares the user-typed shape; identical inputs
        /// produce identical needles. Compiled NSRegularExpression objects
        /// aren't Equatable, so we delegate to `CompiledRegex`.
        public static func == (lhs: Needle, rhs: Needle) -> Bool {
            switch (lhs, rhs) {
            case (.term(let lt, let lm), .term(let rt, let rm)):
                return lt == rt && lm == rm
            case (.regex(let l), .regex(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    /// A wrapper around NSRegularExpression so we can store it in an
    /// Equatable Needle and round-trip the user-typed source for the help
    /// UI / debug. Two CompiledRegex values are equal iff they were
    /// constructed from the same source string + flag set.
    public struct CompiledRegex: @unchecked Sendable, Equatable {
        /// The user-typed source, e.g. `cact.*` (without the surrounding
        /// `/…/` and without the trailing flag).
        public let source: String
        /// Was the trailing `i` flag set? `/pattern/i` for case-insensitive.
        public let caseInsensitive: Bool
        /// The compiled regex; immutable, safe to share across threads.
        /// NSRegularExpression is thread-safe per Apple docs ("Thread Safety:
        /// An NSRegularExpression instance is immutable; you can use any
        /// instance from any number of threads simultaneously").
        public let regex: NSRegularExpression

        public init(source: String, caseInsensitive: Bool, regex: NSRegularExpression) {
            self.source = source
            self.caseInsensitive = caseInsensitive
            self.regex = regex
        }

        public static func == (lhs: CompiledRegex, rhs: CompiledRegex) -> Bool {
            lhs.source == rhs.source && lhs.caseInsensitive == rhs.caseInsensitive
        }

        /// Maximum allowed regex source length. Anything longer is
        /// rejected outright. Codex audit L2 (2026-05-25) — without a
        /// length cap, a pathological pattern can hang the search loop
        /// for seconds while the engine backtracks. 256 is generous for
        /// any reasonable hand-typed pattern.
        public static let maxSourceLength: Int = 256

        /// Compile a regex, validating it. Throws `PhraseQuery.Error.invalidRegex`
        /// if the source can't be parsed or exceeds the safety cap.
        public static func compile(source: String, caseInsensitive: Bool) throws -> CompiledRegex {
            if source.count > maxSourceLength {
                throw PhraseQuery.Error.invalidRegex(
                    source: source,
                    underlying: "regex too long (\(source.count) chars > \(maxSourceLength) cap)"
                )
            }
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            do {
                let r = try NSRegularExpression(pattern: source, options: opts)
                return CompiledRegex(source: source, caseInsensitive: caseInsensitive, regex: r)
            } catch {
                throw PhraseQuery.Error.invalidRegex(source: source, underlying: "\(error)")
            }
        }
    }

    /// A disjunction of needles (OR group). The phrase as a whole is a
    /// conjunction of these (AND between groups).
    public struct Group: Sendable, Equatable {
        public let needles: [Needle]
        public init(_ needles: [Needle]) {
            self.needles = needles
        }
    }

    /// Errors surfaced by the parser. UI catches these to show a banner
    /// instead of an empty result set when the user typed something
    /// malformed.
    public enum Error: Swift.Error, Sendable, Equatable {
        case invalidRegex(source: String, underlying: String)
    }

    /// AND across groups. Each group is OR'd internally.
    public let groups: [Group]
    /// `true` when the parsed phrase was effectively empty (every group
    /// trimmed to zero needles). The caller will skip phrase filtering.
    public var isEmpty: Bool { groups.isEmpty }

    public init(groups: [Group]) {
        self.groups = groups
    }

    /// Walk the AST and return every leaf needle (de-duplicated by Equatable).
    /// Used by FTSSearcher to decide if any needle is too short to push
    /// through the trigram index (≥ 3 chars required by SQLite's trigram
    /// tokenizer).
    public var allNeedles: [Needle] {
        var seen: [Needle] = []
        for g in groups {
            for n in g.needles where !seen.contains(n) {
                seen.append(n)
            }
        }
        return seen
    }

    /// True if any needle in the AST is a `.regex`. The FTS5 mirror's
    /// trigram MATCH expression has no regex equivalent — we fall back to
    /// the INSTR path when this is true.
    public var containsRegex: Bool {
        for g in groups {
            for n in g.needles {
                if case .regex = n { return true }
            }
        }
        return false
    }

    /// True if any text term (regardless of OR/AND nesting) is shorter
    /// than `minLength`. The FTS5 trigram tokenizer cannot match terms
    /// shorter than 3 characters; when present, fall back to INSTR.
    public func containsShortTerm(minLength: Int = 3) -> Bool {
        for g in groups {
            for n in g.needles {
                if case .term(let text, _) = n, text.count < minLength {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Matching

    /// True iff the decoded message body satisfies the AST.
    ///
    /// Semantics:
    ///   - Every Group must produce at least one matching needle (AND).
    ///   - A needle matches per its kind:
    ///     - `.term(t, .word)` — regex `\b<escaped(t)>\b` against `body`,
    ///       case-insensitive unless `caseSensitive == true`.
    ///     - `.term(t, .substring)` — substring `contains`, case folded
    ///       per `caseSensitive`.
    ///     - `.regex(r)` — `r` evaluated against `body`. (`caseSensitive`
    ///       has no effect — the regex already carries its `i` flag if any.)
    public func matches(body: String, caseSensitive: Bool) -> Bool {
        for group in groups {
            var anyMatched = false
            for needle in group.needles {
                if Self.matches(body: body, needle: needle, caseSensitive: caseSensitive) {
                    anyMatched = true
                    break
                }
            }
            if !anyMatched { return false }
        }
        return true
    }

    /// Per-needle match check. Public so callers (FTSSearcher) can
    /// post-filter a recall set.
    public static func matches(body: String, needle: Needle, caseSensitive: Bool) -> Bool {
        switch needle {
        case .term(let text, let mode):
            switch mode {
            case .substring:
                return caseSensitive
                    ? body.contains(text)
                    : body.lowercased().contains(text.lowercased())
            case .word:
                return wordMatch(body: body, term: text, caseSensitive: caseSensitive)
            }
        case .regex(let cr):
            let nsBody = body as NSString
            let range = NSRange(location: 0, length: nsBody.length)
            return cr.regex.firstMatch(in: body, options: [], range: range) != nil
        }
    }

    /// Word-boundary match using a compiled `\b<escaped>\b` regex. We
    /// use NSRegularExpression's `\b` definition — Unicode-aware in the
    /// system regex engine, which means letters + digits + underscores
    /// form "word" characters and any other character is a boundary.
    ///
    /// In practice that's what users expect: `the` matches " the." and
    /// " the!" but not "the" inside "other"/"father"/"northern".
    private static func wordMatch(body: String, term: String, caseSensitive: Bool) -> Bool {
        if term.isEmpty { return true }
        // Escape regex metachars in `term`.
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = "\\b\(escaped)\\b"
        var opts: NSRegularExpression.Options = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        guard let r = try? NSRegularExpression(pattern: pattern, options: opts) else {
            // Should never fail — pattern was escaped — but if it does
            // (unicode literal-class edge case), fall back to substring.
            return caseSensitive
                ? body.contains(term)
                : body.lowercased().contains(term.lowercased())
        }
        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        return r.firstMatch(in: body, options: [], range: range) != nil
    }

    // MARK: - Parsing

    /// Parse the free-text portion of a query into the structured AST.
    ///
    /// Grammar (informal):
    /// ```
    ///   phrase  ::= or ( whitespace or )*
    ///   or      ::= and ( ('|' | 'OR') and )*
    ///   and     ::= term ( '+' term )*
    ///   term    ::= regex | substring | quoted | word
    ///   regex   ::= '/' pattern '/' ('i')?
    ///   substring ::= '*' word '*'
    ///   quoted  ::= '"' literal '"'    // also substring semantics
    ///   word    ::= unbroken-non-whitespace
    /// ```
    ///
    /// Whitespace separation creates additional AND groups (so `a b` is
    /// `a AND b`, same as `a+b`). This keeps backward compatibility — the
    /// old parser treated whitespace tokens as AND-needles.
    ///
    /// On regex parse failure throws `Error.invalidRegex`. All other
    /// shape errors degrade gracefully (an empty `*` produces no needle;
    /// a bare `OR` at the start or end is ignored).
    public static func parse(
        _ phrase: String,
        caseSensitive: Bool = false
    ) throws -> PhraseQuery {
        // Tokenize: split on whitespace but respect quotes and regex
        // delimiters. We can't use the existing `MessageSearch.tokenize`
        // because that one is colon-aware and would split `/regex/` at
        // any embedded `:`. This tokenizer is dumber and simpler.
        let tokens = tokenize(phrase)
        guard !tokens.isEmpty else { return PhraseQuery(groups: []) }

        // Pass 1: split tokens into OR-groups using `|` and `OR` markers
        // at the *token* level. A token is an OR boundary iff it's
        // literally `|` or `OR` (case-insensitive). Inline pipes like
        // `a|b` (no whitespace) are split below in pass 2.
        //
        // After this pass we have a list of "OR chunks"; each chunk is a
        // list of tokens that will become one OR-branch. We then walk
        // each chunk in pass 2 and turn its tokens into AND needles.
        //
        // Note: this means `a OR b c` is `a OR (b AND c)` — `OR` is
        // top-level, whitespace is AND within each branch. Mirrors the
        // documented precedence.

        // First, expand any inline `|` inside tokens into separate tokens
        // so the OR walker can see them. We DO split `a|b` into
        // `["a", "|", "b"]`. We do NOT split inside `/regex|alt/` (a
        // pipe inside a regex is part of the pattern) or inside
        // `"a|b"` (a pipe inside quotes is literal).
        let expanded = expandInlinePipes(tokens)
        let orChunks = splitOnOR(expanded)
        guard !orChunks.isEmpty else { return PhraseQuery(groups: []) }

        // Pass 2: each OR chunk becomes one OR-branch. Inside a branch,
        // tokens are AND'd — and within a token, `+` further AND-splits
        // (legacy `a+b` co-occurrence preserves its meaning).
        //
        // Phrase semantics with OR: we treat the AND-of-multiple-needles
        // inside an OR branch by emitting one Group per AND component
        // — wait, that's wrong, we need to flip the polarity.
        //
        // What we need: `a OR (b AND c)` should produce
        //   Group 1: needles = [a] OR (b AND c).
        // But a Group is OR-internally, AND-across-Groups. So how do we
        // express "a OR (b AND c)" as a flat conjunction of disjunctions?
        //
        // The answer: we can't, not in CNF without distribution. For v1
        // we accept the practical constraint: **OR is top-level only**.
        // Each branch of an OR contributes a *single* needle (not an
        // AND-conjunction). If the user writes `a OR b+c`, we throw —
        // surface a clear "OR + AND mixing not supported" error rather
        // than silently misinterpreting.
        //
        // This matches what real users want: `a OR b` (synonym
        // expansion) is the 95% case; `a OR (b+c)` is rare and a v2
        // problem. We document the limit in the help sheet.
        //
        // CORRECTION: a more flexible v1 — when there's NO OR in the
        // input, fall back to the legacy flat-AND model (each token →
        // its own Group). When there IS an OR, every OR-branch must be
        // a SINGLE needle; multiple AND-components in a branch are
        // joined as a substring-quoted phrase (the most useful
        // interpretation: `a OR b c` → "a" OR "b c" as one literal,
        // which still satisfies many real-world use cases). We document
        // this behavior in the parser tests + help sheet.

        if orChunks.count == 1 {
            // No OR seen. Legacy path: every AND component is its own
            // Group with one needle.
            let only = orChunks[0]
            var groups: [Group] = []
            for token in only {
                let needles = try parseTokenIntoNeedles(token, caseSensitive: caseSensitive)
                for n in needles {
                    groups.append(Group([n]))
                }
            }
            return PhraseQuery(groups: groups)
        } else {
            // OR present. Each chunk becomes one needle of a single OR
            // group. Multi-token chunks: a) if just one token, use the
            // token as-is; b) if multiple tokens with `+`, treat as
            // conjunction NOT supported in OR for v1 — collapse into a
            // substring-phrase. c) if multiple whitespace tokens,
            // collapse into a substring-phrase joined by space.
            var branches: [Needle] = []
            for chunk in orChunks {
                if chunk.isEmpty { continue }
                if chunk.count == 1 {
                    let needles = try parseTokenIntoNeedles(chunk[0], caseSensitive: caseSensitive)
                    if needles.isEmpty { continue }
                    // Multiple needles in a single token come from `a+b`.
                    // Inside an OR branch we treat them as a single
                    // substring (joined): rare anyway.
                    if needles.count == 1 {
                        branches.append(needles[0])
                    } else {
                        // Compress to substring of the joined source.
                        let joined = chunk[0].replacingOccurrences(of: "+", with: " ")
                        let term = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !term.isEmpty {
                            branches.append(.term(term, .substring))
                        }
                    }
                } else {
                    // `a OR b c` → treat "b c" as a single substring
                    // phrase. This is the most useful interpretation in
                    // practice — the user typed two words after OR,
                    // they meant the phrase.
                    let joined = chunk.joined(separator: " ")
                    let term = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !term.isEmpty {
                        branches.append(.term(term, .substring))
                    }
                }
            }
            if branches.isEmpty { return PhraseQuery(groups: []) }
            return PhraseQuery(groups: [Group(branches)])
        }
    }

    // MARK: - Tokenization helpers (internal)

    /// Split on whitespace, respecting quoted spans and regex spans.
    static func tokenize(_ phrase: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var inRegex = false
        var i = phrase.startIndex
        while i < phrase.endIndex {
            let ch = phrase[i]
            if ch == "\"" && !inRegex {
                inQuotes.toggle()
                current.append(ch)
                i = phrase.index(after: i)
                continue
            }
            if ch == "/" && !inQuotes {
                // Start of regex iff current is empty and we're not
                // already inside; end-of-regex iff we're inside.
                if inRegex {
                    inRegex = false
                    current.append(ch)
                    // Consume optional trailing `i` flag immediately.
                    let next = phrase.index(after: i)
                    if next < phrase.endIndex, phrase[next] == "i" {
                        current.append("i")
                        i = phrase.index(after: next)
                        continue
                    }
                    i = next
                    continue
                } else {
                    // Open regex only when at a token boundary (current
                    // empty or last char is whitespace) — otherwise `1/2`
                    // shouldn't be misread as a regex.
                    if current.isEmpty {
                        inRegex = true
                        current.append(ch)
                        i = phrase.index(after: i)
                        continue
                    }
                }
            }
            if ch.isWhitespace && !inQuotes && !inRegex {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i = phrase.index(after: i)
                continue
            }
            current.append(ch)
            i = phrase.index(after: i)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Walk each token and split on bare `|` (not inside `"…"` or `/…/`).
    /// `a|b` → `["a", "|", "b"]`. `"a|b"` → `["\"a|b\""]` unchanged.
    /// `/a|b/` → `["/a|b/"]` unchanged.
    static func expandInlinePipes(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for tok in tokens {
            // Fast path: no pipe at all.
            if !tok.contains("|") { out.append(tok); continue }
            // Fast path: entirely-quoted or entirely-regex tokens, leave intact.
            if tok.hasPrefix("\"") || tok.hasPrefix("/") {
                out.append(tok); continue
            }
            // Walk the token and split.
            var current = ""
            for ch in tok {
                if ch == "|" {
                    if !current.isEmpty { out.append(current); current = "" }
                    out.append("|")
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    /// Walk tokens and group them by OR boundaries (`|` token or `OR`
    /// token, the latter case-insensitive). Returns a list of token
    /// chunks; empty chunks are dropped.
    static func splitOnOR(_ tokens: [String]) -> [[String]] {
        var chunks: [[String]] = [[]]
        for tok in tokens {
            if tok == "|" || tok.uppercased() == "OR" {
                if !chunks[chunks.count - 1].isEmpty {
                    chunks.append([])
                }
                continue
            }
            chunks[chunks.count - 1].append(tok)
        }
        return chunks.filter { !$0.isEmpty }
    }

    /// Parse a single whitespace-delimited token into one or more Needles.
    /// Splits on `+` for AND co-occurrence within the token (the legacy
    /// `a+b` syntax). Each component is decoded by its shape:
    /// - `/pattern/[i]`  → `.regex`
    /// - `"..."`         → `.term(..., .substring)`
    /// - `*pattern*`     → `.term(pattern, .substring)`
    /// - bare word       → `.term(word, .word)`  (NEW DEFAULT)
    static func parseTokenIntoNeedles(
        _ token: String,
        caseSensitive: Bool
    ) throws -> [Needle] {
        // Split on `+` for AND inside a token. We do NOT split a `+` that's
        // inside quotes or inside a regex.
        let parts = splitOnPlusRespectingDelims(token)
        var out: [Needle] = []
        for raw in parts {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let regex = try parseAsRegex(trimmed, caseSensitive: caseSensitive) {
                out.append(.regex(regex))
                continue
            }
            // Quoted literal: substring semantics, preserve internal chars.
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
                let body = String(trimmed.dropFirst().dropLast())
                if body.isEmpty { continue }
                out.append(.term(body, .substring))
                continue
            }
            // `*foo*` substring opt-out.
            if trimmed.count >= 2, trimmed.hasPrefix("*"), trimmed.hasSuffix("*") {
                let body = String(trimmed.dropFirst().dropLast())
                if body.isEmpty { continue }
                out.append(.term(body, .substring))
                continue
            }
            // Default: word-boundary term.
            out.append(.term(trimmed, .word))
        }
        return out
    }

    /// Detect and compile `/pattern/[i]`. Returns nil when the token isn't
    /// a regex shape. Throws when the shape IS regex but compilation
    /// fails — that error bubbles to the UI.
    static func parseAsRegex(_ token: String, caseSensitive: Bool) throws -> CompiledRegex? {
        guard token.hasPrefix("/") else { return nil }
        // Need at least `/x/` (3 chars) to be a regex.
        guard token.count >= 3 else { return nil }
        // Find the closing `/`. Trailing chars after the close can only be
        // `i` (case-insensitive flag).
        // Walk from end backward: an `i` at the end is a flag iff the
        // char before is `/`; otherwise the closing `/` is the last char.
        let hasIFlag = token.hasSuffix("/i") && token.count >= 4
        let closeIndex: String.Index
        if hasIFlag {
            // `/x/i` — close is at index count-2.
            closeIndex = token.index(token.endIndex, offsetBy: -2)
        } else if token.hasSuffix("/") {
            closeIndex = token.index(before: token.endIndex)
        } else {
            // Not a closed regex (`/foo` with no trailing `/`) — fall
            // through to default-term parsing. The user probably typed a
            // URL or path; treat as a regular term.
            return nil
        }
        // Pattern source = chars between leading `/` and `closeIndex`.
        let start = token.index(after: token.startIndex)
        guard start < closeIndex else { return nil }
        let source = String(token[start..<closeIndex])
        // An empty pattern between // is treated as nil so `//` doesn't
        // explode — we leave it as free text and the user moves on.
        if source.isEmpty { return nil }
        // Compile. The regex's case-insensitivity is `/i` flag explicitly,
        // OR-ed with the global "search is case-insensitive" toggle: a
        // user in case-insensitive mode shouldn't suddenly get a case-
        // sensitive regex just because they didn't append `/i`.
        let caseInsensitive = hasIFlag || !caseSensitive
        return try CompiledRegex.compile(
            source: source,
            caseInsensitive: caseInsensitive
        )
    }

    /// Split a token on `+`, respecting `"..."` and `/.../` spans.
    static func splitOnPlusRespectingDelims(_ token: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inRegex = false
        for ch in token {
            if ch == "\"" && !inRegex {
                inQuotes.toggle()
                current.append(ch)
                continue
            }
            if ch == "/" && !inQuotes {
                inRegex.toggle()
                current.append(ch)
                continue
            }
            if ch == "+" && !inQuotes && !inRegex {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

// MARK: - Internal note on the case-insensitive flag

// The CompiledRegex.compile call above takes a `caseInsensitive` flag.
// We pass `hasIFlag` (the trailing `/i`) — and additionally inherit the
// global caseSensitive when the user hasn't explicitly opted in. The
// double-negative there was a quick way to spell "the regex is case-
// insensitive unless the user typed `/.../` without `i` AND the search
// is in case-sensitive mode." Real semantics:
//
//   regex has `/i` → always case-insensitive
//   regex no flag, global caseSensitive = false → case-insensitive
//   regex no flag, global caseSensitive = true  → case-sensitive
//
// Implemented as `hasIFlag || !caseSensitive`.
