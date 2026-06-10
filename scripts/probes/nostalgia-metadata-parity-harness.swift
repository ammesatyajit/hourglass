//
//  nostalgia-metadata-parity-harness.swift
//  GOLDEN before/after PARITY for PERF Pass B (Codex consult #4, steps ④+⑤).
//
//  Compiles the REAL pure builder (`ChatStoryBuilder.swift` +
//  `NostalgiaMomentModels.swift`), the REAL romantic core (`RomanticDetector.swift`),
//  and the REAL typedstream decoder against a raw-SQLite3 scan of the user's
//  REAL chat.db, then diffs:
//
//   PART 1 — ChatStory: OLD path (decode the FULL corpus body for every row)
//     vs NEW path (metadata-only RawMessages with EMPTY bodies + targeted
//     `WHERE ROWID IN (...)` hydration of ONLY origin + peak-candidate rows).
//     Both feed the SAME pure `ChatStoryBuilder.buildStories`. Asserts the two
//     story sets are IDENTICAL: same chats, same per-chat moments (kind +
//     example body + dates + headline + person + id). 0 mismatches required.
//
//   PART 2 — Romantic: OLD sequential `accumulate` fold vs NEW parallel striped
//     fold (DispatchQueue.concurrentPerform) over the EXACT same 1:1 corpus
//     rows. Asserts the flagged-contact-name SET is IDENTICAL. 0 mismatches.
//
//  Also reports the DECODE-COUNT reduction: full-corpus decodes (OLD) vs only
//  the hydrated origin+peak rows (NEW).
//

import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let home = FileManager.default.homeDirectoryForCurrentUser

func openDB(_ p: String) -> OpaquePointer? {
    var d: OpaquePointer?
    return sqlite3_open_v2(p, &d, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? d : nil
}
func col(_ s: OpaquePointer?, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
func blobv(_ s: OpaquePointer?, _ i: Int32) -> Data? {
    guard let p = sqlite3_column_blob(s, i) else { return nil }
    return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
}
func normH(_ raw: String) -> String {
    if raw.contains("@") { return raw.lowercased() }
    let d = raw.filter { $0.isNumber }
    if d.isEmpty { return raw.lowercased() }
    var s = d; if s.count == 10 { s = "1" + s }; return "+" + s
}

// ---- AddressBook: handle(normalized) -> display name (mirrors ContactResolver) ----
var nameByHandle: [String: String] = [:]
if let dirs = try? FileManager.default.contentsOfDirectory(
    at: home.appending(path: "Library/Application Support/AddressBook/Sources"),
    includingPropertiesForKeys: nil) {
    for dir in dirs {
        let p = dir.appending(path: "AddressBook-v22.abcddb").path
        guard FileManager.default.fileExists(atPath: p), let ab = openDB(p) else { continue }
        var s: OpaquePointer?
        sqlite3_prepare_v2(ab, "SELECT r.ZFIRSTNAME,r.ZLASTNAME,p.ZFULLNUMBER,e.ZADDRESS FROM ZABCDRECORD r LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER=r.Z_PK LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER=r.Z_PK", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW {
            let n = [col(s,0), col(s,1)].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            if let ph = col(s,2) { nameByHandle[normH(ph)] = n }
            if let em = col(s,3) { nameByHandle[normH(em)] = n }
        }
        sqlite3_finalize(s); sqlite3_close(ab)
    }
}
let alias: [String: String] = ["vchitturi9@gmail.com": "Venkat Chitturi"]
func nameFor(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "(unknown)" }
    if let a = alias[raw.lowercased()] { return a }
    return nameByHandle[normH(raw)] ?? raw
}
// A "resolved contact" for the romantic path requires a real AddressBook hit.
func resolvedContactName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    if let a = alias[raw.lowercased()] { return a }
    return nameByHandle[normH(raw)]
}
func decodeBody(_ t: String?, _ b: Data?) -> String {
    if let t = t, !t.isEmpty { return t }
    return AttributedBodyDecoder.decode(b)
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    print("FATAL: cannot open chat.db (Full Disk Access?)"); exit(1)
}
let cal = Calendar.current
let CFG_MIN_MESSAGES = 200
let CFG_MIN_PEAK = 2

// ============================================================================
// Shared metadata (chat + participants) — identical for both paths.
// ============================================================================
struct Meta { let id: Int64; let style: Int; let display: String; var parts: [String] }
var metaByID: [Int64: Meta] = [:]
do {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT ROWID, style, COALESCE(display_name,'') FROM chat", -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let id = sqlite3_column_int64(s, 0)
        metaByID[id] = Meta(id: id, style: Int(sqlite3_column_int(s, 1)), display: col(s, 2) ?? "", parts: [])
    }
    sqlite3_finalize(s)
}
do {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id", -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let cid = sqlite3_column_int64(s, 0)
        if let h = col(s, 1) { metaByID[cid]?.parts.append(h) }
    }
    sqlite3_finalize(s)
}

