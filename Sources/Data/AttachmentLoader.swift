//
//  AttachmentLoader.swift
//  Hourglass
//
//  Batched loader for a `[messageGUID: MessageType]` map keyed by message GUID.
//
//  Why batched? Same reason as ReactionLoader — running per-row "what kind is
//  this message" while the UI scrolls would be an N+1 query at the heart of
//  the result-rendering hot path. We instead issue at most two SQL queries
//  for the entire result set:
//
//    Q1 — balloon_bundle_id buckets per GUID
//    Q2 — attachment join: mime_type / uti / is_sticker per GUID
//
//  Both keyed off `message.guid IN (...)`. Result is collapsed in Swift using
//  the priority in `MessageType.swift` (balloon signals win; otherwise the
//  dominant attachment kind for the message wins).
//
//  SQLite has a 999-arg limit on bound parameters in an `IN (?)` list, so we
//  chunk inputs at 500 GUIDs per query (room for both queries' arg shapes).
//
//  Edge cases
//  ----------
//  - Empty input → empty dictionary, no SQL touched.
//  - GUID with no attachment row AND no balloon bundle ⇒ omitted from the
//    output (caller treats absence as `.text`). This keeps the dict small.
//  - Multi-attachment message: we pick the dominant kind via a small priority
//    rank — sticker > image > video > audio > file. Empirically, mixed-type
//    messages are rare (the common multi-attachment case is several photos in
//    one post, which all collapse to `.image` anyway).
//

import Foundation
import GRDB

public enum AttachmentLoader {

    /// Chunk size for the SQLite `IN (?)` lists. Stays well under the 999
    /// limit even with the two-arg-shape of the balloon-bundle query.
    private static let chunkSize = 500

