//
//  ConversationalConceptRetrieval.swift
//  Hourglass
//
//  Lightweight retrieval for concepts that people infer from an exchange
//  rather than type literally. `argument with Annika`, for example, should
//  find accusation/disagreement/tension signals and return the surrounding
//  conversation -- not search only for the word "argument".
//
//  This is intentionally not a general-purpose semantic index. It is a small,
//  explicit, extensible set of conversational concept profiles backed by:
//    1. broad FTS/INSTR recall over local chat.db,
//    2. a bounded direct-chat scan for implicit recent signals,
//    3. Apple's on-device sentiment tagger + deterministic evidence scoring,
//    4. context expansion around the best distinct moments.
//
//  No remote service, downloaded embedding model, or generated prose is used.
//

import Foundation
import NaturalLanguage

enum ConversationalConcept: String, Sendable, Equatable {
    case conflict
}

struct ConversationalConceptRequest: Sendable, Equatable {
    let concept: ConversationalConcept
    let person: String
    let sourceCall: NLToolCall
}

struct ConversationalConceptOutcome: Sendable {
    let candidates: [MessageSearch.Result]
    /// Distinct two-hour moments, best first, each with its scored exchange
    /// attached — the same shape hybrid retrieval returns.
    let exchanges: [MessageExchange]
    let fallbackQuery: String
    let scopeLabel: String
    let windowCount: Int
    let anchorCount: Int
    let failed: Bool
}

enum ConversationalConceptRetrieval {
    /// A compact, model-free representation of one turn in a candidate
    /// exchange. Conflict is evaluated over several of these at once; an
    /// isolated negative sentence is never sufficient on its own.
    struct ConflictWindowMessage: Sendable {
        let body: String
        let isFromMe: Bool
        let sentiment: Double
    }

    struct ConflictFeatures: Sendable {
        let score: Double
        let lexicalScore: Double
        let hasExplicitConflictWord: Bool
        let hasStrongPhrase: Bool
        let isDirected: Bool
        let isRepair: Bool
    }

    struct ConflictWindowEvaluation: Sendable {
        let score: Double
        let anchorIndex: Int?
        let evidenceCount: Int
    }

    /// Conflict-like words opt into the conflict profile only when a real
    /// person was resolved by the normal validator. This avoids turning an
    /// ordinary topic such as "function argument" into social inference.
    private static let conflictIntentWords: Set<String> = [
        "argument", "arguments", "argue", "argued", "arguing",
        "fight", "fights", "fought", "fighting",
        "conflict", "conflicts", "disagreement", "disagreements",
        "disagree", "disagreed", "disputing", "dispute",
    ]

    private static let nonConversationalArgumentMarkers: Set<String> = [
        "code", "coding", "compiler", "function", "functions", "method",
        "parameter", "parameters", "command", "terminal", "python", "swift",
        "javascript", "essay", "thesis", "paper", "legal", "logic", "math",
    ]

    /// One OR group. Quoted entries are phrase needles; `*...*` entries use
    /// the search grammar's substring mode. The broad group provides recall;
    /// `scoreConflict` decides whether a row is convincing evidence.
    static let conflictRecallQuery = [
        "*argu*", "*fight*", "*disagree*", "conflict", "upset", "angry", "mad",
        "unfair", "ridiculous", "frustrated", "hurt", "whatever", "wtf", "fuck",
        "believe", "\"not okay\"", "\"not fair\"", "\"you never\"",
        "\"you always\"", "\"leave me alone\"", "\"sick of\"", "\"need to talk\"",
        "sorry", "*apolog*", "fault", "forgive",
    ].joined(separator: "|")

    static func request(for query: String, call: NLToolCall) -> ConversationalConceptRequest? {
        guard call.tool == "search_messages",
              call.args["type"] == nil,
              call.args["reaction"] == nil else { return nil }

        let words = Set(tokenize(query))
        guard !words.isDisjoint(with: conflictIntentWords),
              words.isDisjoint(with: nonConversationalArgumentMarkers) else { return nil }

        guard let person = call.args["with"]?.asString ?? call.args["from"]?.asString,
              !person.isEmpty,
              person.lowercased() != "me" else { return nil }

        return ConversationalConceptRequest(concept: .conflict, person: person, sourceCall: call)
    }

