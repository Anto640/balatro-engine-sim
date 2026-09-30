# docs/archive/JOKER_FIDELITY_AUDIT.md — is every joker faithfully modelled in the SIM WORLD?

> **Why this exists.** The engine's decision code is identical in sim and live, but the **sim world**
> (`sim/*`) is a *model* of Balatro, not a replica. It reproduces SCORING perfectly (it calls the real
> `engine/hand_eval`) but historically collapsed many **non-scoring** jokers — economy, leveling,
> generation, survival — to a flat `econ`/tier prior, or ignored them. That makes the sim **flatter the
> engine on economy**: it hands the engine money (e.g. Faceless a flat $3/round) that in the real game
> requires EFFORT the engine may never spend. So the sim's winrate is optimistic exactly on the
> dimension where the engine is weakest (conversion/economy). This audit inventories every joker and
> drives the work to close the gap. (Owner-directed, 2026-08-27; supersedes the old "don't make the
> world smarter" guidance *for fidelity* — the goal here is to make the world MATCH reality, not to
> paper over engine bugs. Every added mechanic is `-- VERIFY`-tagged and calibrated.)

## The three realization layers

A joker's effect can be realized in the sim in one of three places. If it's in none, the sim ignores it.

| Layer | File | Realizes | Shared with live? |
|---|---|---|---|
| **Scoring** | `engine/joker_effects.lua` → `hand_eval` | chips/mult/xmult/retrigger during a played hand | **YES** (real engine) |
| **Per-round scaling** | `sim/joker_tick.lua` | Ice Cream decay, Ride-the-Bus growth, Rocket, … | no (sim referee) |
| **World effects** | `sim/world.lua`, `sim/content.lua` | round-end economy, generators, blind-select, boss, deck-mod | no (sim referee) |

## Coverage summary (150 jokers)

- **102 SCORING** jokers → faithful (real `hand_eval`; sim = live). ✅
- **48 VALUE-ONLY** (non-scoring) jokers:
  - **20 realized** in the sim world/tick/content or via deck-aware econ. ✅
  - **28 NOT realized** — the gap list below. ❌
- **0** jokers uncatalogued (no silent-zeros; the coverage-guard test holds).

## The gap list — 28 jokers, prioritised by how much the flat/absent model distorts the sim

Priority = (impact on survival/economy/leveling) × (how often it fires). "Target" = the sim layer to add it to.

### P0 — HIGH: materially distorts survival / economy / leveling, fires often

| Joker | Real mechanic | Status |
|---|---|---|
| **Faceless** | +$5 when 3+ face cards discarded at once | ✅ **DONE** — `discard_econ` hook; excluded from flat sum |
| **Mr. Bones** | prevents death if score ≥ 25% of target, then self-destructs | ✅ **DONE** — `mr_bones_save` in `play_blind` |
| **Space Joker** | 1/4 chance to level up the played hand | ✅ **DONE** — `space_joker_level` on every play |
| **Chaos the Clown** | 1 free reroll each shop | ✅ **DONE** — `shop.free_rerolls`; free roll doesn't escalate |
| **Astronomer** | Celestial packs + Planet tarots cost $0 | ✅ already realized — `OwnedSynergy.pack_free/consumable_free` zero `a.cost`, which the sim spends. NOT a gap. |
| **Golden Joker** | +$4 at end of round, FLAT | ✅ already faithful — the flat `econ=4` prior IS the real effect. NOT a gap. |

> **Audit-method correction:** the original grep-of-`sim/`-files method under-counted. A joker is also
> realized if the ENGINE zeroes/adjusts an action field (`cost`, `credit`, `free_rerolls`) via
> `OwnedSynergy` and the sim executes that field. That covers Astronomer (free Celestials) and Credit
> Card. Only OwnedSynergy **valuation bonuses** (`pack_bonus`, `satellite $/planet`, `midas`, `perkeo`)
> are NOT realized — they nudge the engine's *value* but the real effect never lands. Those stay gaps.

### P1 — MEDIUM: conditional economy the flat prior mis-credits, or a real scaler/generator

