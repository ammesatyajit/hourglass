//
//  VernacularGraphTests.swift
//  HourglassTests
//
//  Pure-logic coverage for the shared bidirectional vernacular-trade rules.
//  Small hand-built corpora — no chat.db, no model. Mirrors the assertions the
//  out-of-band harness checks against the real chat.db (Venkat incoming,
//  traffic-cone outgoing, distinctiveness gate).
//
//  NOTE: `./scripts/test.sh` currently HANGS on the documented XCTest-host
//  model-load issue (Qwen mmap), so these were verified via the `swiftc -O`
//  harness in /tmp/graphtest. They run normally once the host hang is fixed.
//

import XCTest
@testable import Hourglass

private func gmsg(_ body: String, fromMe: Bool, who: String, day: Double) -> VernacularMessage {
    VernacularMessage(date: day * 86_400, chat: 1, fromMe: fromMe, who: who, body: body, uptake: 0)
}

private func spreadTerm(_ surface: String, distinctive: Bool = false) -> SpreadTermSpec {
    SpreadTermSpec(surface: surface,
                   tokens: surface.split(separator: " ").map(String.init),
                   distinctive: distinctive)
}

private func graphFor(_ msgs: [VernacularMessage], terms: [SpreadTermSpec]) -> VernacularGraph {
    VernacularAnalyzer.assembleGraph(accumulators: VernacularAnalyzer.spreadAccumulators(for: terms),
                                     messages: msgs)
}

final class VernacularGraphTests: XCTestCase {

    // MARK: helpers

    private func incoming(_ g: VernacularGraph, _ person: String) -> [String] {
        (g.edges.first { $0.person == person && $0.direction == .theyGaveYou }?.terms ?? []).map { $0.term }
    }
    private func outgoing(_ g: VernacularGraph, _ person: String) -> [String] {
        (g.edges.first { $0.person == person && $0.direction == .youGaveThem }?.terms ?? []).map { $0.term }
    }
    private func adopters(_ g: VernacularGraph, of term: String) -> [String] {
        g.edges.filter { $0.direction == .youGaveThem && $0.terms.contains { $0.term == term } }.map { $0.person }
    }

    // MARK: incoming (they → you)

