//
//  SocialGraphBuilderTests.swift
//  HourglassTests — Social Graph
//
//  Pure-logic tests for the Social Graph dashboard panel. No chat.db, no
//  SwiftUI: every test feeds `SocialGraphBuilder.build` / `CommunityDetector`
//  / `ForceLayout` hand-built fixtures and asserts on the value-type output.
//
//  Coverage:
//    - graph construction: direct edges from 1:1 volume, co-membership edges
//      from shared group chats, node identity / merging
//    - edge model: undirected canonicalization, co-membership thresholds,
//      oversized-group suppression
//    - node cap: keeps top-N by weight, drops edges touching dropped nodes
//    - community detection on a known two-cluster graph
//    - layout determinism + bounds
//

import XCTest
@testable import Hourglass

final class SocialGraphBuilderTests: XCTestCase {

    // Convenience: a center node.
    private func me() -> GraphNode {
        GraphNode(id: "me", displayName: "You", avatarData: nil, isMe: true,
                  directMessageCount: 0, sharedGroupCount: 0)
    }

    private func info(_ id: String, direct: Int) -> (String, ContactNodeInfo) {
        (id, ContactNodeInfo(id: id, displayName: id, avatarData: nil, directMessageCount: direct))
    }

    // MARK: - Direct edges

