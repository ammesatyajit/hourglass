//
//  DashboardAvatarsTests.swift
//  HourglassTests
//
//  Verifies that avatar data flows correctly through `DashboardLoader` for
//  both surfaces:
//
//   - `ContactStat.avatarData` — copied from `ResolvedContacts.byHandle`
//     when the loader rolls up a 1:1 top-contacts entry.
//   - `GroupStat.chatAvatarData` — read from `chat.properties.groupPhotoGuid`
//     → `attachment.filename` → bytes on disk, via `ChatPhotoLoader`.
//   - `GroupStat.participantAvatars` — fed from the resolved `Contact`s of
//     the chat's participants when there's no custom group photo.
//
//  Also covers the small `ChatPhotoLoader.groupPhotoGuid` plist parser in
//  isolation — round-trip a synthesized bplist and verify the key extracts.
//

import Foundation
import GRDB
import XCTest
@testable import Hourglass

final class DashboardAvatarsTests: XCTestCase {

    /// Canonical test clock — matches `DashboardLoaderTests` so a single
    /// fixture covers both classes. 2026-05-22 12:00 UTC.
    private let testNow = Date(timeIntervalSince1970: 1_779_451_200)
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Tiny PNG payload — opaque to us, just needs to round-trip byte-for-byte.
    private let tinyPNG: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0x99, 0x63, 0xF8, 0xCF, 0xC0, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01,
        0x83, 0xB3, 0xCC, 0xA1,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82
    ])

    /// JPEG magic for a second distinguishable image.
    private let tinyJPEG: Data = Data([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, 0x01
    ])

    private func openFixture() throws -> ChatDatabase {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources.")
        }
        return try ChatDatabase(url: url)
    }

    private var emptyContacts: ResolvedContacts {
        ResolvedContacts(byHandle: [:], allContacts: [])
    }

    // MARK: - ContactStat avatar propagation

    /// When the `ResolvedContacts` map carries a photo, the top-contacts
    /// loader must copy it onto the `ContactStat`.
    func testContactStatCarriesAvatarBytesWhenContactHasPhoto() throws {
        let db = try openFixture()
        let phone = Handle(raw: "+15551234567")
        let email = Handle(raw: "friend@example.com")
        let contact = Contact(
            displayName: "Friend Cactus",
            handles: [phone, email],
            avatarData: tinyPNG
        )
        let resolved = ResolvedContacts(
            byHandle: [phone: contact, email: contact],
            allContacts: [contact]
        )

        let stats = try DashboardLoader.loadSync(
            database: db, contacts: resolved, window: .last30Days,
            now: testNow, calendar: calendar
        )

        let merged = stats.topContacts.first { $0.displayName == "Friend Cactus" }
        let entry = try XCTUnwrap(merged, "Expect merged entry under contact's display name.")
        XCTAssertEqual(entry.avatarData, tinyPNG,
                       "ContactStat must surface the resolved Contact's avatarData.")
    }

    /// Handles that resolve to a contact WITHOUT a photo produce a nil
    /// `avatarData` — callers fall back to initials. Verifies backwards
    /// compatibility with the old (pre-avatar) `Contact` shape.
    func testContactStatNilWhenContactHasNoPhoto() throws {
        let db = try openFixture()
        let phone = Handle(raw: "+15551234567")
        let email = Handle(raw: "friend@example.com")
        let contact = Contact(
            displayName: "Friend Cactus",
            handles: [phone, email],
            avatarData: nil
        )
        let resolved = ResolvedContacts(
            byHandle: [phone: contact, email: contact],
            allContacts: [contact]
        )

        let stats = try DashboardLoader.loadSync(
            database: db, contacts: resolved, window: .last30Days,
            now: testNow, calendar: calendar
        )

        let merged = try XCTUnwrap(stats.topContacts.first { $0.displayName == "Friend Cactus" })
        XCTAssertNil(merged.avatarData, "Contact without a photo → nil avatarData.")
    }

    /// Unknown handles (raw phone numbers not in AddressBook) get nil
    /// `avatarData` — there's no Contact to read from.
    func testContactStatNilForUnresolvedHandles() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db, contacts: emptyContacts, window: .last30Days,
            now: testNow, calendar: calendar
        )
        // The fixture has at least one unresolved phone-number entry.
        guard let unresolved = stats.topContacts.first(where: {
            $0.displayName.hasPrefix("+1555")
        }) else {
            XCTFail("Expected at least one raw-handle entry in fixture results.")
            return
        }
        XCTAssertNil(unresolved.avatarData,
                     "Unresolved raw handles never have an avatar.")
    }

    // MARK: - GroupStat avatar resolution

    /// In the bare fixture (no `chat.properties.groupPhotoGuid` rows wired
    /// up by default), every GroupStat should report `chatAvatarData == nil`
    /// AND a `participantAvatars` array reflecting the chat's participants
    /// — each entry nil because no contacts have photos.
    func testGroupStatCompositeFallbackWhenNoCustomPhoto() throws {
        let db = try openFixture()
        let stats = try DashboardLoader.loadSync(
            database: db, contacts: emptyContacts, window: .allTime,
            now: testNow, calendar: calendar
        )

        guard let dashboardGroup = stats.topGroups.first(where: { $0.displayName == "Dashboard Group" }) else {
            XCTFail("Expected 'Dashboard Group' in fixture results.")
            return
        }
        XCTAssertNil(dashboardGroup.chatAvatarData,
                     "No custom photo set on fixture group → chatAvatarData nil.")
        // Dashboard Group has 3 participants in the fixture; the composite
        // pulls the first 3.
        XCTAssertEqual(dashboardGroup.participantAvatars.count, 3,
                       "Composite feedstock should cover up to 3 participants.")
        for slot in dashboardGroup.participantAvatars {
            XCTAssertNil(slot, "Empty AddressBook → every slot nil.")
        }
    }

    /// When participants ARE in AddressBook with photos, the composite
    /// feedstock should populate those slots with the matching bytes
    /// (and only those slots).
    func testGroupStatParticipantAvatarsFilledWhenContactsHavePhotos() throws {
        let db = try openFixture()

        // Wire up: handle 1 (phone) → Friend Cactus (with tinyPNG).
        //         handle 3 (phone) → Other Person (with tinyJPEG).
        //         handle 4 (phone) → unresolved (nil bytes).
        let h1 = Handle(raw: "+15551234567")
        let h3 = Handle(raw: "+15557654321")
        let cactus = Contact(displayName: "Friend Cactus", handles: [h1], avatarData: tinyPNG)
        let other = Contact(displayName: "Other Person", handles: [h3], avatarData: tinyJPEG)
        let resolved = ResolvedContacts(
            byHandle: [h1: cactus, h3: other],
            allContacts: [cactus, other]
        )

        let stats = try DashboardLoader.loadSync(
            database: db, contacts: resolved, window: .allTime,
            now: testNow, calendar: calendar
        )

        guard let dashboardGroup = stats.topGroups.first(where: { $0.displayName == "Dashboard Group" }) else {
            XCTFail("Expected 'Dashboard Group' in fixture results.")
            return
        }
        XCTAssertNil(dashboardGroup.chatAvatarData,
                     "No custom photo → chatAvatarData remains nil.")
        // Dashboard Group has handles 1, 3, 4 — first 3 participants. We
        // can't fully control SQL row order, so assert membership, not slot
        // order. Both photo bytes must be present; one slot is nil.
        XCTAssertEqual(dashboardGroup.participantAvatars.count, 3,
                       "Still feed 3 slots.")
        let nonNilBytes = dashboardGroup.participantAvatars.compactMap { $0 }
        XCTAssertEqual(Set(nonNilBytes), [tinyPNG, tinyJPEG],
                       "Participant photos surfaced for both resolved contacts.")
        XCTAssertEqual(dashboardGroup.participantAvatars.filter { $0 == nil }.count, 1,
                       "Unresolved handle → nil slot preserved.")
    }

    // MARK: - ChatPhotoLoader.groupPhotoGuid plist parsing

    /// Synthesize a tiny bplist {"groupPhotoGuid": "at_0_xxxx"} and verify
    /// the parser extracts the value.
    func testGroupPhotoGuidExtractedFromBplist() throws {
        let payload: [String: Any] = [
            "groupPhotoGuid": "at_0_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "pv": 13,
            "put": 1717026844.870727
        ]
        let blob = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        let guid = ChatPhotoLoader.groupPhotoGuid(fromPropertiesBlob: blob)
        XCTAssertEqual(guid, "at_0_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    /// A bplist without `groupPhotoGuid` → nil (common — ~93% of real
    /// groups). Must not crash on legit-but-imageless properties.
    func testGroupPhotoGuidNilWhenAbsent() throws {
        let payload: [String: Any] = [
            "hasBeenAutoSpamReported": false,
            "shouldForceToSMS": false
        ]
        let blob = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        XCTAssertNil(ChatPhotoLoader.groupPhotoGuid(fromPropertiesBlob: blob))
    }

    /// A bplist with `groupPhotoGuid` set to an empty string → treated as
    /// absent (Messages.app's "user removed the photo" sentinel).
    func testGroupPhotoGuidNilWhenEmptyString() throws {
        let payload: [String: Any] = ["groupPhotoGuid": ""]
        let blob = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        XCTAssertNil(ChatPhotoLoader.groupPhotoGuid(fromPropertiesBlob: blob))
    }

    /// Non-plist garbage in the blob → nil, never crash.
    func testGroupPhotoGuidNilOnGarbageBlob() {
        XCTAssertNil(ChatPhotoLoader.groupPhotoGuid(
            fromPropertiesBlob: Data([0xDE, 0xAD, 0xBE, 0xEF])
        ))
    }

    /// Empty blob → nil. Same as garbage but a frequent enough edge case
    /// (newly created chats with no properties yet) to assert explicitly.
    func testGroupPhotoGuidNilOnEmptyBlob() {
        XCTAssertNil(ChatPhotoLoader.groupPhotoGuid(fromPropertiesBlob: Data()))
    }

    /// `groupPhotoGuid` typed as a non-string → nil. Defensive against
    /// future Apple schema changes that might store the GUID differently.
    func testGroupPhotoGuidNilWhenNonStringValue() throws {
        let payload: [String: Any] = ["groupPhotoGuid": 12345]
        let blob = try PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0
        )
        XCTAssertNil(ChatPhotoLoader.groupPhotoGuid(fromPropertiesBlob: blob))
    }

    // MARK: - ChatPhotoLoader end-to-end

    /// Build an in-process DB with: a group chat row whose `properties`
    /// bplist references a `groupPhotoGuid`, an `attachment` row matching
    /// that GUID, and a temporary file at the resolved path. Then call
    /// `ChatPhotoLoader.loadGroupPhotos` and verify the bytes round-trip.
    func testLoadGroupPhotosResolvesAttachmentToBytesOnDisk() throws {
        // Stand up a temp file for the photo. Use a path that doesn't need
        // tilde expansion — the loader uses NSString.expandingTildeInPath,
        // which is a no-op for already-absolute paths.
        let tmpDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let photoFile = tmpDir.appending(path: "GroupPhotoImage",
                                         directoryHint: .notDirectory)
        try tinyPNG.write(to: photoFile)

        // bplist with the groupPhotoGuid pointing at our synthesized
        // attachment guid.
        let attachmentGuid = "at_0_FAKE-PHOTO-GUID-FOR-TESTS"
        let plist: [String: Any] = ["groupPhotoGuid": attachmentGuid]
        let propsBlob = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )

        // Build a tiny in-memory chat.db with just the columns the loader
        // needs.
        let dbPath = tmpDir.appending(path: "fixture.db",
                                      directoryHint: .notDirectory).path
        let queue = try GRDBOpenWritable(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE chat (
                    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                    style INTEGER,
                    properties BLOB
                );
                CREATE TABLE attachment (
                    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                    guid TEXT,
                    filename TEXT
                );
            """)
            // chat row 7 has properties pointing at our guid
            try db.execute(sql: """
                INSERT INTO chat (ROWID, style, properties) VALUES (7, 43, ?)
            """, arguments: [propsBlob])
            // chat row 8 has properties but no groupPhotoGuid key
            let nakedProps = try PropertyListSerialization.data(
                fromPropertyList: ["hasResponded": true],
                format: .binary, options: 0
            )
            try db.execute(sql: """
                INSERT INTO chat (ROWID, style, properties) VALUES (8, 43, ?)
            """, arguments: [nakedProps])
            try db.execute(sql: """
                INSERT INTO attachment (guid, filename) VALUES (?, ?)
            """, arguments: [attachmentGuid, photoFile.path])
        }

        // Query through the public API.
        let result = try queue.read { db in
            try ChatPhotoLoader.loadGroupPhotos(db: db, chatRowIDs: [7, 8, 9])
        }
        XCTAssertEqual(result.count, 1, "Only chat 7 has a resolvable photo.")
        XCTAssertEqual(result[7], tinyPNG, "Photo bytes round-trip exactly.")
        XCTAssertNil(result[8], "Chat 8 has properties but no groupPhotoGuid.")
        XCTAssertNil(result[9], "Chat 9 doesn't exist.")
    }

    /// Empty input → empty output, no DB hit. Common path when a window
    /// has zero groups.
    func testLoadGroupPhotosEmptyChatRowIDsReturnsEmpty() throws {
        let db = try openFixture()
        try db.dbQueue.read { handle in
            let result = try ChatPhotoLoader.loadGroupPhotos(db: handle, chatRowIDs: [])
            XCTAssertTrue(result.isEmpty)
        }
    }

    /// A `groupPhotoGuid` that doesn't have a matching `attachment` row
    /// silently produces no result for that chat (no crash, no partial
    /// data). Defensive against rare orphaned references.
    func testLoadGroupPhotosOrphanedGuidSilentlyDropped() throws {
        let tmpDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let propsBlob = try PropertyListSerialization.data(
            fromPropertyList: ["groupPhotoGuid": "at_0_ORPHAN"],
            format: .binary, options: 0
        )

        let dbPath = tmpDir.appending(path: "fixture.db",
                                      directoryHint: .notDirectory).path
        let queue = try GRDBOpenWritable(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE chat (
                    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                    style INTEGER,
                    properties BLOB
                );
                CREATE TABLE attachment (
                    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                    guid TEXT,
                    filename TEXT
                );
            """)
            try db.execute(sql: """
                INSERT INTO chat (ROWID, style, properties) VALUES (1, 43, ?)
            """, arguments: [propsBlob])
            // No matching attachment row.
        }

        let result = try queue.read { db in
            try ChatPhotoLoader.loadGroupPhotos(db: db, chatRowIDs: [1])
        }
        XCTAssertTrue(result.isEmpty, "Orphaned guid → silently dropped, no result.")
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "DashboardAvatarsTests-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}

// MARK: - GRDB writable handle helper (test-local)

/// Opens a writable GRDB queue at the given path. Internal helper — the
/// production `ChatDatabase` is read-only, but tests need to write fixture
/// rows. Equivalent to `DatabaseQueue(path:)` with no extra configuration.
private func GRDBOpenWritable(path: String) throws -> DatabaseQueue {
    var config = Configuration()
    config.readonly = false
    return try DatabaseQueue(path: path, configuration: config)
}
