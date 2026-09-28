# CLAUDE.md — working context for AI assistants

Project guide for anyone (human or AI) editing this repo. See `README.md` for the
feature-level overview and `DESIGN.md` for the original (historical) design baseline.
Despite the historical filename, this guide applies equally to Codex and other coding agents.

## What this is

`balatroenginesim` is a **Balatro decision-assistant mod** (LÖVE2D / Lua, Steamodded
+ Lovely). It reads live game state from the global `G`, evaluates every legal
action, and overlays a ranked "best move" with a reason. Roadmap M1–M4 is complete
plus a large correctness/coverage/strategy pass.

> ### ⭐⭐ THE SHARPEST DIAGNOSTIC THIS PROJECT HAS (2026-09-04, `ADVICE_REVIEW.md` R8) — USE IT FIRST.
> **A live misplay can now be traced from board state → valuation → the exact line of code, because the mod
> records both the run and the DECISION STATE.** The loop, in four steps:
> 1. owner reports a misplay → find the run in **`bes_runs.jsonl`** (in the LÖVE save folder, `%APPDATA%/Balatro/`)
>    — `joker_gain`/`joker_loss`/`death` records give the board over time and the death stats;
> 2. pull the matching decision from **`bes_fixtures.jsonl`**, which stores the FULL `gs` at every shop/pack
>    decision (`core/replay_fixture.lua` writes it);
> 3. **replay that `gs` through the current engine** (`SA.recommend(gs, {})`, `Eval.joker_marginal_fv`, …) and
>    watch it reproduce the misplay on the real state;
> 4. fix, and re-replay the same fixture to prove the advice changed.
>
> R8 used exactly this to convert *"it sold Greedy for a To Do List"* into two located defects and a verified
> fix in one session. **It beats reasoning from a synthetic board, which is how the same session's first
> attempt at that diagnosis went wrong** — a hand-built reconstruction picked a different funder and its
> "only Mult" measurement was invalid because the sampled hand contained no Diamonds at all. **Replay the
> recorded state; do not rebuild it from the description.**
>
> ### ⭐⭐⭐⭐⭐ LATEST (2026-09-28): install `42a867f` — best-trade swap shipped (pooled 320 seeds: wins 86->100, 26.9%->31.3%; OOS +4); `main` synced. R17 — `b76d453` (unattended runs via F6; live pack-pick fixes; ⭐ live dies on BIG blinds 6/9 vs sim 20%, p 0.003 — see NEXT_SESSION R17). R16 — `d399bbc` (R15 + pre-deal pack gate + shop planet-use + Black Hole credit + no-flat audit batch 1 with measured use rates + Overstock v2 + retrigger-aware Gold seal). R14 live review — engine `f22edfc`, CONFIRMED vs old live in the corrected sim: 32->38/160 in-sample, 28->49/160 OOS (p 0.022); read the R14 block atop `NEXT_SESSION.md`.
> ### (previous) 2026-09-25: read the "START HERE" block of `NEXT_SESSION.md` — live install `0ed0a6d`,
> ### sim win rate 22.5% (36/160, was 6.2% on 09-23), the win-rate checkpoint table, and the prioritised next sessions.
> ### Every joker is now MEASURED except Mr Bones / Diet Cola / Credit Card; forward valuation ON; the tier floor STAYS.
> ### (previous) 2026-09-24: R12 inert jokers + measured core protection + Burnt Joker, on top of R11 — read the TOP
> ### blocks of `NEXT_SESSION.md` first. ⚠ The tier floor is NOT removable wholesale (sim wins 28->15): it scales measured
> ### jokers against tier-PRIOR (unmodelled) ones; only INERT jokers (measured exactly 0) lose it.
> ### R11 sell/buy valuation overhaul:
> Shipped + deployed: held-card context bug, money-only jokers, survival-first selling, effect-based vouchers,
> calibrated pace risk, live interest-cap fix, and live pack/shop fixes. **Owner rule: the 7-win corpus is the
> owner's playstyle, not ground truth — sim OUTCOMES (wins/reach-8) decide; replicate on fresh seeds.** Run A/B
> arms sequentially at ≤9 workers (memory reaping). Unit tests: plain `lua tests/runner.lua` (1264 pass).
>
> ### ⭐ CURRENT FOCUS (2026-08-31): ADVICE QUALITY, driven by the IN-GAME SELF-PLAYER + owner review + the AGREEMENT A/B.
> **The in-game self-player** (`ui/autoplay.lua`, **F11**) translates the engine's live advice into REAL
> Balatro inputs and plays whole runs unattended — a real-game bug-finder for the overlay. The owner watches
> its runs and reports misplays; I fix them and, for economy/valuation changes, **MEASURE on the frozen 7-win
> agreement corpus** (`tools/agreement_run.sh`) before keeping — the durable, non-ceilinged ruler. **Read
> `NEXT_SESSION.md` top block FIRST** (**2026-09-05: THE "MEASURE, DON'T USE CONSTANTS" ARC IS COMPLETE + the
> two clearest in-blind live bugs are fixed.** SHIPPED this arc: **ALL 31 scalers measured** (0 tier
> fall-throughs) via a unified EVENT-FED model (`Eval.event_fed_forward`); **ALL 18 spectrals measured** (Tier
> 1 Black Hole/seals/Sigil + Tier 2 Soul/Cryptid/Aura/add-group); **the PLAY CHOOSER is now CARD-ORDER-AWARE**
> (`best_play_target` re-judges the top subsets at their best card order when Hanging Chad/Photograph/xmult
> present — corpus BLIND agree +1.0pp; was order-blind, a real death); **Business Card feeds the in-blind money
> model** (was `VALUE_ONLY` → $0 to the tier-2 money tie-break); **Vagabond value is econ-aware**
> (`Generators.fire_rate` — fires only ≤$4). Earlier R6–R8: Ectoplasm priced properly + `CV.hand_size_cost`
> (`175b5c4`); a generator with nowhere to put its output is no longer "live" (`b21aa57`).
> ⛔ OPEN, deliberately deferred with reasons: **the last-unconditional-Mult sale guard** (R8 #4) is the HARD
> §31f board-as-a-SET problem — the leave-one-out marginal is ACCURATE; the gap is worst-case-hand board
> collapse, which needs SET-scoring, NOT a magnitude/guard hack (the research fork); and **the self-player
> never reorders CARDS** (`ui/autoplay.lua`, live-only — must execute the chooser's reorder; the sim already
> does). Earlier 2026-09-01: the MEASURED-SCALER VALUATION owner directive (tiers are a legacy fallback);
> earlier 2026-08-31: in-blind play fixes + Hologram feed + the econ floor).
> ⭐ TWO lessons from this loop: (1) the winners DIG hard (discard 57% vs the
> engine's 41%) — but a uniform dig bias was REFUTED by the corpus (it digs where the human PLAYED; the gap
> is SITUATIONAL commit-to-a-line, the build-commitment wall). (2) the ante-aware econ floor (hold the
> interest buffer, stop the single-digit spiral) was CONFIRMED (agree_save +20). **A live-run misplay is a
> hypothesis; the corpus says keep or revert.** Earlier: the first loop DEBUNKED the joker-churn hypothesis
> (run-length confound). The mod advises a **human who wins ~87.5%**;
> autonomous winrate is *ceilinged* (compute/data-bound — see below). Advice quality is a **different,
> non-compute-bound** objective, and the prior session's work is all there:
> - **`ADVICE_REVIEW.md`** — the owner's live-run decision observations + the fixes shipped (anti-churn
>   SELL_TO_BUY gate, active money-dig, Hermit-use, pack-first, planet-picks, debuff discard, UX).
> - **`JOKER_FIDELITY_AUDIT.md`** — the sim was **flattering the engine** (paying jokers a flat `econ`
>   $/round they never earn). 25/26 jokers now faithfully modelled; **the faithful sim HALVED the winrate
>   5.0% → 2.5%**, proving the old number inflated. The sim now measures what the overlay faces.
> - **In-blind econ system** — `engine/discard_fuel.lua` (discard channel: Faceless/Mail/Trading + scaler
>   feed + a Ramen/Green-Joker **harm guard**) and `engine/hold_fuel.lua` (hold channel: Reserved
>   Parking/gold by playing minimal to HOLD econ cards; held $ credited in the survival rollout), plus an
>   **aggressive farm** (break the winner when `survive_after` confirms a re-clear). Measured SAFE +
>   sim-NEUTRAL. **The winrate wall is CONVERSION (money → directed build), not econ generation** — the
>   open frontier. Read `NEXT_SESSION.md` first for the full handoff.

