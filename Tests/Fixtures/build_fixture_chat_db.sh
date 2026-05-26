#!/usr/bin/env bash
# Build a small synthetic chat.db fixture for tests.
#
# Exercises every gotcha listed in plans.md → "Critical Technical Knowledge — chat.db":
#   - NULL text + decodable attributedBody (typedstream-ish hex blob)
#   - Sent message (is_from_me=1) with NULL handle_id
#   - Received message with a real handle_id
#   - 1:1 chat (style=45) AND group chat (style=43)
#   - associated_message_type != 0 (a tapback) — filterable
#   - One date in NANOSECONDS (post-10.13) and one in SECONDS (legacy)
#   - Two handles for the same contact (phone + email) for contact-merge tests
#
# Output: Tests/Fixtures/chat.db
# Idempotent: drops and recreates every run.
#
# Run from anywhere; we cd to script's dir first.

set -euo pipefail

cd "$(dirname "$0")"

DB="chat.db"
rm -f "$DB"

# Notes on the synthetic typedstream blob for attributedBody:
#   Real chat.db `attributedBody` is an NSKeyedArchiver/typedstream-encoded
#   NSAttributedString. We don't reproduce the full encoding here — we just
#   need (a) the test exercises the "text IS NULL, decode attributedBody"
#   path and (b) a lossy UTF-8 decode + longest-printable-run extraction
#   surfaces a known string. The blob below is structured so the LONGEST
#   contiguous printable-ASCII run is the message body
#   "hello cactus how are you today" (30 chars).
#
#   Layout (hex):
#     04 0b                 typedstream version magic
#     73 74 72 65 61 6d     "stream"  ← 6-char printable run (broken by next non-printable)
#     74 79 70 65 64        "typed"
#     81 e8 03 84 01        non-printable framing
#     40                    '@' (would be a 1-char run on its own)
#     84 84 84 12           non-printable framing
#     12 4e 53 53 74 72 69 6e 67   length(0x12)+"NSString" → run "NSString" (8)
#     00 84 84 08           breaks the run
#     1e                    length byte (30) for the upcoming string
#     "hello cactus how are you today"  ← the message: 30-char run
#     86 84 02 69 86 84     trailing framing (mostly non-printable)
#
#   Note "streamtyped" appears in the original spec as one 11-char run
#   ("stream" + "typed" with no break between). That's fine — 11 < 30.

ATTRIB_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_HEX+="1e68656c6c6f2063616374757320686f772061726520796f7520746f64617986840269868400"

# ---------------------------------------------------------------------------
# Length-prefix bug fixture blobs (rows 200 / 201)
# ---------------------------------------------------------------------------
# These exercise the typedstream NSString length-prefix leak. Layout follows
# the same shape as the row-1 blob above:
#
#   04 0b           streamtyped magic
#   "streamtyped"   ASCII run (broken by next byte)
#   81 e8 03 84 01  framing
#   40              '@' framing sigil
#   84 84 84        framing
#   12 "NSString"   length(0x12)+class name
#   00 84 84 08     framing
#   <LEN>           the BUG: a single byte equal to the body's UTF-8 byte len
#   <BODY>          plain ASCII body, exactly LEN bytes
#   86 84 02 69 86 84 00   trailing framing
#
# Row 200: body is 50 'x' bytes → LEN = 0x32 (ASCII '2'). Pre-fix this
#          decodes as "2xxxxx…x" (51 chars). Post-fix it decodes as
#          "xxxxx…x" (50 chars).
# Row 201: body is 65 'y' bytes → LEN = 0x41 (ASCII 'A'). Pre-broadening
#          this decodes as "Ayyyyy…y" (66 chars) since the narrow rule
#          only handles digits. Post-broadening it decodes as "yyyyy…y".
#
# ---- row 200 (digit-prefix) ----
ATTRIB_DIGIT_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_DIGIT_HEX+="32"  # length prefix = 50 ('2')
# 50 'x' bytes in hex (= "78" repeated 50 times):
ATTRIB_DIGIT_HEX+="7878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878"
ATTRIB_DIGIT_HEX+="86840269868400"

