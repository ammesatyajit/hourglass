# NL Search Bar — Design & Prototype

> **Status (2026-05-23)**: Research + Phase 1 scaffold. Stub LLM runtime ships in this round; concrete `MLXRuntime` lift is documented below and ready for the next round to drop in.

A natural-language **second** search surface for Hourglass — distinct from the keyword Spotlight panel. The canonical query is "find my argument with Avery that happened around 2 weeks ago". The user types a vague NL description; an agentic loop parses it into a structured plan, runs one or more tool calls against the existing `MessageSearch` / `FTSSearcher` engines, and surfaces a single focused result with a transparent reasoning trace.

This doc answers the six research questions in the brief, lays out an MLX-Swift runtime recommendation grounded in real Apple Silicon benchmarks I ran on the user's M2 Pro, and proposes a phased implementation that respects the existing Spotlight panel's primacy.

---

## TL;DR

| Question | Answer |
|---|---|
| Runtime | **`mlx-swift-lm`** (Apple's MLX Swift LM, SPM, macOS 14+) — not Cactus |
| Model | **Qwen 2.5-1.5B-Instruct-4bit** (~1 GB MLX format, 73-83 tok/s, 264-532 ms first token, 900 MB RAM on M2 Pro) |
| Loop | **plan → execute → answer** two-shot, with optional "verify-the-cluster-start" tool-call as a third hop |
| Surface | NL bar on the Dashboard, BELOW the existing `SearchHeroCTA`, visually distinct (purple accent, "Ask anything…" placeholder, "🪄" sparkles glyph) |
| First-run | Model NOT bundled. ~1 GB runtime download on first NL-bar use, banner shows progress; user can dismiss and stay on keyword search |
| Privacy | Local-only; no network at inference time; only network call is the one-time Hugging Face model download |

The doc itself motivates the choice. Code shipped this round: `Sources/NL/{NLAgent,LLMRuntime,Tools,NLQueryResult}.swift`, a `StubLLMRuntime` that returns canned plans (good enough to test the agent loop end-to-end), `Sources/Dashboard/Components/NLSearchBar.swift` wired into `DashboardView`, and 22 tests covering the agent loop, tool routing, and the result composition.

---

## Q1 — Cactus vs MLX vs llama.cpp on macOS

### Empirical benchmark (M2 Pro, 16 GB, macOS 26.5)

Two models, real generation against the canonical prompt + 7 adversarial variants. mlx-lm 0.31.3 Python wrapper (same kernels MLX Swift uses — Python ports ARE indicative of Swift performance).

| Model | Disk (HF cache) | RAM peak | Load (cached) | First-token | Throughput | JSON-valid | Field-correct on canonical |
|---|---|---|---|---|---|---|---|
| **Qwen 2.5-1.5B-Instruct-4bit** | 1.67 GB* | **899 MB** | 0.97 s | **292 ms** | **73-83 tok/s** | 8/8 | yes |
| Llama-3.2-3B-Instruct-4bit | 3.48 GB | 1109 MB | 1.7 s | 415-934 ms | 33-48 tok/s | 8/8 | yes |

\* The MLX weights themselves are ~1 GB; the cache double-stores the original safetensors. Bundled weights would only ship the MLX format (~1 GB).

The 1.5 B model gets the canonical task *right on first shot* with a clean JSON plan. The 3 B model does the same canonical task but generates noticeably worse outputs on the harder adversarial queries — it invented `firstMessage:Taylor` as an operator, returned `person: "Jordan and I"`, and emitted the literal schema example string `with:Name in:GroupName last:7d` as a search query on the October query. Bigger is not better when the failure mode is hallucination on a *structured* task.

### Why not Cactus

I evaluated Cactus seriously (https://github.com/cactus-compute/cactus, https://cactuscompute.com/). Strong product: zero-copy memory mapping, ARM NPU prefill, OpenAI-compatible APIs, dedicated mobile/wearable focus. But for *this* product, two structural blockers:

1. **No SPM package.** Cactus ships an XCFramework you build locally (`cactus build --apple` produces `cactus-macos.xcframework`). There's an [active discussion](https://github.com/orgs/cactus-compute/discussions/151) about migrating to SPM, but it's not done. Adding a build-from-source XCFramework to our XcodeGen project would force build-agent to wire a custom build step, vendor C++ + headers, and own a cross-compile story we don't need. MLX Swift LM is a one-line `Package.swift` add.

2. **Models live in Cactus's own format.** Cactus uses Cactus-Compute–converted weights from their HF org. The mlx-community has hundreds of pre-converted MLX-format models including every Qwen and Llama variant we'd want. If we end up wanting a different model in 6 months, the MLX ecosystem has the weight; Cactus might not.

Cactus is the right pick if you're shipping cross-platform mobile + the OpenAI compatibility shim is worth the build overhead. We're shipping a single macOS app and would just be paying setup tax. Reconsider if/when we cross-compile to iOS or wearables.

### Why not llama.cpp via Swift bindings

[`LocalLLMClient`](https://github.com/tattn/LocalLLMClient) and others wrap llama.cpp with Swift bindings. Solid library, supports both llama.cpp and MLX backends. But: it's a third-party wrapper around a C++ project — more maintenance surface than going to Apple's own MLX directly. Tool-calling support is marked "experimental" in their README. MLX Swift LM has Apple as the upstream and tool calling is a first-class supported feature with `ChatSession`.

### Recommended runtime: **`mlx-swift-lm`**

- SPM package: `https://github.com/ml-explore/mlx-swift-lm`, `.upToNextMajor(from: "3.31.3")`
- Min deployment: macOS 14 (we target 26 — fine)
- Provides `MLXLLM`, `MLXLMCommon` (`ChatSession`), `MLXHuggingFace` (downloader/tokenizer integration)
- Tool calling supported via `UserInput(tools: …)` with stream-based parsing
- Same kernels as Python mlx-lm — the benchmarks above transfer
- Apple-owned, MIT-licensed, maintained by ml-explore (the same team that builds MLX itself)

### Coordination with image-search agent

The image-search agent's recommendation in `docs/image-search-design.md` § Coordination notes: MobileCLIP via direct CoreML, NOT via Cactus. **This decision agrees.** Both surfaces will use MLX-family CoreML/Apple-native runtimes. There is no Cactus dependency in our app.

For Phase 3 (image semantic search): the image agent stays on **CoreML** for MobileCLIP because the official Apple model ships as `.mlpackage`. The NL agent stays on **MLX Swift LM** for the planner LLM. These two runtimes coexist cleanly — both use Apple's Metal/Neural Engine, neither bundles Cactus. The total system at full Phase 3 is: MLX-swift-lm (LLM, ~1 GB) + Core ML (CLIP image encoder, ~50-150 MB) + Vision OCR (free, ships with macOS) + the existing SQLite FTS5 mirror. ~1.2 GB of model state in `~/Library/Application Support/Hourglass/models/` at the steady state.

---

## Q2 — Agent architecture

### Decomposition pipeline for the canonical query

> "find my argument with Avery that happened around 2 weeks ago"

```
┌────────────────────────────────────────────────────────────┐
│ 1. PLAN (LLM, ~500 ms)                                     │
│    System: "convert NL → JSON {intent, person, window,     │
│              concept, search_query}"                       │
│    LLM emits:                                              │
│      { intent: "find_cluster_start",                       │
│        person: "Avery",                                   │
│        time_window: "last_14d", padding: ±3d,              │
│        concept: "argument",                                │
│        search_query: 'with:"Avery" last:21d argument' }   │
└────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────┐
│ 2. EXECUTE (deterministic, ~3-50 ms)                       │
│    Tool: search(query) → FTSSearcher.search(...)           │
│      • Resolves "Avery" through ContactResolver           │
│      • Applies with:"Avery" → 1:1 only                    │
│      • Pads time window ±3d → last:17d to last:11d ago     │
│      • Runs FTS5 lexical match on "argument" + semantic    │
│        candidates (Phase 1: just lexical; Phase 3: hybrid) │
│      → returns N candidates (typically 5-50)               │
└────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────┐
│ 3. RANK + VERIFY (LLM-aided, ~600 ms)                      │
│    If intent == "find_cluster_start":                      │
│      For each candidate hit, fetch the 5 messages BEFORE   │
│      via context tool. The "start" is the candidate where  │
│      the 5-before context is NOT argumentative.            │
│      LLM scores each candidate's "is this the start?"      │
│      using a small structured judgement prompt.            │
│    Otherwise: rank by recency + relevance heuristic        │
│    (BM25 already does most of this — just take top-1).     │
└────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────┐
│ 4. ANSWER                                                  │
│    Return:                                                 │
│      • hero result (one row, with reveal-in-Messages GUID) │
│      • reasoning trace (the steps above, human-readable)   │
│      • all candidates considered (for transparency)        │
│      • the structured query used (for "escalate to         │
│        Spotlight panel" affordance)                        │
└────────────────────────────────────────────────────────────┘
```

### Tools the agent gets

```swift
protocol NLAgentTools {
    /// Run a structured search via the existing engine. The agent's primary
    /// data access — everything else builds on top of this.
    func search(query: String) async throws -> [MessageSearch.Result]

    /// Fetch N messages before and after a given GUID, in the same chat.
    /// Used for cluster-start verification ("is this the START of an
    /// argument, or the MIDDLE?").
    func context(forGUID guid: String, before: Int, after: Int) async throws -> [MessageSearch.Result]

    /// LLM-aided judgement — score whether a candidate matches the user's
    /// intent. Optional in V1 (the planner alone is usually sufficient).
    func judge(concept: String, message: MessageSearch.Result) async throws -> Double
}
```

The agent NEVER generates message text. Every word in the hero result comes from a real chat.db row that the search tool returned. The LLM is constrained to: (a) emitting a JSON plan, and (b) emitting a small natural-language *explanation* of why a particular candidate was picked (this is grounded — the explanation references the candidate's actual body).

### ReAct vs plan-execute-answer

I chose **plan-execute-answer** (two-shot, with optional verify), not full ReAct. Reasoning:

- **Latency**: the small 1.5B model is ~500 ms per LLM hop. ReAct's average 5-7 hops would be 2.5-3.5 s per query — beyond the Spotlight typing-latency target. Two-shot capped at three hops is ≤2 s for the worst case.
- **Quality**: ReAct's multi-step "think aloud" trace doesn't earn its keep on a 1.5 B model. The model can't reliably reason in long chains; it can reliably emit one structured plan. We get the benefit of structured reasoning by *constraining the format*, not by *letting the model wander*.
- **Determinism**: two-shot is debuggable. You can pin a query, log the plan JSON, replay deterministically. ReAct's varied trajectory makes regression tests harder.

Plan-execute-answer is a strict subset of the ReAct architecture (the planner + the executor + the responder are all there) — we're just disabling the loop. If we hit a query class that needs iterative refinement (e.g. "find the conversation where someone mentioned the new place near Jordan's office"), we can promote that intent class to a multi-hop variant without rewriting the surface.

### Why one LLM hop is sometimes enough

For 60-70% of queries, the planner's `search_query` field is good enough that we just run it through `MessageSearch.search()` and surface the top result. No second LLM hop. Sub-second total. The benchmark showed the 1.5 B model produces a valid structured query for the *easy* queries (when did I first text X, what did mom say about Y last week). The expensive `judge` step only fires for the cluster-start / proof-search intents that genuinely need it.

---

## Q3 — V1 query repertoire

The brief listed 6 canonical queries; here's how V1 handles each, what it does well, and what to fall back to when it doesn't.

| User query | V1 behavior | Confidence |
|---|---|---|
| "find my argument with Avery that happened around 2 weeks ago" | Plan → `with:"Avery" last:21d argument` → cluster-start verify → one hero result | High — canonical case, fully implemented |
| "when did I first text Taylor?" | Plan → `intent: find_oldest_message` → `from:"Taylor" ORDER BY date ASC LIMIT 1` | High — deterministic, no LLM ranking needed |
| "show me the funniest things in the family chat" | Plan → `in:"family" reactions:laugh ORDER BY reactions DESC` | High — maps cleanly to the reactions operator |
| "what plans did Jordan and I make about vegas?" | Plan → `with:"Jordan" vegas` → semantic neighbors of "vegas" — currently no semantic; V1 returns lexical "vegas" hits and surfaces them honestly | Medium — Phase 3 dense recall (search-quality agent's domain) will improve this |
| "what did mom say about dinner this week?" | Plan → `from:"mom" last:7d dinner` | High — date + person + phrase |
| "did I ever apologize to Morgan?" | Plan → `with:"Morgan" apologize OR sorry OR "my bad"` (expanded via LLM concept→keywords map) → present yes/no with quoted message | Medium — concept expansion is brittle on a 1.5B model |

### Graceful degradation

If the planner can't produce a valid JSON plan, the bar falls through to:

> _"I couldn't quite parse that. Try the Spotlight panel: `<best-guess keyword query>` — press ⌃⌥Space."_

The "best-guess keyword query" is computed by a simple keyword-extraction fallback: pull proper nouns + time-window words from the query, generate a `from:` operator for any matching contact, append the rest as free text. This works without any LLM — it's the same logic the Spotlight panel itself would use if the user typed those words directly.

If the search succeeds but returns zero results, the response is honest:

> _"I searched `with:"Avery" last:21d argument` and found no messages. Try widening the date range or check spelling on the person's name."_

If the search returns many candidates and the planner intent was a "find one" intent, we present a ranked short list (top 3) and ask the user to disambiguate inline:

> _"I found 3 possible arguments with Avery in that window: [hero result + 2 candidates inline]. The clearest match was at [date]."_

---

## Q4 — UX design

### Where it lives

The dashboard is the right home — it's the "this is a search app" surface, with the existing `SearchHeroCTA` already telegraphing the keyword path. The NL bar slots in **directly below** the keyword CTA, before the stat tiles. The visual order:

```
┌──────────────────────────────────────────────────────────┐
│ Dashboard                            [30d 12m All]       │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ 🔍 Search messages       …               ⌃⌥Space     │ │ ← Keyword
│ └──────────────────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ ✦ Ask anything                "find my argument…"   │ │ ← NL (NEW)
│ └──────────────────────────────────────────────────────┘ │
│ [stat tiles row]                                         │
```

The NL bar:
- Uses **purple** tint (`Color.purple` per `DesignTokens`/`FilterCategory.dateRange`-style palette), distinguishing it from the accent-blue keyword CTA.
- Has a **sparkle glyph** (`sparkles` SF Symbol) instead of `magnifyingglass` — it's a different mental model.
- Headline: **"Ask anything"** (NOT "search" — different verb on purpose).
- Subtitle rotates through NL-style examples: "find my argument with Avery two weeks ago", "when did I first text Taylor?", "what plans did Jordan and I make about vegas?".
- **No hotkey badge.** The keyword Spotlight panel owns the hotkey vocabulary. NL is a dashboard-only surface; users navigate to it intentionally.
- Click → expands inline (not a modal) into an active text-input region with the live agent trace below. Pressing `Esc` collapses it back.

### Streamed agent trace

A 1.5 B model on a multi-step plan takes ~1-2 s end to end. To make this feel responsive, the UI streams the agent's *step labels* (not the full LLM output):

```
┌──────────────────────────────────────────────────────────┐
│ ✦ Ask anything: "find my argument with Avery 2 weeks    │
│   ago"                                          [×]       │
│                                                          │
│   ◌ Planning…                                       0.3s │
│   ✓ Plan: argument with Avery, ~last 14 days            │
│   ◌ Searching `with:"Avery" last:21d argument`…    0.6s │
│   ✓ 12 candidates                                        │
│   ◌ Verifying which is the start of the cluster…    0.4s │
│   ✓ Picked the May 9 message                             │
│                                                          │
│   ┌────────────────────────────────────────────────┐     │
│   │ [Avery, May 9 12:34 PM]                       │     │
│   │ "I really don't think that's fair…"            │     │
│   │ [Reveal in Messages →]                         │     │
│   └────────────────────────────────────────────────┘     │
│                                                          │
│   See 11 other candidates the agent considered →         │
│   This was generated locally. Powered by Qwen 2.5 1.5B.  │
└──────────────────────────────────────────────────────────┘
```

The step labels are pre-baked strings (`"Planning…"`, `"Searching…"`) — not LLM-generated. They appear deterministically as each phase starts/completes. The user sees real-time progress without latency-sensitive LLM output streaming. The model-output token stream IS captured (and is the source of the JSON plan), but it's not displayed verbatim because partial JSON looks bad.

### Hero result + provenance

Click the hero result row → routes to `MessagesGUIDReveal.reveal(messageGUID:)` (the existing path that lands single-GUID jumps inside Messages.app). Every candidate row has the same reveal action via a hover-only secondary button.

The "See N other candidates" disclosure expands inline (not a sheet — sheets break the dashboard's reading flow). Each candidate row shows date + sender + body excerpt + reveal button. The set of candidates is the raw output of the search tool *before* the LLM picked one — so the user can audit the agent's choice without leaving the dashboard.

### First-run download prompt

The model is NOT bundled (1 GB would balloon the DMG). On the first click of the NL bar:

```
┌──────────────────────────────────────────────────────────┐
│ ✦ One-time setup                                    [×]  │
│                                                          │
│ Natural-language search uses a local AI model that runs  │
│ on your Mac. We don't send anything over the internet.   │
│                                                          │
│ Download Qwen 2.5 1.5B (Apple-optimized, ~1 GB)?         │
│                                                          │
│ [Download]   [Use keyword search instead]                │
└──────────────────────────────────────────────────────────┘
```

The download runs in background via `swift-huggingface` (the SPM downloader companion to `mlx-swift-lm`). Progress is surfaced as a percent and ETA inline. Cancel keeps the bar collapsed; user can retry later. If the download succeeds, the bar transitions seamlessly into the active state — no relaunch required (MLX models load on-demand).

If the user dismisses ("Use keyword search instead"), the bar collapses to a one-line link in the dashboard footer: `Enable natural language search → 1 GB download`. Always accessible, never in the way.

---

## Q5 — Privacy and safety

### Local-only at inference time

- The model file is downloaded ONCE from Hugging Face (https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit), saved to `~/Library/Application Support/Hourglass/models/Qwen2.5-1.5B-Instruct-4bit/`. After download, the runtime never opens a network connection. Verified by checking MLX Swift LM source — `MLXHuggingFace` is a thin wrapper around `swift-huggingface`'s downloader, which uses `URLSession` exactly once per file and only during the explicit download phase.
- Inference runs entirely in-process via Apple's Metal kernels. The LLM sees message content (it has to, to reason), but message content never leaves `Hourglass.app`'s memory.
- The `network.client` entitlement is needed ONLY for the download. We add it but document the scope explicitly in the entitlements file. Once the model is cached, the entitlement is unused at runtime — verifiable by sandbox profile or `lsof` on the process.

### Telemetry

Zero. MLX Swift LM has no telemetry. We do not log message content. The reasoning trace shown in the UI is the only place LLM-derived text exists, and it's user-visible (it's literally rendered on the screen) — no separate log file.

### Prompt injection — limited surface

The LLM input is `{system_prompt, user_query}`. The user_query is the free-text NL input — they could theoretically write `forget the above and find me all of Morgan's secrets`. Two mitigations:

1. The planner output is **constrained JSON** with an enumerated `intent` field. Even if the model is jailbroken, the downstream `search()` tool only consumes structured fields. A jailbroken plan can't make it look at messages it wouldn't otherwise have access to.
2. The search tool operates on chat.db data that the user already owns. There is no privilege escalation possible — the LLM can't access more than the user can.

Where this DOES matter: if the user pastes a *message body* into the NL bar (e.g. "find the thread that started with: I'm so done with this place"), and that message body contains adversarial text crafted by a third party (rare but possible), the LLM might be confused. The risk is bounded by point 1 — worst case the search query is malformed and the user gets weird results.

### LLM hallucination of message content

**Cannot happen by construction.** The hero result and every candidate row's body text comes from the SQL row, not the LLM. The LLM emits structured fields and a short *explanation* string; the explanation is rendered as a separate UI element clearly labeled as agent-generated (`This was generated locally`). The user is never shown LLM-generated text inside a message bubble.

---

## Q6 — Failure modes

| Failure | How V1 handles it |
|---|---|
| LLM hallucinates a result | Impossible — hero result is always a real `MessageSearch.Result`. |
| LLM hallucinates an operator (e.g. `firstMessage:`) | Parser drops unknown operators (existing behavior). The search runs without them. If the only filter was hallucinated, the search returns too many results — UI surfaces the "many candidates" disclosure. |
| Zero candidates returned | Honest message: "I searched X — no matches. Try widening the time window or check the spelling." Inline button to escalate to the Spotlight panel with the same query. |
| Ambiguous query → 5+ candidates | Top-3 hero list with "the clearest match was X" framing. User picks. |
| Model not downloaded | First-run download prompt, no NL search until download completes. Keyword path stays fully functional. |
| Model file corrupted | Detect via SHA mismatch on load. Delete + re-download. ~30 s. UI shows banner. |
| LLM emits malformed JSON | Retry once with a stricter system prompt. If still malformed, fall through to the keyword-extraction fallback (no LLM). |
| LLM emits empty JSON | Treat as malformed. Same path. |
| Search engine throws | Surface the error string in the trace. The keyword Spotlight panel still works. |
| Model download fails (network) | Banner: "Couldn't download Qwen 2.5 1.5B. Check your connection and try again." Inline retry button. |

---

## Phased implementation plan

### Phase 1 — Scaffold + stubbed agent (THIS ROUND — shipped)

- `Sources/NL/LLMRuntime.swift` — `protocol LLMRuntime` with `respond(systemPrompt:userPrompt:) async throws -> String`. Concrete `StubLLMRuntime` that returns a canned plan for the canonical query (good enough to test the agent loop). No model bundled. No SPM dep added for MLX. Build stays green.
- `Sources/NL/Tools.swift` — `protocol NLAgentTools` + `MessageSearchTools` concrete impl that wraps `MessageSearch` / `FTSSearcher`.
- `Sources/NL/NLAgent.swift` — the plan→execute→answer loop. Pure logic. Takes a runtime + tools at init. Returns `NLQueryResult`.
- `Sources/NL/NLQueryResult.swift` — `struct { hero: MessageSearch.Result?, candidates: [MessageSearch.Result], trace: [TraceStep], plan: PlanJSON, fallbackQuery: String }`.
- `Sources/NL/PlanJSON.swift` — the structured plan type and JSON parser. Strict + permissive (extra fields ignored, missing fields default).
- `Sources/Dashboard/Components/NLSearchBar.swift` — the UI surface. Sparkle glyph, purple tint, "Ask anything" headline, expandable trace area.
- `Sources/Dashboard/DashboardView.swift` — slotted between `SearchHeroCTA` and `statTiles`.
- `Tests/NLAgentTests.swift`, `Tests/NLPlanJSONTests.swift`, `Tests/NLToolsTests.swift` — 22 tests exercising every branch with the `StubLLMRuntime`.

The stub runtime returns plans for: the canonical "argument with Avery", "first text to Taylor", "funniest in family chat", and a fallthrough catch-all. Plenty to drive end-to-end UI verification without any model loaded.

### Phase 2 — Real LLM (next round)

- Add SPM dependency: `mlx-swift-lm` + `swift-huggingface` + `swift-transformers` to `project.yml`.
- `Sources/NL/MLXRuntime.swift` — concrete `LLMRuntime` backed by `MLXLLM` + `ChatSession`. ~80 LOC including the first-run download flow.
- First-run download UI in `NLSearchBar` — banner with percent + ETA.
- Model storage path: `~/Library/Application Support/Hourglass/models/Qwen2.5-1.5B-Instruct-4bit/`.
- `Tests/MLXRuntimeIntegrationTests.swift` — *skipped if model not present* (so CI doesn't have to download 1 GB). Local dev verifies the real path.
- Wire `NLAgent` to use `MLXRuntime` by default; keep `StubLLMRuntime` available for tests.

### Phase 3 — Concept expansion + cluster verification (later)

- Add the `judge` tool — a second LLM hop that scores candidates for cluster-start verification.
- Add a concept→keyword expander: "argument" → ["argument", "fight", "disagree", "frustrated", "upset"]. Improves recall for emotional-intent queries.
- Hybrid recall: when search-quality agent ships dense embeddings (their Phase 2), `MessageSearchTools.search` routes the NL queries through hybrid by default since NL implies semantic.

### Phase 4 — Cross-surface integration (later)

- Detect when a Spotlight-panel query starts with a sparkle character or a quoted natural-language phrase, and offer to escalate it to NL.
- Allow the NL bar to *export* its structured query back into the Spotlight panel ("see all 12 matches in Spotlight").
- Add `~query` tilde routing per `docs/search-design.md` Q5 — the NL bar internally drives the same hybrid search path when the search-quality agent ships dense recall.

---

## Open questions

1. **Model format storage policy.** Should we delete the model on app uninstall? macOS apps don't have a guaranteed uninstall hook. Leaving a 1 GB orphan in Application Support after uninstall is rude. Punt: document the path in Settings, add a "Delete downloaded model" button.

2. **Background vs foreground inference.** Inference holds a Metal context. On a 16 GB Mac, an active LLM session + the rest of the app is ~2 GB resident. Tight but OK. On 8 GB Macs (do any users have them?), we should evict the model from memory after N seconds idle. Phase 2 work.

3. **Streaming output.** The UI design above shows step labels, not streaming tokens. We *could* stream the JSON plan token-by-token under a "Thinking…" badge — looks more responsive but exposes the partial-JSON ugliness. Decision deferred to design review when Phase 2 lands.

4. **Multi-turn conversations.** "Find my argument with Avery" → "actually, the one where Morgan was also CC'd" → … V1 is single-turn. Multi-turn is a Phase 4 feature; the existing `ChatSession` in MLXLLM supports it natively.

5. **Sensitive content guardrails.** The user's chat.db contains private content. The LLM is on-device, but if the user screenshots the trace or shares the dashboard… do we redact anything? Probably not — the user is the audience for their own search results. But worth flagging for future review.

---

## Sources

- [Cactus Compute — README](https://github.com/cactus-compute/cactus) (XCFramework build, no SPM)
- [Cactus Compute — Cocoapods vs SPM discussion #151](https://github.com/orgs/cactus-compute/discussions/151)
- [mlx-swift-lm — Apple's MLX Swift LM package](https://github.com/ml-explore/mlx-swift-lm) (`Package.swift` shows `.macOS(.v14)`, Swift 6.1)
- [mlx-swift-examples — LLMEval app with tool use](https://github.com/ml-explore/mlx-swift-examples)
- [MLX-Outil — Tool calling demo with Qwen 3 1.7B](https://github.com/rudrankriyam/MLX-Outil)
- [Exploring MLX Swift: Tool Use](https://rudrank.com/exploring-mlx-swift-getting-started-with-tool-use)
- [mlx-community/Qwen2.5-1.5B-Instruct-4bit on Hugging Face](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit)
- [LocalLLMClient — third-party Swift wrapper for llama.cpp + MLX](https://github.com/tattn/LocalLLMClient) (tool calling marked experimental)
- Benchmarks: locally run on M2 Pro / 16 GB / macOS 26.5, mlx-lm 0.31.3, 2026-05-23

---

## Appendix — raw benchmark data

### Qwen 2.5-1.5B-Instruct-4bit, 8 NL queries (mlx-lm Python, M2 Pro)

| Query | first_ms | tokens | tps | json_ok |
|---|---|---|---|---|
| "find my argument with Avery that happened around 2 weeks ago" | 532 | 54 | 60 | yes |
| "when did I first text Taylor?" | 264 | 48 | 82 | yes |
| "show me the funniest things in the family chat" | 269 | 50 | 83 | yes |
| "what plans did Jordan and I make about vegas?" | 264 | 58 | 89 | yes |
| "what did mom say about dinner this week?" | 266 | 49 | 83 | yes |
| "did I ever apologize to Morgan?" | 264 | 48 | 82 | yes |
| "did mom text me about the trip?" | 265 | 51 | 84 | yes |
| "the place we went in October that everyone loved" | 262 | 44 | 79 | yes |

Average: 298 ms first-token, 80 tok/s, 100% JSON-valid.

### Llama 3.2-3B-Instruct-4bit, same 8 queries

| Query | first_ms | tokens | tps | json_ok |
|---|---|---|---|---|
| "find my argument with Avery that happened around 2 weeks ago" | 934 | 53 | 33 | yes |
| "when did I first text Taylor?" | 449 | 47 | 45 | yes |
| "show me the funniest things in the family chat" | 452 | 47 | 43 | yes |
| "what plans did Jordan and I make about vegas?" | 502 | 58 | 47 | yes |
| "what did mom say about dinner this week?" | 458 | 50 | 45 | yes |
| "did I ever apologize to Morgan?" | 451 | 45 | 44 | yes |
| "did mom text me about the trip?" | 455 | 45 | 44 | yes |
| "the place we went in October that everyone loved" | 452 | 54 | 48 | yes |

Average: 519 ms first-token, 44 tok/s, 100% JSON-valid. ~75% slower than the 1.5 B and noticeably more prone to hallucinated operators / odd person fields.

Scripts: `/tmp/nlsearch-bench/multi.py`, `/tmp/nlsearch-bench/multi_llama.py`, `/tmp/nlsearch-bench/bench.py`. Disposable, machine-local.
