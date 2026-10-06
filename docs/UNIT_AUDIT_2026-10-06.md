# Valuation unit-consistency audit (2026-10-06)

Owner-agreed follow-up to the UAPB3XY9 F5 review, where three of the real defects were UNIT mismatches between
valuation channels (a one-hand tarot gain on the per-hand joker scale, discount vouchers as a $/round stream, the
swap measured in the wrong board slot). This audit walks every place a value is created and asks: what unit is it
in, and is it converted the same way everywhere it meets another channel?

## The units

| unit | meaning | where | shop utility |
|---|---|---|---|
| boss-hand fraction ("frac") | added to EVERY hand while owned: score gain per hand / boss per-hand need | jokers, planets, packs, rerolls, card tarots (per-hand since `fz`) | x5 (`VU.FRAC_UTIL`) |
| FV points | eval_function's future value, used for sell / keep / trade | `Eval.joker_marginal_fv`, vouchers.lua | 2.5 per frac (`VU.FV_PER_FRAC`) |
| $ lump | a one-off dollar | prices, sale cash, Hermit / Temperance, tags | 0.3 (`VU.DOLLAR_UTIL`) flat in the shop; `VU.dollar_frac` x5 (0.40 at ante 1 .. 0.19 at ante 8) everywhere else |
| $ per round | income every round from now on | money jokers, card money, interest | 1.0 per $/round on the buy side; see findings |

## Findings

| # | finding | class | status |
|---|---|---|---|
| 1 | vouchers.lua values in FV but the shop added it as utility: every measured voucher (Grabber, Wasteful, Paint Brush, Telescope) counted HALF a joker of the same per-hand value. Only Antimatter carried its own x2. | correctness | fixed `56ce07f` (`SA.VOUCHER_FV_UTIL`) |
| 2 | Paint Brush / Palette: a per-hand lift multiplied by the hands per round (counted every hand twice over) | correctness | fixed `56ce07f` |
| 3 | Grabber / Wasteful: a once-per-round event (one more hand / dig) on the per-hand scale without spreading it over the round's plays | correctness | fixed `56ce07f` (/ `CV.PLAYS_PER_BLIND` = 1.62, measured) |
| 4 | Gold card / Lucky / Gold seal money is $ PER ROUND but was priced as ONE round's lump (~1/3 of a money joker's rate); the Blue / Purple seals beside it are valued over the run | correctness | fixed `56ce07f` (`VU.round_income_frac`) |
| 5 | Handy tag: flat $6, though it pays $1 x hands played this run (known: `gs.run.hands_played`) | correctness | fixed `56ce07f` |
| 6 | a dollar has two prices in the shop: gains via `income_frac` are ante-aware, the price and sale cash are flat (one Hermit expression mixed both) | coherence, BROAD | A/B switch `BES_DOLLAR_ANTE=1` (arm u2) |
| 7 | the interest penalty (lost $/round x 3-round horizon) is added AS utility: one interest dollar costs 3.0 = the price of $10 of goods = 3x a money joker's $1/round; the gain side credits interest at ~1.8 | coherence, BROAD | A/B switch `BES_INTEREST_UNITS=1` (arm u3) |
| 8 | a money joker's $1/round: 1.0 utility to BUY, 0.8 FV = 1.6 utility to KEEP / trade | coherence | A/B switch `BES_ECON_FV=1` (0.5 FV) |
| 9 | pack-open money tarots used `dollars_to_frac`; the pack's purchase EV (packs.lua) and the shop use `income_frac` (interest credit) | correctness | fixed (this commit) |
| 10 | Telescope's levels lacked `CV.level_scale`, which every other planet channel applies | correctness | fixed (this commit) |
| 11 | pack-open joker trades compare the incoming pick against the FLOORED outgoing FV; the shop trade uses unfloored for plain scorers (`trade_mopts`) | coherence, rare | noted (full board + joker pack only) |
| 12 | Speed / Garbage tags flat ($5 / $4) though they pay per skip / per unused discard; the counts are not extracted live (`G.GAME.skips`, `unused_discards`) | correctness, rare | noted (needs state_extraction fields) |

## Checked and consistent

- Packs (`Packs.value` frac x5), rerolls (x5 per card), standalone planets / tarots in the shop (x5), joker buys (x5).
- Skip advisor: tag $ and play $ both lumps; the forgone shop converts frac -> $ at the same `dollar_frac` as the
  pack / joker tags; joker econ forgone = one round (correct: a skip loses one cash-out).
- Orbital tag vs shop planets vs Celestial pool: all `level_scale` x freq x level gain / need.
- Planet `level_scale` (x1..4 persistence) has no joker counterpart -- a modelling choice documented in
  consumable_value.lua (the derived version measured -0.272 and was reverted), not a unit slip.

## Measurement

Baseline `crn3` (CRN sim). `u1` = fixes 1-5. `u2` / `u3` = u1 + switch 6 / 7. Results: see NEXT_SESSION.md.
