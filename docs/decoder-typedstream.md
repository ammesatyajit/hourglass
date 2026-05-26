# `message.attributedBody` typedstream decoder

Canonical reference for `Sources/Data/Typedstream.swift` and the refactored
`Sources/Data/AttributedBodyDecoder.swift`. **If you are reading this
because you are about to add a heuristic to the decoder, stop. The
correct fix is in this file.**

## Background

`message.attributedBody` in iMessage's `chat.db` is an `NSArchiver`-encoded
`NSAttributedString`. Apple deprecated `NSArchiver`/`NSUnarchiver` in macOS
10.13 and removed them from Swift entirely; `NSKeyedUnarchiver` decodes a
different format (binary plist) and rejects these blobs outright. Foundation
gives us nothing to read them with — we have to implement the parser
ourselves.

Before this fix, the decoder used a heuristic: lossy-UTF-8-decode the raw
bytes, split on non-printable scalars, return the longest run. That
approach was the source of a steady drip of bugs:

| Symptom                             | Pre-fix workaround                  |
|-------------------------------------|-------------------------------------|
| "2Looks like..."                    | digit-prefix strip heuristic        |
| "DSample Person..."                | broadened printable-ASCII strip     |
| "6Noah said..."                     | digit-then-uppercase fallback       |
| Bare UUID like `6063E5D5-...`       | UUID exact-match filter             |
| `￼` glyphs in attachment-only rows  | U+FFFC filter                       |
| `__kIMMessagePartAttributeName?`    | metadata-prefix filter              |

Each one was a different shape of the same root problem: **we were guessing
at the format instead of parsing it.** Every fix patched a symptom.

## The actual format

A typedstream is a sequence of *typed values* with a small fixed header.
References: [python-typedstream](https://github.com/dgelessus/python-typedstream)
(canonical reader, well-commented), [imessage-exporter](https://github.com/ReagentX/imessage-exporter)'s
legacy `streamtyped.rs`. Apple's archived NSArchiver headers (early Darwin
sources) are partial but useful.

### Header (5+ bytes)

```
04                streamer version (4 = modern macOS / late NeXTSTEP)
0b                signature length (always 11)
"streamtyped"     little-endian magic (Apple variant)
"typedstream"     big-endian magic (legacy NeXTSTEP)
<integer>         system version (typically 1000 = macOS)
```

### Type-encoding-prefixed values

After the header, the stream is a sequence of typed-value *groups*:

```
<shared-string>   the type-encoding string (e.g. "@", "i", "@@@")
<value>...        one value per char in the encoding
```

Each value is read by first consuming a *head byte*: a signed byte that
either (a) literally encodes a small integer in `[-110, 127]` or (b) is a
TAG indicating a structured read.

### Tag table

| Constant            | Signed | Hex  | Meaning |
|---------------------|-------:|:----:|---------|
| `_TAG_INTEGER_2`    |  -127  | 0x81 | next 2 bytes = LE/BE u16 |
| `_TAG_INTEGER_4`    |  -126  | 0x82 | next 4 bytes = LE/BE u32 |
| `_TAG_FLOATING_POINT` | -125 | 0x83 | next 4 or 8 bytes = IEEE float/double |
| `_TAG_NEW`          |  -124  | 0x84 | literal (string/class/object/c-string) |
| `_TAG_NIL`          |  -123  | 0x85 | nil (any reference type) |
| `_TAG_END_OF_OBJECT`|  -122  | 0x86 | terminates an object's field list |

Tags occupy signed bytes in `[-128, -111]` = unsigned `[0x80, 0x91]`.
Back-reference numbers start at -110 (= 0x92, just past the last tag).

### Length prefixes

For an unshared string (encoding `+`, used for NSString bodies), the head
byte is the length:
- If the length fits in signed `[-110, 127]`, the head byte IS the length
  (interpreted unsigned for lengths 128+; sign-extended for control chars).
- Otherwise, `TAG_INTEGER_2` (0x81) or `TAG_INTEGER_4` (0x82) follows with
  the length as a 2-byte or 4-byte little-endian integer.

**This length byte is the source of every "leading character leak" bug
that the heuristic decoder ever had.** A 50-byte ASCII string is encoded
as `[0x32][50 bytes]`. After lossy UTF-8 decode, `0x32` survives as `'2'`
and gets glued to the front of the body. The typedstream parser reads the
length byte CORRECTLY as a length (not as text), so this entire class of
bug evaporates.

### Strings (two kinds)

**Unshared** (encoding `+`): head byte is the length (or `TAG_INTEGER_N`),
followed by exactly that many UTF-8 bytes. Used for NSString bodies.

**Shared** (used everywhere a string can repeat): head is either
`TAG_NEW` (literal — read the unshared form, append to shared-string
table) or a back-reference number (look up in shared-string table).

### Objects

```
[84]                  TAG_NEW (begin object)
<class chain>         one or more SingleClass entries (each: name + version)
                      terminated by NIL or a backref
<field values>...     one or more typed-value groups, each with their own
                      shared-string type encoding
[86]                  TAG_END_OF_OBJECT
```

**Object slot is reserved BEFORE the class chain is read.** The class
chain itself adds entries to the unified backref table, so the object's
own slot has to be claimed first as a placeholder, then replaced when the
object is finalized.

### Unified back-reference table

This is the single most important detail of the format and the thing my
parser got wrong on the first attempt.

The typedstream has a SINGLE unified numbering space for back-references
that spans c-strings, classes, AND objects. Every literal of any of these
types appends one entry, in encounter order. A back-reference decodes
the same way regardless of context.

**Shared strings are SEPARATE** — they have their own table for
type-encoding-style backrefs (which repeat all over the place).

When reading a class chain like `NSAttributedString → NSObject → NIL`,
the table gets TWO entries appended: one for `[NSAttributedString,
NSObject]` (the suffix at index 0) and one for `[NSObject]` (the suffix
at index 1). A backref to either points to the right starting class.

When reading an object, the slot is reserved BEFORE class reading.
Then class reading appends its own entries. Then field reading runs
(which may itself spawn nested objects, each reserving their own slots).
Finally the object's placeholder is replaced.

This ordering is enforced by python-typedstream's `decode_any_untyped_value`
and is what `Typedstream.swift::readObject` mirrors.

## What the new decoder does

1. **Primary path**: `Typedstream.extractString(_:)` parses the blob as
   a real `NSArchiver` typedstream, walks the resulting object tree,
   finds the first NSString-flavored object (NSString, NSMutableString,
   NSAttributedString, NSMutableAttributedString), extracts its
   underlying string. Returns the raw value to the decoder.

2. **Postprocess**: strip U+FFFC (attachment markers — present inside
   the NSString text payload, not as separate objects) and U+FFFD from
   the leading edge (REPLACEMENT CHARACTER, inserted when the NSString
   contains non-UTF-8 bytes; rare ~0.1% of blobs).

3. **Fallback path**: if the parser throws (truncated, corrupt, unknown
   future format), fall back to the legacy lossy-UTF-8 + longest-printable-run
   heuristic. Logs a debug message on every fallback so we can monitor
   the rate.

The fallback exists ONLY for resilience. On the user's real chat.db the
parser-success rate is **100%** (10,000 / 10,000 samples). The fallback
should never trigger for healthy rows.

## Statistical pass criterion

The audit script at `scripts/decoder_leakage_audit.swift` samples 10,000
random messages with non-NULL `attributedBody`, decodes each, and classifies
the decoded body. Pass criteria:

1. **Parser success rate ≥ 95%** (in practice: 100%)
2. **Leakage rate < 0.1%** of non-empty decoded bodies. A body is "leaked"
   if its first non-whitespace character matches a pattern observed in
   the pre-fix histogram as a typedstream-byte leak. See the inline
   docstring in the audit script for the classifier rules.
3. **Zero metadata leaks** — no body decodes to a sequence containing
   typedstream metadata strings like `streamtyped`, `NSAttributedString`,
   `__kIMMessagePartAttributeName`. These were the "complete failure"
   signal of earlier bugs.

### Measured results (post-fix)

| Run | Parser success | Leak rate | Metadata leaks |
|-----|----------------|-----------|----------------|
| 1   | 10,000 / 10,000 (100%) | 0.0205% | 0 |
| 2   | 10,000 / 10,000 (100%) | 0.0205% | 0 |
| 3   | 10,000 / 10,000 (100%) | 0.0102% | 0 |

**Pre-fix baseline (from `docs/decoder-fix-empirical.md`): 15.5%.**
**Reduction: ~750-1500x.**

The two flagged rows in run #1 were actual user content ("HAhHAHHHA"
laughter, ":D" smiley) that the classifier conservatively flagged. Real
leaks at <2 per 10,000 messages. The threshold is set at 0.1% (10 of
10,000) to allow for genuinely-unusual user content without flagging it.

