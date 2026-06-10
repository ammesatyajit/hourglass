#!/bin/zsh
# Build + run the Nostalgia PERF Pass B GOLDEN OLD-vs-NEW parity harness with
# swiftc -O over the user's REAL chat.db.
#
#  PART 1 — ChatStory: OLD (full-corpus body decode) vs NEW (metadata-only +
#    targeted WHERE-ROWID-IN hydration of origin+peak rows only). Both feed the
#    REAL pure ChatStoryBuilder. 0 moment mismatches required.
#  PART 2 — Romantic: OLD sequential accumulate vs NEW parallel striped
#    accumulate over the same 1:1 rows. Flagged-name set + per-contact Signals
#    must be identical.
#
# Usage (from repo root):  ./scripts/probes/run-nostalgia-metadata-parity.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="$ROOT/Sources/Dashboard/Nostalgia"
TMP="$(mktemp -d)"
OUT="$TMP/nostalgia-metadata-parity"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/nostalgia-metadata-parity-harness.swift" "$TMP/main.swift"

# Minimal BelovedMessagesLoader shim — the pure builder calls only
# `BelovedMessagesLoader.isCoordination(_:)`; reproduce its phrase list VERBATIM
# from the real file so the exclusion behaviour matches production exactly.
cat > "$TMP/BelovedShim.swift" <<'SWIFT'
import Foundation
public struct BelovedMessagesLoader {
    static let coordinationPhrases: [String] = [
        "react to this", "react if", "like this message",
        "love the message", "love this message",
        "headcount", "head count",
        "if you can make it", "if u are coming", "if you're coming", "if youre coming",
        "rsvp", "final count", "react ❤️", "🤍 if",
    ]
    public static func isCoordination(_ body: String) -> Bool {
        let low = body.lowercased()
        for phrase in coordinationPhrases where low.contains(phrase) { return true }
        return false
    }
}
SWIFT

swiftc -O -o "$OUT" \
  "$ROOT/Sources/Data/Typedstream.swift" \
  "$ROOT/Sources/Data/AttributedBodyDecoder.swift" \
  "$N/NostalgiaMomentModels.swift" \
  "$N/ChatStoryBuilder.swift" \
  "$N/RomanticDetector.swift" \
  "$TMP/BelovedShim.swift" \
  "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
