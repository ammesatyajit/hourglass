# Messages.app private-IPC research (GUID jump)

Empirical investigation of how to reach the `OpenMessageIntent` and related
private mechanisms inside Messages.app from our own process, so we can implement
a true "jump to GUID" reveal instead of the current AX-scroll-and-keystroke
fallback.

macOS 26.5 (Tahoe), Messages.app `1450.500.221.1.7` (`com.apple.MobileSMS`),
IMCore `800.0.0`, ChatKit `1450.500.221.1.7`. Testing date 2026-05-22.

## Summary (read this first)

**Conclusion**: There IS a private intent — `ChatKit.OpenMessageIntent` — that
takes a `MessageEntity` (with the message GUID) and reveals it in Messages.app.
The metadata is on disk, the URL schema is `x-apple-appintents://com.apple.MobileSMS/MessageEntity/<GUID>`,
and the dispatch path through `AppIntents.framework`'s `LNAction`/`LNApplicationConnection`
ObjC bridge **can be constructed end-to-end from our process** — but the actual
XPC delivery to Messages.app is **gated by a private entitlement** we don't have.

We confirmed all of:
- The intent exists and is structurally valid (`isDiscoverable: false`, `openAppWhenRun: true`).
- We can build a valid `LNAction(OpenMessageIntent, target: MessageEntity(GUID))` in our process.
- We can obtain an `LNApplicationConnection` to `com.apple.MobileSMS`.
- We can build an `LNActionExecutor` and call `[executor perform]` — it returns without error,
  but the action is silently dropped because the XPC connection requires entitlements
  Messages.app's AppIntents mediator demands.
- `NSWorkspace.open` on the URL representation returns success but Messages.app
  has no LaunchServices handler for `x-apple-appintents://`.
- An Apple Event `'aevt'/'GURL'` (kAEGetURL) delivered to Messages.app with the URL
  string returns errAEEventNotHandled (-1708).
- Posting plausible `Distributed`/`Darwin` notifications doesn't drive nav.
- Parameterized AX attributes on Messages.app expose only text-marker operations,
  not a "jump to message" attribute.