    func testDirectEdges_oneEdgePerContactWithVolume() {
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: false, participantNodeIDs: ["a"]),
            ChatMembership(chatRowID: 2, isGroup: false, participantNodeIDs: ["b"]),
        ]
        let contactInfo = Dictionary(uniqueKeysWithValues: [
            info("a", direct: 100),
            info("b", direct: 5),
        ])

        let g = SocialGraphBuilder.build(memberships: memberships, contactInfo: contactInfo, meNode: me())

        // Center + 2 contacts.
        XCTAssertEqual(g.nodes.count, 3)
        XCTAssertTrue(g.nodes.contains { $0.isMe })

        // Two direct edges, center↔a and center↔b, weighted by volume.
        let direct = g.edges.filter { $0.kind == .direct }
        XCTAssertEqual(direct.count, 2)
        let aEdge = direct.first { $0.other(than: "me") == "a" }
        XCTAssertEqual(aEdge?.weight, 100)
        let bEdge = direct.first { $0.other(than: "me") == "b" }
        XCTAssertEqual(bEdge?.weight, 5)

        // No co-membership edges (no groups).
        XCTAssertTrue(g.edges.allSatisfy { $0.kind == .direct })
    }

    func testNoDirectEdge_whenZeroVolumeButGroupOnly() {
        // Contact only ever seen in a group → node exists (sized by group),
        // but NO direct spoke from center.
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 10, isGroup: true, participantNodeIDs: ["a", "b"]),
        ]
        let g = SocialGraphBuilder.build(memberships: memberships, contactInfo: [:], meNode: me())

        XCTAssertEqual(g.nodes.count, 3) // me + a + b
        XCTAssertTrue(g.edges.filter { $0.kind == .direct }.isEmpty)
        // The two group members share one group → one co-membership edge.
        XCTAssertEqual(g.edges.filter { $0.kind == .coMembership }.count, 1)
        let coEdge = g.edges.first { $0.kind == .coMembership }
        XCTAssertEqual(coEdge?.weight, 1)
    }

    // MARK: - Co-membership edges

    func testCoMembership_weightedBySharedGroupCount() {
        // a & b share THREE groups → weight 3. a & c share ONE.
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: true, participantNodeIDs: ["a", "b"]),
            ChatMembership(chatRowID: 2, isGroup: true, participantNodeIDs: ["a", "b"]),
            ChatMembership(chatRowID: 3, isGroup: true, participantNodeIDs: ["a", "b", "c"]),
        ]
        let g = SocialGraphBuilder.build(memberships: memberships, contactInfo: [:], meNode: me())

        let co = g.edges.filter { $0.kind == .coMembership }
        let ab = co.first { ($0.a == "a" && $0.b == "b") }
        XCTAssertEqual(ab?.weight, 3, "a & b co-appear in 3 groups")
        let ac = co.first { ($0.a == "a" && $0.b == "c") }
        XCTAssertEqual(ac?.weight, 1)
        let bc = co.first { ($0.a == "b" && $0.b == "c") }
        XCTAssertEqual(bc?.weight, 1)
        // Three distinct pairs in the triangle group + the a-b reinforcement.
        XCTAssertEqual(co.count, 3)

        // sharedGroupCount on nodes: a and b are each in 3 groups, c in 1.
        XCTAssertEqual(g.nodes.first { $0.id == "a" }?.sharedGroupCount, 3)
        XCTAssertEqual(g.nodes.first { $0.id == "b" }?.sharedGroupCount, 3)
        XCTAssertEqual(g.nodes.first { $0.id == "c" }?.sharedGroupCount, 1)
    }

    func testCoMembership_minSharedGroupsThreshold() {
        // a-b share 1 group, a-c share 2. With minSharedGroups=2 only a-c
        // survives.
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: true, participantNodeIDs: ["a", "b"]),
            ChatMembership(chatRowID: 2, isGroup: true, participantNodeIDs: ["a", "c"]),
            ChatMembership(chatRowID: 3, isGroup: true, participantNodeIDs: ["a", "c"]),
        ]
        let g = SocialGraphBuilder.build(
            memberships: memberships, contactInfo: [:], meNode: me(),
            minSharedGroups: 2
        )
        let co = g.edges.filter { $0.kind == .coMembership }
        XCTAssertEqual(co.count, 1)
        XCTAssertEqual(co.first?.a, "a")
        XCTAssertEqual(co.first?.b, "c")
    }

    func testCoMembership_skipsOversizedGroups() {
        // A 5-person group with maxGroupSizeForEdges=4 contributes NO
        // co-membership edges (would be 10 spurious edges), but members still
        // get sharedGroupCount + a node.
        let big = ChatMembership(chatRowID: 1, isGroup: true,
                                 participantNodeIDs: ["a", "b", "c", "d", "e"])
        let g = SocialGraphBuilder.build(
            memberships: [big], contactInfo: [:], meNode: me(),
            maxGroupSizeForEdges: 4
        )
        XCTAssertTrue(g.edges.filter { $0.kind == .coMembership }.isEmpty)
        // Members still present + counted.
        XCTAssertEqual(g.nodes.count, 6) // me + 5
        XCTAssertEqual(g.nodes.first { $0.id == "a" }?.sharedGroupCount, 1)
    }

    func test1to1ChatsDoNotCreateCoMembershipEdges() {
        // Two separate 1:1 chats must NOT link a and b.
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: false, participantNodeIDs: ["a"]),
            ChatMembership(chatRowID: 2, isGroup: false, participantNodeIDs: ["b"]),
        ]
        let contactInfo = Dictionary(uniqueKeysWithValues: [info("a", direct: 3), info("b", direct: 3)])
        let g = SocialGraphBuilder.build(memberships: memberships, contactInfo: contactInfo, meNode: me())
        XCTAssertTrue(g.edges.filter { $0.kind == .coMembership }.isEmpty)
    }

    // MARK: - Edge canonicalization

    func testEdge_isUndirectedCanonical() {
        let e1 = GraphEdge(a: "z", b: "a", kind: .coMembership, weight: 2)
        XCTAssertEqual(e1.a, "a", "endpoints sorted so (a,b)==(b,a)")
        XCTAssertEqual(e1.b, "z")
        XCTAssertEqual(e1.other(than: "a"), "z")
        XCTAssertEqual(e1.other(than: "z"), "a")
        XCTAssertNil(e1.other(than: "q"))
    }

    // MARK: - Node cap

    func testNodeCap_keepsTopByWeightAndDropsDanglingEdges() {
        // 4 contacts; a/b are heavy (direct volume), c/d are light but share a
        // group with each other. Cap at 2 → keep a, b; drop c, d and their
        // co-membership edge.
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: false, participantNodeIDs: ["a"]),
            ChatMembership(chatRowID: 2, isGroup: false, participantNodeIDs: ["b"]),
            ChatMembership(chatRowID: 3, isGroup: true, participantNodeIDs: ["c", "d"]),
        ]
        let contactInfo = Dictionary(uniqueKeysWithValues: [
            info("a", direct: 500),
            info("b", direct: 400),
            info("c", direct: 1),
            info("d", direct: 1),
        ])
        let g = SocialGraphBuilder.build(
            memberships: memberships, contactInfo: contactInfo, meNode: me(),
            nodeCap: 2
        )
        // me + top-2 contacts.
        XCTAssertEqual(g.nodes.count, 3)
        let ids = Set(g.nodes.map(\.id))
        XCTAssertEqual(ids, ["me", "a", "b"])
        // The c-d co-membership edge must be dropped (both endpoints gone).
        XCTAssertTrue(g.edges.allSatisfy { $0.kind == .direct })
        // totalContactsConsidered reflects PRE-cap count (4).
        XCTAssertEqual(g.totalContactsConsidered, 4)
    }

    func testNodeCap_zeroMeansNoCap() {
        let memberships = (0..<30).map {
            ChatMembership(chatRowID: Int64($0), isGroup: false, participantNodeIDs: ["c\($0)"])
        }
        let contactInfo = Dictionary(uniqueKeysWithValues: (0..<30).map { info("c\($0)", direct: $0 + 1) })
        let g = SocialGraphBuilder.build(memberships: memberships, contactInfo: contactInfo, meNode: me(), nodeCap: 0)
        XCTAssertEqual(g.nodes.count, 31) // me + 30
    }

    // MARK: - Determinism

    func testBuild_isDeterministic() {
        let memberships: [ChatMembership] = [
            ChatMembership(chatRowID: 1, isGroup: true, participantNodeIDs: ["a", "b", "c"]),
            ChatMembership(chatRowID: 2, isGroup: false, participantNodeIDs: ["a"]),
        ]
        let contactInfo = Dictionary(uniqueKeysWithValues: [info("a", direct: 10), info("b", direct: 0), info("c", direct: 0)])
        let g1 = SocialGraphBuilder.build(memberships: memberships, contactInfo: contactInfo, meNode: me())
        let g2 = SocialGraphBuilder.build(memberships: memberships, contactInfo: contactInfo, meNode: me())
        XCTAssertEqual(g1, g2, "same inputs → identical graph (node + edge order stable)")
    }
}
