//
//  VernacularSignatureFrames.swift
//  Hourglass — Vernacular signature frames (operator feedback)
//
//  The auto-mined templates skew mundane ("_ abt to _", "ur _ tho"). The
//  frames people actually recognize as THEIRS are anchored on something
//  expressive:
//    • EMPHATIC CAPS — "this is NOT the move" → "___ is NOT ___",
//      "I MAY have overcooked" → "I MAY ___". The anchor keeps its caps:
//      shouting one real word inside a lowercase message IS the construction.
//    • VOCATIVE OPENERS — "Brother the elevator is slow" → "brother ___",
//      reusing the POS-sense vocative senses (VernacularPOSSense), so the
//      same senses that power the spread cloud also produce frames.
//
//  One bounded pass over the subject's messages, deterministic, no models.
//  The engine merges these ABOVE the auto-mined templates (`mergeAtTop`).
//

import Foundation
import NaturalLanguage

enum VernacularSignatureFrames {

    /// Short words that may precede the CAPS anchor and join it, so the frame
    /// reads as the construction it is ("is NOT", "I MAY", "that's NOT").
    private static let anchorLinkers: Set<String> = [
        "is", "are", "was", "were", "am", "be", "im", "i", "we", "u", "you",
        "it", "its", "that", "thats", "do", "did", "does", "can", "will",
        "would", "should"
    ]

    /// CAPS tokens that are shouting-shaped but not emphasis (the pronoun I,
    /// initialisms that read as words, place/exam abbreviations).
    private static let capsStoplist: Set<String> = [
        "I", "A", "OK", "TV", "US", "PS", "AI", "ID", "DM", "PR", "NY", "LA",
        "SF", "CA", "UK", "EU", "GPA", "SAT", "ACT", "AP", "CS", "ER", "GG",
        "PE", "TA", "GE", "IT"
    ]

    private struct FrameAcc {
        let anchor: String
        var count = 0
        var fills: [String: Int] = [:]
        var examples: [String] = []

        mutating func add(fill: String, example: String) {
            count += 1
            if !fill.isEmpty {
                fills[fill, default: 0] += 1
            }
            if examples.count < 3 {
                let oneLine = example
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let clipped = String(oneLine.prefix(120))
                if !clipped.isEmpty && !examples.contains(clipped) {
                    examples.append(clipped)
                }
            }
        }
    }

    /// Mine the signature frames for the subject. Bounded: one pass over the
    /// subject's messages for the caps frames, plus the (cached) POS-sense
    /// vocative detection for the vocative frames.
    static func mine(
        messages: [VernacularMessage],
        subjectContext: VernacularSubjectContext,
        baseline: LinguisticBaseline,
        config: VernacularConfig
    ) -> [VernacularProfileTemplate] {
        guard config.signatureFramesEnabled else { return [] }

        // ── (a) emphatic-caps frames ─────────────────────────────────────
        var capsFrames: [String: FrameAcc] = [:]
        for message in messages where subjectContext.isSubjectMessage(message) {
            guard !message.isPoll, !message.bodyLow.contains("http") else { continue }
            let rawTokens = message.body
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }
                .filter { !$0.isEmpty }
            guard rawTokens.count >= 2 else { continue }
            // Whole-message yelling is a register, not emphasis — require the
            // message to be mostly lowercase around the shout.
            let lowercaseTokens = rawTokens.filter { $0.contains(where: \.isLowercase) }
            guard lowercaseTokens.count >= 2 else { continue }

            // Pasted code/SQL fragments carry ALL-CAPS keywords (AND, NOT,
            // SELECT) — skip messages whose tokens look code-shaped.
            let codeShaped = message.body.contains("=")
                || rawTokens.contains { $0.contains(".") || $0.contains("_") || $0.contains("(") }
            guard !codeShaped else { continue }

            for (index, token) in rawTokens.enumerated() {
                let lowered = token.lowercased()
                guard token.count >= 3,
                      token.allSatisfy(\.isLetter),
                      token == token.uppercased(),
                      token != lowered,
                      !capsStoplist.contains(token),
                      // A REAL word, shouted — not an acronym the baseline
                      // has never seen in lowercase…
                      baseline.isKnown(lowered),
                      // …and not texting register (LOL/LMAO are caps by
                      // habit, not emphasis — the register model knows them)…
                      VernacularTextingRegister.penalty(for: lowered) <= 0,
                      // …and not laughter onomatopoeia (a SHAPE rule — lol/
                      // lmao/haha families are caps by habit too).
                      !isLaughterShaped(lowered)
                else { continue }

                var anchor = token
                var anchorStart = index
                if index > 0 {
                    let previous = rawTokens[index - 1]
                    if previous.count <= 6 && anchorLinkers.contains(previous.lowercased()) {
                        anchor = "\(previous) \(token)"
                        anchorStart = index - 1
                    }
                }
                var pattern = anchor
                if anchorStart > 0 { pattern = "___ " + pattern }
                let hasTail = index + 1 < rawTokens.count
                if hasTail { pattern += " ___" }
                var fill = hasTail ? rawTokens[index + 1].lowercased() : ""
                if !fill.allSatisfy({ $0.isLetter || $0 == "’" || $0 == "'" }) { fill = "" }
                capsFrames[pattern, default: FrameAcc(anchor: anchor)]
                    .add(fill: fill, example: message.body)
            }
        }

