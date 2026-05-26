#!/usr/bin/env bash
# Measure end-to-end aggregate preload + per-frame brush recompute time
# against the user's real chat.db. Run via the standalone Swift smoke
# script so it inherits the shell's FDA grant.
#
# Usage:  ./scripts/probes/dashboard-brush-perf.sh
#
# Prints:
#   - preload time (ms)
#   - mean / p95 / max per-recompute time (ms) over a synthetic 300-
#     frame drag covering the full date span.
#
set -euo pipefail
cd "$(dirname "$0")/../.."

cat > /tmp/dashboard-brush-perf.swift <<'EOF'
#!/usr/bin/env swift
import Foundation
import SQLite3

// Inline copy of the dayIndex + slice + recompute logic so we don't
// have to compile the whole app. Mirrors DashboardAllTimeAggregate.swift.
// If this drifts from the real impl, update both.

let DB_PATH = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath
let MAC_EPOCH: TimeInterval = 978_307_200

struct DailyCount {
    let dayIndex: Int32
    let sent: Int32
    let received: Int32
}

func openRO(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    let uri = "file:\(path)?mode=ro"
    if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
        if let db { sqlite3_close(db) }
        return nil
    }
    return db
}

// 1. Preload: global daily series.
guard let db = openRO(DB_PATH) else {
    print("Cannot open chat.db — grant Full Disk Access to your shell first.")
    exit(1)
}
defer { sqlite3_close(db) }

let dailySQL = """
    SELECT
        CAST(strftime('%s', date(
            CASE WHEN m.date > 1000000000000
                 THEN m.date / 1000000000
                 ELSE m.date
            END + 978307200,
            'unixepoch', 'localtime'
        )) AS INTEGER) AS unix_day,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
    FROM message m
    WHERE m.associated_message_type = 0
    GROUP BY unix_day
    HAVING unix_day IS NOT NULL
    ORDER BY unix_day ASC
"""

