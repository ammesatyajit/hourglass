//
//  Typedstream.swift
//  Hourglass
//
//  Pure byte-level parser for the NeXTSTEP/Apple `typedstream` archive format —
//  the binary format used for `message.attributedBody` in chat.db.
//
//  WHY THIS EXISTS
//  ===============
//  `message.attributedBody` is an `NSArchiver`-encoded `NSAttributedString`.
//  `NSArchiver`/`NSUnarchiver` were deprecated in macOS 10.13 and removed
//  from Swift entirely; `NSKeyedUnarchiver` decodes a different format (binary
//  plist, not typedstream) and rejects these blobs outright. Foundation gives
//  us nothing to read these blobs with — we have to implement the parser
//  ourselves.
//
//  Prior to this file, the decoder used a heuristic: lossy-UTF-8-decode the
//  raw bytes, split on non-printable scalars, and return the longest run. That
//  approach has been the source of a steady drip of bugs:
//    - typedstream length prefixes that decode as ASCII chars get glued to the
//      front of the body ("2Looks like…", "?So none…", "DSatyajit Kanna…")
//    - typedstream-internal U+FFFC attachment markers appear as ￼ in display
//    - canonical UUIDs leak from `__kIMFileTransferGUIDAttributeName` values
//    - and many others — each one demanded a new heuristic patch.
//
//  Every one of those bugs has the same root cause: we're guessing at the
//  format instead of parsing it. This file solves them all at once.
//
//  FORMAT OVERVIEW
//  ===============
//  A typedstream is a sequence of *typed values* with a small fixed header.
//  Values are read by knowing their *type encoding* (an Objective-C runtime
//  type signature like `@`, `i`, `*`, `{NSRect=ff}`); the format does not
//  store types inline with each value but rather groups values under shared
//  type-encoding strings.
//
//  Header (5+ bytes):
//      [04]                  streamer version (always 4 in modern blobs)
//      [0b]                  signature length (always 11)
//      "streamtyped"         11 ASCII bytes — magic + little-endian signal
//                            (big-endian variant would be "typedstream")
//      <integer>             system version (typically 1000 = macOS)
//
//  After the header, the stream is a sequence of typed-value groups:
//      <shared-string>       the type-encoding string (e.g. "@", "i", "@@@")
//      <value>...            one value for each character in the encoding
//
//  Each value is read by the *head byte*: a signed byte that either
//  (a) literally encodes a small integer (when in [0x92, 0x7F] interpreted as
//      signed; i.e. -110..127 inclusive), or
//  (b) is a TAG indicating a structured read.
//
//  Tag constants (signed, in [-128, -111] = [0x80, 0x91]):
//      _TAG_INTEGER_2     = -127 / 0x81   integer follows in 2 bytes (LE)
//      _TAG_INTEGER_4     = -126 / 0x82   integer follows in 4 bytes (LE)
//      _TAG_FLOATING_POINT = -125 / 0x83  float/double follows (4 or 8 bytes)
//      _TAG_NEW           = -124 / 0x84   "new" literal — for strings,
//                                          classes, objects, c-strings.
//                                          Backref tables get appended.
//      _TAG_NIL           = -123 / 0x85   nil — for strings, classes, objects
//      _TAG_END_OF_OBJECT = -122 / 0x86   ends an object's contents
//
//  Reference numbers (back-references to earlier-seen shared strings or
//  objects) start at -110 (= 0x92, just past the last tag). The first
//  back-referenceable item gets number -110 (= zero-based index 0), the
//  second -109 (= 1), etc. A single-byte head can encode references 0..127
//  directly (signed range); larger refs use _TAG_INTEGER_2 / _TAG_INTEGER_4
//  to encode the reference number.
//
//  STRINGS
//  -------
//  Two kinds, distinguished by context:
//    - *Unshared* strings: head byte is the length (or a TAG_INTEGER_N for
//      lengths > 127). Followed by exactly that many raw bytes. Used for
//      class names, type encodings.
//    - *Shared* strings: head byte is either TAG_NEW (literal — read the
//      unshared form and append to the shared-string table) or a reference
//      number (look up in shared-string table). Used for shared/repeated
//      strings — type encodings, class names — which appear many times in
//      a typical blob.
//
//  OBJECTS
//  -------
//  Objects begin with a class definition and end with TAG_END_OF_OBJECT:
//      [84]                  begin object (NEW)
//      <class chain>         one or more SingleClass entries (each name +
//                            version int) terminated by NIL or backref —
//                            the chain represents the class + its parents
//      <field values>...     typed-value groups, each with their own
//                            shared-string type encoding
//      [86]                  END_OF_OBJECT
//
//  Each literal object is appended to the *object table* so future
//  references (in any object context) can point back to it.
//
//  NSSTRING IN PARTICULAR
//  ----------------------
//  An NSString object's body is encoded with one typed-value group:
//      encoding string: "+"  (the unshared NSString encoding)
//      value:           [length byte (or TAG_INTEGER_N)] [UTF-8 bytes...]
//
//  NSMutableString uses the same encoding. NSAttributedString contains an
//  NSString (its raw text) followed by an attribute-runs NSDictionary.
//
//  REFERENCES
//  ==========
//  Format spec drawn from:
//    - python-typedstream (dgelessus/python-typedstream, LGPL):
//      https://github.com/dgelessus/python-typedstream
//      Particularly src/typedstream/stream.py — the canonical Python
//      reference reader, well-commented.
//    - imessage-exporter (ReagentX/imessage-exporter, GPL):
//      https://github.com/ReagentX/imessage-exporter
//      Particularly imessage-database/src/util/streamtyped.rs (legacy fallback)
//      and the crabstep Rust crate it depends on for the real parser.
//    - Apple's archived NSArchiver headers (early Darwin sources).
//
//  THIS FILE IS PURE
//  =================
//  No I/O, no global state, no Foundation classes beyond `Data`, `String`,
//  and arithmetic. Easy to unit-test with synthetic byte arrays.
//

