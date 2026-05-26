#!/usr/bin/env swift
//
//  decoder_leakage_audit.swift
//  STATISTICAL TEST — proves the typedstream-based AttributedBodyDecoder
//  doesn't leak format bytes into the displayed body of real messages.
//
//  Why a standalone script (not a XCTest)?
//      Xcode's test runner doesn't inherit Full Disk Access from the
//      developer's shell — macOS TCC keys grants per binary. So even on
//      a dev machine where chat.db is readable from the terminal, the
//      Tests/DecoderLeakageAuditTests test skips. This script runs as
//      a plain Swift process under your shell + inherits the shell's
//      FDA grant, so it can actually read chat.db and produce the
//      headline number.
//
//  Run from repo root:
//      swift scripts/decoder_leakage_audit.swift
//
//  Output:
//      - Sample size, parser success rate
//      - Leakage rate (target < 0.1%)
//      - Top 20 stray leading-char histogram
//      - Up to 20 sample leaked bodies
//
//  PASS = leak rate < 0.1% (= 10 of 10,000). Pre-fix baseline was 15.5%
//  per docs/decoder-fix-empirical.md.
//
//  This script inlines the typedstream parser logic (kept in sync with
//  Sources/Data/Typedstream.swift) so it can run without building the
//  Xcode framework. If the two diverge, the test in
//  Tests/DecoderLeakageAuditTests.swift acts as the canary (it imports
//  the real parser via @testable).
//

import Foundation
import SQLite3

// MARK: - Inlined typedstream parser
// Kept in sync with Sources/Data/Typedstream.swift. See that file's
// docstring for the full format spec + references. Comments here are
// minimal — only enough to understand what's happening at the byte
// level. For the canonical reference, see python-typedstream's
// stream.py.

enum TSError: Error, CustomStringConvertible {
    case empty
    case unexpectedEnd(Int, Int)
    case unsupportedStreamerVersion(UInt8)
    case invalidSignatureLength(UInt8)
    case invalidSignature
    case invalidHeadTag(Int8)
    case invalidBackReference(Int, Int)
    case unsupportedTypeEncoding(String)
    case unexpectedNil

    var description: String {
        switch self {
        case .empty: return "empty"
        case .unexpectedEnd(let n, let r): return "unexpectedEnd(needed:\(n), remaining:\(r))"
        case .unsupportedStreamerVersion(let v): return "unsupportedStreamerVersion(\(v))"
        case .invalidSignatureLength(let l): return "invalidSignatureLength(\(l))"
        case .invalidSignature: return "invalidSignature"
        case .invalidHeadTag(let t): return "invalidHeadTag(\(t))"
        case .invalidBackReference(let i, let n): return "invalidBackref(\(i)/\(n))"
        case .unsupportedTypeEncoding(let e): return "unsupportedTypeEncoding(\(e))"
        case .unexpectedNil: return "unexpectedNil"
        }
    }
}

final class TSReader {
    let data: Data
    var cursor: Int
    var sharedStrings: [String] = []
    // Unified backref table — all of c-strings, classes, and objects
    // share a single numbering space (see python-typedstream's
    // archiving.py / shared_object_table).
    enum Entry {
        case cString(String)
        case classChain([(String, Int)])
        case object(TSObject)
        case placeholder
    }
    var unified: [Entry] = []
    var isBigEndian: Bool = false
    var systemVersion: Int64 = 0

    func resolveBackrefIndex(head h: Int8) throws -> Int {
        let r = try integer(head: h, signed: true)
        return Int(r) - Int(-110)
    }

    init(_ d: Data) { self.data = d; self.cursor = d.startIndex }

    var atEnd: Bool { cursor >= data.endIndex }
    var remaining: Int { data.endIndex - cursor }

    func byte() throws -> UInt8 {
        guard cursor < data.endIndex else { throw TSError.unexpectedEnd(1, 0) }
        let b = data[cursor]; cursor += 1; return b
    }
    func bytes(_ n: Int) throws -> Data {
        guard remaining >= n else { throw TSError.unexpectedEnd(n, remaining) }
        let s = data.subdata(in: cursor..<(cursor+n)); cursor += n; return s
    }
    func head() throws -> Int8 { Int8(bitPattern: try byte()) }

