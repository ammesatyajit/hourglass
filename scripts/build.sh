#!/usr/bin/env bash
# Build Hourglass.app for local development.
# For release builds, see scripts/package.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
SCHEME="${SCHEME:-Hourglass}"

# Regenerate project file in case project.yml changed.
./scripts/generate.sh

# `-skipMacroValidation` is required because mlx-swift-lm ships a Swift macro
# (`MLXHuggingFaceMacros`) that Xcode would otherwise refuse to run from
# headless `xcodebuild` until the user clicks Trust in the Xcode GUI. The
# flag opts the build out of the trust prompt — fine for our own packages.
xcodebuild \
    -project Hourglass.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath build \
    -skipMacroValidation \
    build \
    | xcbeautify 2>/dev/null || \
xcodebuild \
    -project Hourglass.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath build \
    -skipMacroValidation \
    build

APP_PATH="build/Build/Products/${CONFIG}/Hourglass.app"
if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✓ Built: $APP_PATH"

    # ------------------------------------------------------------------
    # Stable-identity post-build re-sign (Debug only)
    # ------------------------------------------------------------------
    # Why: ad-hoc signing produces a fresh CDHash on every rebuild, and
    # macOS TCC keys Full Disk Access grants on the CDHash for
    # ad-hoc-signed apps. Result: every rebuild forced the developer to
    # remove + re-add Hourglass to FDA. Re-signing with a stable
    # identity moves TCC's key to (cert + bundle id), which stays
    # constant across rebuilds — grant persists once and forever.
    #
    # Preference order:
    #   1. The developer's "Apple Development" cert (already in the
    #      keychain for anyone with a paid Apple Developer account).
    #   2. The "Hourglass Dev" self-signed cert created by
    #      `./scripts/setup-dev-identity.sh` (no Apple account needed).
    #   3. None — fall through with a one-line warning. The app still
    #      runs; the developer just sees the FDA churn every rebuild.
    if [ "$CONFIG" = "Debug" ]; then
        # Pick the first available identity in preference order.
        STABLE_ID=""
        if security find-identity -p codesigning -v 2>/dev/null \
                | grep -q "Apple Development:"; then
            STABLE_ID="Apple Development"
        elif security find-identity -p codesigning -v 2>/dev/null \
                | grep -q "Hourglass Dev"; then
            STABLE_ID="Hourglass Dev"
        fi

        if [ -n "$STABLE_ID" ]; then
            echo "  → re-signing with stable identity: $STABLE_ID"
            ENT="$(pwd)/Resources/Hourglass.entitlements"
            # --force replaces the ad-hoc signature; --deep covers the
            # MLX dylibs in the bundle. Entitlements re-applied so
            # network access (HF model download) survives the re-sign.
            codesign --force --deep \
                --sign "$STABLE_ID" \
                --entitlements "$ENT" \
                --options runtime \
                "$APP_PATH" >/dev/null 2>&1 || {
                    echo "  ⚠ re-sign failed; keeping ad-hoc signature."
                    echo "    TCC grants won't survive this rebuild."
                }
        else
            echo "  ⚠ no stable code-signing identity found"
            echo "    (TCC grants will reset on every rebuild)"
            echo "    fix: ./scripts/setup-dev-identity.sh"
        fi
    fi
fi
