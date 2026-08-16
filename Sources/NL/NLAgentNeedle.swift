//
//  NLAgentNeedle.swift
//  Hourglass
//
//  Direct Needle2 path: route once, validate/repair the structured call,
//  execute one database function, and return its rows/counts without asking a
//  large language model to rewrite the result as prose.
//

import Foundation
import os

private let needleAgentLogger = Logger(
    subsystem: "com.satyajit.bettermessages",
    category: "nl-agent-needle"
)

struct NeedleValidatedCall: Sendable, Equatable {
    let call: NLToolCall
    let modelTool: String?
    let repaired: Bool
}

enum NeedleCallValidator {
    static let knownTools: Set<String> = [
        "search_messages", "read_conversation", "count_messages", "first_message",
        "top_contacts", "top_groups", "overview_stats", "friends_made_since",
        "plans_in_window", "search_contacts",
    ]

    static func validate(
        model: NeedleRoutingResult?,
        query: String,
        contactNames: [String],
        now: Date
    ) -> NeedleValidatedCall {
        let forced = highSignalTool(for: query)
        let modelTool = model?.call.flatMap { knownTools.contains($0.tool) ? $0.tool : nil }
        // The base Needle model is useful for constrained argument emission,
        // but its measured tool selection is not reliable enough to let a
        // ranking/analytics call erase an ordinary person-or-topic search.
        // Every specialized tool below has a deterministic high-signal rule;
        // without one, only the general message-search route is safe.
        let tool = forced ?? (modelTool == "search_messages" ? modelTool : nil) ?? "search_messages"
        let args = arguments(
            for: tool,
            query: query,
            modelArgs: model?.call?.args ?? [:],
            contactNames: contactNames,
            now: now
        )
        let call = NLToolCall(tool: tool, args: args)
        return NeedleValidatedCall(
            call: call,
            modelTool: modelTool,
            repaired: model?.callCount != 1 || modelTool != tool || model?.call?.args != args
        )
    }

    /// These phrases are explicit enough that allowing a 45M model to select a
    /// contradictory tool would only reduce accuracy. Queries without one of
    /// these specialized intents are treated as ordinary message searches.
    static func highSignalTool(for query: String) -> String? {
        let q = normalized(query)
        if containsAnyPhrase(q, ["contact named", "contact called", "in my contacts", "in contacts",
                                  "anyone named", "address book"]) {
            return "search_contacts"
        }
        if isExplicitFriendsIntent(q) {
            return "friends_made_since"
        }
        if isExplicitPlansIntent(q) {
            return "plans_in_window"
        }
        if isExplicitTopContactsIntent(q) {
            return "top_contacts"
        }
        if isExplicitTopGroupsIntent(q) {
            return "top_groups"
        }
        if containsAnyPhrase(q, ["total sent and received", "total messages sent and received",
                                  "total texts sent and received", "sent and received total", "overall message",
                                  "overall messages", "message totals", "text totals", "messaging stats",
                                  "message stats", "how active was i", "how active have i"]) {
            return "overview_stats"
        }
        if isExplicitCountIntent(q) {
            return "count_messages"
        }
        if containsAnyPhrase(q, ["first time", "first message", "first text", "when did i first"])
            || containsAnyWord(q, ["earliest"])
            || (containsPhrase(q, "first ever") && containsAnyWord(q, countableMessageWords)) {
            return "first_message"
        }
        if isExplicitConversationReadIntent(q) {
            return "read_conversation"
        }
        return nil
    }

    static func arguments(
        for tool: String,
        query: String,
        modelArgs: [String: NLToolArg],
        contactNames: [String],
        now: Date
    ) -> [String: NLToolArg] {
        let q = normalized(query)
        let built = RuleBasedQueryBuilder.build(from: query, contactNames: contactNames, now: now)
        let person = built.person
        let date = dateArgument(query, now: now)
        let media = mediaType(in: q)
        let reaction = reactionType(in: q)
        let chat = chatName(in: query)

        switch tool {
        case "read_conversation":
            var args: [String: NLToolArg] = [:]
            if let person { args["with"] = .string(person) }
            else if let grounded = groundedString(modelArgs["with"], in: query) { args["with"] = .string(grounded) }
            if let date { args["in"] = .string(date) }
            args["limit"] = .int(80)
            return args

        case "top_contacts":
            var args: [String: NLToolArg] = ["limit": .int(explicitLimit(in: q) ?? 5)]
            if let date { args["in"] = .string(date) }
            if let chat { args["chat"] = .string(chat) }
            return args

        case "top_groups":
            var args: [String: NLToolArg] = ["limit": .int(explicitLimit(in: q) ?? 5)]
            if let date { args["in"] = .string(date) }
            return args

        case "overview_stats":
            return date.map { ["in": .string($0)] } ?? [:]

        case "friends_made_since":
            let since = sinceDate(query, now: now)
                ?? groundedString(modelArgs["since"], in: query)
                ?? startOfCurrentYear(now)
            return ["since": .string(since), "limit": .int(20)]

        case "plans_in_window":
            return ["in": .string(date ?? "this_week"), "limit": .int(80)]

        case "search_contacts":
            let name = contactSearchName(in: query)
                ?? person
                ?? groundedString(modelArgs["name"], in: query)
                ?? query
            return ["name": .string(name), "limit": .int(20)]

        default:
            var structured: [String: NLToolArg] = [:]
            if let date { structured["in"] = .string(date) }
            if let chat { structured["chat"] = .string(chat) }
            if let media { structured["type"] = .string(media) }
            if let reaction { structured["reaction"] = .string(reaction) }
            if let person {
                if indicatesSentByPerson(q, person: person) {
                    structured["from"] = .string(person)
                } else {
                    structured["with"] = .string(person)
                    if indicatesSentByUser(q) { structured["from"] = .string("me") }
                }
            } else if indicatesSentByUser(q) {
                structured["from"] = .string("me")
            }
            if let bodyQuery = bodyQuery(
                original: query,
                built: built,
                modelArgs: modelArgs,
                person: person,
                hasMedia: media != nil,
                hasReaction: reaction != nil,
                hasDate: date != nil
            ) {
                structured["query"] = .string(bodyQuery)
                // GBNF constrains this to a closed strategy enum. The
                // validator, not the 45M model, decides that conceptual body
                // queries use the generic lexical+dense window retriever.
                structured["retrieval"] = .string("hybrid")
            }
            if tool == "search_messages" { structured["limit"] = .int(50) }
            return structured
        }
    }

