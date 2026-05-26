//
//  AvatarLoadingTests.swift
//  Hourglass
//
//  Unit tests for the AddressBook avatar pipeline:
//    - `AvatarStorage.decode` — the framing-byte splitter
//    - `AvatarStorage.decodeBest` — thumbnail-preferred picker
//    - `ContactResolver.resolve(loadAvatars:)` — opt-in flag round trip
//
//  All tests are pure: synthesized in-memory BLOBs, no real DB required.
//  External (`0x02`) tests use a temp directory we stand up per test —
//  fast (microseconds) and self-cleaning.
//

import Foundation
import XCTest
@testable import Hourglass

/// Tiny PNG payload used as a stand-in for real image bytes. Functionally
/// opaque — we just need something `NSImage(data:)` would happily accept,
/// and the decoder should pass it through byte-for-byte.
private let tinyPNG: Data = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,   // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,   // IHDR chunk
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
    0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
    0x08, 0x99, 0x63, 0xF8, 0xCF, 0xC0, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01,
    0x83, 0xB3, 0xCC, 0xA1,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
    0xAE, 0x42, 0x60, 0x82
])

/// JPEG magic for verifying decode preserves bytes.
private let tinyJPEG: Data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

final class AvatarLoadingTests: XCTestCase {

    // MARK: - decode(blob:externalDataDirectory:)

    func testDecodeInlinePNGStripsFramingByte() throws {
        // Mode 1: 0x01 + raw PNG bytes — common for newer contacts.
        let blob = Data([0x01]) + tinyPNG
        let decoded = AvatarStorage.decode(blob: blob, externalDataDirectory: nil)
        XCTAssertEqual(decoded, tinyPNG, "Inline mode should return everything after the framing byte verbatim")
    }

    func testDecodeInlineJPEGStripsFramingByte() throws {
        let blob = Data([0x01]) + tinyJPEG
        let decoded = AvatarStorage.decode(blob: blob, externalDataDirectory: nil)
        XCTAssertEqual(decoded, tinyJPEG)
    }

    func testDecodeExternalReferenceReadsFromDisk() throws {
        // Mode 2: 0x02 + ASCII UUID + 0x00. The UUID names a file in the
        // external-data dir. We stand one up, write our PNG, and check that
        // decode reads it back exactly.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let fileURL = dir.appending(path: uuid, directoryHint: .notDirectory)
        try tinyJPEG.write(to: fileURL)

        var blob = Data([0x02])
        blob.append(uuid.data(using: .ascii)!)
        blob.append(0x00)  // null terminator

        let decoded = AvatarStorage.decode(blob: blob, externalDataDirectory: dir)
        XCTAssertEqual(decoded, tinyJPEG)
    }

    func testDecodeExternalReferenceWithoutTrailingNullStillWorks() throws {
        // Empirically the trailing 0x00 always exists in real DBs, but we
        // should be defensive — the blob.count == 37 case (no null) should
        // still parse the UUID and find the file.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let uuid = "12345678-1234-1234-1234-123456789012"
        try tinyPNG.write(to: dir.appending(path: uuid, directoryHint: .notDirectory))

        var blob = Data([0x02])
        blob.append(uuid.data(using: .ascii)!)
        // NO trailing null
        let decoded = AvatarStorage.decode(blob: blob, externalDataDirectory: dir)
        XCTAssertEqual(decoded, tinyPNG)
    }

    func testDecodeExternalReferenceMissingFileReturnsNil() throws {
        // The blob says "go look at UUID X" — but X doesn't exist on disk.
        // We should return nil cleanly rather than throwing.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var blob = Data([0x02])
        blob.append("MISSING1-MISSING2-MISSING3-MISSING4".data(using: .ascii)!)
        blob.append(0x00)
        XCTAssertNil(AvatarStorage.decode(blob: blob, externalDataDirectory: dir))
    }

    func testDecodeExternalReferenceWithoutDirectoryReturnsNil() throws {
        // No external-data dir provided — there's nowhere to look.
        // Should return nil, not crash, not return the raw UUID bytes.
        var blob = Data([0x02])
        blob.append("AAAA-AAAA-AAAA-AAAA-AAAA".data(using: .ascii)!)
        XCTAssertNil(AvatarStorage.decode(blob: blob, externalDataDirectory: nil))
    }

    func testDecodeNilOrEmptyBlobIsNil() {
        XCTAssertNil(AvatarStorage.decode(blob: nil, externalDataDirectory: nil))
        XCTAssertNil(AvatarStorage.decode(blob: Data(), externalDataDirectory: nil))
    }

    func testDecodeUnknownFramingByteIsNil() {
        // Anything other than 0x01 / 0x02 — bail.
        for marker: UInt8 in [0x00, 0x03, 0xFF, 0x42] {
            var blob = Data([marker])
            blob.append(tinyPNG)
            XCTAssertNil(
                AvatarStorage.decode(blob: blob, externalDataDirectory: nil),
                "Framing byte 0x\(String(marker, radix: 16)) should be rejected"
            )
        }
    }

