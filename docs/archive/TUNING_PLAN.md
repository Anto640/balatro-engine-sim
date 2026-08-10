# TUNING_PLAN.md — data-driven engine improvement (round 2)

Companion to `SELFPLAY_PLAN.md` (Phase 0 telemetry) and the joker-undervaluation memory.
Written 2026-06-27 from a post-fix batch (`bes_runs.jsonl`, 4 completed runs + 2 partial),
F7 joker dumps, and the player's live observations.

## STATUS (2026-06-27, 666 tests pass, deployed)

- **Shipped:** T2.1 (last-hand discard / Needle), T1.1 (upgrade-swap hysteresis + current-value
  gate), T1.2 (reroll discipline), T2.3 (Wraith money-zero), T3.4 (enhancement overwrite),
  T3.1 (skip hysteresis), T4.2 (Ouija downside). T3.2 (Orbital hand-awareness) was **already
  deck-aware** in the code — earlier observations were the stale install before re-sync.
- **Deferred — need the fresh batch / data (do NOT tune blind):** T1.3 (BUY-path over-valuation
  of unfed scalers — Throwback measures 8.1 vs Gros Michel 1.08; touches scaling_projection +
  many tests), T1.4 (leveling), T2.2 (chips-scaler counter read — needs an F7 of a *fed*
  Runner/Castle/Square/Wee). These move with measurement, not before it.
- **Deferred — niche + magic-number-y (better with measurement):** T3.3 (Red Card pack-skip),
  T3.5 (deeper deck-hand valuation — joker valuation is already deck-measured), T4.1 (spectral
  targeting note), T4.3 (Hermit sell gate — the player called it "very situational").

## Where we are (the reframe)

The round-1 fixes **worked**: anti-churn dropped sells 7→3, and the economy floor stopped the
spend-to-$0 (one run reached **$42** by ante 3 vs baseline median $0). So the bottleneck has
**shifted**: it's no longer "goes broke" — it's **converting money into power badly**. Still
0/4, dying ante 2–4, because:

- **It sells its way from winning to dead.** Run `7WY61APY` reached ante 3 measured *on-pace
  (2.43×)* with **$42 in hand**, then in that shop **sold Gros Michel + Scholar (both scorers,
  with cash to spare)** for Throwback + Fortune Teller and **died on the ante-3 _Small_ blind
  at 66%**. The board self-sabotage is now the #1 killer.
- **It over-rerolls** (19 reroll-recommendations across 4 runs) and **never levels hands** (2
  level-ups all batch), so bases stay weak.
- **Boards are piles of lateral commons** (even_steven/flower_pot/egg/wee/jolly) with no
  xmult/scaling core, and the pace measure is **over-optimistic** (said on-pace, then lost to a
  Small).

The theme for round 2 is therefore **BUILD QUALITY**: keep the engine you have, stop trading it
away, convert money into a real scoring core, and fix a cluster of clean valuation/tactical
bugs the player spotted.

---

## ROUND 3 (2026-06-28) — "money is solved, spending is broken"

12-run batch + a FED F7 dump. The round-2 economy fixes **worked**: money now climbs to **$20
@ante4, $58 @ante5** (baseline was $0). But still 0/12, dying ante 3–5 (mode ante 4). The new
killer is **conversion of money → power**:

- **Hand levels = 0 across all 12 runs.** A trace shows it **rerolling 5–6×/shop at $20–39 while
  IGNORING a Mega Celestial pack** sitting in the same shop. It never levels hands.
- **Rerolls 46×/12 runs** — the round-2 reroll gate works below the cap but lets it reroll
  freely (5–6×/shop) above it.
- **Buys economy vouchers** (Seed Money, Money Tree) while already rich and the board weak.
- **Still sells scoring jokers** (and "sells to get ABOVE the interest cap" — backwards).

F7 (FED scaler) **confirms the chips-scaler bug**: Runner `extra.chips=15`, Wee `extra.chips=24`,
top-level `chips=0`. `scaled()` reads the top-level `0` first → CHIPS-scalers read as never-scaled.

### Round-3 action plan (prioritized; folds in the player's 15 observations)

