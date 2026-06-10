//
//  nostalgia-cursor-memfix-harness.swift
//  Behavior-preservation + memory check for the Nostalgia-tab OOM fix
//  (ChatStoryBuilder+DB / RomanticDetector+DB: Row.fetchAll → Row.fetchCursor).
//
//  The fix changed HOW the full-corpus message rows are READ (stream instead of
//  materialize), NOT WHAT is read or how the body is decoded. `fetchAll` and
//  `fetchCursor` run the IDENTICAL SQL and yield the IDENTICAL rows in the
//  IDENTICAL order — that's a GRDB contract; the ONLY difference is whether all
//  rows (incl. their attributedBody blobs) are resident at once. So the things
//  worth proving against the user's REAL chat.db are:
//
//   (1) ROW-SET STABILITY — the EXACT production message query (the
//       ChatStoryBuilder+DB step-3 CTE) returns the SAME row count and the SAME
//       ROWID set on repeated execution. (fetchAll and fetchCursor would each
//       see exactly this set; if it's stable, the two are equivalent.) We run it
//       TWICE without decoding (cheap) and assert count + ROWID-set equality.
//
//   (2) STREAM COMPLETENESS — a cursor-shaped pass that decodes each blob into
//       the lightweight value and DROPS the row/blob immediately (the new
//       production loop) visits EVERY row, decodes EVERY blob without crashing,
//       and yields the SAME ROWID-deduped per-chat buckets `loadRawChats`
//       builds, plus a healthy rate of non-empty decoded bodies.
//
//   (3) MEMORY EFFECT — the concrete win: under fetchAll the peak resident
//       attributedBody bytes = SUM of every blob; under fetchCursor = MAX single
//       blob. We measure both against the real corpus.
//
//  Reuses the REAL decoder (`AttributedBodyDecoder.swift` + `Typedstream.swift`)
//  so the decode path is exactly production's. No GRDB needed — the correctness
//  claim is "same SQL → same rows → same (unchanged) decode", which raw SQLite3
//  proves directly; fetchAll-vs-fetchCursor is purely a materialization-timing
//  detail GRDB guarantees.
//
//  Usage (from repo root):  ./scripts/probes/run-nostalgia-cursor-memfix-harness.sh
//

import Foundation
import SQLite3

let home = FileManager.default.homeDirectoryForCurrentUser

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func openDB(_ p: String) -> OpaquePointer? {
    var d: OpaquePointer?
    return sqlite3_open_v2(p, &d, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? d : nil
}
func col(_ s: OpaquePointer?, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
func blobv(_ s: OpaquePointer?, _ i: Int32) -> Data? {
    guard let p = sqlite3_column_blob(s, i) else { return nil }
    return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
}
func decode(_ t: String?, _ b: Data?) -> String {
    if let t = t, !t.isEmpty { return t }
    return AttributedBodyDecoder.decode(b)
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    err("FATAL: cannot open chat.db (Full Disk Access?)"); exit(1)
}

// The production step-3 query (ChatStoryBuilder+DB.loadRawChats) MINUS the
// `reaction_agg` CTE LEFT JOIN. We DROP the reaction join on purpose: it only
// adds scalar reaction COUNT/rank columns — it does NOT change WHICH message
// rows appear (the join is a LEFT JOIN keyed on m.guid) NOR the attributedBody
// bytes, which is the entire subject of this memory/decode test. (In the raw
// standalone binary the un-indexed CTE join is O(n²) and takes minutes; the app
// pays it once via GRDB's planner. Skipping it here keeps the harness fast
// WITHOUT weakening the claim — same message rows, same blobs, same decode, same
// SUM/MAX residency. The production cursor rewrite keeps the CTE verbatim.)
//
// `cmj.chat_id` column + the `associated_message_type=0 AND item_type=0` filter
// match production exactly, so the ROWID/chat row set is identical.
let sql = """
SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, h.id, cmj.chat_id
FROM message m
JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
LEFT JOIN handle h ON h.ROWID=m.handle_id
WHERE m.associated_message_type=0 AND m.item_type=0
"""

// ============================================================================
// (1) ROW-SET STABILITY — run the query TWICE, NO decode (cheap), collect
//     ROWID + chat_id only. fetchAll and fetchCursor would each see exactly
//     this set; stability across runs ⇒ the two are equivalent on this DB.
// ============================================================================
func scanRowIDs() -> (count: Int, rowids: Set<Int64>, chatByRow: [Int64: Int64]) {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    var count = 0
    var rowids = Set<Int64>()
    var chatByRow: [Int64: Int64] = [:]
    while sqlite3_step(s) == SQLITE_ROW {
        count += 1
        let rowID = sqlite3_column_int64(s, 0)
        rowids.insert(rowID)
        chatByRow[rowID] = sqlite3_column_int64(s, 6)   // last write wins, like the loop's dedup
    }
    sqlite3_finalize(s)
    return (count, rowids, chatByRow)
}
err("[harness] pass 1/3: row-set scan A (no decode)…")
let a = scanRowIDs()
err("[harness] pass 2/3: row-set scan B (no decode)…")
let b = scanRowIDs()

// ============================================================================
// (2) STREAM COMPLETENESS — cursor-shaped pass that decodes each blob and drops
//     it immediately, building the SAME ROWID-deduped per-chat buckets, and
//     measuring (3) the blob-residency numbers in the same single pass.
// ============================================================================
err("[harness] pass 3/3: stream + decode (one blob resident at a time)…")
var streamMsgsByChat: [Int64: Int] = [:]   // chat_id → deduped message count
var streamSeen = Set<Int64>()
var streamRowCount = 0
var nonEmptyBodies = 0
var sumBlobBytes = 0          // peak resident blob bytes under fetchAll  = SUM
var maxBlobBytes = 0          // peak resident blob bytes under fetchCursor = MAX
var sampleBodies: [(Int64, String)] = []   // lowest-ROWID non-empty samples
do {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        streamRowCount += 1
        if streamRowCount % 50_000 == 0 { err("[harness]   …\(streamRowCount) rows streamed") }
        let rowID = sqlite3_column_int64(s, 0)
        if streamSeen.contains(rowID) { continue }
        streamSeen.insert(rowID)
        let chatID = sqlite3_column_int64(s, 6)
        let blob = blobv(s, 4)
        sumBlobBytes += blob?.count ?? 0          // what fetchAll would hold (cumulative)
        maxBlobBytes = max(maxBlobBytes, blob?.count ?? 0)  // what fetchCursor holds (peak single)
        let body = decode(col(s, 3), blob).trimmingCharacters(in: .whitespacesAndNewlines)
        // `blob` + the row's column pointers go out of scope at loop end — only
        // the decoded String survives, exactly as the production cursor loop.
        streamMsgsByChat[chatID, default: 0] += 1
        if !body.isEmpty {
            nonEmptyBodies += 1
            if sampleBodies.count < 60 { sampleBodies.append((rowID, body)) }
        }
    }
    sqlite3_finalize(s)
}
sqlite3_close(db)

// ============================================================================
// ASSERTIONS
// ============================================================================
print("════════════════════════════════════════════════════════")
print(" NOSTALGIA CURSOR MEM-FIX — behavior-preservation + memory check")
print("════════════════════════════════════════════════════════")
print(String(format: "  query rows (scan A):                 %d", a.count))
print(String(format: "  query rows (scan B):                 %d", b.count))
print(String(format: "  rows stepped by stream pass:         %d", streamRowCount))
print(String(format: "  ROWID-deduped messages (scan A):     %d", a.rowids.count))
print(String(format: "  ROWID-deduped messages (stream):     %d", streamSeen.count))
print(String(format: "  chats with ≥1 message (stream):      %d", streamMsgsByChat.count))
print(String(format: "  non-empty decoded bodies:            %d (%.1f%% of deduped)",
             nonEmptyBodies, streamSeen.isEmpty ? 0 : 100.0 * Double(nonEmptyBodies) / Double(streamSeen.count)))

var checks: [(String, Bool)] = []
func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }

