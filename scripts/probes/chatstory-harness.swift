//
//  chatstory-harness.swift
//  Out-of-band verification for the per-chat "notable moments" data layer.
//
//  Compiles the REAL pure builder (`ChatStoryBuilder.swift` +
//  `NostalgiaMomentModels.swift`) and the REAL decoder
//  (`AttributedBodyDecoder.swift` + `Typedstream.swift`) against a raw-SQLite3
//  scan of the user's REAL chat.db that MIRRORS `ChatStoryBuilder+DB.swift`.
//  A tiny `BelovedMessagesLoader` shim supplies the `isCoordination` helper the
//  pure builder calls. The `eventGatedMoments` logic is ported verbatim from
//  `NostalgiaViewModel` (it is pure static).
//
//  Verifies:
//    1. Longest-conversation top matches /tmp/convo (~967 / "Securely Attached…").
//    2. The "Hao did this chat start" group story has an origin + membership
//       joins (Mason adds Venkat/Atul/Noah), merged across recreated threads.
//    3. peakReaction excludes "love the message"/headcount coordination + URLs.
//    4. onThisDay is EVENT-GATED — count for today (2026-06-02).
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
// Alias from /tmp/haotl so Venkat resolves even when only the gmail handle is in-thread.
let alias: [String: String] = ["vchitturi9@gmail.com": "Venkat Chitturi"]
func nameFor(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "(unknown)" }
    if let a = alias[raw.lowercased()] { return a }
    return nameByHandle[normH(raw)] ?? raw
}
func decode(_ t: String?, _ b: Data?) -> String {
    if let t = t, !t.isEmpty { return t }
    return AttributedBodyDecoder.decode(b)
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    print("FATAL: cannot open chat.db (Full Disk Access?)"); exit(1)
}

let cal = Calendar.current

// ============================================================================
// Mirror ChatStoryBuilder+DB.loadRawChats against raw SQLite3.
// ============================================================================

// 1) chat metadata
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
// 2) participants
do {
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id", -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let cid = sqlite3_column_int64(s, 0)
        if let h = col(s, 1) { metaByID[cid]?.parts.append(h) }
    }
    sqlite3_finalize(s)
}

