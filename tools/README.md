# `tools/` — an index

Thirty-odd analysis tools accumulated here with no map, which makes the expensive ones easy to
re-derive by accident. Each entry is the **question the tool answers**; the tool's own header
carries the method, the caveats, and (for most) the result it produced when it was written.

Almost everything here reads **existing** telemetry and costs nothing to run. Only the four marked
**[sim]** actually drive the simulator.

> **Maintainer tooling.** `deploy.sh`, `r2modman_state.py`, `package_r2.py`, `selfplay_watchdog.sh`, `game_click.ps1`
> and `selfplay_night.py` (see *Getting a change into the live game* and *Unattended live self-play* below) automate the author's own Windows / r2modman setup and
> unattended self-play sessions. They are not needed to use the mod or to work on the engine.

---

## Running batches and calling verdicts

| tool | question |
|---|---|
| `sim_par.sh` **[sim]** | run a batch across all cores and merge the shards. **The way to run any batch.** Refuses to start on top of existing shards (a real corruption once produced a false verdict) and integrity-checks every merge. |
| `sim_batch.lua` **[sim]** | single-core batch with live progress; `sim_par.sh` shards through it |
| **`merge_shards.sh`** | **recover a batch whose wrapper died before the merge.** The workers reliably outlive whatever kills the wrapper, so completed runs can sit in shard files looking like a failure. Replicates the merge exactly and refuses to touch shards that are still being written |
| `probe_sweep.sh` **[sim]** | run several `Probe.CONFIGS` as paired batches over the same seeds |
| `analyze_runs.lua` | the dashboard: death-ante histogram, per-ante trajectory, action summary, and `compare` for a paired A/B on the progress metric |
| **`verdict.sh`** | **run the whole verdict battery at once** — integrity, paired progress, paired wins, action summary — so a partial reading cannot be quoted as a result |
| `mcnemar_pair.lua` | paired **wins** (McNemar exact) + win-set overlap. A low overlap means the change re-rolls *which* seeds win rather than lifting a fixed set |
| `metric_agreement.lua` | does `progress` agree with wins? (1002 batch pairs: r = 0.901 — yes, except the pack channel) |
| `overfit_test.sh` / `overfit_report.lua` | difference-in-differences: does the engine generalise to held-out seeds? |
| `feature_diff.lua` | compare two batches' feature vectors at a fixed ante |
| `sim_profile.lua` **[sim]** | per-run timing and a sampling profile |

## The planner and the commitment

