//
//  RekindleBuilder+DB.swift
//  Hourglass — Dashboard / Nostalgia (rekindle reminders)
//
//  The GRDB-backed adapter for `RekindleBuilder`. Kept SEPARATE from the core so
//  the threshold + eligibility logic stays Foundation-only and unit-testable
//  without a database. This file is the only part that touches chat.db.
//
//  Read-only, synchronous + throwing — call off the main thread (the VM does).
//

import Foundation
import GRDB

extension RekindleBuilder {

    /// Scan every 1:1 chat (`chat.style = 45`) and return the SORTED eligible
    /// rekindle reminders (heaviest correspondents first), before any
    /// suppression. The caller (`NostalgiaViewModel`) applies the hidden set +
    /// romantic flags.
    ///
    /// Aggregates by resolved contact NAME (a person can own multiple handles →
    /// multiple 1:1 chats; merging by name matches how the rest of Nostalgia
    /// keys people). Only RESOLVED contacts can be reminders — a raw handle
    /// wouldn't reconcile with the hidden set / romantic flags.
    ///
    /// Synchronous + throwing — call off the main thread. Read-only.
    public static func load(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        now: Date,
        config: Config = Config()
    ) throws -> [RekindleReminder] {
        let byContact = try aggregate(database: database, contacts: contacts)
        return eligible(from: byContact, now: now, config: config)
    }

    /// Build `resolved contact name → {total, lastDate, avatar}` over all 1:1
    /// real messages. Two cheap passes: (1) map each style=45 chat to its
    /// resolved participant contact (via `chat_handle_join`), (2) count real
    /// messages per chat + track the max date. Mirrors the prototype's
    /// `chatContact` + `vol` build. Read-only.
    static func aggregate(
        database: ChatDatabase,
        contacts: ResolvedContacts
    ) throws -> [String: Volume] {
        try database.dbQueue.read { db in
            // 1) style=45 chat → resolved contact (name + avatar). style=45
            //    chats have exactly one participant row, so this is 1 row/chat.
            let chatRows = try Row.fetchAll(db, sql: """
                SELECT chj.chat_id AS chat_id, h.id AS handle
                FROM chat_handle_join chj
                JOIN handle h ON h.ROWID = chj.handle_id
                JOIN chat ch ON ch.ROWID = chj.chat_id
                WHERE ch.style = 45
                """)
            struct ContactRef { let name: String; let avatar: Data? }
            var chatContact: [Int64: ContactRef] = [:]
            for r in chatRows {
                let chatID: Int64 = r["chat_id"]
                guard let handle: String = r["handle"],
                      let contact = contacts.contact(for: Handle(raw: handle)) else { continue }
                chatContact[chatID] = ContactRef(
                    name: contact.displayName, avatar: contact.avatarData)
            }
            guard !chatContact.isEmpty else { return [:] }

            // 2) count real messages per style=45 chat + track the last date.
            //    associated_message_type = 0 drops tapbacks/reactions.
            let msgRows = try Row.fetchAll(db, sql: """
                SELECT m.date AS date, cmj.chat_id AS chat_id
                FROM message m
                JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                JOIN chat ch ON ch.ROWID = cmj.chat_id
                WHERE ch.style = 45
                  AND m.associated_message_type = 0
                """)
            var byContact: [String: Volume] = [:]
            for r in msgRows {
                let chatID: Int64 = r["chat_id"]
                guard let ref = chatContact[chatID] else { continue }
                let date = MessageDate.date(fromRaw: r["date"] ?? 0)
                if var existing = byContact[ref.name] {
                    existing.total += 1
                    if date > existing.lastDate { existing.lastDate = date }
                    byContact[ref.name] = existing
                } else {
                    byContact[ref.name] = Volume(
                        total: 1, lastDate: date, avatarData: ref.avatar)
                }
            }
            return byContact
        }
    }
}
