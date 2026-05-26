//
//  ChatListing.swift
//  Hourglass
//
//  Enumerates all chats in `chat.db`. Used to populate the autocomplete pool
//  for the `chat:` / `in:` token prefixes.
//
//  We're optimizing for "build this once and keep it in memory". The query
//  joins chat, chat_handle_join, and handle in a single pass and aggregates
//  in Swift; that's both simpler and faster than three round-trips per chat.
//

import Foundation
import GRDB

public enum ChatListing {

    /// Fetch every chat. Returns chats sorted by `lastMessageDate` descending
    /// (most recent first), with nil-date chats at the bottom.
    public static func allChats(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [ChatInfo] {

        // 1) Pull chat rows + their last message date.
        //    `last_message_date` per chat = MAX(message.date) over messages in
        //    that chat. We surface it for sorting.
        struct ChatRow: FetchableRecord {
            let rowID: Int64
            let style: Int?
            let displayName: String?
            let lastMessageDate: Int64?

            init(row: Row) {
                rowID = row["rowid"]
                style = row["style"] as Int?
                displayName = row["display_name"] as String?
                lastMessageDate = row["last_date"] as Int64?
            }
        }

        let chatRows: [ChatRow] = try database.dbQueue.read { db in
            try ChatRow.fetchAll(db, sql: """
                SELECT
                    ch.ROWID AS rowid,
                    ch.style AS style,
                    ch.display_name AS display_name,
                    (
                        SELECT MAX(m.date)
                        FROM chat_message_join cmj
                        JOIN message m ON m.ROWID = cmj.message_id
                        WHERE cmj.chat_id = ch.ROWID
                    ) AS last_date
                FROM chat ch
                """)
        }

        // 2) Pull the participant handles for every chat in one query.
        let handleRows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT chj.chat_id AS chat_id, h.id AS handle_id
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                """)
        }

        var handlesByChat: [Int64: [String]] = [:]
        for row in handleRows {
            let chatID: Int64 = row["chat_id"]
            let handleID: String? = row["handle_id"]
            guard let raw = handleID else { continue }
            handlesByChat[chatID, default: []].append(raw)
        }

        // 3) Resolve handles to participant names per chat.
        var chats: [ChatInfo] = []
        chats.reserveCapacity(chatRows.count)
        for r in chatRows {
            let rawHandles = handlesByChat[r.rowID] ?? []
            let names: [String] = rawHandles.map { rawHandle in
                let h = Handle(raw: rawHandle)
                return contacts.byHandle[h]?.displayName ?? rawHandle
            }
            let date = r.lastMessageDate.map(MessageDate.date(fromRaw:))
            chats.append(ChatInfo(
                rowID: r.rowID,
                style: r.style,
                rawDisplayName: r.displayName,
                participantNames: names,
                lastMessageDate: date
            ))
        }

        // Sort by last message date desc, with nil at the bottom (older).
        chats.sort { lhs, rhs in
            switch (lhs.lastMessageDate, rhs.lastMessageDate) {
            case (let a?, let b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.rowID > rhs.rowID
            }
        }
        return chats
    }
}
