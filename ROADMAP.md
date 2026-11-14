# Roadmap

Where the project stands, what is known not to work, and what is still open. For how the code is organised and how
changes are measured, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Current state (late October 2026)

- **Simulator win rate: about 41%** (red deck, white stake; 65 of 160 paired seeds on the out-of-sample pool). The
  simulator (`sim/`) is this project's own model of Balatro's rules, driving the real engine through whole runs. It is
  calibrated against recorded live runs, but it is **not** the game: treat the figure as a relative yardstick for A/B
  comparisons, not as an in-game win rate. Trajectory: ~1% in August, ~6% late September, ~28% early October.
- **Live:** the in-game self-player (F11) has been run unattended for whole nights; two recent nights won 9 of 26 and
  4 of 26 runs. These live runs are reviewed decision by decision; most fixes since September came from them.
- **Tests:** 1872 headless unit tests and 637 simulator-suite tests, all green.
- **Expert reference:** a capture of 8 runs by a strong human player (7 wins) with the engine's recommendations logged
  next to each decision (`data/bes_runs_live_2026-08-12.jsonl`). Per-decision agreement with that player is high; the
  gap is in the trajectory, not in any single choice.

## What has been established

- **In-blind play is close to its ceiling.** The scorer reproduces the game's scores, the play chooser picks the best
  play ~94% of the time, and digging (discarding for a better hand) at ante 1 matches a clairvoyant ceiling.
- **Money binds.** Giving the engine +$4 a round roughly doubles the simulator win rate, and +$10 a round lifts it
  from ~36% to ~81%. But every attempt to make the engine *earn* more (forced money jokers, money cards, vouchers,
  in-blind money farming) measured neutral or negative: the extra money has to come from a better plan, not from a
  money lever.
- **Deck shaping is the strongest edge found.** Continuing the simulator from the expert player's ante-4 positions,
  swapping their shaped deck for a fresh 52 cards costs ~41 points of win rate, more than swapping their jokers (~32)
  or their money (~11). A free Mega Arcana pack every shop in antes 1-4 lifts wins from 64 to 140 of 160; a free
  enhancement tarot alone, 64 to 102. Whether the engine *underprices* those packs at real prices, or simply cannot
  afford them, is not yet settled.
- **Shop supply binds early.** A probe with four jokers per shop gained ~0.6 antes of progress; more realistic supply
  and early-money changes gain ~0.3, below what a 160-seed batch can call for wins.

## Known limits

- **Build assembly.** Jokers are valued one at a time (leave-one-out marginal value, projected to mid-run). Boards
  whose strength is in the combination (copiers × ×mult × retriggers) are under-read, and the engine can sell a piece
  of a working set to fund a weaker one.
- **Face-down cards.** The engine reads the rank and suit of cards a boss has turned face down. Fixing that needs
  hidden-information handling the engine is not built for, so it is a known, accepted advantage.
- **Game-version fields.** Fields marked `-- VERIFY` in `core/state_extraction.lua` depend on the game version and are
  confirmed only in-game.
- **Mod setups.** Tested on Steamodded and Lovely installed through r2modman; other setups may need fixes.
- **Pacing messages are pessimistic** on combo boards (the risk read is 2-4x too high). This only affects the advice
  text; refitting it alone made play worse, so it needs a joint refit with the shop thresholds that lean on it.

## Open ideas

Roughly in order of expected value. Each has a measured lead behind it; none is a promise.

1. **Price Arcana packs and enhancement tarots by what they do to the deck.** The free-supply probes above are the
   biggest ceiling found so far. The open question is price versus income; a narrow, measured repricing (the pack's
   enhancement value, the flat floor on suit tarots) is the natural next experiment. Blanket tarot repricing lost.
2. **Full-board rerolls.** Late rerolls value the next shop's joker as if a slot were free; on a full board that
   inflates rerolls (many rerolls, few buys). A trade-aware joker term plus a term for refreshed consumables is the
   proposed fix; a simple reroll bar measured negative because rerolls also refresh consumables.
3. **Joint refit of risk and shop thresholds** (see Pacing above).
4. **A sell-consumable action.** Needed before Perkeo can be played well: the engine's consumable tray fills with
   cards it cannot use, and Perkeo copies a random one. Shipping Perkeo support without it measured negative.
5. **Board-as-a-set valuation** (the build-assembly limit above). The hardest and probably the largest.
6. More recorded runs from strong human players, to find the ante-2/3 decisions where their trajectory and the
   engine's part.

## Already tried

Most single levers on the shop, economy, pacing and in-blind play have been measured with paired simulator batches,
and the negative results are kept on purpose so they are not re-tried by accident:

- [`docs/archive/CLAUDE_HISTORY.md`](docs/archive/CLAUDE_HISTORY.md): the investigation log (win-rate audits,
  operating-point results, refuted levers, the human-run dataset findings).
- [`docs/GRAND_AUDIT.md`](docs/GRAND_AUDIT.md): the deep audit of the win-rate ceiling.
- [`docs/HUMAN_RUNS_REVIEW_2026-10-23.md`](docs/HUMAN_RUNS_REVIEW_2026-10-23.md): continuing the simulator from human
  positions, with the deck / jokers / money ablations above.
- [`docs/ADVICE_REVIEW.md`](docs/ADVICE_REVIEW.md): live misplays and how each was traced and fixed.
- [`docs/archive/`](docs/archive/README.md): superseded plans and earlier audits.

Closed with a measurement (kept off or reverted): voucher and interest-stream changes, play-money pricing, forced money
cards, early-planet bans, forced Hanged Man, deck-quality multipliers, a measured-dig survival rollout, a shallow
look-ahead search at early shops, sharing Monte-Carlo deals across decisions, and one shared per-state seed for every
advisor (13 fewer wins of 160, p 0.085: not proven harmful, but it has no upside, so each advisor keeps its own seed).
