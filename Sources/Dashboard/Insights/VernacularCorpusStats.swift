//
//  VernacularCorpusStats.swift
//  Hourglass — Vernacular Analysis (Layer 1 corpus statistics)
//
//  The single-pass corpus accumulator + the slang-phrase / repurposed /
//  tag / construction / sense-split scorers. Faithful port of the validated
//  `/tmp/slang3/main.swift` PASS A + PASS B + downstream sections.
//
//  PURE: constructed from `[VernacularMessage]` (no I/O), all scoring is a
//  deterministic function of the accumulated counts.
//

import Foundation

struct CorpusStats {

    // Per-candidate accumulated stats (slang3's `Stat`).
    struct PhraseStat {
        var count = 0
        var uptake = 0.0
        var senders = Set<String>()
        var recent = 0
        var older = 0
        var first = Double.greatestFiniteMagnitude
        var firstWho = ""
        var examples: [String] = []
        var titleHits = 0
    }

    let baseline: LinguisticBaseline
    // unigram + n-gram counts over the non-poll, non-URL corpus
    let uni: [String: Int]
    let uniTotal: Double
    let gramTotal: Double          // bigram total (for NPMI denominator)
    let candidates: Set<String>    // grams with count ≥ threshold
    let stat: [String: PhraseStat]
    let myCommon: Set<String>      // top-250 of the user's own words (register set)
    // raw message handles for tag/construction/sense passes
    private let messages: [VernacularMessage]

    // tuning constants lifted verbatim from the prototype
    private static let urlish: Set<String> = ["www","com","http","https","org","net","gg","linkedin","docs","google","io","co"]

    init(messages: [VernacularMessage], baseline: LinguisticBaseline) {
        self.messages = messages
        self.baseline = baseline

        // ---- PASS A: unigram + bigram + trigram counts ----
        var uni: [String: Int] = [:]
        var gram: [String: Int] = [:]
        var uniTot = 0.0
        var gramTot = 0.0
        for m in messages {
            if m.isPoll { continue }
            let w = m.words
            for x in w { uni[x, default: 0] += 1; uniTot += 1 }
            if w.count >= 2 {
                for i in 0..<(w.count - 1) { gram["\(w[i]) \(w[i+1])", default: 0] += 1; gramTot += 1 }
            }
            if w.count >= 3 {
                for i in 0..<(w.count - 2) { gram["\(w[i]) \(w[i+1]) \(w[i+2])", default: 0] += 1 }
            }
        }
        self.uni = uni
        self.uniTotal = max(1, uniTot)
        self.gramTotal = max(1, gramTot)

        let cands = Set(gram.filter {
            $0.value >= 15 && !$0.key.split(separator: " ").contains { Self.urlish.contains(String($0)) }
        }.keys)
        self.candidates = cands

        // ---- PASS B: per-candidate stats ----
        let nowU = Date().timeIntervalSince1970
        let cut = nowU - 180 * 86_400
        var stat: [String: PhraseStat] = [:]
        for m in messages {
            if m.isPoll || m.bodyLow.contains("http") { continue }
            let w = m.words
            if w.count < 2 { continue }
            var gs: [String] = []
            for i in 0..<(w.count - 1) { gs.append("\(w[i]) \(w[i+1])") }
            if w.count >= 3 { for i in 0..<(w.count - 2) { gs.append("\(w[i]) \(w[i+1]) \(w[i+2])") } }
            for g in Set(gs) where cands.contains(g) {
                var s = stat[g] ?? PhraseStat()
                s.count += 1
                s.uptake += m.uptake
                s.senders.insert(m.who)
                if m.date >= cut { s.recent += 1 } else { s.older += 1 }
                if m.date < s.first { s.first = m.date; s.firstWho = m.who }
                if m.body.contains(VernTokens.titlecase(g)) { s.titleHits += 1 }
                if m.fromMe && s.examples.count < 2 {
                    let one = m.body.replacingOccurrences(of: "\n", with: " ")
                    if !s.examples.contains(one) { s.examples.append(one) }
                }
                stat[g] = s
            }
        }
        self.stat = stat

        // register set = top-250 of your own words
        self.myCommon = Set(uni.sorted { $0.value > $1.value }.prefix(250).map { $0.key })
    }

    // MARK: - baseline / scoring primitives

    private func pb(_ w: String) -> Double { baseline.probability(of: w) }

