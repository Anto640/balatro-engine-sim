# AUDIT 2026-10-10 — what is the next BIG lever?

(DRAFT — being filled in as the probe arms finish; the "Status" block at the end says what is still running.)

Baseline: `sim_out/fsh.jsonl` (engine == HEAD 46b0923 == a1ecd4c), **48/160 wins, reach-8 65/160, progress 6.210**.
All experimental code lives in worktrees (listed at the end); nothing touches the engine on `winrate-v4-bundle` / `main`.

## TL;DR (provisional)
1. **The sim's losses are mostly NEAR MISSES.** 37 of 112 deaths are within 15% of the target, 77 within 30%;
   87 are at a boss. Anything that adds 10-30% to mid/late scoring converts a large share of them -- which is why
   resource lesions look so big and why a single scoring channel can move wins a lot.
2. **Concentrated leveling is a large ceiling** (`lvredir`: every planet / level goes to the run's main hand):
   n=40 screen wins 9 -> 16, reach-8 15 -> 20, McNemar 9/2 (p 0.065). The engine spreads its ~10 planets over
   4-5 hand types (only 25-28% of gained levels land on the hand it plays most). A realistic version (value planets
   against a concentrated play frequency) is running as an arm.
3. **A provable, run-killing in-blind bug**: on the LAST hand of a blind the engine arbitrates "play now vs dig" by
   E[frac] (capped at 1) with a 0.06 margin, so a sure near-miss (frac ~0.92-0.95, P(clear) = 0) beats a dig with
   P(clear) 0.83-0.995. Replayed: sim 102003 a4 Needle (dig P(clear) 0.995 vs play 0), 5003 a5 Needle (0.83 vs 0),
   117003 a6 Needle (0.225 vs 0). 15/112 baseline deaths failed their last hand with discards unused (5 of them at
   The Needle, which has ONE hand, so the rule fires on its very first decision). **Live too**: of 30 auto-saved
   live deaths, 5 ended on a last hand with discards left; replayed, the 2026-10-09 02:31 death (ante-6 Big blind,
   High Card 4550 vs 5010 needed, 5 discards unused) had P(clear) 0.000 playing vs **1.000 digging**, and the fixed
   rule digs. Fix (`BES_LAST_CLEAR=1`, worktree `bes_wt_audit_lc`) + arm running.
4. **The scaler valuation is miscalibrated by up to ~20x, in both directions**, and it fires in about half of all
   runs: additive scalers the engine buys often (Runner predicted 2.26 of a boss hand vs ~0.11 realized one/two antes
   later; Spare Trousers 3.1 vs 0.25-0.57; Castle 2.6 vs 0.33-0.48) and the xmult scalers it almost never buys
   (Constellation 0.06 vs 0.17-0.32; xmult_scaling class 0.13 predicted, 2.3x / 3.2x that realized at +1 / +2 antes).
   Root causes found: guessed event rates (planets 0.03-0.15 per scoring hand assumed vs 0.37 realized; tarots
   0.03 vs 0.41; sells 0.05 vs 0.15) and committed-build trigger rates (Runner 0.45 Straights/hand).

## Offline findings (free: existing arms, live fixtures)

### O1. Anatomy of a loss (fsh)
- Deaths: a1-3 10, a4 10, **a5 29, a6 29**, a7 17, a8 17. 87/112 at the boss; median clear ratio at death 0.78.
- The board gap opens EARLY: capacity entering ante 3 is 14.0k (eventual winners) vs 6.8k (ante-5 deaths), with
  the same joker count, levels and money. Capacity AUC for the eventual win: 0.64 (a3) / 0.68 (a4) / 0.72 (a5).
- Everybody's board grows slower than the requirement: winners' capacity/boss ratio 3.5 (a3) -> 2.9 -> 1.8 -> 1.5 (a6).
- Money at death: median $25, 72% of deaths hold >= $20 (the interest reserve; "died rich" was closed as correct).
- Ante 8: 15 of 17 ante-8 deaths are at the finisher; Crimson Heart / Verdant Leaf / Violet Vessel each kill ~40%
  of the runs that meet them (5/13 each); Cerulean Bell / Amber Acorn 0.
- Outcome per seed is path-dependent, not luck-fixed: over 16 near-identical policy arms 59 seeds never won and ~45
  won >= 10 times, yet rich4 wins 23 of the 59 "never" seeds and loses 7 of the 29 "always" seeds.

### O2. Hand-type coherence and leveling are spread thin
- At ante 4+, the run's most-played hand is only **47%** of plays; score share of plays at ante 5+: Pair 23%,
  Straight 16%, Two Pair 13.5%, High Card 13.5%, Flush 10%, Full House 8%, Three of a Kind 7.6%.
- Only **25-28% of gained levels** land on the most-played hand; at the last ante it sits at level 3.9 while the
  highest level is 4.95. Planets used: 10.5/run, 3.0 on the main hand. Main-hand planet SUPPLY is ~1.3 shop offers
  + 2.6 Celestial pack items per run and the engine already takes ~3 of them -- so concentration needs a policy
  (skip off-type planets, more Celestial packs, Telescope), not just better picks.
- Coherence does NOT separate the engine's own winners from losers (top-hand share ~0.5 in both) -- the engine
  never concentrates, so its data cannot show the effect; the lesion does.
- Build planner steering: replaying 40 mid-game live shop states with BuildPlan.fit / planet_credit / level push /
  keep_bias zeroed changes the top pick in **3/40 (8%)**, all sell-side. The planner is close to inert on buys.

### O3. Valuation vs outcome
- Joker identity on the ante-4 board vs eventual win (591 runs, 4 arms): Spearman(engine's median offer value,
  win lift) = **0.14**. Outliers: Joker Stencil valued 30.5 (median) but P(win | owned) 0.05 (n=19); Constellation
  -0.31 / 0.60 (n=15); Obelisk -4.2 / 0.50; Blackboard 4.0 / 0.63; Photograph 3.5 / 0.48.
- By category (fsh + u4_7, antes 1-4): **xmult_scaling bought on 9% of affordable views, P(win | owned at a5) 0.52**
  vs 0.34 overall; scaling_mult 10% / 0.22; economy 7% / 0.19; retrigger 52% / 0.37; xmult 34% / 0.40.
  Baseline acquisitions: Runner 20, Supernova 23, Square 13, Trousers 14, Hiker 13 vs Constellation 3, Hologram 5,
  Obelisk 1, Lucky Cat 1, Vampire / Glass / Campfire 0.
- Holding capacity fixed, multiplier pieces predict wins at antes 4-5, most on STRONG boards (ante 5, top capacity
  tercile: 0 pieces 31% win, 2+ pieces 66%), yet the engine buys affordable multipliers LESS when its pace risk says
  it is secure (24% of views) than when at risk (32%). (Policy probe `xsecure` queued.)
- PREDICTED vs REALIZED (`tools/joker_realized.lua`, 620 live shop buys replayed with the current engine; realized =
  the joker's leave-one-out single-deal marginal at the first shop of each later ante while held, same unit):

  | class | n | predicted (frac of boss hand) | realized/predicted at +0 / +1 / +2 antes |
  |---|---|---|---|
  | flat_mult | 214 | 1.42 | 0.88 / 0.38 / 0.28 |
  | flat_chips | 107 | 1.53 | 0.95 / 0.41 / 0.26 |
  | xmult | 112 | 1.44 | 0.49 / 0.33 / 0.23 |
  | retrigger | 38 | 1.88 | 0.14 / 0.09 / 0.13 (realized is card-order-blind: understates Hanging Chad) |
  | scaling_chips | 26 | 2.09 | 0.00 / 0.04 / 0.05 |
  | scaling_mult | 20 | 0.57 | 0.00 / 0.11 / 0.20 |
  | xmult_scaling | 15 | 0.13 | 0.00 / **2.31 / 3.24** |

  Flat and xmult jokers lose ~60% of their share per ante as the requirement doubles (expected); the scalers are
  where the model is wrong. Per joker (median realized at +1 / +2): Runner pred 2.26 -> 0.11 / 0.11; Trousers 3.12
  -> 0.25 / 0.57; Castle 2.58 -> 0.33 / 0.37; Constellation 0.06 -> 0.17 / 0.32; Square 0.14 -> 0.27 / 0.44;
  Throwback 0.03 -> 0.28 / 0.59; Red Card 0.06 -> 0.48; Hiker 1.27 -> 0 (Hiker's buffs live on the cards, so the
  leave-one-out cannot see them -- measurement caveat).

### O4. Guessed constants that are far off the measured value
- `Eval.event_rate` feeds the consumable-fed scalers with **0.03-0.15 planets / tarots per scoring hand**; the sim
  realizes **0.37 planets and 0.41 tarots per scoring hand** (fsh, all antes). Constellation is priced at ~1/2.5 and
  Fortune Teller at ~1/13 of the rate they actually feed at. Joker sells (Campfire) 0.05 assumed vs 0.15 realized.
  Prototype (worktree `bes_wt_audit_er`, BES_EVENT_RATES=1): Constellation 0.09 -> 0.22, Fortune Teller 0.017 ->
  0.23, Campfire 0.019 -> 0.056 of a boss hand on replayed ante-4 live shops.
- Negative tag: a FLAT $16 in `engine/tags.lua` (owner rule: no flat scores); offered 65 times in 160 runs, taken
  once. It is the most frequent reachable joker-slot source in the game (0.4 offers/run), and slots are the biggest
  resource lever ever measured.

### O5. Where the CPU goes (why every verdict costs 3-4.5 h)
- One sim run: **shop advisor 82%** of CPU (4.4 s/call, 57 calls), pack picks 10%, in-blind play 7.5%.
- Exclusive time: **JokerValue.score_delta 67%** (13,375 calls/run), remove_delta 11%, survival rollouts 7%.
- In a mid-game live shop, the reroll / Buffoon joker-pool EV (32 draws x 2 deals each) is ~40% of the decision.
- Every measurement draws fresh random deals and re-scores the unchanged base board on them: only 7% of best_play
  calls in a decision are exact repeats, so output-preserving memoisation cannot help; sharing the deals can.
- Prototype (worktree `bes_wt_audit_proto`, BES_CRN_DEALS=1): sample k of every single-deal measurement is the k-th
  CONTENT-seeded deal of the deck, and the base board's best play per deal is cached (content-keyed). On 20 replayed
  live shops: **1.41x less CPU per decision (cold cache), top pick unchanged in 18/20, seed flips 3 -> 2.** In the
  sim the cache also survives across a visit's re-evaluations (after a reroll the board is unchanged), so the run-level
  gain should be larger. Unit tests 1624/1625 (the one failure counts rng draws to detect cache misses).
- Valuation noise: the 2026-09-28 seed-flip probe found 37% of decisions change their top pick with only the MC seed
  changed; per-joker 2-deal noise inflates the reroll EV by ~11-18% (measured here on 16 live shops).

### O6. Live vs sim
- 32 recent finished live self-play runs: reach-5 78%, reach-6 72%, reach-7 50%, reach-8 34%, wins 5 (16%). The
  sim (fsh): reach-7 51%, reach-8 41%, wins 30%. Reach rates match through ante 7; the ante-8 conversion differs
  (live 5/11 vs sim 48/65, Fisher p ~0.05, n tiny). Live ante-8 death records carry no boss key (telemetry gap),
  so the finisher cannot be attributed.

## Probe / arm results (vs `fsh`, 48 wins; added by the main session after the audit agent hit the API session limit)

| arm | what | n | wins | reach-7 / reach-8 | progress delta (p) | sign | verdict |
|---|---|---|---|---|---|---|---|
| `audit_lastclear` | last hand: dig by P(clear) (BES_LAST_CLEAR=1) | 160 | 48 -> **50** | +3 / +2 | +0.050 (0.07) | 6/5; death ante 5 later, 0 earlier | **SHIPPED** `ec08796` (on by default) |
| `audit_conc` | realistic concentrated leveling | 160 | 48 -> 52 | +4 / -2 | -0.031 (0.82) | 54/51 | mixed; magnitude change -> not shipped |
| `audit_lvredir40` | lesion: every level to the main hand | 40 | 9 -> 16 | +5 / +5 | +0.296 (0.33) | 19/12 | ceiling, n.s. at n=40 |
| `audit_noboss40` | lesion: every boss a plain 2x blind | 40 | 9 -> **25** | +9 / +15 | **+0.954 (0.0004)** | 27/6 | **large ceiling** |
| `audit_scalerfix` | measured event rates + time-consistent scaler ramp | 160 | running | | | | |

Boss deaths per encounter (640 sim runs): Crimson Heart 0.38, Verdant Leaf 0.37, Violet Vessel 0.31, **The Wall 0.22**
(12% of all boss deaths), then Plant / Ox / Serpent / Needle / Manacle 0.11-0.13, most others 0.02-0.10. The boss-reroll
channel (Director's Cut / Retcon vouchers, Boss tag) is unbuilt end to end: excluded from the sim's voucher pool, the Boss
tag unmodelled, no engine or self-player action. Follow-up ceiling probe `bossrr` (one FREE reroll of Wall / Heart / Leaf /
Vessel, vs `audit_lastclear` = HEAD) queued after `audit_scalerfix`.

## Status
- The audit agent stopped at ~06:00 (API session limit) before finishing; this report is its 02:00 draft plus the table
  above. Worktrees kept: `%TEMP%/bes_wt_audit_{b,base,conc,er,lc,proto}`.