# ---- row 201 (letter-prefix 'A') ----
ATTRIB_LETTER_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_LETTER_HEX+="41"  # length prefix = 65 ('A')
# 65 'y' bytes in hex (= "79" repeated 65 times):
ATTRIB_LETTER_HEX+="7979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979"
ATTRIB_LETTER_HEX+="86840269868400"

# ---------------------------------------------------------------------------
# Attachment-only UUID leak fixture (row 202)
# ---------------------------------------------------------------------------
# Mirrors the real-world layout for attachment-only messages where the
# attachment.guid leaks through as a bare canonical UUID. See
# docs/decoder-uuid-leak.md for the empirical finding.
#
# Layout:
#   04 0b                                          streamtyped magic
#   "streamtyped"                                  ASCII run (filtered)
#   81 e8 03 84 01                                 framing
#   40                                             '@' (trimmed)
#   84 84 84                                       framing
#   12 "NSString"                                  class header (filtered)
#   00 84 84 08                                    framing
#   22                                             length=34 for kIM attr key
#   "__kIMFileTransferGUIDAttributeName"           __kIM-prefixed (filtered)
#   00 84 84                                       framing
#   24                                             length=36 ('$') for UUID
#   "DEADBEEF-1234-5678-9ABC-DEF012345678"         the bare UUID — 36 chars
#   86 84 02 69 86 84 00                           trailing framing
#
# Run-split analysis:
#   The '$' length prefix is in the strippedFraming edge charset, so it gets
#   trimmed off the leading edge — leaving "DEADBEEF-1234-5678-9ABC-DEF012345678"
#   exactly as the longest surviving run. Pre-fix it decodes as the bare UUID.
#   Post-fix isCanonicalUUID drops the run and decode returns "".
ATTRIB_UUID_HEX="040b73747265616d747970656481e803840140848484124e53537472696e6700848408"
ATTRIB_UUID_HEX+="225f5f6b494d46696c655472616e73666572475549444174747269627574654e616d65"
ATTRIB_UUID_HEX+="00848424"
# "DEADBEEF-1234-5678-9ABC-DEF012345678" in ASCII hex:
ATTRIB_UUID_HEX+="44454144424545462d313233342d353637382d394142432d444546303132333435363738"
ATTRIB_UUID_HEX+="86840269868400"

# ---------------------------------------------------------------------------
# Inline-attachment marker (U+FFFC) fixtures (rows 203, 204, 205)
# ---------------------------------------------------------------------------
# NSAttributedString uses U+FFFC (OBJECT REPLACEMENT CHARACTER, UTF-8
# EF BF BC) as the inline-attachment placeholder. Every image / video /
# audio / file / sticker / link preview / Apple Pay / location / etc.
# embedded in a message's attributedBody is one U+FFFC scalar. An
# attachment-only message therefore decodes to:
#   - "￼"   for one attachment (Venkat's image-only row was this)
#   - "￼￼" for two attachments
#   - …
# The decoder must filter U+FFFC as non-printable so the longest-run
# extraction returns "" — letting the SpotlightResultRow type-label
# placeholder ("Image" / "Video" / …) render. Pre-fix this rendered as
# a row of literal ￼ glyphs (visually blank because the font has no
# default glyph for U+FFFC), which defeated the placeholder check.
#
# Layout (shared across rows 203/204/205, varying only in body length
# and marker count):
#   04 0b                            streamtyped magic
#   "streamtyped"                    ASCII run (filtered)
#   81 e8 03 84 01                   framing
#   40                               '@' (trimmed)
#   84 84 84                         framing
#   12 "NSString"                    class header (filtered)
#   00 84 84 08                      framing
#   <LEN>                            body byte count (3, 6, 9 — all non-printable)
#   <BODY>                           U+FFFC × N (3 bytes each)
#   86 84 02 69 86 84 00             trailing framing
#
# ---- row 203 (single attachment marker — Venkat / 1-image shape) ----
# Body = 1× U+FFFC = 3 UTF-8 bytes. Length byte = 0x03 (non-printable
# ASCII control, so our run-splitter cleanly breaks at it).
ATTRIB_FFFC_1_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_FFFC_1_HEX+="03"        # length=3
ATTRIB_FFFC_1_HEX+="efbfbc"    # U+FFFC × 1
ATTRIB_FFFC_1_HEX+="86840269868400"

