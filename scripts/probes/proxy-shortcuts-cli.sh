#!/bin/bash
# proxy-shortcuts-cli.sh — Hypothesis A
#
# Probe whether we can build a Shortcut that calls ChatKit.OpenMessageIntent
# and run it via /usr/bin/shortcuts. If Shortcuts.app is privileged (i.e. has
# the entitlement to invoke private system AppIntents), it would call the
# intent on our behalf — bypassing the entitlement gate that bit us in
# docs/messages-private-ipc.md.
#
# Three sub-probes:
#   A.1 verify the CLI works and we have shortcuts
#   A.2 build a `.shortcut` plist that calls OpenMessageIntent via the
#       AppIntent runner (WFAppIntentExecutionAction)
#   A.3 install the shortcut into the user's library and `shortcuts run` it
#
# We test against a synthetic GUID (probe-test) — the empirical question is
# whether the call dispatches at all, not whether Messages navigates to a real
# bubble. If the call dispatches but Messages doesn't navigate, that's the
# same entitlement gate (negative). If the call dispatches AND Messages
# navigates, we found it.

set -uo pipefail

PROBE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d -t bm-shortcuts-probe.XXXXXX)"
trap "rm -rf $WORK_DIR" EXIT
echo "[probe] workdir: $WORK_DIR"

echo ""
echo "=== A.1: Verify shortcuts CLI ==="
which shortcuts && shortcuts list 2>&1 | head -3 || { echo "FAIL: no shortcuts"; exit 1; }

echo ""
echo "=== A.2: Build a Shortcut plist with OpenMessageIntent ==="
# The shortcut runs ChatKit.OpenMessageIntent(target: MessageEntity(GUID))
# via WFAppIntentExecutionAction. The relevant action identifier is the
# "fully qualified link action identifier" from the AppIntents metadata.

# We craft the workflow plist directly — the simplest viable form. The
# WFAppIntentExecutionAction identifier embeds the mangled type name and the
# action identifier from `extract.actionsdata`. Two formats observed in
# practice:
#
#   Format 1 (linkaction):
#     WFWorkflowActionIdentifier = "com.apple.MobileSMS.OpenMessageIntent"
#   Format 2 (appintents executor):
#     WFWorkflowActionIdentifier = "com.apple.WorkflowKit.AppIntent.OpenMessageIntent"
#
# Try multiple format guesses. Use python to write a clean binary plist.

python3 - <<PY
import plistlib

# Action invoking the OpenMessageIntent. The parameter "target" is a
# MessageEntity referenced by GUID. We craft an LNEntity-shaped parameter.
target_guid = "ABCDEF12-3456-7890-ABCD-EF1234567890"

# Try the most likely format first: a generic AppIntent action whose
# identifier mirrors the LNAction.
actions = [
    {
        "WFWorkflowActionIdentifier": "com.apple.WorkflowKit.RunAppIntent",
        "WFWorkflowActionParameters": {
            "AppIntentIdentifier": "OpenMessageIntent",
            "AppIntentMangledTypeName": "7ChatKit17OpenMessageIntentV",
            "AppIntentBundleIdentifier": "com.apple.MobileSMS",
            "target": {
                "Value": {
                    "Identifier": target_guid,
                    "TypeName": "MessageEntity",
                },
                "WFSerializationType": "WFAppIntentEntityValue",
            },
        },
    }
]

workflow = {
    "WFWorkflowClientVersion": "2607.0.4",
    "WFWorkflowMinimumClientVersion": 1500,
    "WFWorkflowMinimumClientVersionString": "1500",
    "WFWorkflowIcon": {
        "WFWorkflowIconStartColor": 431817727,
        "WFWorkflowIconGlyphNumber": 61440,
    },
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": [],
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowActions": actions,
}
with open("$WORK_DIR/bm-reveal.plist", "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
print("Wrote bm-reveal.plist")
PY
ls -la "$WORK_DIR/bm-reveal.plist"

echo ""
echo "=== A.3: Sign via shortcuts CLI ==="
# Modern macOS expects a signed shortcut. Sign with people-who-know-me mode
# (local cert) so we don't need to upload to iCloud.
shortcuts sign --mode anyone --input "$WORK_DIR/bm-reveal.plist" --output "$WORK_DIR/BMReveal.shortcut" 2>&1
ls -la "$WORK_DIR/BMReveal.shortcut" 2>&1

echo ""
echo "=== A.4: Open with Shortcuts.app to import ==="
# Opening a .shortcut file in Shortcuts.app prompts the user to add it.
# We can't auto-accept this, but we can at least confirm the file is well-formed.
file "$WORK_DIR/BMReveal.shortcut" 2>&1
echo ""
echo "shortcut head bytes:"
xxd "$WORK_DIR/BMReveal.shortcut" 2>/dev/null | head -5

echo ""
echo "=== A.5: Try to run from CLI (without installing) ==="
# `shortcuts run` accepts only installed shortcuts by name/UUID. Test what
# happens if we try a name that doesn't exist yet.
shortcuts run "BM Reveal Test Does Not Exist" 2>&1 | head -5

echo ""
echo "[probe] Done. See docs/messages-private-proxy.md for verdict."
