//
//  vernacular-loadmessages-oom-harness.swift
//  Real-chat.db parity + memory probe for the VernacularLoader.loadMessages OOM fix.
//
//  What this proves over ~/Library/Messages/chat.db:
//    1) PARITY: a raw-SQLite mirror of the NEW batched loadMessages shape produces
//       the same ordered decoded corpus as an independent, straightforward
//       single-threaded reference decode of the same SQL and field logic.
//    2) MEMORY: the NEW batched shape samples peak task_vm_info.phys_footprint while
//       it runs and asserts the peak stays under a configurable bound (default 2 GB).
//
//  The harness compiles the REAL Typedstream + AttributedBodyDecoder sources. It
//  intentionally avoids GRDB so it can run as a standalone probe like the existing
//  scripts/probes/*-parity-harness.swift files.
//
//  Usage (from repo root):
//      ./scripts/probes/run-vernacular-loadmessages-oom-harness.sh
//

import Darwin
import Foundation
import SQLite3

let home = FileManager.default.homeDirectoryForCurrentUser
let defaultDB = home.appending(path: "Library/Messages/chat.db").path
let chatDBPath = ProcessInfo.processInfo.environment["HOURGLASS_CHAT_DB"] ?? defaultDB
let maxMessages = Int(ProcessInfo.processInfo.environment["HOURGLASS_VERN_MAX_MESSAGES"] ?? "") ?? 1_000_000
let memoryLimitMB = Double(ProcessInfo.processInfo.environment["HOURGLASS_VERN_MEMORY_LIMIT_MB"] ?? "") ?? 2_048.0
let memoryLimitBytes = UInt64(memoryLimitMB * 1_048_576.0)

func err(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func openDB(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    return sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK ? db : nil
}

func prepare(_ db: OpaquePointer?, _ sql: String) -> OpaquePointer? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        if let db {
            err("sqlite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return nil
    }
    return stmt
}

func prepareOrExit(_ db: OpaquePointer?, _ sql: String, label: String) -> OpaquePointer? {
    guard let stmt = prepare(db, sql) else {
        err("FATAL: failed to prepare \(label)")
        exit(1)
    }
    return stmt
}

func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    sqlite3_column_text(stmt, index).map { String(cString: $0) }
}

func colBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
    guard let pointer = sqlite3_column_blob(stmt, index) else { return nil }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, index)))
}

func currentPhysFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                       MemoryLayout<natural_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

func mb(_ bytes: UInt64) -> Double {
    Double(bytes) / 1_048_576.0
}

final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var peak: UInt64

    init() {
        peak = currentPhysFootprint()
    }

    func sample() {
        let now = currentPhysFootprint()
        lock.lock()
        if now > peak { peak = now }
        lock.unlock()
    }
}

// MARK: - Minimal production shims

struct Handle: Hashable {
    let normalized: String
    init(raw: String) { normalized = Self.normalize(raw) }
    static func normalize(_ input: String) -> String {
        if input.contains("@") { return input.lowercased() }
        let digits = input.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map { Character($0) }
        guard !digits.isEmpty else { return input.lowercased() }
        var d = String(digits)
        if d.count == 10 { d = "1" + d }
        return "+" + d
    }
}