    /// NPMI — collocation glue within the user's world.
    func npmi(_ gram: String, _ count: Int) -> Double {
        let ws = gram.split(separator: " ").map(String.init)
        let p = Double(count) / gramTotal
        guard p > 0 else { return 0 }
        var pi = 1.0
        for w in ws { pi *= Double(uni[w] ?? 1) / uniTotal }
        guard pi > 0 else { return 0 }
        let pmi = log(p / pi)
        let denom = -log(p)
        guard denom != 0 else { return 0 }
        return pmi / denom
    }

    /// Over-representation vs normal English (log ratio).
    func over(_ gram: String, _ count: Int) -> Double {
        let ws = gram.split(separator: " ").map(String.init)
        var e = 1.0
        for w in ws { e *= pb(w) }
        return log((Double(count) + 0.5) / (gramTotal * e + 0.5))
    }

    /// A phrase that is ENTIRELY register words is just how you text; real
    /// in-group slang carries ≥1 word outside the top-250 ("cone","goat").
    func hasNovelWord(_ gram: String) -> Bool {
        gram.split(separator: " ").contains {
            let w = String($0); return w.count >= 3 && !myCommon.contains(w)
        }
    }

    private func interesting(_ gram: String, _ s: PhraseStat) -> Double {
        let upPer = s.uptake / Double(s.count)
        let rise = Double(s.recent + 1) / Double(s.older + 1)
        let ov = over(gram, s.count)
        let np = max(npmi(gram, s.count), 0)
        return (max(ov - 2.5, 0.2) + 2.6 * np)
            * (1 + 1.6 * min(upPer, 3))
            * (1 + 0.35 * max(0, log(rise)))
    }

    // MARK: - slang phrases + repurposed

    /// Returns (slang, repurposed) phrase lists, both ranked. Recency is
    /// already accumulated into each `PhraseStat` (recent/older) in `init`.
    func rankPhrases(options: VernacularAnalyzer.Options) -> ([VernacularPhrase], [VernacularPhrase]) {
        func keep(_ g: String, _ s: PhraseStat) -> Bool {
            guard s.senders.count >= options.minSpread,
                  over(g, s.count) > options.slangOverRepGate,
                  hasNovelWord(g) else { return false }
            return Double(s.titleHits) / Double(s.count) < 0.5
        }

        var ranked = stat.filter { keep($0.key, $0.value) }
            .map { (g: $0.key, s: $0.value, score: interesting($0.key, $0.value)) }
        ranked.sort { $0.score > $1.score }

        let slang: [VernacularPhrase] = ranked.map { r in
            let s = r.s
            return VernacularPhrase(
                phrase: r.g,
                count: s.count,
                peopleCount: s.senders.count,
                uptakePerUse: s.uptake / Double(s.count),
                rising: s.recent > s.older && s.older > 0,
                example: s.examples.first,
                firstSeenWho: s.firstWho,
                firstSeenMonth: VernacularAnalyzer.monthLabel(s.first),
                isRepurposedCandidate: isRepurposed(r.g, s)
            )
        }

        // ---- repurposed common phrases (the "traffic cone" class) ----
        // Words individually common in English, but the PAIRING is rare
        // (over-rep) AND glued tight (NPMI) ⇒ ordinary words, in-group meaning.
        var repur: [(VernacularPhrase, Double)] = []
        for (g, s) in stat {
            let ws = g.split(separator: " ").map(String.init)
            guard ws.allSatisfy({ (baseline.counts[$0] ?? 0) > 6e-6 * baseline.totalCount || baseline.isKnown($0) }) else { continue }
            guard hasNovelWord(g) else { continue }
            guard s.senders.count >= options.minSpread, Double(s.titleHits) / Double(s.count) < 0.5 else { continue }
            let ov = over(g, s.count); let np = max(npmi(g, s.count), 0)
            guard ov > 4.2, np > 0.4 else { continue }
            let score = ov * np * (1 + 0.5 * s.uptake / Double(s.count))
            let p = VernacularPhrase(
                phrase: g, count: s.count, peopleCount: s.senders.count,
                uptakePerUse: s.uptake / Double(s.count),
                rising: s.recent > s.older && s.older > 0,
                example: s.examples.first,
                firstSeenWho: s.firstWho, firstSeenMonth: VernacularAnalyzer.monthLabel(s.first),
                isRepurposedCandidate: true
            )
            repur.append((p, score))
        }
        let repurposed = repur.sorted { $0.1 > $1.1 }.map { $0.0 }
        return (slang, repurposed)
    }

