# NEXT_SESSION.md — handoff & plan of action (2026-07-01)

Read this first, then `CLAUDE.md` (esp. "THE WALL" + the self-play loop) and the
`selfplay-system-plan` memory (running log, rounds 1–15). This file is the current
state, what's been tried, and exactly what to do next.

## TL;DR
The engine is a pure Balatro decision-advisor, tuned by a **headless self-play sim** that drives the
REAL engine through whole runs. Baseline mean death-ante is now **3.513** (n=80, `sim_out/scorer2.jsonl`),
up from 3.000 — real cumulative progress — but still **0 wins**.

**⚠ THE CEILING IS NOW MAPPED (read before tuning). A sharp boundary governs what works:**
- **Additive re-ranks with NO extra spend WORK** — the big win was `first-scorer` (+0.163: when the board
  has no flat/xmult scorer it can't score at all, so boost a flat scorer; a pure joker-vs-joker re-rank).
- **Anything that shifts SPENDING or DAMPS backfires — every time** (leveling-need -0.051, coupled
  consistency pair -0.063, swap-damp -0.075, first-xmult -0.051, base-gate/scaler-condition/level-use
  no-op). The leveling one is the proof: it *worked* mechanically (+57% planets, helped ante 4) but lost
  at ante 2 because buying leveling = not buying early power.
- **The structural reason:** the engine is resource-constrained (dies ante 3-4), so every $ invested in
  leveling/shaping/early-scaling trades away the survival it needs to mature. The human wins did BOTH
  power AND heavy leveling because they had economy headroom (skill/luck). **Winning needs an EARLY
  STRATEGIC COMMITMENT (pick an archetype, accept early weakness, invest) that a greedy per-decision
  value engine structurally resists — that's the ARCHITECTURAL ceiling, not a missing constant.** The
  real next step is a **committed-archetype planner**, not another valuation tweak. Fidelity fixes
  (below) are the other proven source of gains (the sim was under-rewarding the engine).

**THREE REAL WINS ANALYZED, THREE DISTINCT ARCHETYPES** (see `winning-archetype-from-real-run` memory):
(1) H129ZGT1 — Flush House + Duo/Trio + deck-shaping + heavy leveling; (2) 81XB8PIN — Hologram +
Brainstorm(copier) + Duo/Trio + heavy leveling (Two Pair→12); (3) IRXRZRWV (an ACTUAL completed win) —
economy (Bull + To the Moon → $106 → chips) + Trio/Tribe xmult, leveling NOT relied on. **The common
thread across all three: an XMULT STACK (Duo/Trio/Tribe/Hologram) that the human KEPT — never churned.**
The "fuel" varies (leveling vs economy vs deck-shaping) but the winning core is always xmult + not
dismantling it. The engine VALUES these pieces correctly (it valued Hologram 600%, Bull 333%) but
repeatedly advised SELLING them for junk — the recurring flaw (fixed sim-neutrally by `6008829`).

**BUT — reframe (2026-07-01):** after making deck-shaping fully functional + measurable (deck-mutation
fidelity, below), forcing the engine to build flushes did NOT improve survival — the sim dies at ante
2-3, too early for a shaped build to mature. So the archetype is the ANTE-5+ win condition, but the
current blocker is **EARLY BUILD STRENGTH (antes 1-3)**. Consistency/deck-shaping is shelved until the
engine reliably reaches ante 5+. See "THE DIAGNOSIS — REFRAMED" below.

## The loop (how to work)
```
bash tools/sim_par.sh <n> <name>          # PARALLEL batch across all cores -> sim_out/<name>.jsonl (~6min/n40, ~12min/n80)
lua  tools/analyze_runs.lua sim_out/<name>.jsonl [trace [seed]]   # death histogram, VARIANCE-vs-BUILD split, per-ante, counterfactual, per-hand trace
lua  tests/runner.lua                      # 702 unit tests (must stay green); add a regression per fix
luajit tests/runner_sim.lua                # 69 sim integration tests
```
- **Determinism is fixed** (sorted-key sampling + stable tie-breaks). A seed is byte-identical across
  processes → parallel batches are exact, and A/B is trustworthy. NEVER trust n=40 (it's noise — it
  burned us twice: cost-discount and A1 both looked good at n=40, both flat/negative at n=80).
  **USE n≥80 for every verdict.**
- **Reference baseline (CURRENT):** `sim_out/scorer2.jsonl` (n=80, mean **3.513**) — committed engine on
  the faithful world. Compare new changes vs `scorer2`. (History: base80 2.862 → after_b1 3.000 →
  after_keep 3.100 → deckmut 3.212 → projdamp 3.250 → econmoney 3.350 → firstscorer 3.475 → scorer2
  3.513. This multi-session arc moved the baseline **+0.65 / ~23%** over base80, +0.51 over after_b1.)
- **#1 backfire signal:** median $/ante collapsing. Economy-safe changes never backfire; economy-
  disturbing ones do (the session's biggest lesson).
- Rich telemetry: `blind_result` per-hand play log, VARIANCE-vs-BUILD death split, per-offer shop
  values, skip decisions. Use `trace <seed>` to read a run's actual decisions.

## Current git state
Branch `joker-coverage-and-engine-fixes`. Committed this session:
- `7553f72` determinism + parallelism + telemetry + skip-tag valuation
- `7efa517` build-planning layer (engine/build_plan.lua)
- `42851f3` core-protection (don't sell xmult/scaling)
- `e125364` UI (native left-bar recommendation panel)
- `bdc0a1c` B1 leveling axis
- `3bb9cb3` scorer-protection (tiered `BP.keep_bias`: protect flat scorers too, not just the core)
- `95af713` **deck-MUTATION fidelity** (sim world now applies suit/enhancement tarots → deck shapes;
  → 3.212). Unblocked deck-shaping measurement.
- `33c20fa` **pace-gated scaling projection** (don't value scalers at grown potential when you'll die
  to the near boss; ante 2-3 build-death fix) → 3.250.
- `5132c54` **econ-joker money** (sim world now pays owned jokers' $/round; fidelity correction) → 3.350.
- `6008829` **anti-churn on swaps** (don't sell a CORE piece for a lateral upgrade; require beating its
  keep_bias). SIM-NEUTRAL (3.350 — core-sells happen ante 5+, past the death-ante mode) but validated by
  all 3 real wins as a live-advice correctness fix; economy-safe. Revisit its sim value at ante 5+.
- `7199317` rank + thinning tarot fidelity (Strength/Death/Hanged Man) — NEUTRAL (3.325), kept as fidelity.
- `0f8a329` **FIRST-SCORER priority** (+0.125): a board with NO flat/xmult scorer can't score and dies
  regardless of play (36% of ante-2 deaths were scorer-less: {vampire}, {throwback,luchador}...). When
  scorer-less, boost a FLAT immediate scorer. ADDITIVE-only → no backfire. ante-1 deaths 14→10. → 3.475.
- `a74e421` **graduate first-scorer to the 2nd scorer** (+0.038, survivors carry ~2 flat scorers). → 3.513.
  THE WINNING PATTERN this session: additive priority when the board LACKS a needed piece (never a
  spending/suppression change) — economy-safe, doesn't backfire like the scaler DAMPS did.

Tree is CLEAN — nothing uncommitted. Reference batches in `sim_out/`: `base80` (2.862), `after_b1`
(3.000), `after_keep` (**3.100**, current committed engine).

NOTE: engine changes this session are **sim-side (repo) only** — NOT deployed to the live install
(`%APPDATA%\Balatro\Mods\balatroenginesim\`), except the UI. To make the live advisor match, re-sync
the changed `engine/*.lua` (see CLAUDE.md deploy note).

## What actually helped (kept, economy-safe, small but real, n=80)
- **Core-protection** (don't sell xmult/scaling): xmult keep-rate 57%→80%, xmult/board 0.35→0.54,
  +0.10 death-ante. The real mover.
- **B1 leveling axis** (`BP.level_amplifier`: planets/Celestial worth ~board-multiplier× more once a
  core exists): +24% leveling acquisition, +0.038.
- **Scorer-protection** (tiered `BP.keep_bias`: flat scorers protected too, not just the core):
  flat-scorer keep-rate 30%→42%, **+0.10** (3.000→3.100). Came straight from the seed-13003 trace —
  the trace-driven approach found a real fix where sim-guessing had stalled.
- Earlier: skip-tag power valuation (take free Rare jokers / Orbital), SELL_TO_BUY last-joker guard.

## ⚠ PHASE-3 UPDATE (2026-07-06) — the graveyard was RE-LITIGATED at n=160 paired on the FAITHFUL world
The "do NOT repeat" list below was written against the OLD (broken) world + unpaired n=80 (noise). After
the WINRATE_AUDIT world-fidelity + valuation fixes (Phases 1-2), the graveyard was re-run PAIRED at n=160
(see WINRATE_AUDIT.md §5). **A residual cross-process non-determinism was also found & fixed — every prior
batch carried ~1/80-seed noise; n=160 paired is now byte-exact.** New verdicts SUPERSEDE the entries below:
- **leveling-need — FLIPPED to a (small) positive (+0.012 n.s.), SHIPPED.** The backfire is GONE on the
  faithful world (leveling↑, money flat-to-up, early deaths do NOT rise). It's the additive-when-lacking
  shape, core-gated + tapered. Committed. This is the one graveyard lever that flipped.
- **coupled pair / flush-commitment / leveling-alignment — STILL REFUTED, sharper reason.** A greedy
  per-tarot commitment credit can't ASSEMBLE a shaped deck (suit tarots offer-rate-limited; marginal flips
  just cascade RNG — the biggest "win" was a Soul-cascade, not a flush). Not per-decision-fixable → needs
  the committed-archetype PLANNER. Do NOT re-try as a valuation credit.
- **"delete the scaler damps" — TESTED & REFUTED.** Removing `proj_damp` = −0.004 wash + breaks guardrails.
  proj_damp (pace) + scale_trigger_factor (trigger-freq) are legitimate survival-timing gates; KEEP them.
  The reverted round-19/20 damps stay OUT (doubly-wrong now that A1 grows scalers). Do NOT re-add either.

## What was TRIED and FAILED — do NOT repeat  (⚠ leveling-need entry below is SUPERSEDED — see Phase-3 update above)
- **A1 pacing recalibration** — negative at n=80 (drained economy + leveling for 0 gain). Lesson:
  making the engine *know* it's behind doesn't help if the response isn't productive.
- **A2 copiers (Blueprint)** — unmeasurable (6 offers/80 runs); Blueprint is already `is_xmult`.
- **B3 slice-1 (committed-hand joker credit)** — no-op (target hand is often a high-value hand few
  jokers tag).
- **Shop-buy lookahead/MCTS** — no-op even at dominating weight: the greedy value + build_plan already
  pick the rollout-optimal joker, and no available buy meaningfully changes boss-survival for weak
  builds. **Conclusion: the shop-BUY-among-offered decision is NOT the lever.** (But the lookahead only
  covered direct buys — swaps/sells/packs were never rollout-checked; those are where mistakes happen.)
- **cost-discount-when-behind, flat xmult-floor** — backfired (bought power too early / drained
  economy → earlier deaths).
- **Leveling ALIGNMENT (round 16)** — weighted `best_planet` argmax by the board's hand-specific
  multipliers so leveling CONCENTRATES on the amplified hand. Economy-safe. n=80: 3.075 vs 3.100 = FLAT.
  Lesson: leveling-concentration ALONE is a no-op — the deck isn't SHAPED to make the hand fire. Reverted.
- **FLUSH COMMITMENT (round 18)** — credited suit tarots by the compounding payoff of a reliable leveled
  flush. At ship weight: no-op; PROBE at 5× bootstrapped real flush-building but death-ante FLAT and
  ante-1 deaths ROSE. Deck-shaping is functional + measurable but doesn't help survival (deaths too early
  to mature). Reverted.
- **Round 16-22 reverts (2026-07-05, do NOT repeat — the "damps/spend-shifts backfire" evidence):**
  base-gate (no-op), level-use-credit 0.15→0.35 (byte-identical no-op — engine already uses held
  planets), **swap-damp** (extend pace-damp to the swap/SELL_TO_BUY path via jp_from_measure: **-0.075**,
  over-suppresses good scaler upgrades), **first-xmult** (boost xmult when board has base but none:
  **-0.051** with the `cat=="xmult"` bug that missed `xmult_scaling`; **neutral -0.013** once corrected to
  `is_xmult` — redundant with build_plan), **scaler-condition-discount** (discount unfeedable scalers'
  projection: no-op — swapping one weak buy for another), **coupled consistency pair** (flush-commit +
  leveling-alignment together, the theoretically-strongest combination: **-0.063** — deck genuinely
  shaped but the tempo/economy cost sinks it), **leveling-need** (additive Celestial/planet bonus when
  core+low-levels: **-0.051** — mechanism worked, +57% planets, helped ante 4, but lost ante 2 because
  leveling costs $ = a spend-shift). **PATTERN: pure re-ranks (no spend) help; anything spend-shifting or
  damping backfires. Don't retry these as valuation tweaks — the fix is architectural (see TL;DR).**

## THE DIAGNOSIS — REFRAMED (2026-07-01): EARLY build strength, not late consistency
Two death modes coexist: a MODE at **ante 2-3 (BUILD deaths — the deck/board is just too weak)** and a
tail at ante 5-6 (variance deaths, e.g. the traced seed 13003 that scored 24,733 then crashed to 8,307).
The **flush-commitment probe settled which one binds:** with deck-mutation now faithful, forcing the
engine to build reliable flushes (acquisition 1→14) did NOT move death-ante (3.200 vs 3.212) and even
raised ante-1 deaths — because **the sim dies at ante 2-3, too early for any shaping/consistency play to
mature into the ante-5+ powerhouse the human win showed.** So consistency/deck-shaping is a REAL,
now-measurable capability but it is NOT the current lever. **The binding constraint is EARLY BUILD
STRENGTH (surviving antes 1-3).** This matches the pace data (on-pace% collapses by ante 2-3). The
consistency work (deck-shaping/committed-hand) is shelved until the engine reliably reaches ante 5+.

## ANTE 2-3 BUILD DEATH — DIAGNOSED (2026-07-01)
Survivor-vs-death board contrast at ante 2: dying boards carry ~3× the ungrown SCALERS and HALF the
flat scorers (scale 0.41 vs 0.14, flat 0.69 vs 1.34). Cause (traces seed 1003/79003): the engine values
scalers at their ante-8 GROWN potential (Supernova 14.9, Onyx 27.6) and buys/swaps into them, but at
ante 2-3 they're barely grown and the boss is NOW. **FIX SHIPPED** (`33c20fa`, baseline → **3.250**):
`SA.proj_damp` pace-gates the scaling projection (full only on-pace; behind 0.65×, urgent 0.30×). A
follow-up base-gate (also damp when no immediate scorers) was a NO-OP (3.237) — reverted.
**Second real win run (81XB8PIN) sharpened the next lever:** the engine's BUY valuation is GOOD (it
valued Hologram 600%, recommended it) — the gaps are (a) it UNDER-LEVELS massively (sim uses ~0.5
planets/run, hand-lv 0 through ante 3; the human leveled Two Pair to 12), and (b) it churns the CORE
(advised selling Brainstorm/Trio for junk). See [[winning-archetype-from-real-run]].

## THE ANTE-4 WALL (2026-07-05, current mode) + WHY VALUATION FIXES CAN'T BREAK IT
Baseline `scorer2` 3.513: deaths peak at **ante 4** (a1=10 a2=15 a3=11 **a4=22** a5=14 a6=7). Ante-4
death boards are NOT scorer-less and NOT xmult-less (73% have xmult, 91% a flat scorer) — they're full of
**condition-locked xmult-scalers that never grew** (Throwback per-skip, Constellation per-planet, Lucky
Cat per-lucky, Vampire per-destroy; `scale_trigger_factor` only discounts HAND-triggered scalers).
**But the fix does NOT live in valuation** — this was tested exhaustively (round 20-22): discounting the
unfeedable scalers is a no-op (swaps one weak buy for another), and getting the engine to level/shape
instead backfires (leveling-need -0.051, coupled -0.063) because those cost money it needs to survive.

## THE REAL NEXT STEP: a COMMITTED-ARCHETYPE PLANNER (architectural, not a tweak)
The ceiling is architectural (see TL;DR): a greedy per-decision value engine can't make the EARLY
COMMITMENT the human wins used (pick flush / leveling / economy-xmult by ante 2, accept early weakness,
invest through it) because each individual invest-when-weak decision correctly *looks* worse in the
moment, and forcing it via valuation = a spend-shift that backfires. To break 3.5 you likely need a
STATEFUL planner that (a) commits to one archetype early from deck+jokers+levels, (b) holds it through
the early dip, (c) drives shaping + leveling + joker-credit ONE direction, and (d) is measured on whether
it reaches ante 6+ (not just per-blind survival). This is the next-generation design; `engine/build_plan`
+ `engine/deck_plan` are the scaffolding to build it on. Don't re-attempt the reverted valuation levers.

## STILL-OPEN, PROVEN-SAFE work (fidelity — the OTHER source of gains; the sim was under-rewarding)
- **`sim/world.lua` deck-mutation is INCOMPLETE:** modeled = suit/enh/rank/thin tarots + planets + econ-
  joker money. Still UNMODELED = spectral deck effects, money-tarot $ (Hermit/Temperance), **copier-econ
  doubling** (Brainstorm copying Reserved Parking — the user's money farm), and the **consumable-pool
  dedup** (holding a planet blocks another copy — see `sim-world-fidelity-gap` memory). Each faithful
  fix is a candidate correction like deck-mutation (+0.11) / econ-money (+0.10). These are the
  lowest-risk remaining gains.
- **#1 next input if the user plays more:** more win/loss traces in `bes_runs.jsonl` — the three analyzed
  wins were the highest-signal input of the whole effort.

## Guardrails (learned the hard way)
- **THE BIG ONE:** additive re-ranks with NO extra spend can help (first-scorer +0.163); DAMPS and
  SPEND-SHIFTS backfire every single time (swap-damp, leveling-need, coupled, cost-discount, xmult-floor).
  If a change makes the engine spend more or value something less, expect it to lose — don't ship on a
  hunch, and don't re-try the reverted list above.
- Measure-first: it repeatedly overturned premises. Before building, measure whether the lever is real.
- n≥80 only. Watch median $/ante. Full fidelity (no `_G.BES_MC_CAP`). Green tests + a regression per fix.
- The greedy per-decision valuation is already good at *individual* picks (and in-blind PLAY is verified
  optimal — Mad-only clears the ante-2 boss ~80%); the remaining ceiling is STRATEGIC COMMITMENT (the
  build you commit to early), which needs a stateful planner, not per-buy tuning. Fidelity fixes are the
  other proven, low-risk source of gains.
