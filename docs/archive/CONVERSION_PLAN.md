# docs/archive/CONVERSION_PLAN.md — money → a directed, supermodular build (2026-08-28)

> **The frontier, in one line.** Econ *generation* is now correct and faithful (the 2026-08-28
> fidelity + econ work — see `sim-fidelity-and-econ-2026-08-28`, `docs/archive/JOKER_FIDELITY_AUDIT.md`). What the
> engine still does not do is **CONVERT** the money it now truthfully earns into a *directed* build:
> copiers × xmult × retriggers × the leveled hand you are building **toward**. The win condition is a
> **product of assembled pieces**; the engine scores it as a **sum of present-board marginals**. That
> mismatch is the whole gap, and it is the same failure the one human LOSS run named from the inside:
> *"so much econ, couldn't find anything that boosted my build or gave it direction."*

---

## 0. The reframe that makes this tractable again (READ FIRST)

Every prior attack on conversion was judged on **autonomous sim winrate**, and every one came back
null or was reverted on a winner's-curse null:

| attempt | what it was | verdict | instrument |
|---|---|---|---|
| `oracle_plan` (§24) | a perfect deck-frequency target handed free from ante 1 | **null**, 41/40 wins | winrate |
| additive-lever family (§31) | every per-decision / economy lever on the over-buy | **exhausted on mechanism** | winrate |
| target/completion model (§32b/c) | `completion_credit` gated on `needs_xmult`, hooked into pack EV + tags | in-sample +0.067 @rich10, **OOS-fail** → reverted worktree-only | winrate |
| product board-scorer (P4, GRAND_AUDIT) | score the board as a set | **bounded weak** | winrate |

**The load-bearing observation: not one of those verdicts was rendered on the ADVICE-QUALITY
instrument.** They were all rendered on the sim's *autonomous greedy winrate* — which the project has
independently, quadruply confirmed is **ceilinged** (the value function is the wall; compute/data-bound;
`docs/archive/MCTS_PLAN.md`, `docs/GRAND_AUDIT.md`). A ceilinged, chaotic instrument (sd ≈ 1.9, MDE ≈ 0.42 at n=160;
85% of seeds flip outcome under tiny perturbations, `tools/envelope.lua`) cannot register a conversion
improvement even when one exists — the greedy autonomous policy can't *execute* a directed build
regardless of how well the engine *advises* one.

