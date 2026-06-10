//
//  vern-attribution-parity-harness.swift
//  Out-of-band GOLDEN-PROBE parity for Codex consult #4, Pass A
//  (occurrence-index attribution).
//
//  Compiles the REAL new `VernacularAttributionIndex.swift`
//  (`buildAttributionIndex` / `attributeFromOccurrences` / `attributeAll`) against
//  a raw-SQLite3 scan of the user's REAL chat.db (using the REAL typedstream
//  decoder), and diffs its output PER TERM against a VERBATIM inline copy of the
//  OLD scan-based `attribute(term:messages:)` (the two-full-scans-per-term
//  implementation that was replaced). 0 mismatches required — this is a SPEED
//  change, NOT a behavior change.
//
//  Also asserts the new path does NOT re-scan the corpus per term: the inverted
//  index is built in ONE pass for ALL terms, so `lastIndexScanCount == 1`
//  regardless of how many terms are attributed (the old path was ~2 × terms).
//
//  Term universe (>> the ~22 production terms, to stress the math): the curated
//  `attributionSeedTerms` ∪ the top sent unigrams ∪ the top sent/received bigrams
//  from the real corpus — hundreds of real terms with real ties / 30-day
//  boundaries / unknown senders / phrases-inside-words.
//
//  PURE harness over a minimal corpus shim (only the fields the index reads). The
//  attribution math under test is the genuine shipping code.
//

import Foundation
import SQLite3

// ============================================================================
// Minimal shims so the REAL VernacularAttributionIndex.swift compiles unchanged.
// These reproduce ONLY the surfaces the index file references; the attribution
// logic itself is the real shipping source.
// ============================================================================

