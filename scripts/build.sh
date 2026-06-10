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
run_xcodebuild() {
    xcodebuild \
        -project Hourglass.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -destination "platform=macOS" \
        -derivedDataPath build \
        -skipMacroValidation \
        build
}

# ----------------------------------------------------------------------
# Run xcodebuild EXACTLY ONCE and read its REAL exit status.
# ----------------------------------------------------------------------
# The previous form was:
#     xcodebuild ... build | xcbeautify 2>/dev/null || xcodebuild ... build
# which is unsafe two ways and could ship a STALE binary that still printed
# "BUILD SUCCEEDED":
#   1. `| xcbeautify` makes the pipeline's status xcbeautify's, not
#      xcodebuild's — so the `||` fallback fired whenever xcbeautify was
#      merely missing or errored, NOT only when the build failed.
#   2. When xcbeautify is absent the read end of the pipe is dead; the first
#      xcodebuild takes a SIGPIPE mid-build, then the `||` fallback xcodebuild
#      resumes over that half-written incremental state and can SKIP
#      recompiling changed app sources — i.e. a silent stale binary.
# Fix: detect xcbeautify explicitly (no SIGPIPE games), pipe through it only
# when present, and take xcodebuild's status from PIPESTATUS[0] — never the
# tail of the pipe. set +e so pipefail/-e don't abort before we read it.
set +e
if command -v xcbeautify >/dev/null 2>&1; then
    run_xcodebuild | xcbeautify
    BUILD_STATUS=${PIPESTATUS[0]}
else
    run_xcodebuild
    BUILD_STATUS=${PIPESTATUS[0]}
fi
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "✗ xcodebuild failed (exit status $BUILD_STATUS)" >&2
    exit "$BUILD_STATUS"
fi

# ----------------------------------------------------------------------
# Guard: fail loudly on a silent stale binary.
# ----------------------------------------------------------------------
# Even after a single, clean-exit xcodebuild, assert the build actually
# recompiled what changed: every app source that has a compiled object must
# be no newer than that object. If a source is NEWER than its own `.o` after
# the build, xcodebuild did not recompile it and the binary runs OLD code —
# the exact failure this script was hardened against. Sources with no matching
# object (excluded from the target, or whole-module-merged) are skipped, so
# this never false-positives on files that don't emit a per-file object.
OBJ_DIR="build/Build/Intermediates.noindex/Hourglass.build/${CONFIG}/Hourglass.build/Objects-normal/$(uname -m)"
if [ -d "$OBJ_DIR" ]; then
    STALE=""
    while IFS= read -r src; do
        obj="$OBJ_DIR/$(basename "${src%.swift}").o"
        if [ -f "$obj" ] && [ "$src" -nt "$obj" ]; then
            STALE="${STALE}    ${src}"$'\n'
        fi
    done < <(find Sources -name '*.swift')
    if [ -n "$STALE" ]; then
        echo "" >&2
        echo "✗ STALE BUILD: xcodebuild reported success but did NOT recompile" >&2
        echo "  these changed source(s) (object older than source):" >&2
        printf "%s" "$STALE" >&2
        echo "  The resulting binary would run OLD code. This is a build-system" >&2
        echo "  fault, not a compile error. Recover with:" >&2
        echo "      find Sources -name '*.swift' -exec touch {} + && ./scripts/build.sh" >&2
        exit 1
    fi
fi

APP_PATH="build/Build/Products/${CONFIG}/Hourglass.app"
if [ -d "$APP_PATH" ]; then
    echo ""
    echo "✓ Built: $APP_PATH"

    # ------------------------------------------------------------------
    # Stable-identity post-build re-sign (local Debug + Release)
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
    # Both configs are re-signed for LOCAL running: Debug for stable TCC
    # (rationale above), and Release because the embedded Sparkle.framework
    # ships with its own Team ID — without a unifying --deep re-sign, dyld
    # aborts at launch ("different Team IDs"). Distribution + notarization
    # still goes through scripts/package.sh, not this script.
    if [ "$CONFIG" = "Debug" ] || [ "$CONFIG" = "Release" ]; then
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
