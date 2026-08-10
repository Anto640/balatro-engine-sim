# SELFPLAY_PLAN.md — self-play simulation & data-driven tuning

Status: proposal / evaluation. Written after an audit of the current engine (see "What
exists" below). Companion to `BASE_VALUE_FIXES.md` and the joker-undervaluation note in
memory.

### Decisions taken (2026-06-25)
- **World scope: full fidelity** (eventual target). v1 still lands the common path first
  (§9.1) so we have something to calibrate, then expands to all vouchers/spectrals/packs/
  editions/stakes. Full fidelity is the destination, not the first commit.
- **Honesty source: headless simulator + a small real-run calibration set** (§6). No live
  in-game automation.
- **Now in progress: Phase 0** — instrument a real session and confirm the "behind on pace
  by ante 2–3" hypothesis with real numbers before building the big simulator.

---

## 0. Verdict (is this sensible?)

**Yes — with one honest caveat, and a clear idea of where the wins actually are.**

- It is sensible because the engine is **pure** and **fact/opinion-separated**. We can drive
  thousands of headless runs in plain Lua and measure winrate without the live game.
- The caveat is **"marking your own homework"**: if the simulator that judges the engine is
  built from the same *strategy opinions* the engine uses, winrate is circular — the engine
  will look great while still dying at ante 3 in the real game. The mitigation is structural
  (Section 2) and is the single most important design decision in this whole plan.
- The likely payoff is **not** better in-blind tactics. The in-blind decision layer
  (`decision_engine`, `hand_eval`, `search`, boss handling) is already sophisticated. Dying
  at ante 3 is an **economy/pace** failure: the build isn't strong enough by ante 3 because
  shop/economy/joker-selection decisions are mis-valued (over-saving, over-rerolling, chasing
  flushes, undervaluing owned jokers — exactly the existing `joker-undervaluation-plan`
  hypothesis). Self-play's job is to **prove that, quantify it, and tune it.**

---

## 1. What exists vs. what's missing

### Already built (the hard 80%)
| Capability | File | Notes |
|---|---|---|
| Full hand scoring pipeline (chips/mult/editions/seals/retriggers) | `engine/hand_eval.lua` | order-faithful, joker-aware |
| Joker scoring effects (~103 jokers, copy/retrigger/scaling hooks) | `engine/joker_effects.lua` | reads live `ability` counters |
| Ground-truth mechanics (ante targets, boss mults/effects, economy, planets) | `engine/mechanics.lua`, `engine/boss_effect.lua` | **facts, not opinions** |
| Single-blind survival rollout (seeded MC, discard-aware greedy policy) | `engine/simulation.lua` | `rollout()` already "plays a blind" |
| In-blind decision (play/discard/use-consumable) | `engine/decision_engine.lua` | `DE.decide(gs) -> ranked action` |
| Shop decision (buy/sell/reroll/skip) | `engine/shop_advisor.lua` | `SA.recommend(gs)` |
| Pack-pick & skip-tag decisions | `engine/pack_open_advisor.lua`, `engine/skip_advisor.lua` | |
| Deck/joker/consumable valuation (deck-aware MC) | `engine/joker_value.lua`, `consumable_value.lua`, `eval_function.lua` | the **opinion** layer |
| Heuristic forward pace projection | `engine/pacing.lua` | hand-tuned growth constants → tuning target |
| Seeded LCG determinism pattern | throughout (`*_seed`, `lcg`) | reused for self-play world RNG |
| State signature (for caching) | `core/signature.lua` | reuse to cache MC measurements |

### Missing (the connective 20% we must build)
1. **A run driver / forward state machine.** Nothing advances state. Every module *reads* a
   `GameState` and returns advice; none returns a successor state. We need an explicit loop:
   `blind → resolve → income → shop → buy/sell/reroll/pack → advance blind/ante → repeat`
   until death or an ante-8 boss clear.
2. **Shop & pack *content generation*.** The advisors consume a shop/pack the live game
   supplies. Nothing *generates* one. We need rarity-weighted draws from the `joker_data`
   catalogue, edition roll rates, voucher/pack slots, "already-owned" exclusion, and per-ante
   shop slot counts. This is the bulk of new **facts** code.
3. **A telemetry layer.** No run-level or decision-level logging exists.
4. **An experiment/tuning harness.** Parameter sweeps, A/B of policy variants, winrate stats.
5. Smaller gaps: full spectral/voucher *effects* (currently heuristic tiers), edition drop
   rates as constants, antes 9+ (already formula-ready in `mechanics`).

---

## 2. The honesty problem and how we avoid circularity

**Rule: the simulator's world is built ONLY from the facts layer; the engine-under-test is the
ONLY thing allowed to use the opinion layer.**

- **World / referee (facts):** `mechanics` (ante targets, economy, planet increments),
  `hand_eval` + `joker_effects` (actual scoring), `boss_effect` (debuffs/restrictions), plus
  new content-generation drawing from `joker_data`'s *catalogue* fields (rarity/cost only —
  **not** `tier`). The referee deals cards, generates shops, scores hands, awards money,
  raises the ante. It has no opinion about strategy.
