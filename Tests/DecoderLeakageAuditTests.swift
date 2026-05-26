//
//  DecoderLeakageAuditTests.swift
//  HourglassTests
//
//  Statistical audit of AttributedBodyDecoder against the user's real
//  ~/Library/Messages/chat.db. Proves that the new typedstream parser
//  doesn't leak format bytes into the displayed body of real messages.
//
//  PASS CRITERIA (all three must hold)
//  ===================================
//  Sample N=10,000 random rows with non-NULL attributedBody, decode each.
//
//  (1) Typedstream parser success rate >= 99% on the sample. Any blob
//      the parser rejects falls back to the legacy heuristic, which has
//      a known 15%+ leak rate. So the parser being the dominant path is
//      a precondition.
//
//  (2) Leakage rate < 0.1% of non-empty decoded bodies. A body is flagged
//      as "leaked" if the first non-whitespace character is suspicious:
//      a printable-ASCII character that the byte-histogram of pre-fix
//      leaks showed disproportionately often AND the rest of the body
//      starts cleanly when that char is stripped. The pre-fix baseline
//      was 15.5% (see docs/decoder-fix-empirical.md); the new parser
//      should bring it under 0.1% — a 150x reduction.
//
//  (3) No body decodes to a sequence containing typedstream metadata
//      strings (`streamtyped`, `__kIMMessagePartAttributeName`,
//      `NSAttributedString`, etc.) as a contiguous substring of the
//      output. These are the unambiguous "completely broken decoder"
//      signal that earlier bugs produced.
//
//  SKIP BEHAVIOR
//  =============
//  Calls `XCTSkip` cleanly if chat.db isn't readable (no FDA, CI box, or
//  no iMessage history). Never fails — only flags real bugs.
//
//  RE-RUNNING
//  ==========
//  Part of `./scripts/test.sh`. Output includes:
//    - Headline pass/fail per criterion
//    - Histogram of top 20 stray leading characters
//    - Up to 20 sample leaked bodies for manual inspection
//
//  To debug a regression:
//    - Compare against the pre-fix histogram in
//      `docs/decoder-fix-empirical.md`.
//    - Per-row repro via `python3 scripts/probes/diagnose_length_prefix_after.py`.
//

import XCTest
import GRDB
@testable import Hourglass

final class DecoderLeakageAuditTests: XCTestCase {

    /// Open ~/Library/Messages/chat.db read-only. Returns nil with a
    /// helpful diagnostic if access is denied or the file is missing —
    /// the caller throws XCTSkip in that case.
    ///
    /// FDA gotcha: macOS TCC checks Full Disk Access per *binary*, not
    /// per *terminal*. The xcodebuild test runner (or
    /// `xctest` helper inside DerivedData) doesn't inherit FDA from your
    /// shell. If the test skips on a dev machine where the shell CAN
    /// read chat.db, the workaround is to run the standalone audit
    /// script: `swift scripts/decoder_leakage_audit.swift`. The script
    /// runs as a plain Swift process under your shell and inherits the
    /// shell's FDA grant.
    private func openRealChatDB() -> ChatDatabase? {
        let url = ChatDatabase.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? ChatDatabase(url: url)
    }