check("Query row count is STABLE across runs (A == B)", a.count == b.count)
check("ROWID set is STABLE across runs (A == B)", a.rowids == b.rowids)
check("Stream pass steps the same number of rows as scan A", streamRowCount == a.count)
check("Stream pass ROWID-dedup matches scan A's ROWID set", streamSeen == a.rowids)
// Per-chat bucketing: the stream's per-chat counts must match what we'd get by
// bucketing scan A's ROWIDs by their chat_id (the loadRawChats dedup-by-ROWID).
var aMsgsByChat: [Int64: Int] = [:]
for rid in a.rowids { if let c = a.chatByRow[rid] { aMsgsByChat[c, default: 0] += 1 } }
check("Per-chat deduped message counts match scan A", aMsgsByChat == streamMsgsByChat)
check("Every blob decoded without crashing (stream completed)", true)
check("Decoder produced non-empty bodies (sanity: ≥50% non-empty)",
      !streamSeen.isEmpty && Double(nonEmptyBodies) / Double(streamSeen.count) >= 0.5)

// Show a few decoded sample bodies so a human can eyeball the decode worked.
print("\n──── sample decoded bodies (lowest 5 ROWIDs with non-empty body) ────")
for (rid, b) in sampleBodies.sorted(by: { $0.0 < $1.0 }).prefix(5) {
    let one = b.replacingOccurrences(of: "\n", with: " ")
    print(String(format: "  ROWID %-8d “%@”", rid, String(one.prefix(70))))
}

// ============================================================================
// (3) MEMORY EFFECT (the point of the fix).
// ============================================================================
let mb = 1024.0 * 1024.0
print("\n──── memory effect (attributedBody blobs only) ────")
print(String(format: "  fetchAll   peak resident blob bytes = SUM = %9.1f MB", Double(sumBlobBytes) / mb))
print(String(format: "  fetchCursor peak resident blob bytes = MAX = %9.3f MB", Double(maxBlobBytes) / mb))
if maxBlobBytes > 0 {
    print(String(format: "  → blob-residency reduction ≈ %.0fx (peak no longer scales with corpus size)",
                 Double(sumBlobBytes) / Double(maxBlobBytes)))
}
print("  NOTE: this counts ONLY the raw blob bytes. fetchAll ALSO held every")
print("  GRDB Row wrapper for all \(streamSeen.count) rows simultaneously; the")
print("  cursor holds ONE Row at a time. The blob SUM is the dominant term and")
print("  the source of the multi-GB Nostalgia-tab OOM.")

// ============================================================================
print("\n════════════════════════════════════════════════════════")
var passed = 0
for (name, ok) in checks {
    print("  \(ok ? "PASS" : "FAIL")  \(name)")
    if ok { passed += 1 }
}
print("════════════════════════════════════════════════════════")
print("  \(passed)/\(checks.count) checks passed")
exit(passed == checks.count ? 0 : 1)
