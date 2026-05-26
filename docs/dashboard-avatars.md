# Dashboard avatars — where group photos live in chat.db

Empirical investigation of the Messages.app schema, run against the user's
real `~/Library/Messages/chat.db` on macOS 26.5 (Tahoe), May 2026.

Question: when a user sets a custom group-chat photo in Messages.app, **where
do those bytes end up**, and can we read them at the same time we read group
metadata for the Dashboard's "Top Groups" list?

## TL;DR

Group photos are stored as **regular attachments** on disk, referenced from
`chat.properties` via a bplist key `groupPhotoGuid`. The full path:

```
chat.properties (BLOB, binary plist) -> "groupPhotoGuid" -> at_0_<UUID>
attachment.guid = at_0_<UUID> -> attachment.filename (with ~ for $HOME)
filename expands to e.g.:
~/Library/Messages/Attachments/19/09/at_0_<UUID>/GroupPhotoImage  (real PNG)
```

In the user's DB: **49 of 696 group chats (~7%) have a custom photo**. The
file always exists on disk when `groupPhotoGuid` is set — no orphaned
references.

## Schema walk

### `chat.properties` is a binary plist

`PRAGMA table_info(chat)` confirms a `properties` BLOB column. Across the
user's 696 group rows, every non-NULL `properties` blob is a `bplist00`
(binary plist). Decode with Python `plistlib.loads(blob)` or Foundation's
`PropertyListSerialization`.

Unique keys observed across 696 group rows:

```
CKChatPreviousAccountsDictionaryKey, CKChatWatermarkMessageID,
CKChatWatermarkTime, LSMD, LegacyGroupIdentifiers, RCSGroupIdentityVersion,
RCSGroupURI, SMSCategory, SMSSubCategory, backgroundChannelGUID,
backgroundProperties, chatSummaryDictionary, gppv, *groupPhotoGuid*,
hasBeenAutoSpamReported, hasReceivedResponse, hasResponded,
hasViewedPotentialSpamChat, lastKnownHybridState, lastSeenMessageGuid,
lastTUConversationCreatedDate, markedAsKnownDate, messageHandshakeState,
numberOfTimesRespondedtoThread,
prefersTextResponseToIncomingAudioMessages, put, pv, shouldForceToSMS,
showAudioButtonInEntryView, spamDetectionSource, supportsEncryption,
wasDetectedAsSMSSpam
```

The keys we care about:

| Key              | Type    | Meaning |
|------------------|---------|---------|
| `groupPhotoGuid` | string  | Attachment GUID of the photo (e.g. `at_0_<UUID>`). |
| `pv`             | int     | Photo version (mtime-ish counter). |
| `put`            | float   | Photo update time (unix epoch seconds). |
| `gppv`           | int     | Group-photo-protocol version (Apple internal). |

When `groupPhotoGuid` is absent, the chat doesn't have a custom photo.
Messages.app shows the canonical "stacked participant avatars" composite in
that case — we mirror that in the Dashboard.

### `groupPhotoGuid` resolves through the `attachment` table

`attachment.guid` is the join key. Example:

```sql
SELECT filename FROM attachment WHERE guid = 'at_0_F6E2C86F-52CE-4BDC-8A2C-A1F9E17200AD';
-- '~/Library/Messages/Attachments/19/09/at_0_F6E2C86F-52CE-4BDC-8A2C-A1F9E17200AD/GroupPhotoImage'
```

Two things to note about `filename`:
- It uses `~` for `$HOME` and must be tilde-expanded before opening.
- The basename is literally `GroupPhotoImage` (not `<UUID>.png`). It's a
  raw PNG file — `NSImage(data:)` reads it directly, no framing byte.

### Verification

Of 696 group chats:
- 49 have `groupPhotoGuid` in `chat.properties`
- 49 / 49 — every one of those has a matching `attachment` row
- 49 / 49 — every one of those resolves to a file that exists on disk
- 0 orphaned references

That zero-orphan rate is reassuring: the iCloud sync seems to drop the
`properties` blob update if the file doesn't sync.

## What about `NickNameCache/`?

There's a separate directory at `~/Library/Messages/NickNameCache/` that
contains PNG files keyed by an opaque hash (e.g. `+fHWQxmGKfDx91rVb2iFcQ==-ad`).
On inspection these are **per-contact nickname avatars** (one PNG per
contact who has a custom "share my name and photo" handshake set up with
the user), not group photos. The hash-style key has no obvious join into
`chat.db` — Messages.app derives it from the handle plus some salt. Not
useful for the group-photo path; potentially interesting later if we want
to upgrade per-contact avatars (we already have those via AddressBook).

## What about `iCloud / shared photo storage`?

Briefly explored. `~/Library/Group Containers/group.com.apple.MobileSMS/`
exists but only contains:
- `Library/Preferences/com.apple.IMCoreSpotlight.plist` (Spotlight indexing
  state — not images)
- Other state caches, no image bytes

The attachments directory under `~/Library/Messages/Attachments/` is the
single source of truth. Same place where every other Messages attachment
lives.

## Fallback strategy when groupPhotoGuid is missing

About 93% of groups have no custom photo. We mirror Messages.app's own UI:
**stacked composite avatar of the first few participants**.

- Pull participants via `chat_handle_join` (already populated by the
  existing `loadGroupParticipantNames` query — small refactor to also
  return the resolved handle list, not just names).
- For each participant, resolve a `Contact` via `ResolvedContacts.byHandle`
  and grab `avatarData`.
- Render the first 2-3 as overlapping circles. Generic person icon when a
  participant has no AddressBook entry / no photo.

## Implementation surface

For the data layer:
- Add an optional `avatarData: Data?` to `ContactStat` (people).
- Add an optional `chatAvatarData: Data?` + `participantAvatars: [Data?]` to
  `GroupStat` (groups). `chatAvatarData` is the resolved custom photo if
  any; `participantAvatars` is the stacked-fallback feedstock.

For the loader:
- `DashboardLoader.loadTopContacts` reads `Contact.avatarData` from the
  same `ResolvedContacts` it already uses for name merge.
- `DashboardLoader.loadTopGroups` reads `chat.properties`, parses the
  bplist, follows `groupPhotoGuid` to `attachment.filename`, expands `~`,
  reads the file bytes. Falls back to the participant-avatar list when
  there's no custom photo or the file fails to read.

For the rendering:
- `TopList` accepts entries with a precomposed avatar view, or builds
  `AvatarView` from the entry's bytes + initials fallback.
- A small `GroupAvatarView` stacks 2-3 circles when no single image.

## Caveats / known limitations

- **Sandboxed apps**: reading from `~/Library/Messages/Attachments/`
  requires Full Disk Access just like reading `chat.db`. Already required
  by every other feature in this app, so no new entitlement surface.
- **Permissions**: the file is owned by the user, mode 644. Direct read
  works once FDA is granted.
- **`chat.properties` parsing failure**: defensive — return nil on any
  decode failure, fall through to composite avatars.
- **`groupPhotoGuid` pointing at a missing attachment row**: never seen in
  the user's real data, but defensively handled the same way (nil →
  composite).
- **Memory**: at ~50 group photos per user with PNGs averaging ~500 KB
  each, an upper bound of ~25 MB if we read every one. The dashboard only
  shows the top 12, so practical bound is ~6 MB. Acceptable for an active
  Dashboard window; we don't cache across loads.