    func integer(head h: Int8, signed: Bool) throws -> Int64 {
        if h == -127 {  // TAG_INTEGER_2
            let b = try bytes(2)
            let lo = b[b.startIndex]; let hi = b[b.startIndex + 1]
            let u = isBigEndian ? (UInt16(lo) << 8) | UInt16(hi) : (UInt16(hi) << 8) | UInt16(lo)
            return signed ? Int64(Int16(bitPattern: u)) : Int64(u)
        }
        if h == -126 {  // TAG_INTEGER_4
            let b = try bytes(4)
            let b0 = UInt32(b[b.startIndex]), b1 = UInt32(b[b.startIndex+1])
            let b2 = UInt32(b[b.startIndex+2]), b3 = UInt32(b[b.startIndex+3])
            let u = isBigEndian
                ? (b0<<24) | (b1<<16) | (b2<<8) | b3
                : (b3<<24) | (b2<<16) | (b1<<8) | b0
            return signed ? Int64(Int32(bitPattern: u)) : Int64(u)
        }
        if h >= -128 && h <= -111 {
            throw TSError.invalidHeadTag(h)
        }
        return signed ? Int64(h) : Int64(UInt8(bitPattern: h))
    }
    func integer(signed: Bool) throws -> Int64 { try integer(head: try head(), signed: signed) }

    func readHeader() throws {
        guard data.count >= 1 else { throw TSError.empty }
        let v = try byte()
        guard v == 4 else { throw TSError.unsupportedStreamerVersion(v) }
        let len = try byte()
        guard len == 11 else { throw TSError.invalidSignatureLength(len) }
        let sig = try bytes(11)
        if sig.elementsEqual([0x73,0x74,0x72,0x65,0x61,0x6d,0x74,0x79,0x70,0x65,0x64]) {
            isBigEndian = false
        } else if sig.elementsEqual([0x74,0x79,0x70,0x65,0x64,0x73,0x74,0x72,0x65,0x61,0x6d]) {
            isBigEndian = true
        } else {
            throw TSError.invalidSignature
        }
        systemVersion = try integer(signed: false)
    }

    func unsharedString(head h: Int8) throws -> String? {
        if h == -123 { return nil }  // NIL
        let len = try integer(head: h, signed: false)
        let b = try bytes(Int(len))
        return String(decoding: b, as: UTF8.self)
    }
    func sharedString(head h: Int8) throws -> String? {
        if h == -123 { return nil }
        if h == -124 {  // NEW
            let nh = try head()
            guard let s = try unsharedString(head: nh) else { throw TSError.unexpectedNil }
            sharedStrings.append(s); return s
        }
        let r = try integer(head: h, signed: true)
        let idx = Int(r) - Int(-110)
        guard idx >= 0 && idx < sharedStrings.count else {
            throw TSError.invalidBackReference(idx, sharedStrings.count)
        }
        return sharedStrings[idx]
    }
    func sharedString() throws -> String? { try sharedString(head: try head()) }

    func readClass(head h: Int8) throws -> [(String, Int)] {
        var newSingles: [(String, Int)] = []
        var cur = h
        while cur == -124 {  // NEW
            guard let name = try sharedString() else { throw TSError.unexpectedNil }
            let ver = try integer(signed: true)
            newSingles.append((name, Int(ver)))
            cur = try head()
        }
        var terminatorChain: [(String, Int)] = []
        if cur == -123 {
            // NIL terminator
        } else {
            let idx = try resolveBackrefIndex(head: cur)
            guard idx >= 0 && idx < unified.count,
                  case .classChain(let chain) = unified[idx] else {
                throw TSError.invalidBackReference(idx, unified.count)
            }
            terminatorChain = chain
        }
        let fullChain = newSingles + terminatorChain
        for i in 0..<newSingles.count {
            let suffix = Array(newSingles[i...]) + terminatorChain
            unified.append(.classChain(suffix))
        }
        return fullChain
    }

