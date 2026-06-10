//
//  nostalgia-depth-harness.swift
//  Hourglass — out-of-band verification of the Nostalgia data layer.
//
//  Compiled with `swiftc -O` against the REAL, GRDB-free detector source files
//  (RomanticDetector core, StreakDetector, EraDetector, FunnyMomentsLoader
//  windowing, BelovedMessagesLoader pure ranking, NostalgiaDismissals) plus
//  tiny shims (below) for the heavy types those files only NAME but never
//  execute on the pure paths. DB access is raw SQLite3 against the user's real
//  ~/Library/Messages/chat.db; rows are fed into the real pure cores.
//
//  Build + run via scripts/probes/run-nostalgia-depth-harness.sh
//
//  REQUIRES Full Disk Access for the running shell.
//

import Foundation
import SQLite3

// ───────────────────────────── Shims ─────────────────────────────
// Minimal stand-ins for module types the real detector files reference at
// compile time but DON'T execute on the code paths the harness drives. Keeping
// them tiny is the whole point — we compile the REAL algorithm code unchanged.

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Real `Reaction` is Foundation-only and lives in the app; we re-declare the
/// slice the beloved scorer needs (kind enum + the weights are in the real
/// `BelovedMessagesLoader.score`, which we compile).
public struct Reaction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case love, like, dislike, laugh, emphasize, question
        case customEmoji(String)
        case sticker
    }
    public let kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

/// `MemoryMessage` stand-in carrying just the fields the real beloved ranker
/// reads (`reactions`, `body`, `isGroup`, `date`, `rowID`). Field-compatible
/// with the real type's accessors used in `BelovedMessagesLoader.rank`.
public struct MemoryMessage: Sendable, Equatable, Identifiable {
    public let rowID: Int64
    public let date: Date
    public let isFromMe: Bool
    public let body: String
    public let senderName: String
    public let partnerName: String
    public let isGroup: Bool
    public let reactions: [Reaction]
    public var id: Int64 { rowID }
    public init(rowID: Int64, date: Date, isFromMe: Bool, body: String,
                senderName: String, partnerName: String, isGroup: Bool, reactions: [Reaction]) {
        self.rowID = rowID; self.date = date; self.isFromMe = isFromMe; self.body = body
        self.senderName = senderName; self.partnerName = partnerName
        self.isGroup = isGroup; self.reactions = reactions
    }
}

/// `BelovedMessage` mirror — exactly the shape `BelovedMessagesLoader.rank`
/// returns.
public struct BelovedMessage: Sendable, Equatable, Identifiable {
    public let message: MemoryMessage
    public let reactionCount: Int
    public let warmthScore: Double
    public var id: Int64 { message.rowID }
    public init(message: MemoryMessage, reactionCount: Int, warmthScore: Double) {
        self.message = message; self.reactionCount = reactionCount; self.warmthScore = warmthScore
    }
}

// MessageType / MessageSearch shims — `BelovedMessagesLoader` names these in
// its (uncompiled-path) `load()`; the harness only drives `rank`/`score`/
// `isCoordination`. We never call `search()`, so the bodies are stubs.
public enum MessageType: Sendable, Equatable { case text }
public final class ChatDatabase: @unchecked Sendable {}
public struct Contact: Sendable, Hashable { public let displayName: String }
public struct ResolvedContacts: Sendable {
    public func name(forRawHandle raw: String?) -> String { raw ?? "(unknown)" }
    public func avatarData(forRawHandle raw: String?) -> Data? { nil }
    public func contact(for handleRaw: String) -> Contact? { nil }
}
public struct MessageSearch: Sendable {
    public struct Result: Sendable, Equatable {}
    public let database: ChatDatabase
    public let contacts: ResolvedContacts
    public init(database: ChatDatabase, contacts: ResolvedContacts) {
        self.database = database; self.contacts = contacts
    }
    public enum SortOrder: Sendable { case descending, ascending }
    public func search(phrase: String, limit: Int? = nil, order: SortOrder = .descending) throws -> [Result] { [] }
}
extension MemoryMessage {
    /// Stub initializer matching the real `MemoryMessage(result:)` signature so
    /// `BelovedMessagesLoader.load` compiles. Never invoked by the harness.
    public init(result: MessageSearch.Result) {
        self.init(rowID: 0, date: Date(), isFromMe: false, body: "",
                  senderName: "", partnerName: "", isGroup: false, reactions: [])
    }
}