func macDate(_ raw: Int64) -> Date {
    Date(timeIntervalSince1970: (raw > 1_000_000_000_000 ? Double(raw)/1e9 : Double(raw)) + 978307200)
}
func glyph(_ rank: Int?) -> String {
    switch rank { case 1: return "❤️"; case 2: return "😂"; case 3: return "‼️"
    case 4: return "👍"; case 5: return "❓"; case 6: return "🏷️"; default: return "❤️" }
}

// ============================================================================
// PART 1 — ChatStory parity.
// ============================================================================
// The message CTE (identical SQL for both; OLD path also pulls text+blob).
let MSG_SQL = """
WITH reaction_agg AS (
    SELECT CASE WHEN instr(r.associated_message_guid,'/')>0
                THEN substr(r.associated_message_guid, instr(r.associated_message_guid,'/')+1)
                ELSE r.associated_message_guid END AS target_guid,
           COUNT(*) AS rx_count,
           MIN(CASE r.associated_message_type
                 WHEN 2000 THEN 1 WHEN 2003 THEN 2 WHEN 2004 THEN 3 WHEN 2001 THEN 4
                 WHEN 2005 THEN 5 WHEN 2007 THEN 6 WHEN 2006 THEN 7 ELSE 9 END) AS warm_rank
    FROM message r
    WHERE r.associated_message_type BETWEEN 2000 AND 2007 AND r.associated_message_guid IS NOT NULL
    GROUP BY target_guid )
SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody, h.id, cmj.chat_id,
       COALESCE(ra.rx_count,0), ra.warm_rank
FROM message m
JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
LEFT JOIN handle h ON h.ROWID=m.handle_id
LEFT JOIN reaction_agg ra ON ra.target_guid=m.guid
WHERE m.associated_message_type=0 AND m.item_type=0
"""

// Two variants of msgsByChat: OLD (full body) and NEW (empty body until hydrate).
// Build them in ONE cursor pass to guarantee identical row order & dedup.
var msgsByChatOLD: [Int64: [ChatStoryBuilder.RawMessage]] = [:]
var msgsByChatNEW: [Int64: [ChatStoryBuilder.RawMessage]] = [:]
// Capture each row's (text, blob) by ROWID for the NEW path's targeted hydration.
var textByRow: [Int64: String?] = [:]
var blobByRow: [Int64: Data?] = [:]
var fullCorpusRows = 0
do {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, MSG_SQL, -1, &s, nil)
    var seen = Set<Int64>()
    while sqlite3_step(s) == SQLITE_ROW {
        let row = sqlite3_column_int64(s, 0)
        if seen.contains(row) { continue }; seen.insert(row)
        fullCorpusRows += 1
        let cid = sqlite3_column_int64(s, 6)
        let date = macDate(sqlite3_column_int64(s, 1))
        let fm = sqlite3_column_int(s, 2) == 1
        let t = col(s, 3); let b = blobv(s, 4)
        let sender = fm ? "You" : nameFor(col(s, 5))
        let rx = Int(sqlite3_column_int(s, 7))
        let warm: Int? = sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 8))
        let topGlyph = rx > 0 ? glyph(warm) : nil
        // OLD: decode every body up front.
        let oldBody = decodeBody(t, b).trimmingCharacters(in: .whitespacesAndNewlines)
        msgsByChatOLD[cid, default: []].append(.init(
            rowID: row, date: date, isFromMe: fm, senderName: sender, body: oldBody,
            reactionCount: rx, topReactionEmoji: topGlyph))
        // NEW: empty body now; stash raw text/blob for targeted hydration.
        msgsByChatNEW[cid, default: []].append(.init(
            rowID: row, date: date, isFromMe: fm, senderName: sender, body: "",
            reactionCount: rx, topReactionEmoji: topGlyph))
        textByRow[row] = t; blobByRow[row] = b
    }
    sqlite3_finalize(s)
}

