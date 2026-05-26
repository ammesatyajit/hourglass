//
//  TypedstreamTests.swift
//  HourglassTests
//
//  Unit tests for the byte-level typedstream parser at
//  `Sources/Data/Typedstream.swift`. Covers:
//    - Header parsing: streamer version + signature + system version, both
//      endian variants and every error path (empty, truncated, wrong
//      version, wrong signature length, wrong magic bytes).
//    - Integer decoding: inline single-byte form vs TAG_INTEGER_2 vs
//      TAG_INTEGER_4. Signed and unsigned.
//    - String decoding: unshared (length-prefixed), shared (literal +
//      back-reference), edge cases (empty string, multi-byte length).
//    - Class chains: SingleClass + version + nil-terminated chain,
//      back-references to previously seen classes.
//    - Object decoding: BeginObject + class chain + fields +
//      EndOfObject, back-referenced objects.
//    - End-to-end: full minimal NSString blob round-trip.
//    - Type-encoding splitter: simple types, structs, arrays, modifier
//      prefixes.
//
//  Synthetic byte arrays are constructed and the parser is run against
//  them — no chat.db dependency. Should run in <100 ms.
//
//  Format references (read these before changing the parser):
//    - python-typedstream src/typedstream/stream.py (canonical reference)
//    - imessage-exporter src/util/streamtyped.rs (legacy fallback)
//

import XCTest
@testable import Hourglass

final class TypedstreamTests: XCTestCase {

    // MARK: - Test helpers

    /// Build the standard header bytes: streamer version 4, signature
    /// length 11, "streamtyped" (little-endian), system version 1000.
    private func makeHeader(systemVersion: Int = 1000) -> [UInt8] {
        var bytes: [UInt8] = [
            0x04,                                                // streamer version 4
            0x0b,                                                // signature length 11
        ]
        // "streamtyped" little-endian magic
        bytes.append(contentsOf: [0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64])
        // System version, encoded as TAG_INTEGER_2 + 2 LE bytes.
        bytes.append(0x81) // TAG_INTEGER_2
        bytes.append(UInt8(systemVersion & 0xff))
        bytes.append(UInt8((systemVersion >> 8) & 0xff))
        return bytes
    }

    /// Build the big-endian header variant. Used to test the byte-order
    /// detection.
    private func makeBigEndianHeader(systemVersion: Int = 1000) -> [UInt8] {
        var bytes: [UInt8] = [
            0x04,
            0x0b,
        ]
        // "typedstream" big-endian magic
        bytes.append(contentsOf: [0x74, 0x79, 0x70, 0x65, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d])
        // System version, BE encoding.
        bytes.append(0x81)
        bytes.append(UInt8((systemVersion >> 8) & 0xff))
        bytes.append(UInt8(systemVersion & 0xff))
        return bytes
    }

    // MARK: - Header parsing

    func testHeader_emptyBlob_throws() {
        XCTAssertThrowsError(try Typedstream.parse(Data())) { err in
            XCTAssertEqual(err as? TypedstreamError, .empty)
        }
    }