**Tier A — convert money to POWER (the new #1 killer):**
- **A1. Level hands / open Celestial packs.** hand-lv=0; ignored a Mega Celestial while rerolling.
  Value Celestial packs + planets much higher when hands are unleveled and behind pace; treat
  leveling as a core build axis. (obs: deck-hand awareness.) `engine/packs`, `pack_need`,
  `consumable_value`, `shop_advisor`.
- **A2. Reroll cap above the interest cap.** 5–6 rerolls/shop at $38. Cap rerolls/shop (≈1–2),
  require a real improvement over the current best, and stop preferring rerolls to opening a
  Celestial pack / buying a scorer. `shop_advisor` REROLL.
- **A3. Buy a SCORING core; stop over-buying econ when already rich.** Bought Seed Money/Money
  Tree at $34 with a weak board. When the bankroll is healthy + behind pace, weight scoring/xmult
  over economy. (obs: undervalues Trio/Duo.) `shop_advisor` situation weighting.

**Tier B — stop money mismanagement / bad sells (still happening):**
- **B1. NEVER sell to push money above the interest cap** (overflow earns nothing). `shop_advisor` SELL.
- **B2. NEVER sell the board's only/primary scoring joker.** (obs: "sold only scoring joker.")
- **B3. Buy-then-sell-same-joker consistency** — don't sell a joker just bought; a visit should
  plan, not make contradictory locally-optimal moves. (obs.) `shop_advisor`.
- **B4. Combo-aware keep value** — sold Photograph, breaking the Photograph+Hanging Chad combo,
  to keep Seance. Credit owned-combo synergy so combo pieces aren't sold. `owned_synergy`/sell.

**Tier C — in-blind play quality (player-observed):**
- **C1. Under Psychic, only consider 5-card plays** (it sometimes plays <5). `boss_effect`/`hand_eval`.
- **C2. Don't waste discards then play a loss** — with a near-winning hand, dig to complete it
  (or hold) instead of spending discards on single cards then playing a sub-scoring hand.
  Investigate single-card plays / 1-card discards. `decision_engine`/`search`.

**Tier D — valuation correctness (confirmed):**
- **D1. Chips-scaler read (CONFIRMED, now unblocked).** `scaled()` must use the live accumulator
  in `ability.extra.*` (max across top-level + extra), so fed Runner/Wee/Square/Castle aren't
  read as 0. Verify it doesn't mis-read decaying jokers (Ice Cream/Popcorn). `joker_effects`.
- **D2. Joker Stencil valued by its current xMult** (≈ empty slots). Verify/fix. `eval`/`joker_value`.
- **D3. Conditional-xMult (Trio/Duo) undervaluation** — the greedy sampler rarely triggers them,
  so they read weak and get sold/skipped. Floor/credit them. `eval`/`joker_value`. (overlaps A3.)
- **D4. Ace "most valuable" is debatable** — keep/enhancement targeting shouldn't blindly rank
  Aces top. `deck_plan`/card-value heuristic.

**Tier E — synergy / slot management (features):**
- **E1. Vampire (and enhancement-chasers) credit SHOP tarots too** — it favours Arcana *packs*
  for Vampire but won't buy a shop Magician. `owned_synergy` consumable_bonus.
- **E2. Slot management** — make space for Riff-Raff (needs free slots); but a Buffoon pack must
  NOT force-sell when the board has no weak joker. `owned_synergy`, `pack_open_advisor`.

**Tier F — advice clarity (UI):**
- **F1. Concrete Buffoon-pick advice** — one decision, not "skip OR sell for money."
- **F2. Spectral targeting notes** — name the card for Cryptid/Aura/etc. (like tarots).

Recommended first slice (biggest data-backed wins + the confirmed bug): **A1 (level hands /
Celestial) + A2 (reroll cap) + B1+B2 (sell guards) + D1 (scaler read)**. Then re-batch.

### Round-3 first slice — SHIPPED (2026-06-28, 672 tests pass, deployed)
- **D1** `joker_effects.scaled()` now MAXes across `ability` + `ability.extra` → fed
  Runner/Wee/Square/Castle read their real `extra.chips` accumulator (F7-confirmed) instead of 0.
- **B1** sell value discounts cash that would push you ABOVE the interest cap (overflow earns
  nothing) — never sell just to climb the cap.
- **B2** never cash-sell the board's only/primary scorer (`only_scorer` guard) — only a real
  upgrade may take it.
- **A2** reroll discipline above the cap: `SA.REROLL_APPETITE_RICH=0.7` + a min-improvement gate
  (`SA.REROLL_MIN_IMPROVEMENT=0.2`) so a PAID reroll needs a meaningfully better expected joker.
- **A1 (PARTIAL)** leveling persists: `Packs.level_persist` projects a planet/Celestial pack over
  the remaining runway (bounded ≤3, taper to 1 by ante 8). Flips a Celestial pack from negative to
  positive when rich, so it's competitive — but a reroll/strong joker can still edge it. Fully
  landing "levels reliably" needs the **T1.3 spending-priority rework** (weight power/leveling over
  interest when the bankroll is healthy + behind pace), still deferred.

Regression tests: test_jokers (fed-scaler read), test_shop #31d (level persistence), #31e (sell
guards). NEXT: re-batch ~8-10 runs (+F7) to measure; then tackle T1.3 (the core spending-priority +
unfed-scaler/Trio-Duo valuation) and the remaining Tier B/C/E/F items.