# ---- row 204 (2 markers — common 2-photo post shape) ----
ATTRIB_FFFC_2_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_FFFC_2_HEX+="06"
ATTRIB_FFFC_2_HEX+="efbfbcefbfbc"
ATTRIB_FFFC_2_HEX+="86840269868400"

# ---- row 205 (3 markers — 3-photo / 3-attachment post) ----
ATTRIB_FFFC_3_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_FFFC_3_HEX+="09"
ATTRIB_FFFC_3_HEX+="efbfbcefbfbcefbfbc"
ATTRIB_FFFC_3_HEX+="86840269868400"

# ---- row 206 (1 marker + caption — "look at this ￼" shape) ----
# Body = "look at this " (13 bytes) + U+FFFC (3 bytes) = 16 bytes.
# Length byte = 0x10 (DLE, non-printable). Decoded body must contain
# "look at this" (no U+FFFC).
ATTRIB_FFFC_CAPTION_HEX="040b73747265616d747970656481e80384014084848412124e53537472696e670084840808"
ATTRIB_FFFC_CAPTION_HEX+="10"                          # length=16
ATTRIB_FFFC_CAPTION_HEX+="6c6f6f6b2061742074686973"    # "look at this" = 12 bytes
ATTRIB_FFFC_CAPTION_HEX+="20"                          # " " = 1 byte
ATTRIB_FFFC_CAPTION_HEX+="efbfbc"                      # U+FFFC = 3 bytes (total 16)
ATTRIB_FFFC_CAPTION_HEX+="86840269868400"

# ---------------------------------------------------------------------------
# Time values (Mac absolute time; epoch = 2001-01-01 00:00:00 UTC)
# ---------------------------------------------------------------------------
# Modern (nanoseconds): 2024-06-15 12:00:00 UTC
#   unix     = 1718452800
#   mac s    = 1718452800 - 978307200 = 740_145_600
#   mac ns   = 740_145_600 * 1e9     = 740_145_600_000_000_000
NS_DATE=740145600000000000

# Legacy (seconds): 2010-06-15 12:00:00 UTC
#   unix     = 1276603200
#   mac s    = 1276603200 - 978307200 = 298_296_000
SEC_DATE=298296000

# A second modern message a minute later (for ordering / multi-row scans):
NS_DATE_2=740145660000000000

# A tapback message — also nanoseconds, modern.
NS_DATE_TAPBACK=740145720000000000

# Bursts of tapbacks for the reactions tests — staggered by 30s each so the
# ascending-by-date load order is deterministic.
NS_DATE_TAPBACK_2=740145750000000000
NS_DATE_TAPBACK_3=740145780000000000
NS_DATE_TAPBACK_4=740145810000000000
NS_DATE_TAPBACK_5=740145840000000000
NS_DATE_TAPBACK_6=740145870000000000
NS_DATE_TAPBACK_7=740145900000000000
NS_DATE_TAPBACK_8=740145930000000000
NS_DATE_TAPBACK_9=740145960000000000
NS_DATE_TAPBACK_10=740145990000000000
NS_DATE_TAPBACK_11=740146020000000000

# A "reactable" message (row 5) with a known GUID we can target from
# tapback rows. This is the message we'll surface in the reaction-loader
# test as having multiple reactions.
NS_DATE_REACTABLE=740146050000000000

