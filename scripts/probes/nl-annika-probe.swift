#!/usr/bin/env swift
//
//  nl-annika-probe.swift
//  Hourglass — NL race fix verification probe
//
//  Runs against the user's REAL ~/Library/Messages/chat.db to verify
//  that the rule-based fallback handles the canonical failing query:
//
//      "find my argument with annika around 3 weeks ago"
//
//  This is the end-to-end test that the in-app demo bombed today
//  (legacy planner + stub fallback returned 44 "find" matches with
//  Annika's "i cant find my airpods" as the hero). After the L2 fix
//  in `NLAgent.answer()`, the stub runtime is bypassed; the agent
//  goes straight to `runFallback` which uses `RuleBasedQueryBuilder`.
//
//  The probe is INTENTIONALLY standalone — it inlines the minimum
//  needed to exercise the same SQL the app would emit. Doesn't link
//  the app target; runs from the repo root via
//      swift scripts/probes/nl-annika-probe.swift
//  Requires Full Disk Access on the running shell (Terminal/iTerm).
//

import Foundation
import SQLite3

// MARK: - Helpers (mirror of `Sources/Data/*` + `Sources/Search/*` math)

let MAC_EPOCH: TimeInterval = 978_307_200

func macAbsoluteFrom(date: Date) -> Int64 {
    // Nanoseconds form (post-10.13). The chat.db `date` column is
    // ns-since-2001 for modern messages; older rows are seconds. We
    // produce ns and pair it with a seconds query for safety.
    Int64((date.timeIntervalSince1970 - MAC_EPOCH) * 1_000_000_000)
}

func macAbsoluteFromSeconds(date: Date) -> Double {
    date.timeIntervalSince1970 - MAC_EPOCH
}

func dateFromMac(raw: Int64) -> Date {
    let secs = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
    return Date(timeIntervalSince1970: secs + MAC_EPOCH)
}

func extractText(text: String?, blob: Data?) -> String {
    if let t = text, !t.isEmpty { return t }
    guard let blob, !blob.isEmpty else { return "" }
    // Lossy: pull printable runs from the typedstream blob. Good
    // enough for diagnostics — the real app uses the proper
    // typedstream parser.
    let decoded = String(decoding: blob, as: UTF8.self)
    var runs: [String] = []
    var cur = ""
    for ch in decoded.unicodeScalars {
        if (ch.value >= 0x20 && ch.value <= 0x7E)
            || ch.value == 0x09 || ch.value == 0x0A
            || (ch.value >= 0xA0 && ch.value <= 0xFFFF) {
            cur.append(Character(ch))
        } else {
            if cur.count >= 4 { runs.append(cur) }
            cur = ""
        }
    }
    if cur.count >= 4 { runs.append(cur) }
    return (runs.max(by: { $0.count < $1.count }) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 1. Resolve "Annika" against AddressBook

func resolveContactByFirstName(_ first: String) -> (displayName: String, handles: [String])? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let sourcesRoot = home.appending(path: "Library/Application Support/AddressBook/Sources",
                                     directoryHint: .isDirectory)
    guard let dirs = try? FileManager.default.contentsOfDirectory(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
    ) else {
        return nil
    }
    for dir in dirs {
        let dbPath = dir.appending(path: "AddressBook-v22.abcddb").path
        guard FileManager.default.fileExists(atPath: dbPath) else { continue }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            continue
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT r.ZFIRSTNAME, r.ZLASTNAME,
                   group_concat(DISTINCT p.ZFULLNUMBER) AS phones,
                   group_concat(DISTINCT e.ZADDRESS) AS emails
            FROM ZABCDRECORD r
            LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
            WHERE LOWER(r.ZFIRSTNAME) = LOWER(?)
            GROUP BY r.Z_PK
            ORDER BY (COALESCE(phones, '') || COALESCE(emails, '')) DESC
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, first, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let firstN = (sqlite3_column_text(stmt, 0)).map { String(cString: $0) } ?? ""
            let lastN = (sqlite3_column_text(stmt, 1)).map { String(cString: $0) } ?? ""
            let phones = (sqlite3_column_text(stmt, 2)).map { String(cString: $0) } ?? ""
            let emails = (sqlite3_column_text(stmt, 3)).map { String(cString: $0) } ?? ""
            let displayName = [firstN, lastN].filter { !$0.isEmpty }.joined(separator: " ")
            var handles: [String] = []
            if !phones.isEmpty {
                handles.append(contentsOf: phones.split(separator: ",").map(String.init))
            }
            if !emails.isEmpty {
                handles.append(contentsOf: emails.split(separator: ",").map(String.init))
            }
            return (displayName, handles)
        }
    }
    return nil
}

