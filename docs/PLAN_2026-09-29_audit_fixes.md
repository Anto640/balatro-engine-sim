# Plan: fixes from the three 2026-09-28 audits

Sources (full reports): sim-rules audit (job `5683c56b`), live-vs-sim gap audit (job `9a3e1089`, worktree
`live-only-audit`), seed-flip probe (job `ca93692c`, worktree `seed-flip-probe`, data in `sim_out/seedflip_2026-09-28/`).
Every item from all three is listed below with a decision. Batch times assume 11 workers (~50 min per 160-seed arm).

**Order and why.** Engine scoring bugs first (they are wrong in the live game today). Then fix the sim's rules, because
every A/B after that should be judged in a world that behaves like the real game, and the current baseline is inflated
(mostly by Cavendish). Engine tuning (reroll samples, pacing, guaranteed clears) comes last, measured on the corrected sim.

## Status (overnight 2026-09-29)
- Phase 1 DONE (`f86c375`): Baseball, Flower Pot, Ramen. Live replay: predictable plays <0.8x 5.1% -> 1.7%,
  guaranteed-clear failures 12 -> 5. Regression arm `sc19` vs fin18: neutral (155/160 tied, wins 50 -> 51) -- kept.
- Phase 2 DONE (`f80b871`): telemetry capacity on the whole deck, discards logged as discards, tools merged.
- Phase 3A DONE (`8d2739f`): 3.1-3.8 all implemented.
- Phase 3B DONE for the frequent items: 3.9 Arm (engine scores it too), 3.10 Hook, 3.11 first-shop Buffoon, 3.12
  Serpent, 3.13 Ox (sim side; the engine doesn't yet avoid the Ox hand), 3.14 Blue/Purple seals, 3.15 econ double-pay,
  3.17 Dagger, 3.18 Madness, 3.21 Mr. Bones reward, 3.22 edition weights.
  DEFERRED (each fires in <=5 of 160 runs, below the frequency ceiling): 3.16, 3.19, 3.20, 3.23-3.29.
- Baselines: `fin20` = 3A+3B (+ `fin20_7` out-of-sample); `fin19` skipped for time. **fin20: 21/160 wins (13%)** vs 51
  (32%) in the old world; reach-8 57 -> 27. Deaths moved to ante 5-6, led by **Big blinds (ante-5 Big deaths 3 -> 12)** --
  the corrected sim now reproduces the live signature (live dies on Big blinds 2-3x the old sim). The Serpent kills 4 at
  ante 6. `fin20_7` (fresh seeds): 31/160, reach-8 46. Phase 4 arms compare against fin20.
- 4.1 `pool32` (BES_POOL_DRAWS=32) vs fin20: **wins 21 -> 28, reach-8 27 -> 38, sign 78/52 (p 0.028), progress +0.276
  (p 0.059)** -- but **`pool32_7` vs fin20_7 did NOT replicate: wins 31 -> 29, sign 67/75 (n.s.), reach-8 46 -> 43**.
  Pooled 320: wins 52 -> 57, nothing significant -> winner's curse; NOT shipped (switch stays default 8).
- 4.2 `xpick` (BES_EXACT_PICK=1) vs fin20: **wins 21 -> 32, reach-8 27 -> 43 (McNemar p 0.021)**, progress +0.096 (n.s.),
  sign 75/60 (n.s.). **`xpick_7` vs fin20_7: wins 31 -> 33, progress +0.121, sign 80/61 -- same direction. Pooled 320:
  wins 52 -> 65, sign 155/121 (p ~0.04). SHIPPED as default (exact maths of the same quantity; correctness + cheaper).**
  Combo arms dropped (pool32 failed OOS); `poolall` / `pool64` queued instead (fresh-seed arm only if promising).
- `poolall` (BES_POOL_DRAWS=all, exact pick OFF, worktree f6ebab3) vs fin20: **wins 21 -> 29, progress +0.287** --
  promising -- but **`poolall_7` vs fin20_7 did NOT replicate: wins 31 -> 33, reach-8 46 -> 44, progress -0.105
  (p 0.55), sign 66/70. NOT shipped** (switch stays default 8). Same pattern as pool32. The two first-pool gains are
  not independent: per-seed deltas of pool32 and poolall correlate 0.39 (they flip the same decisions and inherit the
  same cascades), so "twice on the original seeds" was one piece of evidence. Pooled 320: pool32 +0.20, poolall +0.10,
  both n.s. `pool64` stopped by Claude (between two OOS failures, answers nothing new).
  **Revised (owner 2026-09-29):** poolall measures the SAME pack value with less noise -- an accuracy change, like
  xpick -- so by the burden-of-proof rule it ships unless measured significantly negative (pooled 320: wins 52 -> 62,
  reach-8 73 -> 83, n.s. but positive). Regression arms on the CURRENT engine in the cheap live form (all jokers,
  2 deals each, +14% shop deals): `pa2` vs `stone`, `pa2_7` vs `xpick_7` (chain `%TMP%/bes/chain_pa2s.sh`, ETA ~20:50).
  Ship if neither is significantly negative.
- **poolall SHIPPED (`585d25f`, deployed):** `pa2` vs `stone` wins 24 -> 28, reach-8 42 -> 36, progress +0.051 (p 0.75),
  sign 77/59; `pa2_7` vs `xpick_7` wins 33 -> 41, reach-8 44 -> 52, progress -0.150 (p 0.38), sign 61/72. Wins up on
  all four pools; nothing significant either way -> shipped as an accuracy change. **New baselines: `pa2` / `pa2_7`**
  (= current default). `sb1` / `rr32` were queued on worktrees without it and compare vs `stone`; a winner there needs
  one confirming arm on the current default.
- **`stone` vs `xpick` (Stone fix + Loyalty, correctness):** progress +0.041 (p 0.45), sign 23/19 (118 tied), death-ante
  equal, reach-7 56 -> 62, reach-8 43 -> 42, **wins 32 -> 24 (11 lost / 3 gained, McNemar p 0.057)**. The lost wins had
  no Stone card when they diverged: the fix shifts VALUATIONS that price hypothetical Stone cards (Tower, Marble,
  projected decks; e.g. Shoot the Moon 15.98 -> 15.81 in an ante-1 shop) and the cascade reshuffles 86 seeds. Not
  significant -> KEPT (correctness, and it is the live-scoring fix); `stone` is the new baseline. Watch wins on the
  next arms; if they stay low, recheck the Tower/Marble valuations.
- **SWAP BAR (owner 2026-09-29: "it rarely takes a comparable or clearly better joker").** `tools/swap_bar_probe.lua`
  over 1610 live full-board shops (fixtures from line 9035): 974 offers weighed, **409 beat the joker they'd replace,
  284 of those (69%) refused by the bar, 177 even at >= 1.5x** (WJ9XMWUQ: Blue Joker 2.11 vs Seeing Double 5.51, bar
  5.53). Causes: the flat UPGRADE_MARGIN 1.2 exceeds most offers' whole gain (0.4-3), and scaler keep_bias (~2.5)
  shields weak scalers (Green Joker 0.01 at a7, Runner 0.27). Arm `sb1` (BES_UPGRADE_MARGIN=0.6, BES_SWAP_SLOPE=0.25)
  vs `stone` runs after pa2_7 (`%TMP%/bes/chain_next.sh`, worktree `%TMP%/bes_wt_sb` at 978ce1b), then rr32. July's
  lesson: margin cuts alone churned -- watch SOLD counts. Next if needed: keep_bias for low-C scalers.
- **`sb1` vs `stone`: NOT promising** -- wins 24 -> 27, progress -0.056 (p 0.60), sign 44/52, reach-8 42 -> 36, jokers
  sold 433 -> 520. A lower bar alone swaps more without better outcomes: at 6 deals a close swap is a coin flip (both
  sides ARE measured alike -- forward_measure on each -- so the probe's comparison is fair). Next: `ss24` = the lower
  bar + BES_SWAP_SAMPLES=24 (precise measurement of just the swap, +9% deals), then `sb2` -- both vs `pa2` on the
  shipped default (worktree `%TMP%/bes_wt_ss` at cba4e3f, chain `%TMP%/bes/chain_night.sh`, after rr32).
- **`sb2` vs `pa2`: NEUTRAL, barely fires** -- 150/160 tied, wins 28 -> 28, reach-8 36 -> 35, sold 459 -> 473.
  **Swap-bar line CLOSED:** sb1, ss24 and sb2 all failed to convert; the bar stays as shipped.
- **`ss24` vs `pa2`: NOT promising** -- wins 28 -> 24, reach-8 36 -> 40, progress +0.039 (p 0.73), sign 45/48, sold
  459 -> 528. With sb1: a lower swap bar trades more but not better, even with 24-deal measurement -- the refused
  "better" swaps are worth little in the sim. The flat margin stays. `sb2` (scaler keep runway) running, ETA ~07:20.
- **rr32 SHIPPED (`94b37f9`, deployed, main synced):** `rr32_7` vs `xpick_7` wins 33 -> 34, reach-8 44 -> 51, reach-7
  72 -> 79, progress +0.004. Pooled 320 wins 57 -> 66, reach-8 86 -> 99. Confirm arm `rrc` (new default vs `pa2`) queued
  last (`%TMP%/bes/chain_rrc.sh`); it becomes the next baseline.
- **`rr32` vs `stone`: PROMISING** -- wins 24 -> 32, reach-8 42 -> 48, reach-7 62 -> 66, progress +0.122 (p 0.33),
  sign 62/61, sold 433 -> 469. `rr32_7` (vs xpick_7) running, ETA ~03:50.
- **"Died rich" CLOSED (no defect):** `tools/died_rich.py sim_out/pa2.jsonl` -- 22 of 132 deaths held $25+ and scored
  >= 90%; in their death-ante shops the engine bought packs 27/52 times and never left an affordable +value offer
  untaken. The money is the interest reserve (~$25), which the owner rates as well handled.
- **Boss-aware pacing (`pboss`, switch BES_PACE_BOSS=1, `06c2c6d`):** `urgent` used a generic 2x / 4-hand boss.
  Boss death rates near ante 4 (pa2+pa2_7): Water 18%, Wall 17%, Mouth 15%, Needle 14% vs Wheel/Arm ~6%. The switch
  also checks the known next boss at its real requirement / hands / scoring effect; newly urgent in 7.7% of live
  shops (Club 17, Wall 16, Needle 12, Flint 10, Manacle 9 ...). Queued last (`%TMP%/bes/chain_pb.sh`, vs `pa2`).
  Not covered: Water (capacity is already no-discard), Mouth/Eye/Serpent (play restrictions).
- **Overnight order after sb1/rr32** (owner asked for the next clear thing if rr32 fails): (1) `sb2`
  (BES_SCALER_KEEP_RUNWAY=15, `0a92d6a`) regardless of sb1 -- the probe shows two separate causes; (2) a swap-bar
  winner gets one confirming arm on the current default vs `pa2`, ships, then rerun the reroll test (rerolls only pay
  once the engine takes what they surface); (3) "died rich" probe: 60% of sim deaths hold $25+, ~1/3 miss by <10% --
  replay the last shop before those deaths and check for an affordable buy that closes the gap.
- **4.1 was never tested:** the reroll path passes `measure_count = 6`, so pool32/poolall only changed Buffoon-pack and
  created-joker values. `BES_REROLL_DRAWS` (`492dff7`, default 6) -> arm `rr32` vs `stone` queued after pa2_7
  (`%TMP%/bes/chain_rr.sh`, worktree `%TMP%/bes_wt_rr`), `rr32_7` vs `xpick_7` only if promising. ETA ~21:45 / ~22:40.
- **4.3 DROPPED (no batch):** the chooser already ranks a guaranteed clear above an average-only one (tier 2 > 1). Live
  average-only clears that failed were almost all on the blind's FIRST hand with 3-4 hands and discards left (e.g.
  TCUKQQQH needed 20000, got 17937, 2063 left for 3 hands); the only last-hand one cleared. A miss costs ~$1, not runs.
- Card order: the self-player DOES reorder (45 "reorder cards" live). Short plays left: 371LEAD2 cleared anyway (money
  order once the clear is guaranteed, by design); JDBPAMG6 a4 Big missed by 60 (pred 10416, got 7440; Photograph +
  Greedy order, old build) -- one case, watch for more before acting.
- 1.4 live check (smoke test 2026-09-29, 6 runs, 1 win): **Stone cards scored as ranked** (Hack retriggered them) --
  fixed `c95f142`, deployed; regression arm `stone` vs `xpick` queued after the pool chain. Remaining misses = card
  order (self-player plays in hand order).

## Phase 0 — finish what is running (tonight)
| # | Item | Action | Batch |
|---|---|---|---|
| 0.1 | `rs07` (risk read +0.7 more pessimistic) | **DONE: lost (wins 50 → 38, p 0.026).** With refit/pq25 also losing, the shipped risk fit is a local optimum; no OOS arm | — |

## Phase 1 — engine scoring correctness (live + sim; ship on mechanism)
These are provably wrong scores; per the burden-of-proof rule they ship unless a paired batch is significantly negative.
Each gets a unit test built from a recorded live play where the game's actual score is known.
| # | Item (audit) | Change | Test |
|---|---|---|---|
| 1.1 | **Baseball Card** (live-gap) | Apply ×1.5 at each Uncommon joker's position in the scoring order, not ×1.5ⁿ on the whole hand | N3WZCB7D plays scored 0.57–0.72× of prediction; replay must match the game |
| 1.2 | **Flower Pot / Seeing Double + Wild cards** (live-gap) | A Wild card fills ONE missing suit (assign Wilds to cover missing suits), not all four | Four Clubs + a Wild: Flower Pot gives nothing |
| 1.3 | **Ramen reader** (live-gap) | `joker_effects.scaled` takes the max of `ability.x_mult` and `ability.extra`; Ramen's fixed 2 wins over the decaying value. Read the current value for Ramen (check other jokers with the same two-field layout via the F7 dump) | Live Ramen at 1.8 reads 1.8 |
| 1.4 | Check for more mis-scored jokers | Rerun the live-gap tool (`tools/live_gap.lua`, commit it from the worktree) after 1.1–1.3: list jokers on boards still scoring <0.8× on deterministic plays | Tool output |
| 1.5 | Regression batch | One paired arm vs the current baseline; ship unless significantly negative; deploy (owner restarts the game) | 1 arm |

## Phase 2 — live telemetry and tooling (no batch)
| # | Item | Change |
|---|---|---|
| 2.1 | Live capacity at each new ante measured on the undrawn pile (reads too low; made live boards look weaker) (live-gap) | Measure on the full deck, as the sim does |
| 2.2 | `track_play` logs every discard as a play (live-gap) | Log discards as discards |
| 2.3 | Tools left in the audit worktrees | Merge `tools/seed_flip_probe.lua`, `tools/seed_flip_report.lua` (branch `worktree-seed-flip-probe`) and `tools/live_gap.lua` into the main branch with `tools/README.md` entries; remove the two locked worktrees afterwards |

## Phase 3 — sim rules corrections (fidelity; one bundle, then a NEW BASELINE)
Fidelity fixes define the ruler, so there is no keep/revert verdict: apply them, rebuild the baseline (in-sample +
out-of-sample), and expect the sim win rate to fall. Split into two bundles so the big movers are visible on their own.

**Bundle 3A — frequent, large (then baseline `fin19` + `fin19_7`, 2 arms):**
| # | Gap (sim audit rank) | Fires | Change |
|---|---|---|---|
| 3.1 | Cavendish offered without Gros Michel going extinct (#1) | owned in 53/160 runs (64% win vs 15%) | Pool conditions: Cavendish only after Gros Michel went extinct; Gros Michel leaves the pool then |
| 3.2 | Enhancement-gated jokers offered with no matching cards (rare list) | dead offers | Same pool-condition mechanism: Steel Joker / Golden Ticket / Glass Joker / Lucky Cat (and any other `in_pool` rule) need a matching card in the deck |
| 3.3 | The Pillar does nothing (#2) | 43 boss fights | Cards played this ante are debuffed in the boss blind (engine side: `boss_effect` entry so live advice sees it too) |
| 3.4 | Orbital Tag levels the engine's best hand (#3) | 52 tags | Level a random hand (engine opinion out of the rules layer) |
| 3.5 | Pack Tarots/Planets/Spectrals can be kept (#4) | ~7 held picks per run | Must be used on pick (match the game); keep the engine's in-pack targeting |
| 3.6 | Glass cards never shatter (#5) | Justice in 36% of runs | 1-in-4 destroy chance each time a Glass card scores |
| 3.7 | Soul / Black Hole rates (#6) | ~2× too many Legendaries | Real weights: rare in Spectral packs, 0.3% in Arcana/Celestial packs |
| 3.8 | Chance effects scored at their average (live-gap step 1) | every Lucky/Misprint/Bloodstone play; 52% of average-only clears fail live | World rolls each chance effect (the referee uses a sampled score; the engine keeps its own model) |

**Bundle 3B — smaller or rarer (then re-baseline `fin20` + `fin20_7`, 2 arms):**
| # | Gap | Change |
|---|---|---|
| 3.9 | The Arm lowers the level after scoring (#7) | Lower before scoring (also make the engine's scoring apply it) |
| 3.10 | The Hook discards after scoring (#8) | Discard before scoring |
| 3.11 | No guaranteed Buffoon Pack in the first shop (#9) | Add it |
| 3.12 | The Serpent (#10) | Always draw exactly 3 after a play or discard |
| 3.13 | The Ox (#11) | Playing the most-played hand sets money to $0 (engine side: read the flag, avoid that hand when money matters) |
| 3.14 | Blue / Purple seals make nothing (#13) | Blue: a Planet for the final hand's type when held at round end; Purple: a Tarot on discard (slot-limited) |
| 3.15 | Econ double-pay: Business Card, Midas Mask, Certificate | Add to `ECON_INCOME_EXCLUDE` |
| 3.16 | Trading Card flat $3; Matador flat $4 | Trading Card: only on a first discard of exactly 1 card (and destroy it); Matador: $8 only when a boss ability triggers |
| 3.17 | Ceremonial Dagger never destroys | Use `engine/dagger.lua`'s feed-or-park decision at blind start (the player's arrangement, like live) and destroy the fed joker |
| 3.18 | Madness never grows | +×0.5 when a Small/Big blind is selected, destroying a random other joker |
| 3.19 | Invisible Joker skips its 2-round wait | Enforce the wait |
| 3.20 | Double Tag does nothing (and Diet Cola feeds it) | Duplicate the next tag taken |
| 3.21 | Mr. Bones save still pays the blind reward | $0 reward on a save |
| 3.22 | Wheel of Fortune / Aura editions uniform | 50/35/15 Foil/Holo/Polychrome |
| 3.23 | Ectoplasm penalty doesn't grow; Immolate hits the whole deck | Growing hand-size penalty; Immolate destroys from the hand |
| 3.24 | The Tooth stops money at $0 | Allow the real behaviour (verify: negative money) |
| 3.25 | Illegal Psychic/Eye/Mouth plays replaced by a legal one | Score 0 (the engine already filters; this only guards the world) |
| 3.26 | Tags: Voucher Tag free random voucher; Boss / Speed / Negative tag | Voucher Tag adds a voucher to the shop; Boss Tag rerolls the boss; Speed counts the current skip; Negative Tag gives a free Negative joker |
| 3.27 | Vouchers: Clearance Sale not applied to vouchers; Merchants ×2 (real ×2.4); Telescope uses most-leveled not most-played; 8 vouchers excluded | Fix the three rules; model the excluded vouchers where they matter (Observatory first) |
| 3.28 | A planet bought with a full tray is paid for but lost (live-gap) | The world refuses the buy (the game does); also check the engine never proposes it |
| 3.29 | Stale `-- VERIFY` comments (`content.lua:99/507/648/862`, `world.lua:1195`) and To Do List missing High Card (`world.lua:734`) | Update comments with the rules above; confirm High Card and add it |

## Phase 4 — engine changes, judged on the corrected sim (A/B each; tuning ones also out-of-sample)
| # | Item (seed-flip / live-gap) | Change | Evidence needed |
|---|---|---|---|
| 4.1 | Reroll value swings ±57% by seed; 35% of all flips (seed-flip) | `Packs.expected_shop_joker`: draw 32 jokers instead of 8 (+6% shop time), or value the whole pool once per shop | Paired A/B + OOS (precision changes have shifted the operating point before: pace20) |
| 4.2 | `Packs.expected_pick` uses a 40-trial best-of-N simulation (seed-flip) | Exact calculation: no noise, cheaper | Paired A/B |
| 4.3 | Chance-dependent plays fail 52% live (live-gap step 1) | Play chooser prefers a guaranteed clear (minimum score ≥ need) over a higher-average play when one exists | Needs 3.8 first; paired A/B |
| 4.4 | Pacing: `urgent` flag flips on noise (12 of 13 pace flips) | Low priority: the risk fit is a local optimum (refit, pq25 and rs07 all lost). Only worth trying `urgent` hysteresis, which keeps the same decisions on average and removes the coin flips | A/B + OOS |
| 4.5 | Joker value noise (16% of flips; ×4 samples = 2.7× slower shops) | Deferred: too expensive now; revisit with a cheaper estimator | — |

## Checked and no change needed
| Item | Why |
|---|---|
| Face-down bosses (House/Wheel/Mark/Fish) and Amber Acorn | Owner directive (engine sees hidden cards; the self-player re-sorts face-down jokers) |
| In-blind deck: live passes the undrawn pile, sim the full deck | 0 of 80 replayed decisions change |
| Tarot/Spectral packs valued with the dealt hand live, without it in the sim | 0 of 70 picks change |
| Self-player acting on slow decisions, 20 s pack limit, clicks/retries | 58/58 up to date; 3/322; 1 skip in 17 runs |
| Self-player plays exactly the chosen cards | 150/150 |
| Change detection (`core/signature.lua`) | Fixed in R18, clean |
| Consumable-value flips (31% of flips) | Genuine near-ties (gaps ≤ 0.07), low stakes; more samples don't fix them |
| Shop pack-value flips beyond 4.2 | Packs usually near-equal; not worth samples |
| Multiplayer-mod jokers (`j_mp_*`) score zero | 28 of 2283 offers; revisit only if the owner plays with that mod's pool |
| Build plan lost when the game restarts mid-run | 3 of 38 runs; minor (optional later: persist it in the save) |