    static func legacyCall(from call: NLToolCall) -> NLToolCall? {
        switch call.tool {
        case "search_messages", "count_messages", "first_message":
            var parts: [String] = []
            if let person = call.args["with"]?.asString, !person.isEmpty {
                parts.append("with:\"\(escape(person))\"")
            }
            if let sender = call.args["from"]?.asString, !sender.isEmpty {
                if sender.lowercased() == "me" { parts.append("from:me") }
                else { parts.append("from:\"\(escape(sender))\"") }
            }
            if let chat = call.args["chat"]?.asString, !chat.isEmpty {
                parts.append("in:\"\(escape(chat))\"")
            }
            if let type = call.args["type"]?.asString { parts.append("type:\(type)") }
            if let reaction = call.args["reaction"]?.asString { parts.append("reactions:\(reaction)") }
            if let query = call.args["query"]?.asString, !query.isEmpty { parts.append(query) }
            var args: [String: NLToolArg] = ["query": .string(parts.joined(separator: " "))]
            if let date = call.args["in"] { args["in"] = date }
            if let limit = call.args["limit"] { args["limit"] = limit }
            let name: String
            if call.tool == "count_messages" { name = "countMatching" }
            else if call.tool == "first_message" { name = "firstMatching" }
            else { name = "search" }
            return NLToolCall(tool: name, args: args)

        case "read_conversation":
            return NLToolCall(tool: "readMessages", args: call.args)
        case "top_contacts":
            return NLToolCall(tool: "topContacts", args: call.args)
        case "top_groups":
            return NLToolCall(tool: "topGroups", args: call.args)
        case "overview_stats":
            return NLToolCall(tool: "overviewStats", args: call.args)
        case "friends_made_since":
            return NLToolCall(tool: "friendsMadeSince", args: call.args)
        case "plans_in_window":
            return NLToolCall(tool: "plansInWindow", args: call.args)
        default:
            return nil
        }
    }

    private static func bodyQuery(
        original: String,
        built: RuleBasedFallbackResult,
        modelArgs: [String: NLToolArg],
        person: String?,
        hasMedia: Bool,
        hasReaction: Bool,
        hasDate: Bool
    ) -> String? {
        let filtered = built.concepts.filter { concept in
            let c = normalized(concept)
            if genericBodyWords.contains(c) { return false }
            if hasMedia && mediaWords.contains(c) { return false }
            if hasReaction && reactionWords.contains(c) { return false }
            if hasDate && (temporalBodyWords.contains(c) || looksDateLike(c)) { return false }
            return person.map { normalized($0).contains(c) } != true
        }
        if !filtered.isEmpty {
            // The old literal fallback intentionally kept one keyword to
            // avoid FTS AND-recall death. Hybrid retrieval is different: its
            // grouped semantic expansion and dense vector need the complete
            // concept (`vacation planning`, not merely `vacation`) to rank the
            // right exchange. Keep a small deduplicated concept phrase.
            var seen = Set<String>()
            let concepts = filtered.filter { seen.insert(normalized($0)).inserted }
            return concepts.prefix(4).joined(separator: " ")
        }

        // Needle's body-text argument is a last resort, not the source of
        // truth. Accept it only when the complete token sequence occurs in
        // the user's words and it is not schema/date vocabulary.
        if let modelQuery = groundedString(modelArgs["query"], in: original),
           modelQuery.caseInsensitiveCompare(person ?? "") != .orderedSame {
            let modelWords = words(modelQuery)
            let personWords = Set(person.map(words) ?? [])
            guard !modelWords.isEmpty,
                  modelWords.allSatisfy({ !genericBodyWords.contains($0) }),
                  modelWords.allSatisfy({ !personWords.contains($0) }),
                  !hasDate || modelWords.allSatisfy({ !temporalBodyWords.contains($0) && !looksDateLike($0) })
            else { return nil }
            return modelQuery
        }
        return nil
    }

