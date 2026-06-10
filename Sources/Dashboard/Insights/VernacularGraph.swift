//
//  VernacularGraph.swift
//  Hourglass — Vernacular Analysis (bidirectional language-trade graph)
//
//  Adds the OUTGOING direction to the engine's existing DECISIVE INCOMING
//  attribution and folds both into ONE Sendable graph the UI can render: who
//  you got terms FROM (incoming), and who got terms FROM YOU (outgoing).
//
//  Faithful port of the validated standalone prototype `/tmp/trade/main.swift`
//  (run against the real chat.db, 517,418 msgs). The two directional rules:
//
//  INCOMING (they → you) — the same DECISIVE rule as `VernacularAnalyzer.attribute`:
//    • they used the term ≥5× strictly BEFORE your first use
//    • their first use ≥30 days before your first use
//    • they dominate: before-count ≥ 2× the runner-up (or sole early user)
//
//  OUTGOING (you → them) — the NEW part:
//    • you used the term ≥5× strictly BEFORE their first use
//    • your first use ≥30 days before their first use
//    • you dominate: your before-their-first count ≥ 2× the max OTHER contact's
//      before-their-first count (or you're the sole prior user)
//    • they actually adopted it: their total uses ≥4
//    • DISTINCTIVENESS GATE (critical): the term is used by ≤20 DISTINCT
//      contacts total. Ambient register (ur/tho/cuz/lemme/yk/fs…) is excluded —
//      you can't be credited with giving someone "ur"; the culture gave it to
//      them. Without this gate the outgoing side is garbage.
//
//  CANDIDATE TERMS are supplied by the Phase-1 spread profile. This file owns
//  only the shared incoming/outgoing directional math.
//
//  PURE: graph assembly is a deterministic function of ready term accumulators
//  plus `[VernacularMessage]`. The chat.db read lives in `VernacularLoader`;
//  this file does no I/O.
//

import Foundation

// MARK: - Public graph model

/// The bidirectional vernacular-trade graph. One `Sendable` value the panel can
/// render directly: a node per person (plus a "You" node) and a directed edge
/// per (person, direction) carrying the traded terms.
public struct VernacularGraph: Sendable, Equatable {

    /// A node: a contact, or you. Counts are # of DISTINCT terms on each side.
    public struct Person: Sendable, Equatable, Identifiable {
        public let id: String          // contact display name, or "You"
        public let isYou: Bool
        public let gaveYouCount: Int   // # distinct terms they gave you (incoming)
        public let tookFromYouCount: Int // # distinct terms they took from you (outgoing)
        public init(id: String, isYou: Bool, gaveYouCount: Int, tookFromYouCount: Int) {
            self.id = id
            self.isYou = isYou
            self.gaveYouCount = gaveYouCount
            self.tookFromYouCount = tookFromYouCount
        }
    }

    /// One traded term on an edge.
    public struct TermFlow: Sendable, Equatable {
        public let term: String
        /// their-uses-before-you (incoming) OR your-uses-before-them (outgoing).
        public let count: Int
        public let yourFirstUse: Date
        public let theirFirstUse: Date
        /// A representative real message (the adopter's first use for outgoing,
        /// the source's first use for incoming). Truncated, newlines stripped.
        public let example: String?
        public init(term: String, count: Int, yourFirstUse: Date, theirFirstUse: Date, example: String?) {
            self.term = term
            self.count = count
            self.yourFirstUse = yourFirstUse
            self.theirFirstUse = theirFirstUse
            self.example = example
        }
    }

    /// A directed edge between you and one other person.
    public struct Edge: Sendable, Equatable, Identifiable {
        public enum Direction: String, Sendable, Equatable { case theyGaveYou, youGaveThem }
        public let id: String          // "\(person)|\(direction)"
        public let person: String      // the OTHER person (never "You")
        public let direction: Direction
        public let terms: [TermFlow]   // sorted by count desc
        public var weight: Int { terms.count }
        public init(person: String, direction: Direction, terms: [TermFlow]) {
            self.id = "\(person)|\(direction.rawValue)"
            self.person = person
            self.direction = direction
            self.terms = terms
        }
    }

    public let people: [Person]        // includes a Person with isYou == true
    public let edges: [Edge]
    public init(people: [Person], edges: [Edge]) {
        self.people = people
        self.edges = edges
    }

    public static let empty = VernacularGraph(people: [], edges: [])
    public var isEmpty: Bool { edges.isEmpty }
}

// MARK: - Builder (pure, on `VernacularAnalyzer`)

