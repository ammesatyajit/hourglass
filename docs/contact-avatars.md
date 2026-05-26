# Contact avatars in macOS AddressBook

How macOS stores contact photos, empirically verified against the user's
real `AddressBook-v22.abcddb` on macOS 26.5 (Tahoe).

## Where the bytes live

The schema is Core-Data-generated (`ZABCDRECORD` etc). For each contact:

| Column | Type | Holds |
|---|---|---|
| `ZIMAGEDATA` | BLOB | Full-resolution photo (or pointer to it) |
| `ZTHUMBNAILIMAGEDATA` | BLOB | Thumbnail variant (or pointer to it) |
| `ZIMAGETYPE` | VARCHAR | `"PHOTO"`, `"MONOGRAM"`, etc. — empirically informational only |
| `ZIMAGEREFERENCE` | VARCHAR | iCloud gateway URL (NOT a local path — don't use) |

**`ZABCDLIKENESS` is empty in this DB.** It's a Core Data entity that
exists but nothing populates it. Don't waste a join on it.

## Two storage modes — distinguished by the first byte

The BLOB is **framed**:

### Mode 1 — inline (`0x01`)

The first byte is `0x01`. Bytes 1..end are the raw image. Real magic
follows:

- `01 89 50 4E 47 0D 0A 1A` → PNG (`\x89PNG\r\n\x1a`)
- `01 FF D8 FF E0` / `01 FF D8 FF E1` / `01 FF D8 FF DB` → JPEG

In the user's DB: **63 of 101** records with `ZIMAGEDATA` use inline mode.

### Mode 2 — external (`0x02`)

The first byte is `0x02`. The remaining bytes are an ASCII UUID
(36 chars) plus a null terminator — 38 bytes total. The UUID is the
filename in the sibling `_EXTERNAL_DATA/` directory:

```
~/Library/Application Support/AddressBook/Sources/<UUID>/
  AddressBook-v22.abcddb              ← contains the 0x02 reference
  .AddressBook-v22_SUPPORT/
    _EXTERNAL_DATA/
      <UUID-from-the-blob>             ← raw PNG/JPEG bytes
```

Files in `_EXTERNAL_DATA/` are raw images (no `0x02` framing). `file(1)`
on a sample returns `JPEG image data, JFIF standard 1.01, ...`.

In the user's DB: **38 of 101** records with `ZIMAGEDATA` use external
mode.

### Tiny-thumb sentinel

A 38-byte `ZTHUMBNAILIMAGEDATA` value is always external (mode 2). A
larger blob is always inline (mode 1). The first byte tells you which —
don't rely on length.

## Recommended decode pipeline

```
loadAvatar(record) -> Data? {
    let raw = record.ZIMAGEDATA            // or ZTHUMBNAILIMAGEDATA
    guard let raw, raw.count > 1 else { return nil }
    switch raw[0] {
    case 0x01:                              // inline
        return raw.dropFirst()              // → PNG/JPEG bytes
    case 0x02:                              // external
        let nameEnd = raw[1..<raw.count].firstIndex(of: 0x00) ?? raw.endIndex
        let uuid = String(data: raw[1..<nameEnd], encoding: .ascii)
        return try? Data(contentsOf: externalDir.appending(uuid))
    default:                                // unknown framing — bail
        return nil
    }
}
```

## Prefer thumbnail when both present

`ZTHUMBNAILIMAGEDATA` exists for 108 of 502 contacts in the user's DB,
slightly more than `ZIMAGEDATA` (101). Avg sizes: ~31KB thumb vs ~43KB
full. For a 28pt or 36pt avatar in search results, the thumbnail is the
right choice — it's the version macOS uses for compact UI. Fall back to
`ZIMAGEDATA` only if thumb is missing.

## Sizing distribution (user's DB)

- ZIMAGEDATA: min 38 / max 130734 / avg 43721 bytes
- ZTHUMBNAILIMAGEDATA: min 38 / max 126744 / avg 30978 bytes

The 38-byte minimum is the `0x02` + UUID + null sentinel — every record
with that exact size is an external reference.

## What's not used

- `ZIMAGEREFERENCE` — `https://gateway.icloud.com/contacts/...` URL.
  Useless without iCloud auth. Don't fetch.
- `ZEXTERNALFILENAME` — a `.vcf` filename, not an image. Red herring.
- `ZABCDLIKENESS` — schema exists, table empty in this DB.

## Caveats / known limitations

- **Memoji / monograms**: `ZIMAGETYPE = 'MONOGRAM'` rows exist in some
  DBs (not the user's). They likely store the monogram config in
  `ZAVATARRECIPEDATA` rather than as a bitmap. We currently render the
  fallback initials for these — no parse, no display.
- **Multi-Source merging**: if a user has both iCloud and "On My Mac"
  Sources, the same contact may appear in both. The existing resolver
  merges by display name; we'll just use whichever Source's avatar we
  encounter first. Visually fine — they're usually the same photo.
- **Tahoe sticker-style avatars**: macOS 26 introduced emoji/sticker
  avatars. The byte format is the same (inline JPEG or external
  reference); they look slightly different (transparent backgrounds via
  PNG with alpha) but display as expected through `NSImage(data:)`.
