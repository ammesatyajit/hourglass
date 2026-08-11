# Needle-hybrid NL runtime — spec

_Draft 2026-08-10. Evaluates a two-tier on-device runtime: a tiny grammar-constrained
emitter (Needle-2-class) for routing + structured emission, escalating to the existing
Qwen3-4B (MLX) only for free-text synthesis._

## Problem being solved

Today one model (Qwen3-4B, ~1 GB via MLX) does two structurally different jobs:

1. **Routing + structured emission** — pick a tool, emit valid args / a QuerySpec.
2. **Free-text synthesis** — read messages/observations, write a prose answer.

This session's QuerySpec probe measured job (1) precisely: **11/11 valid JSON, 6/6 correct
dimension routing**. **Correction after evaluation (see bottom):** the failures split into two
classes, and only one is grammar-fixable. (a) *Invalid tokens* — `message_type:` for `type:`,
`reaction:` for `reactions:` — which a decode-time grammar makes **unsamplable**. (b)
*Valid-but-wrong semantic picks* — `type:sticker` for a photos query (`sticker` is a legal
`type:` value), `last_month` for "last week" (a legal window token), a dropped `from:me`, a
missing weekday dimension — which **neither a grammar nor Needle fixes**. Class (b) is the
*majority* of the consequential misses. So constrained decoding closes the invalid-token class
at the root (the "gold standard" `agent-optimization-research.md` names), but it is a *minority*
of the measured user-visible errors — do not oversell it.

## The idea: two-tier runtime

- **Tier 1 — Constrained Emitter (Needle-2-class):** 45M params, 14 MB binary, 28 MB RAM,
  CPU-only, Apache-2.0. `text → JSON`, grammar compiled from tool schemas constrains every
  token → invalid enums/operators become **impossible**. Emits `function_calls` + `reasoning`
  + `confidence`, auto-retrieves top-5 tools from the catalogue.
- **Tier 2 — Synthesizer (existing Qwen3-4B / MLX):** invoked ONLY for queries that need
  prose over an observation.

## Routing boundary (grounded in the 30-query corpus from the semantic-layer eval)

| Class | Examples | Path |
|---|---|---|
| Stats / count / ranking / date-agg / first-last / dim×filter unlocks | "who did I text most in 2026", "photos last month", "busiest month with Annika", "who posts most in the Hao group" | **Tier-1 only** → emit QuerySpec → execute in Swift → templated answer. No prose model. |
| Investigative / content-synthesis / open-ended / long-read | "what did Beck and I talk about", "what have I been stressed about", the Beck-gift read | **Escalate to Tier-2**: Tier-1 emits the initial retrieval call; the 4B reads the observation and writes prose. |

**Escalation trigger:** Needle's own `confidence` field (it confidence-gates and escalates
below threshold) + a static `needsSynthesis` flag on each QuerySpec intent.

## Why Needle fits the *emit* step

- **Grammar-constrained JSON** kills the operator/enum error class outright — the one thing
  the 4B provably fumbled in the probe.
- **14 MB / 28 MB / CPU-only** → instant load, no MLX/Metal (would have sidestepped today's
  Metal-toolchain build breakage), negligible footprint.
- Native tool-calling API with top-5 retrieval matches our ~11-tool catalogue.

## Hard constraints (why it can NOT just replace the 4B)

- **256-token sliding window** → cannot ingest a 40-message observation → **cannot drive
  multi-turn ReAct** with result feedback. It is a *one-shot* `query → call` emitter, not a
  loop driver.
- **No free-text generation** (off-topic → empty calls) → cannot synthesize prose. The 4B
  stays for Tier 2.
