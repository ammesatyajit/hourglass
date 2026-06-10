#!/bin/zsh
# Build + run the PERF Pass C step-② COUNT/FIRST aggregate GOLDEN parity harness
# with swiftc -O over the user's REAL chat.db.
#
# Proves the NEW SQL/FTS aggregate path for MessageSearchTools.countMatching /
# firstMatching is byte-for-byte equivalent to the OLD materialized-search path
# for FILTER-ONLY queries (the only shapes the production gate optimizes), and
# that the gate is load-bearing for free-text queries (where it correctly
# falls back). 0 mismatches required.
#
# Usage (from repo root):  ./scripts/probes/run-count-aggregate-parity.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/count-aggregate-parity"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/count-aggregate-parity-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" "$TMP/main.swift"

echo "built → $OUT"
"$OUT"
