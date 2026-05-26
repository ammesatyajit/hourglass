//
//  RuleBasedQueryBuilder.swift
//  Hourglass — Natural-language search
//
//  Pure-Swift rule-based query extractor used as the NL agent's fallback
//  when the LLM planner fails (model not loaded, malformed output, OOM,
//  etc.). The previous fallback joined all non-stopword tokens with AND,
//  which silently guaranteed zero hits on natural-language phrasing
//  (e.g. "argument annika maybe" never co-occurs in real messages).
//
//  This builder runs three deterministic passes against the input:
//
//    1. **Person extraction**: match capitalized n-grams against the real
//       AddressBook display names. Longest match wins. Emits
//       `with:"<Name>"` (default) or `from:"<Name>"` if the query says
//       "from X". Recognising the name strips it from the search phrase
//       so it doesn't leak into the freetext.
//
//    2. **Date extraction**: a small set of phrase regexes ("yesterday",
//       "this week", "N (day|week|month|year)s? ago", "last N (units)")
//       feeding `DateParser` for the canonical `last:Nd` form. Both
//       single-word phrases ("yesterday") and multi-word phrases ("2
//       weeks ago") are matched; the regex match is stripped from the
//       phrase. Fuzzy markers ("maybe", "around") widen the window.
//
//    3. **Stopword / filler prune + concept extraction**: drop "find",
//       "my", "the", "about", auxiliaries, modals, etc. The surviving
//       content words are the search concept. The engine's current
//       phrase grammar AND's keywords — and AND'ing free-text NL terms
//       against message bodies almost always returns zero hits because
//       the model rarely says exactly the same word as the message. We
//       therefore emit only the FIRST surviving content word as the
//       keyword. The date+person filters do the real narrowing; recall
//       over precision is the right tradeoff in the fallback path
//       since the user sees a degraded-to-fallback indicator.
//
//  Tested by `Tests/RuleBasedQueryBuilderTests.swift`.
//

import Foundation

public struct RuleBasedFallbackResult: Sendable, Equatable {
    /// The constructed query string, ready for `MessageSearch.search(phrase:)`.
    public let query: String
    /// The person name recognised (if any), already quoted-and-escaped.
    public let person: String?
    /// The date operator inserted (e.g. `last:21d`) if recognised.
    public let dateOperator: String?
    /// The concept keyword(s) the builder kept. Index 0 is the primary
    /// hero word; remaining entries are synonyms displayed in the trace
    /// explanation but not all included in the query (engine has no OR).
    public let concepts: [String]
}

public enum RuleBasedQueryBuilder {