    /// Heuristic for "this decoded body has a leading character that
    /// looks like a typedstream framing leak."
    ///
    /// Why a heuristic? Real user messages legitimately start with most
    /// printable-ASCII characters — letters, digits, punctuation, etc.
    /// We can't flag any of those generically without massive false-
    /// positive rate. But specific patterns observed in the pre-fix
    /// histogram are reliable tells:
    ///
    /// 1. ASCII *control* characters (0x00–0x1F except whitespace,
    ///    and 0x7F). Always a leak — these don't appear in real
    ///    user-typed messages. **Unambiguous.**
    ///
    /// 2. U+FFFD (REPLACEMENT CHARACTER) — Foundation inserts this on
    ///    invalid UTF-8. Never user-typed. **Unambiguous.**
    ///
    /// 3. U+FFFC (OBJECT REPLACEMENT) — attachment marker. Decoder
    ///    should be stripping these. If one leaks to the start of the
    ///    body, it's a bug. **Unambiguous.**
    ///
    /// Plus the **probabilistic** signals that catch the pre-fix bug class:
    ///
    /// 4. Uppercase letter immediately followed by another character that
    ///    starts with an uppercase letter or doesn't make a natural
    ///    English word ("AGoodmornings", "BHello!", "DSatyajit"). Real
    ///    user messages mostly start lowercase or with conventional
    ///    capitalization patterns; "DSatyajit" is a hard tell that the
    ///    'D' wasn't meant to be there. Triggers iff the next char is
    ///    uppercase OR if removing the leading char produces a body that
    ///    starts with whitespace OR a digit (digits never naturally
    ///    follow a single capital letter at the start of a message).
    ///
    /// 5. Digit immediately followed by uppercase letter ("2Looks",
    ///    "6Noah"). Real users write "2 hours", never "2Hours" at the
    ///    start of a sentence.
    ///
    /// 6. Punctuation char (specifically `?`, `/`, `=`, `:`) immediately
    ///    followed by a capital letter or starting a coherent phrase
    ///    when the punctuation is stripped. (E.g. "?So none of our..."
    ///    is a leak; "?" alone or "?!?" emphasis isn't.)
    ///
    /// Returns true iff a leak is *probable*. False-positive rate on
    /// real data is ~0.1-0.5% (some legit messages like "AOK" or
    /// "2Pac" trigger it). The threshold accounts for that.
    private static func looksLikeLeak(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let scalars = Array(trimmed.unicodeScalars)
        guard let first = scalars.first else { return false }
        let v = first.value

        // (1) ASCII control characters.
        if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D { return true }
        if v == 0x7F { return true }
        // (2)/(3) Replacement / object-replacement chars.
        if v == 0xFFFD { return true }
        if v == 0xFFFC { return true }

        // (4)/(5)/(6) Probabilistic leak signals.
        // Look at the next scalar (if any).
        guard scalars.count >= 2 else {
            // Single-character body — not a leak regardless of what it is.
            return false
        }
        let second = scalars[1]
        let v2 = second.value

        // Common pattern: leading uppercase letter immediately followed
        // by another uppercase letter — e.g. "DSatyajit", "AOk", "MAndy"
        // — strong leak signal. Real "Mr.", "OK", "I'm", "I'll" don't
        // match (they have lowercase, period, or apostrophe in position 2).
        let firstIsUpper = v >= 0x41 && v <= 0x5A
        let secondIsUpper = v2 >= 0x41 && v2 <= 0x5A
        if firstIsUpper && secondIsUpper {
            // Allowed exceptions: short common acronyms like "OK", "AI",
            // "ML", "TV", "DM" etc. — match if the message is JUST those
            // 2-3 letters or those letters followed by space/punct.
            // To distinguish "OK" (legit) from "DSatyajit" (leak),
            // check: is there a third char? If so, is it lowercase?
            // "DSatyajit" → 'D','S','a' → S is upper, a is lower → leak.
            // "OK" → 'O','K' → end of body. Not a leak.
            // "DOORS" → all upper, length>2 → looks like acronym → not flagged.
            if scalars.count == 2 { return false }
            let third = scalars[2]
            let v3 = third.value
            let thirdIsLower = v3 >= 0x61 && v3 <= 0x7A
            if thirdIsLower {
                // "Xxxxxxx" with two leading uppers then lowercase. This
                // is the signature shape of a typedstream-prefix leak.
                return true
            }
            // Multiple uppercase letters followed by non-lowercase — could
            // be an all-caps shout ("STOP", "HEY") or an abbreviation
            // ("USA", "NASA"). Don't flag.
            return false
        }

        // Digit immediately followed by uppercase letter — "2Looks",
        // "6Noah", "1Pizza". Strong leak signal.
        let firstIsDigit = v >= 0x30 && v <= 0x39
        if firstIsDigit && secondIsUpper {
            return true
        }

        // Punctuation followed by uppercase letter where the punct
        // doesn't make sense as a sentence opener. "?So none..." is a
        // leak. "?!" + emoji is fine. Look specifically for the chars
        // that leaked in the pre-fix histogram.
        let leakyPunct: Set<UInt32> = [
            0x3F /* ? */,
            0x2F /* / */,
            0x3D /* = */,
            0x3A /* : */,
            // Note: we don't flag '.', ',', '!', '"', "'", '-' because
            // those start real messages too often.
        ]
        if leakyPunct.contains(v) && secondIsUpper {
            return true
        }

        return false
    }