func normalizeHandle(_ raw: String) -> String {
    if raw.contains("@") { return raw.lowercased() }
    let digits = raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init)
    var d = String(digits)
    if d.count == 10 { d = "1" + d }
    return "+" + d
}

// MARK: - 2. Find Annika's 1:1 chat ROWID (mirrors `in:"NAME"` semantics)

let home = FileManager.default.homeDirectoryForCurrentUser
let chatDBPath = home.appending(path: "Library/Messages/chat.db").path

var db: OpaquePointer?
let openRC = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil)
guard openRC == SQLITE_OK else {
    print("ERROR: could not open chat.db (\(openRC)). Grant Full Disk Access to the shell.")
    exit(1)
}
defer { sqlite3_close(db) }

print("=== nl-annika-probe ===")
print("Query: \"find my argument with annika around 3 weeks ago\"")
print("Today: 2026-05-27 → 3 weeks ago ≈ 2026-05-06")
print("")

// Step A: resolve "annika" to a contact display name + handles
guard let (displayName, rawHandles) = resolveContactByFirstName("annika") else {
    print("FAIL: no contact named 'annika' in AddressBook.")
    exit(1)
}
let normalizedHandles = rawHandles.map(normalizeHandle)
print("Step A — resolved person: \(displayName)")
print("           handles: \(normalizedHandles.joined(separator: ", "))")
print("")

// Step B: find the 1:1 chat (style=45) whose participant is one of Annika's handles.
//         This mirrors what `in:"NAME"` does in MessageSearch.chatClause.
let allHandles = Set(rawHandles).union(normalizedHandles)
let placeholders = Array(repeating: "?", count: allHandles.count).joined(separator: ", ")
let findChatSQL = """
    SELECT ch.ROWID, ch.display_name
    FROM chat ch
    JOIN chat_handle_join chj ON chj.chat_id = ch.ROWID
    JOIN handle h ON h.ROWID = chj.handle_id
    WHERE ch.style = 45
      AND h.id IN (\(placeholders))
    GROUP BY ch.ROWID
    """