# ---------------------------------------------------------------------------
# Dashboard fixture extras
# ---------------------------------------------------------------------------
# Dates anchored to 2026-05-15 12:00 UTC so they fall comfortably inside the
# "last 30 days" window when the test clock is 2026-05-22 (the current
# canonical date in plans.md / CLAUDE.md).
#
# We want enough data to make every dashboard aggregation meaningful:
#   - one 1:1 chat with a SECOND contact so top-contacts has order
#   - one named group with several sent-by-me messages so top-groups
#     ranking actually has a #1
#   - messages spanning multiple days (so day-bucketed time series has
#     more than one row) and a couple of months apart (so month-bucketed
#     12m view has multiple buckets too)
#
# Mac-absolute-time conversions (computed via:
#   ns = (calendar.timegm((Y,M,D,12,0,0,0,0,0)) - 978307200) * 1e9
# all anchored to 12:00 UTC):
#   2026-05-15 12:00:00 UTC: mac ns=800539200000000000
#   2026-05-14 12:00:00 UTC: mac ns=800452800000000000
#   2026-05-13 12:00:00 UTC: mac ns=800366400000000000
#   2026-04-15 12:00:00 UTC: mac ns=797947200000000000   (~37 days before "now"=2026-05-22)
#   2026-04-14 12:00:00 UTC: mac ns=797860800000000000
#   2026-03-15 12:00:00 UTC: mac ns=795268800000000000   (~68 days before "now")
#   2025-11-15 12:00:00 UTC: mac ns=784900800000000000   (~6 months before)
# Anchor "now" for tests is 2026-05-22 12:00 UTC (matches the canonical
# date in plans.md). Last-30-days window = approx 2026-04-22 to 2026-05-22,
# so RECENT_* are inside, LASTMONTH_* are JUST outside, TWOMONTHS_* +
# SIXMONTHS_* are well outside.
NS_DATE_RECENT_A=800539200000000000
NS_DATE_RECENT_B=800452800000000000
NS_DATE_RECENT_C=800366400000000000
NS_DATE_LASTMONTH_A=797947200000000000
NS_DATE_LASTMONTH_B=797860800000000000
NS_DATE_TWOMONTHS_A=795268800000000000
NS_DATE_SIXMONTHS_A=784900800000000000

sqlite3 "$DB" <<SQL
PRAGMA foreign_keys = OFF;

-- ----- schema (minimal-but-realistic subset of real chat.db) -----

CREATE TABLE handle (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL,                 -- "+15551234567" or "friend@example.com"
    country TEXT,
    service TEXT,                     -- "iMessage" or "SMS"
    uncanonicalized_id TEXT
);

CREATE TABLE chat (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    guid TEXT NOT NULL,
    style INTEGER,                    -- 45 = 1:1, 43 = group
    state INTEGER,
    account_id TEXT,
    chat_identifier TEXT,
    service_name TEXT,
    room_name TEXT,
    display_name TEXT,
    properties BLOB                    -- bplist00; may contain groupPhotoGuid
);

-- Attachment table: minimal subset used by ChatPhotoLoader. Real chat.db
-- has many more columns; we only need the guid (join key) and filename
-- (the tilde-prefixed path to the actual image bytes on disk).
CREATE TABLE attachment (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    guid TEXT NOT NULL,
    filename TEXT,
    uti TEXT,
    mime_type TEXT,
    total_bytes INTEGER
);

CREATE TABLE chat_handle_join (
    chat_id INTEGER,
    handle_id INTEGER,
    UNIQUE (chat_id, handle_id)
);

CREATE TABLE message (
    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
    guid TEXT,
    text TEXT,
    handle_id INTEGER,                -- NULL when is_from_me=1
    is_from_me INTEGER NOT NULL DEFAULT 0,
    date INTEGER,                     -- Mac absolute time (ns post-10.13, s legacy)
    date_read INTEGER,
    date_delivered INTEGER,
    is_read INTEGER DEFAULT 0,
    is_sent INTEGER DEFAULT 0,
    service TEXT,                     -- "iMessage" / "SMS"
    account TEXT,
    associated_message_guid TEXT,
    associated_message_type INTEGER DEFAULT 0,  -- 0 = real msg, nonzero = tapback
    associated_message_emoji TEXT,    -- non-NULL for custom-emoji reactions (type=2006)
    attributedBody BLOB
);