---

## Tier 1 — build quality (run-deciders; from the data) — ROUND 2 (mostly shipped, see STATUS)

**T1.1 — Stop board self-sabotage (upgrade-swap churn). [highest priority]**
- Evidence: sold Gros Michel + Scholar at $42 (didn't need the cash) → died.
- Root cause: the full-board "sell weakest to buy better" path swaps on tiny / measurement-noise
  improvements, and shop *buys* get a behind-pace `w_score` boost + fresh-measurement optimism
  that owned jokers' *keep*-value never gets — so a lateral/worse joker out-scores a contributing
  owned one. (The round-1 anti-churn fix only gated the *cash* path, not this upgrade path.)
- Fix: (a) **upgrade-sell hysteresis** — require net improvement to clear a real margin covering
  the buy/sell spread + measurement noise before recommending a swap; (b) **value owned keep and
  shop buy on the same basis** (don't let the behind-pace boost apply to buys but not to the
  joker you'd sell); (c) when you can simply *afford* the new joker, never sell a contributing
  one to fund it. File: `engine/shop_advisor.lua` (SELL_JOKER upgrade path; buy/keep symmetry).

**T1.2 — Curb rerolling.**
- Evidence: 19 reroll-recs/4 runs; rolls as soon as it has money.
- Root cause: the appetite/realizable gate loosens once above ~$10, and the expected
  improvement over the current best is over-credited.
- Fix: require a genuine expected improvement over the best *current* offer, cap reroll appetite
  harder below the interest cap, and respect the economy floor. File: `shop_advisor` REROLL.

**T1.3 — Build a core; stop hoarding lateral commons.**
- Evidence: boards are flat-mult commons, no xmult/scaling backbone; pace said 2.43× then lost.
- Root cause: each cheap joker measures marginally positive in isolation; nothing models
  diminishing returns on redundant flat mult or the run's need for an xmult/scaling core; the
  `avg_score`/pace measure is over-optimistic.
- Fix: (a) diminishing returns on redundant flat-+mult commons; (b) tilt toward xmult/scaling
  when behind; (c) calibrate `avg_score`/pacing against actual blind clears (it claimed on-pace
  before a Small-blind loss). Files: `eval_function`, `joker_value`, `pacing`.

**T1.4 — Level hands (it almost never does).**
- Evidence: 2 level-ups all batch.
- Root cause: planet/Celestial value isn't deck-aware; leveling the deck's actual most-played
  hand is undervalued. Ties to T3.5 (deck-hand awareness) and the Orbital tag (T3.2).
- Fix: value planets/Celestial by the deck's most-played hand and its current level. File:
  `consumable_value` (it already has `hand_frequencies` — wire it into the value, not just gating).

---

## Tier 2 — clean bugs (high confidence, verified in code)

**T2.1 — Discard on the last hand when discards remain (the "Needle no-discard" bug).**
- Evidence: player observation + `decision_engine.lua:207` `forced_play = (hands_left <= 1)`,
  and the discard candidate is gated by `not forced_play`. With Needle (1 hand, discards intact)
  — and on *every* normal last hand with discards left — it never digs.
- Fix: allow a DISCARD when `discards_left > 0` regardless of `hands_left`; value it without the
  saved-hand credit (you still must play after). File: `engine/decision_engine.lua`.

**T2.2 — Read scaling counters from the live accumulator.**
- Evidence: F7 dump — Runner's accumulated chips live in `ability.extra.chips`, but top-level
  `ability.chips = 0` **shadows** it (`joker_effects.lua:46` returns the top-level field first).
  CHIPS-scalers (Runner/Square/Castle/Wee) likely read as *never scaled*.
- Fix: make `scaled()` prefer the live accumulator (`extra`) over a vestigial top-level
  default; **verify on a FED scaler via F7** before committing (don't break the MULT scalers
  whose value DOES live top-level, e.g. Swashbuckler `mult=11`). Also project scaling value from
  the *current accumulated* amount and recent scaling rate (player's "how much it's scaled
  lately"). Files: `joker_effects` (`scaled`), `eval_function` (`scaling_projection`).

**T2.3 — Value Wraith inversely to the money it destroys.**
- Evidence: player observation; picks Wraith → $0. The `SA.CREATES_JOKER` comment even notes
  Wraith zeroes money but it's unmodelled.
- Fix: charge Wraith the money it would wipe (scaled by current $ held), so it's cheap when
  broke and expensive when rich; penalize early. Files: `consumable_value`, `pack_open_advisor`.

---

## Tier 3 — correctness / strategy polish (medium)

- **T3.1 — Need-gate skip-blind tags** like packs: don't auto-take a tag every time just because
  its $-equivalent clears the bar; gate by how much the run needs it. File: `skip_advisor`.
- **T3.2 — Orbital tag hand-awareness:** value it by *which* hand it would level (the deck's
  most-played / most-valuable hand), not a flat number. Files: `tags`, `skip_advisor`.
- **T3.3 — Red Card → value skipping packs:** Red Card gains +mult per *skipped* Booster pack,
  so when it's owned, skipping a pack has real value. File: `pack_open_advisor` / skip path.
- **T3.4 — Don't overwrite an already-enhanced card.** Enhancement tarots (and Chariot/steel)
  target the "strongest" card even if it's already enhanced, wasting the enhancement. Prefer a
  strong *un-enhanced* card. File: `tarot` (target selection).
- **T3.5 — Deck-hand-aware valuation.** Use the deck's hand-making potential (e.g. "loads of
  queens" → pairs/trips, or a flush skew) when valuing jokers, planets, and leveling — not just
  the joker set. `consumable_value.hand_frequencies` already measures this; extend its use into
  joker/eval valuation. Files: `eval_function`, `joker_value`, `consumable_value`.

---

## Tier 4 — advice / situational (low, do last)

- **T4.1 — Spectral targeting advice:** say *which* card(s) a spectral applies to (a
  `target_note` for spectrals like the tarot one). File: spectral targeting.
- **T4.2 — Skip harmful spectral packs / picks** (e.g. Ouija vs Incantation): model spectral
  downsides (hand-size loss, money wipe) in pack-pick value. File: `pack_open_advisor`.
- **T4.3 — "Sell for Hermit value" is over-eager / situational:** gate it. File: `shop_advisor`.

---

## Sequencing & measurement

Implement in tiers, **measuring after each** against `bes_runs_baseline.jsonl` (the pre-fix 4
runs) and the round-1 batch, using `tools/analyze_runs.lua` (death-ante mode, per-ante `$` and
`pace_margin`, ENGINE ACTION SUMMARY churn/reroll counts, and a `trace` of a representative run).

Recommended first slice (highest impact × confidence, all test-safe):
1. **T2.1** (last-hand discard) — clean tactical win, broad.
2. **T1.1** (upgrade-swap hysteresis) — stops the current #1 killer (selling winning boards).
3. **T1.2** (reroll discipline) — frees the money those swaps/rolls waste.

Then re-batch (~8–10 runs) and read the trace: did it **stop selling contributing jokers**, did
**rerolls drop**, did the **death-ante mode move past 3–4**? Iterate from there into T1.3/T1.4
(the deeper build-quality + leveling work) and the Tier 2–3 bugs.

Keep the 661-test suite green throughout; add a regression test per fix (as with round 1's #31/#32).
