#!/usr/bin/env bash
# Package Hourglass.app into a signed, notarized DMG. After notarization,
# also produce a Sparkle EdDSA signature for the DMG and print the
# `<item>` block to paste into the appcast feed.
#
# Required env (set in your shell, NEVER commit):
#   DEVELOPER_ID         e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE       keychain profile name from `xcrun notarytool store-credentials`
#
# Optional env:
#   SPARKLE_PRIVATE_KEY  path to a file containing the base64 EdDSA private
#                        key (output of `bin/generate_keys -p`). If unset,
#                        sign_update reads from the macOS Keychain
#                        (`generate_keys` defaults to storing the key
#                        there under the name "Private key for signing
#                        Sparkle updates"). NEVER COMMIT THIS FILE — keep
#                        it on the developer machine outside any tracked
#                        directory (e.g. `~/.config/hourglass/sparkle.key`,
#                        mode 0600).
#   SPARKLE_DOWNLOAD_URL the https URL where this DMG will be hosted (used
#                        in the printed <item> block). Defaults to the
#                        GitHub Releases download URL for the matching
#                        tag — `gh release create vX.Y.Z dist/<DMG>` is the
#                        expected publish step. Override only if you're
#                        hosting DMGs elsewhere.
#
# Usage:
#   DEVELOPER_ID="..." NOTARY_PROFILE="..." ./scripts/package.sh
#   DEVELOPER_ID="..." NOTARY_PROFILE="..." SPARKLE_PRIVATE_KEY=~/.config/hourglass/sparkle.key ./scripts/package.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_ID:-}" ]; then
    echo "error: DEVELOPER_ID not set" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "error: NOTARY_PROFILE not set" >&2
    exit 1
fi

# Build Release.
./scripts/generate.sh

xcodebuild \
    -project Hourglass.xcodeproj \
    -scheme Hourglass \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath build \
    -skipMacroValidation \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build

# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO above tells Xcode to use ONLY the
# entitlements declared in Resources/Hourglass.entitlements — without it,
# Xcode auto-injects com.apple.security.get-task-allow=true (the
# "let-a-debugger-attach" entitlement, fine for Debug, forbidden by
# notarization). Apple's notary service rejects builds carrying this
# entitlement with status=Invalid, message "The executable requests the
# com.apple.security.get-task-allow entitlement."

APP_PATH="build/Build/Products/Release/Hourglass.app"
DMG_PATH="build/Hourglass.dmg"

# ---------------------------------------------------------------------------
# Re-sign Sparkle's nested executables.
#
# xcodebuild's CODE_SIGN_IDENTITY only signs the top-level app + first-party
# frameworks. The Sparkle.framework ships with its own pre-signed nested
# executables (Updater.app, Autoupdate, Downloader.xpc, Installer.xpc) that
# DO NOT inherit our Developer ID + secure timestamp. Apple's notary service
# rejects the bundle with:
#   "The binary is not signed with a valid Developer ID certificate."
#   "The signature does not include a secure timestamp."
#
# Fix per Sparkle docs (https://sparkle-project.org/documentation/sandboxing/
# #code-signing): re-sign each nested binary with our Developer ID + a secure
# timestamp + the hardened runtime flag, deepest-first, then re-sign the
# framework, then re-sign the app. `--preserve-metadata=entitlements,flags`
# keeps Sparkle's own entitlements intact (the XPC services need them).
# ---------------------------------------------------------------------------
SPARKLE_VERSION_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
for target in \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION_DIR/Autoupdate" \
    "$SPARKLE_VERSION_DIR/Updater.app" \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"; do
    if [ -e "$target" ]; then
        codesign --force --sign "$DEVELOPER_ID" \
            --timestamp \
            --options runtime \
            --preserve-metadata=entitlements,flags \
            "$target"
    fi
done

# Re-sign the app itself with our own entitlements (NOT preserved — we want
# Resources/Hourglass.entitlements to win, which `codesign --force` on the
# bundle pulls in via the embedded .plist).
codesign --force --sign "$DEVELOPER_ID" \
    --timestamp \
    --options runtime \
    --entitlements Resources/Hourglass.entitlements \
    "$APP_PATH"