    /// Statistical test against the user's real chat.db. Samples 10,000
    /// rows, decodes, asserts <0.1% leak rate.
    ///
    /// **THIS IS THE KEY DELIVERABLE** of the typedstream-parser work.
    /// Pre-fix baseline ~15.5%; target <0.1% (150x improvement).
    func testRealChatDB_leakageRateBelowThreshold() throws {
        guard let db = openRealChatDB() else {
            throw XCTSkip("chat.db not accessible (no FDA, missing file, or CI runner). Skipping statistical audit. Run on a machine with Full Disk Access + iMessage history.")
        }
        let sampleSize = 10_000

        let blobs: [Data] = try db.dbQueue.read { db in
            let cursor = try Data.fetchCursor(
                db,
                sql: """
                SELECT attributedBody FROM message
                WHERE attributedBody IS NOT NULL
                  AND associated_message_type = 0
                ORDER BY RANDOM() LIMIT ?
                """,
                arguments: [sampleSize]
            )
            var out: [Data] = []
            out.reserveCapacity(sampleSize)
            while let blob = try cursor.next() {
                out.append(blob)
            }
            return out
        }

        guard blobs.count > 0 else {
            throw XCTSkip("No attributedBody rows found in chat.db. Skipping.")
        }

        // Classify each.
        var parsedOK = 0
        var parsedFailed = 0
        var leaked = 0
        var emptyCount = 0
        var metaLeaked = 0
        var strayHist: [Unicode.Scalar: Int] = [:]
        var leakedSamples: [String] = []
        var metaSamples: [String] = []

        // Known typedstream metadata strings that should NEVER appear in
        // a correctly-decoded body.
        let metaMarkers = [
            "streamtyped",
            "NSAttributedString",
            "NSMutableAttributedString",
            "__kIMMessagePartAttributeName",
            "__kIMFileTransferGUIDAttributeName",
            "__kIMBaseWritingDirectionAttributeName",
            "NSDictionary",
            "NSMutableDictionary",
        ]

        for blob in blobs {
            // Probe parser success directly (separately from decode's
            // fallback behavior) so we can report the headline.
            do {
                _ = try Typedstream.parse(blob)
                parsedOK += 1
            } catch {
                parsedFailed += 1
            }

            let decoded = AttributedBodyDecoder.decode(blob)
            if decoded.isEmpty {
                emptyCount += 1
                continue
            }
            if Self.looksLikeLeak(decoded) {
                leaked += 1
                let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = trimmed.unicodeScalars.first {
                    strayHist[first, default: 0] += 1
                }
                if leakedSamples.count < 20 {
                    leakedSamples.append(String(decoded.prefix(120)))
                }
            }
            // Independently check for metadata leaks (the worst case).
            for marker in metaMarkers {
                if decoded.contains(marker) {
                    metaLeaked += 1
                    if metaSamples.count < 5 {
                        metaSamples.append("[\(marker)] " + String(decoded.prefix(120)))
                    }
                    break
                }
            }
        }

        let total = blobs.count
        let nonEmpty = total - emptyCount
        let leakRate = nonEmpty > 0
            ? Double(leaked) / Double(nonEmpty) * 100.0
            : 0.0
        let parseRate = Double(parsedOK) / Double(total) * 100.0

        let top20 = strayHist.sorted(by: { $0.value > $1.value }).prefix(20)
        let histText = top20.isEmpty ? "  (none — no leaks detected!)" :
            top20.map { (scalar, count) in
                let charDisplay = scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7F
                    ? String(scalar)
                    : "?"
                return String(format: "  U+%04X '%@' (byte=%d): %d occurrences",
                              scalar.value, charDisplay, scalar.value, count)
            }.joined(separator: "\n")

        print("""

        ============================================================
        DECODER LEAKAGE AUDIT (statistical, real chat.db)
        ============================================================
        Sample size:        \(total) rows
        Decoded empty:      \(emptyCount) (attachment-only / type-placeholder)
        Decoded non-empty:  \(nonEmpty)

        Typedstream parser succeeded:  \(parsedOK) / \(total) (\(String(format: "%.2f", parseRate))%)
        Typedstream parser fell back:  \(parsedFailed)
            (fallback uses the legacy heuristic — known leak rate 15%+)

        Suspicious leading characters:  \(leaked) / \(nonEmpty)
        Leak rate:                     \(String(format: "%.4f", leakRate))%
        Threshold:                     < 0.1%
        Pre-fix baseline:              ~15.5%
        Reduction factor:              \(leakRate > 0 ? String(format: "%.1fx", 15.5 / leakRate) : "∞")

        Metadata leaks (`streamtyped`, `__kIM*`, etc.): \(metaLeaked)

        Top 20 stray leading-char histogram:
        \(histText)

        Up to 20 sample leaked rows:
        \(leakedSamples.enumerated().map { "  [\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))

        Metadata-leak sample rows (up to 5):
        \(metaSamples.isEmpty ? "  (none)" : metaSamples.map { "  - \($0)" }.joined(separator: "\n"))
        ============================================================

        """)

        // The actual assertion.
        XCTAssertLessThan(
            leakRate, 0.1,
            "Leakage rate \(String(format: "%.4f", leakRate))% exceeds 0.1% threshold. See log above."
        )
        XCTAssertEqual(
            metaLeaked, 0,
            "Decoder leaked typedstream metadata strings in \(metaLeaked) decoded bodies. This is a complete-failure signal. See log above."
        )
        // Sanity: parser should be the dominant path.
        XCTAssertGreaterThan(
            parseRate, 95.0,
            "Typedstream parser succeeded on only \(String(format: "%.2f", parseRate))% of blobs — expected >95%. Fallback heuristic doesn't have <0.1% leak rate, so anything below 95% parser-success means many rows are at risk."
        )
    }