/// `DormantFriend` mirror — `NostalgiaDismissals.filter` is generic over it.
public struct DormantFriend: Sendable, Equatable, Identifiable {
    public let key: String
    public var id: String { key }
    public init(key: String) { self.key = key }
}

// `FunnyMomentsLoader.load()` calls `self.fetchReactedMessages()` (real impl in
// the GRDB +DB file we don't compile). Stub it so the core compiles; the
// harness drives the PURE `windows(from:config:)` directly, not `load()`.
extension FunnyMomentsLoader {
    func fetchReactedMessages() throws -> [ReactedMessage] { [] }
}

/// `DailyCount` / `ContactDailySeries` mirrors — the day-series the pure
/// StreakDetector / EraDetector consume. Field-compatible.
public struct DailyCount: Sendable, Equatable {
    public let dayIndex: Int32
    public let sent: Int32
    public let received: Int32
    public init(dayIndex: Int32, sent: Int32, received: Int32) {
        self.dayIndex = dayIndex; self.sent = sent; self.received = received
    }
}
public struct ContactDailySeries: Sendable {
    public let key: String
    public let displayName: String
    public let avatarData: Data?
    public let days: [DailyCount]
    public init(key: String, displayName: String, avatarData: Data?, days: [DailyCount]) {
        self.key = key; self.displayName = displayName; self.avatarData = avatarData; self.days = days
    }
}

// The real Streak / FirstMessage / Era / FunnyMoment models are Foundation-only
// and compiled from NostalgiaDepthModels.swift — no shim needed.

// ───────────────────────── SQLite helpers ─────────────────────────

let home = FileManager.default.homeDirectoryForCurrentUser
let MAC_EPOCH: TimeInterval = 978_307_200

func openDB(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    return sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? db : nil
}
func col(_ s: OpaquePointer?, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
func blobv(_ s: OpaquePointer?, _ i: Int32) -> Data? {
    guard let p = sqlite3_column_blob(s, i) else { return nil }
    return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
}
func macToDate(_ raw: Int64) -> Date {
    let s = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
    return Date(timeIntervalSince1970: s + MAC_EPOCH)
}
func normH(_ raw: String) -> String {
    if raw.contains("@") { return raw.lowercased() }
    let d = raw.filter { $0.isNumber }
    if d.isEmpty { return raw.lowercased() }
    var s = d; if s.count == 10 { s = "1" + s }; return "+" + s
}

// Body decode uses the REAL `AttributedBodyDecoder` + `Typedstream` (compiled
// into this harness from Sources/Data), so the romantic/beloved/funny signals
// that live in `attributedBody` (NULL-`text` modern rows) are decoded exactly
// as the app does — no lossy heuristic.
func body(text: String?, blob: Data?) -> String {
    if let t = text, !t.isEmpty { return t }
    return AttributedBodyDecoder.decode(blob)
}

// ───────────────────── AddressBook: handle → name ─────────────────────

var nameByHandle: [String: String] = [:]
let abRoot = home.appending(path: "Library/Application Support/AddressBook/Sources")
if let dirs = try? FileManager.default.contentsOfDirectory(at: abRoot, includingPropertiesForKeys: nil) {
    for dir in dirs {
        let p = dir.appending(path: "AddressBook-v22.abcddb").path
        guard FileManager.default.fileExists(atPath: p), let ab = openDB(p) else { continue }
        var s: OpaquePointer?
        sqlite3_prepare_v2(ab, "SELECT r.ZFIRSTNAME,r.ZLASTNAME,p.ZFULLNUMBER,e.ZADDRESS FROM ZABCDRECORD r LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER=r.Z_PK LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER=r.Z_PK", -1, &s, nil)
        while sqlite3_step(s) == SQLITE_ROW {
            let nm = [col(s, 0), col(s, 1)].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !nm.isEmpty else { continue }
            if let ph = col(s, 2) { nameByHandle[normH(ph)] = nm }
            if let em = col(s, 3) { nameByHandle[normH(em)] = nm }
        }
        sqlite3_finalize(s); sqlite3_close(ab)
    }
}
func name(forHandle raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return nameByHandle[normH(raw)]
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    FileHandle.standardError.write(Data("FATAL: cannot open chat.db (Full Disk Access?)\n".utf8))
    exit(1)
}

let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}()
func dayIndex(_ date: Date) -> Int32 {
    let anchor = cal.date(from: DateComponents(year: 2001, month: 1, day: 1))!
    return Int32(cal.dateComponents([.day], from: anchor, to: date).day ?? 0)
}

