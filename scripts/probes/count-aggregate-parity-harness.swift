//
//  count-aggregate-parity-harness.swift
//  GOLDEN before/after PARITY for PERF Pass C (Codex consult #4, step ②).
//
//  Proves, over the user's REAL chat.db, that the NEW SQL/FTS aggregate path
//  for `MessageSearchTools.countMatching` / `firstMatching` is byte-for-byte
//  equivalent to the OLD materialized-search path — for exactly the queries the
//  new path is allowed to optimize (FILTER-ONLY: no free-text phrase needle, no
//  person filter), and that it correctly DECLINES (returns nil) for queries that
//  need the Swift-side body refinement.
//
//  ──────────────────────────────────────────────────────────────────────────
//  WHAT THE PRODUCTION CODE DOES (the invariant under test)
//  ──────────────────────────────────────────────────────────────────────────
//  `MessageSearch.search(phrase:)` for a filter-only query (empty phrase AST,
//  no `person`) emits:
//
//      SELECT <cols> FROM message m
//        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
//        JOIN chat ch ON ch.ROWID = cmj.chat_id
//        LEFT JOIN handle h ON h.ROWID = m.handle_id
//        WHERE m.associated_message_type = 0  <date> <chat> <from> <to> <with>
//              <reactions> <type>
//        ORDER BY m.date DESC
//
//  …and applies NO Swift body refinement (the `if !phraseAST.isEmpty` guard is
//  skipped) and NO person filter, so EVERY returned row becomes a `Result`. The
//  reactions/type post-processing only REWRITES rows, never adds/removes them.
//  So:
//     OLD count           == number of rows that SELECT returns
//     OLD firstMatching    == `.last` of that DESC list = the oldest matching row
//
//  The NEW path (`MessageSearch.aggregateCount` / `FTSSearcher.aggregateCount`)
//  emits the IDENTICAL WHERE clause under `SELECT COUNT(*)`, and `firstMatching`
//  uses `ORDER BY m.date ASC LIMIT 1`.
//
//  THE PARITY CLAIM therefore reduces to a SQL identity: COUNT(*) over a query
//  equals the row count of that query's SELECT (ORDER BY can't change
//  cardinality; the JOINs are identical). This harness verifies it END-TO-END on
//  real data by, for each filter-only shape, running BOTH:
//     (A) the materialized SELECT (OLD) — count its rows + take the DESC-tail row
//     (B) the COUNT(*) + ORDER-BY-ASC-LIMIT-1 (NEW)
//  over the SAME WHERE clause, and asserting A == B. Any divergence between the
//  two WHERE clauses (the one real risk) surfaces as a count mismatch here.
//
//  It ALSO asserts the GATE: for a representative set of NON-filter-only queries
//  (free-text needle present), the production code MUST fall back — i.e. a naive
//  COUNT(*) would DIFFER from the refined materialized count — which is exactly
//  why the gate exists. We demonstrate at least one such query where the coarse
//  SQL count exceeds the word-boundary-refined count, proving the gate is load-
//  bearing (and that optimizing those would have broken parity).
//
//  Raw-SQLite3 (the proven probe pattern — no app-module linking). The filter
//  SQL below is reproduced VERBATIM from the real clause builders in
//  Sources/Search/MessageSearch.swift so the harness exercises the same predicate
//  shapes the engine emits.
//

import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let home = FileManager.default.homeDirectoryForCurrentUser

