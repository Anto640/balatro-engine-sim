# CLAUDE.md — working context for AI assistants

Project guide for anyone (human or AI) editing this repo. See `README.md` for the
feature-level overview and `DESIGN.md` for the original (historical) design baseline.
Despite the historical filename, this guide applies equally to Codex and other coding agents.

## What this is

`balatroenginesim` is a **Balatro decision-assistant mod** (LÖVE2D / Lua, Steamodded
+ Lovely). It reads live game state from the global `G`, evaluates every legal
action, and overlays a ranked "best move" with a reason. Roadmap M1–M4 is complete
plus a large correctness/coverage/strategy pass.

> ### The main diagnostic: replay the recorded decision state (`docs/ADVICE_REVIEW.md` R8)
> **A live misplay can now be traced from board state → valuation → the exact line of code, because the mod
> records both the run and the DECISION STATE.** The loop, in four steps:
> 0. if the owner pressed **F5** at the misplay, start from **`bes_flagged.jsonl`** (`luajit tools/flagged.lua --replay`): it holds
>    the last 4 decision states before the press (the one on screen + 3), already in fixture format -- skip to step 3;
> 1. owner reports a misplay → find the run in **`bes_runs.jsonl`** (in the LÖVE save folder, `%APPDATA%/Balatro/`)
>    — `joker_gain`/`joker_loss`/`death` records give the board over time and the death stats;
> 2. pull the matching decision from **`bes_fixtures.jsonl`**, which stores the FULL `gs` at every shop/pack
>    decision (`core/replay_fixture.lua` writes it);
> 3. **replay that `gs` through the current engine** (`SA.recommend(gs, {})`, `Eval.joker_marginal_fv`, …) and
>    watch it reproduce the misplay on the real state;
> 4. fix, and re-replay the same fixture to prove the advice changed.
>
> Minimal replay: `local gs = require("core.replay_fixture").rehydrate(Json.decode(line))` for the fixture line, then
> `require("engine.shop_advisor").recommend(gs, {})` (shop) or `require("engine.pack_open_advisor").recommend(gs, {})` (pack).
>
> R8 used exactly this to convert *"it sold Greedy for a To Do List"* into two located defects and a verified
> fix in one session. **It beats reasoning from a synthetic board, which is how the same session's first
> attempt at that diagnosis went wrong** — a hand-built reconstruction picked a different funder and its
> "only Mult" measurement was invalid because the sampled hand contained no Diamonds at all. **Replay the
> recorded state; do not rebuild it from the description.**
>
> **Second diagnostic: continue the sim FROM a human's position** (`tools/owner_continue_trace.lua`, any recorded blind
> start, paired seeds, ablations that swap the deck / jokers / money for the engine's typical one). It exposes failures
> the engine's own runs rarely reach and attributes a human edge to a component -- `docs/HUMAN_RUNS_REVIEW_2026-10-23.md`.
>
> **Current state, the live install and next steps:** the START HERE block at the top of `NEXT_SESSION.md`. Read it
> before starting work. Dated status lives there, not here.
>
> **Focus: advice quality, driven by the in-game self-player.** `ui/autoplay.lua` (F11) plays real runs on the
> engine's live advice; the owner watches or leaves it unattended (F6) and reports misplays. Reviewing those runs is
> the assistant's job: replay the recorded decision (above), fix the defect it points to, and sim-verify anything that
> changes valuation. A live misplay is a hypothesis; the sim outcome decides.

## Architecture (one rule: the engine is PURE)

Data flows one way: `core/state_extraction` (the **only** file that reads `G`) →
`model/game_state` POD → `engine/*` (pure functions) → `ui/*` overlay. Every engine
module consumes plain Lua tables and never touches `G`, which is what makes the whole
thing **headless-testable**. See the Layout section in `README.md` for the per-file map.

## Build / test / run

- **Tool index:** `tools/README.md` lists the analysis tools, grouped by the question each answers.
  Read it before writing a new one; most read existing telemetry and cost nothing to run.
- **Tests (do this after every change):** `lua tests/runner.lua` (run via the Bash
  tool). Lua 5.1+/LuaJIT, no `love`/`G`/Steamodded needed. Both suites are kept fully green, so any FAIL is a regression.
  Failures print `FAIL  <case>  (got X, want Y)`; exit code is non-zero on failure.
  One known quirk: `tests/test_shop.lua` calls
  `table.unpack` (~line 1048), which is **nil under LuaJIT**, so that suite aborts there if you run it
  standalone with `luajit`. It is fine under `lua tests/runner.lua`, which is how it is meant to run.