CREATE TABLE chat_message_join (
    chat_id INTEGER,
    message_id INTEGER,
    message_date INTEGER,
    UNIQUE (chat_id, message_id)
);

-- ----- handles -----
-- Same contact, two handles (phone + email): handles 1 and 2.
INSERT INTO handle (ROWID, id, country, service) VALUES (1, '+15551234567', 'us', 'iMessage');
INSERT INTO handle (ROWID, id, country, service) VALUES (2, 'friend@example.com', 'us', 'iMessage');

-- A second contact, for the group chat:
INSERT INTO handle (ROWID, id, country, service) VALUES (3, '+15557654321', 'us', 'iMessage');

-- Additional handle for the dashboard extras: a separate 1:1 partner so the
-- top-contacts ranking has more than one row. Picks a distinct prefix so
-- it can't be conflated with contacts 1-3.
INSERT INTO handle (ROWID, id, country, service) VALUES (4, '+15558889999', 'us', 'iMessage');

-- ----- chats -----
-- 1:1 chat (style=45) with the multi-handle contact.
INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (1, 'iMessage;-;+15551234567', 45, '+15551234567', 'iMessage', NULL);

-- Group chat (style=43).
INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (2, 'iMessage;+;chat0000001', 43, 'chat0000001', 'iMessage', 'Test Group');

-- Dashboard extras: a second 1:1 chat with handle 4, and a second named
-- group "Dashboard Group" so top-groups ranking has order.
INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (3, 'iMessage;-;+15558889999', 45, '+15558889999', 'iMessage', NULL);

INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
VALUES (4, 'iMessage;+;chat0000002', 43, 'chat0000002', 'iMessage', 'Dashboard Group');

-- ----- chat_handle_join -----
-- 1:1 chat has both phone and email handles for the same contact.
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 1);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 2);

-- Group has handles 1 and 3.
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 1);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 3);

-- Dashboard 1:1 has handle 4 only.
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (3, 4);

-- Dashboard group has handles 1, 3, and 4 — three "participants" not
-- counting "me".
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (4, 1);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (4, 3);
INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (4, 4);

-- ----- messages -----
-- 1) Sent message: is_from_me=1, handle_id NULL, MODERN (ns) date,
--    text NULL, attributedBody populated. Exercises the most common
--    modern-chat-db row shape.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (1, 'msg-0001', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_HEX');

-- 2) Received message: is_from_me=0, handle_id=1 (phone), plain text,
--    legacy SECONDS date — exercises the seconds branch and the
--    "handle_id is real" branch.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (2, 'msg-0002', 'legacy reply with text column populated', 1, 0, $SEC_DATE, 'iMessage',
   0, NULL);

-- 3) Received message in group from a different handle (3), modern ns,
--    plain text — exercises group-chat membership lookup.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (3, 'msg-0003', 'group hello from contact 3', 3, 0, $NS_DATE_2, 'iMessage',
   0, NULL);

-- 4) Tapback message: associated_message_type != 0. Must be filterable
--    by predicate associated_message_type = 0.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (4, 'msg-0004-tap', NULL, 1, 0, $NS_DATE_TAPBACK, 'iMessage',
   'bp:msg-0003', 2000, NULL);

-- 5) Highly-reacted target message: a regular message in the 1:1 chat
--    that we'll attach 6 reactions to (2 loves, 1 like, 1 laugh,
--    1 custom-emoji, 1 sticker). Used by ReactionLoaderTests.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (5, 'msg-0005-reactable', 'check this out, big news', NULL, 1, $NS_DATE_REACTABLE,
   'iMessage', 0, NULL);

-- ----- reaction rows (associated_message_type in 2000-2999) -----
-- All target msg-0005-reactable. Mix of senders and types so the tests can
-- assert grouping, kind decoding, the per-sender "latest wins" rule, and
-- the prefix-stripping behavior on associated_message_guid.