enum VernTokens {
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" {
                cur.append(ch)
            } else {
                if !cur.isEmpty { out.append(cur) }
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

struct Contacts {
    var byHandle: [Handle: String]
}

let unknownLabel = "someone not in your contacts"

func loadContacts() -> Contacts {
    let sourcesRoot = home.appending(path: "Library/Application Support/AddressBook/Sources")
    guard let dirs = try? FileManager.default.contentsOfDirectory(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
    ) else {
        return Contacts(byHandle: [:])
    }

    var handlesByName: [String: Set<Handle>] = [:]
    for dir in dirs {
        let path = dir.appending(path: "AddressBook-v22.abcddb").path
        guard FileManager.default.fileExists(atPath: path), let db = openDB(path) else { continue }
        let sql = """
            SELECT r.ZFIRSTNAME, r.ZLASTNAME, p.ZFULLNUMBER, e.ZADDRESS
            FROM ZABCDRECORD r
            LEFT JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            LEFT JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
            """
        if let stmt = prepare(db, sql) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = [colText(stmt, 0), colText(stmt, 1)]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if let phone = colText(stmt, 2), !phone.isEmpty {
                    handlesByName[name, default: []].insert(Handle(raw: phone))
                }
                if let email = colText(stmt, 3), !email.isEmpty {
                    handlesByName[name, default: []].insert(Handle(raw: email))
                }
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }

    var byHandle: [Handle: String] = [:]
    for (name, handles) in handlesByName {
        for handle in handles {
            byHandle[handle] = name
        }
    }
    return Contacts(byHandle: byHandle)
}

struct VernacularMessage {
    var messageID: Int = -1
    let date: Double
    let chat: Int64
    let isOneOnOne: Bool
    let itemType: Int64
    let fromMe: Bool
    let who: String
    let body: String
    let bodyLow: String
    let uptake: Double
    let isPoll: Bool
    let amused: Bool
    let laughed: Bool

    init(date: Double, chat: Int64, fromMe: Bool, who: String, body: String,
         uptake: Double, amused: Bool, laughed: Bool, isOneOnOne: Bool, itemType: Int64) {
        self.date = date
        self.chat = chat
        self.isOneOnOne = isOneOnOne
        self.itemType = itemType
        self.fromMe = fromMe
        self.who = who
        self.body = body
        self.bodyLow = body.lowercased()
        self.uptake = uptake
        self.isPoll = isPollMessage(self.bodyLow)
        self.amused = amused
        self.laughed = laughed
    }
}

struct RawMessageRow: Sendable {
    let date: Int64
    let chat: Int64
    let fromMe: Bool
    let handle: String?
    let text: String?
    let blob: Data?
    let guid: String
    let itemType: Int64
}

struct MessageFingerprint: Equatable {
    let messageID: Int
    let dateBits: UInt64
    let chat: Int64
    let isOneOnOne: Bool
    let itemType: Int64
    let fromMe: Bool
    let who: String
    let body: String
    let bodyByteCount: Int
    let uptakeBits: UInt64
    let isPoll: Bool
    let amused: Bool
    let laughed: Bool
}

func fingerprint(_ message: VernacularMessage) -> MessageFingerprint {
    MessageFingerprint(
        messageID: message.messageID,
        dateBits: message.date.bitPattern,
        chat: message.chat,
        isOneOnOne: message.isOneOnOne,
        itemType: message.itemType,
        fromMe: message.fromMe,
        who: message.who,
        body: message.body,
        bodyByteCount: message.body.utf8.count,
        uptakeBits: message.uptake.bitPattern,
        isPoll: message.isPoll,
        amused: message.amused,
        laughed: message.laughed
    )
}

func decodedBody(text: String?, blob: Data?) -> String {
    if let text, !text.isEmpty { return text }
    return AttributedBodyDecoder.decode(blob)
}

func containsURL(_ low: String) -> Bool {
    low.contains("http") || low.contains("://") || low.contains("www.")
        || low.contains(".com") || low.contains(".net") || low.contains(".org")
}

func isAmusement(_ low: String) -> Bool {
    let keys = ["lmao","lmfao","lmaoo","haha","hahah","\u{1F480}","\u{1F62D}","\u{1F602}","\u{1F923}",
                " lol","lol ","crying","im dead","so real","deadass","cooked","fr fr","\u{1F4AF}"]
    for k in keys where low.contains(k) { return true }
    if low == "lol" || low == "real" || low == "facts" || low == "w" || low == "\u{1F480}" || low == "\u{1F62D}" {
        return true
    }
    return false
}

func isPollMessage(_ low: String) -> Bool {
    let keys = ["this message","like this","react to","react if","headcount","rsvp",
                "love the message","if you can make it","like the message","comment if",
                "react with","tap the","\u{1F44D} if","like if"]
    for k in keys where low.contains(k) { return true }
    return false
}

func resolveWho(rawHandle: String?, fromMe: Bool, contacts: Contacts) -> String {
    if fromMe { return "You" }
    guard let rawHandle, !rawHandle.isEmpty else { return unknownLabel }
    return contacts.byHandle[Handle(raw: rawHandle)] ?? unknownLabel
}

func reactionMap(db: OpaquePointer?, sql: String) -> [String: Int] {
    var out: [String: Int] = [:]
    guard let stmt = prepareOrExit(db, sql, label: "reaction map") else { return out }
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let guid = colText(stmt, 0) else { continue }
        out[guid] = Int(sqlite3_column_int64(stmt, 1))
    }
    sqlite3_finalize(stmt)
    return out
}