| Joker | Real mechanic | Status |
|---|---|---|
| **Golden Ticket** | Gold cards give +$4 when played & scored | ✅ **DONE** — post_play_econ, excluded from flat sum |
| **Satellite** | +$1 at round end per UNIQUE planet used this run | ✅ **DONE** — conditional_econ + planets-used set |
| **Delayed Gratification** | +$2 per discard UNUSED (none used), at round end | ✅ **DONE** — conditional_econ + discards_start |
| **Midas Mask** | played face cards become Gold (→ $3 held / Ticket) | ✅ **DONE** — post_play_econ deck-mod |
| **Mail-In Rebate** | +$5 per discarded card of a chosen rank | ✅ **DONE** — discard_econ + per-round rank |
| **To Do List** | +$4 if you play a specific poker hand this round | ✅ **DONE** — conditional_econ + per-round hand |
| **Hiker** | every scored card gains +5 perma chips | ✅ **DONE** — Cards.chips perma_chips (golden-safe) |
| **Gift Card** | +$1 sell value to every joker & consumable each round | ✅ **DONE** — on_round_end sell-value tick |
| **Matador** | +$8 if played hand triggers the boss's ability | ⛔ **DEFERRED** — see below |

### P2 — LOW: rare / situational / sell-to-trigger effects

| Joker | Real mechanic | Status |
|---|---|---|
| **Marble Joker** | adds 1 Stone card to deck on blind select | ✅ DONE — blind_start_generators |
| **DNA** | first played card of round: add a copy to deck | ✅ DONE — play_effects (first single play) |
| **Certificate** | round start: add a random card with a random seal | ✅ DONE — blind_start_generators |
| **Sixth Sense** | first discard of a single 8 → destroy it, create a Spectral | ✅ DONE — discard_effects |
| **Riff-Raff** | blind select: create 2 Common jokers (slots permitting) | ✅ DONE — Content.gen_common_joker |
| **Perkeo** | shop exit: create a Negative copy of 1 held consumable | ✅ DONE — shop_phase exit |
| **Luchador** | sell to disable the current boss blind | ✅ DONE — sell_effects + play_blind |
| **Invisible Joker** | sell to duplicate a random joker | ✅ DONE — sell_effects (3-round gate approximated) |
| **Burnt Joker** | upgrade the first discarded poker hand's level | ✅ DONE — discard_effects |
| **Diet Cola** | sell to create a free Double Tag | ✅ DONE — sell_effects |
| **Showman** | allows duplicate jokers/consumables in the shop | ✅ DONE — owned_joker_keys bypass |
| **Oops! All 6s** | doubles all listed probabilities | ✅ **DONE** — mods.oops (hand_eval) + World.oops_p |

### ⛔ DEFERRED (1) — genuinely not worth a fragile/risky implementation now

- **Matador** — `+$8 if the played hand triggers the boss's ability`. The sim models boss *effects*
  (score/resource penalties, play restrictions) but has no granular "the ability TRIGGERED on this hand"
  event to hang the payout on, and it varies per boss. High infrastructure cost for a rare joker; the
  flat prior is excluded-worthy but the real condition is unmodellable without a boss-trigger event bus.

## Implementation plan

1. **Build the hooks the sim lacks** (DONE): per-DISCARD hook (Faceless/Mail/Sixth Sense/Burnt), a
   planets-used set (Satellite), blind-select + round-start deck/gen hooks (Marble/Certificate/Riff-Raff),
   first-play/first-discard-of-round flags (DNA/Burnt/Sixth Sense), a sell-effects hook (Luchador/Diet
   Cola/Invisible), and a perma-chip field on cards (Hiker).
2. **Implemented P0 → P1 → P2**, batched by hook, each with `-- VERIFY`-tagged magnitudes, a headless
   test, and (for economy jokers) exclusion from the flat `joker_econ_income` sum.
3. **Re-measure (NEXT):** re-run the churn/money-dig A/B against the *old* world to confirm the sim is now
   harsher on economy (the anti-churn / money-dig fixes should finally register), then **recalibrate the
   world against the real `bes_runs` death-ante distribution** so fidelity is preserved, not drifted.

## Status log

- 2026-08-27: audit built. 102 scoring faithful, 20 value-only realized, 28 gaps, 0 silent-zeros.
- 2026-08-27: audit-method correction — Astronomer & Golden already faithful → **26 real gaps**.
- 2026-08-27/28: **24 of 26 implemented + tested** (sim suite 601 pass, +1 pre-existing unrelated overflow
  fail; engine suite 1079 pass). Done: Faceless, Mr. Bones, Space, Chaos, Delayed Grat, Satellite, Golden
  Ticket, Midas, Mail, To Do List, Hiker, Gift, Marble, Certificate, Riff-Raff, Burnt, Sixth Sense,
  Showman, DNA, Perkeo, Luchador, Invisible, Diet Cola (+ Astronomer/Golden already-faithful). **2
  DEFERRED** (Oops — golden-scorer-invasive; Matador — needs a boss-trigger event bus).
- ⚠ **NEXT:** the world is now more faithful but the death-ante calibration may have SHIFTED — re-validate
  against real `bes_runs` before trusting sim A/B verdicts, and re-run the anti-churn / money-dig A/Bs.