**The AUTONOMOUS-WINRATE ceiling (historical, still true):** every per-decision / present-state / economy /
product-board / learned-objective lever is closed or bounded; the MCTS/search investigation (`MCTS_PLAN.md`,
`GRAND_AUDIT.md`) reached a **well-confirmed ceiling** — the gap is POLICY not supply (Phase 0a: 70–92% of
lost runs were offered the winning pieces and passed), but the value function is the wall and it is
compute/data-bound beyond available local compute. Consolidated at the ceiling; the live objective is now
advice quality (above).

## Architecture (one rule: the engine is PURE)

Data flows one way: `core/state_extraction` (the **only** file that reads `G`) →
`model/game_state` POD → `engine/*` (pure functions) → `ui/*` overlay. Every engine
module consumes plain Lua tables and never touches `G`, which is what makes the whole
thing **headless-testable**. See the Layout section in `README.md` for the per-file map.

## Build / test / run

- **Tool index:** `tools/README.md` — 31 analysis tools grouped by the QUESTION each answers.
  Read it before writing a new one; most read existing telemetry and cost nothing to run.
- **Tests (do this after every change):** `lua tests/runner.lua` (run via the Bash
  tool). Lua 5.1+/LuaJIT, no `love`/`G`/Steamodded needed. Currently **1278 pass** (+ 605 sim, all green 2026-09-27).
  Failures print `FAIL  <case>  (got X, want Y)`; exit code is non-zero on failure.
  ⚠ **Two known, pre-existing conditions — don't mistake either for a regression you caused:**
  (1) the sim suite's standing failures are gone (2026-09-26: the CORE-PROTECTED pack-swap test was restated for
  the R13 swap-at-the-shop-bar rule; all 605 pass) -- a sim-suite FAIL is now a real regression; (2) `tests/test_shop.lua` calls
  `table.unpack` (~line 1048), which is **nil under LuaJIT**, so that suite aborts there if you run it
  standalone with `luajit`. It is fine under `lua tests/runner.lua`, which is how it is meant to run.
- **Phase-1 simulator suites are SEPARATE** (they drive the real engine per hand and
  take minutes): `luajit tests/runner_sim.lua` (`test_world`, `test_driver`, `test_consumables`, `test_content_rates`, …). `luajit`
  is installed and ~2.5x faster — prefer it for anything that runs the `sim/` forward
  simulator (`World.play_blind` / `Driver.run`).
- **Deploy to the live game (manual copy — the repo is NOT the install):** the running
  mod lives at `%APPDATA%/Balatro/Mods/balatroenginesim/`. After editing, copy changed
  files there or the game won't see them. Green tests ≠ works in-game.
- **In-game debug keys:** `F7` dump owned jokers' live `ability` tables (to the console
  and to `bes_joker_dump.txt` in the LÖVE save folder, each tagged
  `scored`/`value-only`/`UNCOVERED`); `F8` force a re-evaluation; `F9` toggle the overlay;
  `F10` capture-only toggle (log decisions, no eval); **`F11` AUTO-PLAY toggle** (the self-player,
  `ui/autoplay.lua`, default OFF — plays whole runs; logs to `bes_autoplay.log`); **`F6` AUTO-RESTART toggle** (default OFF — with
  auto-play on, a finished run (game over / win) is restarted via the game's hold-R path after 4 s, so runs chain
  unattended). The panel shows a live `Self-play: ON/OFF   Auto-restart: ON/OFF` row.

## Self-play simulator & data-driven tuning (THE current workflow — read this)

The engine is tuned by running a **headless self-play simulator** that drives the REAL engine
through whole runs, then analysing where/why it dies and fixing the cause. This is the primary
way to improve the engine now. Plans/history: **`WINRATE_AUDIT.md`** (the authoritative audit + roadmap
+ implementation logs) and the `selfplay-system-plan`
memory (running log of every fix + the open blockers).

