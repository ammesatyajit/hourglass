//
//  SocialGraphModel.swift
//  Hourglass — Dashboard / Social Graph
//
//  Pure value types describing the user's social graph: the user at the
//  center, their contacts as nodes, and two kinds of edges:
//
//    1. user ↔ contact  — weighted by 1:1 message volume (how much you
//       actually text that person).
//    2. contact ↔ contact — weighted by SHARED GROUP CHATS (two people who
//       co-appear in the same group chats get an edge; the more group chats
//       they share, the stronger the tie). This is the signal that reveals
//       distinct social *circles* (work, college, family) without ever
//       reading message text.
//
//  Everything here is `Sendable` and free of UIKit/AppKit so the graph build
//  + clustering + layout can run entirely off the main thread; only the
//  Canvas render touches the main actor.
//
//  Identity model: a node's `id` is the *merged contact* identity (resolved
//  display name when known, normalized handle otherwise). Two handles for the
//  same person (Mom's phone + Mom's email) collapse into ONE node — the
//  builder resolves through `ResolvedContacts` before keying.
//

import Foundation

// MARK: - Node

/// One node in the social graph. The center node (the user) is flagged via
/// `isMe`; every other node is a resolved contact (or an unknown handle).
public struct GraphNode: Sendable, Identifiable, Equatable {

    /// Stable identity. For a resolved contact this is `"name:<displayName>"`;
    /// for an unknown handle `"handle:<normalized>"`; the center node is
    /// `"me"`. Matches the keying convention used elsewhere in the dashboard
    /// (`DashboardLoader.loadTopContacts`) so the two surfaces agree on who's
    /// who.
    public let id: String

    /// Human-readable label (contact display name, or the raw handle).
    public let displayName: String

    /// Raw AddressBook avatar bytes (PNG/JPEG) when known, else nil — callers
    /// fall back to an initials monogram via `AvatarView`.
    public let avatarData: Data?

    /// True for the single center node (the user / "Me"). At most one node
    /// in a graph has this set.
    public let isMe: Bool

    /// 1:1 message volume between this contact and the user (sent + received).
    /// Drives node size and the user↔contact edge weight. Zero for the center
    /// node and for contacts only ever seen in group chats.
    public let directMessageCount: Int

    /// Number of distinct group chats this contact co-appears in with the
    /// user. A secondary size signal: someone you only know through three
    /// group chats still deserves a visible node.
    public let sharedGroupCount: Int

    /// Community / circle id assigned by `CommunityDetector`. -1 until
    /// clustered. The center node keeps -1 (it bridges every community, so
    /// coloring it by one circle would be misleading — the view renders it
    /// in a neutral accent).
    public var communityID: Int

    public init(
        id: String,
        displayName: String,
        avatarData: Data?,
        isMe: Bool,
        directMessageCount: Int,
        sharedGroupCount: Int,
        communityID: Int = -1
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.isMe = isMe
        self.directMessageCount = directMessageCount
        self.sharedGroupCount = sharedGroupCount
        self.communityID = communityID
    }

    /// A single "importance" scalar used for node sizing + label priority.
    /// Direct 1:1 volume dominates (it's the strongest tie signal); group
    /// co-membership contributes a softer term so group-only contacts still
    /// register.
    public var weightScore: Double {
        Double(directMessageCount) + 6.0 * Double(sharedGroupCount)
    }
}

// MARK: - Edge

/// An undirected edge between two nodes. `kind` distinguishes the two tie
/// types so the renderer can style them differently (direct ties as spokes
/// from the center, co-membership ties as the web between contacts).
public struct GraphEdge: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// user ↔ contact, weighted by 1:1 message volume.
        case direct
        /// contact ↔ contact, weighted by shared group-chat count.
        case coMembership
    }

    /// Node ids — order is irrelevant (undirected). Stored sorted so an edge
    /// is canonical regardless of construction order (helps dedup + tests).
    public let a: String
    public let b: String
    public let kind: Kind

    /// Raw tie strength: 1:1 message count for `.direct`, shared-group count
    /// for `.coMembership`.
    public let weight: Double

    public init(a: String, b: String, kind: Kind, weight: Double) {
        // Canonical ordering so (a,b) == (b,a) for dedup + deterministic tests.
        if a <= b {
            self.a = a
            self.b = b
        } else {
            self.a = b
            self.b = a
        }
        self.kind = kind
        self.weight = weight
    }

    /// The other endpoint given one end. Returns nil if `node` isn't an
    /// endpoint.
    public func other(than node: String) -> String? {
        if node == a { return b }
        if node == b { return a }
        return nil
    }
}

// MARK: - Graph

/// The assembled, pre-clustering social graph. Pure data — produced by
/// `SocialGraphBuilder`, consumed by `CommunityDetector` and `ForceLayout`.
public struct SocialGraph: Sendable, Equatable {

    public var nodes: [GraphNode]
    public var edges: [GraphEdge]

    /// Total distinct contacts considered BEFORE the visible-node cap was
    /// applied. The UI surfaces this ("showing top 60 of 214 people") so the
    /// cap is honest.
    public let totalContactsConsidered: Int

    public init(nodes: [GraphNode], edges: [GraphEdge], totalContactsConsidered: Int) {
        self.nodes = nodes
        self.edges = edges
        self.totalContactsConsidered = totalContactsConsidered
    }

    public static let empty = SocialGraph(nodes: [], edges: [], totalContactsConsidered: 0)

    /// Lookup index: node id → array position. O(n) to build, O(1) lookups —
    /// used by the layout + renderer to resolve edge endpoints without a
    /// linear scan per edge.
    public func indexByID() -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(nodes.count)
        for (i, n) in nodes.enumerated() { map[n.id] = i }
        return map
    }

    /// Number of distinct communities present across the nodes (ignoring the
    /// unassigned center, communityID == -1).
    public var communityCount: Int {
        Set(nodes.map(\.communityID)).subtracting([-1]).count
    }
}

// MARK: - Layout result

/// A 2D position in the layout space the force simulation produces.
/// Coordinates are roughly centered on the origin; the view scales + offsets
/// them to fit the canvas. Kept separate from `GraphNode` so the (expensive)
/// build can be cached independently of the (cheaper, re-runnable) layout.
public struct LayoutPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = LayoutPoint(x: 0, y: 0)
}

/// The output of `ForceLayout`: a position per node id, plus the bounding box
/// (so the view can compute a fit transform without re-scanning).
public struct GraphLayout: Sendable, Equatable {
    public var positions: [String: LayoutPoint]
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(positions: [String: LayoutPoint], minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.positions = positions
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = GraphLayout(positions: [:], minX: 0, minY: 0, maxX: 0, maxY: 0)

    public var width: Double { max(maxX - minX, 1e-6) }
    public var height: Double { max(maxY - minY, 1e-6) }
}