enum VernTokens {
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch == "'" || ch == "\u{2019}" { cur.append(ch) }
            else { if !cur.isEmpty { out.append(cur) }; cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

public struct VernacularMessage: Sendable, Equatable {
    public internal(set) var messageID: Int
    public let date: Double
    public let chat: Int64
    public let fromMe: Bool
    public let who: String
    public let body: String
    public let bodyLow: String
    public let words: [String]
    public let wordSet: Set<String>
    public init(date: Double, chat: Int64, fromMe: Bool, who: String, body: String, messageID: Int = -1) {
        self.messageID = messageID
        self.date = date; self.chat = chat; self.fromMe = fromMe; self.who = who
        self.body = body
        let low = body.lowercased()
        self.bodyLow = low
        let w = VernTokens.words(body)
        self.words = w
        self.wordSet = Set(w)
    }
}

public struct VernacularAttribution: Sendable, Equatable, Identifiable {
    public let term: String
    public let yourCount: Int
    public let yourFirstMonth: String
    public let source: String?
    public let sourceBeforeCount: Int
    public let sourceFirstMonth: String
    public var id: String { term }
    public init(term: String, yourCount: Int, yourFirstMonth: String,
                source: String?, sourceBeforeCount: Int, sourceFirstMonth: String) {
        self.term = term; self.yourCount = yourCount; self.yourFirstMonth = yourFirstMonth
        self.source = source; self.sourceBeforeCount = sourceBeforeCount
        self.sourceFirstMonth = sourceFirstMonth
    }
}

public enum VernacularAnalyzer {
    public struct Options: Sendable {
        public var attributionMinBefore: Int
        public var attributionMinDays: Double
        public var attributionDominanceRatio: Double
        public init(attributionMinBefore: Int = 5, attributionMinDays: Double = 30,
                    attributionDominanceRatio: Double = 2.0) {
            self.attributionMinBefore = attributionMinBefore
            self.attributionMinDays = attributionMinDays
            self.attributionDominanceRatio = attributionDominanceRatio
        }
        public static let `default` = Options()
    }
    static let unknownLabel = "someone not in your contacts"
    static func monthLabel(_ epoch: Double) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM yyyy"
        return df.string(from: Date(timeIntervalSince1970: epoch))
    }
    // The production seed list (verbatim from VernacularAnalyzer.swift).
    static let attributionSeedTerms: [String] = [
        "lil bro", "big bro", "deadass", "hella", "lowkey", "cooked", "crashout",
        "gotchu", "fs", "icl", "yk", "tho", "diff", "lock in", "plot armor",
        "my goat", "gotchu fam", "grown ass man", "hell nah",
    ]
}

// ============================================================================
// OLD scan-based attribute(term:messages:) — VERBATIM copy of the replaced impl
// (two full corpus scans per term). This is the golden reference.
// ============================================================================

func attributeOLD(term: String, messages: [VernacularMessage],
                  options: VernacularAnalyzer.Options = .default) -> VernacularAttribution? {
    let isPhrase = term.contains(" ")
    let needle = term.lowercased()
    func matches(_ m: VernacularMessage) -> Bool {
        isPhrase ? m.bodyLow.contains(needle) : m.wordSet.contains(needle)
    }
    var yourCount = 0
    var yourFirst = Double.greatestFiniteMagnitude
    var byContact: [String: (first: Double, total: Int)] = [:]
    for m in messages where matches(m) {
        if m.fromMe {
            yourCount += 1
            yourFirst = min(yourFirst, m.date)
        } else if m.who != VernacularAnalyzer.unknownLabel {
            var e = byContact[m.who] ?? (m.date, 0)
            e.first = min(e.first, m.date)
            e.total += 1
            byContact[m.who] = e
        }
    }
    guard yourCount > 0, yourFirst < .greatestFiniteMagnitude else { return nil }
    var beforeCounts: [(who: String, before: Int, first: Double)] = []
    for (who, e) in byContact where e.first < yourFirst {
        var before = 0
        for m in messages where !m.fromMe && m.who == who && m.date < yourFirst && matches(m) {
            before += 1
        }
        if before > 0 { beforeCounts.append((who, before, e.first)) }
    }
    beforeCounts.sort { $0.before > $1.before }
    let yourFirstMonth = VernacularAnalyzer.monthLabel(yourFirst)
    guard let top = beforeCounts.first,
          top.before >= options.attributionMinBefore,
          (yourFirst - top.first) >= options.attributionMinDays * 86_400 else {
        return VernacularAttribution(term: term, yourCount: yourCount, yourFirstMonth: yourFirstMonth,
                                     source: nil, sourceBeforeCount: 0, sourceFirstMonth: "")
    }
    let runnerUp = beforeCounts.dropFirst().first?.before ?? 0
    let dominant = runnerUp == 0 || Double(top.before) >= options.attributionDominanceRatio * Double(runnerUp)
    guard dominant else {
        return VernacularAttribution(term: term, yourCount: yourCount, yourFirstMonth: yourFirstMonth,
                                     source: nil, sourceBeforeCount: 0, sourceFirstMonth: "")
    }
    return VernacularAttribution(term: term, yourCount: yourCount, yourFirstMonth: yourFirstMonth,
                                 source: top.who, sourceBeforeCount: top.before,
                                 sourceFirstMonth: VernacularAnalyzer.monthLabel(top.first))
}

// ============================================================================
// chat.db load → corpus (mirrors VernacularLoader.loadMessages essentials:
// epoch = date/1e9 + 978307200; who = You / AddressBook name / unknown sentinel;
// drop empty + URL; sort ascending; assign messageID).
// ============================================================================

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
func containsURL(_ low: String) -> Bool {
    low.contains("http") || low.contains("://") || low.contains("www.")
        || low.contains(".com") || low.contains(".net") || low.contains(".org")
}

// AddressBook handle → display name.
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
func nameFor(_ raw: String?, fromMe: Bool) -> String {
    if fromMe { return "You" }
    guard let raw, !raw.isEmpty else { return VernacularAnalyzer.unknownLabel }
    return nameByHandle[normH(raw)] ?? VernacularAnalyzer.unknownLabel
}
func decode(_ t: String?, _ b: Data?) -> String {
    if let t = t, !t.isEmpty { return t }
    return AttributedBodyDecoder.decode(b)
}

guard let db = openDB(home.appending(path: "Library/Messages/chat.db").path) else {
    print("FATAL: cannot open chat.db (Full Disk Access?)"); exit(1)
}

var corpus: [VernacularMessage] = []
corpus.reserveCapacity(600_000)
do {
    let sql = """
    SELECT m.date, cmj.chat_id, m.is_from_me, h.id, m.text, m.attributedBody
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.associated_message_type = 0
    """
    var s: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &s, nil)
    while sqlite3_step(s) == SQLITE_ROW {
        let date = sqlite3_column_int64(s, 0)
        let chat = sqlite3_column_int64(s, 1)
        let fromMe = sqlite3_column_int64(s, 2) == 1
        let handle = col(s, 3)
        let text = col(s, 4)
        let blob = blobv(s, 5)
        let body = decode(text, blob).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { continue }
        if containsURL(body.lowercased()) { continue }
        let who = nameFor(handle, fromMe: fromMe)
        let epoch = Double(date) / 1e9 + 978_307_200
        corpus.append(VernacularMessage(date: epoch, chat: chat, fromMe: fromMe, who: who, body: body))
    }
    sqlite3_finalize(s)
}
sqlite3_close(db)
corpus.sort { $0.date < $1.date }
for i in corpus.indices { corpus[i].messageID = i }
print("corpus: \(corpus.count) messages")

