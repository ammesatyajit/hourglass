#!/usr/bin/env bash
# Run the Hourglass test suite.
# Regenerates the project from project.yml first so newly-added test files
# (or project.yml changes) are picked up. Exits non-zero on test failure.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
SCHEME="${SCHEME:-Hourglass}"

# Regenerate so fresh files in Tests/ get into the project.
./scripts/generate.sh

# Try xcbeautify if installed, otherwise raw xcodebuild output.
# `set -o pipefail` keeps xcodebuild's exit code through xcbeautify.
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild \
        -project Hourglass.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS" \
        -derivedDataPath build \
        -skipMacroValidation \
        test \
        | xcbeautify
else
    xcodebuild \
        -project Hourglass.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS" \
        -derivedDataPath build \
        -skipMacroValidation \
        test
fi

echo ""
echo "✓ Tests passed"