func oneOnOneSet(db: OpaquePointer?) -> Set<Int64> {
    var out = Set<Int64>()
    guard let stmt = prepareOrExit(db, "SELECT ROWID AS id FROM chat WHERE style = 45", label: "one-on-one chat map") else {
        return out
    }
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.insert(sqlite3_column_int64(stmt, 0))
    }
    sqlite3_finalize(stmt)
    return out
}

let reactionSQL = """
    SELECT
      CASE
        WHEN instr(associated_message_guid, '/') > 0
          THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
        ELSE associated_message_guid
      END AS g,
      COUNT(*) AS c
    FROM message
    WHERE associated_message_type IN (2000, 2001, 2003, 2004)
      AND associated_message_guid IS NOT NULL
    GROUP BY g
    """

let amusedSQL = """
    SELECT
      CASE
        WHEN instr(associated_message_guid, '/') > 0
          THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
        ELSE associated_message_guid
      END AS g,
      COUNT(*) AS c
    FROM message
    WHERE associated_message_type IN (2000, 2003, 2004)
      AND is_from_me = 0
      AND associated_message_guid IS NOT NULL
    GROUP BY g
    """

let laughedSQL = """
    SELECT
      CASE
        WHEN instr(associated_message_guid, '/') > 0
          THEN substr(associated_message_guid, instr(associated_message_guid, '/') + 1)
        ELSE associated_message_guid
      END AS g,
      COUNT(*) AS c
    FROM message
    WHERE associated_message_type = 2003
      AND is_from_me = 0
      AND associated_message_guid IS NOT NULL
    GROUP BY g
    """

let msgSQL = """
    SELECT m.date AS date, cmj.chat_id AS chat_id, m.is_from_me AS is_from_me,
           h.id AS handle, m.text AS text, m.attributedBody AS body,
           m.guid AS guid, m.item_type AS item_type
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.associated_message_type = 0
    ORDER BY m.date DESC
    LIMIT ?
    """

struct Context {
    let contacts: Contacts
    let amused: [String: Int]
    let amusedFromOthers: [String: Int]
    let laughedFromOthers: [String: Int]
    let oneOnOne: Set<Int64>
}

func buildMessage(from r: RawMessageRow, context: Context) -> VernacularMessage? {
    let body = decodedBody(text: r.text, blob: r.blob)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    if containsURL(body.lowercased()) { return nil }
    let who = resolveWho(rawHandle: r.handle, fromMe: r.fromMe, contacts: context.contacts)
    let epoch = Double(r.date) / 1e9 + 978_307_200
    let uptake = Double(context.amused[r.guid] ?? 0) * 1.5
    let amusedFlag = r.fromMe && (context.amusedFromOthers[r.guid] ?? 0) > 0
    let laughedFlag = r.fromMe && (context.laughedFromOthers[r.guid] ?? 0) > 0
    return VernacularMessage(
        date: epoch,
        chat: r.chat,
        fromMe: r.fromMe,
        who: who,
        body: body,
        uptake: uptake,
        amused: amusedFlag,
        laughed: laughedFlag,
        isOneOnOne: context.oneOnOne.contains(r.chat),
        itemType: r.itemType
    )
}

func readRawRow(_ stmt: OpaquePointer?) -> RawMessageRow {
    RawMessageRow(
        date: sqlite3_column_int64(stmt, 0),
        chat: sqlite3_column_int64(stmt, 1),
        fromMe: sqlite3_column_int64(stmt, 2) == 1,
        handle: colText(stmt, 3),
        text: colText(stmt, 4),
        blob: colBlob(stmt, 5),
        guid: colText(stmt, 6) ?? "",
        itemType: sqlite3_column_int64(stmt, 7)
    )
}

func finalizeCorpus(_ messages: inout [VernacularMessage]) {
    messages.sort { $0.date < $1.date }
    for i in messages.indices { messages[i].messageID = i }
    addDownstreamAmusement(&messages)
}