    /// Heuristic flag: are all words individually common English but the
    /// pairing rare+glued? (Used only to tag a slang phrase for the AI layer.)
    private func isRepurposed(_ g: String, _ s: PhraseStat) -> Bool {
        let ws = g.split(separator: " ").map(String.init)
        guard ws.allSatisfy({ baseline.isKnown($0) }) else { return false }
        return over(g, s.count) > 4.2 && max(npmi(g, s.count), 0) > 0.4
    }

    // MARK: - approval/question tags ("… word?")

    func approvalTags(options: VernacularAnalyzer.Options) -> [VernacularConstruction] {
        var tagEnd: [String: Int] = [:]
        var tagUp: [String: Double] = [:]
        for m in messages {
            let b = m.body.trimmingCharacters(in: .whitespaces)
            guard b.hasSuffix("?") else { continue }
            let w = m.words
            guard let last = w.last else { continue }
            tagEnd[last, default: 0] += 1
            tagUp[last, default: 0] += m.uptake
        }
        return tagEnd.sorted { $0.value > $1.value }
            .filter { $0.value >= options.minTagCount }
            .prefix(10)
            .map { (w, c) in
                VernacularConstruction(pattern: "… \(w)?", family: .tag, count: c,
                                       uptakePerUse: (tagUp[w] ?? 0) / Double(c))
            }
    }

    // MARK: - caps / vocative constructions

    /// Detects the "… NOT … lil bro" family + "brother …" + "… no?". Counted
    /// over the user's own sent messages (these are the user's constructions),
    /// matching the prototype.
    func capsVocativeConstructions() -> [VernacularConstruction] {
        var construct: [String: Int] = [:]
        var cup: [String: Double] = [:]
        for m in messages where m.fromMe {
            let low = m.bodyLow
            if low.contains(" not ") && low.contains("lil bro") {
                construct["… NOT … lil bro", default: 0] += 1
                cup["… NOT … lil bro", default: 0] += m.uptake
            }
            if low.hasSuffix("lil bro") || low.hasSuffix("lil bro \u{1F62D}") {
                construct["… lil bro", default: 0] += 1
                cup["… lil bro", default: 0] += m.uptake
            }
            if low.hasPrefix("brother ") {
                construct["brother …", default: 0] += 1
                cup["brother …", default: 0] += m.uptake
            }
            if low.hasSuffix(" no?") || low.hasSuffix(", no?") {
                construct["… no?", default: 0] += 1
                cup["… no?", default: 0] += m.uptake
            }
        }
        return construct.sorted { $0.value > $1.value }.map { (t, c) in
            VernacularConstruction(pattern: t, family: .construction, count: c,
                                   uptakePerUse: (cup[t] ?? 0) / Double(max(c, 1)))
        }
    }

    // MARK: - sense splits (Layer 2 summary over the user's own messages)

    func senseSplits() -> [VernacularSenseSplit] {
        var voc: [String: Int] = [:]
        var lit: [String: Int] = [:]
        for m in messages where m.fromMe {
            let w = m.words
            for (i, tok) in w.enumerated() {
                let lemma = tok.lowercased()
                guard VernacularSenseRules.isAmbiguousAddressTerm(lemma)
                    || VernacularSenseRules.isRegisteredPlural(lemma) else { continue }
                // map a plural to its singular lemma for the summary bucket
                let bucket = VernacularSenseRules.isAmbiguousAddressTerm(lemma)
                    ? lemma
                    : singularOf(lemma)
                switch VernacularSenseRules.classify(term: lemma, at: i, in: w) {
                case .vocative: voc[bucket, default: 0] += 1
                case .literal:  lit[bucket, default: 0] += 1
                case .none:     break
                }
            }
        }
        // Only surface terms where the vocative (slang) sense is meaningful.
        let terms = Set(voc.keys).union(lit.keys)
        return terms.compactMap { t -> VernacularSenseSplit? in
            let v = voc[t] ?? 0
            guard v >= 5 else { return nil }
            return VernacularSenseSplit(term: t, vocativeCount: v, literalCount: lit[t] ?? 0)
        }.sorted { $0.vocativeCount > $1.vocativeCount }
    }

    private func singularOf(_ plural: String) -> String {
        for (singular, plurals) in VernacularSenseRules.ambiguousTerms where plurals.contains(plural) {
            return singular
        }
        return plural
    }
}
