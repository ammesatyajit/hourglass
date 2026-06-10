#!/bin/zsh
# Build + run the VernacularLoader.loadMessages OOM parity/memory harness.
# It compiles the REAL typedstream decoder and a standalone raw-SQLite mirror of
# the new bounded-batch loader, then runs over the user's real chat.db.
#
# Optional environment:
#   HOURGLASS_CHAT_DB=/path/to/chat.db
#   HOURGLASS_VERN_MAX_MESSAGES=1000000
#   HOURGLASS_VERN_MEMORY_LIMIT_MB=2048
#
# Usage (from repo root): ./scripts/probes/run-vernacular-loadmessages-oom-harness.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/vernacular-loadmessages-oom.XXXXXX)"
OUT="$TMP/vernacular-loadmessages-oom-harness"

# swiftc only allows top-level statements in a file literally named main.swift.
cp "$ROOT/scripts/probes/vernacular-loadmessages-oom-harness.swift" "$TMP/main.swift"

swiftc -O -o "$OUT" \
  "$ROOT/Sources/Data/Typedstream.swift" \
  "$ROOT/Sources/Data/AttributedBodyDecoder.swift" \
  "$TMP/main.swift"

echo "built -> $OUT"
"$OUT"