var failures = 0
func check(_ label: String, _ pass: Bool) {
    print("  [\(pass ? "PASS" : "FAIL")] \(label)")
    if !pass { failures += 1 }
}

print("════════════════════════════════════════════════════════════════")
print(" NOSTALGIA DEPTH HARNESS — real chat.db, real detectors")
print("════════════════════════════════════════════════════════════════")

// ─────────────── (A) RomanticDetector (advisory flag) ───────────────
// Build per-contact Signals from the SAME query the real +DB adapter runs,
// then call the REAL pure `RomanticDetector.accumulate` / `flagged`.

print("\n── (A) RomanticDetector — advisory flag (must be EXACTLY {Beck, Shreya}) ──")
do {
    // Map style=45 chat -> participant handle.
    var chatParticipant: [Int64: String] = [:]
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id JOIN chat ch ON ch.ROWID=chj.chat_id WHERE ch.style=45", -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let cid = sqlite3_column_int64(s, 0)
        if let h = col(s, 1) { chatParticipant[cid] = h }
    }
    sqlite3_finalize(s)

    var byContact: [String: RomanticDetector.Signals] = [:]
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT m.is_from_me, m.text, m.attributedBody, cmj.chat_id FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID JOIN chat ch ON ch.ROWID=cmj.chat_id WHERE ch.style=45 AND m.associated_message_type=0", -1, &st, nil)
    while sqlite3_step(st) == SQLITE_ROW {
        let cid = sqlite3_column_int64(st, 3)
        guard let handle = chatParticipant[cid], let nm = name(forHandle: handle) else { continue }
        let b = body(text: col(st, 1), blob: blobv(st, 2))
        let fromMe = sqlite3_column_int(st, 0) == 1
        var sig = byContact[nm] ?? RomanticDetector.Signals()
        RomanticDetector.accumulate(into: &sig, body: b, isFromMe: fromMe)
        byContact[nm] = sig
    }
    sqlite3_finalize(st)

    let flagged = RomanticDetector.flagged(from: byContact)
    print("  flagged = \(flagged)")

    // Detail for the named people.
    for who in ["Shreya Shirsathe", "Beck Peterson", "Keeshant Hoogar", "Mason Funaki", "Venkat Chitturi"] {
        if let sig = byContact[who] {
            print(String(format: "    %-18@ total %6d  recipLove %3d  miss %3d  gn %3d  hearts %3d  babe %3d  → %@",
                         who, sig.total, sig.reciprocalLove, sig.miss, sig.goodnight, sig.hearts, sig.babe,
                         RomanticDetector.isRomantic(sig) ? "ROMANTIC" : "platonic"))
        } else {
            print("    \(who): (no 1:1 history found)")
        }
    }

    check("flagged == exactly [Beck Peterson, Shreya Shirsathe]",
          flagged == ["Beck Peterson", "Shreya Shirsathe"])
    check("Shreya Shirsathe IS romantic", byContact["Shreya Shirsathe"].map { RomanticDetector.isRomantic($0) } ?? false)
    check("Beck Peterson IS romantic", byContact["Beck Peterson"].map { RomanticDetector.isRomantic($0) } ?? false)
    check("Keeshant Hoogar is platonic", !(byContact["Keeshant Hoogar"].map { RomanticDetector.isRomantic($0) } ?? false))
    check("Mason Funaki is platonic", !(byContact["Mason Funaki"].map { RomanticDetector.isRomantic($0) } ?? false))
    check("Venkat Chitturi is platonic", !(byContact["Venkat Chitturi"].map { RomanticDetector.isRomantic($0) } ?? false))
}

