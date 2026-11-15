# Engine Sim — Decision Assistant & Self-Player

Engine Sim reads your live game and recommends the best move, with a reason: what to play or discard, what to buy,
sell or reroll in the shop, which pack card to take, whether to skip a blind, and which consumables to use. It can
also **play whole runs by itself**.

## Win rate

| | Red Deck, White Stake |
|---|---|
| **Simulator** (current build, 160 seeded runs) | **~41%** wins (65 / 160), half the runs reach ante 8 |
| **Real game**, playing itself unattended | **13 wins in 52 runs** (two recorded nights: 9 / 26 and 4 / 26) |

The simulator is the project's own model of Balatro's rules, so its number is a guide, not an in-game guarantee.
For scale, the same simulator measured ~1% in August, ~6% in late September and ~28% at the start of October 2026.

![The advice panel in an Arcana Pack: it recommends The Tower, tags the card to apply it to (TARGET) and the pick (TAKE)](https://raw.githubusercontent.com/Anto640/balatro-engine-sim/main/docs/images/screenshot-pack-advice.jpg)

## How it works

- **It measures instead of using tier lists.** For each option it deals many sample hands from *your* deck and scores
  them with a re-implementation of Balatro's scoring, with your jokers, levels, enhancements and the current boss.
  A joker is worth what it adds to your scores, now and projected to mid-run as your deck and hand levels grow.
- **Play and discard:** picks the play that best secures the blind, and discards that dig toward the hand your
  jokers reward. It handles card order (Photograph, Hanging Chad, ×Mult placement) and money discards (Faceless,
  Mail-In Rebate, Trading Card).
- **Shop:** buy, sell, reroll or save, judged in one currency with an interest-aware money plan. It considers swaps
  on a full board and values vouchers by what they do for this run.
- **Packs:** planets by the hands you actually play; tarots and spectrals by their measured effect on your deck,
  naming the card to target; jokers against your current board, including which joker to sell to make room.
- **Blinds:** skip-for-tag versus play, and whether your board is on pace for ante 8, which tilts it between
  economy and power.
- **Tested by playing.** The advice is tuned with a headless simulator that plays whole runs on the real engine,
  with paired A/B experiments over 160 seeded runs, and checked by watching the mod play the real game.

## How to use it

Start a run. The advice panel sits at the top of the left HUD; hover it for the reason and stats. A small tag marks
the recommended card, shop item or button.

| Key | Action |
|---|---|
| F9 | Show / hide the panel |
| F11 | Self-play on/off (the mod plays the run on its own advice) |
| F6 | Auto-restart on/off (with self-play on, a finished run restarts after 4 s) |

Settings (panel, tags, self-play speed): **Mods → Engine Sim → Config**.

Optional: with [Handy](https://thunderstore.io/c/balatro/p/SleepyG11/Handy/) installed, self-play skips animations
and runs much faster. Without it, self-play still works at normal speed.

## Limits

- Strongest at in-blind play; weakest at assembling a build (valuing jokers as a set rather than one by one).
- Tuned and measured on Red Deck, White Stake. Other decks and stakes work, but are less tested.
- **Single-player only.** Don't use it in Balatro Multiplayer or any competitive setting. Under some bosses it can
  read face-down cards, which a human player can't.

## Good to know

- It writes logs to your save folder (`%APPDATA%/Balatro/`): `bes_runs.jsonl`, `bes_fixtures.jsonl` and
  `bes_autoplay.log`. They stay on your PC and are only used to review its decisions.
- Unofficial fan project. Not affiliated with or endorsed by Playstack or LocalThunk; it ships no game code or assets.
- Built by Anto640 together with Claude (Anthropic), which wrote most of the code. It is open source (MIT), with
  the full research log of what helped and what didn't:
  [github.com/Anto640/balatro-engine-sim](https://github.com/Anto640/balatro-engine-sim).

Maintenance is sporadic. Bug reports are welcome on GitHub but may wait.