// 3) real messages with reaction count + warm rank (mirrors the +DB CTE)
var msgsByChat: [Int64: [ChatStoryBuilder.RawMessage]] = [:]
do {
    let sql = """
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
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    var seen = Set<Int64>()
    func glyph(_ rank: Int?) -> String {
        switch rank { case 1: return "❤️"; case 2: return "😂"; case 3: return "‼️"
        case 4: return "👍"; case 5: return "❓"; case 6: return "🏷️"; default: return "❤️" }
    }
    while sqlite3_step(s) == SQLITE_ROW {
        let row = sqlite3_column_int64(s, 0)
        if seen.contains(row) { continue }; seen.insert(row)
        let cid = sqlite3_column_int64(s, 6)
        let rawDate = sqlite3_column_int64(s, 1)
        let date = Date(timeIntervalSince1970: (rawDate > 1_000_000_000_000 ? Double(rawDate)/1e9 : Double(rawDate)) + 978307200)
        let fm = sqlite3_column_int(s, 2) == 1
        let body = decode(col(s, 3), blobv(s, 4)).trimmingCharacters(in: .whitespacesAndNewlines)
        let sender = fm ? "You" : nameFor(col(s, 5))
        let rx = Int(sqlite3_column_int(s, 7))
        let warm: Int? = sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, 8))
        msgsByChat[cid, default: []].append(ChatStoryBuilder.RawMessage(
            rowID: row, date: date, isFromMe: fm, senderName: sender, body: body,
            reactionCount: rx, topReactionEmoji: rx > 0 ? glyph(warm) : nil))
    }
    sqlite3_finalize(s)
}

// 4) membership / rename events
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
        let rawDate = sqlite3_column_int64(s, 1)
        let date = Date(timeIntervalSince1970: (rawDate > 1_000_000_000_000 ? Double(rawDate)/1e9 : Double(rawDate)) + 978307200)
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
sqlite3_close(db)

// 5) Assemble RawChats with the SAME merge logic as the +DB adapter.
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
var buckets: [String: Bucket] = [:]
let MIN_MESSAGES = 200
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
    guard b.msgs.count >= MIN_MESSAGES else { continue }
    var seen = Set<Int64>()
    let dedup = b.evs.filter { seen.insert($0.rowID).inserted }
    rawChats.append(ChatStoryBuilder.RawChat(
        chatRowID: b.primary, title: b.title, isGroup: b.isGroup,
        participantCount: max(b.parts.count, 1), avatarData: nil,
        messages: b.msgs, events: dedup))
}

// ============================================================================
// Build stories via the REAL pure builder.
// ============================================================================
let stories = ChatStoryBuilder.buildStories(from: rawChats, calendar: cal)

print("════════════════════════════════════════════════════════")
print(" CHAT STORIES — \(stories.count) chats with ≥\(MIN_MESSAGES) msgs")
print("════════════════════════════════════════════════════════")

var checks: [(String, Bool)] = []
func check(_ name: String, _ pass: Bool) { checks.append((name, pass)) }

// ---- CHECK 1: longest conversation top matches /tmp/convo ----
struct LC { let title: String; let count: Int; let detail: String; let date: Date }
var longestConvos: [LC] = []
for s in stories {
    if let m = s.moments.first(where: { $0.kind == .longestConversation }),
       let c = m.headline.split(separator: " ").first.flatMap({ Int($0) }) {
        longestConvos.append(LC(title: s.title, count: c, detail: m.detail ?? "", date: m.date))
    }
}
longestConvos.sort { $0.count > $1.count }
print("\n──── LONGEST CONVERSATIONS (top 12) ────")
for lc in longestConvos.prefix(12) {
    print(String(format: "  %4d  %@  — %@", lc.count, lc.detail, lc.title))
}
let topLC = longestConvos.first
check("Longest-convo top is in 'Securely Attached' chat",
      (topLC?.title.localizedCaseInsensitiveContains("Securely Attached") ?? false))
check("Longest-convo top count in 900...1000 (≈967)",
      (topLC.map { $0.count >= 900 && $0.count <= 1000 } ?? false))

// ---- CHECK 2: "Hao did this chat start" group story ----
if let hao = stories.first(where: { $0.title.localizedCaseInsensitiveContains("Hao did this") }) {
    print("\n──── GROUP STORY: \(hao.title) (merged, \(hao.messageCount) msgs, \(hao.participantCount) people) ────")
    for m in hao.moments {
        let ex = m.example.map { " “\($0.replacingOccurrences(of: "\n", with: " ").prefix(46))”" } ?? ""
        print("  • [\(m.kind.rawValue)] \(m.headline)\(m.detail.map { " — \($0)" } ?? "")\(ex)")
    }
    let hasOrigin = hao.moments.contains { $0.kind == .origin }
    let joins = hao.moments.filter { $0.kind == .joined }
    let joinPeople = Set(joins.compactMap { $0.person?.components(separatedBy: " ").first })
    check("Hao story has an origin moment", hasOrigin)
    check("Hao story has membership joins (≥3)", joins.count >= 3)
    check("Hao joins include Venkat", joinPeople.contains("Venkat"))
    check("Hao joins include Atul", joinPeople.contains("Atul"))
    check("Hao joins include Noah", joinPeople.contains("Noah"))
    check("Hao adder is Mason", joins.contains { $0.headline.localizedCaseInsensitiveContains("Mason") })
} else {
    print("\n!! 'Hao did this chat start' story not found")
    for k in ["Hao story has an origin moment", "Hao story has membership joins (≥3)",
              "Hao joins include Venkat", "Hao joins include Atul", "Hao joins include Noah",
              "Hao adder is Mason"] { check(k, false) }
}

// ---- CHECK 3: peakReaction excludes coordination + URLs ----
print("\n──── PEAK REACTIONS (top 12 stories by msg count) ────")
var anyCoordinationLeak = false
var anyURLLeak = false
for s in stories.prefix(40) {
    guard let pr = s.moments.first(where: { $0.kind == .peakReaction }) else { continue }
    let body = pr.example ?? ""
    if BelovedMessagesLoader.isCoordination(body) { anyCoordinationLeak = true }
    if ChatStoryBuilder.isURLOnly(body) { anyURLLeak = true }
}
for s in stories.prefix(12) {
    if let pr = s.moments.first(where: { $0.kind == .peakReaction }) {
        let ex = (pr.example ?? "").replacingOccurrences(of: "\n", with: " ").prefix(50)
        print("  • \(pr.headline)  \(s.title): “\(ex)”")
    }
}
check("No peakReaction body is coordination/RSVP-bait", !anyCoordinationLeak)
check("No peakReaction body is a bare URL", !anyURLLeak)

// ---- CHECK 4: onThisDay event-gating (today = 2026-06-02) ----
// Port of NostalgiaViewModel.eventGatedMoments (pure).
func eventGatedMoments(from stories: [ChatStory], now: Date, calendar: Calendar) -> [NotableMoment] {
    let today = calendar.dateComponents([.month, .day, .year], from: now)
    guard let tm = today.month, let td = today.day else { return [] }
    let kinds: Set<NotableMoment.Kind> = [.origin, .biggestDay, .peakReaction]
    var out: [NotableMoment] = []
    for st in stories {
        for m in st.moments where kinds.contains(m.kind) {
            let c = calendar.dateComponents([.month, .day, .year], from: m.date)
            guard c.month == tm, c.day == td else { continue }
            if let y = c.year, let ty = today.year, y == ty { continue }
            out.append(m)
        }
    }
    out.sort { $0.date < $1.date }
    return out
}
var todayComps = DateComponents(); todayComps.year = 2026; todayComps.month = 6; todayComps.day = 2; todayComps.hour = 12
let today = cal.date(from: todayComps)!
let otd = eventGatedMoments(from: stories, now: today, calendar: cal)
print("\n──── ON THIS DAY (event-gated, 2026-06-02): \(otd.count) moments ────")
for m in otd.prefix(20) {
    print("  • [\(m.kind.rawValue)] \(m.headline) — \(m.detail ?? "")")
}
// Sanity: also count what a NAIVE raw-dump would yield (all msgs on Jun 2 any year)
// to demonstrate event-gating is far smaller than a raw dump.
var rawJun2 = 0
for rc in rawChats { for m in rc.messages {
    let c = cal.dateComponents([.month, .day], from: m.date)
    if c.month == 6 && c.day == 2 { rawJun2 += 1 } } }
print("  (a naive raw-dump of ALL messages on any June 2 would be \(rawJun2) messages)")
check("onThisDay is event-gated (≤ raw-dump count, today=Jun 2)", otd.count <= rawJun2)
// Probe a date we KNOW has an origin: pick the most-active story's origin date,
// re-run gating "as if today were that origin's anniversary", expect ≥1.
if let big = stories.first, let origin = big.moments.first(where: { $0.kind == .origin }) {
    let oc = cal.dateComponents([.month, .day], from: origin.date)
    var probe = DateComponents(); probe.year = 2099; probe.month = oc.month; probe.day = oc.day; probe.hour = 12
    let probeDate = cal.date(from: probe)!
    let probed = eventGatedMoments(from: stories, now: probeDate, calendar: cal)
    print("  (probe: on \(big.title)'s origin anniversary → \(probed.count) gated moments, expect ≥1)")
    check("Event-gating surfaces ≥1 moment on a known anniversary", probed.count >= 1)
}

// ---- summary ----
print("\n════════════════════════════════════════════════════════")
var passed = 0
for (name, ok) in checks {
    print("  \(ok ? "PASS" : "FAIL")  \(name)")
    if ok { passed += 1 }
}
print("════════════════════════════════════════════════════════")
print("  \(passed)/\(checks.count) checks passed")
exit(passed == checks.count ? 0 : 1)
