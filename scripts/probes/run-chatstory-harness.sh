#!/bin/zsh
# Build + run the per-chat "notable moments" verification harness with swiftc -O.
# Compiles the REAL pure builder + REAL typedstream decoder against a raw-SQLite3
# scan of the user's real chat.db that mirrors ChatStoryBuilder+DB.swift.
#
# Usage (from repo root):  ./scripts/probes/run-chatstory-harness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="$ROOT/Sources/Dashboard/Nostalgia"
TMP="$(mktemp -d)"
OUT="$TMP/chatstory-harness"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/chatstory-harness.swift" "$TMP/main.swift"

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
  "$TMP/BelovedShim.swift" \
  "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
