# Messages.app GUID-reveal via privileged proxies

Continuation of `docs/messages-private-ipc.md`. The prior investigation
concluded that `ChatKit.OpenMessageIntent` is the right intent and that we can
construct an `LNAction` end-to-end from our process, but the XPC dispatcher
silently drops the call because we lack
`com.apple.private.appintents.exception.allow-foreign-bundle-identifiers`.

**Hypothesis for this round**: the entitlement is checked on the *caller*.
Apple's own daemons (Shortcuts.app, coreservicesd, the Spotlight handler) DO
have the entitlement and can invoke ChatKit's hidden intent. Can we induce one
of them to call it on our behalf?

macOS 26.5 (Tahoe), Messages.app `1450.500.221.1.7`, Shortcuts.app `7.0`.
Testing date 2026-05-22.

## Five hypotheses

| # | Path | Result |
|---|------|--------|
| A | `/usr/bin/shortcuts` CLI — install/run a `.shortcut` that calls `OpenMessageIntent` | **NEGATIVE** — Shortcuts.app, siriactionsd, BackgroundShortcutRunner all lack the foreign-bundle entitlement. Even linkd (which has it) can't dispatch because Messages.app doesn't publish an AppIntent delegate endpoint to non-Apple-internal callers. |
| B | `shortcuts://run-shortcut?name=…&input=…` URL scheme | **NEGATIVE (by inheritance)** — same dispatch path as A, same gate. |
| C | Direct XPC to Shortcuts.app's mach services | **NEGATIVE (by inheritance)** — same gate. |
| D | `CSSearchableItem` publish + Spotlight continuation | **NEGATIVE** — see D below. |
| E | `NSUserActivity` + LaunchAgent / utility plug-in | **NEGATIVE (by inheritance)** — sibling-bundle helpers don't inherit Apple-only entitlements either. |

---

## Hypothesis A — Shortcuts CLI

(see `scripts/probes/proxy-shortcuts-cli.sh`,
`scripts/probes/proxy-build-shortcut.m`,
`scripts/probes/proxy-list-workflow-actions.m`,
`scripts/probes/proxy-linkd-services.m`)

### A.1 — Basic `shortcuts run` works

The `shortcuts` CLI is functional and can list/run user-installed shortcuts.

### A.2 — Hand-built `.shortcut` files

The `.shortcut` container is a binary plist of `WFWorkflowAction` dicts.
`WFAppIntentExecutionAction` is the subclass for App-Intent-backed actions —
carries `metadata: LNActionMetadata`, `fullyQualifiedLinkActionIdentifier`,
and `mangledTypeName`. We could in principle construct one targeting
`ChatKit.OpenMessageIntent` with a `MessageEntity(GUID)` parameter.

### A.3 — But: who actually has the foreign-bundle entitlement?

```
$ codesign -d --entitlements - /System/Applications/Shortcuts.app | grep foreign-bundle
(no match)
$ codesign -d --entitlements - /usr/libexec/siriactionsd | grep foreign-bundle
(no match)
$ codesign -d --entitlements - /System/Library/PrivateFrameworks/WorkflowKit.framework/XPCServices/BackgroundShortcutRunner.xpc | grep foreign-bundle
(no match)
```

**None of the Shortcuts execution layer has the foreign-bundle entitlement.**
Routing through Shortcuts changes *who* the caller is, but doesn't change
whether the caller is entitled to dispatch to Messages.app.

System-wide scan for who DOES have it: `/usr/libexec/linkd` and
`/System/Library/PrivateFrameworks/MediaRemote.framework/Support/mediaremoted`.

`launchctl print gui/501` shows only three delegate endpoints published:
`com.apple.private.appintents.delegate.com.apple.homed`,
`.intelligenceplatformd`, and `.appstorecomponentsd`. **There is no
`delegate.com.apple.MobileSMS`** — meaning even linkd cannot dispatch to
Messages.app, because Messages.app does not register an AppIntent delegate
endpoint to non-Apple-internal callers.

### A.4 — Verdict

The dispatch failure isn't about caller identity. It's about Messages.app
not advertising its AppIntent delegate endpoint outside Apple's own daemons.
`OpenMessageIntent` is `isDiscoverable: false` AND the bundle doesn't
publish its delegate. Routing through a privileged proxy doesn't help when
the destination doesn't accept the call.

