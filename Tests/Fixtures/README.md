# Tests/Fixtures

Synthetic chat.db for integration tests. Tiny on purpose — checked into git.

## Build

```
./build_fixture_chat_db.sh
```

Idempotent. Re-running drops and recreates `chat.db` in place. Run it
whenever you change the script.

## What's in it

The fixture is hand-built to exercise every footgun documented in
`plans.md` → **Critical Technical Knowledge — chat.db**.

### Handles

| ROWID | id                     | service  | Notes                          |
|------:|------------------------|----------|--------------------------------|
| 1     | `+15551234567`         | iMessage | "Contact A" — phone            |
| 2     | `friend@example.com`   | iMessage | "Contact A" — email (alias)    |
| 3     | `+15557654321`         | iMessage | "Contact B" — group member     |

Handles 1 and 2 represent the **same human reached two ways** — the
contact-merge logic should collapse them.

### Chats

| ROWID | style | display_name | Members        | Notes              |
|------:|------:|--------------|----------------|--------------------|
| 1     | 45    | (null)       | handles 1, 2   | 1:1 — multi-handle |
| 2     | 43    | "Test Group" | handles 1, 3   | Group              |

### Messages

| ROWID | is_from_me | handle_id | date format | text  | attributedBody | associated_message_type | Chat | Notes                              |
|------:|-----------:|----------:|-------------|-------|----------------|------------------------:|-----:|------------------------------------|
| 1     | 1          | NULL      | nanoseconds | NULL  | hex blob       | 0                       | 1    | Modern sent — must decode blob     |
| 2     | 0          | 1         | seconds     | set   | NULL           | 0                       | 1    | Legacy row, seconds time           |
| 3     | 0          | 3         | nanoseconds | set   | NULL           | 0                       | 2    | Group, received from contact B     |
| 4     | 0          | 1         | nanoseconds | NULL  | NULL           | 2000                    | 2    | Tapback — must be filterable out   |
| 200   | 1          | NULL      | nanoseconds | NULL  | hex blob       | 0                       | 1    | Length-prefix bug — digit '2' (50) |
| 201   | 1          | NULL      | nanoseconds | NULL  | hex blob       | 0                       | 1    | Length-prefix bug — letter 'A' (65)|

### Gotchas exercised

- [x] **NULL text + decodable attributedBody** — row 1. Lossy UTF-8 decode +
      longest-printable-run heuristic surfaces `hello cactus how are you today`.
- [x] **Sent message with NULL handle_id** — row 1.
- [x] **Received message with real handle_id** — rows 2, 3, 4.
- [x] **1:1 chat (style=45)** and **group chat (style=43)** — chats 1, 2.
- [x] **Tapback (`associated_message_type != 0`)** — row 4 (type 2000).
- [x] **Nanosecond date** (post-10.13) — rows 1, 3, 4: `740_145_600_000_000_000`
      and adjacents = 2024-06-15 12:00:00 UTC + 1 min + 2 min.
- [x] **Seconds date** (legacy) — row 2: `298_296_000` = 2010-06-15 12:00:00 UTC.
- [x] **Two handles for the same contact** — handles 1 (`+15551234567`) and 2
      (`friend@example.com`), both in chat 1.
- [x] **Typedstream length-prefix leak — digit branch** — row 200. Blob has a
      `0x32` (= ASCII `'2'`) length byte followed by exactly 50 ASCII bytes.
      Naive lossy-UTF-8 decode would yield `"2xxxxx…"`; decoder must strip
      the leading `'2'`.
- [x] **Typedstream length-prefix leak — letter branch** — row 201. Blob has a
      `0x41` (= ASCII `'A'`) length byte followed by exactly 65 ASCII bytes.
      Tests the broadened printable-ASCII (not just digits) heuristic in
      `AttributedBodyDecoder.stripLengthPrefix`.

### Notes on the attributedBody blob (row 1)

We don't reproduce the full NSKeyedArchiver typedstream — we just need:

1. The "text-is-NULL, decode attributedBody" path to fire.
2. A lossy UTF-8 decode + longest-printable-run extraction to surface a known
   string. The blob's layout:

   ```
   04 0b                             typedstream magic (non-printable)
   "streamtyped"                     11-char run, broken by 0x81 0xe8 0x03…
   …framing…                         non-printable
   12 "NSString"                     length(0x12) + class name (8-char run)
   00 84 84 08                       breaks the run
   1e "hello cactus how are you today"   length(0x1e=30) + body (30-char run)
   86 84 02 69 86 84 00              trailing framing
   ```

The body run (30 chars) is the longest printable run, beating the class-name
runs ("NSString" = 8, "streamtyped" = 11). Tests that match this pattern
will pick up the body unambiguously.

### Time conversion cheatsheet

Mac epoch (2001-01-01 00:00:00 UTC) → Unix epoch: add `978_307_200`.

| Raw `date`                | Format       | UTC                  |
|---------------------------|--------------|----------------------|
| `740_145_600_000_000_000` | nanoseconds  | 2024-06-15 12:00:00  |
| `740_145_660_000_000_000` | nanoseconds  | 2024-06-15 12:01:00  |
| `740_145_720_000_000_000` | nanoseconds  | 2024-06-15 12:02:00  |
| `298_296_000`             | seconds      | 2010-06-15 12:00:00  |

Disambiguation threshold (from plans.md): `date > 1_000_000_000_000` → ns,
else seconds.