### The simulator (`sim/`) — built, calibrated
- `sim/world.lua` — the "referee": faithful in-blind play (seeded shuffle → deal → REAL
  `decision_engine` each hand → `hand_eval` scoring), boss **min-ante gating** (ante 1 = the 8
  easy bosses only; Wall/Flint/Needle 2+; source: balatrowiki/Blinds_and_Antes), Mr Bones,
  economy + ante advance. `sim/content.lua` — shop/pack generation (rarity-weighted, editions,
  vouchers, packs, reroll scaling) + **skip-tag economy** (Investment etc.) + the **action trace**
  (every buy/sell/skip + the engine's per-offer VALUE). `sim/driver.lua` — the run loop, emitting
  the SAME JSONL record shapes as live telemetry.
- **Fidelity rule:** the world models RULES only (the FACTS layer: `mechanics`/`hand_eval`/
  `boss_effect`); the engine-under-test is the only thing using the OPINION layer. Every odd is
  `-- VERIFY`-tagged. Calibrated against real `bes_runs` death-ante (same range; reproduces the
  real failure modes). Don't make the world "smarter" — fix the ENGINE.

### Running batches + reading the data (the loop)
```
bash tools/sim_par.sh <n_seeds> <name>             # PARALLEL (all cores) -> sim_out/<name>.jsonl  [PREFER THIS]
luajit tools/sim_batch.lua <n_seeds> <name>        # single-core -> sim_out/<name>.jsonl, live [k/N] progress
lua  tools/analyze_runs.lua sim_out/<name>.jsonl   # death-ante histogram, per-ante trajectory,
                                                   #   ENGINE ACTION SUMMARY + COUNTERFACTUAL
lua  tools/analyze_runs.lua sim_out/<name>.jsonl trace [seed]   # one run's blow-by-blow timeline
```
- **Run FULL FIDELITY** (no `mc_cap` arg). The `_G.BES_MC_CAP` cheap-path **distorts** decisions
  (cap=3 degrades in-blind play → too harsh); only for rough scans.
- **SPEED — SOLVED by PARALLELISM (2026-07-01).** ~95s/run single-core → ~60 min for n=40. `tools/sim_par.sh`
  shards the seeds across all cores (one LuaJIT process each, interleaved) and merges the JSONL, so n=40
  drops to **~6–8 min on 12 cores** (~10×). This is EXACT (no distortion) and only became safe once the
  sim was made cross-process deterministic (sorted-key sampling + stable tie-breaks — see the determinism
  fix); merged parallel output is byte-identical to sequential. `sim_batch.lua` gained `[shard nshards]`
  args for it. (The old idea of a per-call deck-signature MC cache is now moot — parallelism is the win.)
- **What to read in `analyze_runs`:** the **death-ante histogram** (push the mode later);
  **per-ante trajectory** ($ / jokers / **hand-lv** / pace_margin / run_str); **ENGINE ACTION
  SUMMARY** (what it bought / SOLD / **SKIPPED** = offered-but-not-taken, packs, rerolls,
  level-ups); **COUNTERFACTUAL** (avg tier bought vs skipped + strong jokers skipped). Tiers there
  are a **superficial fallback flag only** — the real signal is the MEASURED valuation and, at
  scale, survival-correlation. Use `trace` to see the actual buy→sell churn / skip sequence.
- **n matters:** at n≈16 the death-ante is pure noise; use **n ≥ 40** to call a shift real. Now that
  the sim is deterministic, a re-run of the same seeds+engine is byte-identical, so A/B is finally clean.
  **Deterministic baseline (n=40, `sim_out/det_baseline.jsonl`):** death-ante a1=6 a2=13 a3=7 a4=7 a5=4
  a6=2 a7=1 (mean ≈ 3.0), **13 VARIANCE / 27 BUILD** deaths — the reference a fix is judged against.
  (The old 2.78 baseline was a PRE-determinism-fix, cross-process-noisy engine — do not use it.)

### Shipped engine fixes (most also deployed to the install; identical sim↔game)
Economy floor (`SA.ECON_FLOOR*` — don't spend to $0); anti-churn (`shop_advisor` `cash_matters =
dead` — only cash-sell a DEAD joker; `SA.UPGRADE_MARGIN` + current-value gate — don't swap a
working board for an unfed scaler); reroll discipline; last-hand DISCARD when discards remain
(Needle); **chips-scaler read** (`joker_effects.scaled` MAXes `ability`+`ability.extra` — F7
confirmed Runner/Wee accumulate in `extra.chips`); Wraith money-wipe; tarot won't overwrite an
enhancement; **boardless first-shop** (`skip_advisor` shop value scales as the board empties);
**use held planets proactively** (`decision_engine` `DE.LEVEL_USE_CREDIT`); leveling-acquisition
(`CV.level_persist` shared by standalone planets + Celestial packs); **SELL_TO_BUY last-joker guard**
(never sell your only board joker to fund a non-joker — it's lost); **skip-tag power valuation**
(`engine/tags` — free Rare/Uncommon/Top-up jokers valued by the MEASURED joker, tier-floored + slot-
gated; Orbital `×level_persist`), so the engine finally takes free jokers/leveling via skips.
**2026-08-14 fixes:** the **currency bridge** (`VU.BASE_FRAC` 0.03→0.06 = `DOLLAR_UTIL/FRAC_UTIL`, so a
dollar costs the same in the shop and inside a pack — this is **B3**, reverted in July on a baseline
measurement and resurrected at the operating point, §9); the **economy model** (`Eval.econ_value` is now
deck-aware and probability-aware, and `jp_to_fv` actually consults it — it never did, so deck-aware econ
had never reached a buy/sell decision); and the **SELL_TO_BUY refill charge** (selling a joker to fund a
NON-joker frees a slot the engine demonstrably refills, so charge `TYPICAL_JOKER_COST` against the cash
raised — the purchase price is sunk, the refill is not).

**2026-08-13 fixes:** a **game-breaking OOM** — `each_subset` allocated a scoring table per subset
(218 at hand size 8, 2379 at 13) and `best_play` runs ~80×/decision, so a large hand exhausted LuaJIT's
heap and soft-locked a live run (`decide failed: not enough memory`); `HandEval.HAND_BUDGET = 8` bounds
enumeration ABOVE 8 only (sim byte-identical at ≤8) and `main.lua` steps the GC per evaluation.
**The Fool** was valued at its flat 0.30 prior with nothing to copy, because `pack_open_advisor`'s
copy-target search runs AFTER selection — `CV.fool_target` now zeroes it pre-sort (an in-pack target
only counts when `picks_left >= 2`). Live telemetry gained `blind_select`, `blind_result`
(hands/discards actually SPENT) and per-option `ranked` valuations.
⚠ **THE INSTALL IS NOW BEHIND THE REPO BY 9 FILES** — see the deploy table in `NEXT_SESSION.md`,
which splits them by which verdict gates each. Two are unconditional live fixes; the rest wait.
(The install was **CURRENT as of the mid-2026-08-14 sync** — verified
file-by-file: all 42 mod files match the repo and the six re-deployed engine files parse cleanly.
The sync had drifted by SIX files, not the three the day's fixes touched — `build_plan`,
`decision_engine` and `discard_value` were also stale — so **diff the whole tree against the install,
don't copy just the files you edited.** A pre-deploy backup is at
`%APPDATA%/Balatro/bes_install_backup_20260814` — note it is deliberately OUTSIDE `Mods/`, since a
copy left inside `Mods/` would be loaded by Steamodded as a second, conflicting instance of the mod.)

### ⭐ LATE 2026-08-14 — A UNIT ERROR IN THE LEVELING CHANNEL (read `WINRATE_V3_PLAN.md` §12)

**`CV.level_gain` priced a hand level against the hand's own BASE chips/mult, then every caller
divided that by `boss_per_hand_need` — the TOTAL a hand must reach.** Same class as the dollar unit
error in 82f808f. Measured against the real scorer over **19 board/hand cases**, the base-only
figure understates a level by **1.3–1.5× bare / 4.5–9.4× on a typical ante-3 board / 10.3–19.3× with
one ×3 xmult** — the error **grows with board strength**, inverted from what a core-building engine
needs. Fixed exactly (`dchips*M + dmult*X*C + dchips*dmult*X`, using board context that
`hand_frequencies` already computed and discarded); verified to <1% including stacked xmults,
polychrome editions and Glass-card decks.

**It resolves an apparent contradiction in the existing findings.** The error is a near-uniform
factor ACROSS hands, so it leaves the argmax intact while destroying the magnitude — exactly the
split already recorded: §5s "planets are the one channel where engine and winner agree exactly"
(*which* hand — unaffected) vs §5z "Celestial priced −0.79, bought 6.3%" (*whether* to buy —
destroyed). **One bug, both symptoms.** Celestial pool value 0.084 → 0.429 on real ante-3 boards.

**⭐ VERDICT (§13–§16): it is an OPERATING-POINT lever, not a baseline one.** Paired n=160 per arm:

| | baseline income | **`rich10`** |
|---|---|---|
| the delta (commitment + correction) | −0.076 (p 0.585) | **+0.421 (t 2.35, p 0.019)** ✅ |
| sign test | 82 / 67 | **84 / 57 (p 0.029)** ✅ |
| winrate | 1.9% → 0.6% | **18.8% → 26.2%** |

**Interaction +0.497, t 2.19, p ≈ 0.028 — and the prediction was recorded BEFORE the batch ran.**
§6's original demonstration was a six-commit bundle read after the fact; this one *predicted*.

**Why it inverts (§15b), measured end to end.** The correction converts money → levels. At baseline
the engine has no *spare* money, so what it converts is its **first-joker** money — ante-2 board 2.48
vs 2.99, **ante-2 deaths +50%**, gain cancelled. At `rich10` it converts spare money instead, keeps
its board (4.43 vs 4.52 — a 2% difference), and reaches **15.67 hand levels by ante 8 against the
human's 18.6**, with ante-4 deaths falling 32 → 18.
⚠ **The live mod sits at the `rich10` end** — it advises a *human*, and the human dataset has them
**2–4× richer than the engine at every ante**. So the correction is a *ship* on the operating point
that actually matters for the overlay, even though it is worth zero on the sim's.

### ❌ AND A COUNTER-EXAMPLE WORTH MORE THAN THE FIX: the readiness gate (§14, §17)

A board-readiness gate ("buy the base first, then level it") was built to fix the baseline cost, and
**it did exactly what it was designed to do** — ante-2 deaths **21 → 16**, ante-2 board
**2.48 → 2.77**, ante-6 reach restored, leveling preserved. The full 2×2:

| gate effect | baseline | `rich10` |
|---|---|---|
| progress Δ | +0.116 (p 0.286) | −0.165 (p 0.284) |
| sign test | **39 / 43** | **35 / 34** |

**Null at both operating points, means pointing opposite ways, sign tests against-to-even.
REVERTED** (a magnitude change introducing constants needs positive evidence; on mechanism, there
is no opportunity cost to avoid at `rich10`, so damping there is pure loss).

**⭐ The finding is not the revert — it is that the mechanism worked and did NOT convert.** Closing a
precisely-diagnosed behavioural gap moved nothing. File it beside §5m's "capability without intent
changes nothing" and the indiscriminate dig: **a measured behavioural gap is not a lever until the
metric says so.**

**✅ SHIPPED on its own merit: the play-derived commitment** (§11, §13). +0.049 at p 0.092 with
**131 of 160 seeds TIED** (sd 0.372 → MDE 0.082) — a small positive on the most precise measurement
class this apparatus produces. 63% of runs never committed before; now 71%. Feasibility class.

**Two more findings that stand on their own:**
* **⭐ THE WINNERS' BOARDS ARE HAND-AGNOSTIC.** Human wins acquire only **8.7%** handtype-tagged
  jokers (engine 13.3%, same denominator); Hanging Chad / Photograph / Sock and Buskin carry no
  handtype tag at all. **So widening the tag set is a dead end — there is nothing to widen.** But
  those same winners level HUMBLE hands hard (Pair 18 of 32 levels in one win) and **70% of their
  leveling happens after ante 4**; the single loss has 4 levels against wins of 7–41.
* **✅ The "silent zeros" live-key risk is CLOSED** (`tools/key_coverage.lua`): 147 distinct real
  in-game keys across all captures, **0 catalogue misses**. The only non-Legendary key never seen is
  `j_gluttonous_joker` — the correctly-spelled alias the game never emits. Alias strategy confirmed.

**🛑 PROCESS, learned the hard way today:**
1. **Run every A/B arm from a git worktree, never the tree you are editing.** An arm was silently
   contaminated — its workers started 2 minutes after an engine edit, so it tested two changes
   against a baseline with neither. Module code is read at `require` time, i.e. at worker start.
2. **Killing the wrapper does not kill the workers, and `TaskStop` killed neither** — the script
   resumed with its next arm 12 minutes later. Detect quiescence from the FILES.
3. **A nil argument fails silently in Lua.** The level_gain fix missed the free in-pack channel
   **twice** (a nil global once, a caller-scoped upvalue once). Neither errors. **Verify a threading
   change by MEASURING the value, not by reading the diff.**
4. **A measured value near zero can mean the measurement never fired.** At the default 12 samples,
   comparing card enhancements returned identical values because the added card never landed in the
   sampled hand — which reads exactly like "the engine can't tell them apart".

### CURRENT STATE (2026-08-21, §31e) — **8 expert HUMAN runs captured, 7 wins**; engine ~3.1% at
### BASELINE, the TRUE operating point (the engine must generate its OWN money — rich10 is a diagnostic
### ceiling only, NOT what the live mod serves; see `rich10-is-not-the-operating-point`). §29
### `growth_factor` is ✅ KEPT: reverted at rich10 (tail sheds) but re-measured at BASELINE (n=320)
### it is +0.111 (p 0.25) and IMPROVES the tail (reach-7 +8, reach-8 +5) — moves runs DEEPER.
### ⭐ THE WALL MOVED from pace to ENDGAME POWER: more runs reach ante 8 but DIE there under-levelled
### (~12 hand-levels vs the human's ~18.6), holding ~$27 unspent into the final boss. The gap
### accumulates over antes 3–7; no ante-8 action saves it (endgame reroll-damp built + reverted, §30a).
### ⭐⭐ OPTION 3 DONE + SHIPPED (§30d): the rollout is money-aware (survive_after returns money+banked;
### baseline byte-identical) + a MILK lever — LIVE. Milk is sim-neutral (+0.032) because the sim engine's
### decks lack the gold-seal density to milk; the in-blind economy gap is a LEAF of deck-shaping.
### ⭐⭐ (a) MULTI-STEP PLANNER BUILT + CLOSED ON MECHANISM (§31c–e). Every reachable lever on the 24%
### over-buy — 1-step lookahead (§31c: an income-asymmetry ARTIFACT), pack-aware lookahead (artifact),
### depth-3 economy search (§31d: fires 0; buying dominates additive capacity when money isn't binding,
### and the econ floor already saves when it is). ⇒ the over-buy is NOT economic — it's SUPERMODULAR,
### target-directed banking (the win condition is a PRODUCT; an additive marginal can't represent it),
### exactly what `oracle_plan` (a perfect target) measured NULL (§24).
### ⭐ §31e — THE PER-DECISION/ADDITIVE-LEVER FAMILY IS EXHAUSTED. **This is NOT "3% is acceptable" — the
### win target is unchanged; a whole CLASS is ruled out, which REDIRECTS the work to a RESEARCH problem:**
### (1) score the board as a SET (copiers×xmult×triggers as a PRODUCT, not a sum of marginals); (2) a
### target as a SET of pieces-to-assemble + slot reservation (the pairing oracle_plan never tried). The
### work continues on (1)+(2); the apparatus (agreement.py, blind_outcome, replay/lookahead diagnostics)
### is the durable asset that makes them well-posed. Retained: Option 3 fidelity+milk (live), §29 pacing.
### ⭐ §31f (2026-08-24) — THE RESEARCH FORK IS BOUNDED (not built) BY A CHEAP HUMAN-DATA PROBE.
### `tools/supermodular_headroom.lua` classifies jokers MULTIPLIER (copier|xmult|retrigger) vs ADDITIVE.
### H1 (payoff) confirmed HARD: winning boards **86% multiplier**, kept-rate **77% vs 13%**. H2 (over-buy):
### additive over-buy 57% vs multiplier 29%, concentrated in **flat_chips 76% / scaling_mult 80%**; a
### role-only flip is +7/57% (too blunt), a {flat_chips,scaling_mult} buy-bar +12/77% (post-hoc n=22 —
### SIM-verdict it, don't ship; §17 caveat). Engine is NOT purely additive (`BP.is_core`/`BP.fit`/
### `level_amplifier` exist) ⇒ dir-1 = two RETUNES: demote scaling_mult from `BP.is_core`; weight
### flat_chips dilution > flat_mult. Naive dir-2 REFUTED (post-save next-joker multiplier 37% < 41% base;
### winners get multipliers via packs/tags/later shops).
### ⭐ §31g — THE BUY-BAR WAS SIM-TESTED → BASELINE NULL. Built {flat_chips,scaling_mult} damp in `BP.fit`,
### paired n=159: +0.036 (p 0.158 n.s.), 144 tied, wins 4→4. Mechanism explains it: the damp barely fired
### (flat_chips 122→118) and declines went to OTHER ADDITIVES (flat_mult 218→224), NOT multipliers — the
### shop lacks the multiplier the human builds toward. ⇒ dir-1 present-board damp CONFIRMED INSUFFICIENT;
### the real lever is the multi-channel dir-2 target. Buy-bar reverted (worktree only).
### ⚠️ §32a RETRACTS §32 (below): §32's "pack EV already rises +23%" was a MEASUREMENT ERROR (passed the
### pack key as a STRING → P.size_of mis-read it as a CARD pack). Corrected: the real Buffoon pv is FLAT
### across board states in HEAD (0.690 bare / 0.689 core-deficit) — the completion primitive is NOT already
### present, so the target model is NON-REDUNDANT. Built it (BP.completion_credit gated on needs_xmult,
### hooked into Buffoon pack EV + joker tags).
### ⭐ §32b — THE TARGET MODEL CONVERTS AT rich10 (the operating-point signature, like B3/level_gain):
### baseline income NULL (−0.009, p 0.866, sign 7/7) but rich10 **+0.067 (p 0.065), sign 9/2 (p 0.070),
### wins 39→43**, with ASYMMETRIC swings (gains +4.71/+2.80 vs losses ≤0.64). Interaction +0.076. A
### SUGGESTIVE-POSITIVE in-sample (p 0.065, sign 9/2). §32c OUT-OF-SAMPLE (BES_SEED_OFF=7): DID NOT REPLICATE
### — Δ+0.039 (p 0.519), sign 6/7 EVEN, symmetric ±5 chaos. Pooled +0.060 (p≈0.055, +6 wins/320) is a fragile
### MEAN carried by big-win flips, sign-test-null OOS = winner's-curse (the B3 lesson). ⇒ NOT a proven lever,
### REVERTED (worktree-only). Stands: zero baseline harm + sound human-aligned mechanism (chase multiplier
### packs/tags when core-deficit) = a defensible LIVE-ADVICE option, NOT a demonstrated winrate win. §32a
### retraction still vindicated (direction was real enough to warrant the 4 arms). Arms on disk:
### sim_out/{base,tgt,baser,tgtr,baser7,tgtr7}_31f.jsonl. Frontier stays operating-point economy (pack×income).
### ↓ THE §32 CLAIM BELOW IS FALSIFIED — kept only for the audit trail:
### ⭐ §32 — DIR-2 (THE TARGET MODEL) IS CLOSED ON MECHANISM (scoped before building, the §31d rule). The
### completion primitive is ALREADY in the valuation: `Packs.value(Buffoon)` rises 0.353→0.433 (+23%) on a
### core-deficit board because `joker_pool` MEASURES sampled jokers against your real board — a completion
### credit would be inert. H3: the completion interaction is only a WEAK signal in the human data (ROLE
### dominates). §5s/§5z: engine prices offered multipliers ~right; under-opens packs for CURRENCY reasons.
### ⇒ the target-model axis is WRONG; the residual gap is income/throughput at the operating point (§6/§18,
### where the live mod already sits). The one open thread: pack-throughput × income INTERACTION (§5z
### richpack suggestive) — an economy investigation, NOT a per-decision/target build. Both the additive-
### family and the target-family are now exhausted; the frontier is operating-point economy.

**➡ THE authoritative status is now `GRAND_AUDIT.md`** (2026-08-25) — a ground-up re-derivation +
section scorecard + ranked forward plans that re-establishes (and in places overturns) the conclusions
below. **Read it FIRST.** It supersedes the *navigation* role of the docs below but preserves them as the
audit trail: `docs/archive/WINRATE_V3_PLAN.md` §32 (then §31/§6/§30/§18) is the detailed checkpoint every
`GRAND_AUDIT` citation resolves into; fresh-session handoff: `NEXT_SESSION.md`; historical audit + roadmap:
`docs/archive/WINRATE_AUDIT.md`; superseded plans: `docs/archive/`. (The `WINRATE_*` docs were moved to
`docs/archive/` on 2026-08-26; a bare `WINRATE_V3_PLAN.md §X` reference elsewhere in this file resolves there.)
**The MCTS/search investigation is complete — see `MCTS_PLAN.md`: the winrate ceiling is POLICY not supply
(Phase 0a), but is not closable with the current apparatus — the value function is the wall and it is
compute/data-bound beyond a few nights of local compute (quadruply confirmed). Consolidated at the ceiling.**
_Key `GRAND_AUDIT` corrections to the block below: (1) the level_gain "+0.421 rich10" is UNCONFIRMED
(never OOS-replicated, same profile as the target model that failed OOS) — treat as correctness-only until
re-run; (2) "converts at rich10 in-sample" is NOT a reliable ship signal (B3 weak-OOS, level_gain untested,
target-model OOS-fail); (3) the current-code operating-point gap is 2.5%→24–32% (robust); (4) the biggest
tractable un-probed lever is SLOT-EXPANSION valuation (+3 slots = +0.984); (5) the scripted-expert ceiling
re-confirms valuation EARNS ITS KEEP (engine 2.5% vs expert 0.6%)._

> ### ⭐ §24 — ARCHETYPE PLANNING IS CLOSED, at BOTH operating points
> A perfect deck-frequency plan handed to the engine free from ante 1, at `rich10`: progress
> **−0.165 (p 0.228)**, sign **47/52**, wins **42 → 40** (McNemar p 0.860) — **replicating** the 41/40
> measured at baseline. It **executed** (commitment in 577/577 ante-states vs 622/828). So the gap is
> not the engine failing to know what to build. **NOT closed: search over the SHOP STREAM** — a
> different object; its cheapest slice (slot reservation, `MCTS_PLAN.md` INC-1) was bounded by
> `ecap3rich` (§28) and **REFUTED before being built** (below).
> **⚠ §6 is a filter, not a wand:** 5 changes re-measured at `rich10` — 2 converted (B3, level_gain,
> both *valuation*), 3 did not (readiness gate, oracle, **`ecap3` early board cap**, all *policy/
> behaviour*).
>
> ### ❌❌ §28 — EARLY BOARD DISCIPLINE IS REFUTED, HARDER AT `rich10`
> `ecap3rich` (board ≤3 jokers through ante 2, **plus** +$10/round) vs `pacefix`, paired n=160:
> progress **−0.945 (t −4.85, p < 0.0001)**, wins **45 → 24** (McNemar p 0.0065), tail collapsing at
> every level. **5.6× more negative at `rich10` than baseline** — opposite of §22's prediction. My §22
> reasoning was wrong: `rich10`'s exogenous +$10/round did NOT close the harm channel (capped engine
> still ends ante 2 with HALF the money, $4.8 vs $9.9) because the harm channel is **board power
> itself**, which produces money AND survival jointly. **Refinement to §6: the operating-point
> argument holds only when the point SUPPLIES the thing the lesion removes — "income" is not one
> thing.** ⇒ the human's empty ante-2 board is a CONSEQUENCE of their play, not a cause; **INC-1 slot
> reservation is dead unbuilt** — the second search-adjacent direction closed after §24.
>
> ### 🧭 §18, in four lines
> * **§5u is REVISED.** Its *"wrong SIZE by 1–2 orders of magnitude; do not open another single-lever
>   arm"* was computed at baseline income. At `rich10` the gap is **1.36 sd, not 2.47**, and the two
>   levers shipped since sum to **≈0.47 sd — twice the whole prior arc.** Tuning is not exhausted there.
> * **The level_gain correction IS the pack-throughput fix** (§5z closed): packs/ante +18%/+22%,
>   rerolls −16%, Orbital tags 23→59, Meteor 0→39 — behaviour three lesion configs were built to test.
> * **⭐ Behaviour and payoff are SEPARABLE.** Identical behaviour change paid +0.421 at one operating
>   point and −0.076 at the other. **"The mechanism fired" is a SCREEN, never evidence of value.**
> * **Both baselines are on disk** and HEAD is verified identical to `pd_play_r` — every A/B costs
>   **ONE** arm: `rich10` `sim_out/pd_play_r.jsonl` · baseline `sim_out/lg_both_c.jsonl`.

> ## ⭐⭐ READ THIS BEFORE RUNNING OR JUDGING ANY BATCH (2026-08-14, `WINRATE_V3_PLAN.md` §6)
> **THE BASELINE IS A BROKEN INSTRUMENT.** The *identical* six-commit engine delta
> (`e7c3a8c`→`82f808f`), on the *same* seeds, measured at two operating points:
>
> | operating point | code delta | p | wins | sign test |
> |---|---|---|---|---|
> | **baseline income** | **−0.102** | 0.65 (n.s.) | 1 → 2 / 80 | **32 / 34 — dead even** |
> | **+$10/round** (`rich10`) | **+0.730** | **0.0018** | **6 → 12 / 80** | 46 / 26 (p 0.025) |
>
> **Interaction: +0.832, SE 0.324, t = 2.57, p = 0.0102.** Same code. Same seeds. The only
> difference is whether the engine had money to act on its preferences — it holds **$1.3 at ante 2**
> at baseline. A valuation fix changes what the engine *prefers*, and preference is unmeasurable
> when it cannot afford to act. Testing valuation at baseline income is testing a car's handling
> with an empty tank.
>
> **DO:** judge valuation changes with a `BES_PROBE=rich10` arm (same cost, ~8× the winrate
> headroom: 15% vs 2.5%). Keep baseline as the honest headline number; it is a poor *instrument*.
> **⚠ BUT "measure at rich10" is NOT a universal upgrade — ASK WHAT THE CHANGE IS ABOUT FIRST.**
> Pick the operating point that CONTAINS the mechanism. The two fixes shipped 2026-08-14 are exact
> mirrors and prove the point:
>
> | fix | prices | baseline | `rich10` |
> |---|---|---|---|
> | **B3** (`BASE_FRAC` 0.03→0.06) | the value of MONEY | −0.102 (inert) | **+0.518** (p 0.0011) |
> | **SELL_TO_BUY refill charge** | the cost of POVERTY-driven churn | **+0.096** | −0.034 (**95% of seeds tied**) |
>
> B3 needs money to EXPRESS; the refill charge only FIRES when poor (SELL_TO_BUY runs 1.25/run at
> baseline vs **0.12/run** at rich10 — a funded engine never enters the sell-to-afford spiral).
> **Measuring the refill charge only at `rich10` would have discarded it.** A fix whose subject is
> scarcity must be measured under scarcity.
> ❌ **"The revert graveyard was populated almost entirely by baseline nulls" — THAT IS FALSE, and it
> was checked item by item (§19a).** swap-damp/cost-discount were **directly measured** (−0.004,
> **145 tied**, and they broke two guardrail tests — they fight the world's real `joker_tick`);
> xmult-floor is refuted on **mechanism** (§5o: winners are xmult-POOR early, front-loading xmult is
> what LOSING runs do); C1 is obsolete, W-ECON hits the frequency ceiling, the reroll gate went on
> mechanism, and F3/F4/F8 are **in-blind** — money does not help you play a hand.
> **Exactly TWO items were ever reverted on an underpowered baseline null: B3 (retested, +0.518) and
> E-12 (retested 2026-08-14, §19).** The graveyard is now empty; do not go shopping in it again.
> ⚠ **And read the TIE COUNT before calling a null underpowered** — 145/153/127 ties mean a low sd
> and therefore a LOW MDE. Those are the project's most trustworthy nulls, not its least.
> **DON'T** conclude "logical fix, no effect" from a baseline null ever again. That verdict has been
> the project's central mystery and it is substantially a measurement artifact.
> ⚠ Caveats: the bundle is six commits; the two deltas share a seed family so the interaction SE is
> approximate; the gain is broad and EARLY (rich10 deaths in antes 1–3 fall 20→7), not a tail artifact.
>
> **✅ ISOLATED + REPLICATED (§9): it is substantially ONE CONSTANT — B3.** `VU.BASE_FRAC` 0.03→0.06
> (reverted in July on a baseline −0.245) measures **+0.518 pooled over TWO disjoint seed pools
> (SE 0.159, t 3.26, p 0.0011)** at `rich10`, against **−0.102** at baseline — interaction
> **+0.620, t 2.26, p 0.0238**. That is the size of the project's whole historical retained arc.
> Its mechanism is measured, not guessed: it makes the engine **skip 25% fewer blinds** (correcting
> the ~2× tag over-valuation the audit itself named) and reallocates toward packs/Celestials/planets
> at **unchanged dollars held**.
> ⚠ **Do NOT quote "B3 doubles the winrate."** The in-sample 6→12 wins did NOT replicate (disjoint
> pool: 6 vs 6 discordant, dead null; combined McNemar p 0.286). And the in-sample progress figure
> (+0.672) was inflated by **winner's curse** — B3 was chosen for testing because the bundle
> containing it looked good on that same pool. **Always replicate a selected lever out-of-sample.**

**THE DATASET IS THE HEADLINE.** `data/bes_runs_live_2026-08-12.jsonl` — the mod's own user played 8
runs (red deck / white stake) with the **overlay hidden (F9)** so their choices are independent of the
engine, while every recommendation was logged beside them. **7 wins in 8 runs (87.5%) vs the engine's
1.25%** (12 in 960 sim runs), across **seven distinct winning archetypes**, with winning hand-levels
from **7 to 40**. There is no single winning shape. One joker appears in all seven wins: **Hanging
Chad**; Photograph 5/7, Sock and Buskin 3/7 — retriggers and conditional xmult, not raw tier.
Telemetry carries 1046 shop / 415 pack / 189 blind_select / 114 blind_result records and **928+
entries pairing the engine's measured value for each option against what the human actually did**.

**THE SEQUENCING INVERTS, SIGNIFICANTLY (`tools/real_vs_sim.lua`).** The human is 2–4× richer at every
ante ($7.5 vs $1.0 at a2, p 0.009) **and levels LESS than the engine early** (a2–a3, p<0.01), then
crosses over at a4 and finishes on 3–4× the levels (a8: 15 vs 4.5, p 0.009). Economy and base first,
power second. ⚠ This does NOT reopen the world-fidelity verdict: that compared mixed-outcome real runs
to mixed-outcome sim runs. This is near-all-wins vs mixed, so it measures **policy, not world**.

**THE LOSS IS THE MOST INFORMATIVE RUN.** X3L32ZEA died at ante 5 holding **$52 — more than most of
the wins had** — on a scattered board with hand-levels stuck at 0 through ante 4. The player: *"despite
having so much econ i couldnt find anything which boosted my build or gave it direction."* Resources
were not the constraint, **conversion** was — the engine's own failure mode, executed once by a human.

Sim baseline (current code, paired n=480): **progress 3.744**, `sim_out/dig_base_all.jsonl`.
Verdict standard remains **PAIRED n≥160**; compare with `analyze_runs.lua <A> compare <B>`.

**THE #1 TUNING RULE — REVISED 2026-08-11. The old rule ("ship correctness freely; revert ANY lever
that doesn't measure positive") was half right, and the wrong half has been quietly deciding most
keep/revert calls by coin flip.** Read this before reverting anything.

**The power problem, in the project's own numbers.** A paired batch's sensitivity depends on how much
the change CASCADES the seeded RNG (the per-seed sd), not on `n` alone. Minimum detectable effect at
80% power ≈ 2.8 × sd/√n:

| change shape | typical sd | MDE at n=160 |
|---|---|---|
| narrow / late-firing (E-13 sd 0.066, E-6 sd 0.067) | ~0.07 | **~0.015** |
| broad re-weight or world change (sd 0.9–1.9) | ~1.2 | **~0.27** |

Now compare the levers actually shipped: E-6 +0.006 · E-13 +0.012 · leveling-need +0.012 · stdsync
+0.017 · V2c +0.020 · commit25 +0.024 · F1/F2 +0.038 · coupled +0.040 · pack-pick +0.054 · W3 +0.054 ·
W4 +0.066 · W6 +0.070 · E-5 +0.146. **Every BROAD change ever kept or reverted on a |Δ| below ~0.27 was
decided by noise.** The narrow ones (E-13, E-6) are genuinely detectable — which is exactly why the
"E-13 shape" (late, low-cascade) kept producing the only trustworthy verdicts. That was discovered
empirically; the table above is why.

**Two consequences the old rule got wrong:**

1. **"n.s." ≠ "no effect."** Reverting a logically-correct fix because a *underpowered* batch didn't
   move is optimizing the measurement, not the game. State the MDE before calling a verdict.
2. **Seed overfitting was the obvious worry — it was TESTED and is NOT a problem.** Selecting changes
   on the same 160 seeds they are measured on could fit that sample. Measured (2026-08-11,
   `tools/overfit_test.sh`, n=344 tuned vs n=308 held-out): **held-out − tuned = −0.050 (SE 0.133,
   95% CI [−0.31, +0.21])** — an arc-sized effect (0.487) is excluded. The retained arc generalizes.
   Keep `BES_SEED_OFF` for spot-confirming a big retained change, but out-of-sample confirmation is
   NOT required for every lever.
   **The real lesson from that run is POWER, not overfitting:** the same engine on the same pool
   measured **3.716 at n=344 but 4.244 at n=40** — a +0.53 error, larger than the whole arc. So:
   **never quote an UNPAIRED mean from a small batch, and always PAIR** (same seeds, both arms), which
   cuts the SE from ~0.25 to ~0.10 and is what makes any of this measurable at all.

**The replacement rule — burden of proof by change class:**

- **Correctness / fidelity / feasibility** (the code was provably wrong): **ship it**, unless it measures
  significantly NEGATIVE. Justify by mechanism, not by the metric. Correctness compounds, and the live
  mod advises a HUMAN — wrong advice is bad even when sim-neutral.
- **Magnitude / weight tuning** (a constant moved): still requires positive evidence, still backfires in
  isolation, and should be calibrated JOINTLY with the constants tuned around it.
  ⚠ The old revert set was described here as "all this class and stays refuted" — **§19a checked it and
  that is wrong twice over.** Most of it is refuted on MECHANISM (not magnitude), and **B3 and E-12 were
  neither: both were correctness fixes misfiled as tuning, and both have now been retested.** Before
  filing a change as "magnitude", ask whether the constant is *derived* — a constant that follows from
  an argument (§19b's `X` cancelling, the SELL_TO_BUY refill charge) is correctness wearing a number.
- **Revert on MECHANISM, not on a null result.** A change should be pulled when you can say *why* it is
  wrong. (Worked example: the 2026-08-11 reroll feasibility gate measured +0.024 n.s. — by itself that
  is no reason to pull it — but it was pulled because a concrete mechanism explained the harm: it damped
  rerolls that were earning value through CONSUMABLES, which `e_best` never prices.)

**THE FREQUENCY CEILING (2026-08-11 — check this BEFORE writing any fix).** A change can only move a
verdict if it FIRES often enough. Measure the firing rate first; if it is low, do not batch it:

| change touches | typical firing rate | can it move an n=160 verdict? |
|---|---|---|
| ONE joker's behaviour | **~5% of runs** | **No.** W-ECON (To the Moon + Rocket) came back 153/160 seeds TIED |
| a rare voucher / tag chain | ~5–10% | No — the voucher-upgrade fix, −0.064 n.s. |
| a rare shop situation | ~2.5 events/run (rerolls) | Marginal — the reroll gate, +0.024 n.s. |
| every shop of every run | 100% | **Yes** — this is the only class worth batching |

This single rule retro-explains W7, W8, the voucher upgrades, the reroll gate AND W-ECON. **Individual
card/joker fidelity is a dead end for winrate** (it is still worth fixing for a human following the live
overlay — just do not expect a batch to show it). Only SYSTEMS qualify: the shop loop, the economy
formula, the play engine, the leveling channel, the requirement curve, the starting conditions.

**Still true and unchanged:** in-blind changes cascade the seeded RNG, so prefer narrow/late-firing
changes whose sd is small enough to actually measure; prefer the screen-then-batch harness; a fix pays
only when the thing it fixes is BOTH strong AND frequent (W6 yes, W7 weak, W8 too rare).
NOTE: `xmult_scaling` jokers ARE xmult — use `JokerData.is_xmult()`.

**THREE REAL HUMAN WINS analyzed** (`bes_runs.jsonl`; `winning-archetype-from-real-run` memory) — Flush
House+leveling / Hologram+copier / economy→Bull+xmult; common thread = an XMULT stack the human KEPT.
~~In-blind PLAY verified near-optimal; the losses are BUILD, not play.~~

> ### ⭐ 2026-09-19 — WHAT THE PLAY INVESTIGATION ACTUALLY FOUND (read before trusting the play claims below).
> Owner reported the F11 self-player's live play looked "nowhere near optimal." Investigated hard; the
> nuanced, measured truth (full detail: `WINRATE_V4_PLAN.md` "IN-BLIND PLAY"):
> **(1) PURE SCORING-PLAY IS near-optimal — but this is NARROW.** `HandEval` scores hands EXACTLY right
> (7/7 canonical Balatro cases, `/tmp/hefid.lua`); the play-subset chooser picks the MAX-score play **94%**
> of the time when it must maximize; the ante-1 dig is **at a clairvoyant ceiling** (78% one-hand vs 75% for a
> future-knowing greedy reference, `tools/first_blind_optimal.lua`); and two dig-objective rewrites (clear-
> probability vs mean-score, incl. 3× samples) measured **NEUTRAL** on both the isolated first blind and full
> runs — REVERTED. So "which cards clear the blind" is solved; do not keep re-searching it.
> **(2) ⭐ THE OPEN FRONTIER (owner, 2026-09-19): JOINT MONEY-FARMING + SCORING is NOT solved.** Optimal play
> is not just "clear the blind" — it is milking ECONOMY *while* clearing: Gold cards/seals, Lucky, econ jokers
> (Faceless/Mail/Reserved Parking), and card/joker EDITIONS, held/played to MAXIMIZE $ subject to still
> clearing. The $1/unused-hand + farmed $ compounds into the next shop where every dollar decides survival.
> The scoring-play tests above do NOT measure this joint optimization — it is the next thing to probe
> (`engine/discard_fuel.lua`, `hold_fuel.lua`, `HandEval.play_econ`, the MILK/DIG paths in `decision_engine`).
> **(3) NEAR-100% IS A LEGITIMATE TARGET.** Expert human play (DoctorSpectred-tier) reaches **>98% on GOLD
> stake, hardest decks** — Balatro is ~fully winnable with expert play; the ceiling is POLICY, not variance.
> The 7/8 (87.5%) local sample was a small non-peak sample, NOT the skill ceiling. Even 0.5% ante-1 failures
> are a real defect (a competent human never dies ante 1).
> **(4) LIVE vs SIM.** All (1) is measured in the SIM (which builds `gs` correctly and uses `HandEval` as both
> chooser and referee, so it CANNOT reveal a live `state_extraction` fidelity gap). The live self-player runs
> the FULL engine at `BES_SAMPLES=80` (main.lua) — NOT a degraded path. Owner (2026-09-19): assume autoplay
> actuation is NOT the problem for now. So if live play still looks off after (2), the remaining suspect is
> `state_extraction` feeding wrong inputs (the documented Mouth-bug class) — needs a live example to pin.
> ⇒ The 2026-09-18 WINRATE_V4 "autonomous ceiling ~8–30% / compute-bound" conclusion STANDS for BUILD/scoring,
> but the **joint economy-farming-during-play axis (2) is un-probed and deterministic** — the live frontier.

**THE WORLD IS VALIDATED (2026-08-11) — `tools/real_vs_sim.lua`, live telemetry vs the n=344 baseline.**
Median dollars at ante 2 are **$1 in BOTH** (real mean is a fat right tail, not a shifted centre);
`njokers` matches exactly, `run_strength` to ±0.01 through ante 4, pack-type supply within ~1.5pp of
real AND of the wiki weights, progress ≈3.5 vs ≈3.55. **The "sim is a poorer world" hypothesis is dead —
stop conditioning conclusions on it.** The ONE divergence is hand levels late (real ~5× at ante 5–6).

**➡ THE GOVERNING FRAME (user, 2026-08-11): THERE IS ALMOST ALWAYS A WINNING LINE; THE ENGINE FINDS NONE.**
Wins do not come from holding a particular card or archetype — a strong player notices which of several
viable lines *this* run offers and COMMITS. The proof is already in the data and was filed under the wrong
heading: the `rich` probe handed the engine **+$100/round** (~20× the interest headroom) and it won **72.5%,
not ~100%**. Unlimited resources ≠ wins. **Every ceiling probe was measuring the greedy policy's CONVERSION
RATE, not resource scarcity.** So: do NOT chase archetypes (adding the secret hands measured **exactly**
0.000), do NOT probe resources further (axis exhausted), and treat the target as **LINE-FINDING** — is there
a reachable winning end-state from here, and does this action advance the best one? That is a planning/search
problem, which is why every magnitude lever failed and the structural planner is the only positive. Cheap
first step: a retrospective oracle over each LOST run's recorded offer stream to measure how often a winning
line existed. Full argument: `WINRATE_V3_PLAN.md` §5n.

**➡ CHECK EXPRESSIBILITY BEFORE CONCLUDING "THE ENGINE CAN'T"** — but check your MEASUREMENT first.
This section used to open *"The level gap was NOT policy: the sim uses MORE planets/run than the human
(1.67 vs 1.05)."* ❌ **THAT NUMBER IS WRONG** (corrected 2026-08-13, `WINRATE_V3_PLAN.md` §5z). Live
`consumable_use` records carry `key`, **not** `set` — reading `set` returns nil, which is the likely
origin. Counting keys in `CV.PLANET_KEY_HAND`: **ENGINE 1.77 planets/run (0.43/ante) vs HUMAN 8.38
(0.99/ante)** — 4.7× per run, **the opposite sign**. The level gap IS policy. That erroneous figure is
what redirected the project into the expressibility work below, which measured **exactly 0.000**.
Still worth knowing (and still fixed): **the three deepest human runs each committed to a SECRET hand**
(the WIN leveled Five of a Kind 9×, antes 3–8) and the project could not express that build in FOUR
places — secret planets excluded from the pool outright, Black Hole leveling 9 hands not 12, **15 of 18
spectrals silent no-ops** (incl. Ouija/Sigil/Cryptid, the only rank/suit CONCENTRATING cards), and
`build_plan.HAND_ORDER` listing 8 of 12 hands so sunk secret-hand levels scored ZERO toward commitment
(`WINRATE_V3_PLAN.md` §5m). **The lesson is now the reverse of the old one: re-derive the measurement
that motivates an architectural conclusion BEFORE acting on it.** A single mis-read field sent this
project down a path that cost a whole workstream and returned 0.000.

**THE REMAINING WALL is BUILD-ASSEMBLY**, and the divergence mine (`tools/divergence.lua`,
`WINRATE_V3_PLAN.md` §5s) has now MEASURED where it lives. Two results:

**❌ It is NOT the joker valuation.** 7 of 8 human runs won, so a joker still held at the end is part of
a *winning* board — and the engine's rank at purchase predicts that: rank #1 → 47% kept, #2 → 31%,
#3 → 0%, valued-negative → 22% (n=69). **Relative joker pricing is directionally right; do not re-tune
it.** (Shop-buy agreement 54%, n=85.)

**✅ It IS the PACK-PICK channel, and the disagreement is about what a pick is FOR.** Free, ~16 picks/run,
agreement only **41% (53/129)** — the lowest anywhere. Every disagreement is PAIRED (same pack, same
instant → composition and board controlled), so the sign test applies: **enhance** (per-card Bonus/Mult/
Glass) engine 36% vs human 5%, discordant 25/2, **p<0.00001**; **money** (Hermit/Temperance) human 20% vs
engine 1%, 1/15, **p 0.0005**; **shape** (thinning + rank/suit convergence) human 29% vs engine 12%, 6/19,
**p 0.0146**; **level** (planets) 22% vs 22%, **0 discordant pairs, the perfect control**. The engine buys
what a per-decision measurement can price TODAY; the human buys what pays LATER (cash compounding through
interest, deck shape raising the odds of the hand the build aims at).

**The located next lever is COMMITMENT→VALUATION FEEDBACK, and `level` is the proof of the template:**
planets are the one function priced *by the commitment* (`BP.planet_credit`) and the one function where
engine and winner agree exactly. Deck-shaping and cash have no equivalent, so each is priced alone and the
product is never assembled. This also explains the surplus dig's **−0.110 (p 0.012, n=480)** — it dug
*indiscriminately*, while the human shapes toward a *target* — and the secret-hand fixes' **exactly 0.000**
(capability without intent changes nothing). Co-calibrate with the planner constants — **never as an
isolated magnitude lever**. Do NOT re-try the reverted valuation levers in isolation.
⚠ **Engine `value`s are comparable ONLY within one ranked list** ("fraction of a boss hand" units, so ~3 at
ante 1 and ~300 at ante 7). Live re-sync is DONE (the install is current as of 2026-08-13).

**➡ BUT THE PACK-PICK CHANNEL IS DOWNSTREAM OF A BIGGER GAP (2026-08-13, `WINRATE_V3_PLAN.md` §5z).**
That analysis asks which card to pick *inside* a pack. **The engine mostly never opens the pack.**
Packs/ante: **ENGINE 1.36 vs HUMAN 6.10** — and inside the human's own 8 runs pack throughput separates
outcomes with **no overlap** (7 wins 4.33–7.44/ante; the 1 loss **2.80**, opening ZERO packs at antes 2
AND 3). It is valuation, not poverty: of 2410 shops with an **affordable** pack it bought **23.7%**, and
**1337 declines were packs it rated positive itself** — it rerolls instead 24.9% of the time. Worst
exactly where the human is heaviest: **Celestial mean value −0.79 (buy rate 6.3%), Standard −1.35
(6.8%)**, Celestial negative across the whole **a2–a6** window. Human hand-levels cross the engine's at
a4 and end **18.6 vs 7.7**.
**Treat this as an INTERACTION, not a lever.** "Just buy more packs" is already refuted (`levelbuy`
−0.229). But money alone (`rich10`) reaches only 2.44 packs/ante and 7.5% winrate, and the human has
BOTH: their dollar curve matches the `rich10` arm within ~15% at every ante *while* buying ~4.7 more
packs/ante. Mechanically the axes are **not separable** — with a $10 reserve and no extra income the
engine *cannot* buy packs (it holds $1.3 at ante 2, below the reserve): `packgreed10` moves 1.60→2.00
packs/ante while `richpack` reaches **5.75** (human 6.10). `Probe.pack_greed` + configs
`packgreed`/`packgreed10`/`richpack` test the 2×2.
⚠ Unknown, and it matters: this dataset **cannot** tell bought packs from free skip-tag packs
(`blind_select`/`blind_result` were added 2026-08-13; the dataset is 08-12).

**➡ CHAOS IS THE MEASUREMENT PROBLEM, quantified (`tools/envelope.lua`, §5z).** Every batch on the
shared seed pool is an expressible policy over the same seeds. Across 7 variants the per-seed MAX wins
**11/160 (6.9%)** vs the best single arm's 5 (3.1%) — but that 2.2× is **NOT hidden upside**:
envelope−best = **+0.690** and best−floor = **+0.773**. Near-symmetric dispersion is the signature of
NOISE. **85% of seeds change outcome under tiny policy perturbations**, and the sim is deterministic, so
this is chaotic policy sensitivity, not measurement error. **Never read max-over-k as an oracle**, and
expect sd ~1.9 (MDE ~0.42 at n=160) for anything touching the shop loop.

## Conventions & gotchas (learned the hard way)

- **Calculated, not static.** Joker/card/consumable *strength* is MEASURED from the
  player's deck (Monte-Carlo via `engine/joker_value`, `consumable_value`, etc.).
  `joker_data` tiers are only a **prior/fallback** for unmodelled cases — never the truth.
- **Determinism.** Live recommendations re-run every state change, so any advisor that
  samples MUST use a **per-state seeded RNG** (see the `lcg`/`*_seed` helpers in
  `shop_advisor`, `decision_engine`, `pack_open_advisor`, `search`). Using global
  `math.random` makes the panel **flicker** between ticks — treat that as a bug.
- **Live-key mismatches are silent zeros.** A joker's in-game center key can differ from
  our catalogue key — the base game itself misspells some (Gluttonous is
  `j_gluttenous_joker`). A mismatch means the joker scores **zero** everywhere. The mod
  logs `[BES][WARN] uncovered joker key …` and F7 tags coverage; when adding jokers,
  prefer aliasing both spellings. The coverage-guard test only checks catalogue↔effects,
  NOT catalogue↔live-game keys.
- **Value scales.** B1 unified scoring fractions: jokers, packs, rerolls, and standalone
  consumables all use the **×5 `JOKER_SCORE_WEIGHT` bridge**. Real-dollar gain terms remain
  unmultiplied. `SA.CREATES_JOKER` selects deck-aware output measurement; it is no longer an ×5 band-aid.
- **Destructive cards.** Hex/Ankh destroy your *other* jokers; their value subtracts the
  jokers lost (`consumable_value`), so never value them as "just a polychrome".
- **Created things need a SLOT.** A generator (Judgement/Soul → a joker; Emperor/High
  Priestess/Fool → consumables; a Buffoon pick → a joker) overflows and is *lost* with no
  free slot. Value it by how much output actually lands (`pack_open_advisor` `gen_fit`),
  and advise making room — *use* a held consumable or *sell* a joker — rather than blindly
  recommending it. Same idea funds a buy you're short on (`SA` `SELL_TO_BUY`).
  ⭐ **This applies to generator JOKERS too, and forgetting it cost a run** (`ADVICE_REVIEW.md` R8).
  `Generators.output_fit` / `has_output_room` are the shared helpers — use them, don't re-derive the
  slot check. Three call sites now share them (blind-select, `SA.funder_is_live`, and BOTH tier-prior
  paths: `Eval.jp_from_measure` **and** the independent `shop_advisor.scoring_gain` prior — patching
  only one leaves the other flat, which is exactly what happened first).
  ⚠ The joker/consumable split is **not** cosmetic: a **consumable** slot frees up as you use it, so a
  full tray is a TRANSIENT blockage and must NOT unprotect a consumable-maker (that would re-open the
  Vagabond churn the 2026-09-01 `funder_is_live` clause closed). A **joker** slot is scarce and sticky,
  so a full board is STRUCTURAL. `joker_data` already encodes the split: every `card_generation` joker
  carries the `"consumable"` tag **except `j_riff_raff`**, the one that makes jokers.
- **Tarot targets = your DRAWN hand, not the deck.** A card-tarot applies to cards you
  select from `gs.hand` (drawn). Naming a `gs.deck` card you haven't drawn is a bug
  (`Tarot.target_note`): name from an explicit pool or `gs.hand`, else give a strategy
  phrase. Sort ties by card `id` so the named card is deterministic (no flicker).
- **Condition-locked scalers.** Runner/Square/Trousers/Ride-the-Bus/Wee only grow on a
  specific played hand. Two places use this: `Eval.scaling_projection` *discounts* their
  shop value by trigger-hand frequency (don't over-value an un-fed scaler), and
  `engine/scaling_fuel` makes the play engine *feed* them when survival allows.
- **`-- VERIFY` fields** in `state_extraction` are game-version-dependent (`sell_cost`,
  `reroll_cost`, `chips_scored`, `current_round.free_rerolls`, sticker flags, `boss_key`).
  Scaling counters were F7-confirmed at `ability.mult` / `ability.x_mult` / `ability.chips`.
- **In-game loader gotcha:** Steamodded does NOT add the mod folder to `package.path`;
  `main.lua` registers a custom `package.searcher` for our namespaces. Headless tests set
  `package.path` instead, so they bypass it.

## Git

Active work is on branch `winrate-v4-bundle`; `main` is synced to the validated/live state (fast-forward/merge it when a
batch of changes is confirmed -- last synced 2026-09-28 at `42a867f`). **Commit and push whenever you (the AI
assistant) judge it appropriate — you do NOT need to wait to be asked** (owner directive, 2026-08-28).
Use judgement: commit at coherent checkpoints with a clear message, keep the tree green, and don't
bundle unrelated changes. Run the test suite before committing.
