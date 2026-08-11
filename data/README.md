# `data/` — captured live-game telemetry

Real telemetry written by the **live mod** while a human played Balatro. This is the only
data in the project that is *not* reproducible by re-running anything: the simulator can be
re-run at will, these runs cannot. Copied here so they survive a save-folder wipe, a mod
reinstall, or a machine change.

Source: the LÖVE save folder, `%APPDATA%\Balatro\` (written by `main.lua` —
`BES_RUNLOG = "bes_runs.jsonl"`, and the `F7` handler for the joker dump).

## Files

| file | captured | size | contents |
|---|---|---|---|
| `bes_runs.jsonl` | through **2026-07-02** | 1948 records | 22 runs started, 14 completed: **1 win, 13 deaths** |
| `bes_runs_baseline.jsonl` | **2026-06-25** | 244 records | the **pre-fix** baseline: 5 runs started, 4 deaths, 0 wins |
| `bes_joker_dump.txt` | **2026-06-28** | 2 jokers | `F7` dump of live `ability` tables (Runner, Wee Joker) |

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
the joker lists of the runs that went deep. `CLAUDE.md` and the `winning-archetype-from-real-run`
memory draw the "keep the xmult stack" conclusion from human wins; only **one** of those is
present as a `"kind":"win"` record in this capture.

The real-world trajectory here is also the calibration target for `sim/world.lua` — the
comparison `NEXT_SESSION.md` asks for ("compare the dollar trajectory in `bes_runs.jsonl`
vs the sim") is run against this file.

## Refreshing after more play

The game appends, so a later capture is a superset. Re-copy with:

```powershell
Copy-Item "$env:APPDATA\Balatro\bes_runs.jsonl" data\bes_runs.jsonl -Force
```

`.gitattributes` marks these `-text` so they are stored and checked out byte-for-byte. That
matters: `core.autocrlf=true` on Windows would otherwise rewrite the game's pure-LF output
to CRLF on checkout, leaving a stray `\r` inside the last JSON value on every line.