// ──────────────── Build per-contact day-series (for B, C) ────────────────
// received+sent per (resolved contact, day), 1:1 + group folded into the
// contact key the same way the aggregate does (by resolved name).

func buildContactSeries() -> [ContactDailySeries] {
    // (name) -> dayIndex -> (sent, received)
    var byName: [String: [Int32: (Int32, Int32)]] = [:]
    // 1:1 sent rows need chat->participant; received rows carry the handle.
    var chatParticipant: [Int64: String] = [:]
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID=chj.handle_id JOIN chat ch ON ch.ROWID=chj.chat_id WHERE ch.style=45", -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let cid = sqlite3_column_int64(s, 0)
        if let h = col(s, 1) { chatParticipant[cid] = h }
    }
    sqlite3_finalize(s)

    var st: OpaquePointer?
    // Per-contact volume = all 1:1 messages with that contact (sent + received).
    sqlite3_prepare_v2(db, "SELECT m.is_from_me, m.date, m.handle_id, h.id, cmj.chat_id FROM message m JOIN chat_message_join cmj ON cmj.message_id=m.ROWID JOIN chat ch ON ch.ROWID=cmj.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id WHERE ch.style=45 AND m.associated_message_type=0", -1, &st, nil)
    while sqlite3_step(st) == SQLITE_ROW {
        let fromMe = sqlite3_column_int(st, 0) == 1
        let date = macToDate(sqlite3_column_int64(st, 1))
        let handle: String?
        if fromMe { handle = chatParticipant[sqlite3_column_int64(st, 4)] }
        else { handle = col(st, 3) }
        guard let h = handle, let nm = name(forHandle: h) else { continue }
        let di = dayIndex(date)
        var perDay = byName[nm] ?? [:]
        var t = perDay[di] ?? (0, 0)
        if fromMe { t.0 += 1 } else { t.1 += 1 }
        perDay[di] = t
        byName[nm] = perDay
    }
    sqlite3_finalize(st)

    return byName.map { (nm, perDay) in
        let days = perDay.map { DailyCount(dayIndex: $0.key, sent: $0.value.0, received: $0.value.1) }
            .sorted { $0.dayIndex < $1.dayIndex }
        return ContactDailySeries(key: nm, displayName: nm, avatarData: nil, days: days)
    }
}

let series = buildContactSeries()
print("\n  (built \(series.count) contact day-series from 1:1 history)")

// ─────────────── (B) StreakDetector ───────────────
print("\n── (B) StreakDetector — longest consecutive-day runs ──")
do {
    let streaks = StreakDetector.detect(series: series, calendar: cal)
    let df = DateFormatter(); df.dateFormat = "MMM d yyyy"
    for s in streaks {
        print("    • \(s.displayName): \(s.length) days straight (\(df.string(from: s.startDate)) → \(df.string(from: s.endDate)))")
    }
    check("streaks non-empty", !streaks.isEmpty)
    check("top streak length plausible (≥ 7)", (streaks.first?.length ?? 0) >= 7)
    check("streaks sorted descending by length",
          zip(streaks, streaks.dropFirst()).allSatisfy { $0.length >= $1.length })
}