- **Phase-1 simulator suites are SEPARATE** (they drive the real engine per hand and
  take minutes): `luajit tests/runner_sim.lua` (`test_world`, `test_driver`, `test_consumables`, `test_content_rates`, …). `luajit`
  is installed and ~2.5x faster — prefer it for anything that runs the `sim/` forward
  simulator (`World.play_blind` / `Driver.run`).
- **Deploy to the live game — `bash tools/deploy.sh` (the repo is NOT the install).**
  Green tests ≠ works in-game. `tools/deploy.sh --check` reports drift and writes nothing.
  **Stop hand-copying the files you edited** — that is what silently drifted the install by SIX
  files once, and it also cannot see DELETIONS: `ui/hud_inject.lua` became `ui/hud_panel.lua`, and
  a leftover `.lua` still gets loaded. The script mirrors the whole tracked tree instead.
  Since 2026-10-01 the game runs through **r2modman** (Balatro Mod Manager was shut down), so there
  are **TWO** install targets and `deploy.sh` keeps both current:
  1. `%APPDATA%/r2modmanPlus-local/Balatro/profiles/Default/mods/Anto640-EngineSim/` — what an
     r2modman launch loads (`steam.exe -applaunch 2379780 --mod-dir "<profile>/mods"`). Imported
     2026-10-02 from `python tools/package_r2.py`'s zip via r2modman's Import local mod, so r2modman
     lists it. ⚠ r2modman RESTORES the mod from `cache/Anto640-EngineSim/<registered version>` (the installed `manifest.json`'s, still 0.5.0) at every launch -- `deploy.sh` now writes that cache too (2026-10-04: until then every deploy since the import was undone at launch). `deploy.sh` keeps that package's own files (`manifest.json`, `icon.png`,
     `mm_v2_manifest.json`) and falls back to the older `mods/balatroenginesim/` only when the
     package folder is absent. **Never leave a second copy of the mod inside `mods/`.**
  2. `%APPDATA%/Balatro/Mods/balatroenginesim/` — the OLD folder Lovely falls back to on a plain
     Steam launch with no `--mod-dir`. It is not harmless dead weight: left behind it makes a plain
     launch run STALE code silently. `--no-legacy` skips it.
  For a FRIEND's install, build the zip with `python tools/package_r2.py` (bump `your_mod.json`'s
  version first) and send `dist/Anto640-EngineSim-<version>.zip` for r2modman's Import local mod.
  The older local-mod registration also rebuilds r2modman's own file manifest (`tools/r2modman_state.py`,
  called by `deploy.sh` for the `balatroenginesim` target only). ⚠ r2modman ships a far newer
  **Steamodded 26.829.0** (vs BMM's `1.0.0~BETA-1620a`); the mod uses `SMODS.load_file` and the
  per-mod config / `config_tab` API, so suspect those first if the panel or settings page never appear.
  Verify drift with `diff -q --strip-trailing-cr` (the checkout is CRLF, the install LF, so a byte
  compare reports false differences — `deploy.sh` already does this). Keep backups outside `Mods/`:
  Steamodded loads any copy inside it as a second, conflicting instance of the mod. The game loads
  code only at startup, and only the owner starts or restarts Balatro.
- **Live logs** (save folder `%APPDATA%/Balatro/`): `bes_runs.jsonl` (run telemetry), `bes_fixtures.jsonl` (full `gs` per
  decision), `bes_autoplay.log` (self-player actions and failures). Crashes: the Lovely log in the profile's `mods/lovely/log/`.
- **In-game debug keys:** `F5` FLAG A MISPLAY (saves the last 4 decisions to `bes_flagged.jsonl`; a lost run also saves its last 12 there automatically, flag id `<date> death`); `F7` dump owned jokers' live `ability` tables (to the console
  and to `bes_joker_dump.txt` in the LÖVE save folder, each tagged
  `scored`/`value-only`/`UNCOVERED`); `F8` force a re-evaluation; `F9` toggle the overlay;
  `F10` capture-only toggle (log decisions, no eval); **`F11` AUTO-PLAY toggle** (the self-player,
  `ui/autoplay.lua`, default OFF — plays whole runs; logs to `bes_autoplay.log`; while it plays, `ui/fast_mode.lua`
  skips animations through the Handy mod's own skip ('Everything', x16) without touching Handy's saved settings, and
  the engine thinks in 50 ms slices); **`F6` AUTO-RESTART toggle** (default OFF — with
  auto-play on, a finished run (game over / win) is restarted via the game's hold-R path after 4 s, so runs chain
  unattended). The advice panel is a native row at the top of the left HUD (`ui/hud_panel.lua`; label reads
  `Auto` while self-playing); hover it for the reason, stats and `Self-play` / `Auto-restart` status. Tags on the
  recommended card / shop item / button come from `ui/highlights.lua`. Settings (panel, tags, fast self-play, its
  speed): Mods menu > Engine Sim > Config (`ui/settings.lua`; defaults in `config.lua` -- deploy it with the rest).

