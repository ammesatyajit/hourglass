# Messages.app deep-link research

Empirical investigation of how to reveal a specific message inside the system
Messages.app, given its `chat.db` `message.guid`. macOS 26.5 (Tahoe),
Messages.app `1450.500.221.1.7`, tested 2026-05-22.

## TL;DR — what works

1. **Open a chat by GUID**: `sms://open?groupid=<chat_identifier>` where
   `chat_identifier` is the part of `chat.guid` after the second `;` (i.e. drop
   the leading `any;-;` or `any;+;`). Works for **both** 1:1 chats and groups —
   a significant improvement over the previous `imessage:<handle>` approach
   that failed on groups.
2. **Scroll the chat to a specific message**: walk the AX tree of Messages.app
   from `AXIdentifier="TranscriptCollectionView"` down to bubbles tagged
   `AXIdentifier="Sticker"` (yes, every bubble), match by `AXDescription`
   (sender + body + time), and call action `AXScrollToVisible`.
3. **Visually highlight the match**: not possible from AX (selection isn't
   settable). Fall back to synthesizing ⌘F → ⌘V → ↵ so Messages.app's own
   Find-in-chat draws the highlight box. Only works for non-empty bodies.

There is **no public mechanism** that takes a `message.guid` and jumps to it.
The system has internal selectors (e.g. `existingChatWithGUID:` in IMCore,
`_automation_markAsRead:messageGUID:forChatGUID:fromMe:` referenced in the
Messages.app binary) but none are exposed via URL scheme, AppleScript, or AX.
GUID-based targeting therefore happens client-side: we resolve the GUID to a
`(sender, body, time, chat_identifier)` tuple via chat.db, open the chat, and
match against AX descriptions to scroll.

## Approach A — URL scheme variants

Each row was tested by `open '<url>'` followed by a 1.0 s settle and reading
the Messages.app window title via System Events. Sentinel chat used to detect
non-changes. Sample `msgGUID = EF52…BF82` (a real recent 1:1 message), sample
`chatGUID = any;-;+15713373957` (1:1) and `any;+;chat728778165720474941`
(group).

| URL | Result |
|-----|--------|
| `imessage://<msgGUID>` | Opens **New Compose** with GUID treated as handle. Fail. |
| `imessage:guid/<msgGUID>` | Opens New Compose. Fail. |
| `imessage:?guid=<msgGUID>` | Opens New Compose. Fail. |
| `imessage:<msgGUID>` | Opens New Compose. Fail. |
| `imessage:<handle>` | Opens 1:1 chat with that handle. (Current implementation; works for 1:1 only.) |
| `messages://<msgGUID>` | Opens New Compose. Fail. |
| `messages://<chatGUID>` | Opens New Compose. Fail. |
| `messages:?id=<msgGUID>` | Opens New Compose. Fail. |
| `messages:?chat=<chatGUID>` | Opens New Compose. Fail. |
| `messages:?guid=<msgGUID>` | Opens New Compose. Fail. |
| `messages://open?addresses=<handle>` | Same as `imessage:<handle>`. |
| `sms://open?groupid=<full chatGUID>` | No effect (still on sentinel). |
| **`sms://open?groupid=<chat_identifier>`** | **Opens the chat — groups AND 1:1.** ✅ |
| `sms://open?groupid=<id>&messageid=<guid>` | Opens chat. Message-level query param ignored — chat is at most-recent position. |
| `sms://open?groupid=<id>&guid=<guid>` | Same. |
| `sms://open?groupid=<id>&id=<guid>` | Same. |
| `sms:<handle>` | Opens 1:1 chat (sends as SMS by default). |
| `sms:?id=<chatGUID>` | No effect. |
| `iChat:<msgGUID>` / `iChat:?id=<msgGUID>` | No effect (legacy scheme, silently swallowed). |
| `x-msg-id://<msgGUID>` | Scheme not registered (`open` returns 1). |
| `im:<msgGUID>` | Opens New Compose (CPIM-style routing). |