| tool | question |
|---|---|
| `commit_dist.lua` | what does the planner commit to, when, and how do those runs end? (board-matched, survival-conditioned) |
| `commit_gap.lua` | what is the commitment gate *rejecting*? |
| `commit_counterfactual.lua` | how often would a proposed change actually alter the commitment? (the frequency-ceiling check — run it **before** spending batch time) |
| `commit_firing.lua` **[sim]** | how often does a commitment reach a consumable valuation at all? |
| `played_hands.lua` | is "the hand you actually play" a usable commitment signal, and does agreeing with it predict the outcome? |
| `board_legibility.lua` | what fraction of a real board can the planner even see? (12.7%) |
| `winner_legibility.lua` | can it read a *winning* board? (8.7% — winners' boards are hand-agnostic) |

## Valuation

| tool | question |
|---|---|
| `celestial_price.lua` | what is a Celestial pack worth, and what *should* it be? (found the level_gain unit error) |
| **`pacing_screen.lua`** | how often would a change to `growth_factor` move a real pace VERDICT? Replays the bands off recorded telemetry (`g` is exactly recoverable from `pace_margin`). ⚠ Its first version measured only the binary `on_pace` and said 4% — "don't batch". The real figure, counting the four `pace.margin` bands the shop advisor actually reads, is **15–18%**. **Screen every consumer, not the obvious one** |
| **`growth_truth.lua`** | what growth does the engine actually REALIZE, against what `Pacing.growth_factor` predicts? **Found the trend inversion** (realized 5.60 -> 1.03 while the model rises 1.47 -> 2.68). Ground truth was in `metrics.capacity` in every batch ever run and had never been looked at |
| **`slotgate_screen.lua`** | model a proposed `growth_factor` change over recorded states without touching engine code. Caught a drafted fix over-correcting (46% band flips, but below realized growth at a3) |
| **`level_scale_screen.lua`** | what does the derived leveling-persistence factor do to boards that really occurred? Reports the new/old RATIO by ante, not a firing rate — the factor is continuous, so there is no threshold to cross |
| `pack_terms.lua` | the actual terms behind a pack's shop value, wallet by wallet |
| **`joker_realized.lua`** / **`joker_realized_report.py`** | does a bought joker become worth what the shop paid for it? Replays every live shop BUY in `bes_fixtures.jsonl` with the current engine: predicted = the shop's scoring gain at the buy, realized = its leave-one-out marginal (same unit) at the first shop of each later ante while held; report by class / buy ante / joker. 2026-10-10 (620 buys): flat jokers keep ~0.4 of their share per ante, additive scalers are priced up to ~20x what they realize (Runner 2.26 -> 0.11), xmult scalers ~1/3 of it. Caveats: card-order-blind (understates Hanging Chad / Photograph), blind to Hiker's per-card chips. `luajit tools/joker_realized.lua <fixtures> <out.jsonl>` then `python tools/joker_realized_report.py <out.jsonl>` |
| `death_wallet.lua` | how much money is the engine holding when it dies? (a mechanism check `progress` cannot see) |
| `key_coverage.lua` | do catalogue keys match the ones the real game emits? (147 live keys, 0 misses) |
| `acquisition_profile.lua` | quantify the acquisition halt the slot probe exposed |

## The human dataset

| tool | question |
|---|---|
| `divergence.lua` | the engine's own valuation paired against what a winning human actually did |
| `pick_order.lua` | reproduce the measured human/engine pack-pick divergence |
| `real_vs_sim.lua` | is the simulator's world as generous as real Balatro? (yes — settled) |
| **`replay_fixtures.lua`** | replay the CURRENT engine over the human's captured decision states (`bes_fixtures.jsonl` from the live mod's capture-only mode) -> `picks.jsonl`. The "run the eval while you sleep" half of the agreement objective |
| **`agreement.py`** | join those engine picks to what the human ACTUALLY did (blind plays, pack picks, shop buys/rerolls/vouchers) and report per-decision agreement per channel. Auto-discovers the winning-run pool. Found: engine plays DIFFERENT cards 83% of shared plays, over-buys 26% + over-rerolls 15% vs winners |
| **`blind_outcome.lua`** | for each blind decision where engine & human played DIFFERENT cards, forward-simulate BOTH with `Sim.survive_after` (CRN) + take each play's immediate score. Answers "who is right." Found: 88% BOTH clear (survival-neutral); the engine clears in ONE big hand (88%) & banks unused hands while the winner plays WEAKER hands (0.32x vs 1.70x target) to MILK the blind for value/scaling -- in-blind economy generation the engine misses |
| **`seed_flip_probe.lua`** / **`seed_flip_report.lua`** | which recorded shop / pack decisions change their TOP PICK when only the Monte-Carlo seed changes, which estimator causes it (pace / pack EV / reroll-pool EV / joker value / consumable value), and what sample count stops it. Replays `bes_fixtures.jsonl` as the live mod calls the advisors (no engine change). **Found (2026-09-28): 35% of live decisions flip; reroll-pool EV is the top source** |
| **`live_gap.lua`** | live vs sim death RATE per blind played (Small/Big/Boss, by ante band), with skips inferred. `lua tools/live_gap.lua <bes_runs.jsonl> <from_line> <sim.jsonl>` |
| **`live_audit/play_realisation.lua`** | every live Small/Big play re-scored by the current engine vs the game's actual score: share under 0.8x, deterministic vs chance plays, guaranteed-clear failures. `luajit tools/live_audit/play_realisation.lua tools/live_audit/seeds_2026-09-28.txt` (one seeds file per live session, e.g. `seeds_2026-10-01.txt`). 2026-10-01: found the Obelisk pre-score reset (the last deterministic play under 0.8x) |
| **`owner_continue_trace.lua`** **[sim]** | what does the engine do FROM a human's position? Continues the sim from any recorded blind start (Small/Big/Boss, real boss) with full traces, plus ablations (`CONT_MONEY` / `CONT_DECK=std` / `CONT_JOKERS=<boards>`) that swap one part of the human position for the engine's typical one. Paired by world seed. 2026-10-23: exposed the full-board reroll inflation, the never-expiring economy commitment and SAVE-at-high-risk |
| **`arm.sh`** | the resumable A/B arm runner (see CONTRIBUTING.md, "The simulator and A/B verdicts") |