    static func recallQuery(
        for request: ConversationalConceptRequest,
        resolvedChat: ScopedPersonChat?
    ) -> String {
        var parts: [String] = []
        let args = request.sourceCall.args

        if let chat = args["chat"]?.asString, !chat.isEmpty {
            parts.append("in:\"\(escape(chat))\"")
            if let person = args["with"]?.asString, !person.isEmpty {
                parts.append("with:\"\(escape(person))\"")
            }
        } else if let resolvedChat {
            // `in:` is narrower than `with:` for this retrieval pass. The
            // authoritative ROWID filter below remains the final boundary.
            parts.append("in:\"\(escape(resolvedChat.resolvedName))\"")
        } else if let person = args["with"]?.asString, !person.isEmpty {
            parts.append("with:\"\(escape(person))\"")
        }

        if let sender = args["from"]?.asString, !sender.isEmpty {
            if sender.lowercased() == "me" { parts.append("from:me") }
            else { parts.append("from:\"\(escape(sender))\"") }
        }
        parts.append(conflictRecallQuery)
        return parts.joined(separator: " ")
    }

    /// Extracts evidence from one message. The score is useful for choosing
    /// recall seeds, but qualification happens in `evaluateConflictWindow`.
    /// This distinction prevents a generally sad/negative monologue from
    /// being mislabeled as an interpersonal argument.
    static func conflictFeatures(body rawBody: String, sentiment: Double) -> ConflictFeatures {
        let body = normalize(rawBody)
        let words = tokenize(body)
        let wordSet = Set(words)
        var lexicalScore = 0.0
        var hasExplicitConflictWord = false
        var hasStrongPhrase = false

        if words.contains(where: { $0.hasPrefix("argu") }) {
            lexicalScore += 5.0
            hasExplicitConflictWord = true
        }
        if words.contains(where: { $0.hasPrefix("fight") }) || wordSet.contains("fought") {
            lexicalScore += 5.0
            hasExplicitConflictWord = true
        }
        if words.contains(where: { $0.hasPrefix("disagree") }) || wordSet.contains("conflict") {
            lexicalScore += 5.0
            hasExplicitConflictWord = true
        }

        for phrase in [
            "can't believe", "cannot believe", "not okay", "not fair", "leave me alone",
            "don't talk to me", "do not talk to me", "sick of", "done with this",
        ] where body.contains(phrase) {
            lexicalScore += 4.0
            hasStrongPhrase = true
        }

        let negativeAffect: Set<String> = [
            "upset", "angry", "mad", "unfair", "ridiculous", "frustrated", "hurt",
            "whatever", "wtf", "fuck", "fucking",
        ]
        lexicalScore += min(6.0, Double(wordSet.intersection(negativeAffect).count) * 2.4)

        let secondPerson = !wordSet.isDisjoint(with: ["you", "your", "yours", "u", "ur"])
        let blaming = !wordSet.isDisjoint(with: [
            "never", "always", "again", "lied", "forgot", "wrong", "stop", "can't", "won't",
            "didn't", "don't", "why",
        ])
        let isDirected = secondPerson && (blaming || hasStrongPhrase || !wordSet.isDisjoint(with: negativeAffect))
        if secondPerson && blaming { lexicalScore += 1.8 }

        // Repair language is useful for locating the tail of an argument, but
        // is weaker evidence than the disagreement itself.
        let isRepair = words.contains(where: { $0.hasPrefix("apolog") })
            || !wordSet.isDisjoint(with: ["sorry", "fault", "forgive"])
        if isRepair {
            lexicalScore += 1.2
        }

        if rawBody.contains("?!") || rawBody.contains("!?") { lexicalScore += 0.7 }
        else if rawBody.contains("!") { lexicalScore += 0.25 }
        if uppercaseRatio(rawBody) >= 0.45 { lexicalScore += 0.8 }

        // NLTagger returns approximately -1...1. Negative tone lifts likely
        // evidence; positive tone suppresses broad-cue false positives such
        // as "you always make me laugh" or "mad funny".
        var score = lexicalScore
        if sentiment < 0 { score += min(3.5, -sentiment * 3.5) }
        else { score -= min(2.0, sentiment * 2.0) }
        return ConflictFeatures(
            score: max(0, score),
            lexicalScore: lexicalScore,
            hasExplicitConflictWord: hasExplicitConflictWord,
            hasStrongPhrase: hasStrongPhrase,
            isDirected: isDirected,
            isRepair: isRepair
        )
    }

