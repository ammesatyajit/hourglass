#!/bin/zsh
# Build + run the Nostalgia depth-layer verification harness with `swiftc -O`.
# Compiles the REAL, GRDB-free detector source files together with the SQLite3
# harness main (+ shims). Runs against the user's real chat.db.
#
# Usage (from repo root):  ./scripts/probes/run-nostalgia-depth-harness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N="$ROOT/Sources/Dashboard/Nostalgia"
TMP="$(mktemp -d)"
OUT="$TMP/nostalgia-depth-harness"
# swiftc only allows top-level statements in a file literally named main.swift,
# so the harness (which has them) is compiled under that name.
cp "$ROOT/scripts/probes/nostalgia-depth-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" \
  "$ROOT/Sources/Data/Typedstream.swift" \
  "$ROOT/Sources/Data/AttributedBodyDecoder.swift" \
  "$N/RomanticDetector.swift" \
  "$N/StreakDetector.swift" \
  "$N/EraDetector.swift" \
  "$N/FunnyMomentsLoader.swift" \
  "$N/BelovedMessagesLoader.swift" \
  "$N/NostalgiaDismissals.swift" \
  "$N/NostalgiaDepthModels.swift" \
  "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
