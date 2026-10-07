# Plan: joint money-farming + scoring in-blind (queued 2026-10-06, runs after the unit-audit arms)

Owner, 2026-10-06: "if i am not able to respond for a while after the batches finish which [bigger lever] should be
done. it should be planned for then done automatically without my confirmation." Chosen lever: the open frontier the
owner named on 2026-09-19 (NEXT_SESSION.md "THE OPEN FRONTIER"): milk money WHILE clearing.

## Why this lever
- Every other big family is closed: build/economy/valuation measured to the ceiling (V4), shop supply concluded
  (10-01: reachable supply/early money ~+0.3 progress, nothing bigger), pure scoring play near-optimal, the
  conversion wall needs set-scoring (a speculative rebuild).
- Money is the one input measured to BIND (shop ceiling probe), and in-blind farming produces it every safe blind
  -> passes the frequency ceiling (fires in most blinds of most runs).
- Pieces exist: DE.MILK_MONEY (shipped 2026-08-21: farm a guaranteed blind), HandEval.play_econ,
  engine/discard_fuel.lua, engine/hold_fuel.lua. What is missing is a MEASUREMENT of the $ left on the table.

## Phase 0 -- measure the gap (no engine change)
1. `tools/money_gap.lua` on the current baseline arm: per blind, the $ actually earned in-blind (played money,
   held Gold at round end, $1 per unused hand, money-joker fires) and the MISSED opportunities, by category:
   (a) a guaranteed blind cleared with discards left while a money discard was available (Mail-In rank,
   Faceless 3 faces, Trading Card first discard, Purple seal, Delayed Gratification needs NONE used);
   (b) Gold cards played instead of held; (c) econ-joker conditions left unfired (To Do List hand, Business Card
   faces, Rough Gem diamonds, Golden Ticket golds); (d) a clear that used more hands than needed;
   (e) (owner 2026-10-06) MONEY CARDS LEFT IN THE DECK -- Gold (pays only if HELD at round end), Gold-seal / Lucky
   (pay when scored), Steel and other held-value cards -- that the blind's UNUSED discards would have drawn. This
   measures how strongly the engine digs FOR money cards, not just whether it uses the ones it is dealt. With the
   CRN sim the draw pile's order is fixed per blind (World.keyed_shuffle of the deal seed), so "within reach" is
   exact: replay the pile order and count the money cards among the next (spare discards x cards per discard).
   Report it per blind and as $ missed (Gold $3 each held; Gold seal $3 / Lucky EV per scored trigger).
   Needs per-blind telemetry already in the trace (blind_result: plays, discards, hands_used, discards_left) +
   the board; add fields to the sim's blind_result only if missing (sim-only, never changes decisions).
2. A loosened-MILK probe arm (env overrides of DE.MILK_SURV_TOL / DE.MILK_MONEY_MARGIN / the hands_left gate,
   off by default): does farming harder earn more $ and does that convert? Verdict vs the baseline arm.

## Phase 1 -- fix the biggest category
Implement the fix for the largest measured category (expected: spend the guaranteed blind's spare DISCARDS on
money discards -- the play engine digs for score, not money, once the clear is assured), as a correctness change
with an A/B switch. Unit tests + replay on recorded live fixtures (bes_fixtures / bes_flagged) showing the new
advice.

## Measurement + shipping
- Paired n=160 on the current baseline (CRN sim). Report the standard table.
- Ship if progress up and wins not down, after a fresh-seed (seed_off 7) confirmation; a correctness fix with
  neutral results ships as correctness (CLAUDE.md burden of proof). Revert on mechanism, not on a null.
- Deploy with tools/deploy.sh, sync main, update NEXT_SESSION.md START HERE, memory, this doc's status block.
- Batches launch HIDDEN at below-normal priority with 11 workers (memory batch-launch-hidden).

## Status
- 2026-10-06: queued; starts when arms u3/u4/u5 + u1_7/u2_7 finish.
- 2026-10-07 PHASE 0 RESULT (baseline `mf0` = `ae51526`, byte-identical to u4 -> the telemetry is decision-neutral):
  in-blind money $1.04/blind (a1 $0.05 .. a8 $3.74); cleared blinds end with 2.62 spare discards / 2.67 spare hands
  (unused hands already pay $1). Money LEFT: Gold within reach of the spare discards 0.07/blind (<= $0.21); Gold cards
  in the deck 0.35/blind -- 0.07 held, 0.19 never drawn, ~0.09 played or discarded (~$0.27); spare discards while
  owning Mail-In 2.2% of cleared blinds (Delayed Gratification 1.5%, where sparing them is correct). TOTAL headroom
  ~$0.2-0.5 a blind (~$5-10 a run) across rare situations -- below the frequency ceiling, and small next to what the
  shop probe showed moves outcomes. The engine already farms in-blind (MILK, the active money dig, HoldFuel); the sim's
  decks simply hold little to farm. Phase 1 (a fix for the biggest category) is NOT justified by the data.
  Pending: probe `mf1` (BES_MILK_TOL=0.05, BES_MILK_MARGIN=0) -- does farming HARDER convert?