    /// Resolve the message type for each of the given message GUIDs.
    ///
    /// Returns a dictionary keyed by message GUID. GUIDs that map to `.text`
    /// are **omitted** from the dictionary (callers should treat absence as
    /// text — saves keeping a copy of every text GUID in memory).
    ///
    /// Two batched SQL queries per chunk:
    ///   1. `SELECT guid, balloon_bundle_id FROM message WHERE guid IN (...)`
    ///   2. `SELECT m.guid, a.mime_type, a.uti, a.is_sticker
    ///       FROM message m
    ///       JOIN message_attachment_join j ON j.message_id = m.ROWID
    ///       JOIN attachment a ON a.ROWID = j.attachment_id
    ///       WHERE m.guid IN (...)`
    ///
    /// Balloon-bundle signals win when present (URLBalloon → .linkPreview is
    /// more precise than the embedded preview image being classified as
    /// .image). For other rows the attachment row(s) determine the kind, with
    /// the `dominant(...)` rule resolving multi-attachment messages.
    public static func types(
        forMessageGUIDs guids: [String],
        database: ChatDatabase
    ) throws -> [String: MessageType] {
        guard !guids.isEmpty else { return [:] }
        let unique = Array(Set(guids.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }

        var out: [String: MessageType] = [:]
        // Collect attachment-derived kinds first; balloon signals override
        // them post-hoc so the linkPreview rule wins over its preview image.
        var attachmentKinds: [String: MessageType] = [:]
        var balloonKinds: [String: MessageType] = [:]

        for chunk in unique.chunked(by: chunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ", ")
            let args: [DatabaseValueConvertible] = chunk.map { $0 as DatabaseValueConvertible }

            // --- Q1: balloon_bundle_id signals -------------------------------
            // Pull every non-null bundle id for the chunk. We only care about a
            // small set of known IDs; everything else falls through to step 2.
            let balloonRows: [Row] = try database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT guid, balloon_bundle_id
                        FROM message
                        WHERE guid IN (\(placeholders))
                          AND balloon_bundle_id IS NOT NULL
                          AND balloon_bundle_id != ''
                        """,
                    arguments: StatementArguments(args)
                )
            }
            for row in balloonRows {
                guard let guid: String = row["guid"],
                      let bundle: String = row["balloon_bundle_id"] else { continue }
                if let kind = classifyBalloon(bundle) {
                    balloonKinds[guid] = kind
                }
            }

            // --- Q2: attachment-row classification ---------------------------
            // For multi-attachment messages we collect every (mime_type, uti,
            // is_sticker) triple and reduce to the dominant kind in Swift.
            let attRows: [Row] = try database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            m.guid       AS guid,
                            a.mime_type  AS mime_type,
                            a.uti        AS uti,
                            a.is_sticker AS is_sticker
                        FROM message m
                        JOIN message_attachment_join j ON j.message_id = m.ROWID
                        JOIN attachment a ON a.ROWID = j.attachment_id
                        WHERE m.guid IN (\(placeholders))
                        """,
                    arguments: StatementArguments(args)
                )
            }
            var perMessage: [String: [MessageType]] = [:]
            for row in attRows {
                guard let guid: String = row["guid"] else { continue }
                let mime: String? = row["mime_type"]
                let uti: String? = row["uti"]
                let isSticker: Bool = (row["is_sticker"] as Int? ?? 0) == 1
                let kind = classifyAttachment(mime: mime, uti: uti, isSticker: isSticker)
                perMessage[guid, default: []].append(kind)
            }
            for (guid, kinds) in perMessage {
                attachmentKinds[guid] = dominant(kinds)
            }
        }

        // Merge: balloon signals are more specific than the underlying
        // attachment heuristic (URLBalloon's preview image would otherwise
        // classify as .image). Apple Pay / location balloons sometimes carry
        // a pluginPayload attachment with no mime_type — without the bundle
        // ID we'd guess `.file` for those.
        for (guid, kind) in attachmentKinds {
            out[guid] = kind
        }
        for (guid, kind) in balloonKinds {
            out[guid] = kind
        }
        return out
    }

    // MARK: - Classification helpers

    /// Map a `balloon_bundle_id` string to a `MessageType`, or nil if the
    /// bundle doesn't correspond to one of our recognized kinds (in which
    /// case we fall through to the attachment-based classification).
    static func classifyBalloon(_ bundle: String) -> MessageType? {
        if bundle.contains("URLBalloonProvider") { return .linkPreview }
        // Apple Pay / Apple Cash. Verified on user's DB:
        //   com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:
        //   com.apple.PassbookUIService.PeerPaymentMessagesExtension
        if bundle.contains("PeerPaymentMessagesExtension") ||
           bundle.contains("PassbookUI") { return .applePay }
        // Location share — Find My.
        if bundle.contains("FindMyMessagesApp") ||
           bundle.contains("findmy.FindMy") { return .location }
        // Everything else (GamePigeon, polls, handwriting, digital touch,
        // photo slideshow, Game Center, chatbot, safety monitor, …) — there
        // are dozens, none worth giving distinct UI today.
        if bundle.contains("MSMessageExtensionBalloonPlugin") ||
           bundle.contains("DigitalTouchBalloonProvider") ||
           bundle.contains("HandwritingProvider") ||
           bundle.contains("messages.chatbot") {
            return .other
        }
        return nil
    }

    /// Classify a single attachment row.
    ///
    /// Precedence:
    ///   1. is_sticker = 1 → .sticker (even when mime_type indicates image)
    ///   2. mime_type prefix wins (image/, video/, audio/)
    ///   3. non-empty mime_type that doesn't match the above → .file
    ///   4. blank mime_type + UTI hints (mostly plugin payloads) → .file
    ///      (will usually be overridden by the balloon-bundle classifier).
    static func classifyAttachment(
        mime: String?,
        uti: String?,
        isSticker: Bool
    ) -> MessageType {
        if isSticker { return .sticker }
        let m = mime?.lowercased() ?? ""
        if m.hasPrefix("image/") { return .image }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        if !m.isEmpty { return .file }

        // Blank mime — fall back to UTI hints. Most blanks on real DBs are
        // plugin payloads (dyn.age…) which we treat as `.file` here; the
        // balloon-bundle pass in `types(...)` overrides them when applicable.
        let u = uti?.lowercased() ?? ""
        if u.hasPrefix("public.image.") { return .image }
        if u.contains("movie") || u.contains("video") { return .video }
        if u.contains("audio") || u.contains("m4a") || u.contains("mp3") { return .audio }
        return .file
    }

    /// Pick the dominant kind for a message that has multiple attachments.
    /// Most common case (several photos) collapses to `.image`. A photo +
    /// pluginPayload mix picks `.image` over `.file`.
    static func dominant(_ kinds: [MessageType]) -> MessageType {
        // Priority order — earlier wins.
        let order: [MessageType] = [
            .sticker, .image, .video, .audio, .file, .other,
            .linkPreview, .applePay, .location, .text,
        ]
        // Score = first index in `order`. Lower wins.
        var best: (Int, MessageType)? = nil
        for k in kinds {
            guard let idx = order.firstIndex(of: k) else { continue }
            if best == nil || idx < best!.0 {
                best = (idx, k)
            }
        }
        return best?.1 ?? .file
    }
}

private extension Array {
    /// Split into chunks of at most `size` elements. Last chunk may be smaller.
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            out.append(Array(self[i..<end]))
            i = end
        }
        return out
    }
}