URL schemes registered by Messages.app (from `Info.plist`): `sms`,
`sms-private`, `itms-messages`, `imessage`, `iChat`, `Messages`, `im`. Strings
found inside the Messages.app binary that look like URL templates:
`sms://open?groupid=%@`, `messages://%@`, `messages://open?addresses=`. No
message-GUID template appears anywhere — the routing genuinely doesn't exist.

**Winner**: `sms://open?groupid=<chat_identifier>`. Despite the name and
scheme, this opens **iMessage chats** too — `sms` is just the registered
URL handler for the modern unified Messages app. The `groupid` parameter
expects the chat's `chat_identifier` (which is the part after `any;-;` or
`any;+;` in `chat.guid`).

## Approach B — AppleScript

Messages.app's full scripting dictionary (`sdef /System/Applications/Messages.app`):

- **Classes exposed**: `application`, `participant` (a.k.a. `buddy`),
  `account`, `chat`, `file transfer`.
- **`chat` properties**: `id` (the GUID, same as `chat.guid` in the DB),
  `name`, `account`, plus an element list of `participant`. **No `messages`
  element, no `message` class anywhere.**
- **Commands**: `send`, `login`, `logout`. Plus inherited `open`, `count`,
  `exists` from CocoaStandard.

So AppleScript can enumerate chats and inspect participants, but it does
**not** expose individual messages and provides no command to navigate to a
chat, select a chat, or reveal a message. You can `send` to a chat, but
sending is a write operation, not a navigation one.

```
tell application "Messages" to get id of first chat
-- → "any;-;+15102196504"

tell application "System Events"
    tell process "Messages"
        return title of front window
    end tell
end tell
-- → "<currently displayed chat name>"
```

The title-of-front-window trick is the cleanest signal for "what chat is
currently visible," and we use it in test harnesses to verify URL-scheme
behavior. It's **read-only** — we can't write the title to change focus.

## Approach C — Accessibility (AX) attribute extraction

This is the heart of the win.

### AX tree layout of a chat

```
AXApplication "Messages"
  AXWindow ident=SceneWindow desc=<chat name>
    AXGroup subrole=iOSContentGroup
      AXGroup
        AXButton ident=ConversationTitle desc=<chat name>
        AXGroup    ← sidebar conversation list, ident=ConversationList
        AXGroup    ← chat transcript area
          AXGroup ident=TranscriptCollectionView desc="Messages"
            AXGroup                                          ← message row
              AXStaticText desc=<sender name>     (optional date / sender)
            AXGroup desc="<Sender>, <body>, <time>"         ← message row
              AXGroup ident=Sticker desc="<Sender>, <body>, <time>"
                AXTextArea ident=CKBalloonTextView desc=""
            …
```

Every message bubble is an `AXGroup` (or `AXButton` for reply previews) with
`AXIdentifier="Sticker"` (yes, even when the message isn't a sticker — Apple
apparently never renamed it from when message bubbles were a Sticker-like
control). The transcript scroll container is `AXIdentifier=
"TranscriptCollectionView"`.

### What's exposed on a message bubble

25 attributes total. The interesting ones:

| Attribute | Value |
|-----------|-------|
| `AXIdentifier` | Always `"Sticker"`. Doesn't carry GUID. |
| `AXRole` | `AXGroup` (text), `AXButton` (reply preview / picture). |
| `AXDescription` | **The only identifying info**: `"<Sender Name>, <body or "Includes picture" or "Image attached, FILENAME, …">, <H:MM AM/PM>"`. For attachments includes file name + size. For tapbacks/reactions includes `"3 reactions, Latest: …"`. |
| `AXValue` | `None`. |
| `AXHelp` | `None`. |
| `AXCustomContent` | An empty `NSMutableArray` archived with `NSKeyedArchiver`. Does not contain GUID or any identifier. |
| `AXSubrole` | `None`. |
| `AXUserInputLabels` | The body text alone (or attachment description). |
| `AXFrame` / `AXPosition` / `AXSize` | Screen rect. Useful for "is it on screen". |
| `AXSelected` | Always `False`; **not settable** (set returns 0 but value stays `False`). |
| `AXFocused` | Always `False`; **not settable**. |
| `AXChildren` | A single `CKBalloonTextView` (the inner text area). |