// Events (identical SQL; no body involved).
var eventsByChat: [Int64: [ChatStoryBuilder.RawEvent]] = [:]
do {
    let sql = """
    SELECT DISTINCT m.ROWID, m.date, m.item_type, m.group_action_type, m.group_title,
           m.is_from_me, actor.id, other.id, cmj.chat_id
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
    LEFT JOIN handle actor ON actor.ROWID=m.handle_id
    LEFT JOIN handle other ON other.ROWID=m.other_handle
    WHERE m.item_type IN (1,3) ORDER BY m.date ASC
    """
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    var seen = Set<Int64>()
    while sqlite3_step(s) == SQLITE_ROW {
        let row = sqlite3_column_int64(s, 0)
        if seen.contains(row) { continue }; seen.insert(row)
        let cid = sqlite3_column_int64(s, 8)
        let date = macDate(sqlite3_column_int64(s, 1))
        let itype = Int(sqlite3_column_int(s, 2))
        let fm = sqlite3_column_int(s, 5) == 1
        let actor = fm ? "You" : nameFor(col(s, 6))
        let other = col(s, 7).map { nameFor($0) } ?? "?"
        if itype == 3 {
            let title = col(s, 4) ?? ""
            guard !title.isEmpty else { continue }
            eventsByChat[cid, default: []].append(.init(rowID: row, date: date, actor: actor, kind: .renamed(title: title)))
        } else {
            let gat = Int(sqlite3_column_int(s, 3))
            if gat == 1 {
                eventsByChat[cid, default: []].append(.init(rowID: row, date: date, actor: actor, kind: .removed(person: other)))
            } else {
                guard other != "?" && other != actor else { continue }
                eventsByChat[cid, default: []].append(.init(rowID: row, date: date, actor: actor, kind: .added(person: other)))
            }
        }
    }
    sqlite3_finalize(s)
}