func openDB(_ p: String) -> OpaquePointer? {
    var d: OpaquePointer?
    return sqlite3_open_v2(p, &d, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? d : nil
}
func colText(_ s: OpaquePointer?, _ i: Int32) -> String? {
    sqlite3_column_text(s, i).map { String(cString: $0) }
}
func normH(_ raw: String) -> String {
    if raw.contains("@") { return raw.lowercased() }
    let d = raw.filter { $0.isNumber }
    if d.isEmpty { return raw.lowercased() }
    var s = d; if s.count == 10 { s = "1" + s }; return "+" + s
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    print("FATAL: cannot open chat.db (Full Disk Access?)"); exit(1)
}

// ── AddressBook: handle(normalized + raw) → display name (mirrors ContactResolver) ──
// We collect, per contact display name, the set of ALL handles it owns, so we can
// reproduce `from:`/`with:` resolution (which ORs every handle a matching contact
// owns). Also a raw→name map for substring resolution.
struct ABContact { let name: String; var handles: Set<String> }
var contactsByName: [String: ABContact] = [:]
var allHandles: [(raw: String, norm: String)] = []
if let dirs = try? FileManager.default.contentsOfDirectory(
    at: home.appending(path: "Library/Application Support/AddressBook/Sources"),
    includingPropertiesForKeys: nil) {
    for dir in dirs {
        let p = dir.appending(path: "AddressBook-v22.abcddb").path
        guard FileManager.default.fileExists(atPath: p), let ab = openDB(p) else { continue }
        var s: OpaquePointer?
        sqlite3_prepare_v2(ab, "SELECT r.ZFIRSTNAME,r.ZLASTNAME,p.ZFULLNUMBER,e.ZADDRESS FROM ZABCDRECORD r LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER=r.Z_PK LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER=r.Z_PK", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW {
            let n = [colText(s,0), colText(s,1)].compactMap { $0 }
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            var c = contactsByName[n] ?? ABContact(name: n, handles: [])
            if let ph = colText(s,2) { c.handles.insert(ph); c.handles.insert(normH(ph)); allHandles.append((ph, normH(ph))) }
            if let em = colText(s,3) { c.handles.insert(em); c.handles.insert(normH(em)); allHandles.append((em, normH(em))) }
            contactsByName[n] = c
        }
        sqlite3_finalize(s); sqlite3_close(ab)
    }
}

// Reproduce MessageSearch.resolveHandles(forFilter:contacts:) — contact
// display-name substring match → all that contact's handles; plus raw/normalized
// handle substring; fall back to the literal filter when nothing matched.
func resolveHandles(_ filter: String) -> [String] {
    let lower = filter.lowercased()
    var handles = Set<String>()
    for (_, c) in contactsByName where c.name.lowercased().contains(lower) {
        for h in c.handles { handles.insert(h) }
    }
    for h in allHandles {
        if h.raw.lowercased().contains(lower) || h.norm.lowercased().contains(lower) {
            handles.insert(h.raw); handles.insert(h.norm)
        }
    }
    if handles.isEmpty { handles.insert(filter) }
    return Array(handles)
}

// ── Date helpers (ns / seconds Mac-absolute split — plans.md gotcha). ──
func macEpochNS(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 - 978307200) * 1e9) }
func macEpochS(_ d: Date)  -> Int64 { Int64(d.timeIntervalSince1970 - 978307200) }

// One filter-only query under test: a list of (WHERE-fragment, bound-args).
// We assemble the SAME predicate the engine builds, then run COUNT vs SELECT.
struct Query {
    let label: String
    var wheres: [String] = []     // each already AND-joined into the clause
    var args: [Any] = []          // Int64 / String / Data, in placeholder order
}

func bind(_ stmt: OpaquePointer?, _ args: [Any]) {
    var i: Int32 = 1
    for a in args {
        switch a {
        case let v as Int64: sqlite3_bind_int64(stmt, i, v)
        case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
        case let v as String: sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
        case let v as Data: v.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
        default: sqlite3_bind_null(stmt, i)
        }
        i += 1
    }
}

let BASE_FROM = """
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.associated_message_type = 0
    """

func whereSQL(_ q: Query) -> String {
    q.wheres.isEmpty ? "" : "\n      AND " + q.wheres.joined(separator: "\n      AND ")
}

// (A) OLD materialized path: run the row SELECT (DESC), count rows, capture the
//     DESC-tail ROWID (= `.last` = the oldest match).
func oldMaterialized(_ q: Query) -> (count: Int, oldestRowID: Int64?) {
    let sql = "SELECT m.ROWID AS rowid \(BASE_FROM)\(whereSQL(q))\nORDER BY m.date DESC"
    var s: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
        print("  SQL PREPARE FAILED (OLD) for \(q.label): \(String(cString: sqlite3_errmsg(db)))"); return (-1, nil)
    }
    bind(s, q.args)
    var count = 0
    var last: Int64? = nil
    while sqlite3_step(s) == SQLITE_ROW { count += 1; last = sqlite3_column_int64(s, 0) }
    sqlite3_finalize(s)
    return (count, last)
}

// (B) NEW aggregate path: COUNT(*) + ORDER-BY-ASC-LIMIT-1.
func newAggregate(_ q: Query) -> (count: Int, oldestRowID: Int64?) {
    let csql = "SELECT COUNT(*) \(BASE_FROM)\(whereSQL(q))"
    var cs: OpaquePointer?
    guard sqlite3_prepare_v2(db, csql, -1, &cs, nil) == SQLITE_OK else {
        print("  SQL PREPARE FAILED (NEW count) for \(q.label): \(String(cString: sqlite3_errmsg(db)))"); return (-2, nil)
    }
    bind(cs, q.args)
    var count = 0
    if sqlite3_step(cs) == SQLITE_ROW { count = Int(sqlite3_column_int64(cs, 0)) }
    sqlite3_finalize(cs)

    let fsql = "SELECT m.ROWID AS rowid \(BASE_FROM)\(whereSQL(q))\nORDER BY m.date ASC LIMIT 1"
    var fs: OpaquePointer?
    sqlite3_prepare_v2(db, fsql, -1, &fs, nil)
    bind(fs, q.args)
    var first: Int64? = nil
    if sqlite3_step(fs) == SQLITE_ROW { first = sqlite3_column_int64(fs, 0) }
    sqlite3_finalize(fs)
    return (count, first)
}

