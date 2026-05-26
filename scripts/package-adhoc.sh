#!/usr/bin/env bash
# Build Hourglass as an AD-HOC-SIGNED DMG.
#
# What this gives you:
#   - A .dmg you can install on your own Mac (passes Gatekeeper because it's
#     re-signed with your local "Apple Development" cert).
#   - A .dmg you can hand to friends — they right-click → Open the first
#     time to bypass Gatekeeper's "unidentified developer" warning. Or run
#     `xattr -dr com.apple.quarantine /Applications/Hourglass.app`.
#
# What this does NOT give you:
#   - Notarization. macOS will warn on first launch for any Mac other than
#     yours. For seamless distribution, use scripts/package.sh which needs
#     a Developer ID Application cert + notarytool creds.
#
# Usage:
#   ./scripts/package-adhoc.sh
#
# Output: build/Hourglass.dmg
#
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT_DIR="$(pwd)"
PACKAGE_CACHE_PATH="${PACKAGE_CACHE_PATH:-$ROOT_DIR/build/PackageCache}"
CLONED_PACKAGES_PATH="${CLONED_PACKAGES_PATH:-$ROOT_DIR/build/SourcePackages}"
XCODEBUILD_HOME="${XCODEBUILD_HOME:-$ROOT_DIR/build/Home}"

mkdir -p "$PACKAGE_CACHE_PATH" "$CLONED_PACKAGES_PATH" "$XCODEBUILD_HOME"

# ---------------------------------------------------------------------------
# 1. Pick a signing identity. Prefer the developer's "Apple Development"
#    cert (stable across rebuilds, TCC remembers grants). Falls back to
#    pure ad-hoc if no real cert is present.
# ---------------------------------------------------------------------------
IDENTITY="-"
if security find-identity -p codesigning -v 2>/dev/null \
        | grep -q "Apple Development:"; then
    IDENTITY="Apple Development"
elif security find-identity -p codesigning -v 2>/dev/null \
        | grep -q "Hourglass Dev"; then
    IDENTITY="Hourglass Dev"
fi
echo "→ signing with: $IDENTITY"

# ---------------------------------------------------------------------------
# 2. Build a clean Release.
# ---------------------------------------------------------------------------
echo "→ regenerating Xcode project"
./scripts/generate.sh >/dev/null

echo "→ building Release (this takes a minute on cold cache)"
HOME="$XCODEBUILD_HOME" CFFIXED_USER_HOME="$XCODEBUILD_HOME" xcodebuild \
    -project Hourglass.xcodeproj \
    -scheme Hourglass \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath build \
    -clonedSourcePackagesDirPath "$CLONED_PACKAGES_PATH" \
    -packageCachePath "$PACKAGE_CACHE_PATH" \
    -skipMacroValidation \
    build \
    2>&1 | (xcbeautify 2>/dev/null || cat) | tail -5

APP_PATH="build/Build/Products/Release/Hourglass.app"
if [ ! -d "$APP_PATH" ]; then
    echo "error: $APP_PATH not produced — check xcodebuild output above" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Post-build re-sign with the stable identity so the bundle CDHash
#    matches across rebuilds (TCC grants survive future iterations).
# ---------------------------------------------------------------------------
ENT="$(pwd)/Resources/Hourglass.entitlements"
echo "→ re-signing $APP_PATH"
codesign --force --deep \
    --sign "$IDENTITY" \
    --entitlements "$ENT" \
    --options runtime \
    "$APP_PATH" 2>&1 | grep -v "replacing existing signature" || true

# Verify the signature actually held — `--verify` doesn't lie even on
# ad-hoc signatures.
codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | tail -3

# ---------------------------------------------------------------------------
# 4. Build the DMG via create-dmg.
# ---------------------------------------------------------------------------
DMG_PATH="build/Hourglass.dmg"
rm -f "$DMG_PATH"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "error: create-dmg not installed. Run: brew install create-dmg" >&2
    exit 1
fi

echo "→ packing DMG"
create-dmg \
    --volname "Hourglass" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Hourglass.app" 175 190 \
    --app-drop-link 425 190 \
    --hdiutil-quiet \
    "$DMG_PATH" \
    "$APP_PATH" >/dev/null

# Sign the DMG itself so Gatekeeper at least sees a consistent identity.
codesign --sign "$IDENTITY" --timestamp=none "$DMG_PATH" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Done.
# ---------------------------------------------------------------------------
SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "✓ Built ad-hoc-signed DMG: $DMG_PATH  ($SIZE)"
echo ""
echo "On your own Mac:"
echo "  open $DMG_PATH    # mount it, drag the app to /Applications"
echo ""
echo "For friends on other Macs (one-time per machine):"
echo "  1. Mount the DMG, drag the app to /Applications"
echo "  2. Right-click Hourglass.app → Open → confirm (bypasses"
echo "     the 'unidentified developer' Gatekeeper warning ONCE)"
echo "  3. OR run: xattr -dr com.apple.quarantine /Applications/Hourglass.app"
echo ""
echo "For seamless distribution: see scripts/package.sh (needs Developer ID +"
echo "notarytool — requires Apple Developer Program membership)."