// Assemble (the +DB merge logic — identical for both, parameterized on the
// per-chat message map so OLD/NEW share the exact same code path).
func participantListTitle(_ handles: [String]) -> String {
    let names = handles.map { nameFor($0) }.filter { !$0.isEmpty && $0 != "(unknown)" }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    guard !names.isEmpty else { return "Group chat" }
    let shown = names.prefix(3).map { $0.components(separatedBy: " ").first ?? $0 }
    return names.count > 3 ? shown.joined(separator: ", ") + " +\(names.count - 3)" : shown.joined(separator: ", ")
}
struct Bucket {
    var primary: Int64; var firstDate: Date; var isGroup: Bool; var title: String
    var parts: Set<String>; var msgs: [ChatStoryBuilder.RawMessage]; var evs: [ChatStoryBuilder.RawEvent]
}
func assemble(_ msgsByChat: [Int64: [ChatStoryBuilder.RawMessage]]) -> [ChatStoryBuilder.RawChat] {
    var buckets: [String: Bucket] = [:]
    for id in metaByID.keys.sorted() {
        guard let meta = metaByID[id] else { continue }
        let msgs = msgsByChat[id] ?? []
        let evs = eventsByChat[id] ?? []
        let isGroup = meta.style == 43
        let key: String; var title: String
        if isGroup {
            if !meta.display.isEmpty { key = "g:\(meta.display)"; title = meta.display }
            else { key = "u:\(id)"; title = participantListTitle(meta.parts) }
        } else {
            let name = nameFor(meta.parts.first)
            key = "p:\(name)"; title = name
        }
        let firstDate = msgs.map(\.date).min() ?? Date.distantFuture
        if var b = buckets[key] {
            b.msgs.append(contentsOf: msgs); b.evs.append(contentsOf: evs); b.parts.formUnion(meta.parts)
            if firstDate < b.firstDate { b.firstDate = firstDate; b.primary = id }
            if b.title.isEmpty { b.title = title }
            buckets[key] = b
        } else {
            buckets[key] = Bucket(primary: id, firstDate: firstDate, isGroup: isGroup, title: title,
                                  parts: Set(meta.parts), msgs: msgs, evs: evs)
        }
    }
    var rawChats: [ChatStoryBuilder.RawChat] = []
    for (_, b) in buckets {
        guard b.msgs.count >= CFG_MIN_MESSAGES else { continue }
        var seen = Set<Int64>()
        let dedup = b.evs.filter { seen.insert($0.rowID).inserted }
        rawChats.append(.init(chatRowID: b.primary, title: b.title, isGroup: b.isGroup,
                              participantCount: max(b.parts.count, 1), avatarData: nil,
                              messages: b.msgs, events: dedup))
    }
    return rawChats
}

let rawOLD = assemble(msgsByChatOLD)
let rawNEWunhydrated = assemble(msgsByChatNEW)

// NEW PHASE 2 — targeted hydration: mirror ChatStoryBuilder+DB.hydrateExampleBodies.
var neededRowIDs = Set<Int64>()
for chat in rawNEWunhydrated {
    guard chat.messages.count >= CFG_MIN_MESSAGES else { continue }
    if let minDate = chat.messages.map(\.date).min() {
        for m in chat.messages where m.date == minDate { neededRowIDs.insert(m.rowID) }
    }
    for m in chat.messages where m.reactionCount >= CFG_MIN_PEAK { neededRowIDs.insert(m.rowID) }
}
// Decode ONLY those rows (from the stashed raw text/blob — same source columns).
var hydratedBody: [Int64: String] = [:]
for rid in neededRowIDs {
    let body = decodeBody(textByRow[rid] ?? nil, blobByRow[rid] ?? nil)
    hydratedBody[rid] = body.trimmingCharacters(in: .whitespacesAndNewlines)
}
let rawNEW: [ChatStoryBuilder.RawChat] = rawNEWunhydrated.map { chat in
    let patched = chat.messages.map { m -> ChatStoryBuilder.RawMessage in
        guard let body = hydratedBody[m.rowID] else { return m }
        return .init(rowID: m.rowID, date: m.date, isFromMe: m.isFromMe, senderName: m.senderName,
                     body: body, reactionCount: m.reactionCount, topReactionEmoji: m.topReactionEmoji)
    }
    return .init(chatRowID: chat.chatRowID, title: chat.title, isGroup: chat.isGroup,
                 participantCount: chat.participantCount, avatarData: chat.avatarData,
                 messages: patched, events: chat.events)
}

let storiesOLD = ChatStoryBuilder.buildStories(from: rawOLD, calendar: cal)
let storiesNEW = ChatStoryBuilder.buildStories(from: rawNEW, calendar: cal)

print("════════════════════════════════════════════════════════")
print(" NOSTALGIA PERF PASS B — GOLDEN OLD-vs-NEW PARITY")
print("════════════════════════════════════════════════════════")
print(" Full real-message corpus rows: \(fullCorpusRows)")
print(" Stories (OLD): \(storiesOLD.count)   Stories (NEW): \(storiesNEW.count)")

var checks: [(String, Bool)] = []
func check(_ name: String, _ pass: Bool) { checks.append((name, pass)) }