// ─────────────── (C) EraDetector ───────────────
print("\n── (C) EraDetector — your person each season ──")
do {
    let eras = EraDetector.detect(series: series, calendar: cal)
    for e in eras.prefix(10) {
        print("    • \(e.seasonLabel): \(e.topContactName) (\(e.messageCount) msgs)")
    }
    check("eras non-empty", !eras.isEmpty)
    check("eras sorted most-recent-first",
          zip(eras, eras.dropFirst()).allSatisfy { ($0.year, $0.quarter) >= ($1.year, $1.quarter) })
    check("every era winner cleared the floor (≥30)", eras.allSatisfy { $0.messageCount >= 30 })
}

// ─────────────── (D) BelovedMessagesLoader (pure ranking) ───────────────
// Replicate the SQL the real loader's MessageSearch path feeds (messages with
// ≥3 reactions), then rank with the REAL BelovedMessagesLoader.rank — which
// must EXCLUDE coordination/RSVP-bait and warmth-weight.
print("\n── (D) BelovedMessagesLoader — coordination excluded, warmth-ranked ──")
do {
    // Per-target reaction kinds (strip prefix: substring after last '/').
    var kindsByGuid: [String: [Reaction.Kind]] = [:]
    var rs: OpaquePointer?
    let rq = """
    SELECT CASE WHEN instr(associated_message_guid,'/')>0
                THEN substr(associated_message_guid, instr(associated_message_guid,'/')+1)
                ELSE associated_message_guid END AS tg,
           associated_message_type, associated_message_emoji
    FROM message
    WHERE associated_message_type BETWEEN 2000 AND 2007 AND associated_message_guid IS NOT NULL
    """
    sqlite3_prepare_v2(db, rq, -1, &rs, nil)
    while sqlite3_step(rs) == SQLITE_ROW {
        guard let tg = col(rs, 0) else { continue }
        let type = Int(sqlite3_column_int(rs, 1))
        let kind: Reaction.Kind?
        switch type {
        case 2000: kind = .love
        case 2001: kind = .like
        case 2002: kind = .dislike
        case 2003: kind = .laugh
        case 2004: kind = .emphasize
        case 2005: kind = .question
        case 2006: kind = .customEmoji(col(rs, 2) ?? "❤️")
        case 2007: kind = .sticker
        default: kind = nil
        }
        if let k = kind { kindsByGuid[tg, default: []].append(k) }
    }
    sqlite3_finalize(rs)

    // Candidate messages: those with ≥3 reactions. Fetch body/sender/chat.
    let candidates = kindsByGuid.filter { $0.value.count >= 3 }
    var memories: [MemoryMessage] = []
    var fetch: OpaquePointer?
    let fq = """
    SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me, h.id, ch.style, ch.display_name
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
    JOIN chat ch ON ch.ROWID=cmj.chat_id
    LEFT JOIN handle h ON h.ROWID=m.handle_id
    WHERE m.guid=? LIMIT 1
    """
    sqlite3_prepare_v2(db, fq, -1, &fetch, nil)
    for (guid, kinds) in candidates {
        sqlite3_reset(fetch); sqlite3_clear_bindings(fetch)
        sqlite3_bind_text(fetch, 1, guid, -1, SQLITE_TRANSIENT)
        if sqlite3_step(fetch) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(fetch, 0)
            let date = macToDate(sqlite3_column_int64(fetch, 1))
            let b = body(text: col(fetch, 2), blob: blobv(fetch, 3))
            let fromMe = sqlite3_column_int(fetch, 4) == 1
            let style = Int(sqlite3_column_int(fetch, 6))
            let sender = fromMe ? "You" : (name(forHandle: col(fetch, 5)) ?? (col(fetch, 5) ?? "(unknown)"))
            let partner = (col(fetch, 7)) ?? sender
            memories.append(MemoryMessage(
                rowID: rowid, date: date, isFromMe: fromMe, body: b,
                senderName: sender, partnerName: partner, isGroup: style == 43,
                reactions: kinds.map { Reaction(kind: $0) }))
        }
    }
    sqlite3_finalize(fetch)

    let ranked = BelovedMessagesLoader.rank(memories, maxResults: 8)
    print("  candidate messages with ≥3 reactions: \(memories.count); ranked top \(ranked.count)")
    for b in ranked {
        let oneLine = b.message.body.replacingOccurrences(of: "\n", with: " ").prefix(70)
        print(String(format: "    [%5.1f warmth, %2d rx] %@%@: %@",
                     b.warmthScore, b.reactionCount,
                     b.message.senderName,
                     b.message.isGroup ? " · \(b.message.partnerName)" : "",
                     String(oneLine)))
    }

    // Assert no surfaced beloved is coordination/RSVP-bait.
    let badPhrases = ["love the message", "love this message", "headcount", "head count",
                      "react to this", "react if", "if you can make it", "rsvp", "final count", "🤍 if"]
    let anyBad = ranked.contains { b in
        let low = b.message.body.lowercased()
        return badPhrases.contains { low.contains($0) }
    }
    check("no coordination/RSVP-bait in beloved top 8", !anyBad)
    check("beloved non-empty", !ranked.isEmpty)
    // Also directly exercise the real isCoordination on a few synthetic strings.
    check("isCoordination('please love the message if you can make it')",
          BelovedMessagesLoader.isCoordination("please love the message if you can make it"))
    check("isCoordination('headcount for friday?')",
          BelovedMessagesLoader.isCoordination("headcount for friday?"))
    check("isCoordination('that was the funniest thing ever') == false",
          !BelovedMessagesLoader.isCoordination("that was the funniest thing ever"))
}

