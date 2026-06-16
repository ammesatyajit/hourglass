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
- [x] **B1. Operator-validation gate.** ✅ DONE 2026-06-16 (`operatorCorrection(for:)` in NLAgentReAct, gating search/countMatching/firstMatching). Catches (1) `key=value` arg-injection (`limit=40`, `in=all_time` stuffed into the query) and (2) unknown `key:` operators; returns a corrective observation derived from `TokenPrefix.allCases` (can't drift from the parser). Turned the protein-shake query FAIL→PASS.
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
- 2026-06-16 · `who were the friends i made since september` (agentic) · NOW calls friendsMadeSince + date-clamp fired (2026-09→2025-09); returned Saketh/Justin/Karen/Annika; Beck (1260 before) excluded after tightening · **PASS (was topContacts→old friends)** · failure: wrong-tool + temporal-hallucination · **B4 applied** (friendsMadeSince tool, contact-merged before/after split, future-date clamp, maxBefore=250 cap). B2 partially baked in (date clamp). Threshold for Karen/Annika unverified by operator.
- 2026-06-16 · `what plans did I commit to this week` (agentic) · NOW uses plansInWindow → 63 msgs in ONE observation → named 5 distinct plans w/ citations (Venkat flights/NY ✓, Amma hand-brace, Beck Thu, tower next week, Gandharva) · **PASS (was: stopped at 1 commitment)** · failure: shallow-survey (fixed) · optimization: none — plansInWindow verified working live (built earlier, now confirmed)
- 2026-06-16 · `how many photos did I send last month` (agentic) · 169 via `from:me type:image last:30d` (ROLLING 30d); strict calendar-May ground truth = 154 · **NEAR-PASS** (right tool + filters; rolling-30d vs calendar-month window) · failure: temporal — "last month" → rolling 30d not calendar May · optimization: DEFERRED (B2 calendar-month resolution; disk at 99% — rebuild risk; also a genuinely ambiguous phrase). Refinement: teach `last:1mo`/"last month" → previous calendar month (after:YYYY-MM-01 before:next-01).
- 2026-06-16 · `what was that protein shake recipe i mentioned` (agentic) · BEFORE: iter1 `protein shake recipe`→0; iter2 broadened to `…|dinner|food|eat limit=40 in=all_time` (args stuffed in query, swallowed silently)→49 junk dinner rows→"no details provided" (**FAIL**). AFTER B1: iter2 gate fired ("ARGUMENTS stuffed into the query text: limit=40, in=all_time")→iter3 self-corrected to `protein|shake`→30 matches, [0]=the 800cal/60g shake→"800 calories and 60g protein", hero_index=0 ✓ · **FAIL→PASS** · failure: operator/arg-injection (silent) · **B1 applied** (`operatorCorrection` gate; corrective's worked example also nudged dropping the poisoning "recipe" term). Residual: synthesis added unrelated "protein bar/skyr" (precision, not operators).
- 2026-06-16 · `who did I text the most in 2026` (agentic) · iter1 `topContacts {in:2026-01-01..2026-12-31,limit:5}` → Beck Peterson 20,853 (10,227 sent/10,626 recv), Annika 7.9k, Venkat 5.4k → iter2 "Beck Peterson the most." Ground truth (raw chat.db): top 1:1 handle +15102196504 = 20,142 (= Beck's phone; next 1:1 only 8,095), Beck's email handle separately 2,304 → contact-merge → Beck clearly #1. · **PASS** · clean 2-turn: right tool + calendar-year range + contact-merge all correct. No failure → no optimization. (Note: range 2026-01-01..2026-12-31 is partly future but harmless — no data after today; B2 not needed here.)