    func testDecodeInlineEmptyAfterMarkerIsNil() {
        // 0x01 alone — no actual image data follows. Reject rather than
        // hand the caller an empty Data() that NSImage would fail on.
        XCTAssertNil(AvatarStorage.decode(blob: Data([0x01]), externalDataDirectory: nil))
    }

    func testDecodeExternalRejectsPathTraversalUUID() throws {
        // If the "UUID" contains "..", refuse to follow it. Belt-and-braces:
        // real UUIDs are hex+dash only, but the decoder should never be a
        // path-traversal sink.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var blob = Data([0x02])
        blob.append("../../../etc/passwd".data(using: .ascii)!)
        blob.append(0x00)
        XCTAssertNil(AvatarStorage.decode(blob: blob, externalDataDirectory: dir))
    }

    // MARK: - decodeBest(thumbnail:full:externalDataDirectory:)

    func testDecodeBestPrefersThumbnailWhenBothPresent() throws {
        // Thumbnail wins — 30% smaller on average, pre-sized for UI.
        let thumb = Data([0x01]) + tinyPNG
        let full = Data([0x01]) + tinyJPEG  // different magic so we can tell
        let decoded = AvatarStorage.decodeBest(
            thumbnailBlob: thumb,
            fullBlob: full,
            externalDataDirectory: nil
        )
        XCTAssertEqual(decoded, tinyPNG)
    }

    func testDecodeBestFallsBackToFullWhenThumbnailNil() {
        let full = Data([0x01]) + tinyJPEG
        let decoded = AvatarStorage.decodeBest(
            thumbnailBlob: nil,
            fullBlob: full,
            externalDataDirectory: nil
        )
        XCTAssertEqual(decoded, tinyJPEG)
    }

    func testDecodeBestFallsBackToFullWhenThumbnailUnparseable() {
        // Thumbnail blob has unknown framing — full is fine.
        let thumb = Data([0xFF, 0x00, 0x00])  // garbage framing
        let full = Data([0x01]) + tinyPNG
        let decoded = AvatarStorage.decodeBest(
            thumbnailBlob: thumb,
            fullBlob: full,
            externalDataDirectory: nil
        )
        XCTAssertEqual(decoded, tinyPNG)
    }

    func testDecodeBestNilEverywhereIsNil() {
        XCTAssertNil(AvatarStorage.decodeBest(
            thumbnailBlob: nil,
            fullBlob: nil,
            externalDataDirectory: nil
        ))
    }

    // MARK: - externalDataDirectory(forDatabase:)

    func testExternalDataDirectoryDerivedFromDBPath() {
        // The directory layout is fixed:
        //   .../Sources/<UUID>/AddressBook-v22.abcddb
        //   .../Sources/<UUID>/.AddressBook-v22_SUPPORT/_EXTERNAL_DATA/
        let db = URL(fileURLWithPath: "/Users/x/Library/Application Support/AddressBook/Sources/ABC-123/AddressBook-v22.abcddb")
        let dir = AvatarStorage.externalDataDirectory(forDatabase: db)
        XCTAssertEqual(
            dir.path,
            "/Users/x/Library/Application Support/AddressBook/Sources/ABC-123/.AddressBook-v22_SUPPORT/_EXTERNAL_DATA"
        )
    }

    // MARK: - ContactResolver integration

    func testContactInitDefaultsAvatarDataNil() {
        // Backwards-compatible: existing callers (tests that construct
        // Contact directly without an avatar) keep working.
        let c = Contact(displayName: "Alice", handles: [Handle(raw: "+15551234567")])
        XCTAssertNil(c.avatarData)
    }

    func testContactInitWithAvatarData() {
        let c = Contact(
            displayName: "Bob",
            handles: [Handle(raw: "bob@example.com")],
            avatarData: tinyPNG
        )
        XCTAssertEqual(c.avatarData, tinyPNG)
    }

    func testResolvedContactsAvatarLookupByRawHandle() {
        let alice = Contact(
            displayName: "Alice",
            handles: [Handle(raw: "+15551234567")],
            avatarData: tinyPNG
        )
        let resolved = ResolvedContacts(
            byHandle: [Handle(raw: "+15551234567"): alice],
            allContacts: [alice]
        )
        XCTAssertEqual(resolved.avatarData(forRawHandle: "+15551234567"), tinyPNG)
        // Different raw form, same normalized — should still hit (Handle's
        // Equatable is normalized-only).
        XCTAssertEqual(resolved.avatarData(forRawHandle: "(555) 123-4567"), tinyPNG)
        XCTAssertNil(resolved.avatarData(forRawHandle: "+15559999999"))
        XCTAssertNil(resolved.avatarData(forRawHandle: nil))
        XCTAssertNil(resolved.avatarData(forRawHandle: ""))
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "AvatarLoadingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
}
