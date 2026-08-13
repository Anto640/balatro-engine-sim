# CLAUDE.md — working context for AI assistants

Project guide for anyone (human or AI) editing this repo. See `README.md` for the
feature-level overview and `DESIGN.md` for the original (historical) design baseline.
Despite the historical filename, this guide applies equally to Codex and other coding agents.

## What this is

`balatroenginesim` is a **Balatro decision-assistant mod** (LÖVE2D / Lua, Steamodded
+ Lovely). It reads live game state from the global `G`, evaluates every legal
action, and overlays a ranked "best move" with a reason. Roadmap M1–M4 is complete
plus a large correctness/coverage/strategy pass; MCTS is intentionally deferred.

## Architecture (one rule: the engine is PURE)

Data flows one way: `core/state_extraction` (the **only** file that reads `G`) →
`model/game_state` POD → `engine/*` (pure functions) → `ui/*` overlay. Every engine
module consumes plain Lua tables and never touches `G`, which is what makes the whole
thing **headless-testable**. See the Layout section in `README.md` for the per-file map.

## Build / test / run

- **Tests (do this after every change):** `lua tests/runner.lua` (run via the Bash
  tool). Lua 5.1+/LuaJIT, no `love`/`G`/Steamodded needed. Currently **932 pass** (+ 524 sim).
  Failures print `FAIL  <case>  (got X, want Y)`; exit code is non-zero on failure.
- **Phase-1 simulator suites are SEPARATE** (they drive the real engine per hand and
  take minutes): `luajit tests/runner_sim.lua` (`test_world`, `test_driver`, `test_consumables`, `test_content_rates`, …). `luajit`
  is installed and ~2.5x faster — prefer it for anything that runs the `sim/` forward
  simulator (`World.play_blind` / `Driver.run`).
- **Deploy to the live game (manual copy — the repo is NOT the install):** the running
  mod lives at `%APPDATA%/Balatro/Mods/balatroenginesim/`. After editing, copy changed
  files there or the game won't see them. Green tests ≠ works in-game.
- **In-game debug keys:** `F7` dump owned jokers' live `ability` tables (to the console
  and to `bes_joker_dump.txt` in the LÖVE save folder, each tagged
  `scored`/`value-only`/`UNCOVERED`); `F8` force a re-evaluation; `F9` toggle the overlay.

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
**2026-08-13 fixes:** a **game-breaking OOM** — `each_subset` allocated a scoring table per subset
(218 at hand size 8, 2379 at 13) and `best_play` runs ~80×/decision, so a large hand exhausted LuaJIT's
heap and soft-locked a live run (`decide failed: not enough memory`); `HandEval.HAND_BUDGET = 8` bounds
enumeration ABOVE 8 only (sim byte-identical at ≤8) and `main.lua` steps the GC per evaluation.
**The Fool** was valued at its flat 0.30 prior with nothing to copy, because `pack_open_advisor`'s
copy-target search runs AFTER selection — `CV.fool_target` now zeroes it pre-sort (an in-pack target
only counts when `picks_left >= 2`). Live telemetry gained `blind_select`, `blind_result`
(hands/discards actually SPENT) and per-option `ranked` valuations.
(The install at `%APPDATA%/Balatro/Mods/balatroenginesim/` is CURRENT as of 2026-08-13.)

### CURRENT STATE (2026-08-13) — **8 expert HUMAN runs captured, 7 wins**; engine still ~1.25%
**➡ THE authoritative status is `WINRATE_V3_PLAN.md` §5r (read that first). Fresh-session handoff:
`NEXT_SESSION.md`. Historical audit + roadmap: `WINRATE_AUDIT.md`. Superseded plans: `docs/archive/`.**

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
  isolation, and should be calibrated JOINTLY with the constants tuned around it. The old revert set
  (C1, B3, F3, F4, F8, swap-damp, cost-discount, xmult-floor…) is all this class and stays refuted.
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
In-blind PLAY verified near-optimal; the losses are BUILD, not play.

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

Active work is on branch `joker-coverage-and-engine-fixes`. Commit/push only when asked.
Run the test suite before committing.
