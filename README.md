# Balatro Engine Sim — Decision Assistant & Self-Player

A Balatro mod (Steamodded + Lovely) that reads the live game state and recommends the best move — what to
play, discard, buy, sell, reroll, skip, pick from a pack, and which consumables to use — with a reason for
each. It can also **play whole runs by itself** (F11), restarting finished runs automatically (F6), which is
how its advice is tested in the real game.

Every recommendation comes from **measuring** options against your actual deck and board (Monte-Carlo over
real hands, scored by a faithful re-implementation of Balatro's scoring), not from fixed tier lists.

## Status

- **Autonomous win rate:** about **25–30%** in the headless simulator (red deck, white stake; 160-seed paired
  batches, confirmed on a fresh seed pool). For scale: it was ~6% in late September 2026 and ~1% in August.
- **Live:** the in-game self-player regularly reaches antes 5–8; its runs are reviewed to find live-only bugs.
- **Tests:** 1278 headless unit tests + 605 simulator tests, all green.
- The full, current handoff (what shipped, what was measured, what's next) is in **`NEXT_SESSION.md`**.

## What it advises

- **Play / discard** — the best play for this blind on a survival objective, and discards that *dig*
  toward the hand your jokers reward (measured on real redraws, board-aware), including economy discards
  (Faceless, Mail-In Rebate, Trading Card, Burnt Joker levelling, Sixth Sense) and card order (Hanging
  Chad, Photograph, ×mult placement).
- **Shop** — buy / sell / reroll / save in one currency with an interest-aware bankroll plan; jokers valued
  by measured scoring now and projected to mid-run (deck and level growth); swaps on a full board; vouchers
  valued by what they do for this run; buys that a reroll would replace are made first.
- **Packs** — which card to take and in what order: planets by the hands you actually play, tarots and
  spectrals by their measured effect on your deck (targets named from your drawn hand), Standard-pack cards
  by a paired with/without measurement plus seal/edition value, jokers against your board (with the
  make-room sale when full).
- **Blind select** — skip for a tag vs play, including Riff-Raff/Cartomancer-style generators.
- **Pacing** — whether the board is on pace for ante 8, which tilts economy vs power.

## In-game keys

| Key | Action |
|---|---|
| F6 | Auto-restart on/off (with self-play on, a finished run restarts after 4 s via the game's hold-R path) |
| F7 | Dump owned jokers' live `ability` tables (`bes_joker_dump.txt`), tagged scored / value-only / UNCOVERED |
| F8 | Force a re-evaluation |
| F9 | Show / hide the panel |
| F10 | Capture-only mode (log decisions, no evaluation) |
| F11 | Self-play on/off |

The panel shows a live `Self-play: ON/OFF   Auto-restart: ON/OFF` row. Pack choices show "Evaluating pack…"
until the measured decision is ready.

## Install

1. Install [Lovely](https://github.com/ethangreen-dev/lovely-injector), then
   [Steamodded](https://github.com/Steamodded/smods).
2. Copy the mod files (`main.lua`, `your_mod.json`, `core/`, `engine/`, `model/`, `ui/`, `util/`) into
   `%APPDATA%/Balatro/Mods/balatroenginesim/`.
3. Start a run; the panel appears in the HUD.

Telemetry is written to the LÖVE save folder (`%APPDATA%/Balatro/`): `bes_runs.jsonl` (the run),
`bes_fixtures.jsonl` (the full game state at every decision, for replaying misplays through the engine) and
`bes_autoplay.log` (what the self-player did).

## Development

The engine is **pure**: `core/state_extraction.lua` is the only file that reads the game; everything in
`engine/` is a function of plain Lua tables, so it runs and is tested headless.

```sh
lua tests/runner.lua                          # unit tests (no game needed)
luajit tests/runner_sim.lua                   # simulator integration tests
bash tools/sim_par.sh 160 <name>              # self-play batch across all cores -> sim_out/<name>.jsonl
lua tools/analyze_runs.lua sim_out/<A>.jsonl compare sim_out/<B>.jsonl   # paired A/B verdict
```

The simulator (`sim/`) drives the real engine through whole runs with the same telemetry as the live mod and
is deterministic per seed across processes, so A/B comparisons are paired and parallel batches are exact.
`tools/README.md` indexes the analysis tools.

## Layout

```
core/     state_extraction (reads G), run telemetry, replay fixtures, change signatures
model/    game_state / shop_state PODs
engine/   hand_eval (scoring), joker_effects / joker_data / joker_value (measured jokers),
          eval_function (run strength, forward valuation), decision_engine / discard_value /
          ordering / simulation (in-blind play), shop_advisor, pack_open_advisor, consumable_value,
          tarot, packs, vouchers, tags, skip_advisor, build_plan, pacing, boss_effect, ...
ui/       overlay panel, HUD drawing, autoplay (the self-player)
sim/      world (rules referee), content (shops/packs/tags), driver (run loop)
tools/    batch runners, analysis and replay tools (see tools/README.md)
tests/    headless unit + simulator suites
```

## Docs

| File | What it is |
|---|---|
| `NEXT_SESSION.md` | Current state, recent results and the prioritised next steps — start here |
| `CLAUDE.md` | Working guide: architecture rules, workflow, measurement rules, gotchas |
| `docs/ADVICE_REVIEW.md` | Live-run misplays reported by the owner and how each was fixed |
| `docs/GRAND_AUDIT.md` | Deep audit of the win-rate investigation (historical, still referenced) |
| `DESIGN.md` | Original design baseline (historical) |
| `docs/archive/` | Superseded plans |

## Known limits

- The engine reads face-down cards under some bosses (the Wheel, the House, …) — an information advantage
  it has no hidden-information model to avoid.
- The main open problem is **build assembly**: valuing a board as a set (copiers × ×mult × triggers) rather
  than as a sum of individual jokers.
- A green headless suite is necessary but not sufficient: fields marked `-- VERIFY` in
  `core/state_extraction.lua` depend on the game version and are confirmed only in-game.