// Fingerprint a story by its moments — kind + date + headline + detail + example + person + id.
func fingerprint(_ s: ChatStory) -> String {
    var parts = ["CHAT|\(s.chatRowID)|\(s.title)|\(s.isGroup)|\(s.participantCount)|\(s.messageCount)|\(Int(s.firstDate.timeIntervalSinceReferenceDate))|\(Int(s.lastDate.timeIntervalSinceReferenceDate))"]
    for m in s.moments {
        parts.append("M|\(m.kind.rawValue)|\(Int(m.date.timeIntervalSinceReferenceDate))|\(m.headline)|\(m.detail ?? "·")|\(m.example ?? "·")|\(m.person ?? "·")|\(m.id)")
    }
    return parts.joined(separator: "\n")
}

let oldByID = Dictionary(uniqueKeysWithValues: storiesOLD.map { ($0.chatRowID, $0) })
let newByID = Dictionary(uniqueKeysWithValues: storiesNEW.map { ($0.chatRowID, $0) })

check("Same story chat-ID set", Set(oldByID.keys) == Set(newByID.keys))

var mismatches = 0
var momentCount = 0
var exampleCount = 0
for (id, oldStory) in oldByID.sorted(by: { $0.key < $1.key }) {
    guard let newStory = newByID[id] else { mismatches += 1; continue }
    momentCount += oldStory.moments.count
    exampleCount += oldStory.moments.filter { ($0.example ?? "").isEmpty == false }.count
    let fOld = fingerprint(oldStory), fNew = fingerprint(newStory)
    if fOld != fNew {
        mismatches += 1
        if mismatches <= 5 {
            print("\n  MISMATCH chat \(id) “\(oldStory.title)”:")
            let lo = fOld.split(separator: "\n"), ln = fNew.split(separator: "\n")
            for k in 0..<max(lo.count, ln.count) {
                let a = k < lo.count ? String(lo[k]) : "<none>"
                let b = k < ln.count ? String(ln[k]) : "<none>"
                if a != b { print("    OLD: \(a)\n    NEW: \(b)") }
            }
        }
    }
}
print("\n Compared \(oldByID.count) stories, \(momentCount) moments (\(exampleCount) with example bodies).")
check("ChatStory moments byte-identical OLD vs NEW (0 mismatches)", mismatches == 0)

// DECODE-COUNT reduction report.
let newDecodes = neededRowIDs.count
print("\n DECODE COUNT — OLD: \(fullCorpusRows) (whole corpus)   NEW: \(newDecodes) (origin+peak only)")
if newDecodes > 0 {
    print(String(format: "   → %.1fx fewer typedstream decodes", Double(fullCorpusRows) / Double(newDecodes)))
}
check("NEW decodes far fewer rows than OLD", newDecodes < fullCorpusRows / 10)

// Spot-print a few example-bearing stories to eyeball the hydrated bodies.
print("\n──── sample hydrated examples (top 6 stories) ────")
for s in storiesNEW.prefix(6) {
    for m in s.moments where (m.example ?? "").isEmpty == false {
        let ex = (m.example ?? "").replacingOccurrences(of: "\n", with: " ").prefix(46)
        print("  [\(m.kind.rawValue)] \(s.title): “\(ex)”")
    }
}

// ============================================================================
// PART 2 — Romantic flagged-names parity (sequential vs parallel-striped fold).
// ============================================================================
// Stream the 1:1 corpus once, collecting (blob,text,isFromMe,name) work items
// for rows whose participant resolves to a contact — exactly the production
// filter. Then fold sequentially (OLD) and via concurrentPerform stripes (NEW).
struct RomItem { let blob: Data?; let text: String?; let fm: Bool; let name: String }
var romItems: [RomItem] = []
do {
    let sql = """
    SELECT m.is_from_me, m.text, m.attributedBody, ph.id
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat ch ON ch.ROWID = cmj.chat_id
    JOIN chat_handle_join chj ON chj.chat_id = ch.ROWID
    JOIN handle ph ON ph.ROWID = chj.handle_id
    WHERE ch.style = 45 AND m.associated_message_type = 0
    """
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        guard let part = col(s, 3), let name = resolvedContactName(part) else { continue }
        romItems.append(RomItem(blob: blobv(s, 2), text: col(s, 1), fm: sqlite3_column_int(s, 0) == 1, name: name))
    }
    sqlite3_finalize(s)
}
sqlite3_close(db)