-- 6) Love from contact handle 1 (phone). Prefix: p:0/
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (6, 'rxn-0001', NULL, 1, 0, $NS_DATE_TAPBACK_2, 'iMessage',
   'p:0/msg-0005-reactable', 2000, NULL);

-- 7) Love from contact handle 3 (phone). Prefix: p:0/
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (7, 'rxn-0002', NULL, 3, 0, $NS_DATE_TAPBACK_3, 'iMessage',
   'p:0/msg-0005-reactable', 2000, NULL);

-- 8) Laugh from handle 3. Prefix: bp:  (older format)
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (8, 'rxn-0003', NULL, 3, 0, $NS_DATE_TAPBACK_4, 'iMessage',
   'bp:msg-0005-reactable', 2003, NULL);

-- 9) Like from "me" (handle_id NULL, is_from_me=1).
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (9, 'rxn-0004', NULL, NULL, 1, $NS_DATE_TAPBACK_5, 'iMessage',
   'p:0/msg-0005-reactable', 2001, NULL);

-- 10) Custom emoji from handle 1. associated_message_emoji is "🤓".
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, associated_message_emoji,
   attributedBody)
VALUES
  (10, 'rxn-0005', NULL, 1, 0, $NS_DATE_TAPBACK_6, 'iMessage',
   'p:0/msg-0005-reactable', 2006, '🤓', NULL);

-- 11) Sticker reaction (type 2007). No emoji. From handle 3.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (11, 'rxn-0006', NULL, 3, 0, $NS_DATE_TAPBACK_7, 'iMessage',
   'p:0/msg-0005-reactable', 2007, NULL);

-- 12) REMOVED reaction (type 3000). Loader MUST drop this — it's historical.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (12, 'rxn-0007', NULL, 1, 0, $NS_DATE_TAPBACK_8, 'iMessage',
   'p:0/msg-0005-reactable', 3000, NULL);

-- 13) handle 1 switches from custom-emoji to dislike (later date wins).
--     "Latest wins" per-sender rule means rxn-0005 should DROP and this
--     dislike is the active reaction from handle 1.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type, attributedBody)
VALUES
  (13, 'rxn-0008', NULL, 1, 0, $NS_DATE_TAPBACK_9, 'iMessage',
   'p:0/msg-0005-reactable', 2002, NULL);

-- ----- dashboard fixture extras (rows 100+) -----
-- These are real (associated_message_type=0) messages spread across two
-- contacts (handles 1+2 → same person; handle 4 → different person) and
-- two groups (chats 2 and 4). The goal is to make every dashboard
-- aggregation produce ordered, distinguishable results.
--
-- Ranking targets (window = last 30 days, anchor = NS_DATE_RECENT_*):
--   Contact A (handle 1 / 2) — chat 1, 1:1: 3 sent + 2 received = 5 total
--   Contact B (handle 4)     — chat 3, 1:1: 1 sent + 0 received = 1 total
--   → top-contacts in last-30-days = [Contact A first, Contact B second]
--
--   Dashboard Group (chat 4): 4 sent by me
--   Test Group       (chat 2): 1 sent by me  (none in original fixture; we
--                                              add one here so it appears)
--   → top-groups in last-30-days = [Dashboard Group first, Test Group second]
--
-- Rows are numbered 100+ so they don't collide with the reaction fixture's
-- 1-13 range. Dates land:
--   * NS_DATE_RECENT_*    → within last 30 days (test "30d" window)
--   * NS_DATE_LASTMONTH_* → ~1 month back     (test "12m" but not "30d")
--   * NS_DATE_TWOMONTHS_* → ~2 months back    (still within 12m)
--   * NS_DATE_SIXMONTHS_* → 6 months back     (all-time only)

