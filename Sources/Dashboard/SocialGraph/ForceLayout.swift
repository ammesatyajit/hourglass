//
//  ForceLayout.swift
//  Hourglass — Dashboard / Social Graph
//
//  Deterministic force-directed (Fruchterman–Reingold-style) layout for the
//  social graph. Pure, off-main, and reproducible: the SAME graph always
//  yields the SAME positions (seeded initial placement + fixed iteration
//  count + no wall-clock / RNG dependence beyond a seeded LCG). That
//  determinism is what lets us unit-test the layout and cache it safely.
//
//  PHYSICS
//  =======
//    - Repulsion: every pair of nodes pushes apart (~ k²/d), so the graph
//      spreads out instead of piling on the origin. O(n²) per step — fine
//      because the node count is capped (~60).
//    - Attraction: each edge pulls its endpoints together (~ d²/k), weighted
//      by edge strength so heavier ties sit closer. Co-membership edges pull
//      members of the same circle into a tight cluster; direct edges pull
//      frequent contacts toward the center.
//    - Center anchor: the "me" node is pinned near the origin every step, so
//      the visualization reads as "you, surrounded by your circles."
//    - Cooling: a linearly-decaying temperature caps per-step displacement so
//      the system settles instead of oscillating.
//
//  The output coordinates are centered on the layout box's midpoint and
//  bounded by `size`; `GraphLayout` carries the actual min/max so the view can
//  fit-transform without rescanning.
//

import Foundation

public enum ForceLayout {

    /// Default simulation steps. ~300 is plenty for ≤60 nodes to settle; the
    /// whole run is well under a few ms.
    public static let defaultIterations = 320

    /// Compute a deterministic layout for `graph` within a square box of
    /// side `size` (centered on the origin → coords roughly in
    /// `[-size/2, size/2]`).
    ///
    /// - Parameters:
    ///   - graph: the clustered graph (community ids influence initial
    ///     placement so clusters start near each other → faster, cleaner
    ///     settle).
    ///   - size: side length of the target layout box.
    ///   - iterations: simulation steps (determinism: fixed by default).
    ///   - seed: LCG seed for initial placement. Fixed default → reproducible.
    public static func layout(
        graph: SocialGraph,
        size: Double = 1000,
        iterations: Int = defaultIterations,
        seed: UInt64 = 0x9E3779B97F4A7C15
    ) -> GraphLayout {
        let n = graph.nodes.count
        guard n > 0 else { return .empty }
        if n == 1 {
            // Lone center node sits at the origin.
            let id = graph.nodes[0].id
            return GraphLayout(positions: [id: .zero], minX: 0, minY: 0, maxX: 0, maxY: 0)
        }

        let index = graph.indexByID()

        // Ideal edge length k ~ area-per-node heuristic (FR).
        let area = size * size
        let k = 0.85 * (area / Double(n)).squareRoot()

        // 1) Seeded initial placement. Cluster members start on a small
        //    circle around their community's anchor so the simulation begins
        //    "pre-separated" and converges to clean circles. The center node
        //    starts at the origin.
        var px = [Double](repeating: 0, count: n)
        var py = [Double](repeating: 0, count: n)
        var rng = LCG(seed: seed)

        let communities = Set(graph.nodes.map(\.communityID)).subtracting([-1]).sorted()
        let communityCount = max(communities.count, 1)
        var communityAnchor: [Int: (Double, Double)] = [:]
        let anchorRadius = size * 0.30
        for (i, c) in communities.enumerated() {
            let theta = (2.0 * Double.pi * Double(i)) / Double(communityCount)
            communityAnchor[c] = (anchorRadius * cos(theta), anchorRadius * sin(theta))
        }

        for i in 0..<n {
            let node = graph.nodes[i]
            if node.isMe {
                px[i] = 0
                py[i] = 0
                continue
            }
            let (ax, ay) = communityAnchor[node.communityID] ?? (0, 0)
            // Jitter on a small disc around the anchor — seeded, so stable.
            let r = size * 0.10 * rng.nextUnit().squareRoot()
            let t = 2.0 * Double.pi * rng.nextUnit()
            px[i] = ax + r * cos(t)
            py[i] = ay + r * sin(t)
        }

        // Precompute edge endpoint indices + a mild log-scaled weight so a
        // 9000-message tie doesn't yank a 30-message tie off the canvas.
        struct E { let i: Int; let j: Int; let w: Double }
        var edges: [E] = []
        edges.reserveCapacity(graph.edges.count)
        for edge in graph.edges {
            guard let i = index[edge.a], let j = index[edge.b] else { continue }
            let w = 1.0 + log1p(max(edge.weight, 0))
            edges.append(E(i: i, j: j, w: w))
        }

        // Find the center node index for the per-step anchor pin.
        let centerIndex = graph.nodes.firstIndex(where: { $0.isMe })

        var temp = size * 0.12 // initial max displacement per step
        let cooling = temp / Double(iterations + 1)

        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)