## Search / ceiling

| tool | question |
|---|---|
| `line_oracle.lua` | was a winning line available in this run? |
| `envelope.lua` | the reachability envelope over several policies — ⚠ read it as a **noise** measure, never as an oracle |
| `replay_states.lua` / `replay_lib.lua` / `extract_states.lua` | replay a fixed corpus of in-blind decision states under the current engine |
| **`money_gap.lua`** | how much in-blind money does the engine leave on the table? Reads the sim's `blind_result.money_gap` telemetry (2026-10-07+, decision-neutral): money per blind, spare discards / hands, money cards within reach of the spare discards (exact under CRN), discard-to-money jokers owned. Result: ~$0.2-0.5/blind -- docs/PLAN_2026-10-07_money_farming.md |
| **`money_gap_live.py`** | the same on LIVE runs (`bes_runs` + `bes_fixtures`; within-reach is an expectation, live has no pile order) |

## Live smoothness (the time-sliced evaluation)

| tool | question |
|---|---|
| **`yield_gaps.lua`** | how long does each live recommendation take, and how long can it run between slice boundaries (= the worst animation stutter)? `luajit tools/yield_gaps.lua [--per N]` over the newest recorded decisions per kind. 2026-10-02: shop ~5 s (max 10 s) total; gap p99 3-6 ms, max ~50 ms |
| **`flagged.lua`** | which decisions were saved to `bes_flagged.jsonl` (a misplay flagged in-game, or the automatic save of a lost run)? `luajit tools/flagged.lua [--list] [--flag "<id>"] [--replay]` -- one flag holds the last ~12 decisions (the key is usually pressed AFTER the misplay; `steps_before` 0 = on screen at the press), each a full fixture-format state; `--replay` re-decides them with the current engine |
| **`slice_check.lua`** | is time-sliced advice identical to synchronous advice, with no yield inside a C call? Run it after touching any engine loop; exit 1 on a mismatch |

## Getting a change into the live game

| tool | question |
|---|---|
| **`deploy.sh`** | **is the running mod the code I just wrote?** Mirrors the whole tracked tree into BOTH install targets — the r2modman profile and the old `%APPDATA%/Balatro/Mods` folder a plain Steam launch falls back to — then rebuilds r2modman's file manifest. Handles adds, edits **and** deletions, and compares with `--strip-trailing-cr` so the CRLF/LF split does not read as drift. `--check` reports and writes nothing; `--no-legacy` skips target 2. Use it instead of copying the files you edited: that is what drifted the install by six files |
| `r2modman_state.py` | rebuild r2modman's own manifest for the mod (`mods.yml` entry + `_state/*.yml`) from what is on disk, at `your_mod.json`'s version. `deploy.sh` calls it; run it standalone only if the profile's state looks wrong |

---

## Unattended live self-play

| tool | question |
|---|---|
| **`selfplay_watchdog.sh`** | keep the in-game self-player running overnight: relaunches Balatro with the one-shot `bes_autostart` file on a crash / stall / loop, closes SteelSeries capture and protects memory, stops at `BES_SELFPLAY_STOP` (default 07:00), hands over ("NEEDS MANUAL") after 3 failed relaunches. Launch it hidden (no console window) so it is not closed by accident |
| **`game_click.ps1`** | take manual control of the live game: screenshot + click at 1280x720 coordinates (F-keys sent as keys do not reach LOVE) |
| **`selfplay_night.py`** | summary of a session: runs, deaths, boards, buys, self-player actions, think-time gaps, failures (`python tools/selfplay_night.py <runs_line_offset> <autoplay_line_offset>`) |

## Two habits worth keeping

**Measure the firing rate before batching a change.** A change that touches one joker fires in ~5%
of runs and cannot move an n=160 verdict no matter how right it is. `commit_counterfactual.lua` is
the template: replay the real decision function over recorded states and count the crossings.

**A near-zero measurement may mean the measurement never fired.** At the default sample counts,
comparing card enhancements returned *identical* values because the added card never landed in a
sampled hand — which reads exactly like "the engine can't tell them apart". Check the sample count
before believing a null.