    func readObject(head h: Int8) throws -> TSValue {
        if h == -123 { return .nilV }
        if h == -124 {
            // Reserve slot BEFORE reading class (class reads add to unified table).
            let myIdx = unified.count
            unified.append(.placeholder)
            let classHead = try head()
            let chain = try readClass(head: classHead)
            var fields: [TSGroup] = []
            while true {
                let nh = try head()
                if nh == -122 { break }  // END_OF_OBJECT
                let g = try readTypedValues(head: nh)
                fields.append(g)
            }
            let obj = TSObject(name: chain.first?.0 ?? "", chain: chain, fields: fields)
            unified[myIdx] = .object(obj)
            return .object(obj)
        }
        let idx = try resolveBackrefIndex(head: h)
        guard idx >= 0 && idx < unified.count else {
            throw TSError.invalidBackReference(idx, unified.count)
        }
        switch unified[idx] {
        case .object(let o): return .object(o)
        case .placeholder: return .nilV
        case .cString:
            throw TSError.invalidBackReference(idx, unified.count)
        case .classChain:
            throw TSError.invalidBackReference(idx, unified.count)
        }
    }

    func readValue(enc: String) throws -> TSValue {
        switch enc {
        case "B":
            return .integer(Int64(try byte() == 0 ? 0 : 1))
        case "C": return .integer(Int64(try byte()))
        case "c": return .integer(Int64(Int8(bitPattern: try byte())))
        case "S","I","L","Q": return .integer(try integer(signed: false))
        case "s","i","l","q": return .integer(try integer(signed: true))
        case "f":
            let h = try head()
            if h == -125 {
                let b = try bytes(4)
                let v: UInt32 = isBigEndian
                    ? (UInt32(b[b.startIndex])<<24) | (UInt32(b[b.startIndex+1])<<16) | (UInt32(b[b.startIndex+2])<<8) | UInt32(b[b.startIndex+3])
                    : (UInt32(b[b.startIndex+3])<<24) | (UInt32(b[b.startIndex+2])<<16) | (UInt32(b[b.startIndex+1])<<8) | UInt32(b[b.startIndex])
                return .float(Double(Float(bitPattern: v)))
            }
            return .float(Double(try integer(head: h, signed: true)))
        case "d":
            let h = try head()
            if h == -125 {
                let b = try bytes(8)
                var u: UInt64 = 0
                if isBigEndian {
                    for i in 0..<8 { u = (u<<8) | UInt64(b[b.startIndex+i]) }
                } else {
                    for i in 0..<8 { u |= UInt64(b[b.startIndex+i]) << (8*i) }
                }
                return .float(Double(bitPattern: u))
            }
            return .float(Double(try integer(head: h, signed: true)))
        case "*":
            let h = try head()
            if h == -123 { return .nilV }
            if h == -124 {
                guard let s = try sharedString() else { throw TSError.unexpectedNil }
                unified.append(.cString(s)); return .cString(s)
            }
            let idx = try resolveBackrefIndex(head: h)
            guard idx >= 0 && idx < unified.count,
                  case .cString(let s) = unified[idx] else { throw TSError.invalidBackReference(idx, unified.count) }
            return .cString(s)
        case "%":
            let h = try head()
            return try sharedString(head: h).map { .atom($0) } ?? .nilV
        case ":":
            let h = try head()
            return try sharedString(head: h).map { .selector($0) } ?? .nilV
        case "+":
            let h = try head()
            if let s = try unsharedString(head: h) { return .string(s) }
            return .nilV
        case "#":
            let h = try head()
            if h == -123 { return .nilV }
            if h == -124 {
                let inner = try head()
                let chain = try readClass(head: inner)
                if chain.isEmpty { return .nilV }
                return .object(TSObject(name: chain[0].0, chain: chain, fields: []))
            }
            // Backref to class.
            let idx = try resolveBackrefIndex(head: h)
            guard idx >= 0 && idx < unified.count,
                  case .classChain(let chain) = unified[idx] else {
                throw TSError.invalidBackReference(idx, unified.count)
            }
            return .object(TSObject(name: chain.first?.0 ?? "", chain: chain, fields: []))
        case "@":
            return try readObject(head: try head())
        case "!":
            return .nilV
        default:
            if enc.hasPrefix("[") {
                guard let (n, e) = parseArr(enc) else { throw TSError.unsupportedTypeEncoding(enc) }
                if e == "C" || e == "c" {
                    return .byteArray(try bytes(n))
                }
                var arr: [TSValue] = []
                for _ in 0..<n { arr.append(try readValue(enc: e)) }
                return .array(arr)
            }
            if enc.hasPrefix("{") {
                guard let fields = parseStruct(enc) else { throw TSError.unsupportedTypeEncoding(enc) }
                var arr: [TSValue] = []
                for f in fields { arr.append(try readValue(enc: f)) }
                return .struct_(arr)
            }
            throw TSError.unsupportedTypeEncoding(enc)
        }
    }

