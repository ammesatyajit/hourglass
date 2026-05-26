#!/usr/bin/env swift
//
//  smoke-dashboard.swift
//  Sanity check for DashboardLoader against the user's real chat.db.
//
//  USAGE (from repo root):
//      swift scripts/smoke-dashboard.swift
//
//  REQUIRES Full Disk Access for the running shell. If FDA isn't granted,
//  this prints a helpful diagnostic and exits 1 (does NOT block the build).
//
//  Runs the same SQL aggregations that `Sources/Dashboard/DashboardLoader.swift`
//  runs, but inlined here so we can execute as a standalone `swift`
//  invocation (no Xcode build required). The numbers it prints should match
//  what shows up in the dashboard window when the app launches.
//
//  NOT a unit test — that lives in `Tests/DashboardLoaderTests.swift`.
//

import Foundation
import SQLite3

let DB_PATH = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
let MAC_EPOCH: TimeInterval = 978_307_200

// MARK: - Minimal SQLite wrapper

func openReadOnly(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    let uri = "file:\(path)?mode=ro"
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
    let rc = sqlite3_open_v2(uri, &db, flags, nil)
    if rc != SQLITE_OK {
        let msg = String(cString: sqlite3_errstr(rc))
        print("sqlite3_open_v2(\(path)) failed: \(msg)")
        if rc == SQLITE_PERM || rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH {
            print("→ This usually means Full Disk Access isn't granted to the running shell.")
            print("  System Settings → Privacy & Security → Full Disk Access → enable Terminal (or your shell host).")
        }
        return nil
    }
    return db
}

func query(_ db: OpaquePointer, _ sql: String) -> [[String]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("prepare failed:", String(cString: sqlite3_errmsg(db)))
        return []
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [[String]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let n = sqlite3_column_count(stmt)
        var row: [String] = []
        for i in 0..<n {
            if let cstr = sqlite3_column_text(stmt, i) {
                row.append(String(cString: cstr))
            } else {
                row.append("")
            }
        }
        rows.append(row)
    }
    return rows
}

// MARK: - Run

guard FileManager.default.fileExists(atPath: DB_PATH) else {
    print("chat.db not at \(DB_PATH) — Messages.app never opened?")
    exit(1)
}
guard let db = openReadOnly(DB_PATH) else { exit(1) }
defer { sqlite3_close(db) }

print("─────────────────────────────────────────────────")
print("  Dashboard smoke against ~/Library/Messages/chat.db")
print("─────────────────────────────────────────────────\n")

// Overview — same shape as DashboardLoader.loadOverview
print("OVERVIEW (all-time, real messages only — tapbacks excluded):")
let overview = query(db, """
    SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received,
        MIN(m.date), MAX(m.date)
    FROM message m
    WHERE m.associated_message_type = 0
    """)
let chatCount = query(db, "SELECT COUNT(*) FROM chat")
if let row = overview.first {
    print("  total    : \(row[0])")
    print("  sent     : \(row[1])")
    print("  received : \(row[2])")
    if let oldestRaw = Int64(row[3]), let newestRaw = Int64(row[4]) {
        let oldest = Date(timeIntervalSince1970: macDateToUnix(oldestRaw))
        let newest = Date(timeIntervalSince1970: macDateToUnix(newestRaw))
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .none
        print("  span     : \(f.string(from: oldest)) → \(f.string(from: newest))")
    }
}
if let row = chatCount.first {
    print("  chats    : \(row[0])")
}

print("\nTOP CONTACTS — all-time, 1:1 only (top 10):")
let topContacts = query(db, """
    SELECT
        h.id,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS recv,
        COUNT(*) AS total
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    JOIN handle h ON h.ROWID = COALESCE(
        m.handle_id,
        (SELECT chj.handle_id FROM chat_handle_join chj WHERE chj.chat_id = ch.ROWID LIMIT 1)
    )
    WHERE m.associated_message_type = 0
      AND ch.style = 45
    GROUP BY h.id
    ORDER BY total DESC
    LIMIT 10
    """)
for (i, row) in topContacts.enumerated() {
    let name = row[0].padding(toLength: 30, withPad: " ", startingAt: 0)
    print("  \(String(format: "%2d", i + 1)). \(name)  sent=\(row[1].padding(toLength: 6, withPad: " ", startingAt: 0))  recv=\(row[2].padding(toLength: 6, withPad: " ", startingAt: 0))  total=\(row[3])")
}

print("\nTOP GROUPS — all-time, ranked by your sent count (top 10):")
let topGroups = query(db, """
    SELECT
        ch.ROWID,
        COALESCE(NULLIF(ch.display_name, ''), '(unnamed group)'),
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        COUNT(*) AS total
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    WHERE m.associated_message_type = 0
      AND ch.style = 43
    GROUP BY ch.ROWID, ch.display_name
    HAVING sent > 0
    ORDER BY sent DESC, total DESC
    LIMIT 10
    """)
for (i, row) in topGroups.enumerated() {
    let name = row[1].padding(toLength: 40, withPad: " ", startingAt: 0)
    print("  \(String(format: "%2d", i + 1)). \(name)  sent=\(row[2].padding(toLength: 6, withPad: " ", startingAt: 0))  total=\(row[3])")
}

print("\nTIME SERIES — last 30 days, daily:")
let now = Date()
let cutoff = now.addingTimeInterval(-30 * 86400)
let cutoffNS = Int64((cutoff.timeIntervalSince1970 - MAC_EPOCH) * 1e9)
let cutoffS = Int64(cutoff.timeIntervalSince1970 - MAC_EPOCH)
let timeSeries = query(db, """
    SELECT
        strftime('%Y-%m-%d', datetime(
            CASE WHEN m.date > 1000000000000 THEN m.date / 1000000000 ELSE m.date END
            + 978307200, 'unixepoch', 'localtime'
        )) AS bucket,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS recv
    FROM message m
    WHERE m.associated_message_type = 0
      AND (
          (m.date > 1000000000000 AND m.date >= \(cutoffNS))
       OR (m.date <= 1000000000000 AND m.date >= \(cutoffS))
      )
    GROUP BY bucket
    ORDER BY bucket
    """)
print("  \(timeSeries.count) day buckets")
for row in timeSeries.prefix(5) {
    print("    \(row[0])   sent=\(row[1])  recv=\(row[2])")
}
if timeSeries.count > 5 {
    print("    …")
    for row in timeSeries.suffix(3) {
        print("    \(row[0])   sent=\(row[1])  recv=\(row[2])")
    }
}

print("\nOK")

// MARK: - utils

func macDateToUnix(_ raw: Int64) -> TimeInterval {
    let s = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
    return s + MAC_EPOCH
}