**No implementation changes shipped.** `Sources/Reveal/MessagesGUIDReveal.swift`
still uses the AX-scroll + keystroke-highlight fallback. The fallback works for
recent messages but breaks for older messages (Messages.app lazy-loads the
transcript — see the user's bug report `2026-05-22 — features-agent`). This is
the gap a working private-IPC path would fill, and we couldn't close it without
privileged entitlements.

If/when we sign with an extension entitlement or ship a privileged helper, the
LNAction path documented below is ready to wire up.

## Architecture: Messages.app on macOS 26

Messages.app is **iOS-bridged Catalyst**, not native AppKit:

- Bundle ID: `com.apple.MobileSMS` (the iOS Messages bundle ID).
- Main binary links `/System/iOSSupport/System/Library/PrivateFrameworks/{IMCore,ChatKit,IMSharedUtilities}.framework` — the **iOSSupport** copies, not the native macOS ones — plus native `Marco`, `FTServices`, `IDSFoundation`.
- `Messages.app/Contents/PlugIns/MessagesAppKitBridge.bundle` provides AppKit↔UIScene glue (`CKAppKitBridge` class).
- Uses `UISceneSession` + `CKMessagesSceneDelegate` for windows.
- `Info.plist` declares `NSUserActivityTypes = ["com.apple.Messages", "com.apple.Messages.StateRestoration"]` and `CoreSpotlightContinuation = 1`.

**We cannot dlopen the iOSSupport copies of ChatKit/IMCore into our native macOS
process** — `dlopen` returns "wrong platform to load into process" (verified). The
native-macOS `/System/Library/PrivateFrameworks/IMCore.framework` **does** load
and has parallel ObjC classes (`IMChatRegistry`, `IMChat`, `IMMessage`,
`IMDaemonController`, `IMAutomation*`), but these talk to imagent (the central
daemon) over XPC — they don't drive Messages.app's UI.

**Messages.app process (PID 767 in this session) registers NO mach service of
its own.** Verified via `launchctl print pid/767` — `services = {}` is empty.
Its only inbound RPC surface is Apple Events / URL handling / NSUserActivity,
all of which go through LaunchServices→UIKit→`CKSceneDelegate scene:openURLContexts:`
(or `scene:continueUserActivity:`).

### Apple Event flow Messages.app uses for URLs

From `log stream` while we ran `sms://open?groupid=…`:
```
com.apple.UIKit.MacHelper [Lifecycle] Enqueueing BSAction: <UISOpenURLAction> (for AppleEvent: GURL/GURL)
com.apple.UIKit.MacHelper [Lifecycle] UISceneActivationConditions told us to send action to scene: <UISOpenURLAction> -> FUScene|com.apple.MobileSMS(767)|...
com.apple.FrontBoard [SceneClient] [(FBSceneManager):FUScene|...] Sending action(s) in update: UISOpenURLAction
com.apple.Messages [CKSceneDelegate] <private>: -[CKSceneDelegate scene:openURLContexts:] <private>
```

So `aevt/GURL` → `UISOpenURLAction` → routed to existing scene → `CKSceneDelegate scene:openURLContexts:`. For an `x-apple-appintents://` URL via the same path, the AppleEvent reply was `errn: -1708` (errAEEventNotHandled) — Messages.app's GURL handler explicitly rejects this scheme.

## The selectors that misled us

The string `_automation_markAsRead:messageGUID:forChatGUID:fromMe:` from
the Messages.app binary, and `_automation_markMessagesAsRead:messageGUID:forChatGUID:fromMe:queryID:`
plus the `IMDaemonAutomationRequestHandler` family in imagent's strings — these
are NOT UI-driving APIs. They are:

- **Daemon-side** automation hooks (in imagent's address space) for marking-as-read
  / sending / receiving via the daemon, mostly used by the test harness
  `screenshotTest.xctest` (`/AppleInternal/XCTests/com.apple.mobilesms/screenshotTest.xctest`
  — internal Apple XCTest target).
- **Client-side** mirror on `IMChatRegistry` (instance method `_automation_markAsReadQuery:finishedWithResult:`) which is the callback for the daemon's reply, not a navigation primitive.

Neither family takes a "show this message" action. The prior agent was looking
at the wrong selectors entirely.

## What ACTUALLY exists for GUID-targeted reveal

### `ChatKit.OpenMessageIntent`

Path:
```
/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework/Resources/Metadata.appintents/extract.actionsdata
```

```bash
jq '.actions.OpenMessageIntent' .../extract.actionsdata
```

Key fields:
- `fullyQualifiedTypeName`: `ChatKit.OpenMessageIntent`
- `mangledTypeName`: `7ChatKit17OpenMessageIntentV`
- `actionConfiguration.actionSummary.summaryString.formatString`: `"Reveal ${target}"`
- `parameters`: one — `target` of type `MessageEntity`, required, non-optional
- `openAppWhenRun: true` (launches Messages.app)
- `isDiscoverable: false` (hidden from Shortcuts UI)
- `systemProtocols`: `["com.apple.link.systemProtocol.OpenEntity", "com.apple.link.systemProtocol.URLRepresentable"]`
- `effectiveBundleIdentifiers`: `[]` (no host bundle restriction)

`MessageEntity` has fields `GUID`, `transferGUID`, `messageType`, `isRead`,
`attributes`, `body`, `subject`, `author` (`MessagePerson`), `date`,
`conversation` (`ConversationEntity`), `service`, `attachments`,
`customAttachments`, `locations`, `links`, `messageEffect`, `reaction`,
`referencedMessage`, `notificationIdentifier`. It conforms to
`com.apple.appintents.entity.Indexed` and `com.apple.appintents.entity.URLRepresentable`.

`ConversationEntity` is similar with `conversationGUID`, `recipients`, etc.

There's also `ChatKit.OpenConversationIntent` (target: `ConversationEntity`),
`SendMessageReactionIntent`, `MarkConversationAsUnreadIntent`,
`MuteConversationIntent`, `DeleteMessageIntent`, etc. — all currently
unreachable for the same reasons as below.

### The URL representation

User confirmed empirically and Apple convention matches:
```
x-apple-appintents://com.apple.MobileSMS/MessageEntity/<messageGUID>
```

Form: `x-apple-appintents://<bundle-id>/<EntityTypeName>/<entity-id>`.

**No LaunchServices handler claims the `x-apple-appintents://` scheme.** `lsregister -dump` has zero matches. `NSWorkspace.shared.open` on this URL pops the macOS "There is no application set to open the URL …" dialog with a "Search the App Store" / "Choose Application" prompt.

## Things we tried — chronologically, with results

### 1. NSWorkspace.open with x-apple-appintents URL → fails (no handler)
Returns false; macOS shows the "no app set" dialog. Already known.

### 2. NSAppleEventDescriptor kAEGetURL → -1708
```swift
let event = NSAppleEventDescriptor.appleEvent(withEventClass: 0x61657674 /* 'aevt' */, eventID: 0x4755524C /* 'GURL' */, …)
event.setParam(NSAppleEventDescriptor(string: entityURL.absoluteString), forKeyword: keyDirectObject)
let reply = try event.sendEvent(…)
```
Reply: `<NSAppleEventDescriptor: 'aevt'\'ansr'{ 'errn':-1708 }>` — `errAEEventNotHandled`. Messages.app receives the AppleEvent but its `_handleAppleEvent:withReplyEvent:` (route in binary at `0x100022060`) dispatches the GURL action to `CKSceneDelegate scene:openURLContexts:` which ignores `x-apple-appintents://`.

(Bonus: the `'shud'` descriptor we found in error strings (`"No 'shud' descriptor on apple event: %@"`) is for **`SHKMessagesLaunchEventContext`** — ShareKit's "Share via Messages" event, NOT a navigation event. Verified by inspecting `SHKMessagesLaunchEventContext` (in `ShareKit.framework`) — its properties are `subject`, `recipients`, `text`, `URLs`, `fileURLs`, etc. Dead end.)

### 3. NSUserActivity with various activityType / userInfo
Tried:
- `activityType = "com.apple.Messages"` with `userInfo[__kIMChatRegistryContinuityURLKey] = <URL>` and `userInfo[__kIMChatRegistryUserActivityLastMessageKey] = <GUID>` (the actual key names IMCore exports), then `activity.becomeCurrent()` + `app.activate()`. No navigation.
- `activityType = "com.apple.corespotlight.searchableitem"` with `userInfo[kCSSearchableItemActivityIdentifier] = <URL>`. No navigation.

`NSUserActivity.becomeCurrent()` makes the activity the *originating* app's current activity — for the activity to actually be delivered to another app, Continuity (Handoff over Bluetooth) or a Spotlight tap mediates it. We can't fake either.

The relevant ChatKit-side handler — `+[CKUserActivityHandler messagesScene:continueUserActivity:withNavigationProvider:chatController:completion:]` — IS the right entry point. It reads `userActivity.userInfo` for `__kIMChatRegistryUserActivityLastMessageKey` and `__kIMChatRegistryContinuityURLKey` and navigates. But we have no way to push our activity into Messages.app's `scene:continueUserActivity:` from a third-party process.

### 4. LSOpenURLsWithRole, openURLs(withApplicationAt:)
Returns success (`com.apple.MobileSMS` becomes frontmost), but Messages.app gets the URL via the same `scene:openURLContexts:` route and ignores `x-apple-appintents://`. Same as Strategy 1.

### 5. dlopen IMCore (native macOS copy) — works, doesn't drive UI

The native-macOS copy `/System/Library/PrivateFrameworks/IMCore.framework/IMCore` dlopens cleanly. Classes recovered via `objc_copyClassList`:
- `IMChatRegistry` (with selectors `existingChatWithGUID:`, `_cachedChatsWithMessageGUID:`, `_chat_loadPagedHistory:numberOfMessagesBefore:numberOfMessagesAfter:messageGUID:threadIdentifier:queryID:synchronous:completion:` — a paged-history-around-a-message API on the daemon side)
- `IMChat`, `IMMessage`, `IMMessageItem`, `IMHandle`
- `IMDaemonController` (`sharedInstance`, `sendQueryWithReply:query:`)
- `IMAutomation`, `IMAutomationMessageSend`, `IMAutomationGroupChat`, `IMAutomationBatchMessageOperations`, `IMCoreAutomationHook`, `IMCoreAutomationNotifications`

These run in **our** address space. They talk to imagent over XPC for chat state, but **they do not drive Messages.app's UI**. Calling `IMChatRegistry existingChatWithGUID:` in our process gives us an `IMChat` we can inspect (sender, participants, message history, etc.) — useful for fact-checking our chat.db decoding, but not for reveal.

### 6. Distributed/Darwin notifications

Posted plausible names (`CKEmphasizeBalloonAtIndexPathNotification`,
`com.apple.imessage.openChat`, `com.apple.messages.revealMessage`, etc.) with
chat/message GUID payload via `DistributedNotificationCenter.default()` —
Messages.app didn't react. `CKEmphasizeBalloonAtIndexPathNotification` (a real
ChatKit symbol) is **intra-process** (regular `NSNotificationCenter`), not
cross-process.

`IMDPersistenceAgent.xpc` has `_AllowedClients` gated to Apple-signed bundle IDs:
```
identifier = com.apple.MobileSMS.spotlight and anchor apple
identifier = com.apple.imagent and anchor apple
identifier = com.apple.imdmessageservices.IMDMessageServicesAgent and anchor apple
```
We can't connect.

### 7. Parameterized AX attributes

`AXUIElementCopyParameterizedAttributeNames` on every node in Messages.app's AX
tree returns only `AXReplaceRangeWithText` (for text fields) and the standard
`AXLineRangeForIndex`, `AXBoundsForRange`, etc. text-marker attributes. **No AX
parameterized attribute takes a message identifier.** Dead end.

### 8. LNAction + LNApplicationConnection + LNActionExecutor (the SPI route)

This is where it gets interesting. AppIntents has Objective-C bridge classes in
`/System/Library/Frameworks/AppIntents.framework/AppIntents` that loadable from
any process:

```
LNAction           — the action to perform
LNActionMetadata   — metadata describing an action (from .appintents file)
LNParameter        — a (name, LNValue) pair
LNValue            — typed value
LNEntity           — an entity instance (id + properties)
LNEntityIdentifier — identifier for an entity (typeName + value)
LNEntityValueType  — type wrapper for entities
LNApplicationConnection / LNMacApplicationConnection — XPC connection to a target app
LNConnectionManager.sharedInstance — connection lifecycle
LNActionExecutor   — performs an action over a connection
LNActionExecutorOptions — execution options (source, kind, interactionMode, etc.)
```

We built the action correctly in local research probes:

```objc
id entityID  = [[LNEntityIdentifier alloc] initWithValue:messageGUID typeName:@"MessageEntity"];
id entity    = [[LNEntity alloc] initWithIdentifier:entityID];
id entityType= [[LNEntityValueType alloc] initWithTypeName:@"MessageEntity"];
id lnValue   = [[LNValue alloc] initWithValue:entity valueType:entityType];
id parameter = [[LNParameter alloc] initWithIdentifier:@"target" value:lnValue];
id action    = [[LNAction alloc] initWithIdentifier:@"OpenMessageIntent"
                                  mangledTypeName:@"7ChatKit17OpenMessageIntentV"
                                   openAppWhenRun:YES
                                       parameters:@[parameter]];
// action.description prints:
//   <LNAction: 0x…, identifier: OpenMessageIntent, mangledTypeName: 7ChatKit17OpenMessageIntentV,
//    openAppWhenRun: YES, …, parameters: ( "<LNParameter: …, identifier: target,
//    value: (Entity<MessageEntity>) <redacted>>" )>
```

The connection works (we get a real `LNConnectionProxy` wrapping
`LNMacApplicationConnection`):
```objc
id conn = [[LNApplicationConnection alloc] initWithBundleIdentifier:@"com.apple.MobileSMS"];
// → <LNConnectionProxy: 0x…, wrapping: <LNMacApplicationConnection: 0x…>>
```

The executor builds fine and `perform` runs without throwing:
```objc
id execOpts = [[LNActionExecutorOptions alloc] init];
id executor = [conn executorForAction:action options:execOpts delegate:nil];
[executor perform];
// executor.state → 100 after a few seconds (terminal state; no error logged)
```

But Messages.app's UI doesn't change. **No log entries from LinkServices or Messages
were generated during the perform**, suggesting the request never reaches Messages.app's process.

The reason is in the AppIntents strings:
```
"Access denied: Bundle identifier '%s' is not authorized. The calling process must have
 either the 'com.apple.private.appintents.exception.allow-foreign-bundle-identifiers'
 entitlement set to true or the 'com.apple.private.appintents.allowed-bundle-identifiers'
 entitlement containing this bundle identifier."
```

And the mach service pattern AppIntents uses is `com.apple.private.appintents.delegate.%@`. Listing `launchctl print gui/$(id -u)` shows entries like:
```
com.apple.private.appintents.delegate.com.apple.homed
com.apple.private.appintents.delegate.com.apple.intelligenceplatformd
com.apple.private.appintents.delegate.com.apple.appstorecomponentsd
```
but **no** `com.apple.private.appintents.delegate.com.apple.MobileSMS`. Messages.app doesn't publish this service to anonymous clients. The earlier exception we hit (`'Invalid parameter not satisfying: bundleIdentifier' in LNConnectionPolicy shouldHandleInProcessWithMangledTypeName:bundleIdentifier:`) confirms the system is trying to check our entitlements and rejecting us.

In short: the LNAction path **is structurally correct**, but the XPC mediator
requires an entitlement only Apple bundles ship with. A non-Apple notarized app
can't talk to Messages.app's AppIntents extension.

### 9. CSSearchableItemContinuation

If we add a `CSSearchableItem` to our own CoreSpotlight index with
`uniqueIdentifier = <our x-apple-appintents URL>` and the user **taps the result
in macOS Spotlight**, Spotlight delivers an `NSUserActivity` of type
`CSSearchableItemActionType` to **us** with `userInfo[CSSearchableItemActivityIdentifier]
= <url>`. That's the documented Spotlight reverse path — but it's gated on a
user click in Spotlight, and the resulting activity is delivered to the
*indexing app* (us), not to Messages.app. We can't programmatically synthesize
the user click. Dead end.

## Why the current AX-scroll fallback breaks for old messages

User report (`2026-05-22`): they double-clicked a result for an older message in
their chat with "Pat" and Messages.app opened the chat but did NOT scroll to
the target and did NOT highlight anything.

`CKSceneDelegate` and `CKTranscriptCollectionView` use lazy loading — older
messages are not in the loaded bubble set when the chat opens. Specifically:
- AX walk over `TranscriptCollectionView` only finds bubbles currently rendered (~14-17 at a time).
- ⌘F/Find-in-Conversation also searches the loaded set (or maybe a slightly larger window — but bounded).
- We don't have a "scroll up by page until found" loop bounded by anything sensible.

`ChatKit.OpenMessageIntent` would fix this because Messages.app would request the message from imagent (which has paged history) and jump to it. That's exactly the gap we tried to close here and couldn't.

## Possible future paths (none implemented)

1. **Ship a privileged helper extension** that has the
   `com.apple.private.appintents.exception.allow-foreign-bundle-identifiers`
   entitlement. Apple doesn't grant this to third-party developers — we'd need
   special licensing.

2. **Implement an iterative `AXScrollUpByPage` loop** on the
   `TranscriptCollectionView` that continues until the target bubble's
   `AXDescription` matches our needles. Bounded by a sane time/page limit. This
   is the most realistic next step — it doesn't reach for private IPC, just
   leverages AX more aggressively. Estimate: ~50 lines of Swift in
   `MessagesGUIDReveal.swift`. Would solve the lazy-load problem for text
   messages. Attachments would still fail (no body to refine the match), but
   `(sender, time)` matching usually disambiguates.

3. **Spawn a sandboxed Catalyst-mode helper app** that links iOSSupport's
   ChatKit directly (since it's a Catalyst environment). Then `dlopen` from
   that helper can load ChatKit, instantiate `ChatKit.OpenMessageIntent`, and
   perform it locally. This is in a gray zone — Catalyst-mode helpers exist on
   macOS 26, but Apple's signing rules around iOSSupport private framework
   linking are tight.

4. **Patch the keystroke flow** to use ⌘F multiple times with different
   keywords until found. Naive but might work — ⌘F + the timestamp string +
   ↵ might land far back enough.

5. **Custom URL scheme via NSExtension?** Register our app as the handler for
   `x-apple-appintents://` (it's currently unhandled). If we then call
   `NSWorkspace.open` on the URL, our app would be invoked with the URL — at
   which point we have nothing extra to do, since the issue was getting
   Messages.app to receive it. Doesn't help.

## What we surface for the parent agent

- **No production-code changes shipped.** `Sources/Reveal/MessagesGUIDReveal.swift` is unchanged.
- **Recommended next iteration**: implement the AX iterative-paging loop (option 2 above) to fix the lazy-load problem without needing privileged entitlements. Lower-risk, ships in a single PR.
- **Long-term**: the LNAction code-path would activate if we ever ship as an Apple-signed extension or get the requisite private entitlement.
