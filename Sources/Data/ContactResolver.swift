//
//  ContactResolver.swift
//  Hourglass
//
//  Reads the macOS AddressBook databases (potentially multiple — one per
//  Source, e.g. iCloud + On-My-Mac) and builds a `[Handle: Contact]` lookup
//  table. Mirrors the Python `build_name_map()` in the reference scripts.
//
//  Path pattern:
//    ~/Library/Application Support/AddressBook/Sources/<UUID>/AddressBook-v22.abcddb
//
//  Schema bits we care about:
//    ZABCDRECORD       (Z_PK, ZFIRSTNAME, ZLASTNAME)
//    ZABCDPHONENUMBER  (ZOWNER → ZABCDRECORD.Z_PK, ZFULLNUMBER)
//    ZABCDEMAILADDRESS (ZOWNER → ZABCDRECORD.Z_PK, ZADDRESS)
//
//  Merging:
//    Multiple Source DBs can list the same person (the iCloud one will
//    typically have everything; the local one might add a few). We merge
//    by display name — two records with the same first+last name combine
//    their handle sets.
//

import Foundation
import GRDB

public struct ResolvedContacts: Sendable {

    /// Lookup map: normalized handle -> contact. A single contact can appear
    /// multiple times in the values (one per handle it owns).
    public let byHandle: [Handle: Contact]

    /// All unique contacts, sorted by display name.
    public let allContacts: [Contact]

    /// The AddressBook "Me" record, when found. Detected via
    /// `ZABCDRECORD.ZCONTAINERWHERECONTACTISME IS NOT NULL` — the column
    /// AddressBook populates on whichever record the user marked as their
    /// own "Me" card. Used by `MessageSearch` to expand `from:me` to also
    /// match `from:"<my name>"` and `from:"<my phone/email>"`. Nil when no
    /// "Me" record exists (uncommon — macOS prompts new users to set one).
    public let meContact: Contact?

    public init(byHandle: [Handle: Contact], allContacts: [Contact], meContact: Contact? = nil) {
        self.byHandle = byHandle
        self.allContacts = allContacts
        self.meContact = meContact
    }

    /// Lookup convenience. Returns nil for unknown handles — callers should
    /// fall back to the raw handle string for display.
    public func contact(for handle: Handle) -> Contact? {
        byHandle[handle]
    }

    /// Resolve a raw handle string. Returns the contact name if known, the
    /// raw string if not.
    public func name(forRawHandle raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "(unknown)" }
        if let c = byHandle[Handle(raw: raw)] {
            return c.displayName
        }
        return raw
    }

    /// Avatar bytes for the contact owning the given raw handle. Returns the
    /// resolved contact's `avatarData` (raw PNG / JPEG) when known and a
    /// photo exists, otherwise nil — callers fall back to a generated
    /// initials/monogram. Empty / nil input → nil.
    public func avatarData(forRawHandle raw: String?) -> Data? {
        guard let raw, !raw.isEmpty else { return nil }
        return byHandle[Handle(raw: raw)]?.avatarData
    }
}

public enum ContactResolver {