import Foundation

// MARK: - Public API

public enum Typedstream {

    /// Parse a typedstream blob into a sequence of `Object`s in encounter
    /// order. Most NSArchiver-archived NSAttributedString blobs produce
    /// exactly one root object (the NSAttributedString itself) with several
    /// nested objects (NSString, NSDictionary, NSNumber, etc.).
    ///
    /// - Parameter data: the raw typedstream bytes (e.g. the
    ///   `message.attributedBody` BLOB column).
    /// - Returns: a structured tree of values. Inspect `Archive.rootValues`
    ///   to access the top-level typed-value groups.
    /// - Throws: `TypedstreamError` if the data is not a valid typedstream.
    public static func parse(_ data: Data) throws -> Archive {
        var reader = TypedstreamReader(data: data)
        try reader.readHeader()
        var rootValues: [TypedValueGroup] = []
        while !reader.isAtEnd {
            // The top level is a sequence of typed-value groups. There's no
            // explicit end marker; we read until we run out of bytes.
            let group = try reader.readTypedValues()
            rootValues.append(group)
        }
        return Archive(
            streamerVersion: reader.streamerVersion,
            systemVersion: reader.systemVersion,
            isBigEndian: reader.isBigEndian,
            rootValues: rootValues
        )
    }

    /// Convenience: parse a typedstream blob expected to contain a single
    /// `NSAttributedString` (or `NSMutableAttributedString`) and return its
    /// underlying plain-text string.
    ///
    /// This is the entry point the `AttributedBodyDecoder` uses for the
    /// common case. Returns `nil` if the blob doesn't decode to one of the
    /// expected shapes (caller should fall back to the legacy decoder).
    ///
    /// - Throws: `TypedstreamError` if the blob is structurally invalid.
    ///   Returns `nil` (rather than throwing) only when the parse succeeds
    ///   but doesn't yield a recognized NSAttributedString shape — that's
    ///   a "wrong shape" condition, not a parse error.
    public static func extractString(from data: Data) throws -> String? {
        let archive = try parse(data)
        // Walk the root values; the first object found is the
        // NSAttributedString (or NSString — single-string archives also
        // occur). Walk into it and find the first NSString value.
        for group in archive.rootValues {
            for value in group.values {
                if let str = Self.findNSString(in: value) {
                    return str
                }
            }
        }
        return nil
    }

    /// True if `value` represents an `NSAttributedString` or
    /// `NSMutableAttributedString` whose underlying text is empty AND
    /// whose only character payloads are U+FFFC (attachment markers).
    /// Used to detect "attachment only" messages cleanly.
    static func findNSString(in value: TypedValue) -> String? {
        switch value {
        case .object(let obj):
            // Match NSAttributedString, NSMutableAttributedString, NSString,
            // NSMutableString — anything whose class chain starts with one of
            // these names.
            let cls = obj.className
            if cls == "NSString" || cls == "NSMutableString"
                || cls == "NSAttributedString" || cls == "NSMutableAttributedString" {
                // An NSString stores its content as a single typed-value
                // group with encoding "+". An NSAttributedString stores its
                // text first, then an NSDictionary of attribute runs — but
                // the text NSString is the FIRST nested object/value, so a
                // depth-first walk finds it.
                for field in obj.fields {
                    for v in field.values {
                        if let inner = findNSString(in: v) {
                            return inner
                        }
                    }
                }
                // No nested NSString found — but if THIS object is an
                // NSString-flavored one, we should have a raw-string field.
                for field in obj.fields {
                    for v in field.values {
                        if case .string(let s) = v {
                            return s
                        }
                    }
                }
            }
            // Not a string-shaped class — but recurse, since attributed
            // strings are sometimes wrapped in containers we don't know
            // about.
            for field in obj.fields {
                for v in field.values {
                    if let inner = findNSString(in: v) {
                        return inner
                    }
                }
            }
        case .string(let s):
            // Bare unshared string — shouldn't normally happen as a root
            // value, but if it does it IS the text.
            return s
        default:
            return nil
        }
        return nil
    }
}

// MARK: - Errors

