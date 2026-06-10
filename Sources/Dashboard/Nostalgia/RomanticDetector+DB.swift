//
//  RomanticDetector+DB.swift
//  Hourglass — Dashboard / Nostalgia & Milestones panel
//
//  The GRDB-backed adapter for `RomanticDetector`. Kept SEPARATE from the core
//  so the romantic decision logic (`Signals`, `accumulate`, `isRomantic`,
//  `flagged`) stays Foundation-only and unit-testable without a database. This
//  file is the only part that touches chat.db.
//
//  ADVISORY ONLY — see the `RomanticDetector` header. This produces flagged
//  contact names; it never hides anyone.
//
//  ──────────────────────────────────────────────────────────────────────────
//  PARALLEL DECODE (Codex consult #4, step ⑤ — the SAFE speedup).
//  ──────────────────────────────────────────────────────────────────────────
//  This scan decodes `attributedBody` for the FULL 1:1 corpus (~310k bodies on
//  the dev machine) and the typedstream parse dominates its cost. Codex's
//  step ⑤ offered two options:
//    (a) PREFERRED — narrow to FTS/text-flag candidate rows for the signal
//        terms, then run `accumulate` only on those; or
//    (b) if parity is uncertain — PARALLELIZE the existing decode.
//  We chose (b). The signal set is genuinely parity-hostile for FTS: `total`
//  counts EVERY message (the `minTotalMessages >= 300` gate needs the full
//  per-contact count, not just signal-bearing rows), and the matchers use
//  short word-boundary tokens (`gn`, `ily`, `bae`), the ASCII heart `<3`, and a
//  19-scalar emoji set — none of which an FTS tokenizer reproduces with the
//  `wordPresent` word-boundary semantics. Proving FTS parity for `gn`/`<3`/emoji
//  is exactly the risk the mandate said NOT to take, so we keep the EXACT
//  matcher and parallelize the decode instead.
//
//  PARITY OF PARALLELISM IS BY CONSTRUCTION: `accumulate` only does additive,
//  per-message `+= 1` updates, and `reciprocalLove` is a derived `min(my,
//  their)`. Every `Signals` field is therefore an order-independent sum, so
//  accumulating each contact's messages into striped partial maps on N worker
//  stripes and then summing the partials yields EXACTLY the same per-contact
//  `Signals` as the old single-threaded fold — independent of which thread sees
//  which message or in what order. (Decode is pure with no shared state.)
//
//  Mechanics: a single streaming cursor on the (serialized) DB queue collects
//  lightweight `(blob, isFromMe, contactName)` work items into fixed-size
//  BATCHES — bounding resident blob bytes to one batch, never the whole corpus
//  (the OOM the cursor rewrite fixed) — and each full batch is decoded +
//  accumulated across cores via `DispatchQueue.concurrentPerform` into
//  per-stripe partials. Partials are summed at the end.
//

import Foundation
import GRDB

extension RomanticDetector {

