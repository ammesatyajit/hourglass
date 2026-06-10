//
//  SocialGraphBuilder.swift
//  Hourglass — Dashboard / Social Graph
//
//  Builds a `SocialGraph` (nodes + edges) from chat membership data. Split in
//  two layers so the graph logic is unit-testable without a live chat.db:
//
//    - `SocialGraphBuilder.build(...)`  — PURE. Takes already-resolved
//      membership rows + per-contact direct counts and produces the graph.
//      Tests feed it hand-built fixtures.
//    - `SocialGraphLoader.load(...)`    — IMPURE. Runs the read-only SQL
//      against chat.db, resolves handles → merged contacts via
//      `ResolvedContacts`, and hands the result to `build`.
//
//  EDGE MODEL
//  ==========
//    direct (you ↔ contact)        weight = 1:1 message volume (sent+recv)
//    coMembership (contact ↔ contact)  weight = # of group chats they share
//
//  The co-membership edges are the heart of the visualization: they connect
//  people who are in group chats together, which is what makes the user's
//  separate social circles cluster apart. We DERIVE these purely from
//  `chat_handle_join` (who's in which group) — no message text, no per-message
//  attribution, so it's cheap and robust.
//
//  NODE CAP
//  ========
//  A social graph with 200+ contacts renders as an unreadable hairball. We
//  keep the top `nodeCap` contacts by `weightScore` (direct volume + a group
//  term) and DROP edges that touch a dropped node. `totalContactsConsidered`
//  records the pre-cap count so the UI can say "top 60 of 214".
//

import Foundation

// MARK: - Pure builder input

/// One chat's membership, already resolved to merged-contact node ids. The
/// loader produces these from chat.db; tests construct them directly.
///
/// `participantNodeIDs` excludes the user (the user is never a row in
/// `chat_handle_join` — chat.db only lists the *other* participants), so a
/// 1:1 chat has exactly one participant id and a group chat has 2+.
public struct ChatMembership: Sendable, Equatable {
    public let chatRowID: Int64
    public let isGroup: Bool
    /// Merged-contact node ids of the non-self participants. De-duplicated by
    /// the loader (two handles for the same person collapse to one id).
    public let participantNodeIDs: [String]

    public init(chatRowID: Int64, isGroup: Bool, participantNodeIDs: [String]) {
        self.chatRowID = chatRowID
        self.isGroup = isGroup
        self.participantNodeIDs = participantNodeIDs
    }
}

/// Per-node display metadata + direct (1:1) message volume. Keyed by node id.
public struct ContactNodeInfo: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let avatarData: Data?
    /// 1:1 sent+received volume between the user and this contact.
    public let directMessageCount: Int

    public init(id: String, displayName: String, avatarData: Data?, directMessageCount: Int) {
        self.id = id
        self.displayName = displayName
        self.avatarData = avatarData
        self.directMessageCount = directMessageCount
    }
}

// MARK: - Builder

public enum SocialGraphBuilder {

    /// Default cap on visible contact nodes. Above ~60 the force layout turns
    /// into a hairball and labels collide; this keeps it legible. Surfaced in
    /// the UI alongside the true total.
    public static let defaultNodeCap = 60