# Sanity check the signature.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Build the DMG.
rm -f "$DMG_PATH"
create-dmg \
    --volname "Hourglass" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Hourglass.app" 175 190 \
    --app-drop-link 425 190 \
    --hdiutil-quiet \
    "$DMG_PATH" \
    "$APP_PATH"

# Sign the DMG itself.
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG_PATH"

# Notarize and staple.
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"

echo ""
echo "✓ Signed + notarized: $DMG_PATH"

# ---------------------------------------------------------------------------
# Sparkle EdDSA signature for the DMG.
#
# The signature is what the running app's Sparkle copy verifies before
# installing an update — it pairs with the SUPublicEDKey we shipped in
# Info.plist. Without it, the appcast `<item>` block is meaningless and
# the updater will refuse the download.
#
# We locate `sign_update` inside the SPM-resolved Sparkle xcframework. The
# binary travels with the package; we don't need a separate brew install.
# ---------------------------------------------------------------------------
SIGN_UPDATE=""
for candidate in \
    "build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
    "build/SourcePackages/artifacts/Sparkle/Sparkle/bin/sign_update" \
    "$(xcrun --find sign_update 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        SIGN_UPDATE="$candidate"
        break
    fi
done

if [ -z "$SIGN_UPDATE" ]; then
    echo ""
    echo "⚠ sign_update not found in SourcePackages or PATH."
    echo "  Skipping Sparkle signature step. Run xcodebuild once with the"
    echo "  Sparkle SPM dep resolved, then re-run this script."
    exit 0
fi

# Run sign_update. The output is one line of attributes:
#   sparkle:edSignature="…" length="…"
# which we capture verbatim and embed in the appcast <item> block below.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    if [ ! -r "$SPARKLE_PRIVATE_KEY" ]; then
        echo "error: SPARKLE_PRIVATE_KEY=$SPARKLE_PRIVATE_KEY is not readable" >&2
        exit 1
    fi
    # `-f <file>` reads the base64 private key from disk instead of the
    # default Keychain entry. Useful in CI where the keychain isn't unlocked.
    SPARKLE_SIG_ATTRS="$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY" "$DMG_PATH")"
else
    # Default path: sign_update reads "Private key for signing Sparkle updates"
    # from the login keychain. Requires the dev machine to have run
    # `bin/generate_keys` at least once.
    SPARKLE_SIG_ATTRS="$("$SIGN_UPDATE" "$DMG_PATH")"
fi

# Derive the values we need for the appcast XML.
DMG_FILENAME="$(basename "$DMG_PATH")"
# Pull MARKETING_VERSION + CURRENT_PROJECT_VERSION out of the built app so the
# appcast item matches what the binary self-reports. PlistBuddy is the right
# tool here — `defaults read` silently fails when the path has a `.plist`
# extension on a relative path, producing the placeholder "0.0.0" in the
# printed <item> block.
APP_PLIST="$APP_PATH/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo "0.0.0")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo "0")"
PUB_DATE="$(LC_TIME=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")"
# GitHub Releases is the default DMG host — tag convention is `vX.Y.Z` and
# the DMG is attached as a release asset. Override with SPARKLE_DOWNLOAD_URL
# if you're hosting elsewhere.
DOWNLOAD_URL="${SPARKLE_DOWNLOAD_URL:-https://github.com/ammesatyajit/hourglass/releases/download/v${APP_VERSION}/${DMG_FILENAME}}"

echo ""
echo "✓ Sparkle signed: $DMG_PATH"
echo ""
echo "----- Paste into appcast.xml (inside <channel>) ----------------------"
cat <<EOF
        <item>
            <title>Version ${APP_VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${APP_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                type="application/octet-stream"
                ${SPARKLE_SIG_ATTRS} />
        </item>
EOF
echo "----------------------------------------------------------------------"
