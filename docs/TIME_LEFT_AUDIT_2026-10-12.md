# Time-left audit 2026-10-12 -- where "how much of the run is left" changes a valuation

**Owner's principle (2026-10-12):** what matters is what is needed to most likely WIN. A STATIC boost (a joker, a hand
level, a slot) is worth what it adds to the chance of clearing the remaining blinds -- the hardest ones (ante 6-8 bosses)
decide it -- not "value per blind x blinds it will be around for". Time left legitimately matters only for things that
GROW or PAY OUT over time (scalers, money/interest, generators), and for the time left to still FIND pieces.
**Owner's second point:** early in a run there is no direction yet (which hand you will play), so hand-specific
investments (planets, Celestial packs) are worth LESS early, not more.

## A. Static power multiplied by time left -- SUSPECT (the owner's error class)
| where | what | effect |
|---|---|---|
| `CV.level_scale` (consumable_value.lua:79) = 1 + 0.45 x antes left, capped 4 | every persistent hand level: planet cards (CV ~983), Celestial-pack pool (packs.lua:150), Black Hole (packs.lua:292) | a level is worth up to **4x at ante 1** vs 1x at ante 8 -- the opposite of the owner's "worth less early (no direction)" |
| `CV` ~290 (hand-size / one-card-fewer value) x `level_scale` | hand size changes priced with the same runway multiplier | static power x runway |
| `Eval.negative_slot_fv` (eval_function.lua:2090) | flat 6.0 boss hands x (antes left / 6) x board fill | flat AND runway-tapered; 4-12x the measured Antimatter slot; also double counts (a Negative joker OCCUPIES its own slot) |
| Telescope voucher (vouchers.lua:325) = gain per pack x packs per ante x antes left | levels counted per future pack, each level already carrying level_scale | time counted twice |
| Marble Joker (eval_function.lua:623) = stone value x blinds left / 2 | growth (stones accumulate) priced as a run-average, not at the deciding blinds | mixed |

## B. Growth -- time legitimately counts (check the UNIT, not the time factor)
Scaler projections (`Eval.scaling_projection`, `event_fed_forward`, deck-buff (Hiker), `Eval.time_ramp` -- the
time-consistent ramp shipped 2026-10-10), scaling/discard fuel credits (`scaling_fuel`, `discard_fuel`), leveling
generators (Burnt / Space, `leveling_fraction`), consumable generators (`generator_fraction`), seal generators
(`CV.seal_generator_value`: Blue/Purple produce per blind -- but each produced planet is then priced WITH level_scale,
so the time is counted twice there too), decaying resources (Turtle Bean, Ramen), Gold-card money (tarot.lua:516),
Overstock's extra card views (shop_advisor ~1421).

## C. Money / interest -- time counts (a stream), shape worth re-checking
`SA.interest_horizon` (fades over antes 6-8), `VU` interest fade (value_units ~107), `SA.ENDGAME_*` damp at ante 7+,
`Eval.money_weight` (switch off), the final-shop rule (money after the last shop = $0).

## D. The measuring stick itself
Everything is measured as a fraction of the NEXT boss's per-hand need; jokers are also measured "now + at the run's
midpoint" (`Eval.forward_measure`); `VU.dollar_frac` converts $ to that unit by ante. Under the owner's principle the
stick should be the requirement that DECIDES the run (the binding later blinds). The forward measure is a step toward
that; levels and the slot never got it (they use the runway multipliers in A instead).

## Plan (owner-approved 2026-10-12, after `lshare_7` lands)
1. Negative tag / Negative jokers: value = one average random shop joker, no slot credit, never lost on a full board.
2. Hand levels: drop the `level_scale` runway multiplier; price a level the way jokers are priced (forward measure).
3. Then the rest of section A, one at a time; section B's double counts (seal generators, Telescope).
4. Optional ceiling probe: +1 joker slot granted at ante 2 / 4 / 6 -> what a slot is worth by stage, in P(win).
