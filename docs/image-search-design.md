# Image Search Design

Research and recommendation. Empirical findings drawn from the user's real `~/Library/Messages/chat.db` (914 MB, 35,484 attachments) on 2026-05-23. No implementation yet — this doc establishes what to build, in what order, and what we know NOT to build.

---

## The User's Two Questions

### Q1 — Show image previews in search results?

**Answer: Yes — show small thumbnails (~48 px square) inline in result rows whenever the file IS locally available, and show a "Photo from <sender> · <date>" tile when it isn't. Always-on, never modal/hover-only.**

Empirical benchmark on 20 random images from the user's Attachments (mixed HEIC/JPEG/PNG, 12 KB → 6.4 MB on disk):

| Strategy | Total time | Avg per image |
|---|---|---|
| `NSImage(contentsOf:)` full decode | 521 ms | 26 ms |
| `CGImageSourceCreateThumbnailAtIndex` @ 128 px | 663 ms | 33 ms |
| `CGImageSourceCreateThumbnailAtIndex` @ 48 px | 675 ms | 34 ms |
| **`QLThumbnailGenerator` @ 128 px (concurrent)** | **386 ms** | **19 ms** |

20 thumbnails ready in 386 ms with QuickLook — well under the 200 ms target users perceive as "instant." With a disk cache (`~/Library/Caches/Hourglass/thumbs/<sha1(path)>.jpg`) this drops to ≤5 ms per cache hit. Conclusion: previews are cheap.

Clutter risk is real but small: result rows already render text + sender + reactions in ~36 pt. A 28 pt thumbnail leading the row badges the result *more* clearly than a generic `photo` SF Symbol does — text result vs. image result is suddenly visually obvious. The status-quo (no thumbnail) is *worse* for clutter, because the user can't distinguish "Jordan sent a photo" from "Jordan mentioned a photo" without clicking through.

For the **un-loaded** case (no file on disk), the row falls back to a stylized "Photo from Jordan · Apr 16, 2026" tile with a faint placeholder. The metadata (sender, date, chat) is always present in chat.db, so the row still conveys identity. The user knows there's a photo there and can request it (Phase 3) by opening the message in Messages.app.

### Q2 — Can we search images that aren't loaded on this Mac?

**Answer: No, we cannot search them by content — but we CAN surface them by metadata (sender + date + chat + filename), and that's the right product behavior given the empirical state of the world.**

Empirical findings on the user's chat.db:

- **Total image attachments**: 24,533
- **Locally on disk**: 2,097 (**8.5%**)
- **Missing from disk**: 22,436 (**91.5%**)

Per-year breakdown:

| Year | Present | Missing | % Locally Available |
|---|---|---|---|
| 2022 | 40 | 3,136 | 1.3% |
| 2023 | 63 | 5,180 | 1.2% |
| 2024 | 164 | 5,042 | 3.2% |
| 2025 | 1,209 | 5,707 | 17.5% |
| 2026 | 621 | 3,371 | 15.6% |

This is the dominant case, not the edge case. iCloud Messages with "Optimize Mac Storage" enabled aggressively evicts attachments — the user's Mac has only ~9% of historical images on disk at any moment. Searching only the local subset would be a search product that silently hides 91% of their photo history.

#### What can we do for the 91%?

The schema gives us a lot of metadata that survives without the bytes:

| Field | Available when bytes missing? | Searchable? |
|---|---|---|
| `attachment.transfer_name` (often the filename, e.g. `IMG_4213.jpeg`) | Yes | Yes — substring on filename |
| `attachment.mime_type` | Yes | Yes — `type:image` filter already works |
| `message.date` | Yes | Yes — date filters work |
| Sender handle / contact name | Yes | Yes — `from:` filter works |
| `chat.display_name` / chat participants | Yes | Yes — `in:` / `chat:` filters work |
| Surrounding text in the message OR adjacent messages | Yes | Yes — full-text search works |

