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
  tool). Lua 5.1+/LuaJIT, no `love`/`G`/Steamodded needed. Currently **769 pass** (+ 195 sim).
  Failures print `FAIL  <case>  (got X, want Y)`; exit code is non-zero on failure.
- **Phase-1 simulator suites are SEPARATE** (they drive the real engine per hand and
  take minutes): `luajit tests/runner_sim.lua` (`test_world`, `test_driver`). `luajit`
  is installed and ~2.5x faster — prefer it for anything that runs the `sim/` forward
  simulator (`World.play_blind` / `Driver.run`).
- **Deploy to the live game (manual copy — the repo is NOT the install):** the running
  mod lives at `%APPDATA%\Balatro\Mods\balatroenginesim\`. After editing, copy changed
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
(NOTE: the 2026-07-01 determinism + skip-tag/orbital work is SIM-SIDE in the repo; re-deploy to the
install when you want the live mod to match.)

### CURRENT STATE (2026-07-10) — retained working mean death-ante **3.663** (n=160 paired), still 0 wins
**➡ THE authoritative plan is `WINRATE_AUDIT.md` (audit + roadmap + implementation logs). Fresh-session
handoff: `NEXT_SESSION.md`. Full running log: `selfplay-system-plan` memory. Superseded plans: `docs/archive/`.**

Current retained working baseline: `sim_out/p5_commit.jsonl` **3.663 death-ante / 3.345 progress**
(n=160); last committed baseline remains `p4_surv` (3.612 / 3.300) until explicitly committed. The
**WINRATE_AUDIT** (2026-07-05) overturned the earlier "the ante-4 wall is ARCHITECTURAL" conclusion as
**confounded by a sim world that couldn't express the winning archetypes**, and drove Phases 0–6:
Phase 0 (paired tooling) → Phase 1 (world fidelity A1–A9) → Phase 2 (engine valuation B/C/K) → Phase 3
(re-litigate the graveyard) → Phase 4 (low-risk pass complete) → Phase 5 (planner, IN PROGRESS).
Faithful-world arc: scorer2 3.513 → a789 3.450 → k12 3.575 → **base160 3.550 →
p3_levelneed 3.569 → p4_surv 3.612 → p4_f6f7 3.625 → p5_commit 3.663**.
**Verdict standard is now PAIRED n≥160** (the sim is byte-deterministic per seed; a residual determinism
bug was fixed 2026-07-07). Compare with `analyze_runs.lua <A> compare <B>` (sign test + progress Δ).

**THE #1 TUNING RULE (proven across every phase): ship UNIT/MECHANISM/CORRECTNESS fixes freely; ANY
isolated measurement/value re-weight that doesn't co-move the constants tuned around it BACKFIRES.** The
consistent revert set: C1, B3, F3, F4, F8 (Phase 2–4) + the whole pre-audit graveyard (swap-damp,
leveling-need-on-broken-world, coupled, cost-discount, xmult-floor). The wins were all correctness/mechanism
(A1–A9 fidelity, B1/C2-C3/B5/B2/K-fixes), the additive "boost a needed piece" shape (first-scorer +0.163;
leveling-need-on-FAITHFUL-world +0.012 — it FLIPPED once the world was fixed), or a superior-machinery swap
(F1/F2 boss-aware survival arbitration, +0.038 sign 31/18 — the best single-lever signal of the effort).
**Corollary:** in-blind changes CASCADE the seeded RNG — a balanced sign test + high variance = churn, not a
win (F4/F8). NOTE: `xmult_scaling` jokers ARE xmult — use `JokerData.is_xmult()`.

**THREE REAL HUMAN WINS analyzed** (`bes_runs.jsonl`; `winning-archetype-from-real-run` memory) — Flush
House+leveling / Hologram+copier / economy→Bull+xmult; common thread = an XMULT stack the human KEPT.
In-blind PLAY verified near-optimal; the losses are BUILD, not play.

**THE REMAINING WALL is BUILD-ASSEMBLY.** Phase-3 confirmed deck-shaping levers stay refuted on the faithful
world because a greedy per-decision valuation can't *commit to and assemble* an archetype across many shops
(offer-rate-limited + cascade-dominated). **The evidence-backed next big lever is the committed-archetype
PLANNER (Phase 5)**. V1 is now retained (+0.033 progress, sign 17/11): sticky commitment co-moves
joker fit/retention, planet concentration, and deck target, but still has 0 wins and needs refinement.
F6/F7 are complete (+0.012, sign 13/8); live re-sync remains Phase 6. Do NOT
re-try the reverted valuation levers in isolation — only as coupled, co-calibrated changes.

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
