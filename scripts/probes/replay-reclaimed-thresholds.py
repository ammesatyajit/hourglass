#!/usr/bin/env python3
"""Replay the reclaimed-words classifier tail OFFLINE against the adjacency
dump a bench run leaves behind (/tmp/hourglass-reclaimed-adjacency.json,
written by ReclaimedContextClassifier when HOURGLASS_PANEL_BENCH is set).

The dump carries the RAW ingredients per candidate — pre-affinity slang rate,
topic rate, raw affinity cosine, partner adjacency counts — so any threshold
combination (verdict, affinity ramp, fold, compound-drop) can be evaluated in
milliseconds instead of re-running the 10+-minute extraction.

Examples:
  # current defaults
  ./replay-reclaimed-thresholds.py
  # find the cone-saving hard-tier exemption
  ./replay-reclaimed-thresholds.py --hard-protect-margin 0.40
  # see what a lower mutual fold threshold would do to holy+bang
  ./replay-reclaimed-thresholds.py --fold-share 0.4 --mutual-factor 0.5
"""
import argparse
import json
import sys

def smoothstep(x, floor, ceil):
    span = max(ceil - floor, 0.01)
    t = max(0.0, min(1.0, (x - floor) / span))
    return t * t * (3 - 2 * t)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dump", default="/tmp/hourglass-reclaimed-adjacency.json")
    p.add_argument("--keep-threshold", type=float, default=0.10)
    p.add_argument("--affinity-floor", type=float, default=0.30)
    p.add_argument("--affinity-ceil", type=float, default=0.60)
    p.add_argument("--affinity-boost", type=float, default=0.22)
    p.add_argument("--fold-share", type=float, default=0.5)
    p.add_argument("--mutual-factor", type=float, default=0.66,
                   help="mutual-partner fold threshold = max(0.30, fold_share * this)")
    p.add_argument("--compound-drop-share", type=float, default=0.6)
    p.add_argument("--hard-share", type=float, default=0.8,
                   help="compound share at/above which the word dies regardless of margin")
    p.add_argument("--protect-margin", type=float, default=0.25,
                   help="keep margin that protects in the [compound-drop, hard) band")
    p.add_argument("--hard-protect-margin", type=float, default=None,
                   help="if set: margin at/above which even the hard tier is survived")
    p.add_argument("--min-uses", type=int, default=None,
                   help="ADMISSION gate replay: drop candidates with userMessages below this (needs a floor-gate dump)")
    p.add_argument("--min-world-eff", type=float, default=None,
                   help="ADMISSION gate replay: drop candidates with worldEff below this (needs a floor-gate dump)")
    p.add_argument("--watch", default="",
                   help="comma-separated surfaces to report gate fates for (e.g. gang,twin,sheesh)")
    p.add_argument("--limit", type=int, default=20)
    args = p.parse_args()

    with open(args.dump) as f:
        payload = json.load(f)
    rows = payload["candidates"]

    # ── admission-gate replay (works on floor-gate dumps that include the
    #    gate-input fields userMessages/worldEff) ─────────────────────────
    watch = [w.strip() for w in args.watch.split(",") if w.strip()]
    if args.min_uses is not None or args.min_world_eff is not None:
        admitted = []
        for r in rows:
            uses_ok = args.min_uses is None or r.get("userMessages", 0) >= args.min_uses
            world_ok = args.min_world_eff is None or r.get("worldEff", 0.0) >= args.min_world_eff
            if uses_ok and world_ok:
                admitted.append(r)
            elif r["surface"] in watch:
                why = []
                if not uses_ok:
                    why.append(f"uses {r.get('userMessages',0)} < {args.min_uses}")
                if not world_ok:
                    why.append(f"worldEff {r.get('worldEff',0.0):.2f} < {args.min_world_eff}")
                print(f"  GATE-KILL {r['surface']}: {', '.join(why)}")
        rows = admitted
    for w in watch:
        hit = next((r for r in rows if r["surface"] == w), None)
        if hit:
            print(f"  WATCH {w}: uses={hit.get('userMessages','?')} worldEff={hit.get('worldEff',0.0):.2f} "
                  f"pct={hit.get('percentile',0.0):.2f} roleSkew={hit.get('roleSkew',0.0):.2f} "
                  f"margin={hit.get('keepMargin',0.0):+.2f} verdict={hit.get('verdict','?')}")
        else:
            print(f"  WATCH {w}: NOT IN DUMP (gated before ranking, or below candidateLimit)")

    by_surface = {r["surface"]: r for r in rows}

    # ── verdicts (replayed with the chosen affinity ramp) ──────────────
    for r in rows:
        addend = args.affinity_boost * smoothstep(
            r["affinityCosine"], args.affinity_floor, args.affinity_ceil)
        r["replayMargin"] = min(1.0, r["slangRateRaw"] + addend) - r["topicRate"]
        r["replayKeep"] = r["replayMargin"] >= args.keep_threshold

    kept = [r for r in rows if r["replayKeep"]]
    kept_surfaces = {r["surface"] for r in kept}
    considered_surfaces = set(by_surface)

    # ── fold / demote ───────────────────────────────────────────────────
    consumed, out, actions = set(), [], []
    for r in kept:
        s = r["surface"]
        if s in consumed:
            continue
        partner = r["partner"]
        total = r["windowCount"]
        if not partner or total == 0:
            out.append(r)
            continue
        share = (r["adjBefore"] + r["adjAfter"]) / total
        partner_row = by_surface.get(partner)
        mutual = bool(partner_row) and partner_row.get("partner") == s
        fold_threshold = max(0.30, args.fold_share * args.mutual_factor) if mutual else args.fold_share

        if partner in considered_surfaces and partner not in consumed and share >= fold_threshold:
            surface = f"{partner} {s}" if r["adjBefore"] >= r["adjAfter"] else f"{s} {partner}"
            folded = dict(r)
            folded["surface"] = surface
            folded["score"] = max(r["score"], partner_row["score"] if partner_row else 0)
            out.append(folded)
            consumed.update({s, partner})
            actions.append(f"FOLD  {s} + {partner} → \"{surface}\" (share {share:.2f}{' mutual' if mutual else ''})")
        elif partner not in considered_surfaces and share >= args.compound_drop_share:
            hard = share >= args.hard_share
            protected = (r["replayMargin"] >= args.protect_margin and not hard) or (
                hard and args.hard_protect_margin is not None
                and r["replayMargin"] >= args.hard_protect_margin)
            if protected:
                out.append(r)
                actions.append(f"PROTECT {s} (share {share:.2f}, margin {r['replayMargin']:+.2f})")
            else:
                consumed.add(s)
                actions.append(f"DROP  {s} (compound \"{partner} {s}\", share {share:.2f}, margin {r['replayMargin']:+.2f})")
        else:
            out.append(r)

    out.sort(key=lambda r: (-r["score"], r["surface"]))
    print(f"== actions ==")
    for a in actions:
        print(f"  {a}")
    print(f"== kept list (top {args.limit}) ==")
    for i, r in enumerate(out[: args.limit], 1):
        print(f"  #{i:02d} {r['score']:.3f} margin{r['replayMargin']:+.2f} {r['surface']}")
    # quick expectations check
    surfaces = {r["surface"] for r in out}
    for want in ("cone", "aura", "cooked"):
        mark = "✓" if any(want in s for s in surfaces) else "✗"
        print(f"  expect {want}: {mark}")
    for nowant in ("lag",):
        mark = "✓" if not any(s == nowant for s in surfaces) else "✗"
        print(f"  expect no bare {nowant}: {mark}")

if __name__ == "__main__":
    sys.exit(main())
