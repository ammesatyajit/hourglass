#!/bin/zsh
# Build + run the tokenized vernacular corpus parity harness with swiftc -O.
#
# Usage:
#   ./scripts/probes/run-vern-tokenized-corpus-parity.sh \
#     /path/to/Hourglass.app/Contents/MacOS/Hourglass ["You,Contact Name"]
#
# The harness runs the real app twice per subject with
# `vernacular.profile.tokenizedCorpus` OFF then ON and diffs the normalized
# HOURGLASS_PANEL_BENCH profile dump. It is intentionally out-of-band so it can
# exercise the real corpus/load path after the operator builds the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/vern-tokenized-corpus-parity"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/vern-tokenized-corpus-parity-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" "$TMP/main.swift"

echo "built -> $OUT"
"$OUT" "$@"