- **Player (opinions):** `decision_engine`, `shop_advisor`, `pack_open_advisor`,
  `skip_advisor`, and everything they pull from `joker_value`/`eval_function`/`pacing`. This is
  the policy we are grading and tuning.

This separation already exists in the codebase (it's the project's "calculated, not static"
principle). Self-play just enforces it as a wall: **the referee must not import the opinion
layer, and the player must not be allowed to define what a win is.**

Residual risk that remains even with the wall: **fact-layer fidelity.** If `hand_eval` or the
shop generator diverges from real Balatro, winrate is honest *relative to our model* but not to
the game. That is what Section 6 (calibration) exists to bound. We can never fully escape it
headlessly — which is why a small number of real in-game runs stays in the loop.

---

## 3. Architecture of the self-play system

New files (all pure Lua, headless, no `G`):

```
sim/
  world.lua        -- the referee: deals hands, scores via hand_eval, awards $, advances ante.
                   --   apply(gs, action) -> gs'   (the successor function nothing currently has)
  content.lua      -- shop & pack generation: rarity-weighted joker draws, editions, vouchers,
                   --   packs, owned-exclusion, per-ante slot counts. FACTS only.
  driver.lua       -- the run loop. Wires player (decision_engine/shop_advisor/...) to world.
                   --   run(seed, policy, opts) -> RunRecord
  telemetry.lua    -- structured logging: RunRecord + per-decision records -> JSONL.
  policy.lua       -- bundles the player entry points + the tunable PARAMS table (see §5),
                   --   so a run is parameterised by one params object.
experiments/
  harness.lua      -- run N seeds for a given params set; aggregate winrate + stats.
  sweep.lua        -- vary knobs, compare, write results.
tests/test_world.lua, test_content.lua, test_driver.lua  -- keep the green-tests discipline.
```

### `world.apply(gs, action) -> gs'` — the keystone
The one function the engine never had. Per action type:
- `PLAY`: score via `hand_eval`, add to `chips_scored`, decrement `hands_left`, remove played
  cards, redraw from `remaining`; on clear → round-end income (`mechanics.round_income`).
- `DISCARD`: decrement `discards_left`, redraw.
- `USE_CONSUMABLE`: apply the consumable's *effect* (level a hand, enhance cards, make money,
  generate a joker into a free slot) — reuse the effect knowledge in `tarot`/`consumable_value`
  but execute it as a state mutation.
- Shop `BUY/SELL/REROLL/PACK`: adjust `dollars`, joker/consumable slots, `reroll_cost`.
- `ADVANCE`: small→big→boss→next ante; regenerate blind target + boss; generate next shop.

Much of `simulation.lua`'s `rollout()` is a lossy prototype of the blind half — but it bakes in
a *greedy* policy and tracks no detail. The driver should instead call the **real**
`decision_engine.decide()` each step so we grade the actual shipping policy, and have `world`
own the bookkeeping.

### Cost control (this matters — naive nesting is too slow)
Every `decide()` / `recommend()` call internally runs Monte-Carlo measurement. A full run is
~24 blinds + ~8 shops, and "many many runs" means 10³–10⁵ runs. Mitigations:
- Run the player on the **cheap path** by default (`eval_function` already supports
  `measure=false`; advisors fall back to tier priors without a deck-measure). Reserve measured
  evals for the decisions a given experiment is actually studying.
- **Cache** measured values by `core/signature.lua` keyed on (deck-signature, joker-set),
  shared across a run and ideally across runs in a sweep.