### Actions on a message bubble

`AXScrollToVisible` ✅, `AXCancel`, `AXScrollUpByPage`, `AXShowMenu`, plus a
long list of tapback-emoji and context-menu actions (`Name:Heart`,
`Name:Reply…`, `Name:Forward…`, `Name:Copy`, etc.).

**`AXScrollToVisible` works.** Empirically: a bubble whose `AXFrame.y`
started at 44.5 px ended at 790.5 px after a single `AXScrollToVisible` call.
The transcript scrolled by 746 pixels to bring the target into view.
Confirmed for both old (off-screen) and visible bubbles.

### What's NOT exposed via AX

- **No message GUID anywhere in the AX tree.**
- **No row index, ROWID, or stable identifier per bubble.**
- **No way to set `AXSelected` or `AXFocused` to draw a highlight.**
- The transcript collection view is **virtualized**: only the rendered bubbles
  appear in the AX tree (~14–17 at a time on a 1512×868 window). Bubbles
  outside the visible region simply don't exist in AX until they're scrolled
  into view. Programmatic `AXScrollUpByPage` on the transcript loads older
  rows.

### Identification strategy

Since GUID isn't in AX, we identify a target bubble by matching its
`AXDescription` against `(sender display name, message body, time-of-day
H:MM)` derived from chat.db. Format:

```
"<Sender>, <body>, <H:MM AM/PM>"
```

Special cases:
- **Sent messages**: Messages.app prefixes the description with
  `"Your iMessage, "` (or `"Your SMS, "` for SMS) — empirically confirmed.
  We drop the sender from the substring we look for, so `"<body>, <time>"`
  is contained inside `"Your iMessage, <body>, <time>"`. CONTAINS matching
  (not equality) is the right primitive throughout.
- **Image attachments**: body is replaced by `"Includes picture"` (reply
  previews) or `"Image attached, <filename>, Image · <size>"`. We can't
  recover the original filename without joining `message_attachment_join`,
  but sender + time + first-attachment-hint usually disambiguates.
- **Tapbacks/reactions append** to the description: `"3 reactions, Latest:
  Mason loved this"`. CONTAINS matching survives this naturally.
- **Time format**: 24-hour locales render differently. We construct the
  expected substring using the user's current locale formatter to match
  whatever Messages.app rendered.

## Approach D — Spotlight integration

`mdfind kMDItemContentType=com.apple.message` and a wide net of related
queries returned **0 results** on the user's machine. Messages.app declares
`CoreSpotlightContinuation = true` in its Info.plist (so it can handle
`NSUserActivity` continuation), but messages aren't indexed into Spotlight
by default on macOS — likely a deliberate privacy choice. Even if they were,
the activity type `com.apple.Messages` is private to Apple and Messages.app's
handling of it isn't documented. Not actionable from outside the app.

## Approach E — Private frameworks (documentation only, no linking)

For reference; **we do not link to any of these** and we do not call into
them. Documented to inform future work.

- `IMCore.framework`: contains `IMChatRegistry` and methods like
  `existingChatWithGUID:` (found via strings on the Messages.app binary). A
  call into this would let us go straight from chat.guid to an IMChat
  instance. Private; would break code signing for a notarized distribution.
- `Messages.app` binary contains the string
  `_automation_markAsRead:messageGUID:forChatGUID:fromMe:` — an internal
  automation entry point on a private object that takes both GUIDs. There is
  no scroll/reveal counterpart visible in the binary's string table.