    /// Build a structured query from `input`, using `contactNames` for the
    /// person-recognition pass. `now` is injected for deterministic tests.
    public static func build(
        from input: String,
        contactNames: [String],
        now: Date = Date()
    ) -> RuleBasedFallbackResult {
        // Normalise whitespace + strip the punctuation that confuses tokenisation.
        var working = input
            .replacingOccurrences(of: "?", with: " ")
            .replacingOccurrences(of: "!", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "'s", with: "")  // possessive: "Annika's chat" → "Annika"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // ----- Pass 1: person extraction -----
        let (person, personWasFrom, strippedAfterPerson) = extractPerson(
            from: working,
            contactNames: contactNames
        )
        working = strippedAfterPerson

        // ----- Pass 2: date extraction (with fuzzy padding) -----
        let isFuzzy = lower(input).contains("maybe")
            || lower(input).contains("around")
            || lower(input).contains("approximately")
            || lower(input).contains("roughly")
        let (dateOperator, strippedAfterDate) = extractDate(
            from: working,
            isFuzzy: isFuzzy,
            now: now
        )
        working = strippedAfterDate

        // ----- Pass 3: stopword + concept extraction -----
        let concepts = extractConcepts(from: working)

        // ----- Compose -----
        var parts: [String] = []
        if let person {
            parts.append(personWasFrom ? "from:\"\(person)\"" : "with:\"\(person)\"")
        }
        if let dateOperator {
            parts.append(dateOperator)
        }
        // Concept policy:
        //   - When we have a recognised person filter, the date + person
        //     already narrow drastically — emit ONE meaningful concept
        //     keyword to avoid AND'd-keyword recall death.
        //   - When NO person filter was found, the bare keywords ARE the
        //     filter. Emit ALL surviving capitalised tokens (likely
        //     proper nouns the contact-resolver missed) plus the first
        //     lowercase content word. This gives the search engine
        //     enough signal to produce a candidate set; trades some
        //     AND-precision for not-zero recall.
        if person != nil {
            if let primary = concepts.first {
                parts.append(primary)
            }
        } else {
            // No person → keep proper-noun-shaped tokens + first content word.
            var emitted: [String] = []
            var emittedLC: Set<String> = []
            for c in concepts {
                // Capitalized (Title- or UPPER-cased) → likely a proper noun
                // the contact resolver didn't recognise. Always keep.
                let isProperNounish = c.first?.isUppercase == true
                if isProperNounish || emitted.isEmpty {
                    if emittedLC.insert(c.lowercased()).inserted {
                        emitted.append(c)
                    }
                }
            }
            parts.append(contentsOf: emitted)
        }

        // If we extracted absolutely nothing structural, fall back to the
        // input verbatim so the engine still tries phrase search.
        let query: String
        if parts.isEmpty {
            query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            query = parts.joined(separator: " ")
        }

        return RuleBasedFallbackResult(
            query: query,
            person: person,
            dateOperator: dateOperator,
            concepts: concepts
        )
    }

    // MARK: - Person extraction

