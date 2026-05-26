#!/usr/bin/env bash
# Regenerate Hourglass.xcodeproj from project.yml via XcodeGen.
# Run this any time project.yml changes.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not installed. Run: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --quiet
echo "Generated Hourglass.xcodeproj"
