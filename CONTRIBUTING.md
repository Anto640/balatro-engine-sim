# Contributing

How the code is organised, how to test a change, and how changes are judged. For where the project stands and what is
open, see [`ROADMAP.md`](ROADMAP.md); `tools/README.md` indexes the analysis tools.

Maintenance is sporadic. Issues and pull requests against `main` are welcome but may wait.

## Architecture: the engine is pure

Data flows one way:

```
core/state_extraction  ->  model/game_state (plain tables)  ->  engine/* (pure functions)  ->  ui/* (panel, tags)
```

- `core/state_extraction.lua` is the **only** file that reads the game's global `G`.
- Everything in `engine/` takes plain Lua tables and never touches `G` or `love`. That is what makes the engine
  testable headless and lets the simulator drive the real engine. Keep it that way: a new engine input is a new
  field written by `state_extraction`.
- A field the engine reads but `state_extraction` never writes is silently `nil` in the live game while every headless
  test passes. When you add an input, check the live writer too.

## Tests

```sh
lua tests/runner.lua          # headless unit tests (Lua 5.1+ or LuaJIT; no game, no Steamodded)
luajit tests/runner_sim.lua   # simulator suites: drive the real engine per hand, take minutes
```

Run the unit suite after every change; it is kept fully green, so any `FAIL` is a regression (exit code non-zero).
Run the simulator suites too if you touch `sim/` or anything the in-blind play uses. LuaJIT is ~2.5x faster for
anything that runs the simulator. `tests/test_shop.lua` uses `table.unpack`, which is nil under LuaJIT when the file is
run on its own; run it through `tests/runner.lua`.

Green tests are necessary, not sufficient: fields marked `-- VERIFY` in `state_extraction` depend on the game version
and are only confirmed in-game.

## The simulator and A/B verdicts

`sim/` is a headless referee: seeded shuffles and deals, the real `decision_engine` for every hand, faithful scoring,
boss rules, shops, packs, tags and the economy. It writes the same JSONL record shapes as the live mod.

**Fidelity rule:** the simulator models the game's *rules* only (`mechanics`, `hand_eval`, `boss_effect`). The engine
under test is the only thing allowed to hold *opinions*. Don't make the world smarter; fix the engine.

```sh
bash tools/sim_par.sh 160 <name>                      # a batch across all cores -> sim_out/<name>.jsonl
lua  tools/analyze_runs.lua sim_out/<name>.jsonl      # death-ante histogram, per-ante trajectory, action summary

# an A/B arm: run the commit under test from its own worktree, then compare paired with a baseline arm
git worktree add ../bes_wt_<name> HEAD
bash tools/arm.sh <name> ../bes_wt_<name> <workers> [n=160] [seed_off=3] [ENV=VAL ...]
lua  tools/analyze_runs.lua sim_out/<baseline>.jsonl compare sim_out/<name>.jsonl
```

- Run every arm from a worktree: modules load when a worker starts, so editing the tree mid-batch contaminates it.
- Run at full fidelity (no Monte-Carlo cap); the cheap path distorts decisions.
- The simulator is deterministic per seed across processes, and shops, packs, deals, tags and bosses each draw from
  their own seeded stream, so a re-run is byte-identical and every A/B is **paired** on the same seeds.

### The verdict standard: paired, n >= 160

A batch's sensitivity depends on how much the change cascades through the rest of the run (the per-seed standard
deviation), not on `n` alone. The minimum detectable effect at 80% power is about `2.8 × sd / sqrt(n)`:

| change shape | typical sd | detectable at n=160 |
|---|---|---|
| narrow, late-firing (one decision late in the run) | ~0.07 | ~0.015 antes |
| broad re-weight or a world change | ~1.2 | ~0.27 antes |

So:

- **Always pair** (same seeds, both arms) and use n >= 160. An unpaired mean from a small batch can be off by more
  than any single improvement this project has shipped.
- **"Not significant" is not "no effect."** State the detectable effect before calling a null.
- **Check the firing rate first.** A change that touches one joker fires in roughly 5% of runs and cannot move a
  160-seed verdict however right it is. Only systems (the shop loop, the economy, in-blind play, leveling) can. Replay
  the decision function over recorded states and count how often it changes the answer before spending batch time.
- **Burden of proof depends on the change.** A correctness fix (the code was provably wrong) ships unless it measures
  significantly negative; the live mod advises a human, so wrong advice matters even when it is sim-neutral. A tuned
  constant needs positive evidence. Revert on a mechanism you can name, not on a null result.
- A gain carried by the mean is replicated on fresh seeds (`seed_off`) before it is trusted.

## Rules that are easy to break

- **Determinism.** Live advice is recomputed on every state change. Anything that samples must use a per-state seeded
  RNG (see the `lcg` / `*_seed` helpers in `shop_advisor`, `decision_engine`, `pack_open_advisor`, `search`). Global
  `math.random` makes the panel flicker between ticks; treat that as a bug.
- **Time-sliced evaluation.** Live recommendations run in a coroutine that yields at `HandEval`'s slice boundaries so
  the game keeps animating. A new heavy loop that scores without going through `each_subset` must call
  `HandEval.yield_tick()`, and nothing may score inside a C callback (a `table.sort` comparator, `gsub`): a yield there
  errors in the live game. `tools/slice_check.lua` and `tools/yield_gaps.lua` check this.
- **Live-key mismatches are silent zeros.** A joker's in-game key can differ from the catalogue key (the base game
  spells Gluttonous Joker `j_gluttenous_joker`; Showman is `j_ring_master`). A mismatch makes the joker score zero
  everywhere. The mod logs `[BES][WARN] uncovered joker key ...`; when adding a joker, use the live key (alias both
  spellings if unsure). The coverage test checks catalogue against effects, not against the game.
- **Measured, not static.** Joker, card and consumable strength is measured against the player's deck (Monte-Carlo).
  The tiers in `joker_data` are a fallback prior for unmodelled cases, not the truth.
- **Created things need a slot.** Anything that creates a joker or consumable is worth only what lands in a free slot.
  Use `Generators.output_fit` / `has_output_room` rather than re-deriving the check. A full consumable tray is
  temporary (using a card frees it); a full joker board is not.
- **Tarot targets come from the drawn hand**, not the deck. Break ties by card `id` so the named card is stable.
- **Value scales.** Jokers, packs, rerolls and consumables share one scoring-fraction unit (the ×5
  `JOKER_SCORE_WEIGHT` bridge); real-dollar terms stay in dollars.
- **Loader.** Steamodded does not add the mod folder to `package.path`; `main.lua` registers its own searcher. Headless
  tests set `package.path` instead and bypass it.

## Replaying a live decision

The live mod records the full game state at every shop, pack, blind-select and in-blind decision in
`bes_fixtures.jsonl` (LÖVE save folder). A reported misplay is best diagnosed by replaying that exact state through the
current engine, not by rebuilding the board from a description:

```lua
local gs = require("core.replay_fixture").rehydrate(Json.decode(line))
require("engine.shop_advisor").recommend(gs, {})        -- or engine.pack_open_advisor for a pack
```

Fix the cause, then replay the same fixture to show the advice changed.

## Trying a change in the game

The game loads mod code only at startup. Copy the mod files (`main.lua`, `your_mod.json`, `config.lua`, `core/`,
`engine/`, `model/`, `ui/`, `util/`) into your Mods folder, or build an r2modman package with
`python tools/package_r2.py`, and restart Balatro. Don't leave a second copy of the mod inside `Mods/`: Steamodded
loads it as a separate, conflicting instance.
