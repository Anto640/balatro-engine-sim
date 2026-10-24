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

## Follow-up (2026-10-24 afternoon/evening)
**1. `BES_ECON_EXIT=1` + `BES_MONEY_ANTE=1` together**, all 10 owner positions, 33 paired seeds (330): 79% -> 82% (+3pp,
se 0.02). X778 a4 61% -> 91% (12 seeds gained / 2 lost; alone: ECON_EXIT 73%, MONEY_ANTE 86%); the other 9 positions flat
(13 / 12). Regression arm **emx_7 vs shp_7**: wins 64 -> 65, reach-8 77 -> 78, +0.006 (p 0.80), sign 10/3, 147 tied
(MDE ~0.07) -> clean; a correctness fix (never-expiring commitment) that fires rarely in the engine's own runs.
**Both made DEFAULT ON 2026-10-25 (owner); `=0` disables each. New baseline arm: `sim_out/emx_7.jsonl`.**

**2. Finer deck ablation** (`CONT_DECK=plain / stdmods / sizemods`, 4 positions x 22 paired seeds = 88 each, base 72%):

| removed | variant | win | change |
|---|---|---|---|
| enhancements / seals / editions (owner cards kept) | plain | 48% | -24pp (se 0.06) |
| which ranks / suits + size (owner modifiers on a fresh 52) | stdmods | 49% | -23pp (se 0.07) |
| which ranks / suits only (size matched) | sizemods | 50% | -22pp (se 0.07) |
| everything (fresh 52) | std | 31% | -41pp (se 0.06) |

Modifiers and composition carry about half each and add up; size alone ~0 (cf. thin8 vs thinr8). SEMX's edge is its
modifiers (11 Gold + Ticket: plain -36, stdmods 0), UEZM's its composition (46 cards, Clubs-heavy for Onyx Agate:
stdmods -45). Per position n=22 (se ~0.12).

**Why the engine's decks stay vanilla:** at antes 2-4 it uses ENHANCEMENT tarots at the owner's rate (1.83 vs 1.89 a
run) but COMPOSITION tarots (Death / Strength / Hanged Man / suit) ~3x less (0.87 vs 2.49; pack picks 0.33 vs 2.0 in the
capture runs). It sees ~3.7 a run and takes 22%: in packs it prices the suit tarots at the flat 0.03 floor
(`CV.suit_tarot_value`), Hanged Man ~0.08, Strength ~0.10, vs Hermit ~1.05.

**3. Free-shaping ceiling probes** (vs shp_7, 160 paired seeds, seed_off 7):

| arm | free supply | wins | reach-8 | progress (p) | sign |
|---|---|---|---|---|---|
| ar4_7 (`arcana4`) | a Mega Arcana opened every shop a1-a4 (~24 tarots) | 140 | 143 | +1.157 (<0.0001) | 88/11 |
| sh4_7 (`shape4`) | 3 composition tarots, 1 forced engine-ranked pick, every shop a2-a4 | 75 | 93 | +0.330 (0.028) | 70/46 |
| en4_7 (`enhance4`) | the same with the 8 enhancement tarots | 102 | 113 | +0.733 (<0.0001) | 78/27 |

ar4_7 at a5: 20.7 enhanced cards (4.4), hand levels 12.5 (7.7), median capacity 2.8x, same money -- tarot SUPPLY of every
kind (enhancement, High Priestess planets, Hermit / Temperance money), not shaping alone. sh4_7: composition uses 0.87 ->
9.5 a run (Death 2.9, Hanged Man 1.9, Strength 1.7), a5 deck 49.9 cards (53.4), same money / enhancements: matched
composition is worth wins even when the engine aims it, about thin8's size. These are FREE-supply ceilings: they do not
yet show the engine's own price is wrong (buying costs money + the pick); dq4 (blanket x4 repricing) lost.
en4_7 at a5: 18.4 enhanced cards (4.4), median capacity 42k (30.7k), same money / deck size; enhancement uses a1-a4
1.8 -> 10.4 a run (Magician 2.4, Hierophant 2.1, Empress 1.7). So of ar4's +1.16: enhancement ~+0.73, composition ~+0.33,
the rest (planets / money tarots) small or interacting. NOTE the free supply is ~5x the owner's enhancement rate --
the engine already matches the owner's PAID rate, so the open question is the price: `ba4_7` (`buyarc4`, buy every
affordable Arcana pack a1-a4 with its own money) tests it.