public extension VernacularAnalyzer {

    /// Tunables for the bidirectional graph. Mirrors `/tmp/trade`'s constants and
    /// shares the incoming thresholds with `Options` (≥5 before, ≥30 days, 2×).
    struct GraphOptions: Sendable {
        /// Incoming/outgoing: min uses strictly before the other side's first.
        public var minBefore: Int
        /// Incoming/outgoing: min days the earlier user must precede the later.
        public var minDays: Double
        /// Dominance ratio (before-count ≥ ratio × runner-up, or sole user).
        public var dominanceRatio: Double
        /// Outgoing: min total uses the adopter must have (they actually took it).
        public var adopterMinTotal: Int
        /// Outgoing DISTINCTIVENESS GATE: term must be used by ≤ this many
        /// distinct contacts total (else it's ambient register, excluded).
        public var maxDistinctContacts: Int
        /// Truncate example messages to this many characters.
        public var exampleMaxChars: Int

        public init(
            minBefore: Int = 5,
            minDays: Double = 30,
            dominanceRatio: Double = 2.0,
            adopterMinTotal: Int = 4,
            maxDistinctContacts: Int = 20,
            exampleMaxChars: Int = 120
        ) {
            self.minBefore = minBefore
            self.minDays = minDays
            self.dominanceRatio = dominanceRatio
            self.adopterMinTotal = adopterMinTotal
            self.maxDistinctContacts = maxDistinctContacts
            self.exampleMaxChars = exampleMaxChars
        }

        public static let `default` = GraphOptions()
    }

    /// Run the populate-pass + directional rules over a READY list of
    /// accumulators (curated OR universe-derived) and assemble the graph. PURE.
    /// Split out so the curated test path and the unified shipping path share
    /// the EXACT same incoming/outgoing math + exposure gate. `internal` (not
    /// `public`) because `GraphAcc` is an internal type.
    internal static func assembleGraph(
        accumulators matchers: [GraphAcc],
        messages: [VernacularMessage],
        chatParticipants: [Int64: Set<String>] = [:],
        options: GraphOptions = .default
    ) -> VernacularGraph {

        let day = 86_400.0
        // single pass: populate every accumulator's events / per-side stats.
        for m in messages {
            let isYou = m.fromMe
            let who = m.who
            let known = !isYou && who != Self.unknownLabel
            // sender bucket: "You" for sent, the resolved name for known received,
            // skipped entirely for unknown handles (can't attribute to/from them).
            if !isYou && !known { continue }
            for a in matchers where a.pred(m) {
                if isYou {
                    a.yourTotal += 1
                    if m.date < a.yourFirst { a.yourFirst = m.date; a.yourFirstBody = m.body }
                    a.events.append(Event(date: m.date, who: "You"))
                    // Record the chat of each of YOUR uses for the shared-exposure
                    // gate (could the adopter SEE you use it in a chat they're in?).
                    a.yourUses.append(YourUse(date: m.date, chat: m.chat))
                } else {
                    a.total[who, default: 0] += 1
                    if (a.firstByContact[who] ?? .greatestFiniteMagnitude) > m.date {
                        a.firstByContact[who] = m.date
                        a.firstBodyByContact[who] = m.body
                    }
                    a.events.append(Event(date: m.date, who: who))
                }
            }
        }
        // events accumulate in message order; the directional math sorts by date
        // where it matters, but we keep them as-is (prototype appends in the
        // ascending load order — counts are order-independent).

        // ── per-edge aggregation ─────────────────────────────────────────────
        // incoming: source -> [TermFlow]    outgoing: adopter -> [TermFlow]
        var incomingBySource: [String: [VernacularGraph.TermFlow]] = [:]
        var outgoingByAdopter: [String: [VernacularGraph.TermFlow]] = [:]

        for a in matchers {
            if let inc = incoming(a, options: options, day: day) {
                let flow = VernacularGraph.TermFlow(
                    term: a.label,
                    count: inc.before,
                    yourFirstUse: Date(timeIntervalSince1970: a.yourFirst),
                    theirFirstUse: Date(timeIntervalSince1970: inc.sourceFirst),
                    example: truncatedExample(a.firstBodyByContact[inc.source], max: options.exampleMaxChars)
                )
                incomingBySource[inc.source, default: []].append(flow)
            }
            for out in outgoing(a, options: options, day: day, chatParticipants: chatParticipants) {
                let flow = VernacularGraph.TermFlow(
                    term: a.label,
                    count: out.youBefore,
                    yourFirstUse: Date(timeIntervalSince1970: a.yourFirst),
                    theirFirstUse: Date(timeIntervalSince1970: out.adopterFirst),
                    example: truncatedExample(a.firstBodyByContact[out.adopter], max: options.exampleMaxChars)
                )
                outgoingByAdopter[out.adopter, default: []].append(flow)
            }
        }

        // ── assemble edges + nodes ───────────────────────────────────────────
        var edges: [VernacularGraph.Edge] = []
        for (src, flows) in incomingBySource {
            edges.append(VernacularGraph.Edge(
                person: src, direction: .theyGaveYou,
                terms: flows.sorted { $0.count > $1.count }))
        }
        for (adopter, flows) in outgoingByAdopter {
            edges.append(VernacularGraph.Edge(
                person: adopter, direction: .youGaveThem,
                terms: flows.sorted { $0.count > $1.count }))
        }
        // stable order: heavier edges first, then person, then direction.
        edges.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.person != $1.person { return $0.person < $1.person }
            return $0.direction.rawValue < $1.direction.rawValue
        }