public enum TypedstreamError: Error, CustomStringConvertible, Equatable {
    /// The blob is empty or too short to even contain a header.
    case empty
    /// Reading past the end of the data while consuming a value.
    case unexpectedEnd(needed: Int, remaining: Int)
    /// The streamer version byte is not in the supported range (we only
    /// support version 4 — the macOS / late-NeXTSTEP variant).
    case unsupportedStreamerVersion(UInt8)
    /// The signature length byte doesn't match the literal "streamtyped" /
    /// "typedstream" length (11).
    case invalidSignatureLength(UInt8)
    /// The signature bytes don't match either little-endian or big-endian
    /// expected magic.
    case invalidSignature(Data)
    /// A head byte was encountered in a context where it's not legal
    /// (e.g. TAG_FLOATING_POINT where an integer was expected).
    case invalidHeadTag(Int8, context: String)
    /// A back-reference points to a slot we never populated.
    case invalidBackReference(Int, tableSize: Int, context: String)
    /// We don't know how to decode this type-encoding character.
    case unsupportedTypeEncoding(String)
    /// A class name or shared string was encoded as `nil` in a context that
    /// demands a non-nil value (e.g. a class name in a class definition).
    case unexpectedNil(context: String)

    public var description: String {
        switch self {
        case .empty:
            return "typedstream: empty blob"
        case .unexpectedEnd(let needed, let remaining):
            return "typedstream: needed \(needed) bytes, only \(remaining) left"
        case .unsupportedStreamerVersion(let v):
            return "typedstream: unsupported streamer version \(v) (expected 4)"
        case .invalidSignatureLength(let len):
            return "typedstream: invalid signature length \(len) (expected 11)"
        case .invalidSignature(let sig):
            let asString = String(data: sig, encoding: .ascii) ?? sig.hexShort
            return "typedstream: invalid signature \(asString)"
        case .invalidHeadTag(let tag, let context):
            return "typedstream: invalid head tag \(tag) (0x\(String(UInt8(bitPattern: tag), radix: 16))) in context \(context)"
        case .invalidBackReference(let ref, let tableSize, let context):
            return "typedstream: invalid backref \(ref) into \(context) table of size \(tableSize)"
        case .unsupportedTypeEncoding(let enc):
            return "typedstream: unsupported type encoding \(enc)"
        case .unexpectedNil(let context):
            return "typedstream: unexpected nil in \(context)"
        }
    }
}

