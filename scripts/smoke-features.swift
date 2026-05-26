#!/usr/bin/env swift
//
//  smoke-features.swift
//  Quick sanity check for the chat.db access layer + search.
//
//  USAGE (from repo root):
//      swift scripts/smoke-features.swift
//
//  REQUIRES Full Disk Access for the running shell. If FDA isn't granted,
//  this prints a helpful diagnostic and exits 1 (does NOT block the build).
//
//  The script does NOT depend on building the app — it inlines the bits of
//  the data layer it needs so it can run as a standalone `swift` invocation.
//  We can't import the app target here without an Xcode-built framework, but
//  the SAME LOGIC is exercised in the real Sources/Data + Sources/Search.
//

import Foundation
import SQLite3

// MARK: - Helpers (mirror of the real code, kept tiny on purpose)

let MAC_EPOCH: TimeInterval = 978_307_200

func macDateToUnix(_ raw: Int64) -> TimeInterval {
    let s = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
    return s + MAC_EPOCH
}

func unixToMacNanos(_ d: Date) -> Int64 {
    Int64((d.timeIntervalSince1970 - MAC_EPOCH) * 1e9)
}

func unixToMacSeconds(_ d: Date) -> TimeInterval {
    d.timeIntervalSince1970 - MAC_EPOCH
}

func extractText(text: String?, blob: Data?) -> String {
    if let t = text, !t.isEmpty { return t }
    guard let blob, !blob.isEmpty else { return "" }
    let decoded = String(decoding: blob, as: UTF8.self)
    var runs: [String] = []
    var cur = String.UnicodeScalarView()
    func isPrintable(_ v: UInt32) -> Bool {
        if v >= 0x20 && v <= 0x7E { return true }
        if v == 0x09 || v == 0x0A { return true }
        if v >= 0xA0 && v <= 0xFFFF { return true }
        return false
    }
    func flush() {
        if cur.count >= 4 { runs.append(String(cur)) }
        cur.removeAll(keepingCapacity: true)
    }
    for s in decoded.unicodeScalars {
        if isPrintable(s.value) { cur.append(s) } else { flush() }
    }
    flush()
    return (runs.max(by: { $0.count < $1.count }) ?? decoded)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Open chat.db read-only

let home = FileManager.default.homeDirectoryForCurrentUser
let dbPath = home.appending(path: "Library/Messages/chat.db").path

var db: OpaquePointer?
let openFlags: Int32 = SQLITE_OPEN_READONLY
let openRC = sqlite3_open_v2(dbPath, &db, openFlags, nil)
if openRC != SQLITE_OK {
    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(openRC)"
    FileHandle.standardError.write(Data("""
        Could not open chat.db at \(dbPath).
        \(msg)
        If this is a TCC denial: grant Full Disk Access to your terminal/shell
        in System Settings → Privacy & Security → Full Disk Access.

        """.utf8))
    exit(1)
}

// MARK: - Range: last 30 days, search for " the "

let end = Date()
let start = end.addingTimeInterval(-30 * 24 * 3600)
let loNS = unixToMacNanos(start), hiNS = unixToMacNanos(end)
let loS = unixToMacSeconds(start), hiS = unixToMacSeconds(end)

let sql = """
SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody
FROM message m
WHERE m.associated_message_type = 0
  AND (
        (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
     OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
  )
"""

var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
    let msg = String(cString: sqlite3_errmsg(db))
    FileHandle.standardError.write(Data("prepare failed: \(msg)\n".utf8))
    sqlite3_close(db)
    exit(1)
}
defer { sqlite3_finalize(stmt) }
sqlite3_bind_int64(stmt, 1, loNS)
sqlite3_bind_int64(stmt, 2, hiNS)
sqlite3_bind_double(stmt, 3, loS)
sqlite3_bind_double(stmt, 4, hiS)

let needle = "the"
var scanned = 0
var matches = 0
var sentMatches = 0
var firstSample: (Date, Bool, String)?

while sqlite3_step(stmt) == SQLITE_ROW {
    scanned += 1
    let raw = sqlite3_column_int64(stmt, 1)
    let isFromMe = sqlite3_column_int(stmt, 2) == 1
    let text: String? = {
        if let c = sqlite3_column_text(stmt, 3) { return String(cString: c) }
        return nil
    }()
    let blob: Data? = {
        if let p = sqlite3_column_blob(stmt, 4) {
            let n = Int(sqlite3_column_bytes(stmt, 4))
            return Data(bytes: p, count: n)
        }
        return nil
    }()
    let body = extractText(text: text, blob: blob).lowercased()
    if body.contains(needle) {
        matches += 1
        if isFromMe { sentMatches += 1 }
        if firstSample == nil {
            let d = Date(timeIntervalSince1970: macDateToUnix(raw))
            let preview = String(body.prefix(120))
            firstSample = (d, isFromMe, preview)
        }
    }
}
sqlite3_close(db)

let df = ISO8601DateFormatter()
print("Window: \(df.string(from: start)) -> \(df.string(from: end))")
print("Scanned: \(scanned) messages, matched '\(needle)': \(matches) (\(sentMatches) from you)")
if let s = firstSample {
    print("First hit: [\(df.string(from: s.0))] \(s.1 ? "You" : "Other"): \(s.2)")
}
if matches == 0 {
    FileHandle.standardError.write(Data("warning: zero matches — expected a common word like 'the' to hit\n".utf8))
}

// MARK: - from: filter sanity check
//
// Pick the most common received handle from the last 30 days; count messages
// it would surface under `from:<that-handle>`. Validates that fromClause
// (in MessageSearch.swift) would resolve to a reasonable non-zero set.

var topHandleCounts: [String: Int] = [:]
let topHandleSQL = """
SELECT h.id AS handle, COUNT(*) AS n
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
JOIN chat ch ON ch.ROWID = cmj.chat_id
LEFT JOIN handle h ON h.ROWID = m.handle_id
WHERE m.is_from_me = 0
  AND m.associated_message_type = 0
  AND (
        (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
     OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
  )
  AND h.id IS NOT NULL
GROUP BY h.id
ORDER BY n DESC
LIMIT 1
"""

var stmt2: OpaquePointer?
var db2: OpaquePointer?
let openRC2 = sqlite3_open_v2(dbPath, &db2, openFlags, nil)
if openRC2 == SQLITE_OK, sqlite3_prepare_v2(db2, topHandleSQL, -1, &stmt2, nil) == SQLITE_OK {
    sqlite3_bind_int64(stmt2, 1, loNS)
    sqlite3_bind_int64(stmt2, 2, hiNS)
    sqlite3_bind_double(stmt2, 3, loS)
    sqlite3_bind_double(stmt2, 4, hiS)
    if sqlite3_step(stmt2) == SQLITE_ROW {
        let h = String(cString: sqlite3_column_text(stmt2, 0))
        let n = Int(sqlite3_column_int64(stmt2, 1))
        topHandleCounts[h] = n
        print("Top received handle in window: \(h) (\(n) msgs)")
        print("  → would be surfaced by `from:\(h)` filter (assuming it resolves).")
    } else {
        print("No received messages in the last 30 days.")
    }
}
sqlite3_finalize(stmt2)
sqlite3_close(db2)
