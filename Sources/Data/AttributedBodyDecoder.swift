//
//  AttributedBodyDecoder.swift
//  Hourglass
//
//  Decodes `message.attributedBody` (a binary NSAttributedString typedstream)
//  to a plain-text String suitable for substring search and display.
//
//  HOW THIS WORKS NOW
//  ==================
//  1. **Primary path** — call `Typedstream.extractString(from:)` to parse
//     the blob as a real `NSArchiver` typedstream and pull out the
//     underlying `NSString` value. This is the *correct* approach: it
//     understands length prefixes, attachment markers, class definitions,
//     back-references — every quirk the format throws at us.
//  2. **Fallback path** — if the typedstream parser rejects the blob
//     (corrupted, truncated, ancient NeXTSTEP variant, or some
//     newer-format wrapper Apple introduces in the future), fall back to
//     the legacy lossy-UTF-8 + longest-printable-run heuristic. We keep
//     this for resilience; any blob that triggers it is logged so we can
//     track residual unparseable cases.
//
//  The typedstream parser also gives us correct handling of two more cases
//  that the legacy heuristic only patched with band-aids:
//    - **U+FFFC attachment markers** — these are stored INSIDE the
//      NSString's text, not as separate values. We strip them
//      post-parsing for display purposes (they render as invisible
//      placeholder boxes; callers want the type label "Image" instead).
//    - **NSAttributedString-only attachment messages** — the parser
//      returns an NSString whose text is "￼" (or empty); we return ""
//      so the higher-level type-placeholder fires.
//
//  WHY THE HEURISTIC PATH STAYS
//  ============================
//  Some real-world blobs in the user's chat.db DO fail to parse. The
//  legacy approach got those rows roughly right by accident (longest
//  printable run heuristic was crude but resilient). The typedstream
//  parser is strict — when it can't parse, it can't parse. We don't want
//  to surface a parse error to the user; we want a best-effort decode.
//  So the heuristic stays, gated to triggers only when the parser fails.
//
//  Pure. No I/O, no global state.
//

import Foundation
import os

public enum AttributedBodyDecoder {

    /// Decode the attributed-body blob to a best-effort plain-text string.
    /// Returns an empty string if the blob is nil/empty or yields no
    /// extractable text.
    ///
    /// Primary path: real typedstream parser (`Typedstream.extractString`).
    /// Fallback path: legacy lossy-UTF-8 + longest-printable-run heuristic,
    /// only used when the parser throws.
    public static func decode(_ blob: Data?) -> String {
        guard let blob, !blob.isEmpty else { return "" }
        // Primary: try the real parser.
        do {
            if let raw = try Typedstream.extractString(from: blob) {
                return postprocess(raw)
            }
            // Parsed successfully but didn't find an NSString — treat as
            // empty body (attachment-only messages with no inner NSString
            // are valid and decode to nothing).
            return ""
        } catch {
            // Parser rejected the blob. Log + fall through to heuristic.
            // This shouldn't happen for any healthy chat.db row but it's
            // possible for: truncated blobs, unknown Messages.app variants,
            // or our parser missing an Objective-C type encoding we
            // haven't seen yet.
            Self.fallbackLogger.debug("AttributedBodyDecoder: typedstream parse failed (\(String(describing: error), privacy: .public)); using legacy heuristic")
            return legacyDecode(blob)
        }
    }

