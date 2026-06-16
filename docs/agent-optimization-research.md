# Multi-turn agent optimization — research synthesis + backlog + test loop

Goal: make Hourglass's on-device NL-search agent (the ReAct loop in
`Sources/NL/NLAgentReAct.swift`, running Qwen3-4B-4bit) more reliable. Grounded
in (a) the failures observed this session and (b) online research on multi-turn
tool-calling agents (2025-2026).

## Our observed failures (the eval record)
1. **Operator hallucination** — 1.7B/7B emitted invalid query operators (`with:me`, `type:chat`, `this_week`) → 0 results → gave up.
2. **Temporal hallucination** — "since September" → `in:"2026-09-01..2026-06-16"` (future month + backwards range). "what plans this week" off by wrong window.
3. **Repetition loop** — 7B emitted a 2,437-char query (`protein shake|shake recipe|…` ×80) → empty answer.
4. **Wrong tool / shallow** — "friends made since September" → `topContacts` (returned OLDEST friends); "plans this week" stopped at the first commitment.

## Research → mechanism → fix (mapped to our failures)

| Failure | Research finding | Our fix (on-device, no fine-tune) |
|---|---|---|
| Operator hallucination (1) | Tool schemas in the prompt are "advisory, not grammar-enforced" — exactly our prose setup. Grammar-constrained decoding masks invalid tokens. Validation gates: "reject, fix, or escalate — no silent failures." | **Validate tool args against the REAL operator grammar; on invalid, return a corrective observation naming valid operators** (turn a silent 0-result into a self-correcting signal). Gold standard = constrained decoding (bigger lift, later). |
| Temporal (2) | Models "fabricate plausible calendar mappings"; relative-date accuracy drops 23-35% vs absolute; prompt-based fixes are "marginally effective"; ISO-timestamp augmentation + deterministic resolution help; only post-training (DPO) fully fixes it. | **Resolve relative dates deterministically in code** ("since September" → most-recent-past Sept; "this week"; "N weeks ago") and **validate/clamp the model's date range** (reject future-relative-to-today, reject start>end) with a corrective observation. Don't trust the model's date math. |
| Repetition loop (3) | Repetition is self-reinforcing once started; "clear SUCCESS/terminal states cut tool calls 7×"; restrict/penalize repeated calls; anti-repetition prompt instructions. | We already have a **repeat-call breaker** (keep). Add a **degenerate-query guard**: reject a query that is absurdly long or self-repeats a token N× → corrective observation. |
| Wrong tool / shallow (4) | Validation gates; clear tool routing; bounded enums; "typed inputs, bounded enums drive consistency." | Purpose tools (`plansInWindow` ✓, `friendsMadeSince` TODO) + **bounded-enum operator presentation** + routing hints in the prompt. |

## ⚠️ Key NEGATIVE finding — do NOT add self-reflection
Reflexion/self-critique only helps at ~70B+. "For smaller models, self-reflexion can result in MORE erroneous responses — the limited capacity makes them suspect their original CORRECT answers and generate wrong ones." We run a 4B model. **Prefer deterministic guardrails over asking the model to reflect.** This rules out a tempting but harmful direction.

Corollary (research): for tool-calling, "architecture/training matters more than parameter count" — Qwen-family 4B benches ~97% on tool calls, beating bigger non-reasoning models. Matches our eval (Qwen3-4B > Qwen2.5-7B). So the model is fine; the **harness** is the lever.

## Prioritized backlog (highest leverage first; all deterministic)
- [ ] **B1. Operator-validation gate.** Before running `search`/`countMatching`/`firstMatching`, parse the query; if it contains an unknown `key:` operator, return a corrective observation: "`X:` isn't a valid operator. Valid: with/from/to/in/last/before/after/on/type/reactions, | for OR, + for AND, *sub*." Don't run garbage.
- [ ] **B2. Date-range validation + relative resolution.** Reject/clamp future-relative-to-today and backwards ranges; resolve "since/last/this <unit>" deterministically; corrective observation on bad dates.
- [ ] **B3. Degenerate-query guard.** Reject queries > N chars or with a token repeated > K× → corrective observation ("query looks malformed; simplify").
- [ ] **B4. `friendsMadeSince` / `newContactsSince` tool** (contact-merged before/after-date volume split; excludes old friends w/ new handles — the Shreya case).
- [ ] **B5. Bounded-enum operator presentation** in the system prompt (tighten the catalog; generate from the `TokenPrefix` enum so prompt + parser can't drift).

## Test set (ground truth, for the loop to score against)
| Query | Type | Expected | Source |
|---|---|---|---|
| `Couldn't even tell u if venkat in that or not` | keyword | exactly 1 result (Atul's msg) | regression: apostrophe+OR fix |
| `what plans did I commit to this week` | agentic | ≥4 of {NY trip, summer skills, chaat bhavan, LG brunch, boondocks 8am, hao dinner, finals}; no hallucination | docs/nl-eval-grounded.md |
| `what was that protein shake recipe i mentioned` | agentic | names the "800 cal / 60g protein" shake | nl-eval-grounded.md |
| `who were the friends i made since september` | agentic | NEW people (Saketh/Justin/Gandharva); NOT Shreya/Venkat/Beck (old, new handles) | this session |
| `who did I text the most in 2026` | agentic | correct topContacts ranking | — |
| `how many photos did I send last month` | agentic | a count via countMatching/type:image | — |

## Running results log (the loop appends here)
<!-- each loop fire: date · query · model answer · score · failure mode · optimization applied -->
- 2026-06-16 · `Couldn't even tell u if venkat in that or not` (keyword) · 1 result (Atul) · **PASS** · regression guard for apostrophe+OR fix · optimization: none (harness validation)
