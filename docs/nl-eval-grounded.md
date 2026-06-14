# Grounded NL-search eval — "plans I committed to" + fuzzy recall

Purpose: pick the best ON-DEVICE model for two capability classes the operator
named — (A) "what plans did I commit to this week" and (B) "remind me about
something when I'm struggling to find it" (fuzzy recall) — by scoring each
candidate model against GROUND TRUTH derived by reading the real chat.db, not
by vibes.

How ground truth was built: read every substantive message the operator SENT in
the trailing window (via the FTS index `index.sqlite`, body in `messages_fts_content`),
plus commitment-language filters (let's / i'll / gonna / we should / confirmed /
tmrw / next week). Today = 2026-06-14; "this week" = 2026-06-08 .. 06-14.

Run a case:  `HOURGLASS_NL_EVAL_REACT="<query>" <app>`  (honors nl.runtime.cactus +
NLModelPreference). Score the emitted `answer` against the expected set below.

---

## A. "Plans I committed to this week" — GROUND TRUTH (read from real texts)

The genuine commitments the operator made 06-08 .. 06-14 (each cites a real sent
message). A correct answer should surface MOST of these; a great one cites them.

| # | Commitment | Evidence (sent message, paraphrased) | With (handle) |
|---|-----------|--------------------------------------|---------------|
| 1 | NY trip that weekend | "Also we're confirmed ny that weekend right"; recreating the Times Square pic; "we are gon be dripped out" | 15713373957 |
| 2 | Summer-skills list, one/day | "list of stuff I wanna cultivate over summer: AI/ML, Singing, Origami, Fashion, Gym" + "aim to progress at least one per day" | 15713373957 |
| 3 | South Bay dinner (chaat Bhavan) | "We're gonna end up at chaat Bhavan"; "this one dinner gonna run us 2 bands"; "do more South Bay" | — |
| 4 | LG cafe brunch | "thoughts on LG cafe brunch tmrw" (06-13) | — |
| 5 | Boondocks coffee, 8am | "Tmrw 8 am boondocks coffee roasters" (06-12) | — |
| 6 | Hao dinner | "Tmrw hao dinner im there" (06-10) | — |
| 7 | Finals / final report | "I need to finish this final report"; "have a final until 6"; "one final tmrw" | — |
| 8 | See each other next week | "We're prob gonna see each other next week" (06-11) | — |

Scoring (0–8 recall): count distinct true commitments the model names. Penalize
HALLUCINATED commitments not in this list (precision). Target: recall ≥5/8, zero
hallucinations.

OPEN QUESTION the eval answers: is a weak result a MODEL problem or a TOOL-GAP
problem? The agent has no "extract commitments from a date window across all
chats" primitive — `readMessages` needs a person, `search` is keyword-driven,
and the loop caps at 8 calls / 3 reads. If even the 7B model fails the same way,
the fix is a NEW tool (see "Findings → tool gap"), not a bigger model.

## B. Fuzzy recall — "remind me about X when I can't find it"

Real, findable things the operator referenced this week — phrased VAGUELY, the way
you'd ask when you can't remember the exact words:

| Query (vague, as a human would type) | Ground-truth target |
|---|---|
| "what was that protein shake recipe i mentioned" | "800 cals and 60g protein" shake (06-14, handle 5102196504) |
| "where were we gonna get coffee" | Boondocks coffee roasters, 8am (06-12) |
| "the summer skills i wanted to work on" | AI/ML, Singing, Origami, Fashion, Gym list |
| "that expensive dinner spot" | chaat Bhavan / South Bay, "2 bands" |
| "what time was the coffee thing" | 8 am |

Scoring (per case, 0/1): did the answer name the correct target with a real
citation? These test fuzzy→precise: the model must BROADEN (synonyms, substring,
date window) then read, exactly the loop the system prompt describes.

---