private extension Data {
    var hexShort: String {
        prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Output model

/// A parsed typedstream archive. Field names match python-typedstream's
/// terminology where possible.
public struct Archive: Equatable {
    public let streamerVersion: UInt8
    public let systemVersion: Int64
    public let isBigEndian: Bool
    public let rootValues: [TypedValueGroup]
}

/// A group of values sharing a single type-encoding string. Most groups
/// contain exactly one value (encoding length 1 — `@`, `i`, `*`); compound
/// archives can have multi-value groups (encoding length > 1 — `@@`, `i@`).
public struct TypedValueGroup: Equatable {
    public let encoding: String
    public let values: [TypedValue]
}

/// A single decoded value. The variant matches Objective-C's runtime type
/// system: integers, floats, strings, objects, etc.
///
/// Some Objective-C atomic types (boolean `B`, char `c`/`C`, struct/array
/// encodings) collapse into `.integer`, `.string`, `.byteArray`, etc.
/// We don't differentiate signed-vs-unsigned for storage — both go into
/// the same `.integer` case; the consumer can inspect the encoding if it
/// cares.
public indirect enum TypedValue: Equatable {
    /// A signed/unsigned integer (B, C, c, S, s, I, i, L, l, Q, q encoding).
    case integer(Int64)
    /// A 32-bit or 64-bit floating-point value (f, d).
    case float(Double)
    /// A nil object/class/string reference.
    case `nil`
    /// A primitive string — an unshared NSString-style byte sequence
    /// (encoding `+`). Decoded as UTF-8 with replacement on invalid bytes.
    case string(String)
    /// A C string (encoding `*`) — typically used for class names. Decoded
    /// as UTF-8 with replacement.
    case cString(String)
    /// An "atom" (encoding `%`) — a shared-string reference.
    case atom(String)
    /// A selector (encoding `:`) — a shared-string reference.
    case selector(String)
    /// A raw byte array (encoding `[NC]` / `[Nc]`).
    case byteArray(Data)
    /// A homogeneous array of values (encoding `[NX]` where X is not C or c).
    case array(elementEncoding: String, values: [TypedValue])
    /// A C struct (encoding `{name=fields}`).
    case `struct`(name: String?, fields: [TypedValue])
    /// An object (encoding `@` or `#`).
    case object(ParsedObject)
    /// A back-reference to a previously seen object (or class).
    /// We resolve these lazily — the index points into the object table
    /// produced by the parser; if the consumer wants the real object,
    /// look it up via `Archive.objectTable[index]`.
    case objectReference(index: Int, expectedKind: ReferenceKind)
}

/// Whether a backref points to an object, a class, or a c-string.
public enum ReferenceKind: Equatable, Sendable {
    case object, classRef, cString
}

/// A literally-encoded Objective-C object. `className` is the most-derived
/// class; `classChain` is the chain of class+version up to (but not
/// including) the root. `fields` are the typed-value groups encoded inside
/// the object body (one group per `encodeValueOfType:at:` / `encodeObject:`
/// call inside the class's `-encodeWithCoder:`).
public struct ParsedObject: Equatable {
    public struct ClassEntry: Equatable {
        public let name: String
        public let version: Int64
    }
    /// Name of the most-derived class. Equal to `classChain[0].name`.
    public var className: String { classChain.first?.name ?? "" }
    public let classChain: [ClassEntry]
    public let fields: [TypedValueGroup]
}

// MARK: - The reader (private — used through Typedstream.parse)

private struct TypedstreamReader {
    var data: Data
    var cursor: Int

    /// Header values, populated by `readHeader()`.
    var streamerVersion: UInt8 = 0
    var systemVersion: Int64 = 0
    var isBigEndian: Bool = false

    /// Shared-string back-reference table — populated by literal shared
    /// strings (type encodings, class names). Indexed by zero-based
    /// position in this list.
    var sharedStringTable: [String] = []

    /// **Unified** object-reference table. The typedstream format uses a
    /// single shared numbering space for c-strings, classes, AND objects
    /// — every literal of any of these types gets appended in encounter
    /// order, and back-references decode to an index into THIS table
    /// (not into per-type tables).
    ///
    /// The `kind` tag lets us validate that a back-reference is being
    /// used in a context that matches what was originally stored
    /// (e.g. an object-context backref must point to an Object entry,
    /// not a Class).
    ///
    /// Object entries are appended as PLACEHOLDERS *before* the object's
    /// class is read, then mutated in place when the object is finalized.
    /// This is required because the class chain itself adds entries to
    /// the table, and the object's stored index needs to come BEFORE
    /// its class entries.
    var objectTable: [ObjectTableEntry] = []

    enum ObjectTableEntry {
        case cString(String)
        case classChain([ParsedObject.ClassEntry])
        case object(ParsedObject)
        /// Placeholder: object index reserved but body not yet read.
        case objectPlaceholder
    }

    init(data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    var isAtEnd: Bool { cursor >= data.endIndex }

    var remaining: Int { data.endIndex - cursor }

    // MARK: Low-level byte reading

    /// Pop one byte, advancing the cursor. Throws if at end.
    mutating func readByte() throws -> UInt8 {
        guard cursor < data.endIndex else {
            throw TypedstreamError.unexpectedEnd(needed: 1, remaining: 0)
        }
        let b = data[cursor]
        cursor += 1
        return b
    }

    /// Pop `n` bytes as a Data slice (a copy — small, fine here).
    mutating func readBytes(_ n: Int) throws -> Data {
        guard remaining >= n else {
            throw TypedstreamError.unexpectedEnd(needed: n, remaining: remaining)
        }
        let slice = data.subdata(in: cursor..<(cursor + n))
        cursor += n
        return slice
    }

    /// Read a signed head byte. The head byte may be an inline integer (in
    /// signed range -110..127 inclusive) or a TAG_* indicator (in [-128, -111]).
    mutating func readHeadByte() throws -> Int8 {
        let raw = try readByte()
        return Int8(bitPattern: raw)
    }

    /// Read an integer value, given an already-read head byte.
    ///
    /// - If the head is itself an inline integer (outside the TAG range),
    ///   return it directly.
    /// - If the head is TAG_INTEGER_2, the next 2 bytes are a little-endian
    ///   (or big-endian, depending on byte order) integer.
    /// - Likewise TAG_INTEGER_4 → 4 bytes.
    /// - Any other tag → invalid.
    mutating func readInteger(head: Int8, signed: Bool) throws -> Int64 {
        switch head {
        case Tag.integer2:
            let bytes = try readBytes(2)
            return signed
                ? Int64(Int16(bitPattern: readU16(bytes)))
                : Int64(readU16(bytes))
        case Tag.integer4:
            let bytes = try readBytes(4)
            return signed
                ? Int64(Int32(bitPattern: readU32(bytes)))
                : Int64(readU32(bytes))
        default:
            // Inline integer.
            if !Tag.isTag(head) {
                if signed {
                    return Int64(head)
                } else {
                    // Unsigned single-byte: mask off sign bit interpretation.
                    return Int64(UInt8(bitPattern: head))
                }
            } else {
                throw TypedstreamError.invalidHeadTag(head, context: "integer")
            }
        }
    }

    /// Convenience: read an integer fresh from the stream.
    mutating func readInteger(signed: Bool) throws -> Int64 {
        let head = try readHeadByte()
        return try readInteger(head: head, signed: signed)
    }

    private func readU16(_ bytes: Data) -> UInt16 {
        let lo = bytes[bytes.startIndex]
        let hi = bytes[bytes.startIndex + 1]
        return isBigEndian
            ? (UInt16(lo) << 8) | UInt16(hi)
            : (UInt16(hi) << 8) | UInt16(lo)
    }

    private func readU32(_ bytes: Data) -> UInt32 {
        let b0 = UInt32(bytes[bytes.startIndex])
        let b1 = UInt32(bytes[bytes.startIndex + 1])
        let b2 = UInt32(bytes[bytes.startIndex + 2])
        let b3 = UInt32(bytes[bytes.startIndex + 3])
        return isBigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    private func readU64(_ bytes: Data) -> UInt64 {
        var v: UInt64 = 0
        if isBigEndian {
            for i in 0..<8 {
                v = (v << 8) | UInt64(bytes[bytes.startIndex + i])
            }
        } else {
            for i in 0..<8 {
                v |= UInt64(bytes[bytes.startIndex + i]) << (8 * i)
            }
        }
        return v
    }

    // MARK: Header

    mutating func readHeader() throws {
        guard data.count >= 1 else { throw TypedstreamError.empty }
        let v = try readByte()
        // We support streamer version 4 only (modern macOS / late NeXTSTEP).
        // Version 3 was used by very early NeXTSTEP; even python-typedstream
        // refuses to read it. We've never seen a v3 blob in chat.db.
        guard v == 4 else {
            throw TypedstreamError.unsupportedStreamerVersion(v)
        }
        streamerVersion = v
        let sigLen = try readByte()
        guard sigLen == 11 else {
            throw TypedstreamError.invalidSignatureLength(sigLen)
        }
        let sig = try readBytes(Int(sigLen))
        if sig.elementsEqual([0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64]) {
            // "streamtyped" → little-endian byte order (the Apple variant).
            isBigEndian = false
        } else if sig.elementsEqual([0x74, 0x79, 0x70, 0x65, 0x64, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d]) {
            // "typedstream" → big-endian (legacy NeXTSTEP).
            isBigEndian = true
        } else {
            throw TypedstreamError.invalidSignature(sig)
        }
        systemVersion = try readInteger(signed: false)
    }

    // MARK: Strings

    /// Read an *unshared* string (encoding `+`, also used for class names
    /// inside `_read_shared_string`).
    ///
    /// Head is the length (or a TAG_INTEGER_N if length > 127). Followed by
    /// exactly `length` bytes interpreted as UTF-8 (lossy on invalid bytes).
    /// Returns `nil` if head is TAG_NIL.
    mutating func readUnsharedString(head: Int8) throws -> String? {
        if head == Tag.nilTag {
            return nil
        }
        let length = try readInteger(head: head, signed: false)
        let bytes = try readBytes(Int(length))
        // Lossy UTF-8 — Foundation's documented behavior on `String(decoding:as:)`
        // is to insert U+FFFD for invalid sequences. The reference Python
        // implementation also tolerates non-UTF-8 bytes (returns `bytes`).
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Read a *shared* string. Either NEW (literal — append to table) or a
    /// back-reference. Returns `nil` if head is TAG_NIL.
    mutating func readSharedString(head: Int8) throws -> String? {
        if head == Tag.nilTag {
            return nil
        } else if head == Tag.newTag {
            // Literal — read an unshared string, append to table, return.
            let nextHead = try readHeadByte()
            guard let s = try readUnsharedString(head: nextHead) else {
                throw TypedstreamError.unexpectedNil(context: "literal shared string")
            }
            sharedStringTable.append(s)
            return s
        } else {
            // Back-reference. The reference number is `head` (or a multi-byte
            // form). Decode and look up.
            let refNumber = try readInteger(head: head, signed: true)
            // Indices in the typedstream start at -110 (= _FIRST_REFERENCE_NUMBER).
            // Convert to a zero-based index.
            let idx = Int(refNumber - Int64(Tag.firstReferenceNumber))
            guard idx >= 0 && idx < sharedStringTable.count else {
                throw TypedstreamError.invalidBackReference(idx, tableSize: sharedStringTable.count, context: "shared string")
            }
            return sharedStringTable[idx]
        }
    }

    mutating func readSharedString() throws -> String? {
        let head = try readHeadByte()
        return try readSharedString(head: head)
    }

    /// Read a C string (encoding `*`). Either NEW (literal — read shared
    /// string body, append to unified object table) or a back-reference.
    ///
    /// C strings have layered semantics: the literal data is read via the
    /// shared-string mechanism (so it ALSO gets appended to the
    /// shared-string table for type-encoding-style backrefs), then the
    /// resulting value gets a slot in the unified object table for
    /// pointer-style backrefs.
    mutating func readCString(head: Int8) throws -> TypedValue {
        if head == Tag.nilTag {
            return .nil
        } else if head == Tag.newTag {
            guard let s = try readSharedString() else {
                throw TypedstreamError.unexpectedNil(context: "literal C string")
            }
            objectTable.append(.cString(s))
            return .cString(s)
        } else {
            let idx = try resolveBackrefIndex(head: head)
            guard idx >= 0 && idx < objectTable.count,
                  case .cString(let s) = objectTable[idx] else {
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "c string")
            }
            return .cString(s)
        }
    }

    /// Helper: decode a back-reference number from a head byte (and any
    /// continuation bytes) into a zero-based index.
    mutating func resolveBackrefIndex(head: Int8) throws -> Int {
        let refNumber = try readInteger(head: head, signed: true)
        return Int(refNumber - Int64(Tag.firstReferenceNumber))
    }

    // MARK: Classes

    /// Read a class (chain of SingleClass entries terminated by NIL or a
    /// back-reference). Used during object decoding.
    ///
    /// The class chain represents the inheritance hierarchy: each
    /// SingleClass is stored *before* its superclass. For
    /// `NSAttributedString` (whose superclass is `NSObject`), the stream
    /// contains `NSAttributedString v0`, `NSObject v0`, then NIL.
    ///
    /// CRITICAL: each SingleClass entry gets its own slot in the unified
    /// object table for back-references. Per python-typedstream's
    /// `_lookup_reference`, a class backref points to a single class
    /// (with all its inherited superclasses already resolved), NOT to
    /// the whole chain that contains it. So we register one entry per
    /// class in the chain, where each entry holds that class's
    /// inheritance suffix (e.g. registering NSAttributedString registers
    /// `[NSAttributedString, NSObject]`; registering NSObject by itself
    /// registers `[NSObject]`).
    ///
    /// Returns the full chain starting at the most-derived class.
    mutating func readClass(head: Int8) throws -> [ParsedObject.ClassEntry] {
        var newSingleClasses: [ParsedObject.ClassEntry] = []
        var currentHead = head
        while currentHead == Tag.newTag {
            guard let name = try readSharedString() else {
                throw TypedstreamError.unexpectedNil(context: "class name")
            }
            let version = try readInteger(signed: true)
            newSingleClasses.append(.init(name: name, version: version))
            currentHead = try readHeadByte()
        }
        // Terminating token: NIL (no super) or a backref to a previously
        // registered class.
        var terminatorChain: [ParsedObject.ClassEntry] = []
        if currentHead == Tag.nilTag {
            // No superclass beyond what we read literally.
        } else {
            let idx = try resolveBackrefIndex(head: currentHead)
            guard idx >= 0 && idx < objectTable.count,
                  case .classChain(let chain) = objectTable[idx] else {
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "class")
            }
            terminatorChain = chain
        }
        // Build the full chain in stream order.
        let fullChain = newSingleClasses + terminatorChain
        // Register each NEWLY-read SingleClass as its own backref slot.
        // The chain stored at index i is the suffix starting from that
        // single class (so backref to NSObject = [NSObject], backref to
        // NSAttributedString = [NSAttributedString, NSObject, …]).
        for i in 0..<newSingleClasses.count {
            // Build the suffix starting at the i-th newly-read class.
            let suffix = Array(newSingleClasses[i...]) + terminatorChain
            objectTable.append(.classChain(suffix))
        }
        return fullChain
    }

    // MARK: Objects

    /// Read an object. Either NEW (literal — full class definition +
    /// fields + END_OF_OBJECT), NIL, or a back-reference to a previously
    /// stored object.
    ///
    /// Per python-typedstream's `decode_any_untyped_value` for
    /// BeginObject: the object's number is reserved BEFORE its class
    /// information is read (with a placeholder), then mutated to the
    /// real value after the object is fully constructed. This ordering
    /// matters because the class chain itself adds entries to the table.
    mutating func readObject(head: Int8) throws -> TypedValue {
        if head == Tag.nilTag {
            return .nil
        } else if head == Tag.newTag {
            // Reserve our slot in the unified object table BEFORE reading
            // the class (which appends class entries to the same table).
            let myIndex = objectTable.count
            objectTable.append(.objectPlaceholder)
            // Read the class chain.
            let classHead = try readHeadByte()
            let classChain = try readClass(head: classHead)
            // Read fields until END_OF_OBJECT.
            var fields: [TypedValueGroup] = []
            while true {
                let nextHead = try readHeadByte()
                if nextHead == Tag.endOfObject {
                    break
                }
                let group = try readTypedValues(head: nextHead)
                fields.append(group)
            }
            let obj = ParsedObject(classChain: classChain, fields: fields)
            // Replace placeholder with the real object.
            objectTable[myIndex] = .object(obj)
            return .object(obj)
        } else {
            // Back-reference to an existing object.
            let idx = try resolveBackrefIndex(head: head)
            guard idx >= 0 && idx < objectTable.count else {
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "object")
            }
            switch objectTable[idx] {
            case .object(let obj):
                return .object(obj)
            case .objectPlaceholder:
                // Circular reference encountered mid-construction. Real
                // typedstream blobs rarely (never?) hit this, but we
                // handle it defensively by returning a nil — the higher
                // level will treat it as an unresolved cycle.
                return .nil
            case .cString:
                // Type-mismatch: backref claims object context but the
                // table entry is a c-string. Real blobs shouldn't do
                // this; throw.
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "object (got cString)")
            case .classChain:
                // Same: object backref pointing at a class entry.
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "object (got class)")
            }
        }
    }