        for _ in 0..<iterations {
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }

            // Repulsion — all pairs.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = px[i] - px[j]
                    var ddy = py[i] - py[j]
                    var dist = (ddx * ddx + ddy * ddy).squareRoot()
                    if dist < 1e-4 {
                        // Coincident — nudge apart deterministically.
                        ddx = (rng.nextUnit() - 0.5) * 0.01
                        ddy = (rng.nextUnit() - 0.5) * 0.01
                        dist = (ddx * ddx + ddy * ddy).squareRoot()
                        if dist < 1e-6 { dist = 1e-6 }
                    }
                    let force = (k * k) / dist
                    let ux = ddx / dist
                    let uy = ddy / dist
                    dx[i] += ux * force; dy[i] += uy * force
                    dx[j] -= ux * force; dy[j] -= uy * force
                }
            }

            // Attraction — along edges, scaled by weight.
            for e in edges {
                let ddx = px[e.i] - px[e.j]
                let ddy = py[e.i] - py[e.j]
                var dist = (ddx * ddx + ddy * ddy).squareRoot()
                if dist < 1e-6 { dist = 1e-6 }
                let force = (dist * dist) / k * e.w
                let ux = ddx / dist
                let uy = ddy / dist
                dx[e.i] -= ux * force; dy[e.i] -= uy * force
                dx[e.j] += ux * force; dy[e.j] += uy * force
            }

            // Apply, capped by temperature — but HARD-PIN the center at the
            // origin. The center ("you") is the visual anchor: every contact
            // arranges around it. Pinning it (rather than letting repulsion
            // shove it off-frame, which happens when it has few/no direct
            // edges) guarantees the composition reads as "you, surrounded by
            // your circles." The figure is recentered on the center below so
            // it always sits dead-middle.
            for i in 0..<n {
                if i == centerIndex {
                    px[i] = 0; py[i] = 0
                    continue
                }
                let d = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                if d > 1e-9 {
                    let capped = min(d, temp)
                    px[i] += (dx[i] / d) * capped
                    py[i] += (dy[i] / d) * capped
                }
            }

            temp = max(temp - cooling, size * 0.002)
        }

        // Recenter the figure. Anchor on the CENTER node so "you" is dead
        // middle; fall back to the centroid when there's no center node.
        var cx = 0.0, cy = 0.0
        if let c = centerIndex {
            cx = px[c]; cy = py[c]
        } else {
            for i in 0..<n { cx += px[i]; cy += py[i] }
            cx /= Double(n); cy /= Double(n)
        }

        var positions: [String: LayoutPoint] = [:]
        positions.reserveCapacity(n)
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for i in 0..<n {
            let x = px[i] - cx
            let y = py[i] - cy
            positions[graph.nodes[i].id] = LayoutPoint(x: x, y: y)
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }

        return GraphLayout(positions: positions, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}

// MARK: - Deterministic RNG

/// A tiny linear-congruential generator. Seeded → fully reproducible, so the
/// layout is deterministic for tests and caching. NOT for cryptographic use.
struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0xDEADBEEF : seed }

    mutating func next() -> UInt64 {
        // Numerical Recipes constants.
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }

    /// Uniform Double in [0, 1).
    mutating func nextUnit() -> Double {
        // Top 53 bits → [0,1).
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }
}