    /// Scan the full two-way history of every 1:1 chat (`chat.style = 45`)
    /// whose participant resolves to a contact, accumulate romantic signals,
    /// and return the SORTED LIST OF FLAGGED CONTACT NAMES.
    ///
    /// The returned names are resolved contact display names — the SAME key
    /// scheme `ContactDailySeries.key` / `DormantFriend.key` use — so the VM
    /// can reconcile them against the hidden set directly.
    ///
    /// Synchronous + throwing — call off the main thread. Read-only.
    ///
    /// IMPORTANT: the output carries NO information about WHY a name is flagged
    /// (no signals, no score). Callers must keep the suggestion copy neutral.
    public static func flaggedContactNames(
        database: ChatDatabase,
        contacts: ResolvedContacts,
        config: Config = Config()
    ) throws -> [String] {
        // One pass over all 1:1 real messages, joined to the chat + participant.
        // We aggregate by resolved contact NAME (a contact can have multiple
        // handles → multiple 1:1 chats; merging by name matches how the rest of
        // Nostalgia keys people). Sent rows have a NULL handle, so we key every
        // row by the chat's participant (resolved via chat_handle_join).
        let sql = """
            SELECT
                m.is_from_me      AS is_from_me,
                m.text            AS text,
                m.attributedBody  AS attributedBody,
                ph.id             AS participant_handle
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat ch ON ch.ROWID = cmj.chat_id
            JOIN chat_handle_join chj ON chj.chat_id = ch.ROWID
            JOIN handle ph ON ph.ROWID = chj.handle_id
            WHERE ch.style = 45
              AND m.associated_message_type = 0
            """
        // NOTE: style=45 chats have exactly one participant in
        // chat_handle_join, so the join doesn't fan out rows.

        // STREAM into bounded BATCHES, then DECODE each batch IN PARALLEL.
        //
        // The serialized GRDB `DatabaseQueue` reads the lightweight per-row work
        // items (the raw blob + `is_from_me` + resolved contact name) cheaply on
        // its private queue; the expensive typedstream decode + `accumulate`
        // runs across cores on each full batch. A batch bounds resident blob
        // bytes (so we never re-introduce the materialize-everything OOM) while
        // still saturating the CPU on the decode-dominated work.
        //
        // `accumulate` is purely additive per contact, so striped partial maps
        // summed at the end == the old single-threaded fold (see file header).
        struct WorkItem { let blob: Data?; let text: String?; let isFromMe: Bool; let name: String }
        let batchSize = 4_096
        let stripes = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16))

        var byContact: [String: Signals] = [:]

        // Decode + accumulate one batch across `stripes` worker stripes, folding
        // the result into the running `byContact`. PURE w.r.t. the batch (each
        // stripe touches only its slice; partials merge deterministically).
        func drain(_ batch: [WorkItem]) {
            guard !batch.isEmpty else { return }
            let count = batch.count
            let lock = NSLock()
            var partials = Array(repeating: [String: Signals](), count: stripes)
            DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
                var local: [String: Signals] = [:]
                var idx = stripe
                while idx < count {
                    let item = batch[idx]
                    idx += stripes
                    let body = (item.text?.isEmpty == false)
                        ? item.text!
                        : AttributedBodyDecoder.decode(item.blob)
                    var sig = local[item.name] ?? Signals()
                    accumulate(into: &sig, body: body, isFromMe: item.isFromMe)
                    local[item.name] = sig
                }
                lock.lock()
                partials[stripe] = local
                lock.unlock()
            }
            // Sum the stripe partials into the running totals. Order-independent
            // because every `Signals` field is an additive sum.
            for partial in partials {
                for (name, sig) in partial {
                    byContact[name] = byContact[name].map { merge($0, sig) } ?? sig
                }
            }
        }

        try database.dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: sql)
            var batch: [WorkItem] = []
            batch.reserveCapacity(batchSize)
            while let row = try cursor.next() {
                guard let participant: String = row["participant_handle"] else { continue }
                // Only relationships with a RESOLVED contact name can be flagged
                // (a raw handle wouldn't match a dormant-friend key meaningfully,
                // and unresolved handles aren't surfaced as rekindle candidates).
                guard let contact = contacts.contact(for: Handle(raw: participant)) else { continue }

                batch.append(WorkItem(
                    blob: row["attributedBody"],
                    text: row["text"],
                    isFromMe: (row["is_from_me"] as Int? ?? 0) == 1,
                    name: contact.displayName
                ))
                if batch.count >= batchSize {
                    drain(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            drain(batch)
        }

        return flagged(from: byContact, config: config)
    }

    /// Field-wise sum of two `Signals`. Used to fold the parallel stripe
    /// partials. Because `accumulate` only ever does additive `+= 1` updates,
    /// summing partials is identical to accumulating the messages sequentially.
    private static func merge(_ a: Signals, _ b: Signals) -> Signals {
        var s = Signals()
        s.total = a.total + b.total
        s.myLoveYou = a.myLoveYou + b.myLoveYou
        s.theirLoveYou = a.theirLoveYou + b.theirLoveYou
        s.myLove = a.myLove + b.myLove
        s.goodnight = a.goodnight + b.goodnight
        s.miss = a.miss + b.miss
        s.hearts = a.hearts + b.hearts
        s.babe = a.babe + b.babe
        return s
    }
}