    // MARK: Floats

    mutating func readFloat(head: Int8) throws -> Double {
        if head == Tag.floatingPoint {
            // Single-precision: 4 bytes.
            let bytes = try readBytes(4)
            let bits = readU32(bytes)
            return Double(Float(bitPattern: bits))
        }
        // Integer-cast-to-float fallback (matches python-typedstream).
        return Double(try readInteger(head: head, signed: true))
    }

    mutating func readDouble(head: Int8) throws -> Double {
        if head == Tag.floatingPoint {
            let bytes = try readBytes(8)
            let bits = readU64(bytes)
            return Double(bitPattern: bits)
        }
        return Double(try readInteger(head: head, signed: true))
    }

    // MARK: Typed-value groups

    /// Read a typed-values block: a shared-string encoding followed by one
    /// value per encoding character. This is the top-level unit of the
    /// stream after the header.
    mutating func readTypedValues(head: Int8? = nil) throws -> TypedValueGroup {
        let initialHead = try (head ?? readHeadByte())
        guard let encoding = try readSharedString(head: initialHead) else {
            throw TypedstreamError.unexpectedNil(context: "type encoding")
        }
        guard !encoding.isEmpty else {
            throw TypedstreamError.unsupportedTypeEncoding("(empty)")
        }
        let encodings = splitEncodings(encoding)
        var values: [TypedValue] = []
        values.reserveCapacity(encodings.count)
        for enc in encodings {
            try values.append(readValueWithEncoding(enc))
        }
        return TypedValueGroup(encoding: encoding, values: values)
    }

