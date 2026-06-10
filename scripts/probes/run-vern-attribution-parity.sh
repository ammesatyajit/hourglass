#!/bin/zsh
# Build + run the occurrence-index attribution PARITY harness with swiftc -O.
# Compiles the REAL new VernacularAttributionIndex.swift + REAL typedstream
# decoder against a raw-SQLite3 scan of the user's real chat.db, and diffs the
# new occurrence-index attribution vs a verbatim inline copy of the OLD
# scan-based attribute(). 0 mismatches required (speed change, not behavior).
#
# Usage (from repo root):  ./scripts/probes/run-vern-attribution-parity.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
I="$ROOT/Sources/Dashboard/Insights"
TMP="$(mktemp -d)"
OUT="$TMP/vern-attribution-parity"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/vern-attribution-parity-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" \
  "$ROOT/Sources/Data/Typedstream.swift" \
  "$ROOT/Sources/Data/AttributedBodyDecoder.swift" \
  "$I/VernacularAttributionIndex.swift" \
  "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
