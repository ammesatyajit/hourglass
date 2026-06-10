//
//  CommunityDetector.swift
//  Hourglass — Dashboard / Social Graph
//
//  Dependency-free community detection via *label propagation* (Raghavan,
//  Albert & Kumara 2007). Chosen because it's near-linear, needs no tuning
//  parameters, and is trivial to make deterministic — which matters: the same
//  chat.db must always produce the same circles and colors.
//
//  WHY IT WORKS HERE
//  =================
//  We run propagation on the CONTACT↔CONTACT co-membership subgraph only —
//  the center node (you) is excluded because you're connected to everyone and
//  would collapse every circle into one giant label. With you removed, the
//  co-membership edges naturally partition into the user's distinct social
//  circles (your work group chats form one dense cluster, your college friends
//  another, family a third).
//
//  ALGORITHM
//  =========
//    1. Each contact node starts in its own community (label = node index).
//    2. Repeatedly, in a FIXED node order, each node adopts the label that
//       has the highest summed edge-weight among its neighbors (ties broken by
//       smallest label id — fully deterministic, no RNG).
//    3. Stop when no node changes its label, or after `maxIterations`.
//    4. Relabel communities to dense 0,1,2,… ids ordered by descending size
//       (so community 0 is the biggest circle — the renderer assigns the
//       most-saturated tint to it).
//
//  Contacts with no co-membership edges (you text them 1:1 only, never in a
//  group) form singleton communities — they're "their own circle," which is
//  honest: we have no group signal placing them anywhere.
//

import Foundation

public enum CommunityDetector {

    public static let maxIterations = 50

    /// Assign `communityID` to every contact node in `graph`. The center node
    /// (`isMe`) keeps `communityID = -1` (it bridges all circles). Returns a
    /// new graph with `communityID` filled in; edges are untouched.
    public static func assignCommunities(to graph: SocialGraph) -> SocialGraph {
        var result = graph

        // 1) Restrict to contact nodes (exclude the center). Build a compact
        //    index space for them.
        let contactNodes = graph.nodes.enumerated().filter { !$0.element.isMe }
        guard !contactNodes.isEmpty else { return result }

        // Map node id → compact contact index, and back.
        var indexForID: [String: Int] = [:]
        var idForIndex: [String] = []
        indexForID.reserveCapacity(contactNodes.count)
        idForIndex.reserveCapacity(contactNodes.count)
        for (_, node) in contactNodes {
            indexForID[node.id] = idForIndex.count
            idForIndex.append(node.id)
        }

        // 2) Adjacency over CO-MEMBERSHIP edges only (the circle signal).
        //    weightedNeighbors[i] = [(neighborIndex, weight)].
        var neighbors: [[(idx: Int, w: Double)]] = Array(repeating: [], count: idForIndex.count)
        for edge in graph.edges where edge.kind == .coMembership {
            guard let ia = indexForID[edge.a], let ib = indexForID[edge.b] else { continue }
            neighbors[ia].append((ib, edge.weight))
            neighbors[ib].append((ia, edge.weight))
        }

        // 3) Label propagation. Initial label = own index.
        var labels = Array(0..<idForIndex.count)

        // Fixed iteration order: by descending degree then index. Updating
        // high-degree (hub) nodes first speeds convergence and keeps the
        // result deterministic without an RNG.
        let order = (0..<idForIndex.count).sorted { lhs, rhs in
            if neighbors[lhs].count != neighbors[rhs].count {
                return neighbors[lhs].count > neighbors[rhs].count
            }
            return lhs < rhs
        }

        var iteration = 0
        var changed = true
        while changed && iteration < maxIterations {
            changed = false
            iteration += 1
            for node in order {
                let ns = neighbors[node]
                if ns.isEmpty { continue } // singleton — keeps its own label

                // Sum neighbor weights per label; pick the heaviest, ties to
                // the smallest label for determinism.
                var weightByLabel: [Int: Double] = [:]
                for (nIdx, w) in ns {
                    weightByLabel[labels[nIdx], default: 0] += w
                }
                var bestLabel = labels[node]
                var bestWeight = weightByLabel[bestLabel] ?? -1
                for (label, w) in weightByLabel {
                    if w > bestWeight || (w == bestWeight && label < bestLabel) {
                        bestWeight = w
                        bestLabel = label
                    }
                }
                if bestLabel != labels[node] {
                    labels[node] = bestLabel
                    changed = true
                }
            }
        }

        // 4) Compact + reorder labels by descending community size. Singletons
        //    keep distinct ids so they don't all merge into one "misc" bucket.
        let dense = denseLabelsBySize(labels)

        // 5) Write community ids back onto the result nodes.
        for i in 0..<result.nodes.count {
            if result.nodes[i].isMe {
                result.nodes[i].communityID = -1
            } else if let ci = indexForID[result.nodes[i].id] {
                result.nodes[i].communityID = dense[labels[ci]] ?? 0
            }
        }
        return result
    }

    /// Remap raw labels to dense 0…k-1 ids ordered by descending member count
    /// (biggest community → id 0). Deterministic tie-break on the raw label.
    static func denseLabelsBySize(_ labels: [Int]) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for l in labels { counts[l, default: 0] += 1 }
        let ordered = counts.keys.sorted { lhs, rhs in
            if counts[lhs]! != counts[rhs]! { return counts[lhs]! > counts[rhs]! }
            return lhs < rhs
        }
        var mapping: [Int: Int] = [:]
        for (dense, raw) in ordered.enumerated() { mapping[raw] = dense }
        return mapping
    }
}
