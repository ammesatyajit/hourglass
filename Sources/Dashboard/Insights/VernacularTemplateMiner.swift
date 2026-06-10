//
//  VernacularTemplateMiner.swift
//  Hourglass — Vernacular Analysis (Layer 1: formulaic templates / snowclones)
//
//  Faithful port of the validated `/tmp/vern/main.swift` template miner.
//  Builds a "skeleton" of each message — content words abstracted to `_`,
//  while emoji, ALL-CAPS emphasis, and short/common frame words are kept —
//  then surfaces the INTERIOR-blank wrap-around frames the user uses far more
//  than the people they text ("the way _ is", "not _ being _"), WITH up to two
//  real fill-in examples each.
//
//  Distinctiveness = log-odds (Fightin' Words shape) of YOUR template rate vs
//  the SAME template's rate in messages you RECEIVE. This demotes generic
//  grammar ("the _", "a _") and surfaces real signatures.
//
//  PURE: deterministic over the message list. No I/O.
//

import Foundation

enum TemplateMiner {

    private static let emojiMarker = "\u{1F600}"  // sentinel token for "an emoji"

    /// Tokenize keeping emoji + sentence punctuation as their own tokens
    /// (matches `/tmp/vern` `tokens(_:)`).
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for ch in s {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                cur.append(ch)
            } else if ch.unicodeScalars.contains(where: isEmojiScalar) {
                flush(); out.append(emojiMarker)
            } else if ".,!?\u{2026}".contains(ch) {
                flush(); out.append(String(ch))
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func isEmojiScalar(_ u: Unicode.Scalar) -> Bool {
        u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x2190)
    }

    /// Abstract one token to its skeleton form.
    static func skeletonToken(_ t: String, common: Set<String>) -> String {
        if t == emojiMarker { return "<emoji>" }
        if ".,!?\u{2026}".contains(t) { return t }
        let letters = t.filter { $0.isLetter }
        if letters.count >= 2 && letters == letters.uppercased() { return t.uppercased() } // CAPS emphasis kept
        let low = t.lowercased()
        if common.contains(low) || low.count <= 3 { return low }  // frame word
        return "_"
    }

    static func skeleton(_ toks: [String], common: Set<String>) -> [String] {
        let sk = toks.map { skeletonToken($0, common: common) }
        var res: [String] = []
        for s in sk { if s == "_" && res.last == "_" { continue }; res.append(s) }
        return res
    }

    static func isFrame(_ t: String) -> Bool { t == "<emoji>" || (t.first?.isLetter ?? false) }

    /// At least two frame anchors AND a slot strictly inside (not first/last).
    static func isMiddleBlank(_ sk: [String]) -> Bool {
        let frames = sk.filter(isFrame).count
        guard frames >= 2 else { return false }
        guard sk.count >= 3 else { return false }
        for i in 1..<(sk.count - 1) where sk[i] == "_" { return true }
        return false
    }

    /// Mine the interior-blank templates and attach examples. `options.topK`
    /// is used to bound the example-collection set.
    static func mine(messages: [VernacularMessage], baseline: LinguisticBaseline,
                     options: VernacularAnalyzer.Options) -> [VernacularTemplate] {

        // Frame anchors = the top-400 most common baseline words. The
        // prototype read the first 400 lines of the baseline file (which is
        // frequency-sorted); we approximate with the 400 highest-count words.
        let common = Set(baseline.counts.sorted { $0.value > $1.value }.prefix(400).map { $0.key })

        var longMine: [String: Int] = [:]
        var longOth: [String: Int] = [:]
        var longMineTot = 0, longOthTot = 0

        for m in messages {
            let toks = tokens(m.body)
            guard toks.count >= 3 && toks.count <= 9 else { continue }
            let sk = skeleton(toks, common: common)
            guard isMiddleBlank(sk) else { continue }
            let key = sk.joined(separator: " ")
            if m.fromMe { longMine[key, default: 0] += 1; longMineTot += 1 }
            else { longOth[key, default: 0] += 1; longOthTot += 1 }
        }

        let ranked = distinctive(longMine, longOth, longMineTot, longOthTot, minN: options.minTemplateCount)
        let wanted = Array(ranked.prefix(12).map { $0.0 })
        let wantedSet = Set(wanted)

        // second pass: collect up to 2 real sent examples per wanted template
        var examples: [String: [String]] = [:]
        for m in messages where m.fromMe {
            let toks = tokens(m.body)
            guard toks.count >= 3 && toks.count <= 9 else { continue }
            let sk = skeleton(toks, common: common)
            guard isMiddleBlank(sk) else { continue }
            let key = sk.joined(separator: " ")
            if wantedSet.contains(key), (examples[key]?.count ?? 0) < 2 {
                let one = m.body.replacingOccurrences(of: "\n", with: " ")
                if !(examples[key]?.contains(one) ?? false) { examples[key, default: []].append(one) }
            }
        }

        return ranked.prefix(12).map { (key, count, _) in
            VernacularTemplate(skeleton: key, count: count, examples: examples[key] ?? [])
        }
    }

    /// Log-odds (Fightin' Words shape) — distinctive = you use it far more
    /// than the people you text. Mirrors `/tmp/vern`'s `distinctive(...)`.
    static func distinctive(_ mineD: [String: Int], _ othD: [String: Int],
                            _ mineTot: Int, _ othTot: Int, minN: Int) -> [(String, Int, Double)] {
        let a = 0.5
        var out: [(String, Int, Double)] = []
        for (t, c) in mineD where c >= minN {
            let o = Double(othD[t] ?? 0)
            let li = log((Double(c) + a) / (Double(mineTot) + a))
            let lj = log((o + a) / (Double(othTot) + a))
            let z = (li - lj) / (1.0 / (Double(c) + a) + 1.0 / (o + a)).squareRoot()
            out.append((t, c, z))
        }
        return out.sorted { $0.2 > $1.2 }
    }
}
