# `data/` — captured live-game telemetry

**What this is:** the maintainer's own recorded live runs — game states, decisions and seeds only, no personal data.

Real telemetry written by the **live mod** while a human played Balatro. This is the only
data in the project that is *not* reproducible by re-running anything: the simulator can be
re-run at will, these runs cannot. Copied here so they survive a save-folder wipe, a mod
reinstall, or a machine change.

Source: the LÖVE save folder, `%APPDATA%\Balatro\` (written by `main.lua` —
`BES_RUNLOG = "bes_runs.jsonl"`, and the debug joker-ability dump for `bes_joker_dump.txt`).

## Files

| file | captured | size | contents |
|---|---|---|---|
| `bes_runs.jsonl` | through **2026-07-02** | 1948 records | 22 runs started, 14 completed: **1 win, 13 deaths** |
| `bes_runs_baseline.jsonl` | **2026-06-25** | 244 records | the **pre-fix** baseline: 5 runs started, 4 deaths, 0 wins |
| `bes_joker_dump.txt` | **2026-06-28** | 2 jokers | debug dump of live `ability` tables (Runner, Wee Joker) |
| **`bes_runs_live_2026-08-12.jsonl`** | **2026-08-13** | 2400+ records | **8 EXPERT runs, 7 WINS.** The single most valuable file in the project — see below |

`bes_runs_baseline.jsonl` is the "measure against this" file referenced by
`docs/archive/TUNING_PLAN.md`; it predates the base-value fix pass, so do **not** merge it
into `bes_runs.jsonl` — they are different engines.

`bes_joker_dump.txt` is the evidence behind the **chips-scaler read**: both Runner and Wee
accumulate in `ability.extra.chips` (not `ability.chips`), which is why
`joker_effects.scaled` MAXes `ability` against `ability.extra`. Keep it as the citation for
that behaviour.

## Reading it

The live telemetry uses the same JSONL record shapes as the simulator, so the normal
analyzer works directly:

```
lua tools/analyze_runs.lua data/bes_runs.jsonl
lua tools/analyze_runs.lua data/bes_runs.jsonl trace <seed>
```

Note the sample is far too small for a winrate — 1/14 carries a 95% CI of 0%–21%. Its value
is **qualitative**: the death contexts, the per-ante dollar/joker/hand-level trajectory, and
the joker lists of the runs that went deep. The "keep the xmult stack" conclusion drawn from
human wins rests on more runs than this; only **one** of them is present as a `"kind":"win"`
record in this capture.

The real-world trajectory here is also the calibration target for `sim/world.lua`: comparing
the dollar trajectory in `bes_runs.jsonl` with the simulator's is run against this file.

## Refreshing after more play

The game appends, so a later capture is a superset. Re-copy with:

```powershell
Copy-Item "$env:APPDATA\Balatro\bes_runs.jsonl" data\bes_runs.jsonl -Force
```

`.gitattributes` marks these `-text` so they are stored and checked out byte-for-byte. That
matters: `core.autocrlf=true` on Windows would otherwise rewrite the game's pure-LF output
to CRLF on checkout, leaving a stray `\r` inside the last JSON value on every line.


## `bes_runs_live_2026-08-12.jsonl` — the expert capture (2026-08-13)

Eight runs played by the mod's own user on **red deck / white stake** with the **overlay hidden
(F9)**, so their decisions are independent of the engine while every recommendation was logged
beside them. **7 wins in 8 runs (87.5%)** against the engine's ~1.25%.

What makes it uniquely valuable — and irreplaceable:

* **928+ records carry the engine's own `ranked` valuations** for every option it considered, next
  to what the human actually chose. That is a labelled divergence set: *where does a winning player
  take what the engine prices low?*
* **114 `blind_result` records** expose in-blind behaviour for the first time — `hands_used` and
  `discards_used`, so "cleared on hand 1" and "spent four hands digging" are finally distinguishable.
* **189 `blind_select` records** make play-vs-skip recoverable (previously a skipped blind left no
  trace at all).
* Seven **distinct** winning archetypes, with winning hand-levels from 7 to 40, plus **one loss**
  (X3L32ZEA) that died at ante 5 holding $52 with no build direction — the contrast case.

The `ranked` / `blind_select` / `blind_result` fields were added mid-capture, so runs 1–2 have
partial coverage and runs 3+ are complete. Analyse with `tools/real_vs_sim.lua` and
`tools/analyze_runs.lua`; full findings in `WINRATE_V3_PLAN.md` §5m–§5r.

**Do not regenerate or overwrite this file.** The simulator can be re-run at will; these cannot.