**But the live objective pivoted this session to ADVICE QUALITY** (`NEXT_SESSION.md`, the "if the
objective shifts" section; the methodology-shift memory). The mod advises a **human who wins ~87.5%
and DOES convert.** For that human, "which buy/pick/play assembles the product" is the single most
valuable thing the overlay can get right — and it is measurable, deterministic, non-chaotic, and
**not compute-bound**, on an instrument that already exists:

- **`tools/replay_fixtures.lua`** replays every captured shop/pack/blind decision under the *current*
  engine (byte-deterministic).
- **`tools/agreement.py`** joins those engine picks to what the **winning humans actually did**, per
  decision, across BLIND / PACK / SHOP.

This is the user's own thesis, stated earlier this session about the fidelity work and applied here:
*"if win rate drops even to zero but as a consequence I believe it will match the overlay and push the
overlay to better results."* **Conversion is re-opened on the agreement instrument.** Winrate stops
being the target and becomes a **safety rail** (a conversion advice change must not measure
*significantly negative* on the paired tail-verdict; it is allowed to be null there).

---

## 1. The mechanism, located in code

The buy decision is formed in `engine/shop_advisor.lua`:

```
-- shop_advisor.lua:678
local value = w_score * (sgain * 5 + syn + fit + first_scorer) + w_econ * econ
            - w_score * down - net_cost(cost) - econ_floor_penalty(gs, cost)
```

Three representational gaps make this a **sum where the win condition is a product**:

1. **`sgain` is a present-board marginal.** `scoring_gain` (`shop_advisor.lua:516`) returns
   `JokerValue.score_delta(gs, sj)` — the MC score added by dropping `sj` onto the board **as it is
   right now**. A copier with nothing worth copying, or an xmult over a thin base, both correctly
   measure *low* — because on the *current* board they *are* low. There is no notion of the marginal
   on the **board you are building toward** (the assembled product), which is exactly where a keystone
   pays off.

2. **The planner's `fit` is a flat constant, not a product term.** `BuildPlan.fit`
   (`build_plan.lua:532`) adds a fixed `BP.XMULT_FILL = 2.2` for "an xmult when `needs_xmult`", a
   fixed `BP.SCALING_FILL = 1.2`, a fixed `BP.COMMIT_JOKER_FILL = 1.2` for an on-plan hand piece.
   These are hand-tuned nudges *added into the same sum*. They shift the argmax a little; they do not
   **represent** the multiplicative value of completing a core. (This is why `BP.XMULT_FILL` had to be
   tuned against a baseline and can't be "turned up" safely — it isn't grounded in the board's product.)

3. **The board is never scored as a set.** `BuildPlan.analyze` (`build_plan.lua:510`) *counts* axes
   (`n_xmult`, `n_scaling`, `base`) and derives boolean needs (`needs_xmult`, `needs_scaling`,
   `needs_base`) — but never computes `product(board)` or `product(board ∪ {candidate}) −
   product(board)`. `BP.level_amplifier` (`build_plan.lua:464`) is the *one* place a product estimate
   leaks in (`XMULT_EST ^ n`, capped) and it only amplifies *leveling* credit, not joker buys.

The pack channel has the same shape one layer over: `pack_open_advisor` prices a pick by its present
value, so it buys **enhance** (immediate per-card chips) over **shape / money / level** (downstream
conversion) — the measured 41% agreement channel, the lowest anywhere (§5s).

---

## 2. What is genuinely new since those verdicts

1. **The sim is now faithful and the econ is real.** Pre-2026-08-28 the sim paid jokers flat econ
   priors they never earned; conversion was being measured against *flattered* money. Now the money
   the engine converts is the money it truthfully earns, so a conversion signal measured today is
   measured against reality.
2. **The agreement instrument is built and validated** (on the 14-win save-folder corpus per
   `NEXT_SESSION.md`) — a dense, deterministic, non-ceilinged ruler that none of the §24/§31/§32/P4
   verdicts ever used.
3. **The winning corpus is on disk**: `data/bes_runs_live_2026-08-12.jsonl` (8 runs, 7 wins) + the
   save-folder captures, carrying 928+ per-decision (engine-value, human-action) pairs.

So the honest status is: **the target/product family is closed on WINRATE and OPEN on AGREEMENT.**
This plan attacks it on agreement.

---

## 3. The plan — four phases, agreement-first

Every phase obeys the project's standing methodology (`CLAUDE.md`): screen the **firing rate** before
batching; run every arm **from a git worktree**, never the tree being edited; **verify the value fired
by MEASURING it**, not by reading the diff; **OOS-confirm** any selected constant (winner's curse is
the documented killer here); a magnitude constant needs positive evidence, a correctness/representation
fix ships unless significantly negative.

**Primary metric:** per-decision agreement with winners (`agreement.py` SHOP `buy_agree` +
`eng_buy_human_save` over-buy rate; PACK `agree_same`; BLIND unchanged as a guard).
**Safety rail:** paired winrate tail-verdict (`analyze_runs.lua <A> compare <B>`, n ≥ 160, reach-7/8 +
McNemar). A phase ships if it **raises agreement AND is not significantly negative on the rail.**

### Phase A — establish the agreement baseline (no build; ~1 session)

The ruler must read the *current* engine before anything changes.

1. Capture / locate the fixtures corpus (`bes_fixtures.jsonl`) + `bes_runs.jsonl` from the winning
   save-folder runs. (Capture-only mode in `main.lua` already writes fixtures; confirm the 14-win
   corpus is present, else re-capture from the saved runs.)
2. `luajit tools/replay_fixtures.lua <fixtures> picks.jsonl`
3. `python tools/agreement.py <fixtures> <runs> picks.jsonl --exclude 45SHRPEF,C94E7UIC`
   (exclude the two flagged seeds per `human-run-collection`).
4. Record the SHOP over-buy rate, the PACK `agree_same`, and the concrete `--- SHOP over-buy ---` /
   `--- PACK disagreements ---` example lists. **These example lists ARE the spec** for Phases B–D:
   each is a decision where a winning human converted and the engine did not.

**Deliverable:** a committed `docs/archive/conversion_baseline.txt` (the agreement report) that every later phase
diffs against. No code change. This is the cheapest, highest-value step and it gates the rest.

### Phase B — the completion/target model, re-judged on agreement

Resurrect the §32 `BP.completion_credit` (it is *not* in the tree — reverted worktree-only on a
winner's-curse **winrate** null, never evaluated on agreement). It encodes exactly the human's measured
dir-2 behaviour: *save past an additive when the board already has a base; chase the multiplier that
completes the product.*

- **Build:** `BP.completion_credit(gs, key)` — nonzero only when `plan.needs_xmult` (a base exists,
  the multiplier is the missing piece) for a candidate that IS the missing multiplier/copier/retrigger;
  hooked into (a) the joker `fit` and (b) Buffoon pack EV (`engine/packs.lua`). Gated to zero on an
  urgent/hopeless board (survival first). Sized from the human take-rate in the H3 2×2, not hand-picked.
- **Screen:** it fires on shop sessions with `needs_xmult` true — measure that rate first
  (`supermodular_headroom.lua` says the class is common enough).
- **Judge:** does SHOP `eng_buy_human_save` fall and `buy_agree` rise? Does PACK `agree_same` rise on
  Buffoon packs? **If yes → ship on advice merit**, even if the winrate rail is null (the §32 signal
  was real enough to warrant 4 arms; it only "failed" on the wrong instrument).
- **Kill:** if agreement does not move, the completion primitive genuinely adds nothing the present
  valuation lacks (the §32a retraction's honest possibility) — stop, don't tune.

### Phase C — the forward marginal (the real representational fix)

The root cause (gap #1): `sgain` is a *present-board* marginal. Give the buy a **second marginal
measured on the committed target board.**

- **Build:** when there is an anchored/committed hand (`BP.anchored_commitment`), form a lightweight
  *target board* = current jokers + the committed hand at a projected level, and compute
  `sgain_target = score_delta(target_board, sj)`. Blend: `sgain_eff = max(sgain, λ · sgain_target)`
  with λ gated on `invest_window` (never when urgent). This makes a keystone that is weak-now but
  completes the product read *high for the reason it is actually valuable* — replacing the flat
  `XMULT_FILL` constant with a measured product marginal.
- **Cost/feasibility:** `score_delta` is MC and `best_play` is the expensive path — measure the added
  per-decision cost (it runs once more per shop joker). If too slow live, cache the target-board
  projection per shop (deterministic per state).
- **Judge:** agreement (primary) + the winrate rail. This is the P4 product-scorer done as a
  *targeted forward marginal* rather than a global board score — the form P4 never took.
- **Risk:** this is the most likely to move the winrate rail *negative* if it over-buys keystones
  early (the documented backfire, `build_plan.lua:7-9`). The `invest_window` gate + the `max()` (never
  *below* the present marginal) are the guards; verify ante-2 board strength doesn't fall (the readiness
  -gate lesson, §17).

### Phase D — the pack-pick conversion channel (the biggest single gap)

PACK agreement is 41% — the lowest channel — and it is *pure conversion*: the human picks shape / money
/ level (pays later), the engine picks enhance (pays now). This is downstream of "the engine mostly
never opens the pack" (§5z) but Phase D is specifically about the pick *given* the pack is open.

- **Build:** in `pack_open_advisor`, price shape (deck-thinning + rank/suit convergence toward the
  committed hand), money (Hermit/Temperance — cash compounding through interest), and level (planets —
  already priced via `planet_credit`) by their **downstream conversion value under the commitment**,
  not their immediate per-card score. The `level` sub-channel is the proven template (§5s: 0 discordant
  pairs, priced by the commitment) — extend the same commitment-conditioned pricing to shape + money.
- **Judge:** PACK `agree_same` and the paired `enhance vs shape/money` discordant counts from §5s.
- **Note:** this is advice-quality-pure — it is unlikely to move autonomous winrate at all (the greedy
  sim under-opens packs), which is precisely why it must be judged on agreement.

---

## 4. Anti-patterns this plan must not repeat (hard-won)

- **Winner's curse.** §32 converted in-sample @rich10 and died OOS. **Any selected constant gets a
  `BES_SEED_OFF` out-of-sample confirmation before it shifts a verdict.** In-sample agreement gains on
  the 8-run corpus are suggestive, not proof — the corpus is tiny; prefer *direction and mechanism*
  over the point estimate, and confirm on the save-folder corpus held out.
- **Broad reweight → noise floor.** A change touching every shop lands inside sd ≈ 1.9 on winrate.
  Keep each phase's *blast radius to one mechanism* (the `build_plan.lua:380` rule) so the agreement
  signal is readable.
- **"The mechanism fired" ≠ value.** §17: an identical behaviour change paid +0.421 at one operating
  point and −0.076 at another. Firing is a *screen*, never evidence. Judge on the metric.
- **Measure the value, not the diff.** The `level_gain` threading bug fired nil twice silently. Verify
  `completion_credit` / `sgain_target` are actually nonzero on a known board *before* trusting a batch.
- **Don't reopen the graveyard on a null.** Revert on *mechanism*, ship correctness on *mechanism*;
  never conclude "logical fix, no effect" from an underpowered winrate null (that verdict was the
  project's central artifact).

---

## 5. The first concrete step

**Phase A, today, no code change:** locate/confirm the winning fixtures corpus, run the three commands
above, and commit `docs/archive/conversion_baseline.txt`. That single report tells us — on the right instrument, for
the first time — *exactly which conversion decisions the engine gets wrong for a winning human*, and it
turns Phases B–D from speculation into a punch-list of real disagreements. Everything after is
build-then-measure against that ruler.

**Definition of done for the frontier:** the engine's SHOP over-buy rate and PACK enhance-over-shape
rate on the winning corpus move toward the human's, with no significant winrate regression — i.e. the
overlay advises the *product-completing* buy/pick a winner makes, which is the value the live mod
actually delivers.