This single finding kills A, B, C, and E as a class.

---

## Hypothesis D — Spotlight continuation

(see `scripts/probes/proxy-spotlight-continuation.swift`)

### D.1 — `NSUserActivity.webpageURL` rejects the scheme

Attempting to construct an `NSUserActivity` with `webpageURL` set to
`x-apple-appintents://com.apple.MobileSMS/MessageEntity/<GUID>` raises:

```
NSInvalidArgumentException: NSUserActivity.webpageURL scheme "x-apple-appintents" is not allowed.
```

Enforced by `+[UAUserActivity(Internal) checkWebpageURL:actionType:throwIfFailed:]`.
The runtime explicitly disallows this scheme on user activities. So even if
the privileged route worked, we couldn't get the URL into the activity.

### D.2 — `CSSearchableItem` indexing works, but routes back to US

`CSSearchableIndex.default().indexSearchableItems([item])` succeeds with our
URL as the `uniqueIdentifier`. `CSSearchQuery` retrieves it. But when an
indexed item is tapped, the system synthesizes an `NSUserActivity` and
delivers it to the **indexing process** (Hourglass), not to
`com.apple.MobileSMS`. The `domainIdentifier` is informational; it doesn't
transfer ownership.

Apple's documented Spotlight indexing for a foreign app is done via
`CSImportExtension` plug-ins — and the plug-in's principal class must be
inside the owning app's bundle. We can't publish in Messages.app's name.

### D.3 — Messages.app's own Spotlight indexing is not active

```
mdfind 'kMDItemDomainIdentifier == "com.apple.MobileSMS"'   → 0
mdfind 'kMDItemContentType == "com.apple.imessage.message"' → 0
```

Messages.app declares `CoreSpotlightContinuation = true` in its Info.plist
and registers a `com.apple.MobileSMS.spotlight` extension container, but the
indexer is dormant on macOS 26.5:

```
~/Library/Containers/com.apple.MobileSMS.spotlight/Data/Library/Preferences/com.apple.IMCoreSpotlight.plist
  → IMCSNeedsDeferredIndexing = true
```

No messages are actually indexed. So even if we could leverage an existing
indexed MessageEntity to obtain its native URL, there ARE none on this
machine. (Likely Apple is rolling this out gradually, gated on user opt-in.)

### D.4 — Direct LS open with explicit Messages.app target

```
NSWorkspace.shared.open([url], withApplicationAt: Messages.app, configuration: …)
  → app=Messages err=nil
  but Messages.app's front window title doesn't change
```

LaunchServices delivers the URL to Messages.app's `application:openURLs:` /
`scene:openURLContexts:`, but Messages.app's URL handlers silently drop
the `x-apple-appintents` scheme — it's not in `CFBundleURLTypes`.

### D.5 — Verdict

Spotlight continuation as a backdoor relies on three things, none of which we
get:
1. Messages.app actively indexing its messages into Spotlight (it isn't).
2. The Spotlight tap delivering the activity to the URL's owner (it
   delivers to the indexer, which is us).
3. The activity construction accepting `x-apple-appintents://` URLs
   (the runtime forbids it).

---

## Final verdict

**The privileged-proxy hypothesis is false on macOS 26.5.** No path exists by
which a third-party unentitled app can trigger Messages.app to reveal a
specific message by GUID, because:

1. **Messages.app does not publish its AppIntent delegate endpoint** to
   non-Apple-internal callers. Even daemons that have the foreign-bundle
   entitlement (linkd) cannot reach it.
2. **Privileged proxies (Shortcuts, siriactionsd) themselves lack the
   foreign-bundle entitlement** — they can't dispatch the intent either.
3. **`NSUserActivity` rejects the AppIntents URL scheme** at runtime,
   blocking the synthesized-continuation route.
4. **Spotlight continuation owners are the indexer**, not the URL target —
   we cannot index in Messages.app's name, and Messages.app's own indexer
   is dormant.

The `ChatKit.OpenMessageIntent` path IS the right answer — it's just gated
behind entitlements that Apple only grants to specific licensees. The local
LNAction probes were removed from the OSS tree as stale research artifacts,
but this document preserves the protocol notes in case that entitlement story
changes.