var chatStmt: OpaquePointer?
guard sqlite3_prepare_v2(db, findChatSQL, -1, &chatStmt, nil) == SQLITE_OK else {
    print("FAIL: prepare chat lookup: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}
for (i, h) in allHandles.enumerated() {
    sqlite3_bind_text(chatStmt, Int32(i + 1), h, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}
var oneToOneChatID: Int64? = nil
while sqlite3_step(chatStmt) == SQLITE_ROW {
    oneToOneChatID = sqlite3_column_int64(chatStmt, 0)
    break
}
sqlite3_finalize(chatStmt)
guard let chatID = oneToOneChatID else {
    print("FAIL: no 1:1 chat (style=45) with Annika's handles. Maybe she's only in groups.")
    exit(1)
}
print("Step B — 1:1 chat ROWID: \(chatID)")
print("")

// Step C: count all messages in that chat in the date window (~3 weeks ago ±15 days,
//         to match RuleBasedQueryBuilder's fuzzy "around" widening).
let now = Date()
let windowStart = now.addingTimeInterval(-Double(31) * 86_400) // last:31d
let countSQL = """
    SELECT COUNT(*)
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id = ?
      AND m.associated_message_type = 0
      AND (
        (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
     OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
      )
    """
var countStmt: OpaquePointer?
sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil)
sqlite3_bind_int64(countStmt, 1, chatID)
sqlite3_bind_int64(countStmt, 2, macAbsoluteFrom(date: windowStart))
sqlite3_bind_int64(countStmt, 3, macAbsoluteFrom(date: now))
sqlite3_bind_double(countStmt, 4, macAbsoluteFromSeconds(date: windowStart))
sqlite3_bind_double(countStmt, 5, macAbsoluteFromSeconds(date: now))
sqlite3_step(countStmt)
let windowCount = sqlite3_column_int64(countStmt, 0)
sqlite3_finalize(countStmt)
print("Step C — messages in 1:1 with \(displayName) in last:31d: \(windowCount)")
print("")

// Step D: sample the chronological tail around 3 weeks ago (May 5±5d).
let target = Calendar.current.date(byAdding: .day, value: -22, to: now)!
let lower = Calendar.current.date(byAdding: .day, value: -5, to: target)!
let upper = Calendar.current.date(byAdding: .day, value: +5, to: target)!
let sampleSQL = """
    SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, m.handle_id
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id = ?
      AND m.associated_message_type = 0
      AND (
        (m.date > 1000000000000 AND m.date BETWEEN ? AND ?)
     OR (m.date <= 1000000000000 AND m.date BETWEEN ? AND ?)
      )
    ORDER BY m.date ASC
    LIMIT 80
    """
var sampleStmt: OpaquePointer?
sqlite3_prepare_v2(db, sampleSQL, -1, &sampleStmt, nil)
sqlite3_bind_int64(sampleStmt, 1, chatID)
sqlite3_bind_int64(sampleStmt, 2, macAbsoluteFrom(date: lower))
sqlite3_bind_int64(sampleStmt, 3, macAbsoluteFrom(date: upper))
sqlite3_bind_double(sampleStmt, 4, macAbsoluteFromSeconds(date: lower))
sqlite3_bind_double(sampleStmt, 5, macAbsoluteFromSeconds(date: upper))

print("Step D — chronological messages in centered window (May \(Calendar.current.component(.day, from: lower))..May \(Calendar.current.component(.day, from: upper))):")

var msgs: [(date: Date, fromMe: Bool, body: String)] = []
while sqlite3_step(sampleStmt) == SQLITE_ROW {
    let date = dateFromMac(raw: sqlite3_column_int64(sampleStmt, 1))
    let fromMe = sqlite3_column_int(sampleStmt, 2) == 1
    let text: String? = (sqlite3_column_text(sampleStmt, 3)).map { String(cString: $0) }
    let blob: Data?
    if let p = sqlite3_column_blob(sampleStmt, 4) {
        let n = Int(sqlite3_column_bytes(sampleStmt, 4))
        blob = Data(bytes: p, count: n)
    } else {
        blob = nil
    }
    let body = extractText(text: text, blob: blob)
    msgs.append((date, fromMe, body))
}
sqlite3_finalize(sampleStmt)

let df = DateFormatter()
df.dateFormat = "MMM d, HH:mm"
for (i, m) in msgs.prefix(20).enumerated() {
    let sender = m.fromMe ? "You" : displayName.split(separator: " ").first.map(String.init) ?? "Other"
    let body = String(m.body.prefix(80))
    print(String(format: "  [%2d] %@ %@: %@", i, df.string(from: m.date), sender, body))
}
if msgs.count > 20 {
    print("  … (\(msgs.count - 20) more)")
}
print("")

// Step E: did we hit any message containing "rage" / "vent" / "frustrat" / "annoy"?
//         These are tone-shift markers a human (or LLM) would identify as
//         "argument start." The probe just checks for SIGNAL.
let toneMarkers = ["rage", "vent", "frustrat", "annoy", "i need to vent", "hella", "delib"]
var matched: [(idx: Int, marker: String, body: String, date: Date)] = []
for (i, m) in msgs.enumerated() {
    let lower = m.body.lowercased()
    for marker in toneMarkers where lower.contains(marker) {
        matched.append((i, marker, m.body, m.date))
        break
    }
}
print("Step E — tone-shift signal (a real argument START would contain at least one):")
if matched.isEmpty {
    print("  ❌ NONE found in the chronological window — either the argument is OUTSIDE the window or the messages don't use these words.")
} else {
    for hit in matched.prefix(5) {
        print("  ✅ index [\(hit.idx)] @ \(df.string(from: hit.date)) — \"\(hit.marker)\" in: \(String(hit.body.prefix(120)))")
    }
}
print("")
print("=== Conclusion ===")
print("Rule-based fallback (after L2 ships) would emit query:")
print("    in:\"\(displayName)\" last:31d argument   (initial)")
print("    in:\"\(displayName)\" last:31d            (retry, if 0 hits on concept)")
print("→ Window has \(windowCount) messages; \(msgs.count) within ±5d of target.")
print("→ \(matched.isEmpty ? "❌ No tone markers — argument may be earlier or use different language." : "✅ \(matched.count) tone marker(s) found — user can identify the argument from the chronological dump.")")
