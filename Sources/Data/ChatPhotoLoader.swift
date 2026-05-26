//
//  ChatPhotoLoader.swift
//  Hourglass
//
//  Reads custom group-chat photos that the user set inside Messages.app.
//
//  The photo bytes are NOT stored in the database. The link from a chat row
//  to its photo runs:
//
//    chat.properties (BLOB, bplist00)
//        ↓  bplist key "groupPhotoGuid" → "at_0_<UUID>"
//    attachment.guid = "at_0_<UUID>"
//    attachment.filename = "~/Library/Messages/Attachments/.../GroupPhotoImage"
//        ↓  tilde-expand to absolute path
//    raw PNG/JPEG bytes on disk
//
//  See `docs/dashboard-avatars.md` for the empirical investigation.
//
//  This loader is pure read-only against chat.db. It does NOT enumerate every
//  attachment for every group — it only reads the bytes for the chats the
//  caller asks about (the dashboard's top-N). Reading 12 PNGs of ~500KB each
//  is ~6MB peak, fine to do on demand.
//

import Foundation
import GRDB

public enum ChatPhotoLoader {

    /// Load custom group photos for a set of chat ROWIDs.
    ///
    /// - Parameters:
    ///   - db: A GRDB `Database` from inside a read transaction.
    ///   - chatRowIDs: The chats to look up. Order is irrelevant.
    /// - Returns: A map from chat ROWID to raw PNG/JPEG bytes for every chat
    ///   that (a) has a `groupPhotoGuid` in its `properties` blob, (b) has a
    ///   matching `attachment` row, and (c) the file resolves and reads
    ///   successfully. Chats with no custom photo are simply absent.
    public static func loadGroupPhotos(
        db: Database,
        chatRowIDs: [Int64]
    ) throws -> [Int64: Data] {
        guard !chatRowIDs.isEmpty else { return [:] }

        // Fetch chat.properties blobs for the requested rows in one query.
        let placeholders = Array(repeating: "?", count: chatRowIDs.count).joined(separator: ", ")
        let propsSQL = """
            SELECT ROWID AS rowid, properties
            FROM chat
            WHERE ROWID IN (\(placeholders))
              AND properties IS NOT NULL
            """
        var propsArgs: [DatabaseValueConvertible] = []
        for rowID in chatRowIDs { propsArgs.append(rowID) }
        let propsRows = try Row.fetchAll(db, sql: propsSQL,
                                         arguments: StatementArguments(propsArgs))

        // Parse each blob and extract the groupPhotoGuid (if any). Build
        // both directions of the join: rowID → guid for the result map,
        // and the flat list of guids for the next query.
        var guidByRowID: [Int64: String] = [:]
        var guids: [String] = []
        for row in propsRows {
            guard let rowID: Int64 = row["rowid"],
                  let blob: Data = row["properties"] else { continue }
            guard let guid = groupPhotoGuid(fromPropertiesBlob: blob) else { continue }
            guidByRowID[rowID] = guid
            guids.append(guid)
        }
        guard !guids.isEmpty else { return [:] }

        // Look up each guid's filename in the attachment table.
        let attPlaceholders = Array(repeating: "?", count: guids.count)
            .joined(separator: ", ")
        let attSQL = """
            SELECT guid, filename
            FROM attachment
            WHERE guid IN (\(attPlaceholders))
            """
        var attArgs: [DatabaseValueConvertible] = []
        for g in guids { attArgs.append(g) }
        let attRows = try Row.fetchAll(db, sql: attSQL,
                                       arguments: StatementArguments(attArgs))

        var filenameByGuid: [String: String] = [:]
        for row in attRows {
            guard let g: String = row["guid"],
                  let fn: String = row["filename"] else { continue }
            filenameByGuid[g] = fn
        }

        // Read each file. Tilde-expand. Failures (missing file, permission
        // denied) silently drop — caller falls back to composite.
        var out: [Int64: Data] = [:]
        for (rowID, guid) in guidByRowID {
            guard let fn = filenameByGuid[guid] else { continue }
            let expanded = (fn as NSString).expandingTildeInPath
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
                  !bytes.isEmpty else { continue }
            out[rowID] = bytes
        }
        return out
    }

    /// Extract the `groupPhotoGuid` value from a `chat.properties` BLOB.
    ///
    /// The blob is always a binary plist (`bplist00` magic). Decode with
    /// Foundation and look up the key. Returns nil for non-plist blobs,
    /// missing keys, and non-string values — defensive but tolerant.
    ///
    /// Exposed for unit tests; not part of the public API contract.
    static func groupPhotoGuid(fromPropertiesBlob blob: Data) -> String? {
        guard !blob.isEmpty else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: blob,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }
        guard let guid = plist["groupPhotoGuid"] as? String,
              !guid.isEmpty else {
            return nil
        }
        return guid
    }
}