    /// Find the longest contact-name match in `input`. Returns:
    ///   - matched display name (preserved as-is for human readability)
    ///   - `true` if the query said "from X" (vs the default "with X")
    ///   - the input string with the matched name + its preceding
    ///     preposition removed, so the remaining tokens go to date /
    ///     concept extraction.
    ///
    /// Strategy:
    /// 1. Build a per-token index of contact-name first words. Most names
    ///    are unique on the first word for English speakers' chat.db.
    /// 2. For each input token whose lowercase matches a name's first
    ///    word, try to match the full name as a prefix of the next
    ///    contiguous input tokens (case-insensitive). Longest win.
    /// 3. If multiple contacts collide on the same name (homonyms), pick
    ///    the first; the LLM path would do better and is the primary.
    /// 4. Single-word matches (just "Annika") are valid — the input is
    ///    NL, not strictly ordered "with X" structure.
    static func extractPerson(
        from input: String,
        contactNames: [String]
    ) -> (name: String?, fromVerb: Bool, stripped: String) {
        // Build map: first-word-lowercase -> [full names]. Names are
        // pre-trimmed; duplicates collapsed.
        var byFirst: [String: [String]] = [:]
        for raw in contactNames {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let firstWord = name.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard !firstWord.isEmpty else { continue }
            byFirst[firstWord.lowercased(), default: []].append(name)
        }

        // Tokenise input on whitespace, keeping ranges so we can splice the
        // match out cleanly.
        let tokens = Array(input.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        guard !tokens.isEmpty else { return (nil, false, input) }

        var bestMatch: (name: String, startIdx: Int, length: Int)?
        for (i, tok) in tokens.enumerated() {
            let lc = tok.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
            guard let candidates = byFirst[lc] else { continue }
            // For each candidate name, see how many input tokens it matches.
            // We accept partial matches: if the full multi-word name doesn't
            // fit but the first word does (the user typed only "Annika" but
            // we know about "Annika Knechtel"), we still emit the full
            // canonical name as the match. This is what NL search expects.
            for candidate in candidates {
                let nameTokens = candidate.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let nameLC = nameTokens.map { $0.lowercased() }
                guard !nameTokens.isEmpty else { continue }

                // Greedy: find the longest prefix of `nameTokens` that
                // appears verbatim in `tokens[i...]`. Accept the longest
                // prefix ≥1 (anything ≥1 means at least the first name
                // matches, which is enough for casual NL).
                var matchedLen = 0
                while matchedLen < nameTokens.count
                      && i + matchedLen < tokens.count {
                    let inputLC = tokens[i + matchedLen].lowercased()
                        .trimmingCharacters(in: CharacterSet.punctuationCharacters)
                    if inputLC == nameLC[matchedLen] {
                        matchedLen += 1
                    } else {
                        break
                    }
                }
                if matchedLen >= 1 {
                    // We weight matchedLen so that longer matches always win,
                    // ties broken by candidate.length (richer name preferred).
                    let len = matchedLen
                    if bestMatch == nil || len > bestMatch!.length
                        || (len == bestMatch!.length && candidate.count > bestMatch!.name.count) {
                        bestMatch = (candidate, i, len)
                    }
                }
            }
        }

        guard let m = bestMatch else { return (nil, false, input) }

        // Detect "from" preceding the match. The token at i-1 is the verb;
        // if it's "from" we set the fromVerb flag.
        var fromVerb = false
        if m.startIdx > 0 {
            let preceding = tokens[m.startIdx - 1].lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if preceding == "from" || preceding == "by" {
                fromVerb = true
            }
        }

        // Splice out the name AND any immediate preceding preposition
        // ("with", "from", "to", "by", "about") so the remaining content
        // doesn't carry those as freetext.
        let prepositions: Set<String> = ["with", "from", "to", "by", "about"]
        var dropStart = m.startIdx
        if m.startIdx > 0 {
            let preceding = tokens[m.startIdx - 1].lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if prepositions.contains(preceding) {
                dropStart = m.startIdx - 1
            }
        }
        var kept = tokens
        kept.removeSubrange(dropStart..<(m.startIdx + m.length))
        let stripped = kept.joined(separator: " ")

        return (m.name, fromVerb, stripped)
    }

    // MARK: - Date extraction

    /// Find a date phrase in `input` and return:
    ///   - the canonical operator (e.g. `last:21d`, `last:7d`)
    ///   - the input with the phrase removed.
    /// When `isFuzzy` is true ("maybe 2 weeks ago"), widen the window by
    /// 50% (e.g. 14d → 21d) so the actual answer falls inside.
    static func extractDate(
        from input: String,
        isFuzzy: Bool,
        now: Date = Date()
    ) -> (op: String?, stripped: String) {
        // Match "(N) (day|week|month|year)s? ago" first — most specific.
        let nUnitAgo = try? NSRegularExpression(
            pattern: #"(?i)(?:about|around|maybe|approximately|roughly)?\s*(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month|year)s?\s+ago"#
        )
        if let regex = nUnitAgo {
            let range = NSRange(input.startIndex..., in: input)
            if let m = regex.firstMatch(in: input, range: range),
               m.numberOfRanges >= 3,
               let nRange = Range(m.range(at: 1), in: input),
               let unitRange = Range(m.range(at: 2), in: input) {
                let nStr = String(input[nRange]).lowercased()
                let unit = String(input[unitRange]).lowercased()
                let n = wordToInt(nStr) ?? Int(nStr) ?? 1
                let totalDays = daysFor(n: n, unit: unit)
                let widened = isFuzzy ? Int(Double(totalDays) * 1.5) : totalDays + max(totalDays / 4, 1)
                let op = "last:\(widened)d"
                let stripped = strippingMatch(in: input, fullRange: m.range)
                return (op, stripped)
            }
        }

        // "last week", "this week", "this month", etc.
        let phrasePatterns: [(String, String)] = [
            (#"(?i)\bthis\s+week\b"#, "last:7d"),
            (#"(?i)\blast\s+week\b"#, "last:14d"),
            (#"(?i)\bthis\s+month\b"#, "last:30d"),
            (#"(?i)\blast\s+month\b"#, "last:60d"),
            (#"(?i)\bthis\s+year\b"#, "last:365d"),
            (#"(?i)\blast\s+year\b"#, "last:730d"),
            (#"(?i)\byesterday\b"#, "last:2d"),
            (#"(?i)\btoday\b"#, "last:1d"),
            (#"(?i)\brecently\b"#, "last:30d"),
        ]
        for (pat, op) in phrasePatterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let m = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) {
                let stripped = strippingMatch(in: input, fullRange: m.range)
                return (op, stripped)
            }
        }

        return (nil, input)
    }

    /// Convert a unit and count to days. Months ≈ 30, years ≈ 365.
    static func daysFor(n: Int, unit: String) -> Int {
        switch unit {
        case "day":   return n
        case "week":  return n * 7
        case "month": return n * 30
        case "year":  return n * 365
        default:      return n
        }
    }

    static func wordToInt(_ s: String) -> Int? {
        switch s {
        case "one":   return 1
        case "two":   return 2
        case "three": return 3
        case "four":  return 4
        case "five":  return 5
        case "six":   return 6
        case "seven": return 7
        case "eight": return 8
        case "nine":  return 9
        case "ten":   return 10
        default:      return nil
        }
    }

    static func strippingMatch(in input: String, fullRange ns: NSRange) -> String {
        guard let range = Range(ns, in: input) else { return input }
        var out = input
        out.removeSubrange(range)
        // Collapse double spaces left behind.
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Concept extraction

    /// Drop NL filler / stopwords and return the surviving content words.
    /// Casing is PRESERVED — we lowercase only for stopword comparison,
    /// not in the output. This matters for proper nouns that didn't make
    /// it through the contact-resolution pass: "find my argument with
    /// Annika" should still emit `argument Annika` (not `argument
    /// annika`) so a downstream INSTR over the message body has a chance
    /// at matching titlecase Annika.
    ///
    /// For known concept words (argument, apologize, plans), the result
    /// composer can emit a synonym set in the trace explanation; the
    /// query only uses the FIRST concept (engine has no OR).
    static func extractConcepts(from input: String) -> [String] {
        // Two parallel arrays: original-cased tokens and their lowercase
        // forms. Stopword check runs against the lowercase forms; the
        // result preserves the original casing.
        let rawTokens = input
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { !$0.isEmpty }
        let tokens = rawTokens.map { $0.lowercased() }

        let stopwords: Set<String> = [
            // Verbs
            "find", "show", "tell", "give", "look", "search", "ask", "see", "get",
            "say", "said", "saying", "talk", "talked", "talking", "mention",
            "happened", "happen", "happens", "made", "make", "makes",
            // Auxiliaries / modals / be
            "is", "are", "was", "were", "be", "been", "being",
            "do", "did", "does", "done", "doing",
            "have", "has", "had", "having",
            "can", "could", "would", "should", "will", "shall", "may", "might", "must",
            // Pronouns
            "i", "me", "my", "mine", "you", "your", "yours", "we", "us", "our",
            "he", "him", "his", "she", "her", "hers", "they", "them", "their", "it", "its",
            // Question / determiner / conjunction
            "what", "when", "where", "who", "why", "how", "which", "that",
            "the", "a", "an", "any", "some", "all", "this", "these", "those",
            "and", "or", "but", "if", "of", "in", "on", "at", "for", "to", "as", "by",
            "with", "from", "about", "ever", "just", "only", "really",
            // NL filler / fuzzy markers
            "maybe", "perhaps", "around", "approximately", "roughly", "about", "kind",
            "like", "thing", "things", "stuff", "ago", "back", "again",
            "please", "want", "wanted", "wants", "need", "needs", "needed",
            // Already extracted by date pass — defensive duplicate strip
            "yesterday", "today", "tomorrow", "week", "weeks", "month", "months",
            "year", "years", "day", "days", "hour", "hours", "recently", "last",
            "this", "next",
        ]

        // Drop pure-numeric tokens (date pass already extracted them).
        // Pair lowercase + original to preserve casing in the output.
        var seen: Set<String> = []
        var ordered: [String] = []
        for (i, lc) in tokens.enumerated() {
            guard !stopwords.contains(lc), !lc.allSatisfy(\.isNumber) else { continue }
            if seen.insert(lc).inserted {
                ordered.append(rawTokens[i])
            }
        }
        return ordered
    }

    // MARK: - Helpers

    static func lower(_ s: String) -> String { s.lowercased() }
}