## Self-play simulator & data-driven tuning (the main tuning workflow)

The engine is tuned by running a **headless self-play simulator** that drives the REAL engine
through whole runs, then analysing where/why it dies and fixing the cause. This is the primary
way to improve the engine. History and past audits: `docs/GRAND_AUDIT.md` and `docs/archive/`.

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
bash tools/sim_par.sh <n_seeds> <name>             # PARALLEL -> sim_out/<name>.jsonl  [PREFER THIS]
luajit tools/sim_batch.lua <n_seeds> <name>        # single-core -> sim_out/<name>.jsonl, live [k/N] progress
lua  tools/analyze_runs.lua sim_out/<name>.jsonl   # death-ante histogram, per-ante trajectory,
                                                   #   ENGINE ACTION SUMMARY + COUNTERFACTUAL
lua  tools/analyze_runs.lua sim_out/<name>.jsonl trace [seed]   # one run's blow-by-blow timeline

# A/B arm (how verdicts are run): a worktree of the commit under test, then the resumable runner from the main checkout
git worktree add "$TMP/bes_wt_<name>" HEAD
bash tools/arm.sh <name> "$TMP/bes_wt_<name>" <workers> [n=160] [seed_off=3] [ENV=VAL ...]   # merges to sim_out/<name>.jsonl
lua  tools/analyze_runs.lua sim_out/<baseline>.jsonl compare sim_out/<name>.jsonl         # paired verdict
```
- **Run FULL FIDELITY** (no `mc_cap` arg). The `_G.BES_MC_CAP` cheap-path **distorts** decisions
  (cap=3 degrades in-blind play → too harsh); only for rough scans.
- **Speed (2026-10-19: hand_eval ~9x + LuaJIT trace cache ~2x in sim/driver.lua):** a 160-seed arm takes ~35-70 min on 11
  workers (was ~3-4 h; `BES_ARM_ORDER=<abs path to a previous arm>.jsonl` runs the longest seeds first; the timing
  notes below predate it). Older: batches run in parallel (one LuaJIT process per worker, interleaved seeds).
  Merged parallel output is byte-identical to sequential because the sim is cross-process deterministic
  (sorted-key sampling + stable tie-breaks).
- **Worker count (owner rule, updated 2026-10-08):** always **11**, whether or not the owner is using the PC -- batches run at
  BELOW-NORMAL priority (see the launch line under Toolchain), which keeps the PC and the CLI responsive, so do not drop
  to 4–6 workers. When memory runs low the
  shell gets killed but the workers usually survive: merge or resume their output with the resumable runner. If a
  batch was actually killed, rerun it (resuming from the finished seeds) without asking the owner first. The same goes
  for ANY job stopped for low memory or similar (probe, replay, watcher, a Claude Code background command killed by the
  memory-pressure reap): restart it without asking -- this standing owner permission overrides the reap notice's default.
  Restart it so the pressure doesn't repeat (run a probe after the batch, or drop a worker) and say what was done.
- **Say how long a batch will take.** When starting a batch or probe, tell the owner the estimated duration and
  the clock time it should finish, and update it when checking progress. **Measured 2026-10-09: a 160-seed arm takes
  ~2 h 45 min at 11 workers** (fs 08:01-10:45, hu 10:46-13:33; 50 ante-8 seeds alone ~80 min) -- ~3x the 2026-09-28
  figure (~50 min), which is stale. Estimate from the live rate (finished seeds / elapsed) once a run is under way; late
  seeds are slower, as runs that reach ante 8 last longest. **Always arm a completion watcher** (a background
  `until [ -f sim_out/<name>.jsonl ]` command) when a batch starts, and report the result as soon as it lands -- an arm
  that finished unreported for 2 h (2026-10-09) is the failure this prevents. **Measured 2026-10-13: under memory pressure
  (1-3 GB free) a run takes ~16 min per worker** -- a 40-seed arm on ONE worker is ~10 h; never run small arms one after
  another on 11 workers (the tail idles most of them) -- run several arms side by side, one worker each. Claude Code's
  low-memory reaper kills background watchers/commands: launch anything long DETACHED (hidden Start-Process) and have it
  write its result to a file.
- **Decision audits** (`tools/decision_audit*.{lua,sh,py}`): a flip re-rolls the rest of the run and one decision is sampled
  per run, so GROUP means are selection-biased -- always read flip minus PLACEBO (`tools/decision_audit_placebo.py`).
- **What to read in `analyze_runs`:** the **death-ante histogram** (push the mode later);
  **per-ante trajectory** ($ / jokers / **hand-lv** / pace_margin / run_str); **ENGINE ACTION
  SUMMARY** (what it bought / SOLD / **SKIPPED** = offered-but-not-taken, packs, rerolls,
  level-ups); **COUNTERFACTUAL** (avg tier bought vs skipped + strong jokers skipped). Tiers there
  are a **superficial fallback flag only** — the real signal is the MEASURED valuation and, at
  scale, survival-correlation. Use `trace` to see the actual buy→sell churn / skip sequence.
- **n matters:** at n≈16 the death-ante is pure noise; verdicts use paired n ≥ 160 (below). A re-run of the
  same seeds and engine is byte-identical, so every A/B is paired. The current baseline arm is named in
  `NEXT_SESSION.md` START HERE.
- **Common random numbers (2026-10-06):** shops, packs, deals, tags and bosses each draw from their own stream keyed by
  (seed, purpose, position) (`World.stream` / `checkpoint` / `keyed_shuffle`; `BES_CRN=0` = the old single stream), so a
  changed decision no longer re-rolls the rest of the run. Arms from before `1653688` are a different world and do not
  pair with newer ones. The remaining per-seed spread is mostly the change's real consequences, so power comes from n.
- **Money telemetry (2026-10-07):** every sim `blind_result` carries `money_gap` (money earned in the blind, spare
  discards / hands, money cards within reach of the spare discards) -- recorded after the blind, never read by a
  decision; `lua tools/money_gap.lua <arm>.jsonl` reports it. Ceiling probes `BES_PROBE=gold6` / `gseal6` start runs with
  6 Gold / Gold-seal cards (`sim/probe.lua` start_money); `rich1` / `rich2` / `rich4` add $1 / $2 / $4 a round.
- **Unattended live self-play:** `tools/selfplay_watchdog.sh` (launch hidden) + an empty `%APPDATA%/Balatro/bes_autostart` file
  (one-shot: turns on F11 + F6 and starts a Red Deck run). The owner authorises each session; see NEXT_SESSION / memory.


## Research history

The investigation log (winrate audits, operating-point results, refuted levers, the human-run dataset findings) is in
`docs/archive/CLAUDE_HISTORY.md` and `docs/GRAND_AUDIT.md`. Check it before re-trying a lever: most per-decision, economy
and planning levers have been measured, and the log records why each was kept or reverted.

Verdict standard: **PAIRED n≥160**; compare with `analyze_runs.lua <A> compare <B>`.

**Tuning rule: the burden of proof depends on the kind of change.** Read this before reverting anything.

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

**Two consequences:**

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

**Burden of proof by change class:**

- **Correctness / fidelity / feasibility** (the code was provably wrong): **ship it**, unless it measures
  significantly NEGATIVE. Justify by mechanism, not by the metric. Correctness compounds, and the live
  mod advises a HUMAN — wrong advice is bad even when sim-neutral.
- **Magnitude / weight tuning** (a constant moved): still requires positive evidence, still backfires in
  isolation, and should be calibrated JOINTLY with the constants tuned around it. Before
  filing a change as "magnitude", ask whether the constant is *derived* — a constant that follows from
  an argument (§19b's `X` cancelling, the SELL_TO_BUY refill charge) is correctness wearing a number.
- **Revert on MECHANISM, not on a null result.** A change should be pulled when you can say *why* it is
  wrong. (Worked example: the 2026-08-11 reroll feasibility gate measured +0.024 n.s. — by itself that
  is no reason to pull it — but it was pulled because a concrete mechanism explained the harm: it damped
  rerolls that were earning value through CONSUMABLES, which `e_best` never prices.)

**Standing measurement rules:**
- Judge changes at baseline income: the engine must generate its own money. `BES_PROBE=rich10` is a diagnostic
  for a mechanism that needs spare money to show up, never the verdict on its own.
- The 7-win human corpus is the owner's playstyle, not ground truth. Sim outcomes (wins, reach-8) decide, and a gain
  carried by the mean is replicated on fresh seeds (`BES_SEED_OFF`) before shipping. Run that fresh-seed arm ONLY when
  the first arm is promising (paired progress up, wins not down) -- a neutral or negative first arm needs no
  confirmation, and correctness fixes need just one regression arm (owner 2026-09-29: don't double-run by default).
- Run each A/B arm from a git worktree. Modules load when a worker starts, so editing the tree mid-arm contaminates it.
- Compare against the current baseline arm named in `NEXT_SESSION.md` START HERE, paired on the same seeds.

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

**Also:** in-blind changes cascade the seeded RNG, so prefer narrow/late-firing
changes whose sd is small enough to actually measure; prefer the screen-then-batch harness; a fix pays
only when the thing it fixes is BOTH strong AND frequent (W6 yes, W7 weak, W8 too rare).
NOTE: `xmult_scaling` jokers ARE xmult — use `JokerData.is_xmult()`.


## Conventions & gotchas (learned the hard way)

- **Calculated, not static.** Joker/card/consumable *strength* is MEASURED from the
  player's deck (Monte-Carlo via `engine/joker_value`, `consumable_value`, etc.).
  `joker_data` tiers are only a **prior/fallback** for unmodelled cases — never the truth.
- **Determinism.** Live recommendations re-run every state change, so any advisor that
  samples MUST use a **per-state seeded RNG** (see the `lcg`/`*_seed` helpers in
  `shop_advisor`, `decision_engine`, `pack_open_advisor`, `search`). Using global
  `math.random` makes the panel **flicker** between ticks — treat that as a bug.
- **Live evaluation is time-sliced** (2026-10-02): every recommendation runs in a coroutine that yields at
  `HandEval`'s slice boundaries (`HandEval.yield_tick()`, one per 16 scored candidates), so the game keeps
  animating while the panel shows "Thinking". A NEW heavy loop that scores without going through
  `each_subset` must call `HandEval.yield_tick()`, and never score inside a C callback (a `table.sort`
  comparator, `gsub`): a yield there errors live. Check with `tools/slice_check.lua` / `tools/yield_gaps.lua`.
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
  ⭐ **This applies to generator JOKERS too, and forgetting it cost a run** (`docs/ADVICE_REVIEW.md` R8).
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
- **Toolchain on this machine:** `lua`/`luajit` need
  `export PATH="$PATH:$HOME/AppData/Local/Programs/LuaJIT/bin:$HOME/AppData/Local/Programs/Lua/bin"` in
  every Bash call. From PowerShell, `bash` resolves to WSL; launch a detached batch with
  `Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c start "" /b /belownormal "C:\Program Files\Git\bin\bash.exe" -l <script>'` -- HIDDEN (no window: the owner closes stray windows, which kills the batch; a visible `start /min` launch
  was used 10-05/06 by mistake) and BELOW-NORMAL priority, inherited by every worker (11 normal-priority workers on this
  6-core/12-thread CPU made the Claude Code CLI crawl; owner 2026-10-05) -- so a memory reap of
  the session shell can't stop it.

## Git

The public repo is `Anto640/balatro-engine-sim` (renamed from `balatro_engine_new` 2026-11-08); `main` is its only remote branch and is the
published state. Work happens on the local branch `winrate-v4-bundle` (no remote counterpart since 2026-11-08); fast-forward `main` to it
and push `main` when a batch of changes is confirmed -- last synced 2026-11-08 (baselines in NEXT_SESSION). **Commit and push whenever you (the AI
assistant) judge it appropriate — you do NOT need to wait to be asked** (owner directive, 2026-08-28).
Use judgement: commit at coherent checkpoints with a clear message, keep the tree green, and don't
bundle unrelated changes. Run the test suite before committing.
