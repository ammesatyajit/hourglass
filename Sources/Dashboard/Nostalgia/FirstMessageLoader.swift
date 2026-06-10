//
//  FirstMessageLoader.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  "Your first words with Venkat, Aug 2022: …" — for the user's top contacts
//  by all-time 1:1 volume, surfaces the very first message exchanged with each,
//  plus the date. DB-backed: we need the decoded body + exact instant, which
//  the aggregate's day-counts don't carry.
//
//  Approach: take the top contacts from the (already-built) per-contact series
//  so ranking matches the rest of the dashboard, then run ONE query over all
//  1:1 chats that pulls each chat's earliest real message. We map chat →
//  resolved contact, keep the earliest message per contact, and emit the top N.
//  No per-contact round-trips.
//

import Foundation
import GRDB

public struct FirstMessageLoader: Sendable {

    public struct Config: Sendable, Equatable {
        /// How many contacts' "first words" to surface.
        public var maxResults: Int = 10
        /// Rank pool: consider the top-by-volume contacts (a generous multiple
        /// of `maxResults` so a contact whose opener didn't resolve doesn't
        /// shrink the list). Volume is summed from the series.
        public var rankPoolSize: Int = 40
        /// A contact needs at least this many all-time messages to be eligible
        /// (filters one-off threads out of "your people").
        public var minTotalMessages: Int = 100

        public init() {}
    }

    private let database: ChatDatabase
    private let contacts: ResolvedContacts
    private let config: Config

    public init(database: ChatDatabase, contacts: ResolvedContacts, config: Config = Config()) {
        self.database = database
        self.contacts = contacts
        self.config = config
    }

    /// Build the "first words" list. Synchronous + throwing — call off-main.
    ///
    /// - Parameter series: the aggregate's per-contact daily series, used to
    ///   pick (and order) the top contacts by volume.
    public func load(series: [ContactDailySeries]) throws -> [FirstMessage] {
        // 1) Rank contacts by all-time volume (same key scheme as the series).
        struct Ranked { let key: String; let name: String; let avatar: Data?; let total: Int }
        let ranked: [Ranked] = series
            .map { s in
                Ranked(
                    key: s.key,
                    name: s.displayName,
                    avatar: s.avatarData,
                    total: s.days.reduce(0) { $0 + Int($1.sent) + Int($1.received) }
                )
            }
            .filter { $0.total >= config.minTotalMessages }
            .sorted { $0.total > $1.total }

        let pool = Array(ranked.prefix(config.rankPoolSize))
        guard !pool.isEmpty else { return [] }

        // We can only resolve a chat's earliest message back to a contact via
        // the contact's handles. Build handle(normalized) -> contact key for
        // the pooled contacts. The series key IS the resolved display name, so
        // we map through `ResolvedContacts` by name.
        var keyByNormalizedHandle: [String: String] = [:]
        var rankedByKey: [String: Ranked] = [:]
        for r in pool {
            rankedByKey[r.key] = r
            // Find the resolved Contact whose displayName == this series key.
            // (Series keys are display names for resolved contacts; raw-handle
            //  keys won't match a contact and are simply skipped — they're not
            //  "your people" with a name to celebrate.)
            if let contact = contacts.allContacts.first(where: { $0.displayName == r.key }) {
                for h in contact.handles {
                    keyByNormalizedHandle[h.normalized] = r.key
                }
            }
        }
        guard !keyByNormalizedHandle.isEmpty else { return [] }

        // 2) Earliest real message per 1:1 chat, with that chat's participant
        //    handle. GROUP BY chat picks the min-date row's payload via a
        //    correlated MIN — SQLite's bare-column-with-aggregate extension
        //    guarantees the other columns come from the min(date) row.
        let sql = """
            SELECT
                ch.ROWID                AS chat_id,
                ph.id                   AS participant_handle,
                MIN(m.date)             AS first_date,
                m.text                  AS text,
                m.attributedBody        AS attributedBody,
                m.is_from_me            AS is_from_me
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            JOIN chat_handle_join chj ON chj.chat_id = ch.ROWID
            JOIN handle ph ON ph.ROWID = chj.handle_id
            WHERE ch.style = 45
              AND m.associated_message_type = 0
            GROUP BY ch.ROWID
            """

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql)
        }

        // 3) Reduce to the earliest opener PER CONTACT (a contact may have more
        //    than one 1:1 chat — phone + email — so take the earliest across
        //    them).
        struct Opener { let date: Date; let body: String; let isFromMe: Bool }
        var earliestByKey: [String: Opener] = [:]
        for row in rows {
            guard let handle: String = row["participant_handle"] else { continue }
            let normalized = Handle(raw: handle).normalized
            guard let key = keyByNormalizedHandle[normalized] else { continue }

            let rawDate: Int64 = row["first_date"] ?? 0
            let date = MessageDate.date(fromRaw: rawDate)
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
            let isFromMe = (row["is_from_me"] as Int? ?? 0) == 1

            if let existing = earliestByKey[key], existing.date <= date { continue }
            earliestByKey[key] = Opener(date: date, body: body, isFromMe: isFromMe)
        }

        // 4) Emit in the volume order we ranked by, capped at maxResults.
        var out: [FirstMessage] = []
        out.reserveCapacity(min(config.maxResults, earliestByKey.count))
        for r in pool {
            guard out.count < config.maxResults else { break }
            guard let opener = earliestByKey[r.key] else { continue }
            out.append(FirstMessage(
                displayName: r.name,
                avatarData: r.avatar,
                body: opener.body,
                isFromMe: opener.isFromMe,
                date: opener.date,
                totalMessages: r.total
            ))
        }
        return out
    }
}