-- Contact A (chat 1, handles 1/2 — same person):
-- 3 sent in last 30 days + 2 received in last 30 days
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (100, 'msg-dash-100', 'recent A sent 1', NULL, 1, $NS_DATE_RECENT_A, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (101, 'msg-dash-101', 'recent A sent 2', NULL, 1, $NS_DATE_RECENT_B, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (102, 'msg-dash-102', 'recent A sent 3', NULL, 1, $NS_DATE_RECENT_C, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (103, 'msg-dash-103', 'recent A reply 1', 1, 0, $NS_DATE_RECENT_A, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (104, 'msg-dash-104', 'recent A reply 2 from email', 2, 0, $NS_DATE_RECENT_B, 'iMessage', 0);

-- Contact A also has older traffic so all-time totals are bigger than
-- the windowed totals.
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (105, 'msg-dash-105', 'two months ago sent', NULL, 1, $NS_DATE_TWOMONTHS_A, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (106, 'msg-dash-106', 'six months ago received', 1, 0, $NS_DATE_SIXMONTHS_A, 'iMessage', 0);

-- Contact B (chat 3, handle 4): one sent in last 30 days.
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (110, 'msg-dash-110', 'sent to B today', NULL, 1, $NS_DATE_RECENT_A, 'iMessage', 0);

-- Test Group (chat 2): one sent message from me in last 30 days (no sent
-- messages in the original fixture, so this puts it on the leaderboard).
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (120, 'msg-dash-120', 'hello group 1 from me', NULL, 1, $NS_DATE_RECENT_A, 'iMessage', 0);

-- Dashboard Group (chat 4): 4 sent + 1 received in last 30 days, so it
-- outranks Test Group.
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (130, 'msg-dash-130', 'dash group sent 1', NULL, 1, $NS_DATE_RECENT_A, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (131, 'msg-dash-131', 'dash group sent 2', NULL, 1, $NS_DATE_RECENT_B, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (132, 'msg-dash-132', 'dash group sent 3', NULL, 1, $NS_DATE_RECENT_C, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (133, 'msg-dash-133', 'dash group sent 4', NULL, 1, $NS_DATE_LASTMONTH_A, 'iMessage', 0);
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service, associated_message_type)
VALUES (134, 'msg-dash-134', 'dash group reply', 3, 0, $NS_DATE_RECENT_A, 'iMessage', 0);

-- A tapback in chat 1 (handle 3 reaction to msg-dash-100) — verifies
-- tapbacks STILL get excluded from dashboard counts after our extras.
INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_guid, associated_message_type)
VALUES (140, 'msg-dash-140-tap', NULL, 3, 0, $NS_DATE_RECENT_A, 'iMessage',
   'p:0/msg-dash-100', 2000);

-- ----- length-prefix bug fixture rows (200, 201) -----
-- These exercise AttributedBodyDecoder.stripLengthPrefix for both branches:
--
--   row 200: digit length prefix '2' (= 50) over a 50-byte body. Pre-fix
--            decoded as "2xxx…" (51 chars); post-fix decodes as "xxx…" (50).
--   row 201: letter length prefix 'A' (= 65) over a 65-byte body. Pre
--            BROADENING this leaked through (the narrow rule only handled
--            digits); post-broadening it decodes clean.
--
-- Both rows are SENT by me, modern (nanoseconds), with NULL text and a
-- non-NULL attributedBody — the most common modern-row shape.
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (200, 'msg-lp-digit', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_DIGIT_HEX');

INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (201, 'msg-lp-letter', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_LETTER_HEX');

-- Row 202: bare-canonical-UUID leak (see decoder-uuid-leak.md). The blob
-- shape mirrors a video/attachment-only message whose attributedBody embeds
-- the attachment.guid next to __kIMFileTransferGUIDAttributeName. Pre-fix
-- this decodes to the bare UUID "DEADBEEF-..."; post-fix decodes to "".
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (202, 'msg-uuid-leak', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_UUID_HEX');

-- Rows 203–206: U+FFFC inline-attachment marker fixtures. These mirror
-- the typedstream shape of attachment-only messages of ANY type (image,
-- video, audio, file, sticker, link preview, Apple Pay, location, ...) —
-- NSAttributedString stamps one U+FFFC per attachment regardless. Pre-fix
-- these decoded to "￼", "￼￼", "￼￼￼" — visually blank but non-empty,
-- so the SpotlightResultRow type-label placeholder didn't render. Post-
-- fix: rows 203–205 decode to "" (placeholder fires), row 206 decodes
-- to the caption text only (no U+FFFC leakage).
INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (203, 'msg-fffc-1', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_FFFC_1_HEX');

INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (204, 'msg-fffc-2', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_FFFC_2_HEX');

INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (205, 'msg-fffc-3', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_FFFC_3_HEX');

INSERT INTO message
  (ROWID, guid, text, handle_id, is_from_me, date, service,
   associated_message_type, attributedBody)
VALUES
  (206, 'msg-fffc-caption', NULL, NULL, 1, $NS_DATE, 'iMessage',
   0, x'$ATTRIB_FFFC_CAPTION_HEX');

-- ----- chat_message_join -----
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 1, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 2, $SEC_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 3, $NS_DATE_2);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 4, $NS_DATE_TAPBACK);
-- The reactable message lives in chat 1 (1:1 with the multi-handle contact).
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 5, $NS_DATE_REACTABLE);
-- Reaction rows are joined to the same chat so chat-scoped tests still work.
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 6, $NS_DATE_TAPBACK_2);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 7, $NS_DATE_TAPBACK_3);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 8, $NS_DATE_TAPBACK_4);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 9, $NS_DATE_TAPBACK_5);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 10, $NS_DATE_TAPBACK_6);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 11, $NS_DATE_TAPBACK_7);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 12, $NS_DATE_TAPBACK_8);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 13, $NS_DATE_TAPBACK_9);

-- Dashboard fixture joins. Rows 100-106 live in chat 1 (Contact A 1:1).
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 100, $NS_DATE_RECENT_A);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 101, $NS_DATE_RECENT_B);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 102, $NS_DATE_RECENT_C);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 103, $NS_DATE_RECENT_A);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 104, $NS_DATE_RECENT_B);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 105, $NS_DATE_TWOMONTHS_A);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 106, $NS_DATE_SIXMONTHS_A);