        var people: [VernacularGraph.Person] = []
        let names = Set(incomingBySource.keys).union(outgoingByAdopter.keys)
        for name in names.sorted() {
            people.append(VernacularGraph.Person(
                id: name, isYou: false,
                gaveYouCount: incomingBySource[name]?.count ?? 0,
                tookFromYouCount: outgoingByAdopter[name]?.count ?? 0))
        }
        // the "You" node: gaveYou = total distinct terms you handed out;
        // tookFromYou = total distinct terms you picked up (the mirror counts).
        let youGave = outgoingByAdopter.values.reduce(0) { $0 + $1.count }
        let youGot = incomingBySource.values.reduce(0) { $0 + $1.count }
        people.insert(VernacularGraph.Person(
            id: "You", isYou: true, gaveYouCount: youGot, tookFromYouCount: youGave), at: 0)

        return VernacularGraph(people: people, edges: edges)
    }

    // MARK: - directional rules (ported verbatim from /tmp/trade)

    /// INCOMING: you got `a.label` from a single dominant early source.
    /// Internal (not private) so the spread overlay can reuse the exact same
    /// decisive source rule per item.
    internal static func incoming(
        _ a: GraphAcc, options: GraphOptions, day: Double,
        minBeforeOverride: Int? = nil
    ) -> (source: String, before: Int, sourceFirst: Double)? {
        guard a.yourTotal > 0, a.yourFirst < .greatestFiniteMagnitude else { return nil }
        let minBefore = minBeforeOverride ?? options.minBefore
        var before: [String: Int] = [:]
        for e in a.events where e.who != "You" && e.date < a.yourFirst {
            before[e.who, default: 0] += 1
        }
        // qualifiers: ≥minBefore uses before you AND first use ≥minDays before you.
        let qualifiers = before.keys.filter {
            before[$0]! >= minBefore
                && (a.firstByContact[$0] ?? a.yourFirst) <= a.yourFirst - options.minDays * day
        }
        guard let top = qualifiers.max(by: { before[$0]! < before[$1]! }) else { return nil }
        // dominance vs the runner-up across ALL early users (matches prototype).
        let runner = before.keys.filter { $0 != top }.map { before[$0]! }.max() ?? 0
        guard runner == 0 || Double(before[top]!) >= options.dominanceRatio * Double(runner) else { return nil }
        return (top, before[top]!, a.firstByContact[top]!)
    }

    /// OUTGOING: contacts who got `a.label` from you (with the distinctiveness
    /// gate AND the shared-exposure gate). Internal (not private) so the spread
    /// overlay can reuse the exact same exposure-gated rule per item.
    internal static func outgoing(
        _ a: GraphAcc, options: GraphOptions, day: Double,
        chatParticipants: [Int64: Set<String>],
        minBeforeOverride: Int? = nil
    ) -> [(adopter: String, youBefore: Int, adopterFirst: Double)] {
        let minBefore = minBeforeOverride ?? options.minBefore
        guard a.yourTotal >= minBefore, a.yourFirst < .greatestFiniteMagnitude else { return [] }
        // DISTINCTIVENESS GATE: only transmissible signatures (marked slang /
        // repurposed phrases / constructions) can be "given" to someone. Ambient
        // register, ordinary phrases, and auto-mined n-grams are incoming-only.
        guard a.distinctive else { return [] }
        // and niche terms only (≤maxDistinctContacts users).
        guard a.total.count <= options.maxDistinctContacts else { return [] }
        // Enforce the shared-exposure gate ONLY when we actually have chat
        // membership data; with no map we can't disprove exposure (keeps the
        // pure unit-test corpora — which pass no map — behaving as before).
        let enforceExposure = !chatParticipants.isEmpty
        var result: [(String, Int, Double)] = []
        for (contact, total) in a.total where total >= options.adopterMinTotal {
            guard let contactFirst = a.firstByContact[contact],
                  a.yourFirst <= contactFirst - options.minDays * day else { continue }
            // your-uses-before-their-first, and the max OTHER contact's before-their-first.
            var youBefore = 0
            var otherBefore: [String: Int] = [:]
            for e in a.events where e.date < contactFirst {
                if e.who == "You" { youBefore += 1 }
                else if e.who != contact { otherBefore[e.who, default: 0] += 1 }
            }
            guard youBefore >= minBefore else { continue }
            let other = otherBefore.values.max() ?? 0
            guard other == 0 || Double(youBefore) >= options.dominanceRatio * Double(other) else { continue }
            // SHARED-EXPOSURE GATE (Fix #1): keep this adopter ONLY if YOU used
            // the term in a chat THEY are a member of, dated strictly BEFORE
            // their first use — i.e. they could actually SEE you use it. Without
            // this we falsely credit transmission across people who never shared
            // a chat where you used the term (e.g. "kewl"→Ishir).
            if enforceExposure {
                let exposed = a.yourUses.contains { use in
                    use.date < contactFirst
                        && (chatParticipants[use.chat]?.contains(contact) ?? false)
                }
                guard exposed else { continue }
            }
            result.append((contact, youBefore, contactFirst))
        }
        return result.sorted { $0.2 < $1.2 }
    }

    // MARK: - example helper

    static func truncatedExample(_ body: String?, max: Int) -> String? {
        guard let body else { return nil }
        let oneLine = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        if oneLine.count <= max { return oneLine }
        return String(oneLine.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - per-candidate accumulator (mirror of /tmp/trade's `Acc`)

/// A single time-stamped use of a term, attributed to "You" or a contact name.
struct Event: Sendable { let date: Double; let who: String }

/// One of YOUR uses of a term, with the chat it happened in — feeds the
/// shared-exposure gate (could an adopter SEE you use it in a chat they share?).
struct YourUse: Sendable { let date: Double; let chat: Int64 }

/// Accumulated stats for one candidate term across the corpus. A class so the
/// single populate-pass can mutate it in place (matching the prototype's `Acc`).
final class GraphAcc {
    let label: String
    let pred: (VernacularMessage) -> Bool
    /// Whether this term is a *transmissible signature* — marked slang, a
    /// repurposed/idiomatic phrase, or a construction. Only distinctive terms
    /// can produce OUTGOING ("you gave them") edges. Ambient register (ur/tho/
    /// cuz), ordinary short phrases (ok sg/last yr/p much), and auto-mined
    /// n-grams are NOT distinctive: they stay incoming-only, where the decisive
    /// rule already rejects them. (User feedback: "little phrases … cannot be
    /// said come from me".)
    let distinctive: Bool
    var events: [Event] = []
    /// Every one of YOUR uses (date + chat), for the shared-exposure gate.
    var yourUses: [YourUse] = []
    var yourFirst = Double.greatestFiniteMagnitude
    var yourFirstBody: String?
    var yourTotal = 0
    var total: [String: Int] = [:]                 // contact -> total uses
    var firstByContact: [String: Double] = [:]      // contact -> first-use date
    var firstBodyByContact: [String: String] = [:]  // contact -> first-use body
    init(_ label: String, _ pred: @escaping (VernacularMessage) -> Bool, distinctive: Bool = false) {
        self.label = label
        self.pred = pred
        self.distinctive = distinctive
    }
}

// Internal (not private) so the spread profile and tests can reuse the exact
// same token matching helpers as the directional graph rules.
extension VernacularAnalyzer {

    /// Substring match of token sequence `pattern` inside token sequence `tokens`.
    static func hasSubsequence(_ tokens: [String], _ pattern: [String]) -> Bool {
        if pattern.isEmpty || pattern.count > tokens.count { return false }
        let lim = tokens.count - pattern.count
        var i = 0
        while i <= lim {
            var ok = true
            var j = 0
            while j < pattern.count {
                if tokens[i + j] != pattern[j] { ok = false; break }
                j += 1
            }
            if ok { return true }
            i += 1
        }
        return false
    }

}