func addDownstreamAmusement(_ messages: inout [VernacularMessage]) {
    var byChat: [Int64: [Int]] = [:]
    for (i, m) in messages.enumerated() {
        byChat[m.chat, default: []].append(i)
    }
    for (_, idxs) in byChat {
        for a in 0..<idxs.count {
            let i = idxs[a]
            var bonus = 0.0
            var b = a + 1
            while b < idxs.count, b <= a + 3 {
                let j = idxs[b]
                if messages[j].date - messages[i].date > 900 { break }
                if messages[j].who != messages[i].who, isAmusement(messages[j].bodyLow) {
                    bonus += 1.0
                }
                b += 1
            }
            if bonus > 0 {
                let updated = VernacularMessage(
                    date: messages[i].date,
                    chat: messages[i].chat,
                    fromMe: messages[i].fromMe,
                    who: messages[i].who,
                    body: messages[i].body,
                    uptake: messages[i].uptake + min(bonus, 3),
                    amused: messages[i].amused,
                    laughed: messages[i].laughed,
                    isOneOnOne: messages[i].isOneOnOne,
                    itemType: messages[i].itemType
                )
                messages[i] = updated
                messages[i].messageID = i
            }
        }
    }
}

func loadReferenceFingerprints(db: OpaquePointer?, context: Context) -> (rows: Int, fingerprints: [MessageFingerprint]) {
    guard let stmt = prepareOrExit(db, msgSQL, label: "reference message SQL") else { return (0, []) }
    sqlite3_bind_int64(stmt, 1, sqlite3_int64(maxMessages))
    var messages: [VernacularMessage] = []
    messages.reserveCapacity(max(0, min(maxMessages, 600_000)))
    var rows = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows += 1
        if rows % 50_000 == 0 { err("[reference] streamed \(rows) rows") }
        let raw = readRawRow(stmt)
        let decoded: VernacularMessage? = autoreleasepool {
            buildMessage(from: raw, context: context)
        }
        if let decoded { messages.append(decoded) }
    }
    sqlite3_finalize(stmt)
    finalizeCorpus(&messages)
    let fps = messages.map(fingerprint)
    messages.removeAll(keepingCapacity: false)
    return (rows, fps)
}

func decodeBatch(_ batch: [RawMessageRow], context: Context, sampler: PeakSampler) -> [VernacularMessage?] {
    var built = [VernacularMessage?](repeating: nil, count: batch.count)
    guard !batch.isEmpty else { return built }
    built.withUnsafeMutableBufferPointer { buf in
        nonisolated(unsafe) let out = buf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: batch.count) { i in
            if (i & 1023) == 0 { sampler.sample() }
            let decoded: VernacularMessage? = autoreleasepool {
                buildMessage(from: batch[i], context: context)
            }
            (out + i).pointee = decoded
        }
    }
    sampler.sample()
    return built
}

func loadNewBatched(db: OpaquePointer?, context: Context, sampler: PeakSampler) -> (rows: Int, messages: [VernacularMessage]) {
    guard let stmt = prepareOrExit(db, msgSQL, label: "new batched message SQL") else { return (0, []) }
    sqlite3_bind_int64(stmt, 1, sqlite3_int64(maxMessages))
    let batchSize = 8_192
    var batch: [RawMessageRow] = []
    batch.reserveCapacity(batchSize)
    var messages: [VernacularMessage] = []
    messages.reserveCapacity(max(0, min(maxMessages, 600_000)))
    var rows = 0

    func drain() {
        guard !batch.isEmpty else { return }
        sampler.sample()
        let decoded = decodeBatch(batch, context: context, sampler: sampler)
        for case let message? in decoded {
            messages.append(message)
        }
        batch.removeAll(keepingCapacity: true)
        sampler.sample()
    }

    while sqlite3_step(stmt) == SQLITE_ROW {
        rows += 1
        if rows % 50_000 == 0 {
            err("[new] streamed \(rows) rows; peak phys_footprint \(String(format: "%.1f", mb(sampler.peak))) MB")
        }
        batch.append(readRawRow(stmt))
        if batch.count >= batchSize { drain() }
    }
    drain()
    sqlite3_finalize(stmt)
    finalizeCorpus(&messages)
    sampler.sample()
    return (rows, messages)
}

