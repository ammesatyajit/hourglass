//
//  AttributedBodyDecoderTests.swift
//  HourglassTests
//
//  Locks the typedstream length-prefix stripping behavior in
//  `Sources/Data/AttributedBodyDecoder.swift`.
//
//  Background: attributedBody NSStrings are stored with a 1-byte length
//  prefix. After lossy UTF-8 decoding, that prefix survives as a single
//  scalar exactly when its byte value is in printable-ASCII range
//  (0x20–0x7E). The decoder strips it iff the rest of the run's UTF-8
//  byte length equals the leading scalar's byte value.
//
//  Test names follow the spec in `.claude/agents/features-agent.md`:
//    - testStrip_digitLengthPrefix         (regression-protect digits)
//    - testStrip_punctuationLengthPrefix   (broadened — '?' = 63)
//    - testStrip_letterLengthPrefix        (broadened — 'D' = 68)
//    - testStrip_emojiNotStripped          (above 0x7E never stripped)
//    - testStrip_lengthMismatchPreserved   ("1st place", "$5 each")
//    - testStrip_realFixtureRow            (end-to-end through ChatDatabase)
//

import XCTest
import GRDB
@testable import Hourglass

final class AttributedBodyDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Build a string whose first scalar is `prefix` (a single-byte UTF-8
    /// char) and whose body has `bodyLength` UTF-8 bytes.
    private func runWithPrefix(_ prefix: Character, bodyByteLength: Int) -> String {
        // Use ASCII 'a' filler — 1 byte each. UTF-8 byte length == count.
        precondition(prefix.utf8.count == 1, "Prefix must be a single ASCII byte for these tests.")
        let body = String(repeating: "a", count: bodyByteLength)
        XCTAssertEqual(body.utf8.count, bodyByteLength, "Filler byte length should equal char count for ASCII filler.")
        return "\(prefix)\(body)"
    }

    // MARK: - Digit prefix (regression-protect the original narrow fix)

    /// A run that starts with an ASCII digit whose value equals the rest's
    /// UTF-8 byte length must be stripped. This was the entirety of the
    /// pre-broadening behavior — keep it nailed down.
    func testStrip_digitLengthPrefix() {
        // '2' = 0x32 = 50. Body of 50 'a's = 50 bytes. Should strip.
        let run = runWithPrefix("2", bodyByteLength: 50)
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, String(repeating: "a", count: 50),
                       "Digit length prefix '2' (50) over 50-byte body should be stripped.")

        // '5' = 0x35 = 53. Body of 53 'a's.
        let run2 = runWithPrefix("5", bodyByteLength: 53)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run2),
                       String(repeating: "a", count: 53))
    }

    // MARK: - Punctuation prefix (new — covers '?', '"', '/', etc.)

    /// User-reported pattern: `"?So none of our chats are private…"`. '?' is
    /// 0x3F = 63. Synthesize a 63-byte body and assert the '?' is stripped.
    func testStrip_punctuationLengthPrefix() {
        // '?' = 63.
        let body = "So none of our chats are private. Should we use cactus instead?"
        XCTAssertEqual(body.utf8.count, 63,
                       "Body length must match the prefix byte value for this test.")
        let run = "?\(body)"
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, body,
                       "'?' (63) over a 63-byte body must be stripped.")
    }

    /// Synthetic case where the prefix is a different punctuation char.
    func testStrip_punctuationLengthPrefix_otherChars() {
        // '"' = 0x22 = 34. 34-byte body of 'a's.
        let run34 = runWithPrefix("\"", bodyByteLength: 34)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run34),
                       String(repeating: "a", count: 34),
                       "'\"' (34) over 34-byte body must be stripped.")

        // '/' = 0x2F = 47. 47-byte body.
        let run47 = runWithPrefix("/", bodyByteLength: 47)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run47),
                       String(repeating: "a", count: 47),
                       "'/' (47) over 47-byte body must be stripped.")
    }

    // MARK: - Letter prefix (new — covers 'D', 'r', 'A', …)

    /// User-reported pattern: `"DSatyajit Kanna, how does Turboquant…"`.
    /// 'D' is 0x44 = 68. Synthesize a 68-byte body and assert stripped.
    func testStrip_letterLengthPrefix() {
        // 'D' = 68. 68-byte body of 'a's.
        let run = runWithPrefix("D", bodyByteLength: 68)
        let stripped = AttributedBodyDecoder.stripLengthPrefix(run)
        XCTAssertEqual(stripped, String(repeating: "a", count: 68),
                       "'D' (68) over 68-byte body must be stripped.")

        // 'A' = 0x41 = 65. 65-byte body.
        let run65 = runWithPrefix("A", bodyByteLength: 65)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run65),
                       String(repeating: "a", count: 65),
                       "'A' (65) over 65-byte body must be stripped.")

        // 'r' = 0x72 = 114. 114-byte body — matches the user-reported
        // "rSatyajit Kanna, you're getting paid $4,254 …" pattern.
        let run114 = runWithPrefix("r", bodyByteLength: 114)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run114),
                       String(repeating: "a", count: 114),
                       "'r' (114) over 114-byte body must be stripped.")
    }

    // MARK: - Non-ASCII / emoji prefix (must NEVER strip)

    /// A real message that starts with an emoji must not be touched. Emoji
    /// scalars are all above 0x7E, so they never qualify as length-prefix
    /// candidates — even if the rest of the body coincidentally matched.
    func testStrip_emojiNotStripped() {
        // 🎉 is U+1F389. 4 UTF-8 bytes (F0 9F 8E 89). Way above 0x7E.
        // Body byte length is irrelevant — the rule short-circuits on the
        // printable-ASCII check.
        let bodies = [
            "🎉 party time",
            "👋 hi",
            "❤️ love this",
            "🤓",  // single-emoji message
        ]
        for body in bodies {
            XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(body), body,
                           "Emoji-led body must be preserved verbatim: \(body)")
        }

        // Also try the worst case: emoji scalar followed by content whose
        // byte length coincidentally happens to be small — still no-op.
        let mixed = "🎂cake"  // 4-byte emoji + 4-byte word = body bytes irrelevant
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(mixed), mixed)
    }

    /// Non-ASCII Latin-1 (accented chars above 0x7E) also must not strip,
    /// even with byte counts that look "right".
    func testStrip_accentedLeadingCharNotStripped() {
        // 'é' is U+00E9 = 0xC3 0xA9 in UTF-8. Its scalar value is 0xE9
        // which is above the 0x7E ceiling, so the length-prefix rule must
        // never fire on it.
        let run = "épicé"
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(run), run,
                       "Above-ASCII scalar must not be considered a length prefix.")
    }

    // MARK: - Length mismatch (must preserve real content)

    /// The classic preservation cases from the (lead's) original change-log
    /// entry — these messages legitimately start with the listed char and
    /// the rest of the body is NOT the byte-length the rule would require.
    func testStrip_lengthMismatchPreserved() {
        let cases: [(input: String, why: String)] = [
            // '1' = 49, rest "st place" = 8 bytes. Mismatch → keep.
            ("1st place", "'1' (49) vs rest 8 bytes — preserve"),
            // '2' = 50, rest " hours" = 6 bytes. Mismatch → keep.
            ("2 hours", "'2' (50) vs rest 6 bytes — preserve"),
            // '$' = 36, rest "5 each" = 6 bytes. Mismatch → keep.
            ("$5 each", "'$' (36) vs rest 6 bytes — preserve"),
            // 'H' = 72, rest "ello there" = 10 bytes. Mismatch → keep.
            ("Hello there", "'H' (72) vs rest 10 bytes — preserve"),
            // 'A' = 65, rest " is the first letter." = 21 bytes. Mismatch → keep.
            ("A is the first letter.", "'A' (65) vs rest 21 bytes — preserve"),
        ]
        for (input, why) in cases {
            XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(input), input,
                           "Length mismatch must preserve: \(why)")
        }
    }

    /// Edge cases — empty and single-char.
    func testStrip_edgeCases() {
        // Empty → unchanged.
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix(""), "")

        // Single ASCII char — rest is 0 bytes. Strip iff first char's
        // value is 0 (impossible since 0 isn't printable ASCII). So
        // single chars are always preserved. (Note: chars whose byte
        // value is 0 wouldn't be printable, so the guard would skip them
        // anyway.)
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix("a"), "a",
                       "Single ASCII char preserved (rest is 0 bytes, doesn't match value).")

        // A char whose value happens to be 0 (NUL) can't appear in a
        // printable run, but for completeness:
        XCTAssertEqual(AttributedBodyDecoder.stripLengthPrefix("\u{00}"), "\u{00}",
                       "NUL byte preserved — outside printable-ASCII range.")
    }

    // MARK: - End-to-end through decode(_:) with synthetic blob

    /// Synthesize a blob that mimics the real-chat.db layout for a message
    /// of byte length 50 ('2' as the length prefix). After full decode the
    /// returned body must be clean (no leading '2').
    ///
    /// Layout (mirrors Tests/Fixtures/build_fixture_chat_db.sh):
    ///   04 0b           magic
    ///   "streamtyped"   ASCII run (11 chars, broken by next non-printable)
    ///   81 e8 03 84 01  framing
    ///   12              len=18 for "NSString"
    ///   "NSString"      class-name run (8 chars)
    ///   00 84 84 08     framing
    ///   32              len=50 for body
    ///   <50 byte body>  body
    ///   86 84 02 ...    trailing framing
    func testDecode_endToEndSyntheticBlob_digit() {
        let body = String(repeating: "x", count: 50)  // 50 'x' bytes
        XCTAssertEqual(body.utf8.count, 50)

        var blob = Data([0x04, 0x0b])
        blob.append("streamtyped".data(using: .ascii)!)
        blob.append(contentsOf: [0x81, 0xe8, 0x03, 0x84, 0x01])
        blob.append(0x40)  // '@' framing sigil
        blob.append(contentsOf: [0x84, 0x84, 0x84])
        blob.append(0x12)  // length 18 for NSString
        blob.append("NSString".data(using: .ascii)!)
        blob.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
        blob.append(0x32)  // length 50 for body
        blob.append(body.data(using: .ascii)!)
        blob.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x86, 0x84, 0x00])

        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, body,
                       "End-to-end decode of digit-prefixed blob must return the body, not '2' + body. Got: \(decoded)")
    }

    /// Same as the digit case but with a letter prefix ('A' = 65, 65-byte body).
    /// Locks in the broadened behavior at the decode() entry point.
    func testDecode_endToEndSyntheticBlob_letter() {
        let body = String(repeating: "y", count: 65)
        XCTAssertEqual(body.utf8.count, 65)

        var blob = Data([0x04, 0x0b])
        blob.append("streamtyped".data(using: .ascii)!)
        blob.append(contentsOf: [0x81, 0xe8, 0x03, 0x84, 0x01])
        blob.append(0x40)
        blob.append(contentsOf: [0x84, 0x84, 0x84])
        blob.append(0x12)
        blob.append("NSString".data(using: .ascii)!)
        blob.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
        blob.append(0x41)  // 'A' = 65 length prefix
        blob.append(body.data(using: .ascii)!)
        blob.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x86, 0x84, 0x00])

        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, body,
                       "End-to-end decode of letter-prefixed blob must return the body, not 'A' + body. Got: \(decoded)")
    }

    // MARK: - Bare canonical UUID (attachment.guid leak through __kIMFileTransferGUID)

    /// A run that is EXACTLY a canonical UUID (8-4-4-4-12 hex with hyphens,
    /// 36 chars total) must be filtered. Comes from attachment-only messages
    /// whose attributedBody embeds the attachment.guid next to
    /// `__kIMFileTransferGUIDAttributeName`. See docs/decoder-uuid-leak.md.
    func testLooksLikeMetadata_canonicalUUID() {
        // Real UUID from the user's chat.db that triggered this fix.
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("6063E5D5-08EF-4993-BF5E-DA7C7DC723F7"),
                      "Canonical uppercase UUID must be flagged as metadata.")

        // A few more arbitrary canonical UUIDs for breadth.
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("DEADBEEF-1234-5678-9ABC-DEF012345678"))
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("00000000-0000-0000-0000-000000000000"),
                      "All-zero canonical UUID must still be flagged.")
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    }

    /// Lowercase / mixed-case hex must also be filtered — UUIDs come both
    /// ways in practice and the check should be case-insensitive.
    func testLooksLikeMetadata_uuidLowercase() {
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("6063e5d5-08ef-4993-bf5e-da7c7dc723f7"),
                      "Canonical lowercase UUID must be filtered.")
        XCTAssertTrue(AttributedBodyDecoder.looksLikeMetadata("6063e5D5-08Ef-4993-bF5e-Da7c7DC723f7"),
                      "Canonical mixed-case UUID must be filtered.")
    }

    /// A UUID embedded inside a sentence must NOT match — the rule is strict
    /// equality, so any surrounding text makes the run longer than 36 chars
    /// and the check is a no-op. Real user content that mentions a UUID stays.
    func testLooksLikeMetadata_uuidEmbeddedInText_preserved() {
        let bodies = [
            "the GUID is 6063E5D5-08EF-4993-BF5E-DA7C7DC723F7",
            "6063E5D5-08EF-4993-BF5E-DA7C7DC723F7 is the attachment id",
            "see 6063E5D5-08EF-4993-BF5E-DA7C7DC723F7 for details",
            "id=6063E5D5-08EF-4993-BF5E-DA7C7DC723F7",
            // Leading/trailing whitespace — also longer than 36 chars,
            // also preserved.
            "  6063E5D5-08EF-4993-BF5E-DA7C7DC723F7  ",
        ]
        for body in bodies {
            XCTAssertFalse(AttributedBodyDecoder.looksLikeMetadata(body),
                           "UUID embedded in text must be preserved: \(body)")
        }
    }

    /// Strings that resemble a UUID but aren't the EXACT canonical form
    /// must NOT match. Catches: missing hyphens, wrong segment lengths,
    /// non-hex digits, total-length deviations, wrong delimiters.
    func testLooksLikeMetadata_almostUUID_notFiltered() {
        let cases: [(String, String)] = [
            // Missing all hyphens — wrong length but otherwise looks UUID-ish.
            ("6063E5D508EF4993BF5EDA7C7DC723F7", "missing hyphens"),
            // Wrong segment lengths.
            ("6063E5D-08EF-4993-BF5E-DA7C7DC723F7", "first segment 7 chars"),
            ("6063E5D5-08E-4993-BF5E-DA7C7DC723F7", "second segment 3 chars"),
            // Extra/missing character at end.
            ("6063E5D5-08EF-4993-BF5E-DA7C7DC723F70", "37 chars"),
            ("6063E5D5-08EF-4993-BF5E-DA7C7DC723F", "35 chars"),
            // Non-hex char (G is not 0-9/a-f/A-F).
            ("6063E5D5-08EF-4993-BF5E-DA7C7DC723FG", "non-hex G in last segment"),
            ("ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ", "all non-hex (Z)"),
            // Hyphens in wrong positions.
            ("60-63E5D5-8EF-4993-BF5E-DA7C7DC723F7", "hyphen shifted"),
            ("6063E5D5_08EF_4993_BF5E_DA7C7DC723F7", "underscores instead of hyphens"),
            // Empty / very short.
            ("", "empty"),
            ("uuid", "short"),
        ]
        for (input, why) in cases {
            XCTAssertFalse(AttributedBodyDecoder.looksLikeMetadata(input),
                           "Near-UUID must NOT be filtered (\(why)): \(input)")
        }
    }

    /// End-to-end: the real-world failure mode is a video/attachment-only
    /// message whose decoded longest run is a bare UUID. Fixture row 202
    /// (see Tests/Fixtures/build_fixture_chat_db.sh) mirrors this shape.
    /// After the fix, decode(_:) returns an empty string so the
    /// SpotlightResultRow type-placeholder ("Video" with the camera icon)
    /// kicks in.
    func testDecode_realFixture_videoMessageWithUUIDBody() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        let db = try ChatDatabase(url: url)

        let blob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 202")
        }
        guard let blob else {
            return XCTFail("Fixture row 202 missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
        }

        // The blob's longest printable run after framing trim is exactly
        // 'DEADBEEF-1234-5678-9ABC-DEF012345678' — a canonical UUID.
        // Pre-fix this returned the bare UUID. Post-fix it must return "".
        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, "",
                       "Attachment-only message whose only surviving run is a bare canonical UUID must decode to empty so the type-placeholder shows. Got: \(decoded)")
    }

    // MARK: - U+FFFC (object replacement char / inline attachment marker)
    //
    // NSAttributedString uses U+FFFC as the inline-attachment placeholder
    // scalar — every image, video, audio, file, sticker, link preview,
    // Apple Pay card, location card, GamePigeon game, handwriting, etc.
    // embedded in a message's attributedBody is represented by exactly
    // one U+FFFC scalar in the typedstream NSString payload. The decoder
    // MUST treat U+FFFC as a run separator (like U+FFFD) so attachment-
    // only messages decode to an empty string. Otherwise the
    // SpotlightResultRow's `body.isEmpty && messageType != .text` guard
    // fails, the type-label placeholder ("Image" / "Video" / "Audio" /
    // "File" / "Sticker" / "Link" / "Apple Pay" / "Location" / …)
    // never renders, and the row appears blank.
    //
    // The bug these tests guard against: a blob containing only U+FFFC
    // markers (and the usual typedstream framing) being decoded as
    // "￼" or "￼￼" instead of "".
    //
    // Because the bug lives entirely in the decoder, and the decoder
    // is downstream-agnostic, fixing it here covers EVERY MessageType
    // case at once — image/video/audio/file/sticker/link/applePay/
    // location/other. The attachment type only changes the rendered
    // placeholder label (resolved by AttachmentLoader from
    // attachment.mime_type), not whether the placeholder shows at all.

    /// `printableRuns(in:)` must split on U+FFFC just like it does on
    /// U+FFFD. A bare scalar (or a sequence of bare scalars) must produce
    /// zero output runs at any minimumLength.
    func testPrintableRuns_splitsOnObjectReplacementChar() {
        // Single U+FFFC — no runs at minLen 1 or 2.
        XCTAssertEqual(AttributedBodyDecoder.printableRuns(in: "\u{FFFC}", minimumLength: 1), [],
                       "Bare U+FFFC must produce no printable runs.")
        XCTAssertEqual(AttributedBodyDecoder.printableRuns(in: "\u{FFFC}", minimumLength: 2), [],
                       "Bare U+FFFC must produce no printable runs (minLen 2).")

        // Repeated U+FFFC — common shape for multi-attachment messages
        // (3 photos = 3 markers in the typedstream NSString).
        XCTAssertEqual(AttributedBodyDecoder.printableRuns(in: "\u{FFFC}\u{FFFC}\u{FFFC}\u{FFFC}", minimumLength: 1), [],
                       "Four consecutive U+FFFC must produce no printable runs.")

        // Mixed text + U+FFFC: text segments either side of the marker
        // come out as separate runs.
        XCTAssertEqual(
            AttributedBodyDecoder.printableRuns(in: "left\u{FFFC}right", minimumLength: 2),
            ["left", "right"],
            "U+FFFC must act as a run separator between text segments.")

        XCTAssertEqual(
            AttributedBodyDecoder.printableRuns(in: "first\u{FFFC}\u{FFFC}second\u{FFFC}third", minimumLength: 2),
            ["first", "second", "third"],
            "Multiple consecutive U+FFFC must still cleanly split text into three runs.")
    }

    /// Helper: build a `Data` by repeating a byte pattern N times. Used
    /// to synthesize multi-attachment bodies (N× U+FFFC = N×3 bytes).
    private func repeatedBytes(_ pattern: [UInt8], times: Int) -> Data {
        var d = Data()
        d.reserveCapacity(pattern.count * times)
        for _ in 0..<times { d.append(contentsOf: pattern) }
        return d
    }

    /// Helper: synthesize an attributedBody-like blob whose payload is
    /// exactly `bodyUTF8` bytes, with the standard typedstream framing.
    /// Returns the assembled `Data`.
    ///
    /// Mirrors the shape used by the digit/letter/UUID synthetic-blob
    /// tests above. The caller passes the raw body bytes (no length
    /// prefix — this helper writes the length byte).
    ///
    /// The length byte is the body's UTF-8 byte count (modulo 256).
    /// For attachment markers (U+FFFC is 3 bytes), 1 marker → 3,
    /// 2 markers → 6, 3 markers → 9 — all non-printable ASCII control
    /// chars, so our run-splitter cleanly breaks at the length byte and
    /// the run-rest contains only the U+FFFC scalars.
    private func makeAttribBlob(bodyUTF8: Data) -> Data {
        var blob = Data([0x04, 0x0b])
        blob.append("streamtyped".data(using: .ascii)!)
        blob.append(contentsOf: [0x81, 0xe8, 0x03, 0x84, 0x01])
        blob.append(0x40)
        blob.append(contentsOf: [0x84, 0x84, 0x84])
        blob.append(0x12)
        blob.append("NSString".data(using: .ascii)!)
        blob.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
        // Length byte: low 8 bits of body byte count. For bodies > 255
        // real typedstream uses a 2-byte length, but all our test bodies
        // are < 255 bytes so this single-byte form is fine.
        precondition(bodyUTF8.count < 256, "Test helper only supports <256-byte bodies.")
        blob.append(UInt8(bodyUTF8.count))
        blob.append(bodyUTF8)
        blob.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x86, 0x84, 0x00])
        return blob
    }

    /// End-to-end through `decode(_:)`: a blob whose body is a single
    /// U+FFFC marker (the canonical shape for a 1-attachment, no-caption
    /// message — image-only, video-only, audio-only, etc.) MUST decode to
    /// the empty string.
    func testDecode_singleAttachmentMarker_returnsEmpty() {
        // U+FFFC in UTF-8 = EF BF BC (3 bytes).
        let body = Data([0xef, 0xbf, 0xbc])
        let blob = makeAttribBlob(bodyUTF8: body)
        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, "",
                       "Attachment-only blob (1× U+FFFC) must decode to empty so the type-label placeholder fires. Got scalars: \(decoded.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
    }

    /// Multi-attachment messages: the typedstream NSString payload
    /// contains one U+FFFC scalar per attachment. Real users routinely
    /// send 2/3/4+ photos in a single message. Each of these shapes
    /// MUST decode to empty.
    func testDecode_multipleAttachmentMarkers_returnsEmpty() {
        // 2× U+FFFC = 6 UTF-8 bytes.
        let two = Data([0xef, 0xbf, 0xbc, 0xef, 0xbf, 0xbc])
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: two)), "",
                       "2× U+FFFC body (2-photo message) must decode to empty.")

        // 3× U+FFFC = 9 UTF-8 bytes.
        let three = Data([0xef, 0xbf, 0xbc, 0xef, 0xbf, 0xbc, 0xef, 0xbf, 0xbc])
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: three)), "",
                       "3× U+FFFC body (3-photo message) must decode to empty.")

        // 8× U+FFFC = 24 UTF-8 bytes — the practical upper end of a
        // single multi-attachment message.
        let eight = repeatedBytes([0xef, 0xbf, 0xbc], times: 8)
        XCTAssertEqual(AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: eight)), "",
                       "8× U+FFFC body (large multi-attachment message) must decode to empty.")
    }

    /// A message with a real text caption AND an inline attachment marker
    /// — e.g. `"check this out ￼"` — must decode to the caption text
    /// alone. The U+FFFC marker must NEVER appear in the decoded body.
    func testDecode_textWithAttachmentMarker_decodedBodyExcludesMarker() {
        let marker = Data([0xef, 0xbf, 0xbc])

        // Caption-then-marker: "look at this " (13 bytes) + U+FFFC (3 bytes) = 16 bytes.
        var captionThenMarker = Data("look at this ".utf8)
        captionThenMarker.append(marker)
        XCTAssertEqual(captionThenMarker.count, 16, "Sanity-check body length.")
        let decoded1 = AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: captionThenMarker))
        XCTAssertFalse(decoded1.unicodeScalars.contains(where: { $0.value == 0xFFFC }),
                       "Decoded body must never contain U+FFFC. Got: \(decoded1.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        XCTAssertFalse(decoded1.isEmpty,
                       "Decoded body must keep the caption text. Got empty.")
        XCTAssertTrue(decoded1.contains("look at this"),
                      "Decoded body must contain the caption text. Got: \(decoded1)")

        // Marker-then-caption: "￼ check it out" — opposite ordering.
        var markerThenCaption = Data()
        markerThenCaption.append(marker)
        markerThenCaption.append(Data(" check it out".utf8))
        let decoded2 = AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: markerThenCaption))
        XCTAssertFalse(decoded2.unicodeScalars.contains(where: { $0.value == 0xFFFC }),
                       "Decoded body must never contain U+FFFC (marker-first ordering). Got: \(decoded2.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        XCTAssertTrue(decoded2.contains("check it out"),
                      "Decoded body must contain the caption text. Got: \(decoded2)")

        // Sandwiched: text-marker-text-marker-text. The longest text run wins,
        // and the marker never leaks. Common for messages like
        // "before ￼ middle ￼ after".
        var sandwich = Data("before ".utf8)
        sandwich.append(marker)
        sandwich.append(Data(" the longest middle segment in the whole body ".utf8))
        sandwich.append(marker)
        sandwich.append(Data(" end".utf8))
        let decoded3 = AttributedBodyDecoder.decode(makeAttribBlob(bodyUTF8: sandwich))
        XCTAssertFalse(decoded3.unicodeScalars.contains(where: { $0.value == 0xFFFC }),
                       "Decoded body must never contain U+FFFC (sandwich ordering). Got: \(decoded3.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        XCTAssertTrue(decoded3.contains("longest middle segment"),
                      "Decoded body must be the longest text run (the middle). Got: \(decoded3)")
    }

    /// Direct probe of the public `printableRuns` against a blob-decoded
    /// string that contains only attachment markers — confirms the
    /// `decode(_:)` empty-string outcome propagates from the
    /// printable-runs level (not just from later metadata filtering).
    func testPrintableRuns_attachmentOnlyDecodedString_isEmpty() {
        // Simulate what `decode()` sees after lossy UTF-8 of an
        // attachment-only blob: the U+FFFC chars are intact, surrounded
        // by U+FFFD replacements for invalid framing bytes.
        let decoded = "\u{FFFD}\u{FFFD}\u{FFFC}\u{FFFC}\u{FFFD}"
        let runs = AttributedBodyDecoder.printableRuns(in: decoded, minimumLength: 1)
        XCTAssertEqual(runs, [],
                       "An attachment-marker-only decoded string must yield no printable runs.")
    }

    /// Regression guard: confirm that `isPrintable` via `printableRuns`
    /// distinguishes U+FFFC (filtered) from neighbouring BMP scalars
    /// (kept). Locks the boundary so a future tweak to the printable
    /// range can't quietly re-include U+FFFC.
    func testPrintableRuns_boundaryAroundObjectReplacementChar() {
        // U+FFFB (RIGHT-TO-LEFT EMBEDDING-related) — formerly the upper
        // bound when U+FFFC was included; must STILL be printable.
        let belowRun = AttributedBodyDecoder.printableRuns(in: "\u{FFFB}\u{FFFB}", minimumLength: 1)
        XCTAssertEqual(belowRun, ["\u{FFFB}\u{FFFB}"],
                       "U+FFFB (one below the marker) must remain a printable scalar.")

        // U+FFFC — filtered.
        let atRun = AttributedBodyDecoder.printableRuns(in: "\u{FFFC}", minimumLength: 1)
        XCTAssertEqual(atRun, [],
                       "U+FFFC must be filtered as non-printable.")

        // U+FFFD — already-filtered (lossy UTF-8 marker).
        let aboveRun = AttributedBodyDecoder.printableRuns(in: "\u{FFFD}", minimumLength: 1)
        XCTAssertEqual(aboveRun, [],
                       "U+FFFD must remain filtered.")
    }

    /// "Any attachment type" parameterized test — synthesizes the same
    /// U+FFFC-only attributedBody shape that EVERY attachment-only
    /// message produces (image, video, audio, file, sticker, link
    /// preview, Apple Pay, location, GamePigeon, handwriting, ...) and
    /// asserts decode is consistently empty across reasonable counts.
    ///
    /// The decoder is type-agnostic — `attachment.mime_type` is what
    /// AttachmentLoader uses to classify the resulting MessageType. So
    /// one empty-decode invariant here guards the placeholder-rendering
    /// invariant for every type at once.
    func testDecode_attachmentMarker_consistentEmptyForAllCounts() {
        for markerCount in 1...12 {
            let bytes = repeatedBytes([0xef, 0xbf, 0xbc], times: markerCount)
            let blob = makeAttribBlob(bodyUTF8: bytes)
            let decoded = AttributedBodyDecoder.decode(blob)
            XCTAssertEqual(decoded, "",
                           "Attachment-only body with \(markerCount) markers must decode to empty. Got: '\(decoded)' (scalars: \(decoded.unicodeScalars.map { String(format: "U+%04X", $0.value) }))")
        }
    }

    /// End-to-end fixture coverage for the U+FFFC bug, mirroring real
    /// attachment-only message shapes. Rows 203–205 are pure marker bodies
    /// (1/2/3 attachments); row 206 is a caption + marker. Post-fix, the
    /// marker-only rows decode to "" so the SpotlightResultRow type-label
    /// placeholder fires; the caption row decodes to the caption text
    /// without any U+FFFC scalar.
    ///
    /// The decoder is type-agnostic — `attachment.mime_type` (queried by
    /// AttachmentLoader) is what classifies the placeholder as Image vs
    /// Video vs Audio vs File vs Sticker vs Link Preview vs Apple Pay vs
    /// Location. Once decode returns "" here, the same UI path renders
    /// the correct type label for every MessageType case.
    func testDecode_realFixture_attachmentMarkerMessages() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        let db = try ChatDatabase(url: url)

        // Rows 203/204/205 — marker-only bodies, decode must be "".
        for (rowID, markerCount) in [(203, 1), (204, 2), (205, 3)] {
            let blob: Data? = try db.dbQueue.read { db in
                try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = ?", arguments: [rowID])
            }
            guard let blob else {
                XCTFail("Fixture row \(rowID) missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
                continue
            }
            let decoded = AttributedBodyDecoder.decode(blob)
            XCTAssertEqual(decoded, "",
                           "Fixture row \(rowID) (\(markerCount)× U+FFFC) must decode to empty for the type-label placeholder to fire. Got scalars: \(decoded.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        }

        // Row 206 — caption + marker. Decode must keep the caption text
        // and must NOT contain U+FFFC anywhere in the output.
        let captionBlob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 206")
        }
        guard let captionBlob else {
            return XCTFail("Fixture row 206 missing or attributedBody is NULL.")
        }
        let captionDecoded = AttributedBodyDecoder.decode(captionBlob)
        XCTAssertFalse(captionDecoded.unicodeScalars.contains(where: { $0.value == 0xFFFC }),
                       "Caption-plus-marker fixture (row 206) must not leak U+FFFC into the decoded body. Got scalars: \(captionDecoded.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
        XCTAssertTrue(captionDecoded.contains("look at this"),
                      "Caption-plus-marker fixture (row 206) must decode to the caption text. Got: \(captionDecoded)")
    }

    // MARK: - End-to-end via fixture chat.db (integration)

    /// Opens the bundled fixture chat.db, fetches the rows we added that
    /// exhibit the length-prefix bug (digit + letter prefixes), and
    /// asserts the decoded body comes out clean.
    func testStrip_realFixtureRow() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "chat", withExtension: "db") else {
            throw XCTSkip("chat.db fixture not in test bundle resources. Re-run Tests/Fixtures/build_fixture_chat_db.sh and rebuild.")
        }
        let db = try ChatDatabase(url: url)

        // Row 200 (digit-prefix): body byte len = 50, prefix byte = '2'.
        // Row 201 (letter-prefix): body byte len = 65, prefix byte = 'A'.
        // See Tests/Fixtures/build_fixture_chat_db.sh.

        let row200Blob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 200")
        }
        guard let blob200 = row200Blob else {
            return XCTFail("Fixture row 200 missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
        }
        let decoded200 = AttributedBodyDecoder.decode(blob200)
        XCTAssertFalse(decoded200.hasPrefix("2"),
                       "Digit-prefix fixture (row 200) must decode without a leading '2'. Got: \(decoded200)")
        XCTAssertEqual(decoded200.utf8.count, 50,
                       "Digit-prefix fixture body must be exactly 50 bytes. Got: \(decoded200.utf8.count) bytes; body=\(decoded200)")

        let row201Blob: Data? = try db.dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT attributedBody FROM message WHERE ROWID = 201")
        }
        guard let blob201 = row201Blob else {
            return XCTFail("Fixture row 201 missing or attributedBody is NULL. Re-run Tests/Fixtures/build_fixture_chat_db.sh.")
        }
        let decoded201 = AttributedBodyDecoder.decode(blob201)
        XCTAssertFalse(decoded201.hasPrefix("A"),
                       "Letter-prefix fixture (row 201) must decode without a leading 'A'. Got: \(decoded201)")
        XCTAssertEqual(decoded201.utf8.count, 65,
                       "Letter-prefix fixture body must be exactly 65 bytes. Got: \(decoded201.utf8.count) bytes; body=\(decoded201)")
    }
}