    /// Compatibility/helper score for individual-message ordering. A result
    /// is not accepted from this value alone; see `evaluateConflictWindow`.
    static func conflictScore(body rawBody: String, sentiment: Double) -> Double {
        conflictFeatures(body: rawBody, sentiment: sentiment).score
    }

    /// Scores a short chronological exchange as one retrieval unit.
    ///
    /// Qualification deliberately requires at least two messages plus
    /// interaction-level evidence: a directed high-signal accusation, an
    /// explicit conflict reference supported by an exchange/second signal,
    /// or multiple tension-bearing turns. Sentiment alone can adjust ranking
    /// but can never make a window qualify.
    static func evaluateConflictWindow(
        _ messages: [ConflictWindowMessage]
    ) -> ConflictWindowEvaluation {
        guard messages.count >= 2 else {
            return ConflictWindowEvaluation(score: 0, anchorIndex: nil, evidenceCount: 0)
        }

        let features = messages.map {
            conflictFeatures(body: $0.body, sentiment: $0.sentiment)
        }
        let evidenceIndices = features.indices.filter { features[$0].lexicalScore >= 1.2 }
        let strongDirected = features.indices.contains {
            features[$0].isDirected && features[$0].hasStrongPhrase
        }
        let explicitIndices = features.indices.filter { features[$0].hasExplicitConflictWord }
        let tensionIndices = features.indices.filter {
            let feature = features[$0]
            return feature.lexicalScore >= 1.2 && feature.score >= 1.8 && !feature.isRepair
        }
        let hasTwoSides = Set(messages.map(\.isFromMe)).count > 1
        let explicitSupported = !explicitIndices.isEmpty
            && (hasTwoSides || evidenceIndices.count >= 2)
        let repeatedTension = tensionIndices.count >= 2

        guard strongDirected || explicitSupported || repeatedTension else {
            return ConflictWindowEvaluation(
                score: 0,
                anchorIndex: nil,
                evidenceCount: evidenceIndices.count
            )
        }

        let orderedScores = features.map(\.score).sorted(by: >)
        var score = orderedScores.first ?? 0
        if orderedScores.count > 1 { score += orderedScores[1] * 0.65 }
        if orderedScores.count > 2 { score += orderedScores[2] * 0.35 }
        if hasTwoSides { score += 1.0 }
        if evidenceIndices.count >= 2 { score += min(2.0, Double(evidenceIndices.count - 1) * 0.7) }

        let anchorIndex = features.indices.max {
            if features[$0].score != features[$1].score {
                return features[$0].score < features[$1].score
            }
            return $0 < $1
        }
        return ConflictWindowEvaluation(
            score: score,
            anchorIndex: anchorIndex,
            evidenceCount: evidenceIndices.count
        )
    }

    static func sentimentScore(_ body: String, using tagger: NLTagger) -> Double {
        guard !body.isEmpty else { return 0 }
        tagger.string = body
        let range = body.startIndex..<body.endIndex
        tagger.setLanguage(.english, range: range)
        let (tag, _) = tagger.tag(
            at: body.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        )
        return tag.flatMap { Double($0.rawValue) } ?? 0
    }