let t0 = Date()
var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, dailySQL, -1, &stmt, nil) == SQLITE_OK, stmt != nil else {
    print("prep failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}
var dailyOverview: [DailyCount] = []
while sqlite3_step(stmt) == SQLITE_ROW {
    let unixDay = sqlite3_column_int64(stmt, 0)
    let sent = sqlite3_column_int64(stmt, 1)
    let recv = sqlite3_column_int64(stmt, 2)
    let date = Date(timeIntervalSince1970: TimeInterval(unixDay))
    let dayIndex = Int32(floor(date.timeIntervalSinceReferenceDate / 86_400))
    dailyOverview.append(DailyCount(dayIndex: dayIndex, sent: Int32(clamping: sent), received: Int32(clamping: recv)))
}
sqlite3_finalize(stmt)

// 2. Per-contact daily series — same SQL as DashboardLoader.loadContactSeries.
let contactSQL = """
    SELECT
        h.id AS handle,
        CAST(strftime('%s', date(
            CASE WHEN m.date > 1000000000000
                 THEN m.date / 1000000000
                 ELSE m.date
            END + 978307200,
            'unixepoch', 'localtime'
        )) AS INTEGER) AS unix_day,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    JOIN handle h ON h.ROWID = COALESCE(
        m.handle_id,
        (SELECT chj.handle_id FROM chat_handle_join chj
         WHERE chj.chat_id = ch.ROWID LIMIT 1)
    )
    WHERE m.associated_message_type = 0
      AND ch.style = 45
    GROUP BY h.id, unix_day
    HAVING unix_day IS NOT NULL
"""

guard sqlite3_prepare_v2(db, contactSQL, -1, &stmt, nil) == SQLITE_OK, stmt != nil else {
    print("contact prep failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}
var contactRows: [(String, Int32, Int32, Int32)] = []
while sqlite3_step(stmt) == SQLITE_ROW {
    let handle = String(cString: sqlite3_column_text(stmt, 0))
    let unixDay = sqlite3_column_int64(stmt, 1)
    let sent = sqlite3_column_int64(stmt, 2)
    let recv = sqlite3_column_int64(stmt, 3)
    let date = Date(timeIntervalSince1970: TimeInterval(unixDay))
    let dayIndex = Int32(floor(date.timeIntervalSinceReferenceDate / 86_400))
    contactRows.append((handle, dayIndex, Int32(clamping: sent), Int32(clamping: recv)))
}
sqlite3_finalize(stmt)

// 3. Per-group daily series.
let groupSQL = """
    SELECT
        ch.ROWID AS chat_rowid,
        CAST(strftime('%s', date(
            CASE WHEN m.date > 1000000000000
                 THEN m.date / 1000000000
                 ELSE m.date
            END + 978307200,
            'unixepoch', 'localtime'
        )) AS INTEGER) AS unix_day,
        SUM(CASE WHEN m.is_from_me = 1 THEN 1 ELSE 0 END) AS sent,
        SUM(CASE WHEN COALESCE(m.is_from_me, 0) = 0 THEN 1 ELSE 0 END) AS received
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    WHERE m.associated_message_type = 0
      AND ch.style = 43
    GROUP BY ch.ROWID, unix_day
    HAVING unix_day IS NOT NULL
"""
guard sqlite3_prepare_v2(db, groupSQL, -1, &stmt, nil) == SQLITE_OK, stmt != nil else {
    print("group prep failed: \(String(cString: sqlite3_errmsg(db)))")
    exit(1)
}
var groupRows: [(Int64, Int32, Int32, Int32)] = []
while sqlite3_step(stmt) == SQLITE_ROW {
    let rowID = sqlite3_column_int64(stmt, 0)
    let unixDay = sqlite3_column_int64(stmt, 1)
    let sent = sqlite3_column_int64(stmt, 2)
    let recv = sqlite3_column_int64(stmt, 3)
    let date = Date(timeIntervalSince1970: TimeInterval(unixDay))
    let dayIndex = Int32(floor(date.timeIntervalSinceReferenceDate / 86_400))
    groupRows.append((rowID, dayIndex, Int32(clamping: sent), Int32(clamping: recv)))
}
sqlite3_finalize(stmt)

let preloadMs = Date().timeIntervalSince(t0) * 1000.0
print("PRELOAD: \(Int(preloadMs)) ms  (daily \(dailyOverview.count), contact-day rows \(contactRows.count), group-day rows \(groupRows.count))")

// Build per-handle and per-chatRowID sorted arrays.
var contactsByKey: [String: [DailyCount]] = [:]
for r in contactRows {
    contactsByKey[r.0, default: []].append(DailyCount(dayIndex: r.1, sent: r.2, received: r.3))
}
for (k, _) in contactsByKey {
    contactsByKey[k]?.sort { $0.dayIndex < $1.dayIndex }
}
var groupsByID: [Int64: [DailyCount]] = [:]
for r in groupRows {
    groupsByID[r.0, default: []].append(DailyCount(dayIndex: r.1, sent: r.2, received: r.3))
}
for (k, _) in groupsByID {
    groupsByID[k]?.sort { $0.dayIndex < $1.dayIndex }
}

print("CONTACTS: \(contactsByKey.count), GROUPS: \(groupsByID.count)")

// Binary search helpers.
func lowerBound(_ arr: [DailyCount], target: Int32) -> Int {
    var lo = 0, hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid].dayIndex < target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}
func upperBound(_ arr: [DailyCount], target: Int32) -> Int {
    var lo = 0, hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid].dayIndex <= target { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

// 4. Per-frame recompute — same logic as DashboardAllTimeAggregate.recomputeForRange.
guard let first = dailyOverview.first, let last = dailyOverview.last else { exit(0) }
let firstIdx = Int(first.dayIndex)
let lastIdx = Int(last.dayIndex)
let spanDays = lastIdx - firstIdx

// Warm up.
for i in 0..<5 {
    let _ = i
    let lo = Int32(firstIdx + (spanDays / 10))
    let hi = Int32(firstIdx + (spanDays / 5))
    let l = lowerBound(dailyOverview, target: lo)
    let u = upperBound(dailyOverview, target: hi)
    var s = 0, r = 0
    for j in l..<u { s += Int(dailyOverview[j].sent); r += Int(dailyOverview[j].received) }
    _ = s; _ = r
}

// Real measurement: 300 frames (5 seconds at 60fps).
var samples: [Double] = []
let iterations = 300
for i in 0..<iterations {
    let t = Date()
    let frac = Double(i + 1) / Double(iterations)
    let lo: Int32 = Int32(firstIdx)
    let hi: Int32 = Int32(firstIdx + Int(Double(spanDays) * frac))
    // overview
    let ovL = lowerBound(dailyOverview, target: lo)
    let ovU = upperBound(dailyOverview, target: hi)
    var ovSent = 0, ovRecv = 0
    for j in ovL..<ovU { ovSent += Int(dailyOverview[j].sent); ovRecv += Int(dailyOverview[j].received) }
    // contacts
    var contactTotals: [(String, Int)] = []
    contactTotals.reserveCapacity(contactsByKey.count)
    for (key, arr) in contactsByKey {
        let l = lowerBound(arr, target: lo)
        let u = upperBound(arr, target: hi)
        if l >= u { continue }
        var s = 0, r = 0
        for j in l..<u { s += Int(arr[j].sent); r += Int(arr[j].received) }
        let total = s + r
        if total == 0 { continue }
        contactTotals.append((key, total))
    }
    contactTotals.sort { $0.1 > $1.1 }
    let _ = Array(contactTotals.prefix(12))
    // groups
    var groupTotals: [(Int64, Int)] = []
    groupTotals.reserveCapacity(groupsByID.count)
    for (id, arr) in groupsByID {
        let l = lowerBound(arr, target: lo)
        let u = upperBound(arr, target: hi)
        if l >= u { continue }
        var s = 0
        for j in l..<u { s += Int(arr[j].sent) }
        if s == 0 { continue }
        groupTotals.append((id, s))
    }
    groupTotals.sort { $0.1 > $1.1 }
    let _ = Array(groupTotals.prefix(12))

    samples.append(Date().timeIntervalSince(t) * 1000.0)
}

samples.sort()
let mean = samples.reduce(0, +) / Double(samples.count)
let p95 = samples[Int(Double(samples.count) * 0.95)]
let max = samples.last!
print("RECOMPUTE (\(samples.count) frames): mean \(String(format: "%.3f", mean)) ms · p95 \(String(format: "%.3f", p95)) ms · max \(String(format: "%.3f", max)) ms")

EOF

swift /tmp/dashboard-brush-perf.swift
rm /tmp/dashboard-brush-perf.swift