- `MessagesKit.framework`, `IMSharedUI.framework`,
  `MessagesBlastDoorSupport.framework`, `IMDPersistence.framework` — none
  expose anything publicly useful for navigation. macOS Big Sur+ ships these
  in the dyld shared cache, not as on-disk dylibs, so symbol enumeration is
  awkward without `dsc_extractor` or DYLD_SHARED_CACHE manipulation.

## Chosen approach (implemented)

`Sources/Reveal/MessagesGUIDReveal.swift`:

1. Resolve `chatGUID` to `chat_identifier` (strip `any;-;` / `any;+;`).
2. Open the chat with `sms://open?groupid=<chat_identifier>` via
   `NSWorkspace.shared.open`. Falls back to legacy `imessage:<handle>` for
   1:1s if the URL doesn't take (defensive — empirically not needed but
   cheap).
3. Wait ~450 ms for the chat to materialize.
4. Walk Messages.app's AX tree to `TranscriptCollectionView`, enumerate its
   `Sticker` descendants, build an expected match string from the chat.db
   row (sender + body/attachment hint + time-of-day), and call
   `AXScrollToVisible` on the first bubble whose description matches.
5. If the message had a non-empty body, also synthesize ⌘F + paste + ↵ to
   draw Messages.app's own highlight box — strict improvement on the
   current implementation because the chat is already correct.
6. If steps 4 and 5 both fail (message GUID we can't identify in the AX tree
   AND no body to Find), the chat is at least open at its bottom — same
   behavior as the previous code, with the new bonus of working for groups.

## Known limitations

- **Highlights are best-effort**. AX can scroll but not select/highlight.
  Empty-body attachments scroll into view but don't get a glow. Acceptable —
  the user sees the message in context, which is the actual goal.
- **Virtualized transcript**. If the target message is far back in history,
  it's not in the AX tree until we scroll. We don't auto-page through the
  history; the fallback ⌘F covers text messages. For older attachments, the
  user lands at the bottom and has to scroll. (Future work: implement an
  iterative `AXScrollUpByPage` loop until the target row appears in the AX
  tree — bounded by a sane limit.)
- **`sms://open?groupid=` is undocumented** by Apple. It's exercised by the
  Messages.app binary itself (string `sms://open?groupid=%@` found there), so
  it's an Apple-supported internal route, but it could change. The fallback
  to `imessage:<handle>` for 1:1s gives us defense in depth.
- **Time-of-day matching is locale-dependent**. We build the expected
  description string using `DateFormatter` with `.short` time style and the
  current locale, so it should track whatever Messages.app renders.
- **Multiple messages within the same minute**: same `(sender, time)`
  ambiguity exists. We disambiguate by body match when body is present;
  otherwise we take the first AX-tree match (most recent rendered).
- **Tapbacks/reactions** modify the parent message's description (appending
  `", N reactions, Latest: …"`). We use a prefix match (description starts
  with the expected `"<sender>, <body>, <time>"`) so reactions don't break
  matching.

## Files touched

- `Sources/Reveal/MessagesGUIDReveal.swift` — new module, the GUID-based path.
- `Sources/Reveal/MessagesReveal.swift` — now delegates to
  `MessagesGUIDReveal.reveal` first; keystroke fallback retained for the
  highlight pass.
- `Sources/Data/Message.swift` — added `guid` field.
- `Sources/Search/MessageSearch.swift` — extended SELECT with `m.guid` and
  `ch.guid`; added `chatGUID` to `MessageSearch.Result`.
- `Tests/MessagesGUIDRevealTests.swift` — pure tests on the AX description
  builder and URL constructor.

## Test fixtures

`Tests/Fixtures/chat.db` already has `message.guid` populated. URL/description
tests use those (`msg-0001`, `msg-0002`, …) so they run hermetically; AX
interaction is not unit-tested (cannot run in CI without a real Messages.app).
