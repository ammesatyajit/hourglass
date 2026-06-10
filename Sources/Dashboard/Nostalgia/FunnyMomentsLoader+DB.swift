//
//  FunnyMomentsLoader+DB.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  The GRDB-backed fetch for `FunnyMomentsLoader`. Kept SEPARATE from the core
//  so the windowing/ranking logic (`windows`, `partnerLabel`) stays
//  Foundation-only and unit-testable without a database. This file is the only
//  part that touches chat.db.
//

import Foundation
import GRDB

extension FunnyMomentsLoader {

    /// Pull every message that drew ≥1 AMUSED reaction from OTHERS, with the
    /// per-message amused count and the chat/sender/body needed downstream.
    ///
    /// Amused = love (2000), laugh (2003), emphasize (2004) added by someone
    /// other than you (reaction `is_from_me = 0`). We strip the positional
    /// prefix off `associated_message_guid` the way the reference scripts do —
    /// the substring AFTER THE FIRST "/" (`p:0/<guid>`, `p:12/<guid>` each
    /// carry exactly one slash) — and join that to `message.guid`. A "bp:" /
    /// bare-GUID reaction has no slash and passes through unchanged, which is
    /// correct (it already equals the bare guid). We GROUP BY the target and
    /// COUNT the amused tapbacks, then join the target's payload.
    ///
    /// NOTE: deliberately NOT using `reverse()` — it isn't available in every
    /// SQLite build, and the `p:N/` prefix is single-slash so first-slash and
    /// last-slash are equivalent here. This mirrors `reference/scripts/*.py`.
    func fetchReactedMessages() throws -> [ReactedMessage] {
        let sql = """
            WITH counts AS (
                SELECT
                    CASE
                        WHEN instr(r.associated_message_guid, '/') > 0
                        THEN substr(r.associated_message_guid,
                                    instr(r.associated_message_guid, '/') + 1)
                        ELSE r.associated_message_guid
                    END AS target_guid,
                    COUNT(*) AS amused_count
                FROM message r
                WHERE r.associated_message_type IN (2000, 2003, 2004)
                  AND r.is_from_me = 0
                  AND r.associated_message_guid IS NOT NULL
                GROUP BY target_guid
            )
            SELECT
                m.ROWID             AS rowid,
                m.date              AS date,
                m.text              AS text,
                m.attributedBody    AS attributedBody,
                m.is_from_me        AS is_from_me,
                h.id                AS sender_handle,
                cmj.chat_id         AS chat_id,
                ch.style            AS chat_style,
                ch.display_name     AS chat_display_name,
                ch.guid             AS chat_guid,
                counts.amused_count AS amused_count
            FROM counts
            JOIN message m ON m.guid = counts.target_guid
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.associated_message_type = 0
            """

        let rows: [Row] = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql)
        }

        var out: [ReactedMessage] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let rawDate: Int64 = row["date"] ?? 0
            let text: String? = row["text"]
            let blob: Data? = row["attributedBody"]
            let body = (text?.isEmpty == false) ? text! : AttributedBodyDecoder.decode(blob)
            out.append(ReactedMessage(
                rowID: row["rowid"],
                chatID: row["chat_id"],
                date: MessageDate.date(fromRaw: rawDate),
                amusedCount: row["amused_count"] ?? 0,
                body: body,
                isFromMe: (row["is_from_me"] as Int? ?? 0) == 1,
                senderHandle: row["sender_handle"],
                chatStyle: row["chat_style"],
                chatDisplayName: row["chat_display_name"],
                chatGUID: row["chat_guid"]
            ))
        }
        return out
    }
}