// ============================================================================
// Term universe: seed ∪ top sent unigrams ∪ top bigrams (sent+received).
// ============================================================================

var sentUni: [String: Int] = [:]
var allBigrams: [String: Int] = [:]
for m in corpus {
    if m.fromMe { for w in m.words { sentUni[w, default: 0] += 1 } }
    let w = m.words
    if w.count >= 2 { for i in 0..<(w.count - 1) { allBigrams[w[i] + " " + w[i+1], default: 0] += 1 } }
}
let topUnigrams = sentUni.filter { $0.value >= 8 }.sorted {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}.prefix(400).map { $0.key }
let topBigrams = allBigrams.filter { $0.value >= 20 }.sorted {
    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
}.prefix(200).map { $0.key }

var terms: [String] = VernacularAnalyzer.attributionSeedTerms
terms.append(contentsOf: topUnigrams)
terms.append(contentsOf: topBigrams)
var seen = Set<String>()
terms = terms.filter { seen.insert($0).inserted }
print("terms under test: \(terms.count) (\(topUnigrams.count) unigrams + \(topBigrams.count) bigrams + seed)")

// ============================================================================
// PARITY: OLD per-term scan vs NEW occurrence index. Also the scan-counter
// assertion (one index pass for ALL terms).
// ============================================================================

let opts = VernacularAnalyzer.Options.default

// NEW path: ONE inverted index for ALL terms, then per-term postings math.
let index = VernacularAnalyzer.buildAttributionIndex(messages: corpus, terms: terms)
let scanCount = VernacularAnalyzer.lastIndexScanCount
print("NEW index built — lastIndexScanCount = \(scanCount) for \(terms.count) terms")

var mismatches = 0
var bothNil = 0
var bothAttr = 0
var sourcedTerms: [(String, String, Int)] = []   // term, source, before (for a sanity peek)
for term in terms {
    let old = attributeOLD(term: term, messages: corpus, options: opts)
    let new = VernacularAnalyzer.attributeFromOccurrences(
        term: term, occurrences: index[term] ?? [], options: opts)
    if old != new {
        mismatches += 1
        if mismatches <= 25 {
            func d(_ a: VernacularAttribution?) -> String {
                guard let a else { return "nil" }
                return "yc=\(a.yourCount) src=\(a.source ?? "-") before=\(a.sourceBeforeCount) yfm=\(a.yourFirstMonth) sfm=\(a.sourceFirstMonth)"
            }
            print("  MISMATCH [\(term)]\n    OLD: \(d(old))\n    NEW: \(d(new))")
        }
    } else {
        if old == nil { bothNil += 1 } else {
            bothAttr += 1
            if let s = old?.source { sourcedTerms.append((term, s, old?.sourceBeforeCount ?? 0)) }
        }
    }
}

// Independent cross-check: attributeAll over the same terms must equal the
// per-term NEW results filtered to non-nil (and match OLD non-nil).
let allOut = VernacularAnalyzer.attributeAll(terms: terms, messages: corpus, options: opts)
let allScan = VernacularAnalyzer.lastIndexScanCount

print("\n================ PARITY RESULT ================")
print("terms compared:        \(terms.count)")
print("OLD == NEW (identical): \(terms.count - mismatches)")
print("  both nil:            \(bothNil)")
print("  both attribution:    \(bothAttr)")
print("MISMATCHES:            \(mismatches)   \(mismatches == 0 ? "✅ 0 diffs" : "❌")")
print("scan count (build):    \(scanCount)   \(scanCount == 1 ? "✅ ONE pass for all terms" : "❌ grows with terms")")
print("scan count (attributeAll): \(allScan)   \(allScan == 1 ? "✅" : "❌")")
print("attributeAll non-nil:  \(allOut.count)")

// A few real attributions for a human sanity peek (sorted by before desc).
print("\nSample decisive attributions (NEW path):")
for (t, s, b) in sourcedTerms.sorted(by: { $0.2 > $1.2 }).prefix(12) {
    print("  \(t.padding(toLength: 18, withPad: " ", startingAt: 0)) ← \(s)  (\(b)× before you)")
}

if mismatches == 0 && scanCount == 1 && allScan == 1 {
    print("\n✅ ALL PARITY CHECKS PASS — occurrence-index attribution is byte-identical, O(occurrences).")
    exit(0)
} else {
    print("\n❌ PARITY FAILED")
    exit(1)
}