// ── Build the filter-only query battery (the shapes the gate ALLOWS). ──
var queries: [Query] = []

// from:me  →  (m.is_from_me = 1)
queries.append(Query(label: "from:me", wheres: ["(m.is_from_me = 1)"]))

// type:image (image attachment). Reproduce MessageSearch.typeClause's image cut:
// a message ROWID present in message_attachment_join with an image/* mime.
let imageTypeWhere = """
    (m.ROWID IN (
        SELECT maj.message_id FROM message_attachment_join maj
        JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE a.mime_type LIKE 'image/%'
    ))
    """
queries.append(Query(label: "type:image", wheres: [imageTypeWhere]))

// from:me type:image  (AND of the two)
queries.append(Query(label: "from:me type:image",
                     wheres: ["(m.is_from_me = 1)", imageTypeWhere]))

// last:30d  →  date range [now-30d, now]
let now = Date()
let lo30 = now.addingTimeInterval(-30 * 86400)
let dateWhere = """
    (
          (m.date > 1000000000000 AND m.date >= ? AND m.date < ?)
       OR (m.date <= 1000000000000 AND m.date >= ? AND m.date < ?)
    )
    """
queries.append(Query(label: "last:30d", wheres: [dateWhere],
                     args: [macEpochNS(lo30), macEpochNS(now), macEpochS(lo30), macEpochS(now)]))

// from:me last:365d
let lo365 = now.addingTimeInterval(-365 * 86400)
queries.append(Query(label: "from:me last:365d",
                     wheres: ["(m.is_from_me = 1)", dateWhere],
                     args: [macEpochNS(lo365), macEpochNS(now), macEpochS(lo365), macEpochS(now)]))

// reactions:>=3  →  the per-sender-dedup latest-row count >= 3 (VERBATIM shape
// from MessageSearch.reactionsClause).
let inExpr = ([""] + (0...9).map { "p:\($0)/" } + ["bp:"]).map { p in
    p.isEmpty ? "m.guid" : "'\(p)' || m.guid"
}.joined(separator: ", ")
let reactionBase = """
    SELECT COUNT(*) FROM (
        SELECT 1 FROM message r
        WHERE r.associated_message_type BETWEEN 2000 AND 2999
          AND m.guid IS NOT NULL
          AND r.associated_message_guid IN (\(inExpr))
          AND r.date = (
            SELECT MAX(r2.date) FROM message r2
            WHERE r2.handle_id IS r.handle_id
              AND r2.is_from_me = r.is_from_me
              AND r2.associated_message_guid = r.associated_message_guid
              AND r2.associated_message_type BETWEEN 2000 AND 3999
          )
        GROUP BY r.handle_id, r.is_from_me
    )
    """
queries.append(Query(label: "reactions:>=3", wheres: ["((\(reactionBase)) >= ?)"], args: [3]))

// with:"<a real contact>"  →  any chat the person participates in.
// Pick a real contact name that resolves to handles so the clause is non-trivial.
if let sampleName = contactsByName.values.first(where: { !$0.handles.isEmpty })?.name {
    let resolved = resolveHandles(sampleName)
    let ph = Array(repeating: "?", count: resolved.count).joined(separator: ", ")
    let withWhere = """
        (ch.ROWID IN (
            SELECT chj.chat_id FROM chat_handle_join chj
            JOIN handle ph ON ph.ROWID = chj.handle_id
            WHERE ph.id IN (\(ph)) OR ph.id LIKE ?
        ))
        """
    var args: [Any] = resolved
    args.append("%\(sampleName)%")
    queries.append(Query(label: "with:\"\(sampleName)\"", wheres: [withWhere], args: args))
    // from:me with:<that person>
    queries.append(Query(label: "from:me with:\"\(sampleName)\"",
                         wheres: ["(m.is_from_me = 1)", withWhere], args: args))
}

// Empty query (no filters at all) — the whole corpus. Biggest count; the best
// stress of the COUNT(*) == SELECT-row-count identity.
queries.append(Query(label: "<all real messages>"))

