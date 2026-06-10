#!/bin/zsh
# Build + run the Nostalgia cursor mem-fix behavior-preservation harness.
# Runs the EXACT production message query (the ChatStoryBuilder+DB CTE) two ways
# over the user's real chat.db — materialize (old fetchAll shape) vs stream (new
# fetchCursor shape) — and proves they yield identical rows + identical decoded
# bodies, while reporting the blob-residency memory reduction.
#
# Reuses the REAL typedstream decoder so the bodies match production exactly.
#
# Usage (from repo root):  ./scripts/probes/run-nostalgia-cursor-memfix-harness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/nostalgia-cursor-memfix-harness"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/nostalgia-cursor-memfix-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" \
  "$ROOT/Sources/Data/Typedstream.swift" \
  "$ROOT/Sources/Data/AttributedBodyDecoder.swift" \
  "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