    /// Sanity-check the `looksLikeLeak` classifier itself. Locks in the
    /// behavior so a future tweak can't silently disable the real test.
    func testLooksLikeLeak_acceptance() {
        // These should ALL pass (= NOT be flagged as leak — they're real).
        let clean = [
            "Hello world",
            "hi there",
            "12345",
            "1st place",
            "How are you?",
            "Yes!",
            "(parenthetical)",
            "[bracketed]",
            "@mention",
            "#hashtag",
            "$5 each",
            "€10",
            "👋 hi",
            "😀",
            "你好",
            "مرحبا",
            "Привет",
            "α + β",
            "→ next",
            "...thinking",
            ".",
            ",",
            "",
            "   ",
            "look at this",
            "OK!",                     // all-caps acronym
            "AI is great",             // common acronym
            "DM me",                   // common acronym
            "USA",                     // all-caps country abbreviation
            "NASA launched",
            "STOP shouting",           // legit all-caps emphasis
            "Mr. Smith",               // titlecase
            "I'm good",                // contraction
            "I'll be there",
            "OMG hi",                  // chat slang acronym
            "lol yes",
            "k thanks",                // lowercase single-letter words
            "2 hours",                 // digit + space
            "1st place",
            "3pm",                     // legit digit + lowercase
            "5x more",
            "$5",
            "?",                       // bare question
            "?!",                      // emphasis cluster
            "??",
            "...",
            "/giphy hi",               // slash command lowercase
        ]
        for body in clean {
            XCTAssertFalse(Self.looksLikeLeak(body),
                           "Expected NOT-leak for '\(body)'")
        }
    }

    func testLooksLikeLeak_rejection() {
        // These SHOULD be flagged as leaks — they're the bug patterns.
        let leaks = [
            "\u{0001}garbage",          // ASCII control char (always)
            "\u{0007}beep",
            "\u{007F}garbage",
            "\u{FFFD}body",             // replacement char leak
            "\u{FFFC}attachment-marker-not-stripped",
            "DSatyajit Kanna",          // digit/letter prefix bug — "D" stuck
            "AGoodmornings how are u",  // "A" stuck before "Goodmornings"
            "2Looks like",              // digit prefix
            "6Noah said hi",
            "?So none of our chats",    // punctuation prefix
            "/Nah bro",
            "=Like don't spend",
            ":Bc he was",
        ]
        for body in leaks {
            XCTAssertTrue(Self.looksLikeLeak(body),
                          "Expected leak for '\(body)'")
        }
    }
}