- Use **LuaJIT** for the batch harness. Thousands of runs/hour is then realistic.
- Keep MC `samples` low (e.g. 20–40) inside self-play; raise only for calibration runs.

### Determinism / RNG discipline (a known footgun here)
The engine's per-state seeded RNG must stay **independent** of the world RNG. The world draws
one stream from the **run seed** (shuffles, shop rolls, edition rolls); the player keeps its
existing per-state seeding for stable advice. Mixing them reintroduces the panel-flicker bug
class and makes runs non-reproducible. One run = one world seed = fully replayable.

---

## 4. Telemetry — what to measure

### Per-run record (`RunRecord`)
- `seed`, `won` (bool), `death_ante`, `death_blind_type`, `death_boss_key`, `antes_cleared`.
- Final board: `jokers[]` (key, edition, sell_value), `hand_levels`, deck composition summary,
  vouchers, consumable usage counts.
- Trajectories (per ante): `money_in`, `money_out`, `reroll_count`, `packs_opened`,
  `pace_margin` (from `pacing.pace`), `run_strength`, projected-vs-required at ante 8.
- The seed of the failure: at the death blind, `chips_scored / target`, hands/discards left,
  best `win_probability` the sim assigned going in (calibration signal — did we walk into a
  loss the model already saw coming?).