    /// Decode a single value, given its (already-split) Objective-C type
    /// encoding string.
    mutating func readValueWithEncoding(_ encoding: String) throws -> TypedValue {
        // Booleans and chars are stored as raw bytes (no head-byte tag
        // wrapper) per python-typedstream's comments.
        switch encoding {
        case "B":
            let b = try readByte()
            return .integer(Int64(b == 0 ? 0 : 1))
        case "C":
            let b = try readByte()
            return .integer(Int64(b))
        case "c":
            let b = try readByte()
            return .integer(Int64(Int8(bitPattern: b)))
        case "S", "I", "L", "Q":
            return .integer(try readInteger(signed: false))
        case "s", "i", "l", "q":
            return .integer(try readInteger(signed: true))
        case "f":
            let head = try readHeadByte()
            return .float(try readFloat(head: head))
        case "d":
            let head = try readHeadByte()
            return .float(try readDouble(head: head))
        case "*":
            let head = try readHeadByte()
            return try readCString(head: head)
        case "%":
            let head = try readHeadByte()
            guard let s = try readSharedString(head: head) else {
                return .nil
            }
            return .atom(s)
        case ":":
            let head = try readHeadByte()
            guard let s = try readSharedString(head: head) else {
                return .nil
            }
            return .selector(s)
        case "+":
            // Unshared string — used for NSString's body.
            let head = try readHeadByte()
            if let s = try readUnsharedString(head: head) {
                return .string(s)
            }
            return .nil
        case "#":
            // Class reference (e.g. NSValue stores its inner type's class
            // here). NEW → fresh class chain (registers backref entries
            // for each SingleClass), NIL → nil class, otherwise → backref
            // into the unified object table at a `classChain` slot.
            let head = try readHeadByte()
            if head == Tag.nilTag {
                return .nil
            }
            if head == Tag.newTag {
                // The NEW byte signals "start of a class chain". Read the
                // SingleClasses until NIL / backref.
                let inner = try readHeadByte()
                let chain = try readClass(head: inner)
                if chain.isEmpty { return .nil }
                return .object(.init(classChain: chain, fields: []))
            }
            // Backref.
            let idx = try resolveBackrefIndex(head: head)
            guard idx >= 0 && idx < objectTable.count,
                  case .classChain(let chain) = objectTable[idx] else {
                throw TypedstreamError.invalidBackReference(idx, tableSize: objectTable.count, context: "class ref")
            }
            return .object(.init(classChain: chain, fields: []))
        case "@":
            let head = try readHeadByte()
            return try readObject(head: head)
        case "!":
            // Encoded type marker for "ignore me" — no data is written or
            // read. Return nil.
            return .nil
        default:
            if encoding.hasPrefix("[") {
                return try readArrayValue(encoding: encoding)
            } else if encoding.hasPrefix("{") {
                return try readStructValue(encoding: encoding)
            }
            throw TypedstreamError.unsupportedTypeEncoding(encoding)
        }
    }