    private static let genericBodyWords: Set<String> = [
        "message", "messages", "text", "texts", "find", "show", "sent", "send",
        "said", "say", "mention", "mentioned", "times", "time", "conversation",
        "talking", "talk", "contact", "contacts", "group", "chat", "active", "total",
        "top", "most", "count", "counts", "number", "overview", "stat", "stats",
        "statistic", "statistics", "rank", "ranking", "where", "many", "often", "much",
    ]
    private static let mediaWords: Set<String> = [
        "photo", "photos", "picture", "pictures", "image", "images", "video", "videos",
        "voice", "audio", "note", "notes", "sticker", "stickers", "link", "links", "url", "urls",
        "file", "files", "document", "documents", "pdf", "pdfs", "movie", "movies", "clip", "clips",
    ]
    private static let reactionWords: Set<String> = [
        "love", "loved", "laugh", "laughed", "like", "liked", "dislike", "disliked",
        "emphasize", "question", "react", "reacted", "reaction", "reactions", "tapback", "tapbacks",
        "heart", "haha", "thumbs", "up", "down",
    ]
    private static let temporalBodyWords: Set<String> = [
        "today", "yesterday", "tomorrow", "week", "weeks", "month", "months", "year", "years",
        "day", "days", "between", "through", "thru", "until", "since", "before", "after", "over",
        "during", "past", "previous", "recent", "recently", "january", "jan", "february", "feb",
        "march", "mar", "april", "apr", "may", "june", "jun", "july", "jul", "august", "aug",
        "september", "sep", "sept", "october", "oct", "november", "nov", "december", "dec",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    ]

    private static func mediaType(in q: String) -> String? {
        if containsAnyWord(q, ["photo", "photos", "picture", "pictures"])
            || (containsAnyWord(q, ["image", "images"])
                && !containsAnyPhrase(q, ["image recognition", "image generation", "image model"])) {
            return "image"
        }
        if containsAnyWord(q, ["video", "videos", "movie", "movies", "clip", "clips"])
            && !containsAnyPhrase(q, ["video game", "video games", "video call", "video calls"]) {
            return "video"
        }
        if containsAnyPhrase(q, ["voice message", "voice messages", "voice note", "voice notes",
                                  "audio message", "audio messages", "audio clip", "audio clips"]) {
            return "audio"
        }
        if containsAnyWord(q, ["sticker", "stickers"]) { return "sticker" }
        if containsAnyWord(q, ["link", "links", "url", "urls"]) { return "link" }
        if containsAnyWord(q, ["file", "files", "document", "documents", "pdf", "pdfs"]) { return "file" }
        return nil
    }

    private static func reactionType(in q: String) -> String? {
        let explicitReaction = containsAnyWord(q, ["react", "reacted", "reaction", "reactions", "tapback", "tapbacks"])
        let messageObject = containsAnyWord(q, ["message", "messages", "text", "texts"])
            && !containsAnyWord(q, ["said", "say", "says", "mentioned", "mention"])
        if containsAnyPhrase(q, ["heart reacted", "heart reaction"])
            || (explicitReaction && containsAnyWord(q, ["love", "loved", "heart"]))
            || (messageObject && containsWord(q, "loved")) { return "love" }
        if containsAnyPhrase(q, ["haha react", "haha reaction"])
            || (explicitReaction && containsAnyWord(q, ["laugh", "laughed", "haha"]))
            || (messageObject && containsWord(q, "laughed")) { return "laugh" }
        if containsPhrase(q, "thumbs up")
            || (explicitReaction && containsAnyWord(q, ["like", "liked"]))
            || (messageObject && containsWord(q, "liked")) { return "like" }
        if containsPhrase(q, "thumbs down")
            || (explicitReaction && containsAnyWord(q, ["dislike", "disliked"]))
            || (messageObject && containsWord(q, "disliked")) { return "dislike" }
        return nil
    }

