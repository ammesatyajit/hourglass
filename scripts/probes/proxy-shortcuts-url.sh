#!/bin/bash
# proxy-shortcuts-url.sh — Hypothesis B
#
# Test the `shortcuts://run-shortcut?name=…` URL scheme as a dispatch path.
# This sends our request through LaunchServices → Shortcuts.app's URL handler,
# which then triggers the shortcut via the Shortcuts runtime. Even though we
# concluded in Hypothesis A that Shortcuts.app lacks the foreign-bundle
# entitlement, the URL scheme may dispatch through *coreservicesd* or another
# privileged broker — verify empirically.

set -uo pipefail

echo "=== B.1: Confirm scheme is handled ==="
# This will pop the "no app" dialog if unhandled.
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$lsregister" -dump 2>&1 | awk '/shortcuts:/{found=1} found' | head -20

echo ""
echo "=== B.2: Open shortcuts:// (just app open) ==="
open "shortcuts://" 2>&1
sleep 1
osascript -e 'tell application "System Events" to set _x to name of every application process whose frontmost is true' 2>&1
echo ""
sleep 1

echo "=== B.3: shortcuts://run-shortcut with a known existing shortcut ==="
# Test it works at all
open "shortcuts://run-shortcut?name=Take%20a%20Break" 2>&1
sleep 2

echo ""
echo "=== B.4: Can shortcuts:// URL invoke an arbitrary AppIntent? ==="
# Documented x-callback-url style and known parameters from Apple docs:
#   shortcuts://run-shortcut?name=<name>&input=<input>&x-success=<url>&x-error=<url>
#   shortcuts://x-callback-url/run-shortcut?...
# There's also an undocumented form for running raw App Intents:
#   shortcuts://?action=open  (opens the editor)
echo "tests will involve installing a shortcut first; deferred to A.3 path"
echo ""
echo "[probe] Done. See docs/messages-private-proxy.md for verdict."
