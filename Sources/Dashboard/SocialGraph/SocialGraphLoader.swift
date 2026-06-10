//
//  SocialGraphLoader.swift
//  Hourglass — Dashboard / Social Graph
//
//  Reads chat.db READ-ONLY to produce the inputs `SocialGraphBuilder.build`
//  needs: chat memberships (resolved to merged-contact node ids) + per-contact
//  1:1 message volume. Then assembles the graph, clusters it, and lays it out.
//
//  All SQL here is read-only and mirrors the battle-tested patterns in
//  `DashboardLoader` and the reference scripts:
//    - `chat.style = 45` → 1:1, `= 43` → group  (plans.md gotcha)
//    - participants come from `chat_handle_join` (NOT `m.handle_id`, which is
//      NULL for sent messages and sometimes a stale ROWID — plans.md gotcha)
//    - 1:1 volume is attributed to the chat's single non-self participant via
//      the chj-only subquery (the COALESCE(m.handle_id, …) approach dropped
//      ~89% of sent messages on the user's real DB — see DashboardLoader
//      comments + 2026-05-25 plans.md entry)
//    - `associated_message_type = 0` drops tapbacks/reactions
//
//  Handle merging: every raw handle is resolved through `ResolvedContacts` so
//  one person's phone + email collapse to ONE node id, exactly matching
//  `DashboardLoader.loadTopContacts`'s `"name:<displayName>"` / `"handle:<n>"`
//  keying.
//

import Foundation
import GRDB

public enum SocialGraphLoader {

    /// Build the full, clustered, laid-out social graph from a read-only
    /// chat.db handle + resolved contacts. Runs synchronously; call it off the
    /// main thread (the view model wraps it in a detached task).
    ///
    /// - Returns: the clustered `SocialGraph` plus a deterministic
    ///   `GraphLayout`. The view renders both directly.
    public static func load(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        nodeCap: Int = SocialGraphBuilder.defaultNodeCap,
        layoutSize: Double = 1000
    ) throws -> SocialGraphResult {
        let memberships = try loadMemberships(database: database, contacts: contacts)
        let directCounts = try loadDirectCounts(database: database, contacts: contacts)
        let meNode = makeMeNode(contacts: contacts)

        let contactInfo = buildContactInfo(
            memberships: memberships,
            directCounts: directCounts,
            contacts: contacts,
            meNodeID: meNode.id
        )

        var graph = SocialGraphBuilder.build(
            memberships: memberships,
            contactInfo: contactInfo,
            meNode: meNode,
            nodeCap: nodeCap
        )
        graph = CommunityDetector.assignCommunities(to: graph)
        let layout = ForceLayout.layout(graph: graph, size: layoutSize)
        return SocialGraphResult(graph: graph, layout: layout)
    }

    // MARK: - Me node

    /// The center node. Prefer the AddressBook "Me" card; fall back to a
    /// generic "You" so the graph always has a center even on a machine with
    /// no Me card set.
    static func makeMeNode(contacts: ResolvedContacts) -> GraphNode {
        if let me = contacts.meContact, !me.displayName.isEmpty {
            return GraphNode(
                id: "me",
                displayName: me.displayName,
                avatarData: me.avatarData,
                isMe: true,
                directMessageCount: 0,
                sharedGroupCount: 0
            )
        }
        return GraphNode(
            id: "me",
            displayName: "You",
            avatarData: nil,
            isMe: true,
            directMessageCount: 0,
            sharedGroupCount: 0
        )
    }

    // MARK: - Node id resolution

    /// Resolve a raw chat.db handle string to a merged-contact node id, using
    /// the SAME keying the rest of the dashboard uses so node ids line up
    /// across surfaces.
    ///
    /// Handles belonging to the user's own "Me" contact collapse to the center
    /// node id ("me") — on some DBs the user appears in their own group's
    /// `chat_handle_join` (e.g. multi-device), and we don't want a duplicate
    /// "you" floating in the graph.
    static func nodeID(
        forRawHandle raw: String,
        contacts: ResolvedContacts,
        meContact: Contact?
    ) -> (id: String, displayName: String, avatar: Data?) {
        let handle = Handle(raw: raw)
        if let resolved = contacts.byHandle[handle], !resolved.displayName.isEmpty {
            // Is this the user themself?
            if let me = meContact, me.displayName == resolved.displayName {
                return ("me", resolved.displayName, resolved.avatarData)
            }
            return ("name:\(resolved.displayName)", resolved.displayName, resolved.avatarData)
        }
        return ("handle:\(handle.normalized)", raw, nil)
    }

    // MARK: - Memberships