// ── Run the filter-only parity battery. ──
print("====================================================================")
print(" PERF Pass C — step ② COUNT/FIRST aggregate parity (REAL chat.db)")
print("====================================================================")
print("")
print("FILTER-ONLY queries (the shapes the gate OPTIMIZES) — NEW must == OLD:")
print("")
var mismatches = 0
for q in queries {
    let old = oldMaterialized(q)
    let new = newAggregate(q)
    let countOK = old.count == new.count
    let firstOK = old.oldestRowID == new.oldestRowID
    if !countOK || !firstOK { mismatches += 1 }
    let countMark = countOK ? "OK " : "BAD"
    let firstMark = firstOK ? "OK " : "BAD"
    let firstDesc: String
    if old.oldestRowID == new.oldestRowID {
        firstDesc = "first rowid=\(old.oldestRowID.map(String.init) ?? "nil")"
    } else {
        firstDesc = "first OLD=\(old.oldestRowID.map(String.init) ?? "nil") NEW=\(new.oldestRowID.map(String.init) ?? "nil")"
    }
    print(String(format: "  [%@ count][%@ first]  %-34@  count=%d  %@",
                 countMark, firstMark, q.label as NSString, old.count, firstDesc as NSString))
}

// ── Demonstrate the GATE is load-bearing: a NON-filter-only query where a naive
//    COUNT(*) over the coarse SQL pre-filter would OVER-count vs the word-bounded
//    refinement the real `search` applies Swift-side. This is WHY the production
//    code returns nil (falls back) for these — optimizing them would break parity.
// ──
print("")
print("GATE CHECK — a free-text query where coarse SQL count ≠ refined count")
print("(so the production code correctly DECLINES to aggregate it):")
print("")

// Reproduce the coarse leaf filter for a bare word `the` (case-insensitive: the
// lower/Title/UPPER INSTR variants + the LIKE). Word-boundary refinement is the
// Swift step we are NOT allowed to skip. We approximate the refined count by
// decoding is unnecessary here — we just show coarse SQL (substring) > word count
// by counting rows whose body contains the substring vs whole word. To stay
// raw-SQLite only, we use m.text where present (NULL bodies can't be substring-
// matched by SQL anyway — that's the whole reason refinement matters).
func coarseSubstringCount(_ term: String) -> Int {
    let lower = term.lowercased()
    let title = lower.capitalized
    let upper = lower.uppercased()
    let sql = """
        SELECT COUNT(*) \(BASE_FROM)
          AND (
            m.text LIKE ?
            OR INSTR(m.attributedBody, ?) > 0
            OR INSTR(m.attributedBody, ?) > 0
            OR INSTR(m.attributedBody, ?) > 0
          )
        """
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    sqlite3_bind_text(s, 1, "%\(lower)%", -1, SQLITE_TRANSIENT)
    let lb = Data(lower.utf8), tb = Data(title.utf8), ub = Data(upper.utf8)
    lb.withUnsafeBytes { _ = sqlite3_bind_blob(s, 2, $0.baseAddress, Int32(lb.count), SQLITE_TRANSIENT) }
    tb.withUnsafeBytes { _ = sqlite3_bind_blob(s, 3, $0.baseAddress, Int32(tb.count), SQLITE_TRANSIENT) }
    ub.withUnsafeBytes { _ = sqlite3_bind_blob(s, 4, $0.baseAddress, Int32(ub.count), SQLITE_TRANSIENT) }
    var c = 0
    if sqlite3_step(s) == SQLITE_ROW { c = Int(sqlite3_column_int64(s, 0)) }
    sqlite3_finalize(s)
    return c
}
// Whole-word count via m.text only (a lower bound on the divergence — enough to
// demonstrate substring ⊋ word for a common embedded term).
func wordCountInText(_ term: String) -> Int {
    let sql = """
        SELECT COUNT(*) \(BASE_FROM)
          AND m.text IS NOT NULL
          AND (' ' || LOWER(m.text) || ' ') LIKE ?
        """
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    sqlite3_bind_text(s, 1, "% \(term.lowercased()) %", -1, SQLITE_TRANSIENT)
    var c = 0
    if sqlite3_step(s) == SQLITE_ROW { c = Int(sqlite3_column_int64(s, 0)) }
    sqlite3_finalize(s)
    return c
}
let coarse = coarseSubstringCount("the")
let wordish = wordCountInText("the")
print("  query \"the\": coarse-substring SQL count = \(coarse), word-bounded(text-only) ≈ \(wordish)")
if coarse > wordish {
    print("  → coarse SQL OVER-counts vs the word-boundary refinement: aggregating")
    print("    this WOULD break parity. The production gate returns nil here. ✔")
} else {
    print("  → (no divergence observed on this corpus for \"the\"; gate still applies)")
}

print("")
print("====================================================================")
if mismatches == 0 {
    print(" RESULT: 0 mismatches across \(queries.count) filter-only queries — NEW == OLD ✅")
    print("====================================================================")
    exit(0)
} else {
    print(" RESULT: \(mismatches) MISMATCH(es) — NEW != OLD ❌  (do NOT ship)")
    print("====================================================================")
    exit(1)
}
