//
//  AvatarStorage.swift
//  Hourglass
//
//  Decodes the macOS AddressBook avatar storage format.
//
//  AddressBook stores a contact photo in `ZABCDRECORD.ZIMAGEDATA` (or the
//  thumbnail-sized `ZTHUMBNAILIMAGEDATA`). The BLOB is framed with a
//  one-byte marker indicating storage mode:
//
//    0x01   inline    — bytes 1..end are raw PNG or JPEG.
//    0x02   external  — bytes 1..end are an ASCII UUID (36 chars) plus a
//                       null terminator. The UUID is the filename in the
//                       sibling `_EXTERNAL_DATA/` directory.
//
//  Anything else (other framing bytes, truncated blobs, monogram-only rows
//  whose data lives in `ZAVATARRECIPEDATA`) is treated as "no avatar".
//
//  See `docs/contact-avatars.md` for the empirical schema deep-dive.
//

import Foundation

public enum AvatarStorage {

    /// Decode the AddressBook image-data BLOB to raw PNG / JPEG bytes.
    ///
    /// - Parameters:
    ///   - blob: The BLOB bytes from `ZIMAGEDATA` or `ZTHUMBNAILIMAGEDATA`.
    ///   - externalDataDirectory: The Source DB's `_EXTERNAL_DATA/` directory,
    ///     used to resolve `0x02` (external) references. Pass nil to skip
    ///     external lookups (tests, sandboxes, or "I just want inline").
    /// - Returns: The raw image bytes ready for `NSImage(data:)`, or nil when
    ///   the BLOB is empty / has unknown framing / points at a missing file /
    ///   reads as a monogram-only sentinel.
    public static func decode(blob: Data?, externalDataDirectory: URL?) -> Data? {
        guard let blob, !blob.isEmpty else { return nil }
        switch blob[blob.startIndex] {
        case 0x01:
            // Inline image. Drop the framing byte and return.
            let payload = blob.dropFirst()
            return payload.isEmpty ? nil : Data(payload)
        case 0x02:
            // External reference: 0x02 + ASCII UUID (36 chars) + 0x00.
            guard let dir = externalDataDirectory else { return nil }
            // Parse the UUID, stopping at the first NUL (or end).
            let afterMarker = blob.dropFirst()
            let nameBytes: Data
            if let nullIdx = afterMarker.firstIndex(of: 0x00) {
                nameBytes = afterMarker[afterMarker.startIndex..<nullIdx]
            } else {
                nameBytes = afterMarker
            }
            guard !nameBytes.isEmpty,
                  let uuid = String(data: nameBytes, encoding: .ascii),
                  !uuid.isEmpty else {
                return nil
            }
            // Defense in depth: refuse anything with slashes or "..". The
            // UUIDs are always 36-char hex+dash, so this is belt-and-braces.
            if uuid.contains("/") || uuid.contains("..") { return nil }
            let fileURL = dir.appending(path: uuid, directoryHint: .notDirectory)
            return try? Data(contentsOf: fileURL)
        default:
            // Unknown framing byte. Could be a future Apple change or a
            // monogram-encoded blob we don't understand — bail cleanly.
            return nil
        }
    }

    /// Pick the best avatar candidate from a record's two columns.
    ///
    /// **Preference order**: thumbnail first (it's pre-sized for compact UI
    /// and ~30% smaller on average), full-resolution as fallback. Either
    /// column can be in either storage mode, so we just try both through
    /// `decode(blob:externalDataDirectory:)`.
    public static func decodeBest(
        thumbnailBlob: Data?,
        fullBlob: Data?,
        externalDataDirectory: URL?
    ) -> Data? {
        if let thumb = decode(blob: thumbnailBlob, externalDataDirectory: externalDataDirectory) {
            return thumb
        }
        return decode(blob: fullBlob, externalDataDirectory: externalDataDirectory)
    }

    /// The directory `_EXTERNAL_DATA/` lives at, given a Source DB URL.
    ///
    /// Path layout:
    /// ```
    /// .../Sources/<UUID>/AddressBook-v22.abcddb            ← databaseURL
    /// .../Sources/<UUID>/.AddressBook-v22_SUPPORT/
    ///                       _EXTERNAL_DATA/                ← returned
    /// ```
    public static func externalDataDirectory(forDatabase databaseURL: URL) -> URL {
        databaseURL
            .deletingLastPathComponent()
            .appending(path: ".AddressBook-v22_SUPPORT/_EXTERNAL_DATA",
                       directoryHint: .isDirectory)
    }
}