// ─────────────── (E) FunnyMomentsLoader windowing (pure) ───────────────
// Pull amused-reacted messages via the SAME query the +DB adapter runs, build
// ReactedMessage values, and call the REAL FunnyMomentsLoader.windows.
print("\n── (E) FunnyMomentsLoader — amused-reaction windows ──")
do {
    var amusedByGuid: [String: Int] = [:]
    var rs: OpaquePointer?
    let rq = """
    SELECT CASE WHEN instr(r.associated_message_guid,'/')>0
                THEN substr(r.associated_message_guid, instr(r.associated_message_guid,'/')+1)
                ELSE r.associated_message_guid END AS tg
    FROM message r
    WHERE r.associated_message_type IN (2000,2003,2004) AND r.is_from_me=0 AND r.associated_message_guid IS NOT NULL
    """
    sqlite3_prepare_v2(db, rq, -1, &rs, nil)
    while sqlite3_step(rs) == SQLITE_ROW {
        if let tg = col(rs, 0) { amusedByGuid[tg, default: 0] += 1 }
    }
    sqlite3_finalize(rs)

    var reacted: [FunnyMomentsLoader.ReactedMessage] = []
    var fetch: OpaquePointer?
    let fq = """
    SELECT m.ROWID, m.date, m.text, m.attributedBody, m.is_from_me, h.id, cmj.chat_id, ch.style, ch.display_name, ch.guid
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id=m.ROWID
    JOIN chat ch ON ch.ROWID=cmj.chat_id
    LEFT JOIN handle h ON h.ROWID=m.handle_id
    WHERE m.guid=? AND m.associated_message_type=0 LIMIT 1
    """
    sqlite3_prepare_v2(db, fq, -1, &fetch, nil)
    for (guid, count) in amusedByGuid {
        sqlite3_reset(fetch); sqlite3_clear_bindings(fetch)
        sqlite3_bind_text(fetch, 1, guid, -1, SQLITE_TRANSIENT)
        if sqlite3_step(fetch) == SQLITE_ROW {
            reacted.append(FunnyMomentsLoader.ReactedMessage(
                rowID: sqlite3_column_int64(fetch, 0),
                chatID: sqlite3_column_int64(fetch, 6),
                date: macToDate(sqlite3_column_int64(fetch, 1)),
                amusedCount: count,
                body: body(text: col(fetch, 2), blob: blobv(fetch, 3)),
                isFromMe: sqlite3_column_int(fetch, 4) == 1,
                senderHandle: col(fetch, 5),
                chatStyle: Int(sqlite3_column_int(fetch, 7)),
                chatDisplayName: col(fetch, 8),
                chatGUID: col(fetch, 9)))
        }
    }
    sqlite3_finalize(fetch)

    let windows = FunnyMomentsLoader.windows(from: reacted, config: FunnyMomentsLoader.Config())
    print("  amused-reacted messages: \(reacted.count); windows: \(windows.count)")
    let df = DateFormatter(); df.dateFormat = "MMM yyyy"
    for w in windows.prefix(6) {
        let who = w.trigger.isFromMe ? "You" : (name(forHandle: w.trigger.senderHandle) ?? "someone")
        let oneLine = w.trigger.body.replacingOccurrences(of: "\n", with: " ").prefix(60)
        let label = w.trigger.body.isEmpty ? "[attachment]" : String(oneLine)
        print("    • [\(w.totalAmused) amused · \(df.string(from: w.trigger.date))] \(who): \(label)")
    }
    check("funny windows non-empty", !windows.isEmpty)
    check("top funny window dense (≥ 4 amused)", (windows.first?.totalAmused ?? 0) >= 4)
    check("windows sorted descending by amused total",
          zip(windows, windows.dropFirst()).allSatisfy { $0.totalAmused >= $1.totalAmused })
    // Coordination/RSVP-bait (the defined phrases) must NOT trigger a moment.
    let funnyBad = ["love the message", "love this message", "headcount", "head count",
                    "react to this", "react if", "if you can make it", "rsvp", "final count", "🤍 if"]
    let anyFunnyBad = windows.prefix(6).contains { w in
        let low = w.trigger.body.lowercased()
        return funnyBad.contains { low.contains($0) }
    }
    check("no coordination/RSVP-bait trigger in funny top 6", !anyFunnyBad)
}