    /// Parse an array encoding like `[3i]` (3 ints), `[5C]` (5 unsigned
    /// chars / bytes), and read the values.
    mutating func readArrayValue(encoding: String) throws -> TypedValue {
        // `[NX]` where N is decimal digits and X is the element encoding.
        // Sometimes X is itself a complex encoding (a struct or array) —
        // we re-parse those recursively.
        guard let (length, elementEncoding) = parseArrayEncoding(encoding) else {
            throw TypedstreamError.unsupportedTypeEncoding(encoding)
        }
        // Byte arrays (signed/unsigned char) are read all at once for
        // performance, mirroring python-typedstream's ByteArray special-case.
        if elementEncoding == "C" || elementEncoding == "c" {
            let data = try readBytes(length)
            return .byteArray(data)
        }
        var values: [TypedValue] = []
        values.reserveCapacity(length)
        for _ in 0..<length {
            try values.append(readValueWithEncoding(elementEncoding))
        }
        return .array(elementEncoding: elementEncoding, values: values)
    }

    mutating func readStructValue(encoding: String) throws -> TypedValue {
        // `{name=field1field2...}` — read the fields, name is optional
        // ("?" instead of name means anonymous).
        guard let (name, fieldEncodings) = parseStructEncoding(encoding) else {
            throw TypedstreamError.unsupportedTypeEncoding(encoding)
        }
        var fields: [TypedValue] = []
        fields.reserveCapacity(fieldEncodings.count)
        for f in fieldEncodings {
            try fields.append(readValueWithEncoding(f))
        }
        return .struct(name: name, fields: fields)
    }
}