    private static func tokenize(_ input: String) -> [String] {
        normalize(input)
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    private static func normalize(_ input: String) -> String {
        PhraseQuery.foldTypography(input)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func uppercaseRatio(_ input: String) -> Double {
        let letters = input.filter(\.isLetter)
        guard letters.count >= 6 else { return 0 }
        let uppercase = letters.filter(\.isUppercase).count
        return Double(uppercase) / Double(letters.count)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension NLAgent {
    func retrieveConversationalConcept(
        _ request: ConversationalConceptRequest,
        now: Date,
        maxCandidates: Int
    ) async -> ConversationalConceptOutcome? {
        let resolvedChat = try? await tools.resolveScopedPersonChat(named: request.person)
        let query = ConversationalConceptRetrieval.recallQuery(
            for: request,
            resolvedChat: resolvedChat
        )
        let dateRange = Self.resolveDateArg(request.sourceCall.args, now: now)

        var sourceSucceeded = false
        var poolByID: [Int64: MessageSearch.Result] = [:]

        // Broad indexed recall. Over-fetch because both FTS and INSTR apply
        // their SQL LIMIT before the final decoded-body refinement; 600 keeps
        // this bounded while leaving room for dropped coarse matches.
        if let recalled = try? await tools.search(
            query: query,
            dateRange: dateRange,
            limit: 600,
            order: .descending
        ) {
            sourceSucceeded = true
            for result in recalled { poolByID[result.message.id] = result }
        }

        // A bounded direct-chat scan catches recent implicit tension that has
        // no lexical cue at all. Exact ROWIDs prevent same-named groups from
        // contaminating `argument with Person`.
        if let resolvedChat,
           let recent = try? await tools.readMessagesInChats(
                rowIDs: resolvedChat.chatRowIDs,
                in: dateRange,
                limit: 200
           ) {
            sourceSucceeded = true
            for result in recent { poolByID[result.message.id] = result }
        }

        guard sourceSucceeded else { return nil }

        let allowedChatIDs = resolvedChat.map { Set($0.chatRowIDs) }
        let pool = poolByID.values.filter { result in
            allowedChatIDs.map { $0.contains(result.message.chatRowID) } ?? true
        }

        struct Seed {
            let result: MessageSearch.Result
            let sentiment: Double
            let features: ConversationalConceptRetrieval.ConflictFeatures
        }
        struct RankedWindow {
            let anchor: MessageSearch.Result
            let messages: [MessageSearch.Result]
            let score: Double
        }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var sentimentByID: [Int64: Double] = [:]
        func sentiment(for result: MessageSearch.Result) -> Double {
            if let cached = sentimentByID[result.message.id] { return cached }
            let value = ConversationalConceptRetrieval.sentimentScore(
                result.message.body,
                using: tagger
            )
            sentimentByID[result.message.id] = value
            return value
        }

        let chronologicalPool = pool.sorted { $0.message.date < $1.message.date }
        var seeds: [Seed] = chronologicalPool.compactMap { result in
            let messageSentiment = sentiment(for: result)
            let features = ConversationalConceptRetrieval.conflictFeatures(
                body: result.message.body,
                sentiment: messageSentiment
            )
            // Keep lexical candidates and markedly negative rows long enough
            // to evaluate their surrounding exchange. Negativity alone still
            // cannot pass the window-level qualification below.
            guard features.lexicalScore >= 1.2 || messageSentiment <= -0.35 else { return nil }
            return Seed(result: result, sentiment: messageSentiment, features: features)
        }
        seeds.sort {
            if $0.features.score != $1.features.score {
                return $0.features.score > $1.features.score
            }
            return $0.result.message.date > $1.result.message.date
        }

        /// Builds a short, contiguous conversational session around a seed.
        /// Count limits stop long rapid-fire chats from becoming huge inputs;
        /// the adjacent-gap limit prevents unrelated conversations hours apart
        /// from being treated as one exchange.
        func localWindow(around seed: MessageSearch.Result) -> [MessageSearch.Result] {
            let chat = chronologicalPool.filter {
                $0.message.chatRowID == seed.message.chatRowID
            }
            guard let anchorIndex = chat.firstIndex(where: { $0.message.id == seed.message.id }) else {
                return [seed]
            }

            let maxGap: TimeInterval = 45 * 60
            var lower = anchorIndex
            var previous = anchorIndex
            while lower > 0, anchorIndex - lower < 3 {
                let candidate = lower - 1
                guard chat[previous].message.date.timeIntervalSince(chat[candidate].message.date) <= maxGap else { break }
                lower = candidate
                previous = candidate
            }

            var upper = anchorIndex
            previous = anchorIndex
            while upper + 1 < chat.count, upper - anchorIndex < 4 {
                let candidate = upper + 1
                guard chat[candidate].message.date.timeIntervalSince(chat[previous].message.date) <= maxGap else { break }
                upper = candidate
                previous = candidate
            }
            return Array(chat[lower...upper])
        }

        func mergedWindow(
            seed: MessageSearch.Result,
            local: [MessageSearch.Result],
            context: [MessageSearch.Result]
        ) -> [MessageSearch.Result] {
            var byID: [Int64: MessageSearch.Result] = [seed.message.id: seed]
            for result in local + context {
                guard result.message.chatRowID == seed.message.chatRowID else { continue }
                if let dateRange, !dateRange.contains(result.message.date) { continue }
                byID[result.message.id] = result
            }
            let sorted = byID.values.sorted { $0.message.date < $1.message.date }
            guard let index = sorted.firstIndex(where: { $0.message.id == seed.message.id }) else {
                return [seed]
            }
            let lower = max(0, index - 3)
            let upper = min(sorted.count - 1, index + 4)
            return Array(sorted[lower...upper])
        }

        func evaluate(_ results: [MessageSearch.Result])
            -> ConversationalConceptRetrieval.ConflictWindowEvaluation {
            let messages = results.map { result in
                ConversationalConceptRetrieval.ConflictWindowMessage(
                    body: result.message.body,
                    isFromMe: result.message.isFromMe,
                    sentiment: sentiment(for: result)
                )
            }
            return ConversationalConceptRetrieval.evaluateConflictWindow(messages)
        }

        // The index still supplies cheap candidate anchors, but the retrieval
        // unit is now a 3-before/4-after exchange. At most 24 explicit/strong
        // seeds need a DB context read; recent implicit candidates already
        // have neighbors in the bounded direct-chat scan.
        var contextLoads = 0
        var rankedWindows: [RankedWindow] = []
        for seed in seeds.prefix(80) {
            var window = localWindow(around: seed.result)
            let shouldLoadContext = contextLoads < 24
                && (seed.features.hasExplicitConflictWord
                    || seed.features.hasStrongPhrase
                    || seed.features.isDirected)
            if shouldLoadContext,
               let guid = seed.result.message.guid,
               let context = try? await tools.context(forGUID: guid, before: 3, after: 4) {
                contextLoads += 1
                window = mergedWindow(seed: seed.result, local: window, context: context)
            }

            let evaluation = evaluate(window)
            guard evaluation.score > 0,
                  let anchorIndex = evaluation.anchorIndex,
                  window.indices.contains(anchorIndex) else { continue }
            rankedWindows.append(RankedWindow(
                anchor: window[anchorIndex],
                messages: window,
                score: evaluation.score
            ))
        }
        rankedWindows.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.anchor.message.date > $1.anchor.message.date
        }

        // Pick distinct windows so multiple seed messages from one exchange
        // do not occupy every result slot.
        var selectedWindows: [RankedWindow] = []
        for window in rankedWindows {
            let duplicatesCluster = selectedWindows.contains { selected in
                selected.anchor.message.chatRowID == window.anchor.message.chatRowID
                    && abs(selected.anchor.message.date.timeIntervalSince(window.anchor.message.date)) <= 2 * 60 * 60
            }
            if !duplicatesCluster { selectedWindows.append(window) }
            if selectedWindows.count == 5 { break }
        }

        // Same grouped-exchange shape as hybrid retrieval. The windows are
        // already two-hour-distinct, so this is a pass-through wrap plus the
        // shared per-exchange message cap.
        let exchanges = MessageExchangeGrouping.distinctExchanges(
            from: selectedWindows.map {
                MessageExchangeGrouping.Candidate(hero: $0.anchor, messages: $0.messages)
            },
            maxExchanges: selectedWindows.count
        )

        var ordered: [MessageSearch.Result] = []
        var seen = Set<Int64>()
        func append(_ result: MessageSearch.Result) {
            if seen.insert(result.message.id).inserted { ordered.append(result) }
        }

        // Flat candidates lead with one hero per distinct moment (so a top-N
        // consumer shows N different moments), then each exchange's short
        // scored context follows.
        for exchange in exchanges { append(exchange.hero) }
        for exchange in exchanges {
            for result in exchange.messages { append(result) }
            if ordered.count >= maxCandidates { break }
        }

        let scopeLabel = resolvedChat?.resolvedName ?? request.person
        return ConversationalConceptOutcome(
            candidates: Array(ordered.prefix(maxCandidates)),
            exchanges: exchanges,
            fallbackQuery: query,
            scopeLabel: scopeLabel,
            windowCount: rankedWindows.count,
            anchorCount: selectedWindows.count,
            failed: false
        )
    }
}