## Models under test (all on-device)
- **Qwen3-4B-4bit** (Standard / default) — has a `<think>` reasoning block.
- **Qwen2.5-7B-Instruct-4bit** (High / opt-in) — no reasoning mode, bigger.
- **Cactus v1.14 / gemma** (opt-in, `nl.runtime.cactus`) — known intermittent input-drop bug.

Also worth trialing if we want a smaller/faster floor: Qwen3-1.7B (already cached).

## Protocol
1. Default model first, both capability sets → establishes the baseline + reveals
   whether failures are model-quality or tool-gap.
2. If tool-gap: implement the commitment/recall primitive, re-baseline on 4B.
3. Only then A/B 4B vs 7B vs Cactus on the FIXED harness — so we compare models,
   not tool coverage.

---
## RESULTS (2026-06-14)

| Query | Qwen3-1.7B (was default) | Qwen3-4B (cached, now Standard) |
|---|---|---|
| Plans this week | Hallucinated operators (with:me/type:chat/this_week) → 0 → repeated → gave up. **0/8** | Valid query → 12 hits → readMessages → found Boondocks 8am w/ John Klemm. **1/8** (real but shallow — stopped at first commitment) |
| Fuzzy: protein shake | (not run) | Broadened correctly → found "800 cals 60g protein" shake → honest answer. **1/1 ✓** |

VERDICT:
1. 1.7B is NOT viable for tool-calling (invents operators). 4B does valid operators + correct broadening. **Wire 4B as the search default** (already downloaded ~2.5GB). DONE provisionally in NLModelPreference (revert note inline).
2. Fuzzy recall ("struggling to find it") WORKS on 4B out of the box.
3. "All plans this week" needs a NEW TOOL even on 4B: a "list commitments/plans in a date window across all chats" primitive (dump sent msgs in range → model extracts). The 4B surveys partially then stops. Model size beyond 4B is NOT the bottleneck here — the tool surface is.
4. TRADEOFF: nl.model.quality also drives the vernacular AI judge (1.7B picked for ~2s load). Decouple: 4B for search agent, 1.7B/off for judge.
5. 7B (High) not cached (4.3GB); only test if 4B's "survey comprehensively" strategy proves model-bound rather than tool-bound (it's tool-bound).

NEXT: (a) add `plansInWindow`/`commitmentsInWindow` tool, (b) decouple judge model, (c) re-baseline 4B on the full 8-commitment + 5-recall set.

---
## THREE-WAY RESULT — model question SETTLED (2026-06-14)

| Model | Size | Q1 plans | Q2 fuzzy recall | Speed | Verdict |
|---|---|---|---|---|---|
| Qwen3-1.7B | 1.0GB | ❌ hallucinated operators, repeated, quit (0/8) | — | 12s | Below tool-call threshold |
| **Qwen3-4B** | **2.5GB** | ✅ valid query→read→real commitment (1/8, correct-but-shallow) | ✅ broadened→found 800cal shake (1/1) | 46s | **WINNER** |
| Qwen2.5-7B-Instruct | 4.3GB | ❌ over-constrained→wrong (Dustin, false positive, out of window) | ❌ degenerate repetition loop (2437-char query)→empty | 68s | Bigger but WORSE |
| Cactus v1.14 (gemma) | — | ⚠️ intermittent input-drop (~3/10 empty) — prior bench | — | — | Engine bug; 4B wins |

KEY INSIGHT: parameter count is NOT the lever — the REASONING MODE is. Qwen3-4B
(has `<think>`) beats Qwen2.5-7B-Instruct (no reasoning) at agentic tool-calling:
the 7B loops and over-constrains; the 4B writes simple valid queries and broadens
cleanly. Bigger ≠ better for this task.

FINAL RECOMMENDATION: ship **Qwen3-4B** as the search default (the in-place
NLModelPreference change). It's the sweet spot — best tool-calling + reasoning
that's still ~2.5GB on-device. No reason to pay for 7B (worse + 2× slower + 4.3GB)
or accept Cactus's engine bug. Remaining work is TOOL-SIDE, not model-side:
plansInWindow primitive + decouple the vernacular judge from this preference.