        // ── (b) vocative frames ("brother ___") ─────────────────────────
        var vocativeFrames: [String: FrameAcc] = [:]
        let vocatives = VernacularPOSSense.detectVocativeSurfaces(
            messages: messages, baseline: baseline, config: config)
        for sense in vocatives where sense.subjectUses >= config.signatureFrameMinCount {
            let pattern = "\(sense.surface) ___"
            var acc = FrameAcc(anchor: sense.surface)
            for message in messages where subjectContext.isSubjectMessage(message)
                && sense.messageIDs.contains(message.messageID) {
                let words = message.words
                guard words.first == sense.surface else { continue }
                let fill = words.count >= 2 ? words[1] : ""
                acc.add(fill: fill, example: message.body)
            }
            if acc.count >= config.signatureFrameMinCount {
                vocativeFrames[pattern] = acc
            }
        }

        // ── select + build ───────────────────────────────────────────────
        let capsSelected = capsFrames
            .filter { $0.value.count >= config.signatureFrameMinCount }
            // NER on the (few) surviving anchors: ALL-CAPS org/place names
            // (UCLA) are how the thing is WRITTEN, not emphasis.
            .filter { !isNamedEntityAnchor($0.value.anchor) }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(8)
        let vocativeSelected = vocativeFrames
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(6)

        var out: [VernacularProfileTemplate] = []
        out.reserveCapacity(capsSelected.count + vocativeSelected.count)
        for (pattern, acc) in vocativeSelected {
            out.append(template(pattern: pattern, acc: acc, idPrefix: "sigvoc"))
        }
        for (pattern, acc) in capsSelected {
            out.append(template(pattern: pattern, acc: acc, idPrefix: "sigcaps"))
        }
        return out.sorted {
            if $0.counts.userMessages != $1.counts.userMessages {
                return $0.counts.userMessages > $1.counts.userMessages
            }
            return $0.pattern < $1.pattern
        }
    }

    /// Merge the signature frames ABOVE the auto-mined templates, dropping any
    /// mined duplicate of the same pattern, and renumber ranks.
    static func mergeAtTop(
        _ signature: [VernacularProfileTemplate],
        into mined: [VernacularProfileTemplate]
    ) -> [VernacularProfileTemplate] {
        guard !signature.isEmpty else { return mined }
        let signaturePatterns = Set(signature.map(\.pattern))
        let rest = mined.filter { !signaturePatterns.contains($0.pattern) }
        return (signature + rest).enumerated().map { index, item in
            VernacularProfileTemplate(
                id: item.id,
                rank: index + 1,
                pattern: item.pattern,
                anchors: item.anchors,
                slotCount: item.slotCount,
                score: item.score,
                features: item.features,
                counts: item.counts,
                topFills: item.topFills,
                examples: item.examples
            )
        }
    }

    /// Laughter onomatopoeia shapes (lol/lmao/haha families) — caps by habit.
    private static func isLaughterShaped(_ lowered: String) -> Bool {
        lowered.range(of: "^(l+o+l+z*|lm+f?a+o+|a?(ha)+h?|he(he)+)$",
                      options: .regularExpression) != nil
    }

    /// True when the anchor's CAPS word tags as an org/place/person name —
    /// "UCLA" is capitalized because that's its spelling, not for emphasis.
    private static func isNamedEntityAnchor(_ anchor: String) -> Bool {
        guard let capsWord = anchor.split(separator: " ").last.map(String.init) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = capsWord
        let (tag, _) = tagger.tag(at: capsWord.startIndex, unit: .word, scheme: .nameType)
        return tag == .organizationName || tag == .placeName || tag == .personalName
    }

    private static func template(
        pattern: String,
        acc: FrameAcc,
        idPrefix: String
    ) -> VernacularProfileTemplate {
        let topFills = acc.fills
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { VernacularProfileTemplate.Fill(fill: $0.key, count: $0.value) }
        let slotCount = max(pattern.components(separatedBy: "___").count - 1, 1)
        let score = min(1.0, 0.6 + Double(acc.count) / 200.0)
        let features = VernacularProfileFeatures(
            length: 0, peopleIDF: 0, selfUsage: 1, rarity: 0, recency: 0,
            spamResistance: 1, glue: 0, collocation: 0, semanticShift: 0,
            registerPenalty: 0, style: 1, topic: 0, zWorld: 0, zRole: 0,
            dispersion: 0, echo: 0, burst: 0,
            productivity: Double(acc.fills.count), anchorDistinctiveness: 1,
            embedding: 0, finalScore: score
        )
        let counts = VernacularProfileCounts(
            userMessages: acc.count, receivedMessages: 0, activeContactUsers: 0,
            distinctUserDays: 0, effectiveUserMessages: Double(acc.count),
            maxUserDayShare: 0, maxMonthShare: 0, effectiveContacts: 0,
            effectiveChats: 0, worldMessages: acc.count, recentUserMessages: 0,
            olderUserMessages: 0
        )
        return VernacularProfileTemplate(
            id: "\(idPrefix):\(pattern)",
            rank: 0,
            pattern: pattern,
            anchors: [acc.anchor],
            slotCount: slotCount,
            score: score,
            features: features,
            counts: counts,
            topFills: Array(topFills),
            examples: acc.examples
        )
    }
}