    /// Enumerate every chat the user participates in, with its style and the
    /// set of non-self participants resolved to merged-contact node ids.
    ///
    /// One round-trip: join `chat_handle_join → handle → chat`, then group by
    /// chat in Swift. We read `chat.style` to classify 1:1 (45) vs group (43);
    /// any other style is treated as non-group (rare legacy rows).
    static func loadMemberships(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [ChatMembership] {
        let rows = try database.dbQueue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT ch.ROWID AS chat_id, ch.style AS style, h.id AS handle
                FROM chat ch
                JOIN chat_handle_join chj ON chj.chat_id = ch.ROWID
                JOIN handle h ON h.ROWID = chj.handle_id
                """)
        }

        let me = contacts.meContact
        // chat_id → (isGroup, set of node ids). Set dedups handles that
        // resolve to the same contact (one person's phone + email in the
        // same chat).
        var byChat: [Int64: (isGroup: Bool, ids: Set<String>)] = [:]
        for row in rows {
            guard let chatID: Int64 = row["chat_id"],
                  let raw: String = row["handle"] else { continue }
            let style: Int64 = row["style"] ?? 0
            let isGroup = (style == 43)
            let resolved = nodeID(forRawHandle: raw, contacts: contacts, meContact: me)
            // Don't count the user's own handle as a participant.
            if resolved.id == "me" { continue }
            var entry = byChat[chatID] ?? (isGroup, [])
            entry.isGroup = isGroup
            entry.ids.insert(resolved.id)
            byChat[chatID] = entry
        }

        return byChat
            .map { (chatID, v) in
                ChatMembership(
                    chatRowID: chatID,
                    isGroup: v.isGroup,
                    participantNodeIDs: Array(v.ids).sorted()
                )
            }
            .sorted { $0.chatRowID < $1.chatRowID }
    }

    // MARK: - Direct (1:1) volume

    /// Per-merged-contact 1:1 message volume (sent + received), keyed by node
    /// id. Ports `DashboardLoader.loadTopContacts`'s chj-only attribution
    /// (the COALESCE(m.handle_id, …) path dropped ~89% of sent messages on the
    /// user's real DB — see that file's comments).
    static func loadDirectCounts(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [String: Int] {
        let rows = try database.dbQueue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT h.id AS handle, COUNT(*) AS total
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat ch ON ch.ROWID = cmj.chat_id
                JOIN handle h ON h.ROWID = (
                    SELECT chj.handle_id FROM chat_handle_join chj
                    WHERE chj.chat_id = ch.ROWID LIMIT 1
                )
                WHERE m.associated_message_type = 0
                  AND ch.style = 45
                GROUP BY h.id
                """)
        }

        let me = contacts.meContact
        var counts: [String: Int] = [:]
        for row in rows {
            guard let raw: String = row["handle"] else { continue }
            let total: Int = row["total"] ?? 0
            let resolved = nodeID(forRawHandle: raw, contacts: contacts, meContact: me)
            if resolved.id == "me" { continue }
            counts[resolved.id, default: 0] += total
        }
        return counts
    }

    // MARK: - Contact info assembly

    /// Merge direct counts + display metadata into the `[id: ContactNodeInfo]`
    /// the builder expects. Pulls labels/avatars from whatever source we have:
    /// resolved contacts (for `name:` ids) or the raw handle (for `handle:`
    /// ids encountered in group chats).
    static func buildContactInfo(
        memberships: [ChatMembership],
        directCounts: [String: Int],
        contacts: ResolvedContacts,
        meNodeID: String
    ) -> [String: ContactNodeInfo] {
        // Build a display-name + avatar lookup for every node id we might
        // surface, from the resolved contacts list.
        var nameByID: [String: String] = [:]
        var avatarByID: [String: Data?] = [:]
        for c in contacts.allContacts where !c.displayName.isEmpty {
            let id = "name:\(c.displayName)"
            nameByID[id] = c.displayName
            avatarByID[id] = c.avatarData
        }

        var info: [String: ContactNodeInfo] = [:]

        // Seed from direct counts.
        for (id, count) in directCounts where id != meNodeID {
            info[id] = ContactNodeInfo(
                id: id,
                displayName: nameByID[id] ?? fallbackLabel(forID: id),
                avatarData: avatarByID[id] ?? nil,
                directMessageCount: count
            )
        }

        // Ensure every group participant has an entry (0 direct volume if
        // we never saw a 1:1 with them).
        for chat in memberships where chat.isGroup {
            for id in chat.participantNodeIDs where id != meNodeID {
                if info[id] == nil {
                    info[id] = ContactNodeInfo(
                        id: id,
                        displayName: nameByID[id] ?? fallbackLabel(forID: id),
                        avatarData: avatarByID[id] ?? nil,
                        directMessageCount: 0
                    )
                }
            }
        }

        return info
    }

    /// Human label for a node id when no resolved contact name is available —
    /// strips the `handle:` prefix so an unknown number shows as the number,
    /// not `handle:+1555…`.
    static func fallbackLabel(forID id: String) -> String {
        if id.hasPrefix("handle:") { return String(id.dropFirst("handle:".count)) }
        if id.hasPrefix("name:") { return String(id.dropFirst("name:".count)) }
        return id
    }
}

/// Bundled output of the loader — the clustered graph and its layout.
public struct SocialGraphResult: Sendable, Equatable {
    public let graph: SocialGraph
    public let layout: GraphLayout

    public init(graph: SocialGraph, layout: GraphLayout) {
        self.graph = graph
        self.layout = layout
    }

    public static let empty = SocialGraphResult(graph: .empty, layout: .empty)
}