// MARK: - Tag constants

private enum Tag {
    // Tags occupy signed bytes in [-128, -111] = unsigned [0x80, 0x91].
    // Reference numbers start at -110 (just past LAST_TAG).
    static let firstTag: Int8 = -128
    static let lastTag: Int8 = -111
    static let firstReferenceNumber: Int8 = -110

    static let integer2: Int8 = -127       // 0x81
    static let integer4: Int8 = -126       // 0x82
    static let floatingPoint: Int8 = -125  // 0x83
    static let newTag: Int8 = -124         // 0x84
    static let nilTag: Int8 = -123         // 0x85
    static let endOfObject: Int8 = -122    // 0x86

    static func isTag(_ b: Int8) -> Bool {
        return b >= firstTag && b <= lastTag
    }
}

// MARK: - Type-encoding helpers (split, parse-array, parse-struct)

/// Split a compound type-encoding string into its component encodings.
/// E.g. `"@@i"` → `["@", "@", "i"]`. Handles nested structs/arrays.
///
/// Made internal so tests can lock in the split behavior.
func splitEncodings(_ s: String) -> [String] {
    var out: [String] = []
    var current = ""
    var depth = 0
    var inStructName = false
    for ch in s {
        // Suffixes for runtime-only annotations get swallowed silently if
        // we don't need them. We pass them through transparently.
        if depth == 0 && current.isEmpty && (ch == "r" || ch == "n" || ch == "N"
                                              || ch == "o" || ch == "O"
                                              || ch == "R" || ch == "V") {
            // Modifier prefix — skip; the next char(s) form the actual
            // encoding.
            continue
        }
        current.append(ch)
        if ch == "{" {
            depth += 1
            inStructName = true
        } else if ch == "[" {
            depth += 1
        } else if ch == "}" {
            depth -= 1
            if depth == 0 {
                out.append(current)
                current = ""
                inStructName = false
            }
        } else if ch == "]" {
            depth -= 1
            if depth == 0 {
                out.append(current)
                current = ""
            }
        } else if ch == "=" && depth == 1 && inStructName {
            inStructName = false
        } else if depth == 0 {
            // Single-character encoding completed.
            out.append(current)
            current = ""
        }
    }
    if !current.isEmpty {
        out.append(current)
    }
    return out
}

/// Parse `[NX]` → (N, X). Returns nil if the encoding doesn't match.
func parseArrayEncoding(_ s: String) -> (length: Int, elementEncoding: String)? {
    guard s.hasPrefix("["), s.hasSuffix("]"), s.count >= 3 else { return nil }
    let inner = String(s.dropFirst().dropLast())
    var digits = ""
    var rest = ""
    var sawDigit = false
    for (i, ch) in inner.enumerated() {
        if !sawDigit && ch.isNumber {
            digits.append(ch)
        } else {
            sawDigit = true
            rest = String(inner.suffix(inner.count - i))
            break
        }
    }
    guard let n = Int(digits), !rest.isEmpty else { return nil }
    return (n, rest)
}

/// Parse `{name=fields}` → (name, [fields]). Name can be "?" for anonymous.
func parseStructEncoding(_ s: String) -> (name: String?, fieldEncodings: [String])? {
    guard s.hasPrefix("{"), s.hasSuffix("}"), s.count >= 3 else { return nil }
    let inner = String(s.dropFirst().dropLast())
    // Find the '=' (at outer level) separating the name from the fields.
    // Name may be omitted (no '=' in the encoding) — treat the whole thing
    // as fields.
    if let eqIdx = inner.firstIndex(of: "=") {
        let name = String(inner[..<eqIdx])
        let fields = String(inner[inner.index(after: eqIdx)...])
        let parsedName: String? = (name == "?" || name.isEmpty) ? nil : name
        return (parsedName, splitEncodings(fields))
    } else {
        return (nil, splitEncodings(inner))
    }
}
