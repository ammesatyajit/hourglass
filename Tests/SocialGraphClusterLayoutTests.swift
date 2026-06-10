//
//  SocialGraphClusterLayoutTests.swift
//  HourglassTests — Social Graph
//
//  Community detection (label propagation) + force-layout determinism on
//  small, known graphs. Pure — no chat.db, no SwiftUI.
//

import XCTest
@testable import Hourglass

final class SocialGraphClusterLayoutTests: XCTestCase {

    // MARK: - Helpers

    private func contact(_ id: String, community: Int = -1) -> GraphNode {
        GraphNode(id: id, displayName: id, avatarData: nil, isMe: false,
                  directMessageCount: 1, sharedGroupCount: 1, communityID: community)
    }

    private func me() -> GraphNode {
        GraphNode(id: "me", displayName: "You", avatarData: nil, isMe: true,
                  directMessageCount: 0, sharedGroupCount: 0)
    }

    /// Two dense triangles {a,b,c} and {d,e,f}, each fully connected by
    /// co-membership edges, joined by a single weak a–d bridge. Classic
    /// two-community test case.
    private func twoClusterGraph() -> SocialGraph {
        let nodes = [me(), contact("a"), contact("b"), contact("c"),
                     contact("d"), contact("e"), contact("f")]
        func co(_ x: String, _ y: String, _ w: Double) -> GraphEdge {
            GraphEdge(a: x, b: y, kind: .coMembership, weight: w)
        }
        let edges = [
            // cluster 1
            co("a", "b", 5), co("b", "c", 5), co("a", "c", 5),
            // cluster 2
            co("d", "e", 5), co("e", "f", 5), co("d", "f", 5),
            // weak bridge
            co("a", "d", 1),
        ]
        return SocialGraph(nodes: nodes, edges: edges, totalContactsConsidered: 6)
    }

    // MARK: - Community detection

    func testCommunityDetection_separatesTwoClusters() {
        let clustered = CommunityDetector.assignCommunities(to: twoClusterGraph())

        func cid(_ id: String) -> Int {
            clustered.nodes.first { $0.id == id }!.communityID
        }

        // Center is unassigned (bridges everything).
        XCTAssertEqual(cid("me"), -1)

        // Within-cluster nodes share a community id.
        XCTAssertEqual(cid("a"), cid("b"))
        XCTAssertEqual(cid("b"), cid("c"))
        XCTAssertEqual(cid("d"), cid("e"))
        XCTAssertEqual(cid("e"), cid("f"))

        // The two clusters are DIFFERENT communities (the single weak bridge
        // shouldn't merge them).
        XCTAssertNotEqual(cid("a"), cid("d"))

        // Exactly two non-center communities.
        XCTAssertEqual(clustered.communityCount, 2)
    }

    func testCommunityDetection_isDeterministic() {
        let g = twoClusterGraph()
        let c1 = CommunityDetector.assignCommunities(to: g)
        let c2 = CommunityDetector.assignCommunities(to: g)
        XCTAssertEqual(c1, c2, "label propagation is seeded/ordered → reproducible")
    }

    func testCommunityDetection_singletonKeepsOwnCommunity() {
        // A node with no co-membership edges is its own circle.
        let nodes = [me(), contact("a"), contact("b"), contact("lonely")]
        let edges = [GraphEdge(a: "a", b: "b", kind: .coMembership, weight: 3)]
        let g = SocialGraph(nodes: nodes, edges: edges, totalContactsConsidered: 3)
        let clustered = CommunityDetector.assignCommunities(to: g)

        func cid(_ id: String) -> Int { clustered.nodes.first { $0.id == id }!.communityID }
        XCTAssertEqual(cid("a"), cid("b"))
        XCTAssertNotEqual(cid("lonely"), cid("a"), "isolated contact is a separate community")
        XCTAssertEqual(clustered.communityCount, 2)
    }