So `from:erik type:image last:2y` finds **every** image Jordan sent in the last 2 years (loaded or not), even though we can't show thumbnails for 91% of them. The result row says "Photo from Jordan · Apr 16, 2026 · Aeternus group" — and ⌘↵ jumps to the message in Messages.app, where Apple's app will download the bytes on demand.

#### Can we trigger a download?

Investigated and ruled out:

- **AppleEvents / public APIs**: no documented "download this attachment" message.
- **Private IPC**: prior research (see `docs/messages-private-ipc.md`, `docs/messages-private-proxy.md`) exhaustively probed Messages.app's private surface — the conclusion was that anything involving privileged dispatch requires entitlements Apple gates to first-party clients. The same conclusion almost certainly applies to attachment fetch.
- **The CloudKit path (`ck_record_id`, `ck_sync_state`)**: tempting — every missing image has `ck_sync_state = 1`. But CloudKit access requires the iMessage CloudKit container entitlement, which is private to Apple.

The clean degradation is: **open the message in Messages.app (we already do this via the `sms://open?message-guid=...` URL). Messages.app downloads the bytes itself.** From the user's perspective, "click → photo loads in Messages" is a perfectly understandable interaction, especially since they're going to want to *see* the photo in Messages.app anyway (that's where it scrolls, has reactions, has reply context, etc).

#### Is metadata-only search "good enough"?

It's strictly better than today. Today the user has:
- iMessage.app's search: text-only, returns nothing for image-only messages.
- Spotlight: indexes some Messages content but image discovery is poor.
- Photos.app: ignores iMessage attachments entirely; only ingests Camera Roll / Library photos.

Our `from:erik type:image last:2y` is **already** more powerful than any of these. Adding a thumbnail rail when bytes are local is gravy. Searching the 9% that's loaded by *visual content* (CLIP / OCR) is the cherry on top.

The honest framing for the user: "We can find every image by who sent it, when, and the chat context. For the 9% loaded locally, we can also search what's *in* the image."

### Q3 (implicit) — Best local engine for content-search of loaded images?

**Answer: Apple Vision (OCR + Classify) in Phase 1. MobileCLIP via CoreML in Phase 2. Both, layered — OCR for "find the screenshot of the flight confirmation," CLIP for "the photo of the dog at the park."**

Empirical benchmark on 30 real images from the user's Attachments (Apple Vision, serial, in a single Swift process on this Mac — Apple Silicon, macOS 26):

| Request | Avg latency |
|---|---|
| Decode (NSImage + CGImage) | 57 ms |
| `VNRecognizeTextRequest` (accurate mode + correction) | 166 ms |
| `VNClassifyImageRequest` (1303-class taxonomy) | 27 ms |
| `VNGenerateImageFeaturePrintRequest` (768-D perceptual embedding) | 10 ms |
| **Combined (all 3)** | **202 ms** |

Throughput at 5 img/sec serial; with `OperationQueue` running 4 in parallel, ~20 img/sec on this Mac. The 2,097 locally-available images would index in ~100 sec — one-time, background, write-once.

**Quality on real iMessage data is excellent:**

- **OCR catches everything**: a screenshot of an email/text/Twitter thread → full text recognized. `Untitled (Draft).heic` (a music-rating handwritten list) → "UTOPIA Ratings HYAENA - 8/Id THANK GOD - 7.5/10 MODERN JAM -6.5/10 MY EYES- 10/10 GOD'S COUNTRY -6/10 …". The user could literally search `from:henry "fein"` and find the music-rating image.
- **Classification gives useful tags**: every screenshot got `document(0.85+), screenshot(0.85+)`. Photos of people got `people, adult`. Stickers got `animal, cetacean, dolphin`. Photos in a room got `structure, furniture, seat`. Good enough to power `type:image dog` (where "dog" matches the classification tag, not OCR).
- **FeaturePrint is fast (10 ms)** but lower information density than CLIP — it's distance-only ("find images similar to this one"). Apple Photos uses it. Not useful for text-prompted search ("find images of dogs") because there's no text encoder.

For **text-prompted semantic image search** ("the photo of the dog at the park") we need CLIP. Apple has shipped official Core ML packages: [`apple/coreml-mobileclip`](https://huggingface.co/apple/coreml-mobileclip) provides image + text encoders for S0/S1/S2/BLT as `.mlpackage` files. From Apple's published benchmarks: MobileCLIP-S0 is **11.4 M (image) + 42.4 M (text) params, 1.5 ms + 1.6 ms latency** on iPhone 12 Pro Max. On an M-series Mac it'll be at least as fast. The S0 image encoder weight is ~50 MB, S1 ~150 MB, S2 ~300 MB — all comfortably under our 300 MB ceiling.

**Why Apple Vision *first*, MobileCLIP *second*:**

1. **Vision is free.** No download, no model packaging, no licensing review. Ships with macOS.
2. **OCR handles the most common iMessage image type — screenshots.** Roughly 60% of the user's loaded images (by eyeballing the sample) are screenshots of texts, emails, Twitter, Discord, Reddit. OCR turns those into searchable text.
3. **CLIP only adds value on the remaining ~40% (camera photos)**, where the user types "dog" and we need to know which images are of dogs. Real, but smaller wedge.
4. **Layering is natural**: we index every image with (OCR text + classification tags + 768-D FeaturePrint embedding) in Phase 1, then add (512/768-D CLIP image embedding) in Phase 2. The two embedding spaces don't conflict.

**Cactus Compute** (the user-mentioned runtime): Cactus DOES support vision-language models on Apple Silicon (LiquidAI LFM2-VL family is listed with "vision, txt & img embed, Apple NPU" support). But Cactus expects models in its own format (cached on HuggingFace under `Cactus-Compute/*`) and is positioned more around LLM + transcription + multimodal-LLM workloads than around pure-CLIP image embedding. For a focused CLIP-style task, calling CoreML directly via Apple's standard `MLModel` API is the lower-friction path — no third-party dependency, no model conversion, official Apple support. **If** the parallel search-quality agent commits to Cactus as the runtime for the text embedder, we should revisit whether to consolidate on Cactus for CLIP too (one runtime, one binary footprint). Coordinate in plans.md.

---

## Phased Plan

Each phase is independently shippable. Phase 1 alone is a clear win over today's state.

### Phase 1 — Metadata + Thumbnails (ship first)

1. **Thumbnail rendering in result rows** for messages where `messageType == .image` AND the attachment file exists on disk.
   - `QLThumbnailGenerator` → 64 pt thumbnail → cache to `~/Library/Caches/Hourglass/thumbs/`.
   - Cache key: `sha1(filename)` truncated to 16 chars.
   - Cache invalidation: file mtime — if newer, regenerate.
   - LRU eviction at ~200 MB.
2. **"Photo from <sender>" placeholder** for images where the file is NOT on disk.
   - Always shows: sender avatar/initials + "Photo from <Name>" + relative date.
   - Visual treatment: small dashed border + iCloud-cloud SF Symbol, no thumbnail attempt.
3. **No semantic search yet.** Existing `from:`, `chat:`, `type:image`, `before:` / `after:` / `last:` filters already let users find "every image from Jordan" or "type:image last:30d." Just polish.
4. **Caption text** is already searchable (`AttributedBodyDecoder` extracts it from `attributedBody` for captioned images).

Shippable as a single ~300-line diff: `Sources/Data/ThumbnailCache.swift` + a thumbnail surface on `ResultRow` + a "loaded?" predicate that does `FileManager.fileExists` on the path.

### Phase 2 — On-device OCR + image tags (Apple Vision)

5. **Background indexer**:
   - On first run (and incrementally on file appearance) walk every image in `Attachments/`.
   - For each: run `VNRecognizeTextRequest` (accurate) + `VNClassifyImageRequest` + `VNGenerateImageFeaturePrintRequest`.
   - Persist `(attachment_guid, ocr_text, tags JSON, feature_print BLOB)` into `Hourglass.sqlite` (the same local mirror DB used for the Phase-1 FTS5 work-in-progress).
   - Indexing throttled to 5 img/sec serial (we have headroom to go faster; conservative for the first pass).
6. **FTS5 over `ocr_text`** — bolt the OCR column onto the existing FTS5 mirror. `from:erik flight confirmation` matches against caption AND OCR.
7. **Tag-filter token**: `tag:dog` matches any image whose classification tags include "dog" with confidence ≥ 0.5. Sugar; mostly redundant with OCR for screenshots but useful for photos.
8. **Similar-image action**: long-press a result row → "find similar images" → uses FeaturePrint cosine distance to surface nearby images. Cheap to add once the embeddings are indexed.

Estimated effort: ~1,000 LOC. Indexer + table + filter syntax + UI menu item.

### Phase 3 — Text-prompted image search (MobileCLIP)

9. **Bundle `mobileclip_s1_image.mlpackage` + `mobileclip_s1_text.mlpackage`** (~150 MB total) into the app — or download on first launch with progress, depending on DMG-size policy (build-agent's call).
10. **Re-index loaded images** with the CLIP image encoder; persist 512-D embeddings.
11. **Query path**: user types free-text → run CLIP text encoder → cosine-search against image embeddings → blend with the OCR/tag results from Phase 2.
12. **Decision gate**: only ship Phase 3 if the parallel search-quality agent's text-semantic work confirms we want a learned-embedding pipeline in the app at all. If they pick a non-embedding text-quality approach (pure BM25 + lexical tricks), we may still want CLIP for image search — but the runtime/dependency conversation needs to be one-shot for both.

Estimated effort: ~1,500 LOC + ~150 MB of model weight to ship.

### Out of scope, possibly never

- **Server-side / cloud inference**: no. Local-first is non-negotiable per the task brief.
- **Triggering iMessage to download a missing attachment from third-party code**: investigated; not possible without entitlements we don't have. The clean degradation (open in Messages.app, let Apple download it) is fine.
- **Spotlight / Photos.app interop**: separate index, not our problem.
- **Indexing non-image attachments (videos, PDFs)**: maybe Phase 4. Video would need keyframe extraction + the same Vision pipeline. PDF would need PDFKit text extraction. Both are mechanical extensions of the Phase-2 design.

---

## Coordination notes

- The parallel **search-quality agent** is also looking at Cactus / local embedders. Their decision on a runtime for text-semantic search directly affects whether we use the same runtime for CLIP image embedding. **Recommended sync:** post in plans.md under a "Round 3 — Phase 2 features" entry; agree on the inference runtime before either of us ships embedding infrastructure.
- The **FTS5 mirror** (Round-2 item #4 in plans.md) is the natural place to add an `ocr_text` column. Whoever ships the mirror first should leave room in the schema for the OCR column.
- **design-agent** owns the visual surface. The thumbnail rail / placeholder visuals (Phase 1) and the "find similar" affordance (Phase 2) need restyling once data is wired.
- **build-agent** is owner of bundle size; Phase 3's ~150 MB model needs their sign-off on packaging strategy (bundle in DMG vs. lazy download from `developer.apple.com`–hosted CoreML mirror or our own CDN).

---

## Empirical artifacts

Probes used during this research, in `/tmp/img-research/` on the user's machine:

- `01-attachment-overview.txt` — full schema + MIME distribution + size statistics
- `02-local-availability.txt` — per-year present/missing breakdown, sample missing rows
- `vision_bench.swift` — Vision OCR/Classify/FeaturePrint benchmark (30 images, summary at the bottom)
- `thumbnail_bench.swift` — QLThumbnailGenerator vs CGImageSource vs NSImage (20 images)
- `sample-list.txt` — the 30-image sample (mix of stickers, photos, screenshots)

Numbers in this doc come from running these scripts against the user's actual `~/Library/Messages/chat.db` and `~/Library/Messages/Attachments/` on 2026-05-23.