    func testIncomingDecisiveSource() {
        var msgs: [VernacularMessage] = []
        // Venkat uses "deadass" 6× from day 0; you start day 100 (>30d later).
        for i in 0..<6 { msgs.append(gmsg("deadass", fromMe: false, who: "Venkat", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("deadass", fromMe: true, who: "You", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("deadass")])
        XCTAssertTrue(incoming(g, "Venkat").contains("deadass"))
        // the edge carries the source's before-count and an example.
        let edge = g.edges.first { $0.person == "Venkat" && $0.direction == .theyGaveYou }
        XCTAssertEqual(edge?.terms.first?.count, 6)
        XCTAssertEqual(edge?.terms.first?.example, "deadass")
    }

    func testIncomingFailsWithinThirtyDays() {
        var msgs: [VernacularMessage] = []
        for i in 0..<6 { msgs.append(gmsg("lowkey", fromMe: false, who: "Dave", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("lowkey", fromMe: true, who: "You", day: 5 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("lowkey")])
        XCTAssertFalse(incoming(g, "Dave").contains("lowkey"), "source must precede you by ≥30 days")
    }

    func testIncomingUnknownHandleExcluded() {
        var msgs: [VernacularMessage] = []
        let unknown = VernacularAnalyzer.unknownLabel
        for i in 0..<8 { msgs.append(gmsg("hella", fromMe: false, who: unknown, day: Double(i))) }
        for i in 0..<6 { msgs.append(gmsg("hella", fromMe: true, who: "You", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("hella")])
        XCTAssertTrue(g.edges.first { $0.direction == .theyGaveYou }?.person != unknown
                      || g.edges.isEmpty, "the unknown sentinel is never a named source")
        XCTAssertNil(g.edges.first { $0.person == unknown })
    }

    // MARK: outgoing (you → them)

    func testOutgoingYouGaveDistinctiveTerm() {
        var msgs: [VernacularMessage] = []
        // "traffic cone" is a curated phrase. You use it 6× from day 0; Beck
        // adopts it 5× starting day 100 (>30d later, ≥4 uses). Only 1 contact
        // ever uses it → passes the ≤20 distinctiveness gate.
        for i in 0..<6 { msgs.append(gmsg("traffic cone", fromMe: true, who: "You", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("traffic cone", fromMe: false, who: "Beck", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("traffic cone", distinctive: true)])
        XCTAssertTrue(adopters(g, of: "traffic cone").contains("Beck"))
        XCTAssertTrue(outgoing(g, "Beck").contains("traffic cone"))
        // example = the adopter's FIRST message containing the term.
        let edge = g.edges.first { $0.person == "Beck" && $0.direction == .youGaveThem }
        XCTAssertEqual(edge?.terms.first { $0.term == "traffic cone" }?.example, "traffic cone")
    }

    func testOutgoingFailsWhenAdopterUsesTooFew() {
        var msgs: [VernacularMessage] = []
        for i in 0..<6 { msgs.append(gmsg("traffic cone", fromMe: true, who: "You", day: Double(i))) }
        // adopter uses it only 3× → below the ≥4 adoption floor.
        for i in 0..<3 { msgs.append(gmsg("traffic cone", fromMe: false, who: "Beck", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("traffic cone", distinctive: true)])
        XCTAssertFalse(adopters(g, of: "traffic cone").contains("Beck"), "adopter must use it ≥4×")
    }

    // MARK: distinctiveness gate

    func testAmbientTermExcludedFromOutgoing() {
        var msgs: [VernacularMessage] = []
        // "ur" is ambient: you use it heavily before an adopter, but it's used
        // by 21 distinct contacts → the ≤20 gate excludes it from outgoing.
        for i in 0..<30 { msgs.append(gmsg("ur", fromMe: true, who: "You", day: Double(i))) }
        for c in 0..<21 {
            for i in 0..<5 { msgs.append(gmsg("ur", fromMe: false, who: "C\(c)", day: 200 + Double(i))) }
        }
        let g = graphFor(msgs, terms: [spreadTerm("ur", distinctive: true)])
        XCTAssertTrue(adopters(g, of: "ur").isEmpty,
                      "an ambient term used by >20 contacts is never an outgoing flow")
    }

    func testNicheTermPassesGate() {
        var msgs: [VernacularMessage] = []
        // same shape but only 3 adopters (≤20) → "traffic cone" DOES flow out.
        for i in 0..<30 { msgs.append(gmsg("traffic cone", fromMe: true, who: "You", day: Double(i))) }
        for c in 0..<3 {
            for i in 0..<5 { msgs.append(gmsg("traffic cone", fromMe: false, who: "C\(c)", day: 200 + Double(i))) }
        }
        let g = graphFor(msgs, terms: [spreadTerm("traffic cone", distinctive: true)])
        XCTAssertEqual(Set(adopters(g, of: "traffic cone")), ["C0", "C1", "C2"])
    }

    // MARK: graph shape

    func testYouNodePresentAndCountsMirror() {
        var msgs: [VernacularMessage] = []
        for i in 0..<6 { msgs.append(gmsg("deadass", fromMe: false, who: "Venkat", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("deadass", fromMe: true, who: "You", day: 100 + Double(i))) }
        for i in 0..<6 { msgs.append(gmsg("traffic cone", fromMe: true, who: "You", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("traffic cone", fromMe: false, who: "Beck", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("deadass"),
                                       spreadTerm("traffic cone", distinctive: true)])
        let you = g.people.first { $0.isYou }
        XCTAssertNotNil(you)
        XCTAssertEqual(you?.id, "You")
        // You got 1 term (deadass) and gave 1 term (traffic cone).
        XCTAssertEqual(you?.tookFromYouCount, 1, "you gave 1 distinct term")
        XCTAssertEqual(you?.gaveYouCount, 1, "you got 1 distinct term")
        // per-person counts
        XCTAssertEqual(g.people.first { $0.id == "Venkat" }?.gaveYouCount, 1)
        XCTAssertEqual(g.people.first { $0.id == "Beck" }?.tookFromYouCount, 1)
    }

    func testEdgeIDIsStableAndTermsSortedByCountDesc() {
        var msgs: [VernacularMessage] = []
        // two outgoing terms to one person with different before-counts.
        for i in 0..<8 { msgs.append(gmsg("traffic cone", fromMe: true, who: "You", day: Double(i))) }
        for i in 0..<6 { msgs.append(gmsg("plot armor", fromMe: true, who: "You", day: Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("traffic cone", fromMe: false, who: "Beck", day: 100 + Double(i))) }
        for i in 0..<5 { msgs.append(gmsg("plot armor", fromMe: false, who: "Beck", day: 100 + Double(i))) }
        let g = graphFor(msgs, terms: [spreadTerm("traffic cone", distinctive: true),
                                       spreadTerm("plot armor", distinctive: true)])
        let edge = g.edges.first { $0.person == "Beck" && $0.direction == .youGaveThem }
        XCTAssertEqual(edge?.id, "Beck|youGaveThem")
        let counts = edge?.terms.map { $0.count } ?? []
        XCTAssertEqual(counts, counts.sorted(by: >), "terms sorted by count desc")
    }
}