func mergeSig(_ a: RomanticDetector.Signals, _ b: RomanticDetector.Signals) -> RomanticDetector.Signals {
    var s = RomanticDetector.Signals()
    s.total = a.total + b.total
    s.myLoveYou = a.myLoveYou + b.myLoveYou
    s.theirLoveYou = a.theirLoveYou + b.theirLoveYou
    s.myLove = a.myLove + b.myLove
    s.goodnight = a.goodnight + b.goodnight
    s.miss = a.miss + b.miss
    s.hearts = a.hearts + b.hearts
    s.babe = a.babe + b.babe
    return s
}

// OLD: sequential single-threaded fold (verbatim shape of the old loop).
var byContactOLD: [String: RomanticDetector.Signals] = [:]
for it in romItems {
    let body = (it.text?.isEmpty == false) ? it.text! : AttributedBodyDecoder.decode(it.blob)
    var sig = byContactOLD[it.name] ?? RomanticDetector.Signals()
    RomanticDetector.accumulate(into: &sig, body: body, isFromMe: it.fm)
    byContactOLD[it.name] = sig
}
let flaggedOLD = RomanticDetector.flagged(from: byContactOLD)

// NEW: parallel striped fold (mirror RomanticDetector+DB's drain()).
let stripes = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16))
var byContactNEW: [String: RomanticDetector.Signals] = [:]
func drainRom(_ batch: [RomItem]) {
    guard !batch.isEmpty else { return }
    let count = batch.count
    let lock = NSLock()
    var partials = Array(repeating: [String: RomanticDetector.Signals](), count: stripes)
    DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
        var local: [String: RomanticDetector.Signals] = [:]
        var idx = stripe
        while idx < count {
            let it = batch[idx]; idx += stripes
            let body = (it.text?.isEmpty == false) ? it.text! : AttributedBodyDecoder.decode(it.blob)
            var sig = local[it.name] ?? RomanticDetector.Signals()
            RomanticDetector.accumulate(into: &sig, body: body, isFromMe: it.fm)
            local[it.name] = sig
        }
        lock.lock(); partials[stripe] = local; lock.unlock()
    }
    for partial in partials {
        for (name, sig) in partial {
            byContactNEW[name] = byContactNEW[name].map { mergeSig($0, sig) } ?? sig
        }
    }
}
let romBatch = 4_096
var k = 0
while k < romItems.count {
    let end = min(k + romBatch, romItems.count)
    drainRom(Array(romItems[k..<end]))
    k = end
}
let flaggedNEW = RomanticDetector.flagged(from: byContactNEW)

print("\n──── ROMANTIC (advisory) — 1:1 rows scanned: \(romItems.count) ────")
print("  flagged OLD (sequential): \(flaggedOLD.count) name(s): \(flaggedOLD.joined(separator: ", "))")
print("  flagged NEW (parallel):   \(flaggedNEW.count) name(s): \(flaggedNEW.joined(separator: ", "))")
check("Romantic flagged-name SET identical OLD vs NEW", flaggedOLD == flaggedNEW)
// Also assert the per-contact Signals maps match exactly (stronger than the
// flag set — proves the parallel fold reproduces every counter).
var sigMismatch = 0
let allNames = Set(byContactOLD.keys).union(byContactNEW.keys)
for n in allNames where byContactOLD[n] != byContactNEW[n] { sigMismatch += 1 }
check("Per-contact Signals maps identical OLD vs NEW (every counter)", sigMismatch == 0)
print("  per-contact Signals maps: \(allNames.count) contacts, \(sigMismatch) mismatched")

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
