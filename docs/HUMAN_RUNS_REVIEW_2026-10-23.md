# 12-human-run review (2026-10-23/24): the engine stress-tested FROM the owner's positions

Runs: the 8-run expert corpus (`data/bes_runs_live_2026-08-12.jsonl`, 7W / 1L X3L32ZEA) and the 4 capture runs
(SEMXURN5, X778PBYT, UEZMTED9 stopped while winning; 9MY8IRY3 died a3). Only the capture runs have full states
(records after line 53787 of `%APPDATA%/Balatro/bes_runs.jsonl`, 51257 of `bes_fixtures.jsonl`).

## Method: `tools/owner_continue_trace.lua`
Continue the sim from any recorded owner blind start (Small / Big / Boss, owner's real boss), keep the full trace, and
optionally swap ONE part of the position for the engine's typical version (`CONT_DECK=std`, `CONT_JOKERS=<boards>`,
`CONT_MONEY=<n>`). World seeds `s*1000+7` pair every variant with the unchanged position. Engine switches pass through
the env. Typical cost ~3.5 CPU-min per continuation (11 workers: ~3 runs/min).

## Results (paired)
Continuation from the owner's positions, 33 seeds each: 9MY8 a3 67%, SEMX a4 70% / a4-boss 76% / a5 91%, UEZM a4 73% /
a5 88% / a6 82%, X778 a4 61% / a5 97% / a6 85% (79% of 330). The engine's deaths there are RICH: median $40-124 held
(its own baseline deaths ~$25), 40-50 rerolls a run.

| test | n | base | variant | change |
|---|---|---|---|---|
| deck -> fresh 52 (SEMX/X778/UEZM a4, 9MY8 a3) | 88 | 72% | 31% | **-41pp** (se 0.06) |
| jokers -> an engine a4 (a3) board | 88 | 72% | 40% | **-32pp** (se 0.07) |
| money -> engine median $23 ($15 at a3) | 88 | 72% | 60% | -11pp (se 0.07); only X778 -27 / 9MY8 -23 |
| `BES_MONEY_ANTE=1`, all 10 positions | 220 | 81% | 81% | 0 (se 0.02); X778 a4 64 -> 86% (n 22) |
| `BES_ECON_EXIT=1`, X778 a4/a5/a6 | 99 | 81% | 85% | +4pp (se 0.02); a4 61 -> 73%, a5/a6 identical |

**Reading:** at ante 4 the owner's edge is the SHAPED DECK plus the jokers chosen for it (Midas gold cards for Golden
Ticket, extra faces for Photograph / Sock and Buskin, thinning for Trio), not money. Engine a4 decks are near vanilla
(2.4 enhanced, 0.42 sealed, 52.8 cards). Consistent with thin8 (free thinning +0.42) and dq4 (blanket tarot repricing
-0.31): shaping pays when it is matched to the board, not as a generic value boost.

## Defects found (traced to code)
1. **Full-board reroll inflation.** `SA` REROLL prices `Packs.expected_shop_joker` as a FREE slot (swap bar off by
   default). shp_7 a4+: median claim +105..+143% of a boss hand per roll (p90 up to +1600%), 85-92% of rolls buy no
   joker; after a late roll the next action is a consumable buy 13%, a joker 9%. SEMX a4-boss seed 5007: $200 ->
   35 rolls over a4-a6, bought nothing, died a6 Big holding $105. R12's swap-bar fix lost because rolls also refresh
   consumables; the proper fix (trade-aware joker term + consumable-refresh term) was never built.
2. **Economy commitment never expires.** `BP.keep_bias` gave every money joker CORE_KEEP (2.5) for the rest of the run
   once committed. Live X778 committed at a3; from its a4, 13/32 died at a5-a7 holding 3-4 of Egg / To the Moon /
   Bootstraps / Golden with $42-110 while advising "At risk ~78-94% -- build power". Fix: `BES_ECON_EXIT=1`
   (`BP.econ_runway`: protection + buy-side fit x blinds-left/12, full to a4, 0 at a8), default OFF. With it on, 6/9
   X778-a4 deaths still hold >= 3 money jokers -> test together with `BES_MONEY_ANTE=1`.
3. **SAVE to the interest cap at "risk 88-94%".** 15-20% of high-risk shops SAVE in shp_7. But the risk read is 2-4x
   pessimistic (claimed 50-59% -> 13% die this/next ante; 70-79% -> 34%), and the known less-pessimistic refit lost
   (50 -> 32 wins) because the shop thresholds lean on it. Only a JOINT refit (risk + thresholds) is untried.

## Owner-vs-engine structure (12 runs vs shp_7 wins)
- Joker gains per ante: owner a1 1.7 / a3 3.8 / a4-a6 2.2-2.6; engine 3.1 / 1.5 / 0.9-1.3. 64% of the engine's a1 jokers
  are still on its a4 board (owner ~0.7 per run).
- Packs: owner opens ~3-4x the Arcana packs at a2-a4 and takes Celestial late (a5+).
- Owner money comes from COMBOS: X778 To the Moon + Seed Money + Money Tree (+$21-26/round from a4); SEMX Midas -> 11
  Gold + Ticket + Blueprint (+$111 in one blind); 9MY8 Faceless (+$15-23/blind at a2).
- Per-decision agreement in the owner's a2-a3 shops stays high; "open the Celestial pack first" picks are mostly
  sequencing hints (the engine buys the joker too).
- Owner does not skip early (plays every blind through a5).

## Next leads (ranked)
1. Board-matched deck shaping: why the engine's tarot use leaves near-vanilla decks; a ceiling probe of free MATCHED
   shaping (like thin8) before any pricing change; a finer ablation (enhancements vs ranks vs size) of the owner decks.
2. `BES_ECON_EXIT=1` + `BES_MONEY_ANTE=1` together on the owner positions, then one regression arm vs shp_7 (correctness,
   mainly live advice).
3. Trade-aware reroll value with the consumable-refresh term (fires every late shop).
