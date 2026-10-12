# Decision audit 2026-10-12 -- which shop choices does the engine get wrong?

**Method** (`tools/decision_audit.lua`, `_plan.py`, `.sh`, `_report.py`; hook `_G.BES_FORCE` in `sim/content.lua`):
for 157 seeds of the baseline arm `etag_7` (seed_off 7, HEAD `4a21056`), one shop visit sampled uniformly from the
run's visits is replayed exactly, with the engine's FIRST action there replaced by (a) its best-ranked alternative
purchase / reroll ("2"), or (b) leaving the shop ("save"; its third choice when it was leaving anyway). The engine
plays the rest of the run; common random numbers keep the world aligned. Outcome = progress (analyze_runs metric)
minus the baseline seed's. An unforced replay reproduces the baseline exactly (checked, seed 1007). 313 decisions.
ONE future per decision: the per-decision delta is noisy (a single changed shop can swing a run by +-5 antes), so
read the GROUPED means and sign counts, not single rows.

## Results (positive = the alternative beat the engine's choice)

| group | n | mean dprog (se) | alt better / worse / tied | wins +/- |
|---|---|---|---|---|
| all | 313 | +0.165 (0.093) | 116 / 85 / 112 | +31 / -34 |
| engine value gap < 2 (close calls) | 108 | **+0.354 (0.136)** | **43 / 13** / 52 | +12 / -6 |
| engine bought a PACK, antes 1-4 | 69 | **~+0.69 (~0.3)** | 33 / 19 | |
| ... Celestial pack (all antes) | 30 | +0.629 (0.288) | 16 / 6 | |
| ... Standard pack | 25 | +0.454 (0.249) | 8 / 4 | |
| ... Buffoon pack | 54 | +0.321 (0.257) | 15 / 14 | |
| ... Arcana pack | 28 | -0.023 (0.329) | 7 / 8 | |
| close calls where the engine picked a PACK | 52 | +0.367 (0.152) | 17 / 5 | |
| close calls where it picked a REROLL | 24 | -0.214 (0.322) | 9 / 2 | |
| engine bought a JOKER -> leave instead | 13 | -0.719 (0.629) | 5 / 7 | +0 / -3 |
| antes 5-8 (all) | 114 | ~+0.02 | 25 / 18 / 71 | |

**Reading.** The engine's first choice is not better than its own runner-up on average (+0.165, t 1.8); the gap is in
the CLOSE calls (its top pick loses 43 to 13) and in EARLY PACK buys (antes 1-4), worst for Celestial and Standard
packs. Joker buys hold up (replacing one with leaving costs -0.7). Late antes are nearly all ties.

**Two mechanisms consistent with this** (both make a pack look better than it is):
1. **Level pricing at today's share** -- every persistent level (planet cards, Celestial pools, Black Hole) was priced
   at the hand's CURRENT share of plays, though its later share is ~half (measured 2026-10-05, applied only to the
   Orbital tag). Fix built: `BES_LATER_SHARE=1` (`3543e56`), arm `lshare_7` running.
2. **Expected-max of noisy values** -- a pack / reroll is valued as the best of several noisily measured items, which
   is biased upward (the 2026-10-10 audit measured +11-18% on rerolls). Not yet addressed.

## Compared with the owner's play (8 expert runs, 7 wins, 2026-08) at ante start
| | owner | engine winners | engine losers |
|---|---|---|---|
| money a3 / a5 / a8 | $24 / $50 / $52 | $15 / $25 / $25 | $15 / $26 / $27 |
| jokers a2 / a3 | 1.4 / 3.9 | 3.0 / 4.6 | 2.8 / 4.4 |
| hand levels a8 | 18.6 | 13.1 | 12.3 |
| xmult jokers a4 / a8 | 1.5 / 2.9 | 0.9 / 1.7 | 0.6 / 1.2 |
Earlier direct copies (hoard lesions, forced xmult) failed, so these are symptoms; the audit points at the early
spending choices (packs) that the owner's banking avoids.