-- Contact B chat 3
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (3, 110, $NS_DATE_RECENT_A);

-- Test Group (chat 2) — new sent message from me
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (2, 120, $NS_DATE_RECENT_A);

-- Dashboard Group (chat 4) — sent 4 + 1 received
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (4, 130, $NS_DATE_RECENT_A);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (4, 131, $NS_DATE_RECENT_B);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (4, 132, $NS_DATE_RECENT_C);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (4, 133, $NS_DATE_LASTMONTH_A);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (4, 134, $NS_DATE_RECENT_A);

-- The dashboard-fixture tapback (row 140) lives in chat 1.
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 140, $NS_DATE_RECENT_A);

-- Length-prefix bug fixture rows (200, 201) — chat 1 (1:1).
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 200, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 201, $NS_DATE);
-- UUID-leak fixture row (202) — chat 1.
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 202, $NS_DATE);
-- U+FFFC inline-attachment marker fixture rows (203–206) — chat 1.
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 203, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 204, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 205, $NS_DATE);
INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (1, 206, $NS_DATE);

-- ----- indexes (mirror real chat.db enough to keep query plans honest) -----
CREATE INDEX message_idx_date ON message(date);
CREATE INDEX message_idx_handle_id ON message(handle_id);
CREATE INDEX chat_message_join_idx ON chat_message_join(message_id);
SQL

echo "Built: $(pwd)/$DB"
sqlite3 "$DB" "SELECT 'messages: ' || COUNT(*) FROM message;"
sqlite3 "$DB" "SELECT 'chats: ' || COUNT(*) FROM chat;"
sqlite3 "$DB" "SELECT 'handles: ' || COUNT(*) FROM handle;"