### Per-decision record (sampled, not every decision — volume)
- State features (ante, money, #jokers, deck archetype, pace margin), action taken, the
  ranked alternatives + their values, and `confidence_basis`. Enables attribution (§5) and
  lets us replay "what if it had taken the 2nd-ranked action."

### Aggregate metrics (the dashboard)
- **Winrate** and its CI (binomial; see noise budget in §5).
- **Death-ante histogram** — the headline. Goal: push the mode past ante 3.
- **Per-joker conditional winrate**: `P(win | owned joker J by ante k)` vs base rate, with
  appearance/offer/buy rates so we separate "J is good" from "J is rarely offered."
- **Economy curves**: median money by ante; reroll spend distribution; interest left on table.
- **Pace margin distribution by ante** — the leading indicator of the ante-3 wall.
- **Decision regret proxy**: how often the chosen action underperforms a forced alternative in
  paired replays (§5 ablation).

Everything writes JSONL so analysis can be done in Lua, or exported to anything.

---

## 5. From data to better values

### 5a. The tunable surface (the knobs)
Collect the scattered magic constants into one `policy.PARAMS` table so a run is fully
parameterised. High-value candidates, by hypothesis-priority:
- **Economy / pace (most likely culprits):** `shop_advisor` `W_FV`, `COST_WEIGHT`,
  `DOLLAR_UTIL`, `REROLL_DISCOUNT`, `FREE_SPEND_DISCOUNT`, `INTEREST_HORIZON`,
  `TYPICAL_JOKER_COST`; `mechanics.RESERVE`; `pacing.growth_factor` coefficients
  (`1.25 / 0.30·xmult / 0.15·scaling / …`) — these are explicitly "tunable, not gospel."
- **Valuation scale:** `JOKER_SCORE_WEIGHT` (×5), `value_units` conversions, `joker_data` tier
  priors (only as fallback), `eval_function` future-value weights.
- **Selection thresholds:** `search.MARGIN`, discard/play econ trade-offs.

### 5b. Three attribution methods (increasing rigor)
1. **Correlational** (cheap, biased): conditional winrate by owned-joker / archetype. Good for
   hypotheses, confounded by "good players reach good states."
2. **Counterfactual replay / ablation** (causal-ish): at logged decision points, fork the run,
   force an alternative action, finish under the same world seed, measure winrate delta. This
   isolates a decision's value from the trajectory that led to it.
3. **Parameter sweep** (the actual tuning): treat `winrate(PARAMS)` as a black-box objective.
   Coordinate descent / coarse grid over the 3–6 highest-impact knobs first; consider a simple
   evolutionary search (CMA-ES-style) only if coordinate descent plateaus. Always pair-seed:
   evaluate every candidate on the **same** seed set to cancel world variance.

### 5c. Noise budget (don't fool yourself)
Winrate is a Bernoulli rate. To detect a 2-point change around a 20% winrate you need on the
order of ~1–2k runs per configuration (95% CI half-width ≈ 1.96·√(p(1−p)/n)). Use **common
random numbers** (same seed set across configs) so most variance cancels and far fewer runs
resolve a *difference* than an *absolute* rate. Report CIs, not point winrates.

### 5d. Guardrails against simulator-overfitting
- Prefer parameter changes with a **mechanistic story** (matches the undervaluation thesis)
  over unexplained winrate bumps.
- Hold out a seed set never used for tuning; report final numbers only on it.
- Re-run the **calibration** check (§6) after any big tuning move: if sim winrate improves but
  diverges further from real-game outcomes, the simulator — not the engine — moved.
- Keep the 581-test suite green throughout; tuning must not silently break unit behaviour.

---

## 6. Calibration against real runs (keeps it honest)

The "dies at ante 3" signal came from **real** play — that's our ground-truth anchor, and it
must stay in the loop.
- Use the existing in-game instrumentation (`F7` joker dump, `[BES]` logging, `state_extraction`)
  to capture a handful of **real** run trajectories and the states at real deaths.
- Replay those exact states through the simulator: does the world score them the same? Does the
  sim assign low survival where the real run actually died? Mismatches localise **fact-layer**
  bugs (scoring, shop pools, economy) — fix those before trusting any tuned winrate.
- Target: sim death-ante distribution ≈ real death-ante distribution on matched seeds/decks
  *before* spending compute on parameter search. Calibrate first, tune second.

A cheaper interim anchor: assert the simulator reproduces known facts (ante-8 boss = 100,000;
interest caps at $5; a flush of N scores exactly what `hand_eval` says in-game on the same
cards). These are unit tests, not full calibration, but they catch gross drift early.

---

## 7. Phased roadmap

**Phase 0 — instrument before simulating (cheap, do first).**
Add per-run + per-decision telemetry to a *real* in-game session and to the existing
`pacing`/`simulation` outputs. Confirm the hypothesis ("we're behind on pace by ante 2–3, not
losing winnable blinds") with real numbers before building anything large. May reveal a quick
win that doesn't need self-play at all.

**Phase 1 — the forward simulator (the keystone).**
`sim/world.lua` (`apply` + round/ante advance) and `sim/content.lua` (shop/pack generation).
Unit-test against `mechanics`/`hand_eval` facts. Deliverable: one full headless run to a
deterministic end from a seed.

**Phase 2 — driver + telemetry.**
`sim/driver.lua` wiring the real advisors to the world; `sim/telemetry.lua` emitting JSONL.
Deliverable: `run(seed)` → `RunRecord`; a death-ante histogram over 1k seeds.

**Phase 3 — calibration.**
Replay real captured states; align sim death distribution to reality; fix fact-layer drift.
Gate: do not proceed to tuning until calibration passes.

**Phase 4 — attribution + tuning.**
`experiments/harness.lua` + `sweep.lua`. Run conditional-winrate and ablation analyses, then
coordinate-descent the economy/pace knobs with common-random-number seed sets and CIs.
Deliverable: a tuned `PARAMS` that measurably lifts the death-ante mode, with a written
rationale per change.

**Phase 5 — monitor & iterate.**
Re-run the sweep periodically (and after engine changes), watch the dashboard, keep a changelog
of `PARAMS` versions and their winrate/CI. Re-calibrate against fresh real runs occasionally.

Rough effort: Phase 1 is the big lift (content generation is fiddly); Phases 2/4 are moderate;
Phase 0/3 are small but high-leverage. Phases 0–2 give the data-gathering system the request
asks for; 3–5 are the "tune and monitor" half.

---

## 7b. Phase 0 — BUILT (2026-06-25)

The instrumentation is in place and headlessly tested (629 tests pass). New files:

- `util/json.lua` — dependency-free JSON encode/decode (JSONL records). Round-trip tested.
- `core/run_telemetry.lua` — **pure** frame→record state machine. `frame_of(gs)` derives a
  light frame from the POD; `observe_gs(gs)` detects run start / new ante / death / win and
  emits flat records. Heavy metrics (pace, run-strength) come from an injected `enrich`
  hook, called only at boundaries. No `G`/`love` deps.
- `main.lua` — `BES.observe(gs)` runs every `BES.tick` (before the change-gate, so it never
  misses an ante advance or `GAME_OVER`). Appends records to `bes_runs.jsonl` in the LÖVE
  save dir; `enrich` measures `pacing.pace` + `eval_function.run_strength` at boundaries.
  Everything is `pcall`-guarded — telemetry must never take the game down.
- `core/run_telemetry.lua` also has an **action tracer** (`trace(scene)`): by diffing
  successive scenes it logs what the engine bought / skipped / sold / used, shop offerings +
  the engine's advice, packs opened, and hand level-ups — so a run's full decision history is
  reconstructable without hooking inputs. `main.BES.scene_of(gs)` builds the scene each tick.
- `tools/analyze_runs.lua` — headless dashboard: winrate + binomial CI, **death-ante
  histogram**, death-context (blind type + clear-ratio at death), a **per-ante trajectory**
  of money / joker count / hand-level investment / `pace_margin` / `run_strength` / on-pace%,
  an **engine action summary** (jokers bought/skipped/sold, packs, level-ups, rerolls), and a
  per-run **timeline** mode: `lua tools/analyze_runs.lua <file> trace [seed]`.
- `tests/test_telemetry.lua` — JSON round-trip + the full transition + action-trace machine.

### How to capture real data
1. **Deploy** the changed files to the install (the repo is NOT the install):
   copy `main.lua`, `util/json.lua`, `core/run_telemetry.lua` into
   `%APPDATA%\Balatro\Mods\balatroenginesim\`. (The `main.lua` require-searcher resolves the
   new `util`/`core` files automatically — no manifest edit needed.)
2. **Play** several runs to their end (death or win). On load the console logs the telemetry
   path; each boundary logs a `run-telemetry …` line. Records append across sessions, so just
   keep playing — more runs = tighter winrate CI (≈1–2k for a 2-pt signal; tens are enough to
   see the death-ante *mode*).
3. **Analyze**: `lua tools/analyze_runs.lua "%APPDATA%\Balatro\bes_runs.jsonl"`
   (the default path is already this; pass an explicit path if your save dir differs).
4. **Read the verdict**: if `pace_margin` sits below 1.0 and on-pace% collapses by ante 2–3,
   the losses are a **build-strength / economy** problem (→ tune `shop_advisor` + `pacing`
   knobs, Phase 4), not in-blind play. If instead runs die at high clear-ratios with healthy
   pace, the problem is tactical/variance and the diagnosis changes.

This must run *before* building the big simulator (Phases 1–2): it tells us which knobs the
self-play tuning loop should target, and it gives the real-run anchor that Phase 3 calibrates
the simulator against.

## 8. Key risks / failure modes

1. **Circular grading** (§2) — the headline risk. Wall off facts from opinions or the whole
   exercise self-confirms.
2. **Fact-layer fidelity ceiling** — sim winrate is only as true as `hand_eval` + content
   generation. Bounded by calibration, never eliminated headlessly.
3. **Compute blow-up** from nested Monte-Carlo — mitigated by cheap-path + signature caching +
   LuaJIT + low samples.
4. **Overfitting to the simulator** — held-out seeds, mechanistic-rationale filter, re-calibrate
   after tuning.
5. **Winrate noise** — common random numbers + CIs + adequate n; never chase a 1-run swing.
6. **Content-generation inaccuracy** (rarity weights, edition rates, slot counts, voucher/pack
   pools) is the most error-prone new code and feeds straight into strategy — test it hardest.

---

## 9. Decisions for the user

1. **Scope of the world model.** Full-fidelity content generation (vouchers, all packs,
   spectrals, stakes) is a lot of new facts code. Recommended: start with the **common path**
   (jokers + planets + tarots + standard/celestial/arcana packs + core vouchers) that covers the
   ante 1–4 economy where runs are dying, and expand only if calibration demands it.
2. **Headless-only vs. also driving the real game.** Recommended: headless simulator as the
   workhorse, plus a *small* real-run calibration set (Phase 3) — not full in-game automation,
   which is far more effort for marginal extra honesty.
3. **How aggressive a tuning search.** Recommended: start with coordinate descent over the
   economy/pace knobs (the prime suspects) before anything fancier.

If this framing is right, the highest-leverage first move is **Phase 0 + Phase 1**: instrument
to confirm the pace hypothesis, then build `sim/world.lua`. Everything else hangs off the
successor function the engine has never had.