- **BFCL v4 42.6%** (below LFM2.5 230M 60.8%, Apple FM 61.7%) → general tool-choice may
  mis-route on our schema; likely needs a Hourglass-specific fine-tune (Apache-2.0 +
  "retrains on a Mac in minutes–hours" makes this feasible, but it's real work).
- **Separate engine.** Needle "bakes into its own engine" (`libneedle.a` / `cactus-needle`),
  NOT necessarily the vendored `cactus-macos.xcframework` that today's `CactusRuntime`
  (`cactus_complete → text`) uses. Integration is probably: vendor a *second* lib + a new
  protocol — not reuse `respond() -> String`.

## Integration sketch

- New protocol beside `LLMRuntime`:
  `protocol StructuredEmitter { func emit(query: String, tools: [ToolSchema]) async throws -> EmittedCall }`
- `NeedleRuntime` conforms, backed by libneedle, guarded `#if canImport(needle)` exactly like
  `CactusRuntime` guards `#if canImport(cactus)`.
- Aggregation tools' arg grammars (metric/dimension/type/reactions enums) become Needle tool
  schemas → provably valid emission.
- `answerWithToolLoop`: Tier-1 emits; `intent==stats` → execute + template; `needsSynthesis ||
  confidence < τ` → hand the query (+ Tier-1's retrieval call) to the existing 4B loop.

## The load-bearing open question (for the eval to settle)

**Grammar-constrained decoding — the main correctness win — is achievable on the EXISTING 4B.**
**Correction after evaluation:** this is NOT a config flag. `llama.cpp` has a native grammar
sampler, but `mlx-swift-lm` (3.31.3, checked out) exposes only a `LogitProcessor` hook +
a `TokenIterator.init(…processor:…)` — no grammar/JSON-schema engine. So the counterfactual
requires **writing the grammar→BPE-token-mask compiler ourselves** (incremental parse, Qwen3
vocab alignment, UTF-8 byte-fallback tokens) AND refactoring `MLXRuntime.respond` off the
high-level `ChatSession` onto the lower-level `TokenIterator/generate()` API. Real, test-heavy
work — but still one model, one engine, no fine-tune. The honest question stands: "**does
Needle's footprint justify a second model + second engine**?" — and per the evaluation the
answer is no *now*, because the size win never materializes while the 4B stays resident for
synthesis.

---

## Evaluation (2026-08-10, adversarial workflow: proponent · skeptic · counterfactual · arbiter)

**Verdict: `gbnf-on-4b-first` — do not build the Needle hybrid now.** The correctness the spec
targets is a property of *constrained decoding* (model-agnostic), so on the measured failure
class GBNF-on-the-existing-4B and Needle are at **parity**. Needle's only unique offering is
footprint (14 MB / 28 MB / CPU-only / no-Metal), and that **does not materialize** in this
hybrid: Tier-2 keeps the ~1 GB Qwen3-4B resident on MLX/Metal for prose synthesis the corpus
provably needs, so the hybrid *increases* model + engine count. All four agents (incl. the
proponent's own concessions) agreed the size win is stranded behind the model you never remove.

**Recommended sequence:**
1. **Keep `operatorCorrection`** as the cheap deterministic floor / fallback.
2. **Probe the already-vendored Cactus `tools_json` path first** — `CactusRuntime` already calls
   `cactus_complete` with `tools_json=nil` today, and its envelope already parses
   `function_calls` + `confidence`. Native constrained tool-calling may be reachable with **no
   new library**. (Audit that its confidence/hand-off cannot re-open the cloud egress the team
   hard-disabled for the local-only promise.)
3. **If that falls short**, prototype GBNF via `LogitProcessor` on the existing 4B, scoped
   narrowly to the filter fields (closed vocab: 11 operators, `type:`=8 values, `reactions:`=6
   kinds+comparators, date-window format). Keeps the validated 6/6 routing untouched; no fine-tune.
4. **Measure the residual** — it will be the *semantic* class (sticker-for-photos, wrong window,
   dropped `from:me`), which neither path fixes; decide separately, and weigh against the OPEN
   multi-term-OR under-return bug that degrades the real corpus and plausibly outranks all of this.
5. **Defer Needle to a named trigger**, not a date: a synthesis-free / routing-only build, weak
   or non-Metal hardware, or an explicit decision to drop MLX/Metal (which itself requires
   replacing the 4B synthesizer). Until then the second engine is unjustified.

**Risks the eval flagged:** BFCL v4 42.6% (below LFM2.5-230M 60.8% / Apple FM 61.7%) → stock
Needle would take over the one job (routing) that already works 6/6, and likely needs a
Hourglass-specific fine-tune (standing ownership burden). Demand risk: 0 of the 6 dim×filter
unlocks come from the validated corpus — all speculative. Opportunity cost: the multi-term-OR
bug is a live correctness defect on real queries.