    /// Glob the default AddressBook Sources directory for v22 databases.
    public static func defaultDatabaseURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sourcesRoot = home.appending(path: "Library/Application Support/AddressBook/Sources",
                                         directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries.compactMap { dir -> URL? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let candidate = dir.appending(path: "AddressBook-v22.abcddb",
                                          directoryHint: .notDirectory)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// Build the lookup. Silently skips Source DBs that fail to open
    /// (matches Python reference's tolerant behavior — one broken Source
    /// shouldn't kill contact resolution for the rest).
    ///
    /// **Avatar loading** is enabled by default. Each contact's `avatarData`
    /// is populated with the raw PNG/JPEG bytes from
    /// `ZABCDRECORD.ZTHUMBNAILIMAGEDATA` (preferred) or `ZIMAGEDATA`. The
    /// `0x01` (inline) / `0x02` (external `_EXTERNAL_DATA/<UUID>` reference)
    /// framing is handled by `AvatarStorage.decodeBest`. Pass
    /// `loadAvatars: false` to skip — useful in low-memory or test contexts.
    public static func resolve(
        databaseURLs: [URL]? = nil,
        loadAvatars: Bool = true
    ) -> ResolvedContacts {
        let urls = databaseURLs ?? defaultDatabaseURLs()

        // Codex audit M7 (2026-05-25): the previous version keyed
        // everything by `displayName`, which silently merged two
        // unrelated AddressBook records that happened to share a name
        // ("John" the colleague and "John" the cousin became one
        // contact, combining their handles and avatar bytes).
        //
        // We now key by `(sourceDBURL, pk)` — the AB record's stable
        // identity within its database. After all sources load, we
        // merge records ACROSS sources only when they share a handle
        // (which is the legitimate "iCloud + on-my-mac duplicate of
        // the same person" case). Same-name distinct records inside
        // a single AB database stay as separate `Contact`s. Same-name
        // records across sources with no handle overlap ALSO stay
        // separate — they're two different people who happen to share
        // a name.
        struct RecordKey: Hashable { let source: URL; let pk: Int64 }
        struct RecordAcc {
            var displayName: String
            var handles: Set<Handle>
            var avatar: Data?
            /// True if this AB record is the "Me" card for its source DB
            /// (`ZCONTAINERWHERECONTACTISME IS NOT NULL`). Propagates through
            /// the cross-source union-find merge below so that even if one
            /// source's "Me" entry has no handles of its own, a merged group
            /// containing it is still marked as `meContact`.
            var isMe: Bool
        }
        var perRecord: [RecordKey: RecordAcc] = [:]

        for dbURL in urls {
            var config = Configuration()
            config.readonly = true
            guard let queue = try? DatabaseQueue(path: dbURL.path, configuration: config) else {
                continue
            }
            // Resolve external-data directory once per Source DB. The blob's
            // `0x02` reference is a bare UUID — the directory tells us where
            // to find it.
            let externalDir = AvatarStorage.externalDataDirectory(forDatabase: dbURL)

            // Avatar columns are on the record itself, but phones/emails are
            // in side tables that we left-join. The cross product would
            // duplicate the BLOBs (huge). Two queries instead — one for the
            // (record, handle) cross product, one for (record, image-blobs)
            // keyed by Z_PK. Map by Z_PK to glue them together.
            //
            // The image query lives behind the `loadAvatars` flag so tests
            // and low-memory contexts can opt out.
            let handleRows: [Row] = (try? queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT r.Z_PK AS pk, r.ZFIRSTNAME, r.ZLASTNAME,
                           r.ZCONTAINERWHERECONTACTISME AS me_container,
                           p.ZFULLNUMBER, e.ZADDRESS
                    FROM ZABCDRECORD r
                    LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                    LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
                """)
            }) ?? []

            // imageBlobsByPK: Z_PK -> decoded PNG/JPEG bytes (or nil for
            // records without a usable photo). We don't store nil entries —
            // the dictionary's missing-key semantics handle that for us.
            var imageBlobsByPK: [Int64: Data] = [:]
            if loadAvatars {
                let imageRows: [Row] = (try? queue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT Z_PK AS pk, ZTHUMBNAILIMAGEDATA AS thumb, ZIMAGEDATA AS full
                        FROM ZABCDRECORD
                        WHERE ZTHUMBNAILIMAGEDATA IS NOT NULL
                           OR ZIMAGEDATA IS NOT NULL
                    """)
                }) ?? []
                for row in imageRows {
                    let pk: Int64 = row["pk"]
                    let thumb: Data? = row["thumb"]
                    let full: Data? = row["full"]
                    if let decoded = AvatarStorage.decodeBest(
                        thumbnailBlob: thumb,
                        fullBlob: full,
                        externalDataDirectory: externalDir
                    ) {
                        imageBlobsByPK[pk] = decoded
                    }
                }
            }

            for row in handleRows {
                guard let pk: Int64 = row["pk"] else { continue }
                let first: String? = row["ZFIRSTNAME"]
                let last: String? = row["ZLASTNAME"]
                let phone: String? = row["ZFULLNUMBER"]
                let email: String? = row["ZADDRESS"]

                let nameParts = [first, last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let displayName = nameParts.joined(separator: " ")
                guard !displayName.isEmpty else { continue }

                let key = RecordKey(source: dbURL, pk: pk)
                let isMe: Bool = (row["me_container"] as Int64?) != nil
                var acc = perRecord[key] ?? RecordAcc(
                    displayName: displayName,
                    handles: [],
                    avatar: imageBlobsByPK[pk],
                    isMe: isMe
                )
                // Same key seen across multiple LEFT JOIN rows: keep isMe
                // sticky (any sighting wins).
                if isMe { acc.isMe = true }

                if let phone, !phone.isEmpty {
                    let h = Handle(raw: phone)
                    if !h.normalized.isEmpty && h.normalized != " " {
                        acc.handles.insert(h)
                    }
                }
                if let email, !email.isEmpty {
                    let h = Handle(raw: email)
                    if !h.normalized.isEmpty {
                        acc.handles.insert(h)
                    }
                }
                if acc.avatar == nil, let bytes = imageBlobsByPK[pk] {
                    acc.avatar = bytes
                }
                perRecord[key] = acc
            }
        }

        // Union-find over records to merge across Sources when they share
        // a handle (legitimate iCloud-vs-local duplicates of the same
        // person). Records with no overlapping handles stay separate
        // even if they share a display name.
        let recordKeys = Array(perRecord.keys)
        var parent: [RecordKey: RecordKey] = Dictionary(uniqueKeysWithValues: recordKeys.map { ($0, $0) })
        func find(_ k: RecordKey) -> RecordKey {
            var root = k
            while parent[root] != root { root = parent[root]! }
            // Path compression.
            var cur = k
            while parent[cur] != root {
                let next = parent[cur]!
                parent[cur] = root
                cur = next
            }
            return root
        }
        func union(_ a: RecordKey, _ b: RecordKey) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        // Build handle → first-record-seen, union with subsequent records.
        var firstRecordForHandle: [Handle: RecordKey] = [:]
        for key in recordKeys {
            let acc = perRecord[key]!
            for h in acc.handles {
                if let existing = firstRecordForHandle[h] {
                    union(key, existing)
                } else {
                    firstRecordForHandle[h] = key
                }
            }
        }

        // Group records by their union-find root.
        var groups: [RecordKey: [RecordKey]] = [:]
        for key in recordKeys {
            let root = find(key)
            groups[root, default: []].append(key)
        }

        // Materialize one Contact per group.
        var contacts: [Contact] = []
        var byHandle: [Handle: Contact] = [:]
        var meContact: Contact? = nil
        contacts.reserveCapacity(groups.count)
        for (_, memberKeys) in groups {
            var displayName = ""
            var handles: Set<Handle> = []
            var avatar: Data? = nil
            var groupIsMe = false
            for k in memberKeys {
                let acc = perRecord[k]!
                if displayName.isEmpty { displayName = acc.displayName }
                handles.formUnion(acc.handles)
                if avatar == nil { avatar = acc.avatar }
                if acc.isMe { groupIsMe = true }
            }
            guard !displayName.isEmpty else { continue }
            let c = Contact(displayName: displayName, handles: handles, avatarData: avatar)
            contacts.append(c)
            for h in handles {
                // Handle-to-contact is now well-defined: union-find
                // guarantees a handle never appears in two distinct
                // groups, so this is no longer a last-writer-wins race.
                byHandle[h] = c
            }
            // Multiple "Me" records across sources can survive union-find
            // when they share no handle overlap (rare — the user typically
            // has at least one phone/email in common). Pick the one with
            // the most handles as the canonical Me; ties broken by name to
            // stay deterministic.
            if groupIsMe {
                if let existing = meContact {
                    if c.handles.count > existing.handles.count
                        || (c.handles.count == existing.handles.count
                            && c.displayName.localizedCaseInsensitiveCompare(existing.displayName) == .orderedAscending) {
                        meContact = c
                    }
                } else {
                    meContact = c
                }
            }
        }
        contacts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return ResolvedContacts(byHandle: byHandle, allContacts: contacts, meContact: meContact)
    }
}