    /// Internal post-process: take the raw NSString value from the parser
    /// and clean it up for display/search.
    ///
    /// Specifically:
    ///   - Strip U+FFFC (OBJECT REPLACEMENT CHARACTER) attachment markers.
    ///     These are stored INSIDE the NSString's character sequence —
    ///     not as separate atoms — so the parser hands them through as
    ///     part of the text. They render as invisible placeholder boxes;
    ///     the caller wants the type-placeholder label ("Image" / "Video"
    ///     / etc.) for attachment-only messages, so we drop the markers
    ///     and let `body.isEmpty` upstream trigger the placeholder.
    ///   - Strip U+FFFD (REPLACEMENT CHARACTER) from the leading edge of
    ///     the body. These appear when the NSString payload contains
    ///     bytes that aren't valid UTF-8 — extremely rare in real chat.db
    ///     (~0.1% of messages) but they show as a "?" glyph that the
    ///     user never typed. We strip from the leading edge only; an
    ///     interior U+FFFD might genuinely be part of legitimate weird
    ///     content (a forwarded message with a question-mark glyph?),
    ///     so we don't blanket-strip.
    ///   - Trim outer whitespace.
    static func postprocess(_ raw: String) -> String {
        // Fast path: no special scalars — just trim.
        let hasFFFC = raw.unicodeScalars.contains(where: { $0.value == 0xFFFC })
        let hasLeadingFFFD = raw.unicodeScalars.first?.value == 0xFFFD
        if !hasFFFC && !hasLeadingFFFD {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        var trimmedLeading = false
        for s in raw.unicodeScalars {
            if s.value == 0xFFFC { continue }
            if !trimmedLeading && s.value == 0xFFFD {
                // Skip leading replacement characters — they're never
                // user content.
                continue
            }
            if !trimmedLeading && (s.value == 0x20 || s.value == 0x09 || s.value == 0x0A) {
                // Skip leading whitespace alongside the U+FFFD strip so
                // we don't surface a body that starts with stray space.
                continue
            }
            trimmedLeading = true
            out.append(s)
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Logger for the fallback-path debug message. Public-but-internal so
    /// callers can subscribe / silence in tests.
    static let fallbackLogger = Logger(subsystem: "com.satyajit.bettermessages", category: "AttributedBodyDecoder.fallback")

    // MARK: - Legacy heuristic path (fallback only)

    /// The pre-typedstream-parser decoder, retained as a fallback for blobs
    /// that fail to parse. Approach: lossy UTF-8 decode → split into
    /// "printable" runs (U+FFFD, U+FFFC, and control chars are separators)
    /// → strip framing-edge characters from each → drop runs that match
    /// known metadata patterns → return the longest survivor.
    ///
    /// Kept identical to the prior implementation (modulo the
    /// stripLengthPrefix tweak — see below) so historical regression tests
    /// still pass. The proper path is `Typedstream.extractString`; this
    /// fallback exists only for resilience.
    static func legacyDecode(_ blob: Data) -> String {
        let decoded = String(decoding: blob, as: UTF8.self)
        let candidates = printableRuns(in: decoded, minimumLength: 2)
            .map(strippedFraming)
            .filter { !$0.isEmpty && !looksLikeMetadata($0) }
        if let best = candidates.max(by: { $0.count < $1.count }) {
            return best
        }
        return longestEmojiRun(in: decoded)
    }

    /// Longest contiguous run of emoji / ZWJ-sequence scalars in `string`.
    /// Used as a last-resort fallback for pure-emoji message bodies that
    /// the printable-run extractor rejects as too short.
    static func longestEmojiRun(in string: String) -> String {
        var best = String.UnicodeScalarView()
        var current = String.UnicodeScalarView()
        func reset() {
            if current.count > best.count { best = current }
            current.removeAll(keepingCapacity: true)
        }
        for s in string.unicodeScalars {
            let v = s.value
            let isEmojiLike =
                v >= 0x10000 ||                       // supplementary planes
                v == 0x200D ||                        // ZWJ
                (v >= 0xFE00 && v <= 0xFE0F) ||       // variation selectors
                (v >= 0x2600 && v <= 0x27BF)          // misc symbols
            if isEmojiLike {
                current.append(s)
            } else {
                reset()
            }
        }
        reset()
        return String(best)
    }

    /// All printable runs in `string` at least `minimumLength` characters
    /// long. "Printable" excludes ASCII control chars, U+FFFD (lossy-UTF-8
    /// marker), and U+FFFC (NSAttributedString attachment marker).
    public static func printableRuns(in string: String, minimumLength: Int) -> [String] {
        var runs: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if current.count >= minimumLength {
                runs.append(String(current))
            }
            current.removeAll(keepingCapacity: true)
        }
        for scalar in string.unicodeScalars {
            if isPrintable(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0xFFFD { return false }
        if v == 0xFFFC { return false }
        if v >= 0x20 && v <= 0x7E { return true }
        if v == 0x09 || v == 0x0A { return true }
        if v >= 0xA0 && v <= 0xFFFB { return true }
        if v >= 0x10000 && v <= 0x10FFFF { return true }
        return false
    }

    static func strippedFraming(_ run: String) -> String {
        let edges = CharacterSet(charactersIn: "+@()[]{}<>!*&^%$#\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}")
            .union(.whitespacesAndNewlines)
        let trimmed = run.trimmingCharacters(in: edges)
        return stripLengthPrefix(trimmed)
    }

    /// Legacy heuristic for stripping a typedstream length prefix that
    /// survived the lossy-UTF-8 decode as a printable ASCII char.
    ///
    /// Strip iff the leading scalar's byte value equals the rest's UTF-8
    /// byte length. Only fires for blobs that bypassed the typedstream
    /// parser — that's the fallback path's job. For correctly-parsed
    /// blobs, the parser handles length prefixes natively and this is
    /// never invoked.
    static func stripLengthPrefix(_ run: String) -> String {
        guard let first = run.unicodeScalars.first else { return run }
        let v = Int(first.value)
        guard v >= 0x20 && v <= 0x7E else { return run }
        let rest = String(run.unicodeScalars.dropFirst())
        if rest.utf8.count == v { return rest }
        // Digit-then-uppercase fallback for blobs with trailing metadata
        // glued on (throws off the byte count). Kept for the legacy path
        // because real-world hits show this pattern (e.g. "6Noah", "2Looks").
        if (0x30...0x39).contains(v),
           let secondScalar = rest.unicodeScalars.first,
           secondScalar.value >= 0x41 && secondScalar.value <= 0x5A {
            return rest
        }
        return run
    }

    /// True if the run is typedstream metadata (class name or IMCore
    /// attribute key) rather than user text. Conservative — only known
    /// patterns. Used by the legacy fallback path only; the typedstream
    /// parser handles metadata structurally.
    static func looksLikeMetadata(_ run: String) -> Bool {
        let exactMatches: Set<String> = [
            "streamtyped",
            "NSObject",
            "NSString", "NSMutableString",
            "NSAttributedString", "NSMutableAttributedString",
            "NSDictionary", "NSMutableDictionary",
            "NSArray", "NSMutableArray",
            "NSNumber", "NSValue",
            "NSData", "NSMutableData",
            "NSDate", "NSUUID", "NSURL",
            "iI",
        ]
        if exactMatches.contains(run) { return true }
        if run.hasPrefix("__kIM") { return true }
        if run.hasPrefix("NS.") { return true }
        for marker in ["$version", "$archiver", "$objects", "$null", "$classname", "$classes"] {
            if run.contains(marker) { return true }
        }
        if run.hasPrefix("at_"),
           let firstUnderscore = run.dropFirst(3).firstIndex(of: "_"),
           run[run.startIndex..<firstUnderscore].dropFirst(3).allSatisfy(\.isNumber) {
            return true
        }
        if isCanonicalUUID(run) { return true }
        return false
    }

    /// True iff `run` is EXACTLY a canonical UUID (8-4-4-4-12 hex with
    /// hyphens, 36 chars, case-insensitive). Used by the legacy fallback's
    /// metadata filter.
    static func isCanonicalUUID(_ run: String) -> Bool {
        guard run.utf8.count == 36, run.count == 36 else { return false }
        let hyphens: Set<Int> = [8, 13, 18, 23]
        for (i, scalar) in run.unicodeScalars.enumerated() {
            let v = scalar.value
            if hyphens.contains(i) {
                if v != 0x2D { return false }
            } else {
                let isDigit = v >= 0x30 && v <= 0x39
                let isLowerHex = v >= 0x61 && v <= 0x66
                let isUpperHex = v >= 0x41 && v <= 0x46
                if !isDigit && !isLowerHex && !isUpperHex { return false }
            }
        }
        return true
    }
}