### Re-running

```bash
# Full statistical audit against the user's real chat.db (~30 seconds).
# Requires Full Disk Access for the shell.
swift scripts/decoder_leakage_audit.swift

# Smaller sample (faster but noisier):
swift scripts/decoder_leakage_audit.swift 1000
```

The same logic ALSO runs as `Tests/DecoderLeakageAuditTests.swift`. The
test SKIPs cleanly when chat.db isn't accessible (CI, no FDA, no
iMessage history) so `./scripts/test.sh` is green on any machine.

## Known unsupported cases

- **Streamer version 3** (old NeXTSTEP): not supported. We've never seen
  one in real chat.db. Falls through to the heuristic.
- **Type encodings we don't decode**: bitfield (`b`), array of arrays
  with complex element types. None of these appear in real
  `attributedBody` blobs; if one shows up, the parser throws
  `unsupportedTypeEncoding` and the decoder falls back.
- **Truncated blobs**: throws `unexpectedEnd`, falls back. Real chat.db
  doesn't have these.

## Why the heuristic fallback stays

A strict parser is correct, but real data has surprises:

- Future Messages.app versions may introduce new typedstream subtleties.
- Truncation, corruption, or partial writes during a Messages.app crash
  could yield blobs that don't parse.

For these cases, the legacy heuristic gives us a degraded-but-not-broken
display. We log every fallback so we can track residual unparseable
cases over time.

The heuristic's old bugs (length-prefix leak, UUID leak, etc.) are also
still patched in the fallback's code. That code only runs for the rare
fallback case — and even on its own, it's better than nothing.

## What this fix is NOT

- Not a new search engine, indexing change, or panel UI tweak.
- Not a change to `Message`, `MessageSearch.Result`, or any public API.
- Not a new SPM dependency. SwiftPM-pure.
- Not a `Sources/Reveal/` change.

The change set is exactly: one new file (`Sources/Data/Typedstream.swift`),
a refactor of `Sources/Data/AttributedBodyDecoder.swift` to delegate to
it, two test files (`Tests/TypedstreamTests.swift`,
`Tests/DecoderLeakageAuditTests.swift`), one script
(`scripts/decoder_leakage_audit.swift`), and this doc.