    /// Build the social graph.
    ///
    /// - Parameters:
    ///   - memberships: one row per chat the user participates in, with the
    ///     non-self participants already resolved to node ids.
    ///   - contactInfo: display metadata + 1:1 volume, keyed by node id. A
    ///     node id that appears in `memberships` but not here is still
    ///     rendered (group-only contact) using a fallback label == its id;
    ///     normally the loader supplies info for everyone.
    ///   - meNode: the center node (the user). Its `directMessageCount` /
    ///     `sharedGroupCount` are forced to 0.
    ///   - nodeCap: keep at most this many contact nodes (by weightScore).
    ///   - minSharedGroups: a co-membership edge is only created when two
    ///     people share at least this many group chats. 1 = any shared group.
    ///     Raising it to 2 de-noises graphs where everyone is in one giant
    ///     "family + friends" chat together.
    ///   - maxGroupSizeForEdges: group chats with MORE than this many
    ///     participants are ignored for co-membership edges. A 40-person
    ///     "neighborhood" chat would otherwise create 780 spurious edges and
    ///     glue unrelated circles together. Direct edges and node sizing are
    ///     unaffected — only the contact↔contact web skips huge rooms.
    public static func build(
        memberships: [ChatMembership],
        contactInfo: [String: ContactNodeInfo],
        meNode: GraphNode,
        nodeCap: Int = defaultNodeCap,
        minSharedGroups: Int = 1,
        maxGroupSizeForEdges: Int = 12
    ) -> SocialGraph {

        // 1) Tally shared-group counts per contact and per unordered pair.
        //    `groupCountPerContact[x]`  = # of (qualifying) group chats x is in
        //    `sharedPairCount[pair]`    = # of group chats x and y are both in
        var groupCountPerContact: [String: Int] = [:]
        var sharedPairCount: [PairKey: Int] = [:]

        for chat in memberships where chat.isGroup {
            // De-dup participants within the chat (defensive — loader already
            // dedups, but a malformed chat_handle_join could repeat a handle).
            let participants = Array(Set(chat.participantNodeIDs)).sorted()
            guard participants.count >= 2 else { continue }

            for p in participants {
                groupCountPerContact[p, default: 0] += 1
            }

            // Co-membership pairs — skip oversized rooms (see param docs).
            guard participants.count <= maxGroupSizeForEdges else { continue }
            for i in 0..<participants.count {
                for j in (i + 1)..<participants.count {
                    let key = PairKey(participants[i], participants[j])
                    sharedPairCount[key, default: 0] += 1
                }
            }
        }

        // 2) Determine the universe of contact node ids (anyone with 1:1
        //    volume OR any group membership).
        var allContactIDs = Set(contactInfo.keys)
        for c in memberships {
            for p in c.participantNodeIDs { allContactIDs.insert(p) }
        }
        allContactIDs.remove(meNode.id) // never duplicate the center

        // 3) Materialize candidate contact nodes (pre-cap).
        var candidates: [GraphNode] = []
        candidates.reserveCapacity(allContactIDs.count)
        for id in allContactIDs {
            let info = contactInfo[id]
            let direct = info?.directMessageCount ?? 0
            let shared = groupCountPerContact[id] ?? 0
            // Skip contacts with no signal at all (no 1:1 volume, no group
            // membership). Shouldn't normally happen, but keeps the graph from
            // showing inert dots.
            if direct == 0 && shared == 0 { continue }
            candidates.append(GraphNode(
                id: id,
                displayName: info?.displayName ?? id,
                avatarData: info?.avatarData,
                isMe: false,
                directMessageCount: direct,
                sharedGroupCount: shared
            ))
        }

        let totalConsidered = candidates.count

        // 4) Rank by weightScore and keep the top `nodeCap`. Deterministic
        //    tie-break by id so the cap (and tests) are stable.
        candidates.sort { lhs, rhs in
            if lhs.weightScore != rhs.weightScore { return lhs.weightScore > rhs.weightScore }
            return lhs.id < rhs.id
        }
        let kept = nodeCap > 0 ? Array(candidates.prefix(nodeCap)) : candidates
        let keptIDs = Set(kept.map(\.id))

        // 5) Assemble nodes: center first (so its index is 0 — nice for the
        //    layout's center anchor), then the kept contacts.
        var nodes: [GraphNode] = []
        nodes.reserveCapacity(kept.count + 1)
        let center = GraphNode(
            id: meNode.id,
            displayName: meNode.displayName,
            avatarData: meNode.avatarData,
            isMe: true,
            directMessageCount: 0,
            sharedGroupCount: 0
        )
        nodes.append(center)
        nodes.append(contentsOf: kept)

        // 6) Direct edges: center ↔ each kept contact that has 1:1 volume.
        var edges: [GraphEdge] = []
        for node in kept where node.directMessageCount > 0 {
            edges.append(GraphEdge(
                a: center.id,
                b: node.id,
                kind: .direct,
                weight: Double(node.directMessageCount)
            ))
        }

        // 7) Co-membership edges: contact ↔ contact, both kept, sharing
        //    ≥ minSharedGroups group chats.
        for (pair, count) in sharedPairCount where count >= minSharedGroups {
            guard keptIDs.contains(pair.lo), keptIDs.contains(pair.hi) else { continue }
            edges.append(GraphEdge(
                a: pair.lo,
                b: pair.hi,
                kind: .coMembership,
                weight: Double(count)
            ))
        }

        // Sort edges canonically for deterministic output (tests + stable
        // layout seeding).
        edges.sort { lhs, rhs in
            if lhs.a != rhs.a { return lhs.a < rhs.a }
            if lhs.b != rhs.b { return lhs.b < rhs.b }
            // direct before coMembership for a stable order
            return kindRank(lhs.kind) < kindRank(rhs.kind)
        }

        return SocialGraph(nodes: nodes, edges: edges, totalContactsConsidered: totalConsidered)
    }

    private static func kindRank(_ k: GraphEdge.Kind) -> Int {
        switch k {
        case .direct: return 0
        case .coMembership: return 1
        }
    }
}

// MARK: - PairKey

/// Order-independent key for an unordered pair of node ids. `(x,y)` and
/// `(y,x)` hash/compare equal. Internal — only the builder's tally maps use it.
struct PairKey: Hashable {
    let lo: String
    let hi: String
    init(_ a: String, _ b: String) {
        if a <= b { lo = a; hi = b } else { lo = b; hi = a }
    }
}