// ─────────────── (F) NostalgiaDismissals — hidden set + suggestions ───────────────
print("\n── (F) NostalgiaDismissals — user-controlled hide model ──")
do {
    let suite = "hourglass.harness.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = NostalgiaDismissals(defaults: defaults)

    check("starts empty", store.hiddenKeys().isEmpty)
    store.hide("Anyone At All")
    check("hide adds to set", store.isHidden("Anyone At All"))
    check("hidden set persists across instances",
          NostalgiaDismissals(defaults: defaults).isHidden("Anyone At All"))
    store.unhide("Anyone At All")
    check("unhide removes from set", !store.isHidden("Anyone At All"))

    // Suggestions = flagged − hidden − declined.
    let flagged = ["Beck Peterson", "Shreya Shirsathe"]
    func suggestions() -> [String] {
        let hidden = store.hiddenKeys(); let declined = store.dismissedSuggestionKeys()
        return flagged.filter { !hidden.contains($0) && !declined.contains($0) }
    }
    check("both flagged suggested initially", suggestions() == ["Beck Peterson", "Shreya Shirsathe"])
    store.hide("Beck Peterson")
    check("hiding a flagged person drops it from suggestions", suggestions() == ["Shreya Shirsathe"])
    store.dismissHideSuggestion("Shreya Shirsathe")
    check("declining a suggestion drops it (without hiding)",
          suggestions().isEmpty && !store.isHidden("Shreya Shirsathe"))
    defaults.removePersistentDomain(forName: suite)
}

print("\n════════════════════════════════════════════════════════════════")
if failures == 0 {
    print(" ALL CHECKS PASSED")
} else {
    print(" \(failures) CHECK(S) FAILED")
}
print("════════════════════════════════════════════════════════════════")
sqlite3_close(db)
exit(failures == 0 ? 0 : 1)