    func readTypedValues(head: Int8? = nil) throws -> TSGroup {
        let h = try (head ?? self.head())
        guard let enc = try sharedString(head: h) else { throw TSError.unexpectedNil }
        if enc.isEmpty { throw TSError.unsupportedTypeEncoding("(empty)") }
        let encs = splitEncs(enc)
        var values: [TSValue] = []
        for e in encs { values.append(try readValue(enc: e)) }
        return TSGroup(enc: enc, values: values)
    }
}

struct TSObject {
    let name: String
    let chain: [(String, Int)]
    let fields: [TSGroup]
}

indirect enum TSValue {
    case integer(Int64), float(Double), nilV, string(String), cString(String)
    case atom(String), selector(String), byteArray(Data)
    case array([TSValue]), struct_([TSValue]), object(TSObject)
}
struct TSGroup { let enc: String; let values: [TSValue] }

func splitEncs(_ s: String) -> [String] {
    var out: [String] = []
    var current = ""
    var depth = 0
    var inName = false
    for ch in s {
        if depth == 0 && current.isEmpty && (ch == "r" || ch == "n" || ch == "N"
                                              || ch == "o" || ch == "O"
                                              || ch == "R" || ch == "V") {
            continue
        }
        current.append(ch)
        if ch == "{" { depth += 1; inName = true }
        else if ch == "[" { depth += 1 }
        else if ch == "}" {
            depth -= 1
            if depth == 0 { out.append(current); current = ""; inName = false }
        } else if ch == "]" {
            depth -= 1
            if depth == 0 { out.append(current); current = "" }
        } else if ch == "=" && depth == 1 && inName { inName = false }
        else if depth == 0 { out.append(current); current = "" }
    }
    if !current.isEmpty { out.append(current) }
    return out
}
func parseArr(_ s: String) -> (Int, String)? {
    guard s.hasPrefix("["), s.hasSuffix("]"), s.count >= 3 else { return nil }
    let inner = String(s.dropFirst().dropLast())
    var digits = "", rest = ""
    var sawDigit = false
    for (i, ch) in inner.enumerated() {
        if !sawDigit && ch.isNumber { digits.append(ch) }
        else { sawDigit = true; rest = String(inner.suffix(inner.count - i)); break }
    }
    guard let n = Int(digits), !rest.isEmpty else { return nil }
    return (n, rest)
}
func parseStruct(_ s: String) -> [String]? {
    guard s.hasPrefix("{"), s.hasSuffix("}"), s.count >= 3 else { return nil }
    let inner = String(s.dropFirst().dropLast())
    let fields: String
    if let eq = inner.firstIndex(of: "=") { fields = String(inner[inner.index(after: eq)...]) }
    else { fields = inner }
    return splitEncs(fields)
}

// Walk a parsed archive to find the first NSString-flavored object and
// extract its raw text value.
func findNSString(_ value: TSValue) -> String? {
    switch value {
    case .object(let obj):
        if obj.name == "NSString" || obj.name == "NSMutableString"
            || obj.name == "NSAttributedString" || obj.name == "NSMutableAttributedString" {
            for field in obj.fields {
                for v in field.values {
                    if let s = findNSString(v) { return s }
                }
            }
            // No nested object — direct string field.
            for field in obj.fields {
                for v in field.values {
                    if case .string(let s) = v { return s }
                }
            }
        }
        for field in obj.fields {
            for v in field.values {
                if let s = findNSString(v) { return s }
            }
        }
    case .string(let s): return s
    default: return nil
    }
    return nil
}

func tsExtractString(_ data: Data) throws -> String? {
    let r = TSReader(data)
    try r.readHeader()
    while !r.atEnd {
        let g = try r.readTypedValues()
        for v in g.values {
            if let s = findNSString(v) { return s }
        }
    }
    return nil
}