// MARK: - Run

guard let db = openDB(chatDBPath) else {
    err("FATAL: cannot open \(chatDBPath) (Full Disk Access?)")
    exit(1)
}

print("════════════════════════════════════════════════════════")
print(" VERNACULAR LOADMESSAGES OOM HARNESS")
print("════════════════════════════════════════════════════════")
print("  db:                 \(chatDBPath)")
print("  maxMessages:        \(maxMessages)")
print(String(format: "  memory limit:       %.0f MB phys_footprint", memoryLimitMB))

err("[setup] loading contacts + scalar reaction maps")
let contacts = loadContacts()
let context = Context(
    contacts: contacts,
    amused: reactionMap(db: db, sql: reactionSQL),
    amusedFromOthers: reactionMap(db: db, sql: amusedSQL),
    laughedFromOthers: reactionMap(db: db, sql: laughedSQL),
    oneOnOne: oneOnOneSet(db: db)
)
print("  resolved handles:   \(contacts.byHandle.count)")
print("  amused guids:       \(context.amused.count)")
print("  amused-from-others: \(context.amusedFromOthers.count)")
print("  laughed guids:      \(context.laughedFromOthers.count)")
print("  1:1 chats:          \(context.oneOnOne.count)")

err("[new] running batched loadMessages mirror with peak sampler")
let sampler = PeakSampler()
let newResult = loadNewBatched(db: db, context: context, sampler: sampler)
var newMessages = newResult.messages
let newFingerprints = newMessages.map(fingerprint)
let newCount = newMessages.count
newMessages.removeAll(keepingCapacity: false)

let memoryOK = sampler.peak > 0 && sampler.peak < memoryLimitBytes

err("[reference] running independent sequential reference decode")
let reference = loadReferenceFingerprints(db: db, context: context)
sqlite3_close(db)

var mismatches = 0
let compareCount = min(reference.fingerprints.count, newFingerprints.count)
func describe(_ fp: MessageFingerprint) -> String {
    let prefix = fp.body
        .replacingOccurrences(of: "\n", with: " ")
        .prefix(120)
    return "id=\(fp.messageID) dateBits=\(fp.dateBits) chat=\(fp.chat) 1to1=\(fp.isOneOnOne) item=\(fp.itemType) fromMe=\(fp.fromMe) who=\(fp.who) bytes=\(fp.bodyByteCount) uptakeBits=\(fp.uptakeBits) amused=\(fp.amused) laughed=\(fp.laughed) poll=\(fp.isPoll) body=\"\(prefix)\""
}
for i in 0..<compareCount {
    if reference.fingerprints[i] != newFingerprints[i] {
        mismatches += 1
        if mismatches <= 20 {
            print("  MISMATCH[\(i)]")
            print("    REF \(describe(reference.fingerprints[i]))")
            print("    NEW \(describe(newFingerprints[i]))")
        }
    }
}
if reference.fingerprints.count != newFingerprints.count {
    mismatches += abs(reference.fingerprints.count - newFingerprints.count)
}

print("\n──── results ────")
print("  new rows scanned:       \(newResult.rows)")
print("  ref rows scanned:       \(reference.rows)")
print("  new decoded messages:   \(newCount)")
print("  ref decoded messages:   \(reference.fingerprints.count)")
print("  ordered mismatches:     \(mismatches)")
print(String(format: "  new peak footprint:     %.1f MB", mb(sampler.peak)))
print(String(format: "  memory limit:           %.1f MB", memoryLimitMB))

var checks: [(String, Bool)] = []
func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }
check("Same SQL row count", newResult.rows == reference.rows)
check("Same decoded count", newCount == reference.fingerprints.count)
check("Same ascending order, messageIDs, exact bodies, senders, flags, uptake", mismatches == 0)
check("NEW batched load peak phys_footprint under limit", memoryOK)

print("\n════════════════════════════════════════════════════════")
var passed = 0
for (name, ok) in checks {
    print("  \(ok ? "PASS" : "FAIL")  \(name)")
    if ok { passed += 1 }
}
print("════════════════════════════════════════════════════════")
print("  \(passed)/\(checks.count) checks passed")
exit(passed == checks.count ? 0 : 1)