    private static func dateArgument(_ query: String, now: Date) -> String? {
        let q = normalized(query)
        if containsPhrase(q, "all time") { return "all_time" }

        // Resolve explicit user ranges and boundaries before coarse phrases.
        // This keeps "between May 1 and June 15" from collapsing to a single
        // named month and ensures every emitted value is executable by
        // NLAgent.resolveDateArg.
        if let explicit = explicitDateWindow(in: query, now: now) { return explicit }

        let named: [(String, String)] = [
            ("today", "today"), ("yesterday", "yesterday"),
            ("this week", "this_week"), ("last week", "last_week"),
            ("this month", "this_month"), ("last month", "last_month"),
        ]
        for (phrase, value) in named where containsPhrase(q, phrase) { return value }
        if containsPhrase(q, "this year") { return yearRange(Calendar.current.component(.year, from: now)) }
        if containsPhrase(q, "last year") { return yearRange(Calendar.current.component(.year, from: now) - 1) }

        // Center "N units ago" around its target rather than treating it as
        // an ever-widening lookback from now.
        if let window = NLAgent.extractCenteredWindow(fromQuery: query, now: now, padDays: 3) {
            return "\(isoDate(window.lower))..\(isoDate(window.upper))"
        }

        // Arbitrary rolling windows MUST be concrete ranges. `last_10d`, for
        // example, is not a PlanJSON.TimeWindow and used to silently resolve
        // to nil (all history).
        if let rolling = rollingDateWindow(in: query, now: now) { return rolling }

        if let year = firstCapture(#"(?i)\b(?:in|during)\s+(20\d{2})\b"#, in: query),
           let value = Int(year) { return yearRange(value) }
        if let future = nextCalendarWindow(in: q, now: now) { return future }
        return nil
    }

    private static func sinceDate(_ query: String, now: Date) -> String? {
        if let window = dateArgument(query, now: now), window.contains("..") {
            return window.components(separatedBy: "..").first
        }
        if let iso = firstCapture(#"(?i)\bsince\s+(20\d{2}-\d{2}-\d{2})\b"#, in: query) { return iso }
        let months = Calendar.current.monthSymbols
        let lower = normalized(query)
        for (index, month) in months.enumerated() {
            let monthLower = month.lowercased()
            guard lower.contains("since \(monthLower)") else { continue }
            let dayText = firstCapture("(?i)since\\s+\(monthLower)\\s+(\\d{1,2})", in: query)
            let day = Int(dayText ?? "1") ?? 1
            var components = Calendar.current.dateComponents([.year], from: now)
            components.month = index + 1
            components.day = day
            guard var date = Calendar.current.date(from: components) else { continue }
            if date > now, let previous = Calendar.current.date(byAdding: .year, value: -1, to: date) { date = previous }
            return isoDate(date)
        }
        return nil
    }

    private struct DateBounds {
        let lower: Date
        let upper: Date
    }

    /// Parse explicit ranges (`May 1 to June 15`, ISO ranges, whole months),
    /// open boundaries (`since`, `after`, `before`, `until`), and single
    /// calendar dates. The output is always the executor's canonical
    /// `YYYY-MM-DD..YYYY-MM-DD` form.
    private static func explicitDateWindow(in query: String, now: Date) -> String? {
        let endpoint = dateEndpointPattern

        let between = "(?i)\\bbetween\\s+(\(endpoint))\\s+and\\s+(\(endpoint))\\b"
        if let values = captures(between, in: query), values.count == 2 {
            return canonicalRange(from: values[0], through: values[1], now: now)
        }

        let connected = "(?i)\\b(\(endpoint))\\s*(?:\\.\\.|to|through|thru|until|[-–—])\\s*(\(endpoint))\\b"
        if let values = captures(connected, in: query), values.count == 2 {
            return canonicalRange(from: values[0], through: values[1], now: now)
        }

        let bounded = "(?i)\\b(since|after)\\s+(\(endpoint))\\s+(?:and\\s+)?(before|until)\\s+(\(endpoint))\\b"
        if let values = captures(bounded, in: query), values.count == 4,
           let bounds = canonicalBounds(from: values[1], through: values[3], now: now) {
            let cal = Calendar.current
            let lowerEndpoint = endpointBounds(
                values[1],
                now: now,
                preferredYear: cal.component(.year, from: bounds.lower)
            )
            let upperEndpoint = endpointBounds(
                values[3],
                now: now,
                preferredYear: cal.component(.year, from: bounds.upper)
            )
            let lower = values[0].lowercased() == "after"
                ? (cal.date(byAdding: .day, value: 1, to: lowerEndpoint?.upper ?? bounds.lower) ?? bounds.lower)
                : bounds.lower
            let upper = values[2].lowercased() == "before"
                ? (cal.date(byAdding: .day, value: -1, to: upperEndpoint?.lower ?? bounds.upper) ?? bounds.upper)
                : bounds.upper
            if lower <= upper { return "\(isoDate(lower))..\(isoDate(upper))" }
        }

        let since = "(?i)\\b(since|after)\\s+(\(endpoint))\\b"
        if let values = captures(since, in: query), values.count == 2 {
            let operation = values[0].lowercased()
            let raw = values[1]
            var preferredYear: Int? = explicitYear(in: raw)
            var bounds = endpointBounds(raw, now: now, preferredYear: preferredYear)
            if preferredYear == nil, let candidate = bounds, candidate.lower > now {
                preferredYear = Calendar.current.component(.year, from: now) - 1
                bounds = endpointBounds(raw, now: now, preferredYear: preferredYear)
            }
            if let bounds {
                let lower = operation == "after"
                    ? (Calendar.current.date(byAdding: .day, value: 1, to: bounds.upper) ?? bounds.upper)
                    : bounds.lower
                return "\(isoDate(lower))..\(isoDate(now))"
            }
        }

        let upperBoundary = "(?i)\\b(before|until)\\s+(\(endpoint))\\b"
        if let values = captures(upperBoundary, in: query), values.count == 2,
           let bounds = endpointBounds(values[1], now: now, preferredYear: nil) {
            let cal = Calendar.current
            let inclusive = values[0].lowercased() == "before"
                ? (cal.date(byAdding: .day, value: -1, to: bounds.lower) ?? bounds.lower)
                : bounds.upper
            return "2001-01-01..\(isoDate(inclusive))"
        }

        let single = "(?i)\\b(?:on|in|during)\\s+(\(endpoint))\\b"
        if let raw = captures(single, in: query)?.first,
           let bounds = endpointBounds(raw, now: now, preferredYear: nil) {
            return "\(isoDate(bounds.lower))..\(isoDate(bounds.upper))"
        }
        return nil
    }

    private static var dateEndpointPattern: String {
        let month = "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
        let iso = "20\\d{2}-\\d{2}-\\d{2}"
        let us = "\\d{1,2}/\\d{1,2}(?:/(?:\\d{2}|20\\d{2}))?"
        let namedDay = "\(month)\\s+\\d{1,2}(?:st|nd|rd|th)?(?:,?\\s+20\\d{2})?"
        let namedMonth = "\(month)(?:\\s+20\\d{2})?"
        let relative = "(?:today|yesterday|this\\s+week|last\\s+week|this\\s+month|last\\s+month|this\\s+year|last\\s+year)"
        return "(?:\(iso)|\(us)|\(namedDay)|\(namedMonth)|20\\d{2}|\(relative))"
    }

    private static func canonicalRange(from lowerRaw: String, through upperRaw: String, now: Date) -> String? {
        guard let bounds = canonicalBounds(from: lowerRaw, through: upperRaw, now: now) else { return nil }
        return "\(isoDate(bounds.lower))..\(isoDate(bounds.upper))"
    }

    private static func canonicalBounds(from lowerRaw: String, through upperRaw: String, now: Date) -> DateBounds? {
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: now)
        let lowerExplicitYear = explicitYear(in: lowerRaw)
        let upperExplicitYear = explicitYear(in: upperRaw)
        var lowerYear = lowerExplicitYear ?? upperExplicitYear
        var upperYear = upperExplicitYear ?? lowerExplicitYear
        var lower = endpointBounds(lowerRaw, now: now, preferredYear: lowerYear)
        var upper = endpointBounds(upperRaw, now: now, preferredYear: upperYear)

        if let lo = lower, let hi = upper, lo.lower > hi.upper {
            if lowerExplicitYear != nil, upperExplicitYear == nil {
                upperYear = (lowerExplicitYear ?? currentYear) + 1
                upper = endpointBounds(upperRaw, now: now, preferredYear: upperYear)
            } else {
                lowerYear = (upperExplicitYear ?? currentYear) - 1
                lower = endpointBounds(lowerRaw, now: now, preferredYear: lowerYear)
            }
        }
        guard let lower, let upper, lower.lower <= upper.upper else { return nil }
        return DateBounds(lower: lower.lower, upper: upper.upper)
    }

    private static func endpointBounds(_ raw: String, now: Date, preferredYear: Int?) -> DateBounds? {
        let cal = Calendar.current
        var cleaned = raw
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: #"(?i)(\\d)(st|nd|rd|th)\\b"#, with: "$1", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let endpointWords = words(cleaned)

        // Users commonly omit the year in compact ranges (`5/1 to 6/15`).
        // DateParser intentionally requires a year for US dates, so supply
        // the range-resolved year here before delegating to it.
        if let values = captures(#"^(\d{1,2})/(\d{1,2})(?:/(\d{2}|20\d{2}))?$"#, in: cleaned),
           values.count >= 2 {
            let explicit: Int? = values.count == 3 ? Int(values[2]).map { value in
                values[2].count == 2 ? (value >= 70 ? 1900 + value : 2000 + value) : value
            } : nil
            let year = explicit ?? preferredYear ?? cal.component(.year, from: now)
            if case .range(let parsed)? = DateParser.parse("\(values[0])/\(values[1])/\(year)", now: now) {
                let end = cal.date(byAdding: .second, value: -1, to: parsed.upperBound) ?? parsed.upperBound
                return DateBounds(lower: parsed.lowerBound, upper: end)
            }
        }

        // A bare month means the whole calendar month, choosing the most
        // recent occurrence when no year is supplied.
        if let first = endpointWords.first, let month = DateParser.monthIndex(first),
           endpointWords.count == 1
            || (endpointWords.count == 2 && Int(endpointWords[1]).map({ $0 >= 1900 && $0 <= 2200 }) == true) {
            var year = preferredYear
                ?? endpointWords.dropFirst().first.flatMap(Int.init)
                ?? cal.component(.year, from: now)
            var components = DateComponents(year: year, month: month, day: 1)
            guard var start = cal.date(from: components) else { return nil }
            if preferredYear == nil, endpointWords.count == 1, start > now {
                year -= 1
                components.year = year
                guard let adjusted = cal.date(from: components) else { return nil }
                start = adjusted
            }
            guard let next = cal.date(byAdding: .month, value: 1, to: start),
                  let end = cal.date(byAdding: .day, value: -1, to: next) else { return nil }
            return DateBounds(lower: start, upper: end)
        }

        if explicitYear(in: cleaned) == nil, let preferredYear,
           endpointWords.first.flatMap(DateParser.monthIndex) != nil {
            cleaned += " \(preferredYear)"
        }
        guard case .range(let parsed)? = DateParser.parse(cleaned, now: now) else { return nil }
        // DateParser ranges use an exclusive-looking next-boundary instant;
        // convert it to the final included calendar day before serializing.
        let end = cal.date(byAdding: .second, value: -1, to: parsed.upperBound) ?? parsed.upperBound
        return DateBounds(lower: parsed.lowerBound, upper: end)
    }

    private static func rollingDateWindow(in query: String, now: Date) -> String? {
        let pattern = #"(?i)\b(?:last|past|previous|recent)\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month|year)s?\b"#
        guard let values = captures(pattern, in: query), values.count == 2 else { return nil }
        let amount = Int(values[0].lowercased()) ?? RuleBasedQueryBuilder.wordToInt(values[0].lowercased())
        guard let amount, amount > 0 else { return nil }
        let component: Calendar.Component
        switch values[1].lowercased() {
        case "day": component = .day
        case "week": component = .weekOfYear
        case "month": component = .month
        case "year": component = .year
        default: return nil
        }
        guard let lower = Calendar.current.date(byAdding: component, value: -amount, to: now) else { return nil }
        return "\(isoDate(lower))..\(isoDate(now))"
    }

    private static func nextCalendarWindow(in q: String, now: Date) -> String? {
        let cal = Calendar.current
        let component: Calendar.Component
        if containsPhrase(q, "next week") { component = .weekOfYear }
        else if containsPhrase(q, "next month") { component = .month }
        else if containsPhrase(q, "next year") { component = .year }
        else { return nil }
        guard let current = cal.dateInterval(of: component, for: now),
              let lower = cal.date(byAdding: component, value: 1, to: current.start),
              let upperExclusive = cal.date(byAdding: component, value: 2, to: current.start),
              let upper = cal.date(byAdding: .day, value: -1, to: upperExclusive) else { return nil }
        return "\(isoDate(lower))..\(isoDate(upper))"
    }

    private static func explicitYear(in raw: String) -> Int? {
        firstCapture(#"\b(20\d{2})\b"#, in: raw).flatMap(Int.init)
    }

    private static func chatName(in query: String) -> String? {
        let patterns = [
            #"(?i)\bin\s+(?:the\s+)?(.+?)\s+(?:group\s+chat|group|chat)\b"#,
            #"(?i)\bfrom\s+(?:the\s+)?(.+?)\s+(?:group\s+chat|group|chat)\b"#,
        ]
        for pattern in patterns {
            if let capture = firstCapture(pattern, in: query) {
                let trimmed = capture.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !["my most active", "my biggest", "a"].contains(normalized(trimmed)) {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func contactSearchName(in query: String) -> String? {
        let patterns = [
            #"(?i)\b(?:named|called)\s+([\p{L}\p{N} .'-]+?)(?:\s+in\s+(?:my\s+)?contacts|\s*$)"#,
            #"(?i)\bdoes\s+([\p{L}\p{N} .'-]+?)\s+exist\s+in\s+(?:my\s+)?address\s+book\b"#,
            #"(?i)\bfind\s+([\p{L}\p{N} .'-]+?)\s+in\s+(?:my\s+)?(?:contacts|address\s+book)\b"#,
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: query)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty { return value }
        }
        return nil
    }

    private static func indicatesSentByUser(_ q: String) -> Bool {
        containsAnyPhrase(q, ["i sent", "have i sent", "did i send", "did i say", "i said",
                               "my sent", "my messages to", "my message to", "my texts to", "my text to",
                               "from me", "i wrote to", "i shared", "i forwarded", "i apologize", "i apologised"])
    }

    private static let countableMessageWords = [
        "message", "messages", "text", "texts", "time", "times", "photo", "photos",
        "picture", "pictures", "image", "images", "video", "videos", "link", "links",
        "file", "files", "document", "documents", "pdf", "pdfs", "sticker", "stickers",
        "tapback", "tapbacks", "reaction", "reactions", "voice", "audio", "note", "notes",
    ]

    private static func isExplicitTopContactsIntent(_ q: String) -> Bool {
        if containsAnyPhrase(q, [
            "top contact", "top contacts", "top people", "text the most", "text most",
            "texted the most", "message the most", "message most", "messaged the most",
            "most active person", "most texted person", "most texted people",
            "most messaged person", "most messaged people",
        ]) { return true }
        let contactNoun = containsAnyWord(q, ["contact", "contacts", "person", "people", "who"])
        let ranking = containsAnyWord(q, ["top", "rank", "ranking"])
        let messageVerb = containsAnyWord(q, ["text", "texted", "message", "messaged"])
        return contactNoun && (ranking || (containsWord(q, "most") && messageVerb))
    }

    private static func isExplicitTopGroupsIntent(_ q: String) -> Bool {
        let groupScope = containsAnyPhrase(q, ["group chat", "group chats"])
            || containsWord(q, "groups")
        guard groupScope else { return false }
        return containsAnyPhrase(q, ["most active", "biggest", "use the most", "text the most",
                                      "message the most"])
            || containsAnyWord(q, ["top", "rank", "ranking"])
    }

    private static func isExplicitConversationReadIntent(_ q: String) -> Bool {
        if containsAnyPhrase(q, [
            "catch me up", "our conversation", "my conversation", "were we talking",
            "what's going on with", "what is going on with", "recap of my chat",
            "recap my chat", "recap our chat", "summarize my", "summarize our",
            "summarise my", "summarise our",
        ]) { return true }
        return containsAnyPhrase(q, ["what were", "what did"])
            && containsAnyWord(q, ["talk", "talking"])
    }

    private static func isExplicitCountIntent(_ q: String) -> Bool {
        if containsPhrase(q, "how much did i text") { return true }
        let countLead = containsAnyPhrase(q, ["how many", "how often", "number of"])
        guard countLead else { return false }
        if containsAnyWord(q, countableMessageWords) { return true }
        // Natural shorthand such as “how many did they send me?” still
        // clearly asks for a message count even though the noun is omitted.
        return q.range(
            of: #"\bhow many\b.+\b(?:send|sent|text|texted|message|messaged)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isExplicitFriendsIntent(_ q: String) -> Bool {
        containsAnyPhrase(q, [
            "friends i made", "friend i made", "new friends i made", "new friend i made",
            "who did i meet", "people i met", "who are my new friends", "who is my new friend",
        ])
    }

    private static func isExplicitPlansIntent(_ q: String) -> Bool {
        containsAnyPhrase(q, [
            "what plans did i make", "which plans did i make", "what plans have i made",
            "which plans have i made", "what are my plans", "which are my plans",
            "what do i have planned", "what did i agree", "what have i agreed",
            "which commitments did i agree", "what commitments did i agree",
            "which commitments did i make", "what commitments did i make",
            "my commitments", "plans i made", "commitments i made",
        ])
    }

    private static func indicatesSentByPerson(_ q: String, person: String) -> Bool {
        let p = normalized(person).split(separator: " ").first.map(String.init) ?? normalized(person)
        return containsAnyPhrase(q, ["\(p) sent", "\(p) said", "\(p) say", "\(p) mentioned",
                                      "\(p) shared", "\(p) forwarded", "from \(p)", "by \(p)", "sent by \(p)"])
    }

    private static func explicitLimit(in q: String) -> Int? {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10]
        for (word, value) in words where q.contains("top \(word)") { return value }
        for (word, value) in words where containsPhrase(q, "\(word) most") { return value }
        if let capture = firstCapture(#"(?i)\btop\s+(\d{1,2})\b"#, in: q) { return Int(capture) }
        if let capture = firstCapture(#"(?i)\b(\d{1,2})\s+most\b"#, in: q) { return Int(capture) }
        return nil
    }

    private static func groundedString(_ arg: NLToolArg?, in query: String) -> String? {
        guard let value = arg?.asString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return containsPhrase(query, value) ? value : nil
    }

    private static func yearRange(_ year: Int) -> String { "\(year)-01-01..\(year)-12-31" }
    private static func startOfCurrentYear(_ date: Date) -> String {
        "\(Calendar.current.component(.year, from: date))-01-01"
    }
    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
    private static func words(_ string: String) -> [String] {
        normalized(string)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        let target = words(needle)
        return target.count == 1 && words(haystack).contains(target[0])
    }
    private static func containsAnyWord(_ haystack: String, _ needles: [String]) -> Bool {
        let haystackWords = Set(words(haystack))
        return needles.contains { needle in
            let candidate = words(needle)
            return candidate.count == 1 && haystackWords.contains(candidate[0])
        }
    }
    private static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        let haystackWords = words(haystack)
        let needleWords = words(needle)
        guard !needleWords.isEmpty, needleWords.count <= haystackWords.count else { return false }
        if needleWords.count == 1 { return haystackWords.contains(needleWords[0]) }
        for start in 0...(haystackWords.count - needleWords.count) {
            if Array(haystackWords[start..<(start + needleWords.count)]) == needleWords { return true }
        }
        return false
    }
    private static func containsAnyPhrase(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { containsPhrase(haystack, $0) }
    }
    private static func looksDateLike(_ value: String) -> Bool {
        value.range(of: #"^\d{1,4}(?:[-/]\d{1,2}){1,2}$"#, options: .regularExpression) != nil
    }
    private static func firstCapture(_ pattern: String, in input: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }
    private static func captures(_ pattern: String, in input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1 else { return nil }
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: input) else { continue }
            values.append(String(input[range]))
        }
        return values
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public extension NLAgent {
    func answerWithNeedle(
        userQuery: String,
        now: Date = Date(),
        maxCandidates: Int = 50
    ) async -> NLQueryResult {
        let started = Date()
        var trace: [NLTraceStep] = []
        let contacts = await tools.availableContactNames()

        var modelRoute: NeedleRoutingResult?
        var runtimeFailed = false
        if let router = runtime as? any NeedleRoutingRuntime {
            do {
                modelRoute = try await router.route(userQuery: userQuery, now: now)
            } catch {
                runtimeFailed = true
                needleAgentLogger.error("Needle2 route failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            runtimeFailed = true
        }

        let validated = NeedleCallValidator.validate(
            model: modelRoute,
            query: userQuery,
            contactNames: contacts,
            now: now
        )
        let routeLabel: String
        if runtimeFailed {
            routeLabel = "Needle2 unavailable — used validated local routing"
        } else if let modelTool = validated.modelTool, modelTool != validated.call.tool {
            routeLabel = "Needle2 → \(validated.call.tool) · route corrected"
        } else if validated.repaired {
            routeLabel = "Needle2 → \(validated.call.tool) · filters validated"
        } else {
            routeLabel = "Needle2 → \(validated.call.tool)"
        }
        trace.append(NLTraceStep(
            phase: .planning,
            label: routeLabel,
            status: runtimeFailed ? .failed : .complete,
            duration: Date().timeIntervalSince(started)
        ))

        if validated.call.tool == "search_contacts" {
            let needle = validated.call.args["name"]?.asString?.lowercased() ?? ""
            let limit = validated.call.args["limit"]?.asInt ?? 20
            let matches = contacts.filter { needle.isEmpty || $0.lowercased().contains(needle) }.prefix(limit)
            let explanation = matches.isEmpty
                ? "No contacts matched \"\(validated.call.args["name"]?.asString ?? userQuery)\"."
                : "Matching contacts:\n" + matches.map { "• \($0)" }.joined(separator: "\n")
            trace.append(NLTraceStep(
                phase: .searching,
                label: "Contact database → \(matches.count) match\(matches.count == 1 ? "" : "es")",
                status: .complete,
                duration: Date().timeIntervalSince(started)
            ))
            return NLQueryResult(
                hero: nil,
                candidates: [],
                trace: trace,
                plan: nil,
                fallbackQuery: userQuery,
                explanation: explanation,
                degradedToFallback: runtimeFailed
            )
        }

        // Concepts such as "argument" are inferred from an exchange's tone;
        // literal keyword search is the wrong retrieval primitive. Needle
        // still owns the typed route/person/date call, then this lightweight
        // local layer broadens recall, ranks conflict evidence, and loads the
        // surrounding messages. It is deliberately profile-gated so ordinary
        // topics continue through the exact database function below.
        if let request = ConversationalConceptRetrieval.request(
            for: userQuery,
            call: validated.call
        ) {
            let retrievalStarted = Date()
            if let outcome = await retrieveConversationalConcept(
                request,
                now: now,
                maxCandidates: maxCandidates
            ) {
                if !outcome.candidates.isEmpty {
                    trace.append(NLTraceStep(
                        phase: .searching,
                        label: "Conflict retrieval → \(outcome.windowCount) qualifying conversation windows in \(outcome.scopeLabel)",
                        status: outcome.failed ? .failed : .complete,
                        duration: Date().timeIntervalSince(retrievalStarted)
                    ))
                    trace.append(NLTraceStep(
                        phase: .ranking,
                        label: "Ranked \(outcome.anchorCount) likely moment\(outcome.anchorCount == 1 ? "" : "s") and loaded surrounding messages",
                        status: .complete,
                        duration: Date().timeIntervalSince(retrievalStarted)
                    ))
                    trace.append(NLTraceStep(
                        phase: .answering,
                        label: "Returned database evidence directly",
                        status: .complete,
                        duration: Date().timeIntervalSince(started)
                    ))
                    return NLQueryResult(
                        hero: outcome.candidates.first,
                        candidates: outcome.candidates,
                        trace: trace,
                        plan: nil,
                        fallbackQuery: outcome.fallbackQuery,
                        explanation: nil,
                        degradedToFallback: runtimeFailed || outcome.failed
                    )
                }
            }
        }

        // Every other conceptual message query uses the generic hybrid
        // retriever. Exact typed filters are resolved above and remain
        // authoritative; only corpus recall/ranking is semantic. Explicit
        // attachment and Tapback requests stay on their exact SQL functions.
        if validated.call.tool == "search_messages",
           validated.call.args["retrieval"]?.asString == "hybrid",
           validated.call.args["type"] == nil,
           validated.call.args["reaction"] == nil,
           let semanticQuery = validated.call.args["query"]?.asString,
           !semanticQuery.isEmpty {
            let retrievalStarted = Date()
            let request = HybridMessageRetrievalRequest(
                semanticQuery: semanticQuery,
                withPerson: validated.call.args["with"]?.asString,
                fromSender: validated.call.args["from"]?.asString,
                chat: validated.call.args["chat"]?.asString,
                dateRange: Self.resolveDateArg(validated.call.args, now: now),
                limit: maxCandidates
            )
            if let outcome = try? await tools.hybridSearch(request),
               !outcome.candidates.isEmpty {
                trace.append(NLTraceStep(
                    phase: .searching,
                    label: "Hybrid retrieval → \(outcome.windowCount) conversation window\(outcome.windowCount == 1 ? "" : "s")",
                    status: .complete,
                    duration: Date().timeIntervalSince(retrievalStarted)
                ))
                trace.append(NLTraceStep(
                    phase: .ranking,
                    label: "Fused exact, semantic-neighbor, and \(outcome.denseCandidateCount) dense candidates",
                    status: .complete,
                    duration: Date().timeIntervalSince(retrievalStarted)
                ))
                trace.append(NLTraceStep(
                    phase: .answering,
                    label: "Returned the highest-ranked exchange with context",
                    status: .complete,
                    duration: Date().timeIntervalSince(started)
                ))
                let fallback = NeedleCallValidator.legacyCall(from: validated.call)?
                    .args["query"]?.asString ?? userQuery
                return NLQueryResult(
                    hero: outcome.candidates.first,
                    candidates: outcome.candidates,
                    trace: trace,
                    plan: nil,
                    fallbackQuery: fallback,
                    explanation: nil,
                    degradedToFallback: runtimeFailed
                )
            }
        }

        guard let legacy = NeedleCallValidator.legacyCall(from: validated.call) else {
            return NLQueryResult(
                hero: nil,
                candidates: [],
                trace: trace,
                plan: nil,
                fallbackQuery: userQuery,
                explanation: "This question does not map to an available local search function.",
                degradedToFallback: true
            )
        }

        var candidates: [MessageSearch.Result] = []
        var contactStats: [DashboardStats.ContactStat] = []
        let toolStarted = Date()
        let observation = await executeReActTool(
            call: legacy,
            now: now,
            maxCandidates: maxCandidates,
            lastCandidates: &candidates,
            lastContacts: &contactStats
        )
        trace.append(NLTraceStep(
            phase: .searching,
            label: "\(validated.call.tool) → \(observation.summary)",
            status: observation.failed ? .failed : .complete,
            duration: Date().timeIntervalSince(toolStarted)
        ))
        trace.append(NLTraceStep(
            phase: .answering,
            label: "Returned database results directly",
            status: .complete,
            duration: Date().timeIntervalSince(started)
        ))

        let messageTools: Set<String> = [
            "search_messages", "read_conversation", "first_message", "plans_in_window",
        ]
        let explanation = messageTools.contains(validated.call.tool)
            ? nil
            : cleanObservation(observation.observation)
        let query = legacy.args["query"]?.asString ?? userQuery
        return NLQueryResult(
            hero: candidates.first,
            candidates: Array(candidates.prefix(maxCandidates)),
            trace: trace,
            plan: nil,
            fallbackQuery: query,
            explanation: explanation,
            degradedToFallback: runtimeFailed || observation.failed
        )
    }

    private func cleanObservation(_ observation: String) -> String {
        observation
            .replacingOccurrences(of: "\n\(Self.answerNowHint)", with: "")
            .replacingOccurrences(of: Self.answerNowHint, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