## What's left — Plan B (AX iterative scroll)

The previous research recommended an iterative `AXScrollUpByPage` loop in
`MessagesGUIDReveal.scrollToMessage(matchingDescriptionNeedles:)`: repeatedly
page Messages.app's `TranscriptCollectionView` upward until either the
target bubble appears in the AX tree or a sane bound (~50 pages / 5 seconds)
hits. This closes the lazy-load gap (the user's reported failure mode — old
messages don't appear in the loaded bubble set) without privileged IPC.

~50 lines of Swift, no entitlement required. **This is the path forward.**

---

## EPILOGUE — actually, this WAS solved (2026-05-22 evening)

Plan B was wrong. The third-party-accessible path EXISTS, and it's mundane:

**The URL Spotlight uses to deep-link a message**:

```
sms://open?message-guid=<messageGUID>
```

**Delivered as**: Apple Event class/id `GURL` / `GURL`, target bundle
`com.apple.MobileSMS`. No entitlement required. Any app can send this. The
single query parameter is `message-guid` (hyphen, lowercase) carrying the
raw `message.guid` from chat.db. Messages.app's ChatRegistry resolves the
chat from the message GUID alone — no chatGUID needed.

**How we found it (after all the failed hypotheses above)**:

1. Installed Apple's Logging Configuration Profile (App Intents Logging +
   Messages Extension Logging from
   `https://developer.apple.com/bug-reporting/profiles-and-logs/`) — required
   to unredact `<private>` markers in `os_log` output.
2. `sudo killall -HUP logd` to reload the daemon.
3. Tailed Messages.app process logs filtered to subsystems
   `com.apple.appintents`, `com.apple.Messages`, `com.apple.UIKit.MacHelper`,
   `com.apple.appleevents`, `com.apple.FrontBoard`.
4. Clicked a Spotlight Messages result.
5. The log line we were missing:
   ```
   Messages: (ChatKit) [com.apple.Messages:CKSceneDelegate] CKMessagesSceneDelegate:
       -[CKSceneDelegate scene:openURLContexts:] 2A2DC5BD-...
       <UIOpenURLContext: URL: sms://open?message-guid=96485953-75DF-47DA-A179-4F0CD81209FE; ...>
   Messages: (ChatKit) [com.apple.Messages:CKMessagesSceneDelegate]
       Opening url: sms://open?message-guid=96485953-... from source application: (null)
   ```

The negative results in the body of this doc all stand — every PRIVATE path
is gated. But the public-ish path (`sms` URL scheme is registered to
Messages.app per its Info.plist `CFBundleURLTypes` with
`LSIsAppleDefaultForScheme = true`) accepts a `message-guid` query parameter
we never thought to try. Spotlight uses it. Now so do we.

**Why we missed it earlier**:

- `sms://open?groupid=<chatID>` was known to open a chat. We tried adding
  `&messageGuid=<G>` (and a dozen camelCase / underscore / path-style
  variants) — none worked. The actual key is hyphenated `message-guid`,
  which is unusual for Apple Cocoa conventions.
- `NSWorkspace.shared.open(URL(string: "sms://open?message-guid=..."))` from
  our process DOES open Messages.app but doesn't navigate (LaunchServices
  routes the URL to Messages.app but the URL handler in Messages.app might
  treat NSWorkspace-delivered URLs differently — needs more investigation,
  but the AppleEvent path works so we don't need to chase this).
- The AppleEvent path bypasses LS routing and goes straight to
  `CKMessagesSceneDelegate scene:openURLContexts:`, which extracts and
  resolves the URL via `IMChatRegistry chatForGUID:` (or equivalent).

**Implementation**: `Sources/Reveal/MessagesGUIDReveal.swift::sendSpotlightOpenURL`:

```swift
let script = "tell application \"Messages\" to «event GURLGURL» \"sms://open?message-guid=\(messageGUID)\""
NSAppleScript(source: script)?.executeAndReturnError(&err)
```

Five lines. Generalizes to attachments, images, reactions, etc.

**This makes the body of this doc historical**. Future agents: don't go
through 8 hypotheses again. The answer is `sms://open?message-guid=` over
GURL.