func postprocess(_ raw: String) -> String {
    let hasFFFC = raw.unicodeScalars.contains(where: { $0.value == 0xFFFC })
    let hasLeadingFFFD = raw.unicodeScalars.first?.value == 0xFFFD
    if !hasFFFC && !hasLeadingFFFD {
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var out = String.UnicodeScalarView()
    var trimmedLeading = false
    for s in raw.unicodeScalars {
        if s.value == 0xFFFC { continue }
        if !trimmedLeading && s.value == 0xFFFD { continue }
        if !trimmedLeading && (s.value == 0x20 || s.value == 0x09 || s.value == 0x0A) { continue }
        trimmedLeading = true
        out.append(s)
    }
    return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
}

// Legacy heuristic — only used as fallback for parser failures.
func legacyDecode(_ blob: Data) -> String {
    let decoded = String(decoding: blob, as: UTF8.self)
    var runs: [String] = []
    var cur = String.UnicodeScalarView()
    func isPrintable(_ v: UInt32) -> Bool {
        if v == 0xFFFD || v == 0xFFFC { return false }
        if v >= 0x20 && v <= 0x7E { return true }
        if v == 0x09 || v == 0x0A { return true }
        if v >= 0xA0 && v <= 0xFFFB { return true }
        if v >= 0x10000 && v <= 0x10FFFF { return true }
        return false
    }
    func flush() {
        if cur.count >= 2 { runs.append(String(cur)) }
        cur.removeAll(keepingCapacity: true)
    }
    for s in decoded.unicodeScalars {
        if isPrintable(s.value) { cur.append(s) } else { flush() }
    }
    flush()
    let exact: Set<String> = ["streamtyped","NSObject","NSString","NSMutableString",
        "NSAttributedString","NSMutableAttributedString","NSDictionary","NSMutableDictionary",
        "NSArray","NSMutableArray","NSNumber","NSValue","NSData","NSMutableData","NSDate","NSUUID","NSURL","iI"]
    let cleaned = runs.compactMap { r -> String? in
        let edges = CharacterSet(charactersIn: "+@()[]{}<>!*&^%$#\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}").union(.whitespacesAndNewlines)
        let trimmed = r.trimmingCharacters(in: edges)
        guard !trimmed.isEmpty else { return nil }
        if exact.contains(trimmed) { return nil }
        if trimmed.hasPrefix("__kIM") || trimmed.hasPrefix("NS.") { return nil }
        return trimmed
    }
    return cleaned.max(by: { $0.count < $1.count }) ?? ""
}

func decode(_ blob: Data) -> String {
    do {
        if let s = try tsExtractString(blob) { return postprocess(s) }
        return ""
    } catch {
        return legacyDecode(blob)
    }
}

// MARK: - "Leak" classifier (kept in sync with DecoderLeakageAuditTests.looksLikeLeak)

func looksLikeLeak(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let scalars = Array(trimmed.unicodeScalars)
    guard let first = scalars.first else { return false }
    let v = first.value
    if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { return true }
    if v == 0x7F { return true }
    if v == 0xFFFD || v == 0xFFFC { return true }
    guard scalars.count >= 2 else { return false }
    let v2 = scalars[1].value
    let firstUpper = v >= 0x41 && v <= 0x5A
    let secondUpper = v2 >= 0x41 && v2 <= 0x5A
    if firstUpper && secondUpper {
        if scalars.count == 2 { return false }
        let v3 = scalars[2].value
        let thirdLower = v3 >= 0x61 && v3 <= 0x7A
        if thirdLower { return true }
        return false
    }
    let firstDigit = v >= 0x30 && v <= 0x39
    if firstDigit && secondUpper { return true }
    let leakyPunct: Set<UInt32> = [0x3F, 0x2F, 0x3D, 0x3A]
    if leakyPunct.contains(v) && secondUpper { return true }
    return false
}

// MARK: - Main

let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
var db: OpaquePointer?
let openFlags: Int32 = SQLITE_OPEN_READONLY
if sqlite3_open_v2(dbPath, &db, openFlags, nil) != SQLITE_OK {
    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    FileHandle.standardError.write(Data("Could not open \(dbPath): \(msg)\nFix: grant FDA to your terminal (Privacy & Security → Full Disk Access).\n".utf8))
    exit(2)
}
defer { sqlite3_close(db) }

let sampleSize = Int(CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 10_000)
print("Sampling \(sampleSize) random rows with non-NULL attributedBody...")
print()

var blobs: [Data] = []
var stmt: OpaquePointer?
let sql = """
SELECT attributedBody FROM message
WHERE attributedBody IS NOT NULL AND associated_message_type = 0
ORDER BY RANDOM() LIMIT \(sampleSize)
"""
if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
    print("SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(2)
}
defer { sqlite3_finalize(stmt) }
while sqlite3_step(stmt) == SQLITE_ROW {
    if let raw = sqlite3_column_blob(stmt, 0) {
        let n = Int(sqlite3_column_bytes(stmt, 0))
        blobs.append(Data(bytes: raw, count: n))
    }
}

var parsedOK = 0
var parsedFailed = 0
var emptyCount = 0
var leaked = 0
var metaLeaked = 0
var strayHist: [Unicode.Scalar: Int] = [:]
var leakedSamples: [String] = []
var metaSamples: [String] = []
var parseErrorHist: [String: Int] = [:]

let metaMarkers = [
    "streamtyped", "NSAttributedString", "NSMutableAttributedString",
    "__kIMMessagePartAttributeName", "__kIMFileTransferGUIDAttributeName",
    "__kIMBaseWritingDirectionAttributeName", "NSDictionary", "NSMutableDictionary"
]

for blob in blobs {
    do {
        _ = try tsExtractString(blob)
        parsedOK += 1
    } catch let e {
        parsedFailed += 1
        let key = "\(e)"
        parseErrorHist[key, default: 0] += 1
    }
    let decoded = decode(blob)
    if decoded.isEmpty { emptyCount += 1; continue }
    if looksLikeLeak(decoded) {
        leaked += 1
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.unicodeScalars.first {
            strayHist[first, default: 0] += 1
        }
        if leakedSamples.count < 20 { leakedSamples.append(String(decoded.prefix(120))) }
    }
    for marker in metaMarkers {
        if decoded.contains(marker) {
            metaLeaked += 1
            if metaSamples.count < 5 { metaSamples.append("[\(marker)] " + String(decoded.prefix(120))) }
            break
        }
    }
}

let total = blobs.count
let nonEmpty = total - emptyCount
let leakRate = nonEmpty > 0 ? Double(leaked) / Double(nonEmpty) * 100.0 : 0.0
let parseRate = Double(parsedOK) / Double(total) * 100.0

print("============================================================")
print("DECODER LEAKAGE AUDIT")
print("============================================================")
print("Sample size:                   \(total)")
print("Decoded empty:                 \(emptyCount)")
print("Decoded non-empty:             \(nonEmpty)")
print("")
print("Typedstream parser succeeded:  \(parsedOK) / \(total) (\(String(format: "%.2f", parseRate))%)")
print("Typedstream parser fell back:  \(parsedFailed)")
if !parseErrorHist.isEmpty {
    print("  Parser error breakdown:")
    for (e, c) in parseErrorHist.sorted(by: { $0.value > $1.value }).prefix(10) {
        print("    \(c)x: \(e)")
    }
}
print("")
print("Suspicious leading characters: \(leaked) / \(nonEmpty)")
print("Leak rate:                     \(String(format: "%.4f", leakRate))%")
print("Threshold:                     < 0.1%")
print("Pre-fix baseline:              ~15.5%")
print("Reduction vs baseline:         \(leakRate > 0 ? String(format: "%.1fx", 15.5 / leakRate) : "∞")")
print("")
print("Metadata leaks (`streamtyped`, `__kIM*`, etc.): \(metaLeaked)")
print("")
print("Top 20 stray leading-char histogram:")
let top = strayHist.sorted(by: { $0.value > $1.value }).prefix(20)
if top.isEmpty {
    print("  (none — no leaks detected)")
} else {
    for (scalar, count) in top {
        let display = scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7F ? String(scalar) : "?"
        print(String(format: "  U+%04X '%@' (byte=%d): %d", scalar.value, display, scalar.value, count))
    }
}
print("")
print("Up to 20 sample leaked rows:")
if leakedSamples.isEmpty {
    print("  (none)")
} else {
    for (i, s) in leakedSamples.enumerated() {
        print("  [\(i+1)] \(s)")
    }
}
if !metaSamples.isEmpty {
    print("")
    print("Metadata-leak sample rows (up to 5):")
    for s in metaSamples { print("  - \(s)") }
}
print("============================================================")
print("")
if leakRate < 0.1 && metaLeaked == 0 {
    print("PASS: leak rate \(String(format: "%.4f", leakRate))% is below the 0.1% threshold.")
    exit(0)
} else {
    print("FAIL: leak rate \(String(format: "%.4f", leakRate))% exceeds 0.1% threshold OR metadata leaks present (\(metaLeaked)).")
    exit(1)
}