    func testHeader_unsupportedStreamerVersion() {
        // Streamer version 3 (old NeXTSTEP) — not supported.
        let bytes: [UInt8] = [0x03, 0x0b]
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            if case .unsupportedStreamerVersion(let v) = err as? TypedstreamError {
                XCTAssertEqual(v, 3)
            } else {
                XCTFail("Expected unsupportedStreamerVersion, got \(err)")
            }
        }
    }

    func testHeader_invalidSignatureLength() {
        let bytes: [UInt8] = [0x04, 0x05]  // length 5, not 11
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            if case .invalidSignatureLength(let len) = err as? TypedstreamError {
                XCTAssertEqual(len, 5)
            } else {
                XCTFail("Expected invalidSignatureLength, got \(err)")
            }
        }
    }

    func testHeader_invalidSignatureBytes() {
        var bytes: [UInt8] = [0x04, 0x0b]
        bytes.append(contentsOf: "garbageeeee".utf8)  // 11 bytes, wrong magic
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            if case .invalidSignature = err as? TypedstreamError {
                // success
            } else {
                XCTFail("Expected invalidSignature, got \(err)")
            }
        }
    }

    func testHeader_truncated() {
        // Just the version byte — header demands signature length next.
        let bytes: [UInt8] = [0x04]
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            // Could be either invalidSignatureLength or unexpectedEnd depending
            // on path; check it's one of the expected errors.
            switch err as? TypedstreamError {
            case .unexpectedEnd, .invalidSignatureLength: break
            default: XCTFail("Expected truncation error, got \(err)")
            }
        }
    }

    func testHeader_littleEndian_valid() throws {
        // Minimal valid blob: just the header. No values follow. parse()
        // should succeed with empty rootValues.
        let archive = try Typedstream.parse(Data(makeHeader()))
        XCTAssertEqual(archive.streamerVersion, 4)
        XCTAssertEqual(archive.systemVersion, 1000)
        XCTAssertFalse(archive.isBigEndian)
        XCTAssertEqual(archive.rootValues.count, 0)
    }

    func testHeader_bigEndian_valid() throws {
        let archive = try Typedstream.parse(Data(makeBigEndianHeader()))
        XCTAssertTrue(archive.isBigEndian)
        XCTAssertEqual(archive.systemVersion, 1000)
    }

    // MARK: - Integer decoding

    /// An NSNumber-like blob with one typed-value group containing an
    /// inline integer. We synthesize:
    ///   header
    ///   "i" type encoding (shared string NEW, length 1, byte 'i')
    ///   value: 42 (inline, fits in one signed byte)
    func testInteger_inlineSingleByte() throws {
        var bytes = makeHeader()
        // Typed-values group: encoding "i" (signed int) + value.
        bytes.append(0x84)              // TAG_NEW (literal shared string)
        bytes.append(0x01)              // length 1
        bytes.append(0x69)              // 'i'
        bytes.append(42)                // inline signed int
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues.count, 1)
        let group = archive.rootValues[0]
        XCTAssertEqual(group.encoding, "i")
        XCTAssertEqual(group.values, [.integer(42)])
    }

    func testInteger_inlineNegative() throws {
        var bytes = makeHeader()
        bytes.append(0x84)
        bytes.append(0x01)
        bytes.append(0x69)
        bytes.append(0xff)              // -1 in signed Int8
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.integer(-1)])
    }

    func testInteger_tag2_signed() throws {
        // Encode value 1000 as TAG_INTEGER_2 + LE u16.
        var bytes = makeHeader()
        bytes.append(0x84)
        bytes.append(0x01)
        bytes.append(0x69)
        bytes.append(0x81)              // TAG_INTEGER_2
        bytes.append(0xe8)              // low byte (1000 = 0x03e8)
        bytes.append(0x03)              // high byte
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.integer(1000)])
    }

    func testInteger_tag2_signedNegative() throws {
        // -1000 as TAG_INTEGER_2 + LE i16.
        var bytes = makeHeader()
        bytes.append(0x84)
        bytes.append(0x01)
        bytes.append(0x69)
        bytes.append(0x81)
        // -1000 = 0xFC18
        bytes.append(0x18)
        bytes.append(0xfc)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.integer(-1000)])
    }

    func testInteger_tag2_unsignedFitsButValueWouldBeNegativeSigned() throws {
        // Value 0xFFFF — fits in u16 but is -1 when interpreted signed.
        // We use encoding "S" (unsigned short) so the parser reads it
        // unsigned.
        var bytes = makeHeader()
        bytes.append(0x84)
        bytes.append(0x01)
        bytes.append(0x53)              // 'S'
        bytes.append(0x81)
        bytes.append(0xff)
        bytes.append(0xff)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.integer(65535)])
    }

    func testInteger_tag4_large() throws {
        // Value 100_000 (doesn't fit in 16 bits — needs TAG_INTEGER_4).
        var bytes = makeHeader()
        bytes.append(0x84)
        bytes.append(0x01)
        bytes.append(0x69)
        bytes.append(0x82)              // TAG_INTEGER_4
        // 100_000 = 0x000186A0, LE: A0 86 01 00
        bytes.append(0xa0)
        bytes.append(0x86)
        bytes.append(0x01)
        bytes.append(0x00)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.integer(100_000)])
    }

    // MARK: - String decoding (unshared / "+")

    /// "+" encoding = unshared string. After lossy UTF-8 it's exactly the
    /// expected text.
    func testString_simpleAscii() throws {
        var bytes = makeHeader()
        // Encoding shared string "+" (length 1).
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b) // '+'
        // Value: length-prefixed bytes. "hello" = 5 bytes.
        bytes.append(0x05)
        bytes.append(contentsOf: "hello".utf8)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.string("hello")])
    }

    func testString_emptyString() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x00)  // length 0
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.string("")])
    }

    func testString_longString_triggersMultiByteLength() throws {
        // 300-byte string — length 300 doesn't fit in a single signed byte
        // and isn't 0x7F or below as unsigned either. Needs TAG_INTEGER_2.
        let body = String(repeating: "a", count: 300)
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x81)              // TAG_INTEGER_2 for length
        bytes.append(0x2c)              // 300 = 0x012c LE
        bytes.append(0x01)
        bytes.append(contentsOf: body.utf8)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.string(body)])
    }

    func testString_lengthExactly127_singleByte() throws {
        // Length 127 is the largest value that fits in a signed Int8 inline
        // (max non-tag value is 127). 128 would be ambiguous but actually
        // it's not in the tag range (-128 to -111 are tags), so 128 as
        // unsigned is OK too — but the inline form for length reads it
        // signed-first then masks to unsigned. Test 127 + verify the
        // string survives.
        let body = String(repeating: "x", count: 127)
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x7f)              // 127
        bytes.append(contentsOf: body.utf8)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.string(body)])
    }

    func testString_unicode_multibyteUTF8() throws {
        // String with emoji (4-byte UTF-8 char) — length is the byte count,
        // not the character count.
        let body = "hi 👋"  // h(1) + i(1) + space(1) + emoji(4) = 7 bytes
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        let bodyBytes = Array(body.utf8)
        XCTAssertEqual(bodyBytes.count, 7)
        bytes.append(UInt8(bodyBytes.count))
        bytes.append(contentsOf: bodyBytes)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues[0].values, [.string(body)])
    }

    func testString_truncated_throws() {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x10)  // claims 16 bytes
        bytes.append(contentsOf: "only-five".utf8)  // 9 bytes, less than claimed
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            if case .unexpectedEnd = err as? TypedstreamError {
                // success
            } else {
                XCTFail("Expected unexpectedEnd, got \(err)")
            }
        }
    }

    // MARK: - Shared string backref

    /// Encode two consecutive typed-value groups with the SAME encoding
    /// string. The first stores it literally; the second should be a
    /// back-reference.
    func testSharedString_backreferenceSecondGroup() throws {
        var bytes = makeHeader()
        // First group: encoding "+", value "ab".
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x02); bytes.append(0x61); bytes.append(0x62)
        // Second group: encoding should be a back-reference to "+" (index 0,
        // which is reference number -110 = 0x92).
        // Reference 0 in the shared-string table corresponds to encoded
        // refnum -110 = 0x92 (== -110 + (-110)? no, _decode_reference_number
        // is `encoded - _FIRST_REFERENCE_NUMBER` and _FIRST_REFERENCE_NUMBER
        // = -110, so encoded == 0 + -110 = -110 = signed byte 0x92).
        bytes.append(0x92)  // refnum -110, decodes to table index 0
        bytes.append(0x03); bytes.append(0x63); bytes.append(0x64); bytes.append(0x65)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues.count, 2)
        XCTAssertEqual(archive.rootValues[0].encoding, "+")
        XCTAssertEqual(archive.rootValues[1].encoding, "+")
        XCTAssertEqual(archive.rootValues[0].values, [.string("ab")])
        XCTAssertEqual(archive.rootValues[1].values, [.string("cde")])
    }

    func testSharedString_invalidBackref_throws() {
        var bytes = makeHeader()
        // Try to back-reference table index 0 before anything has been
        // appended. Should throw.
        bytes.append(0x92)  // refnum -110 → idx 0
        XCTAssertThrowsError(try Typedstream.parse(Data(bytes))) { err in
            switch err as? TypedstreamError {
            case .invalidBackReference: break
            default: XCTFail("Expected invalidBackReference, got \(err)")
            }
        }
    }

    // MARK: - Objects + classes (the load-bearing case)

    /// Build a minimal NSString object blob and confirm we extract the
    /// string. This is the most important end-to-end test — every chat.db
    /// blob is some variant of this.
    ///
    /// Layout:
    ///   header
    ///   encoding "@" (shared string NEW, length 1, '@')
    ///   value: NEW object
    ///     class chain: NEW class "NSString" v1, NIL terminator
    ///     field group: encoding "+" (shared string NEW, length 1)
    ///       value: length-prefixed string "hello world"
    ///     END_OF_OBJECT
    func testObject_simpleNSString() throws {
        var bytes = makeHeader()
        // Encoding "@" (one object).
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)  // '@'
        // Begin object.
        bytes.append(0x84)              // TAG_NEW (object begin)
        // Class chain: NEW SingleClass
        bytes.append(0x84)              // TAG_NEW (class)
        // class name: shared string NEW + length 8 + "NSString"
        bytes.append(0x84); bytes.append(0x08)
        bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)              // class version 1 (inline signed int)
        // End of class chain — NIL
        bytes.append(0x85)              // TAG_NIL
        // Field group: encoding "+" + length-prefixed string.
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)  // '+'
        bytes.append(0x0b)              // length 11
        bytes.append(contentsOf: "hello world".utf8)
        // END_OF_OBJECT
        bytes.append(0x86)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues.count, 1)
        guard case .object(let obj) = archive.rootValues[0].values[0] else {
            return XCTFail("Expected object, got \(archive.rootValues[0].values[0])")
        }
        XCTAssertEqual(obj.className, "NSString")
        XCTAssertEqual(obj.classChain[0].version, 1)
        XCTAssertEqual(obj.fields.count, 1)
        XCTAssertEqual(obj.fields[0].values, [.string("hello world")])

        // Extract via the convenience helper.
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "hello world")
    }

    /// Same as above but a Mutable variant.
    func testObject_NSMutableString() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x0f)
        bytes.append(contentsOf: "NSMutableString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x04)
        bytes.append(contentsOf: "mute".utf8)
        bytes.append(0x86)
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "mute")
    }

    /// Object with a class chain: NSMutableString → NSString → NSObject,
    /// ending with NIL.
    func testObject_classChainWithParents() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        // class chain: NEW NSMutableString v1, NEW NSString v1, NEW NSObject v0, NIL
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x0f); bytes.append(contentsOf: "NSMutableString".utf8)
        bytes.append(0x01)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSObject".utf8)
        bytes.append(0x00)
        bytes.append(0x85)
        // Body
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x03); bytes.append(contentsOf: "abc".utf8)
        bytes.append(0x86)
        let archive = try Typedstream.parse(Data(bytes))
        guard case .object(let obj) = archive.rootValues[0].values[0] else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(obj.classChain.count, 3)
        XCTAssertEqual(obj.classChain.map(\.name),
                       ["NSMutableString", "NSString", "NSObject"])
        XCTAssertEqual(obj.classChain.map(\.version), [1, 1, 0])
    }

    /// Sanity: empty string inside an NSString object.
    func testObject_NSString_emptyBody() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x00)  // length 0
        bytes.append(0x86)
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "")
    }

    /// String with embedded NUL bytes — the format allows them; we should
    /// pass them through.
    func testObject_NSString_embeddedNul() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x05)  // length 5
        bytes.append(contentsOf: [0x61, 0x00, 0x62, 0x00, 0x63])  // "a\0b\0c"
        bytes.append(0x86)
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "a\u{00}b\u{00}c")
    }

    /// String containing U+FFFC (attachment marker) — the parser should
    /// pass the raw bytes through; the decoder's postprocess step strips
    /// markers for display.
    func testObject_NSString_attachmentMarkerPresent() throws {
        // "look ￼ here" — U+FFFC is 3 bytes EF BF BC.
        let body = "look \u{FFFC} here"
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        let bodyBytes = Array(body.utf8)
        bytes.append(UInt8(bodyBytes.count))
        bytes.append(contentsOf: bodyBytes)
        bytes.append(0x86)
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, body, "Parser preserves U+FFFC; decoder strips it later.")
    }

    /// Object back-reference: encode an object, then a second typed value
    /// that's a backref to the same object. python-typedstream registers
    /// each literal object so the second reference looks it up.
    func testObject_backreference() throws {
        var bytes = makeHeader()
        // First "@": literal NSString "foo".
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x03); bytes.append(contentsOf: "foo".utf8)
        bytes.append(0x86)
        // Second "@": backref to that object. Encoding is back-referenced
        // shared string "@" (index 0 = refnum -110 = 0x92).
        bytes.append(0x92)
        // Now the value: object backref. Object table index 0 = refnum
        // -110 = 0x92.
        bytes.append(0x92)
        let archive = try Typedstream.parse(Data(bytes))
        XCTAssertEqual(archive.rootValues.count, 2)
        // Both groups should yield the same NSString object.
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "foo")
    }

    // MARK: - NSAttributedString (the real case)

    /// Build a more realistic NSAttributedString-like blob: an
    /// NSAttributedString contains an inner NSString, then an
    /// NSDictionary of attribute runs. The extractor should find the
    /// inner string.
    ///
    /// We synthesize ONLY the NSString portion since modeling the full
    /// NSDictionary requires NSNumber sub-objects too — overkill for the
    /// parser test. The end-to-end fixture test in
    /// AttributedBodyDecoderTests covers the full shape.
    func testNSAttributedString_extractsInnerNSString() throws {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        // Begin NSAttributedString object.
        bytes.append(0x84)
        // Class chain: NSAttributedString v0, NSObject v0, NIL
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x12); bytes.append(contentsOf: "NSAttributedString".utf8)
        bytes.append(0x00)              // class version 0
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSObject".utf8)
        bytes.append(0x00)
        bytes.append(0x85)              // NIL terminator
        // First nested field: "@" → an inner NSString.
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x05); bytes.append(contentsOf: "Hello".utf8)
        bytes.append(0x86)
        // END_OF_OBJECT for the NSAttributedString itself.
        bytes.append(0x86)
        let extracted = try Typedstream.extractString(from: Data(bytes))
        XCTAssertEqual(extracted, "Hello")
    }

    // MARK: - End-to-end via AttributedBodyDecoder.decode

    /// Confirm AttributedBodyDecoder uses the typedstream parser for a
    /// real (compliant) blob.
    func testDecode_typedstreamPath_returnsCleanText() {
        var bytes = makeHeader()
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x40)
        bytes.append(0x84)
        bytes.append(0x84)
        bytes.append(0x84); bytes.append(0x08); bytes.append(contentsOf: "NSString".utf8)
        bytes.append(0x01)
        bytes.append(0x85)
        bytes.append(0x84); bytes.append(0x01); bytes.append(0x2b)
        bytes.append(0x32)              // length 50
        bytes.append(contentsOf: Array(repeating: UInt8(0x78), count: 50))  // 50 'x'
        bytes.append(0x86)
        let decoded = AttributedBodyDecoder.decode(Data(bytes))
        XCTAssertEqual(decoded, String(repeating: "x", count: 50),
                       "Compliant typedstream blob must decode via the parser, NOT leak a '2' prefix from the length byte.")
    }

    /// A blob that's NOT a valid typedstream (e.g. all zeros) must fall
    /// back to the heuristic decoder without throwing.
    func testDecode_fallbackOnInvalidBlob_doesNotCrash() {
        let blob = Data(repeating: 0x00, count: 200)
        // Should not throw — should return "" or a heuristic best-effort
        // string. The exact return value doesn't matter; the contract is
        // "no crash".
        let result = AttributedBodyDecoder.decode(blob)
        // No assertion on content — just that we got back a String.
        XCTAssertNotNil(result as String?)
    }

    /// A blob that LOOKS like a typedstream (correct header) but has a
    /// garbage body must throw cleanly (caught by `decode`) and fall back.
    func testDecode_fallbackOnPartialTypedstream() {
        var bytes = makeHeader()
        bytes.append(0xff)              // garbage head byte for first value
        bytes.append(0xff)
        bytes.append(0xff)
        let decoded = AttributedBodyDecoder.decode(Data(bytes))
        // Shouldn't crash; output is best-effort heuristic.
        XCTAssertNotNil(decoded as String?)
    }

    // MARK: - Type-encoding splitter

    func testSplitEncodings_simple() {
        XCTAssertEqual(splitEncodings("@"), ["@"])
        XCTAssertEqual(splitEncodings("@@i"), ["@", "@", "i"])
        XCTAssertEqual(splitEncodings("i"), ["i"])
        XCTAssertEqual(splitEncodings("c"), ["c"])
        XCTAssertEqual(splitEncodings(""), [])
    }

    func testSplitEncodings_struct() {
        XCTAssertEqual(splitEncodings("{NSPoint=ff}"), ["{NSPoint=ff}"])
        XCTAssertEqual(splitEncodings("{NSPoint=ff}@"), ["{NSPoint=ff}", "@"])
    }

    func testSplitEncodings_array() {
        XCTAssertEqual(splitEncodings("[5i]"), ["[5i]"])
        XCTAssertEqual(splitEncodings("[5i]@"), ["[5i]", "@"])
    }

    func testSplitEncodings_modifierPrefixes() {
        // Modifier prefixes ('r' for const, 'n' for inout, etc.) are
        // skipped silently.
        XCTAssertEqual(splitEncodings("r@"), ["@"])
        XCTAssertEqual(splitEncodings("ri"), ["i"])
    }

    func testParseArrayEncoding() {
        if let result = parseArrayEncoding("[5i]") {
            XCTAssertEqual(result.length, 5)
            XCTAssertEqual(result.elementEncoding, "i")
        } else {
            XCTFail("parseArrayEncoding failed")
        }
        if let result = parseArrayEncoding("[256C]") {
            XCTAssertEqual(result.length, 256)
            XCTAssertEqual(result.elementEncoding, "C")
        } else {
            XCTFail()
        }
        XCTAssertNil(parseArrayEncoding("[i]"))
        XCTAssertNil(parseArrayEncoding("not-an-array"))
    }

    func testParseStructEncoding() {
        if let result = parseStructEncoding("{NSPoint=ff}") {
            XCTAssertEqual(result.name, "NSPoint")
            XCTAssertEqual(result.fieldEncodings, ["f", "f"])
        } else {
            XCTFail()
        }
        if let result = parseStructEncoding("{?=ii}") {
            XCTAssertNil(result.name)
            XCTAssertEqual(result.fieldEncodings, ["i", "i"])
        } else {
            XCTFail()
        }
    }
}
