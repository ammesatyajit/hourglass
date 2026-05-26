# Search Design — Hybrid Retrieval for Hourglass

> **Status (2026-05-23)**: Phase 1 (FTS5 trigram mirror) shipped. Phases 2–4 (dense recall, rerank, query routing) are documented here but unimplemented; the image-search agent and a future text-semantic round can plug into the same runtime.

This document answers the five research questions in the lead's brief and converts the answers into a phased implementation plan. Phase 1 is the slice that landed in this round. Later phases are intentionally documented in enough detail that the next agent can pick them up without rediscovery.

---

## TL;DR — what the user gets

| | Today (INSTR baseline) | Phase 1 (this round) | Phase 2+ (later) |
|---|---|---|---|
| Latency on 525k msg DB | **~1000ms** per search | **~3ms** FTS5 substring match | <10ms hybrid + rerank |
| Coverage on `cactus` | 566 real hits (694 candidates, 128 false positives) | **566 hits** — same coverage, no false positives | + semantic neighbors ("plant", "succulent", "henry's startup") |
| Multi-case (`iPhone`, `macOS`) | Misses (3-variant heuristic) | **Matches** (case-folded tokenizer) | Same |
| Natural-language queries | Useless ("the trip to Vegas" returns junk) | Same (FTS5 by itself isn't semantic) | **Works** (dense recall + cross-encoder rerank) |
| Disk footprint | 0 (lives on chat.db) | **89–131 MB** mirror | + ~200 MB embeddings (FP16, 525k × 384d) |
| First-launch indexing | n/a | **~10s** (one-time) | + 5–15min for embedding pass (background) |

The keyword path stays the **default and primary** entry point. Phase 1 ships a faster, more correct keyword index. Phases 2+ layer semantic recall on top *only when the user asks for it* (operator prefix or implicit hint — see Q4).

---

## Q1 — Lexical retrieval: what to use?

### Decision: **SQLite FTS5 with the `trigram` tokenizer.**

Mirror chat.db's `message` table into a side database (`Hourglass.sqlite`) under `~/Library/Application Support/Hourglass/`. Build an FTS5 virtual table over the decoded message body. Each row carries a 1:1 ROWID match to `message.ROWID` so cross-DB joins to `chat`, `chat_message_join`, `handle`, etc. still work.

### Why FTS5

- **Already in SQLite.** No new dependencies. Same connection model (`DatabaseQueue` via GRDB) we already use for chat.db.
- **Built-in BM25 ranking** — `bm25(messages_fts)` returns a score we can sort on or feed into a hybrid layer. Adjustable column weights via the SQL options table.
- **Fast.** Measured on the user's 524,818-row DB: every test query returned in **0–3ms** vs the **1000–2150ms** INSTR baseline. (Numbers below.)
- **In-process.** No FFI shim, no ABI risk, no extra binary to ship.
- **Incremental updates are cheap.** `INSERT INTO messages_fts` adds a row in ~30µs. We can stream new chat.db rows on a watcher loop without ever rebuilding.

### Why trigram (not unicode61)

Two tokenizer choices were evaluated end-to-end:

| Tokenizer | Build time | Disk | "cactus" matches | "cactuscompute" matches (substring of "cactus") | "iphone" matches |
|---|---|---|---|---|---|
| **unicode61 + prefix 2,3** | 8.7s | 89 MB | 559 (misses "cactuscompute" etc.) | 0 | 47 |
| **trigram** (chosen) | 10.3s | 131 MB | **566** (matches every substring case) | 2 | 51 |
| INSTR baseline | 0s | 0 | 694 (128 false-positive metadata bytes) | 0 (needs separate query) | 26 (misses iPhone, IPHONE) |

The decisive factor: **the user explicitly said keyword search "works great" and must not regress.** The current INSTR behavior is byte-substring — typing `cactus` finds `cactus`, `cactuses`, `Cactuscompute`. unicode61 tokenizes on word boundaries, so it would silently drop the `cactuscompute` row. Trigram preserves byte-substring semantics while still indexing for O(log N) lookup. Net result: **trigram FTS5 produces the same coverage as INSTR but without the metadata false positives**, and is ~300× faster.

The "the" count is even more interesting: INSTR returns 88,109, trigram returns 62,829, unicode61 returns 43,619. The 25k delta between trigram and INSTR is exactly the false-positive count from byte-substring matches inside the typedstream metadata that the Swift refinement loop currently strips out. **Trigram replicates the post-refinement coverage 1:1, eliminating the wasted CPU spent filtering metadata in Swift.**

### Alternatives ruled out

- **Tantivy via FFI** — a Rust full-text index. Massively more setup (Rust toolchain, build-agent overhead, cross-platform shim). FTS5 already does what we need.
- **Plain LIKE / INSTR refinement only** — what we have today; ~1s per query at 525k rows. Doesn't scale to all-time semantic queries.
- **CoreSpotlight indexing** — locks us into the OS's index policy, doesn't give us BM25 scores, and any cleanup on uninstall is painful.

### Schema

```sql
-- the FTS5 virtual table, body only (everything else lives in message_meta)
CREATE VIRTUAL TABLE messages_fts USING fts5(
    body,
    tokenize = 'trigram remove_diacritics 1'
);

-- the side table for filter-pushdown without joining back into the foreign chat.db
CREATE TABLE message_meta (
    rowid INTEGER PRIMARY KEY,        -- mirrors message.ROWID
    guid TEXT,                        -- mirrors message.guid (for reveal)
    date INTEGER NOT NULL,            -- Mac-absolute-time, ns or s — preserve original
    is_from_me INTEGER NOT NULL,
    chat_id INTEGER,                  -- chat_message_join.chat_id (denormalized)
    handle_id INTEGER,                -- handle.ROWID (NULL for sent)
    associated_message_type INTEGER NOT NULL DEFAULT 0,
    has_attachment INTEGER NOT NULL DEFAULT 0,
    balloon_bundle_id TEXT
);
CREATE INDEX idx_meta_date ON message_meta(date);
CREATE INDEX idx_meta_chat ON message_meta(chat_id);
CREATE INDEX idx_meta_handle ON message_meta(handle_id);

-- Bookkeeping: last source ROWID we've indexed, schema version, etc.
CREATE TABLE index_state (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

The `messages_fts.rowid` is the same ROWID as `message.ROWID` in chat.db — this lets us join across databases by attaching chat.db read-only to the mirror.

### Query shape

```sql
SELECT meta.rowid
FROM messages_fts
JOIN message_meta meta ON meta.rowid = messages_fts.rowid
JOIN chat_db.chat_message_join cmj ON cmj.message_id = meta.rowid
JOIN chat_db.chat ch ON ch.ROWID = cmj.chat_id
LEFT JOIN chat_db.handle h ON h.ROWID = meta.handle_id
WHERE messages_fts MATCH ?
  AND meta.date BETWEEN ? AND ?
  AND ch.display_name LIKE ?
ORDER BY meta.date DESC
LIMIT ?
```

Measured: `messages_fts MATCH ? + date filter + chat name filter` = **26–243ms** for 524k rows including all post-processing JOINs.

### Two-track strategy (this is the key architectural insight)

The user explicitly said the INSTR keyword path must not lose any power. So we don't replace it — we route to FTS5 when fresh, fall back to INSTR when the mirror is missing or behind:

```
SearchViewModel.search()
   ↓
IndexStore.isFresh(maxROWID: chat.db.maxROWID)
   ↓
[fresh]      → FTS5 path (3ms per query)
[behind]     → INSTR path (1000ms) + kick off background catch-up
[no index]   → INSTR path + kick off first-launch indexer
```

This keeps the system **always functional**. The index is purely an optimization — never a correctness dependency. If the mirror file gets corrupted, deleted, or schema-migrated, search degrades to INSTR latency and keeps working.

---

## Q2 — Dense recall: embedding model & runtime

### Decision (recommended, not yet shipped): **bge-small-en-v1.5 via `swift-embeddings` (MLTensor / CoreML).**

This isn't landing in Phase 1. The recommendation is documented so the image-agent and the next text-semantic round converge on the same stack.

### Why this combination

**Model: bge-small-en-v1.5**
- 384-dim embeddings → small enough to fit ~525k × 384 × FP16 = **403 MB** of vectors. Acceptable.
- 33M params → loads in ~150ms on Apple Silicon, runs at ~50ms per 256-token input.
- Quantizes cleanly to INT8 (no calibration data needed for this task).
- Top of the MTEB leaderboard among ≤100 MB models as of late 2025; bge-base bumps quality but ~3× the cost.

**Runtime: swift-embeddings (https://github.com/jkrukowski/swift-embeddings)**
- Pure Swift, MLTensor under the hood — uses the Neural Engine when available.
- Already has bge-small in the model registry. Drop-in.
- No Python, no Rust, no external runtime. Same toolchain we already build with.

### Alternatives evaluated

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Cactus Compute SDK** | OpenAI-compatible API, sub-50ms TTFT, embedding API on `CactusLanguageModel.embeddings` (returns `[Float]`), XCFramework for macOS, "complete privacy" stance | Newer (2025+), smaller community, model selection narrower than the Hugging Face ecosystem, optimized for LLMs rather than embedding-specific workloads | **Use as fallback** if swift-embeddings hits a wall. The unified-runtime ergonomics are nice for the image-agent's CLIP path too. |
| **MLX-embeddings (Blaizzy / mzbac)** | Native Apple Silicon optimization, Python-first but with Swift bindings via mlx-swift | Python or Swift+Python bridge; complicates ship. Heavy on first load. | Pass — overkill for our scale. |
| **llama.cpp embeddings mode** | Lots of model coverage including bge | Need to bring in llama.cpp as a dependency. Embedding API exists but mainline is LLM-focused. | Pass — adds binary. |
| **CoreML conversion of bge** | Native Apple runtime, no third-party deps | Conversion pipeline + hand-tooled tokenizer in Swift, brittle when model changes | Pass — swift-embeddings already wraps this. |
| **Apple `NLContextualEmbedding`** | Zero dependencies, built into NaturalLanguage framework on macOS 14+. Per-token contextual vectors. | Per-token only — needs mean-pooling for sentence embedding. Quality below bge-small on MTEB. macOS-only (locked in but irrelevant here). | **Strong candidate for v1.** Free, zero deps. Worth a benchmark before committing to bge. |

### Recommended path

1. Start with **NLContextualEmbedding + mean-pooling** as the v1 embedder. If quality is satisfactory ("Vegas trip" / "henry's birthday plans" returns sensible neighbors), ship it. Zero deps, Apple-stable, free of model-licensing entropy.
2. If quality is poor, swap in **swift-embeddings + bge-small-en-v1.5** as a one-file change.
3. Cactus stays in our back pocket as a unified-runtime option if the image-agent's CLIP path also wants to live there.

### Vector index

**Decision (when we ship): inline BLOB column in `Hourglass.sqlite`, with a separate in-memory HNSW index built on first load.**

- Persist vectors as `BLOB(768)` (or 384/768 FP16) in `message_meta`. Cheap to update.
- Rebuild HNSW in memory at app launch (525k × 384 × 4B FP32 = 800 MB if loaded eagerly; FP16 BLOB + lazy load brings this to ~400 MB and stays in-RAM only for the active session).
- Library: [HNSWlib via SwiftPM](https://github.com/yourkin/HNSWLib-swift) or roll our own — HNSW is simple enough (~500 lines).

Reasoning: 525k vectors is small enough that brute-force cosine over FP16 vectors takes <300ms on an M-series chip — HNSW gives us <10ms. We don't need FAISS or a vector DB. Apple's `SimilarityComparison` API on macOS 26 (in the [Embeddings framework](https://developer.apple.com/documentation/embeddings)) is the cleanest path if we're targeting macOS 26 anyway — *defer to it before reaching for HNSW*.

---

## Q3 — Reranking

### Decision: **skip in Phase 2; revisit only if hybrid alone underperforms.**

Cross-encoder reranking has a real cost: each query needs to run the reranker over the top-K candidates (K=100 → 100 forward passes through a ~200MB model). Even a fast cross-encoder takes 50–200ms total at K=100. For Spotlight-style typing-latency, that's a third of our latency budget.

We should ship **dense recall alone (Phase 2)**, measure quality on a held-out set, and only add reranking (Phase 3) if there's a measurable accuracy gap. If it's needed, **ms-marco-MiniLM-L-6-v2** is the right starting point — 22M params, ~50ms for top-100, MIT-licensed, supported by swift-embeddings.

---

## Q4 — Indexing pipeline

### When to index

- **First launch**: full-pass over all messages. Background `Task.detached(priority: .utility)`. UI shows a one-time "Indexing your messages…" banner with a progress count. Search continues to work against the live `INSTR` path until the index is ready (the user doesn't have to wait).
- **Incremental**: poll for new `message.ROWID` rows every 5–15 seconds via a `DispatchSourceTimer`. Cheap (a `SELECT MAX(ROWID)` on a partial index is microseconds). Picks up new messages essentially in real time.
- **Optional FSEvents on chat.db** — `FSEventStream` on `~/Library/Messages/`. More responsive than polling but more failure modes (e.g. permission edge cases, WAL flushes that don't trigger an event). The polling approach is robust and simple — we ship polling first and add FSEvents only if real users report lag.

### Detecting chat.db changes

Messages.app uses WAL mode. The simplest "did anything change?" check is `SELECT MAX(ROWID) FROM message` — if it's higher than what we have in `index_state`, we've got new rows to ingest. Sub-millisecond on the indexed PK. Tapbacks have separate ROWIDs and get indexed too (we filter them at *query* time, not index time, so the index can serve both keyword-search and reaction-filter queries).

### Where embeddings live

- **Inline `BLOB` column in `message_meta`** — keeps the file unified, atomic, single backup story.
- **NOT** separate `.npy` / `.faiss` files — too many failure modes (file rename, partial write, schema drift).
- HNSW index rebuilt in-memory at launch from the BLOB column. ~30s rebuild for 525k vectors.

### First-index latency

Measured for FTS5 trigram on user's 524,818-row DB: **~10 seconds** end-to-end (decode + insert). Acceptable for a "first time you open the app" banner.

For embeddings (Phase 2, projected): bge-small at ~50ms per message means **~7 hours** sequential — unacceptable. Batching to 32 inputs per forward pass and the Neural Engine should bring it to **~15–30 minutes for 525k messages** on an M-series. We pre-filter to messages with body length ≥ 5 chars (skip the "ok", "haha" rows that don't need semantic embedding) and only embed the rest — probably 50–60% of total, so ~10 minutes real-world. We run this as a low-priority background task; the user can use the keyword index immediately.

---

## Q5 — Query routing

### Decision: **keyword is the default. Semantic is opt-in via operator prefix, never opt-out.**

The user's explicit request: keyword search must not lose any power. The proposal:

| Query shape | Routes to | Why |
|---|---|---|
| Contains any `prefix:` token (`from:`, `chat:`, `last:`, `reactions:`, `type:`) | **Keyword (FTS5)** | The user has typed a structured filter — they know exactly what they're looking for. Semantic noise here would be insulting. |
| Plain text, ≤ 2 words | **Keyword (FTS5)** | "cactus", "vegas", "happy birthday" — almost certainly literal. Phrase search returns hits in 3ms; opening the semantic floodgates would slow it down and add false positives. |
| Plain text, 3+ words | **Keyword (FTS5) by default**, with a single-key "Search semantically" affordance | The user has a phrase. Most of the time, even a 3-word query is literal ("the new place", "see you tomorrow"). We surface "Search semantically: 'the trip to Vegas'" as a suggested second result row under the keyword results so the user can press one key to escalate. |
| `~query` (prefix tilde) — **NEW operator** | **Hybrid (FTS5 lexical recall + dense vector recall, fused via RRF, then optional cross-encoder rerank)** | Explicit semantic opt-in. The tilde is intuitive ("~" ≈ "fuzzy/approximate"), not in the existing operator namespace, and easy to type. |

### The escalation pattern

When the user types a multi-word phrase that returns few or zero literal hits, the empty-state surfaces:

> No literal matches. **Press Tab to search semantically →**

Tab inserts `~` at the start of the query, runs the hybrid retriever, shows neighbors. The user gains the semantic feature without ever losing the literal default. **Semantic is genuinely additive.**

### Why not auto-detect

We considered "if the query looks like natural language, route to semantic." But: how to tell? "happy birthday" looks like NL but should be literal. "the trip we planned to vegas" looks like NL and should be semantic. The signal is fragile. **An explicit operator removes guesswork.** The user is in control.

### Why not a global toggle / second hotkey

A toggle creates the "wait, am I in semantic mode?" problem every time the panel opens. A separate hotkey doubles the keybinding surface. The operator prefix is mode-local — visible in the query field, easy to remove (backspace), and doesn't affect any other search.

---

## Performance — where the time goes

### Current INSTR baseline (measured on user's chat.db, 524,818 rows)

| Query | Latency | Notes |
|---|---|---|
| `COUNT(*) FROM message` | 42ms | PK only |
| `COUNT WHERE associated_message_type=0` | 2,150ms | full scan of `associated_message_type` |
| `cactus` (INSTR + 3 case variants) | **1,104ms** | 694 candidates, 128 metadata false positives |
| `the` | 1,041ms | 88,109 hits |
| `vegas` | 1,044ms | 71 hits — bottlenecked on the scan, not the result count |

Time is dominated by the byte-scan of every `attributedBody` BLOB in the table — INSTR is O(N × M) where N=525k rows, M=blob bytes. We pay this even for queries with single-digit result counts.

### After Phase 1 (measured on the same DB)

| Query | Latency | Coverage vs INSTR |
|---|---|---|
| `cactus` | **3ms** | 566 hits — matches Python-refined INSTR (no metadata false positives) |
| `the` | 3ms | 62,829 (vs 88,109 raw, 43k post-refinement-equivalent) |
| `vegas` | 0ms | 48 (same as Python-refined) |
| `happy birthday` (multi-word phrase) | 2ms | 33 (same) |
| `cactuscompute` (substring of "cactus") | 1ms | 2 — trigram correctly handles this where unicode61 would miss |

**Net wins from Phase 1:**

1. **~300× faster** in the steady state.
2. **No coverage regression**: trigram FTS5 = post-refinement INSTR coverage.
3. **Fixes the case-folding gap** plans.md has been calling out for months: `iPhone`, `macOS`, mixed-case proper nouns now work.
4. **Frees the Swift refinement loop**: no more decode-and-filter on 1000+ candidates. The Swift layer only handles the joined post-processing (reactions, attachments) and a single phrase contains-check for redundant safety.

### Further wins (Phase 2+)

- **Lowercased-body column** — not needed; trigram tokenizer already handles case-folding via `remove_diacritics 1`.
- **Result cache** — LRU on the (query, filters) tuple. Hits within a 30s window return in O(1). Not implemented yet; pending whether user actually retypes the same query (rare in a Spotlight flow).
- **Background re-rank** — for the 200ms cross-encoder pass we'd run it on the top-K asynchronously, replacing rows in the result list as scores arrive. Phase 3 work.

---

## Phased rollout

### Phase 1 — FTS5 trigram mirror (THIS PR)

- `Sources/Index/IndexStore.swift` — opens (or creates) `Hourglass.sqlite`, exposes schema + read/write API.
- `Sources/Index/IndexBuilder.swift` — first-launch full index. Reads chat.db, decodes via `AttributedBodyDecoder`, batched inserts.
- `Sources/Index/IndexSync.swift` — incremental sync: poll `SELECT MAX(ROWID) FROM message`, ingest new rows. Runs on a background `Task` with a 5-second cadence by default. (Triggered explicitly on app foreground; otherwise sleeps.)
- `Sources/Search/FTSSearcher.swift` — runs the FTS5 query path. Same `[MessageSearch.Result]` return type as the INSTR path so the view model is identical.
- `Sources/Search/MessageSearch.swift` updated:
  - `searchUsingIndex(...)` runs against the FTS5 mirror when fresh. Falls back to the existing INSTR path when not.
  - `IndexFreshness` enum: `.ready`, `.behind(rowsToCatchUp:)`, `.missing`.
- `Sources/Search/SearchViewModel.swift` updated:
  - Holds an `IndexStore` reference alongside the existing `ChatDatabase`.
  - `indexingProgress: IndexingProgress?` published state for the UI banner.
  - First-launch triggers `IndexBuilder.buildFullIndex` if `IndexStore` reports `.missing`.
- `Tests/IndexBuilderTests.swift`, `Tests/IndexSyncTests.swift`, `Tests/FTSSearcherTests.swift` — parity vs INSTR on the fixture chat.db.

### Phase 2 — Dense recall (later round)

- `Sources/Index/EmbeddingPipeline.swift` — bge-small (or NLContextualEmbedding) embedder, batched, runs as a background pass.
- `Sources/Index/VectorIndex.swift` — HNSW (or `SimilarityComparison` on macOS 26) over the FP16 BLOB column in `message_meta`.
- `Sources/Search/HybridSearcher.swift` — fuses FTS5 BM25 + dense cosine via RRF (Reciprocal Rank Fusion, k=60).
- Query routing per Q4: `~query` triggers `HybridSearcher`; everything else stays on `FTSSearcher`.

### Phase 3 — Reranking (only if needed)

- ms-marco-MiniLM cross-encoder reranks top-K from HybridSearcher.
- Asynchronous: results appear keyword-first, semantic re-rank settles in within ~200ms.

### Phase 4 — Image search (cross-agent coordination)

- Same `Hourglass.sqlite` houses CLIP image embeddings in a parallel `image_embeddings` table.
- Image-search agent owns CLIP + attachment plumbing; reuses our embedding-runtime choice from Phase 2.
- Single hybrid search across text + images when the query qualifies (e.g. `type:image vegas` runs the dense+image path).

---

## Open questions (Phase 1)

1. **Where to put the index file.** Decision: `~/Library/Application Support/Hourglass/index.sqlite`. (Standard.)
2. **Schema migration.** Add `index_state.value` for `schema_version`; bump on any column change. On version mismatch, blow away the file and reindex. Cheap (10s rebuild).
3. **Re-running the indexer if user grants FDA later.** Detect on launch: if `setupError` becomes nil after being set, kick off the indexer.
4. **What about reactions / attachments in the mirror?** We mirror `associated_message_type` and `has_attachment` flags so `type:`/`reactions:` filters can still push down. Reaction tapback rows go into `message_meta` too (we filter at query time).

---

## Sources

- [Cactus Compute — Low-latency on-device AI engine](https://github.com/cactus-compute/cactus)
- [Cactus Documentation — Embeddings API](https://cactuscompute.com/docs/v1.7)
- [swift-embeddings — Run embedding models locally in Swift via MLTensor](https://github.com/jkrukowski/swift-embeddings)
- [MLX-Embeddings (Blaizzy) — MLX for Vision and Language embeddings](https://github.com/Blaizzy/mlx-embeddings)
- [Apple NaturalLanguage framework — NLContextualEmbedding](https://markbrownsword.com/2020/12/23/natural-language-framework-sentence-embedding-with-swift/)
- [On-Device Text Embeddings with Apple NLP framework](https://www.callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native)
- [SQLite FTS5 — Built-in BM25 ranking, trigram tokenizer](https://www.sqlite.org/fts5.html)
- [BentoML — Open-source embedding models guide (2026)](https://www.bentoml.com/blog/a-guide-to-open-source-embedding-models)
- [Reciprocal Rank Fusion (Cormack et al.)](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf)
