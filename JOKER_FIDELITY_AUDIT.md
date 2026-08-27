# JOKER_FIDELITY_AUDIT.md — is every joker faithfully modelled in the SIM WORLD?

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

| Joker | Real mechanic | Current sim | Target |
|---|---|---|---|
| **Golden Ticket** | Gold cards give +$4 when played & scored | flat $3/round | world (post-play, gold-card count) |
| **Satellite** | +$1 at round end per UNIQUE planet used this run | flat $4/round | world (track planets-used) |
| **To Do List** | +$4 if you play a specific poker hand this round | flat $4/round | world (per-round, chosen hand) |
| **Mail-In Rebate** | +$5 per discarded card of a chosen rank | flat $4/round | world (discard hook) |
| **Delayed Gratification** | +$2 per discard UNUSED, paid at round end | flat $4/round | world (round-end, discards-left) |
| **Matador** | +$8 if played hand triggers the boss's ability | flat $4/round | world (boss interaction) |
| **Hiker** | every scored card gains +5 perma chips | nothing | tick/scoring (perma-chip growth) |
| **Midas Mask** | played face cards become Gold (→ $3 held) | nothing | world (post-play deck-mod) |
| **Gift Card** | +$1 sell value to every joker & consumable each round | nothing | tick (sell-value growth) |

### P2 — LOW: rare / situational / sell-to-trigger effects

| Joker | Real mechanic | Target |
|---|---|---|
| **Marble Joker** | adds 1 Stone card to deck on blind select | world (blind-select deck-mod) |
| **DNA** | first played card of round: add a copy to deck & hand | world (post-play deck-mod) |
| **Certificate** | round start: add a random playing card with a random seal | world (round-start deck-mod) |
| **Sixth Sense** | first discard of a single 8 → destroy it, create a Spectral | world (discard hook) |
| **Riff-Raff** | blind select: create 2 Common jokers (slots permitting) | world (blind-select gen) |
| **Perkeo** | shop exit: create a Negative copy of 1 held consumable | content (shop-exit gen) |
| **Luchador** | sell to disable the current boss blind | world (sell effect) |
| **Invisible Joker** | after 3 rounds, sell to duplicate a random joker | tick+world (counter + sell) |
| **Burnt Joker** | upgrade the first discarded poker hand's level | world (discard hook, level) |
| **Diet Cola** | sell to create a free Double Tag | world (sell effect) |
| **Showman** | allows duplicate jokers/consumables to appear in the shop | content (generation pool) |
| **Oops! All 6s** | doubles all listed probabilities | world (probability jokers) — engine already models in `Eval` |

## Implementation plan

1. **Build the hooks the sim lacks** (once), so each mechanic has a place to live:
   - a per-DISCARD hook (Faceless, Mail, Sixth Sense, Burnt) — the sim currently models plays, not discards;
   - a planets-used-this-run counter (Satellite) and a bosses/round context already present;
   - blind-select and round-start deck-mod hooks (Marble, Certificate, Riff-Raff).
2. **Implement P0 → P1 → P2**, one joker per commit, each with: the mechanic in the right layer,
   `-- VERIFY`-tagged magnitudes, a headless test, and (for the economy ones) exclusion from the flat
   `joker_econ_income` sum so it is never double-counted.
3. **Re-measure.** After P0, re-run the churn/paced A/B against the *old* world to confirm the sim is now
   harsher on economy (the anti-churn / money-dig fixes should finally register), and recalibrate the
   world against the real `bes_runs` death-ante distribution so fidelity is preserved, not drifted.

## Status log

- 2026-08-27: audit built (this doc). 102 scoring faithful, 20 value-only realized, **28 gaps**, 0 silent-zeros.
- 2026-08-27: audit-method correction — Astronomer & Golden are already faithful (cost-zeroing / correct
  flat prior), so **26 real gaps**. **P0 CLEARED**: Faceless, Mr. Bones, Space, Chaos all implemented +
  tested (sim suite 561 pass, +1 pre-existing unrelated overflow fail). **22 gaps remain** (P1 + P2).