    func testCommunityDetection_biggestClusterGetsLowestID() {
        // {a,b,c,d} dense + {e,f} dense. Bigger cluster should be community 0.
        var nodes = [me()]
        for id in ["a", "b", "c", "d", "e", "f"] { nodes.append(contact(id)) }
        func co(_ x: String, _ y: String) -> GraphEdge { GraphEdge(a: x, b: y, kind: .coMembership, weight: 4) }
        let edges = [
            co("a", "b"), co("b", "c"), co("c", "d"), co("a", "c"), co("a", "d"), co("b", "d"),
            co("e", "f"),
        ]
        let g = SocialGraph(nodes: nodes, edges: edges, totalContactsConsidered: 6)
        let clustered = CommunityDetector.assignCommunities(to: g)
        func cid(_ id: String) -> Int { clustered.nodes.first { $0.id == id }!.communityID }
        // The 4-node cluster is biggest → dense id 0.
        XCTAssertEqual(cid("a"), 0)
        XCTAssertEqual(cid("b"), 0)
        XCTAssertEqual(cid("e"), 1)
    }

    // MARK: - Force layout

    func testLayout_isDeterministic() {
        let clustered = CommunityDetector.assignCommunities(to: twoClusterGraph())
        let l1 = ForceLayout.layout(graph: clustered, size: 1000)
        let l2 = ForceLayout.layout(graph: clustered, size: 1000)
        XCTAssertEqual(l1, l2, "seeded LCG + fixed iterations → identical layout")
    }

    func testLayout_positionsEveryNode() {
        let clustered = CommunityDetector.assignCommunities(to: twoClusterGraph())
        let layout = ForceLayout.layout(graph: clustered, size: 1000)
        for node in clustered.nodes {
            XCTAssertNotNil(layout.positions[node.id], "node \(node.id) has a position")
        }
        XCTAssertEqual(layout.positions.count, clustered.nodes.count)
    }

    func testLayout_centerNodePinnedAtOrigin() {
        // The center ("you") is hard-pinned at the origin during simulation
        // and the whole figure is recentered on it, so it lands exactly at
        // (0,0) — dead middle of the visualization regardless of how few
        // direct edges it has.
        let clustered = CommunityDetector.assignCommunities(to: twoClusterGraph())
        let layout = ForceLayout.layout(graph: clustered, size: 1000)
        XCTAssertEqual(layout.positions["me"], .zero, "center is dead-center")
        // And it really is interior to the figure's bounds.
        XCTAssertLessThanOrEqual(layout.minX, 0)
        XCTAssertGreaterThanOrEqual(layout.maxX, 0)
    }

    func testLayout_clusterMembersCloserThanCrossCluster() {
        // After layout, average intra-cluster distance should be < average
        // cross-cluster distance — the whole point of the co-membership pull.
        let clustered = CommunityDetector.assignCommunities(to: twoClusterGraph())
        let layout = ForceLayout.layout(graph: clustered, size: 1000)

        func pos(_ id: String) -> LayoutPoint { layout.positions[id]! }
        func dist(_ x: String, _ y: String) -> Double {
            let a = pos(x), b = pos(y)
            return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }

        let intra = [dist("a", "b"), dist("b", "c"), dist("a", "c"),
                     dist("d", "e"), dist("e", "f"), dist("d", "f")]
        let cross = [dist("a", "d"), dist("a", "e"), dist("b", "f"), dist("c", "e")]
        let avgIntra = intra.reduce(0, +) / Double(intra.count)
        let avgCross = cross.reduce(0, +) / Double(cross.count)
        XCTAssertLessThan(avgIntra, avgCross, "co-membership clusters pull members together")
    }

    func testLayout_emptyAndSingleton() {
        let empty = ForceLayout.layout(graph: .empty, size: 1000)
        XCTAssertTrue(empty.positions.isEmpty)

        let lone = SocialGraph(nodes: [me()], edges: [], totalContactsConsidered: 0)
        let layout = ForceLayout.layout(graph: lone, size: 1000)
        XCTAssertEqual(layout.positions["me"], .zero)
    }

    // MARK: - PairKey

    func testPairKey_orderIndependent() {
        XCTAssertEqual(PairKey("x", "y"), PairKey("y", "x"))
        XCTAssertEqual(PairKey("x", "y").lo, "x")
        XCTAssertEqual(PairKey("x", "y").hi, "y")
    }
}
