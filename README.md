# Balatro Engine Sim — Decision Assistant Mod

A Balatro mod that reads live game state and recommends the best move — what to
play, discard, buy, sell, reroll, skip, and which held consumables to use — with
a reason for each. See [`DESIGN.md`](./DESIGN.md) for the original technical
design.

**Status: roadmap complete (M1–M4) + a large correctness/coverage/strategy pass.**
On top of the deterministic engine (M1), decision layer (M2), probabilities (M3)
and shop advisor (M4), the engine now models the full base-game joker roster,
joker and card *ordering*, situational joker *downsides*, held planet/tarot *use*,
owned-joker *synergies* with shop and blind actions, **boss-blind effects** (in
scoring, survival, and shop), a **whole-run pacing model** (the ante race), and a
bounded **sequencing search** that refines play-vs-discard (now joker-aware). A
recent correctness pass fixed live-key joker mismatches that silently scored zero
(e.g. Gluttonous, whose base-game key is misspelled `j_gluttenous_joker`), made
discard planning *dig* for the hand your jokers reward instead of over-saving,
stopped unaffordable / falsely-free rerolls, and corrected the consumable/pack
advice (Hex/Ankh penalised for the jokers they destroy, Judgement valued as the
free joker it makes, size-labelled packs, flicker-free deterministic pack picks,
and naming which card a tarot targets). A further strategy pass added **play-time
scaling fuel** (play the hand that feeds Runner / Square / Spare Trousers / Ride the
Bus / Wee when survival allows), a **realized-growth gate** (condition-locked scalers
aren't over-valued in decks that never make their trigger hand), **need-gated pack
buying** (free slot / deck-shaping / pacing margin, with slot-aware generator tarots
and a "sell or use a held card to make room" note), a **sell-to-fund** shop move
(sell a low-value joker / consumable to afford an appetising buy), **Trading Card**'s
single-card destroy-for-$3-and-thinning discard, and clearer advice — Standard-pack
picks named by exact rank / suit, and tarot targets named from your **drawn hand**
(a strategy phrase when none is dealt yet). *MCTS multi-turn lookahead is
intentionally deferred — see "Deferred".* `740 headless tests` (+195 sim) pass.

The engine is **tuned by self-play**: a headless simulator (`sim/`) drives the real engine
through whole runs, logs the same JSONL telemetry the live mod does, and `tools/analyze_runs.lua`
shows *where and why* runs die. The sim is now **deterministic per seed across processes** (a bug
where randomized `pairs()` order made the same seed diverge between runs was fixed — sorted-key
sampling + stable tie-breaks), which makes A/B comparison trustworthy **and** lets batches run
**in parallel across all cores**: `bash tools/sim_par.sh <n> <name>` shards the seeds and merges
the output (≈9× faster — n=40 in ~6 min vs ~60). The telemetry is **diagnosis-rich**: a per-hand
play log, a **variance-death vs build-death** split, skip decisions, and per-offer valuations, so
`analyze_runs` says whether a run died on in-blind *play* or on *build* strength. Run a batch, then
`lua tools/analyze_runs.lua sim_out/<name>.jsonl [trace [seed]]`, or the **paired** A/B verdict tool
`analyze_runs.lua <A> compare <B>` (sign test + a continuous progress metric). **Current frontier
(honest):** mean death-ante has climbed to **3.612** (n=160 paired) but still 0 wins — a faithful,
brutal gauntlet. A **research-grade audit (`WINRATE_AUDIT.md`, 2026-07-05)** found the long-standing
"the wall is architectural" conclusion was *confounded by a sim world that couldn't express the winning
archetypes*, and drove a six-phase program: fix the referee (world fidelity), then the engine's
valuation, then re-litigate every previously-"failed" experiment against the faithful world, then the
in-blind survival policy. **The #1 tuning rule (proven across every phase):** ship unit/mechanism/
correctness fixes freely; any isolated measurement/value re-weight that doesn't co-move the constants
tuned around it backfires. The biggest wins were fidelity corrections, an additive "boost a needed
piece" priority (first-scorer; leveling-need — which *flipped* from a backfire to a gain once the world
was fixed), and a boss-aware in-blind survival arbitration. The remaining wall is **build-assembly**:
a greedy per-decision valuation can't *commit to and assemble* an archetype, so the evidence-backed next
lever is a committed-archetype planner. **Authoritative plan: `WINRATE_AUDIT.md`; fresh-session handoff:
`NEXT_SESSION.md`; working loop: `CLAUDE.md`; superseded plans: `docs/archive/`.**

## What it advises

- **Play / Discard** — the strongest legal play vs. a draw, on a survival
  objective (prefer a guaranteed clear; bank money on overkill). Discards are
  **joker-aware**: they measure the expected hand after redraw with your jokers
  applied, try every discard size (up to a full 5-card re-roll), and keep the cards
  your best joker hand uses — so the engine *digs* for the hand your jokers reward
  instead of clinging to high cards. They also account for held planets,
  Delayed Gratification's no-discard money, and **Trading Card** (on the first
  discard, pitch a single chaff card to destroy it for $3 + permanent thinning —
  free when you still have a discard to dig with afterward). When you own a
  **condition-locked scaler** (Runner / Square / Spare Trousers / Ride the Bus /
  Wee), it also plays the hand that *feeds* it — a Straight to grow Runner, a
  4-card hand for Square — but **only when survival is preserved** (a guaranteed
  clear, or on-pace), so fuelling never trades away the blind (engine/scaling_fuel).
- **Joker & card order** — flags when reordering beats your current order
  (`+mult` before `×mult`, additive card effects before `×mult`); once the clear
  is locked it orders for **money** (e.g. a Hanging Chad retrigger on a gold seal).
- **Use a held consumable** — use a planet to level the hand you'll play; use a
  tarot for income (Hermit/Temperance) or to enhance/convert your cards for a
  bigger play, naming **which card(s)** to apply it to **from your drawn hand**
  (e.g. `apply to AS`, `convert AS, KC → Hearts`; Stone goes on your *weakest*
  card) — and a strategy phrase ("apply to your 2 highest-value cards") when no
  hand is dealt yet, so it never names a card you haven't drawn. The target is
  lifted into the headline move line, not buried in the reason.
- **Shop** — buy joker / consumable / voucher / pack, reroll, sell, **sell-to-fund**
  (sell a low-value joker / held consumable to afford an appetising buy you're just
  short of — valued as the item gained + the cash raised − what the sold item was
  worth to keep, so it only fires when the maths win), or save —
  valued in one currency with a **breakpoint-aware interest cost** built on an
  **end-of-shop bankroll plan**: the $1-per-$5 interest curve is a step function,
  so the visit plans a single target end bankroll (the cap, where interest maxes)
  and a shop-wide free budget (the overflow above it). Every buy draws against
  that one budget — so a sequence of purchases telescopes correctly instead of
  each buy re-claiming its own "free" partial bucket — and the plan + interest-free
  headroom are surfaced on SAVE. A survival reserve floors it, plus reroll gating
  (free-reroll / above-cap / at-risk), owned-joker synergies (e.g. open packs with
  Hallucination, sell with Campfire, free Celestial packs with Astronomer), an
  **upcoming-boss** adaptation (Flint/Wall/debuff next → weight scoring up + a hint),
  and a **scaling projection** — a scaler (Ride the Bus / Hologram / Vampire /
  Constellation / Green Joker) is valued for what it *becomes* over the blinds
  remaining (x-mult compounds steepest), not just its current counter, so an early
  x-mult scaler out-values an equal-tier flat joker (bounded; not for Madness,
  whose growth costs you jokers). A **realized-growth gate** keeps that projection
  honest: a scaler that only grows on a specific played hand (Runner on Straights,
  Square on 4-card hands) is discounted by how often your deck actually makes that
  hand, so it isn't over-valued in a deck that never triggers it. The same projection
  makes the engine **chase a scaler's fuel**: owning Constellation raises planet /
  Celestial-pack value,
  Hologram raises Standard-pack value, Vampire/Glass/Lucky Cat raise enhanced-card
  sources, Campfire raises selling, Flash raises rerolling — and harder EARLY,
  since a permanent increment gained now compounds over every blind left.
  Jokers are otherwise **measured** from your deck (engine/joker_value), but the
  single-hand sampler under-credits held/retrigger combos (it plays the very
  cards Baron/Steel want held and never sees Mime's held retrigger), so a
  deck-aware **synergy** term covers what measurement misses — enriched ranks
  (Baron/Triboulet kings, Scholar aces), seals, and a retrigger joker's payload
  (your seals/enhancements to double) — and the measured floor is raised for the
  classes the sampler is known to suppress. A **deck-composition target** (engine/
  deck_plan) reads the run's archetype (a thin single-suit flush build, a face
  build, or just "thin") and prices **card removal**: Hanged Man cuts your two
  worst (off-suit / low) cards, Immolate trades random thinning for $20 — valued
  by how much a leaner, more focused deck lifts every future draw, so deck
  shaping (not just adding cards) finally has representation. Consumables are
  valued on the *matching* scale — a Judgement (which creates a joker) competes
  with a joker buy (its created joker measured deck-aware, not a flat prior), while
  **Hex / Ankh are penalised for the jokers they would destroy** (so the engine
  won't wipe a built board) — and booster packs are named with their **size**
  (Mega / Jumbo Arcana, …) so two packs of the same type are distinguishable.
  Packs are bought on **need** (a free slot, deck-shaping, and the pacing margin
  damp a reflexive buy) and fundable by a sale when you're just short.
- **Open a pack** — which revealed item to take, in use-order, deterministic (no
  flicker). Jokers and Standard cards are measured against your deck; a Standard
  pick is named by its **exact rank / suit / enhancement / seal** ("Gold King of
  Spades"), not a generic "Gold Card". Slots are respected: a Buffoon pick on a
  **full board** names the weakest joker to **sell** to make room (or flags it's
  only a cash sidegrade), and a **generator** tarot (Emperor / High Priestess /
  Fool create consumables; Judgement / Soul create a joker) is valued by how much
  of its output actually *lands* given your free slots — with advice to use a held
  card or sell a joker to make room, so a slot-blocked generator loses to a usable
  pick.
- **Skip vs play a blind** — tag value vs. playing, crediting blind-select
  generators (Cartomancer / Riff-Raff / Marble) to playing.
- **Whole-run pacing** — projects your measured engine strength forward against
  each ante's boss; the economy-vs-power tilt is driven by "are you on pace to
  beat ante 8?" ("Behind pace (~1.4×/ante; falls off by ante 3) — build power").

## Layout

```
core/   state_extraction.lua   the ONLY file that reads global G
        signature.lua          change detection (state/shop/pack/blind transitions)
model/  game_state.lua         the serialisable POD contract
        shop_state.lua         shop POD + slot/affordability helpers
engine/ hand_eval.lua          classification + scoring pipeline; effective-joker
                               (copy) resolution; retrigger-aware chips + money
        joker_effects.lua      per-joker scoring hooks (scaling read live counters)
        joker_data.lua         ~150-joker catalogue (tier / econ / tags)
        joker_value.lua        MEASURED joker strength vs your deck
        joker_downside.lua     situational downsides (hand-size/destroy/decay/stickers)
        eval_function.lua      run strength / future value (minus downsides)
        heuristics.lua         draw detection + discard valuation
        discard_value.lua      measured, joker-aware discard (all sizes; digs for the joker hand)
        ordering.lua           best joker/card order for a play (score or money)
        search.lua             bounded blind-sequencing expectimax (refines play/discard)
        scaling_fuel.lua       play-time fuel: feed condition-locked scalers (Runner/Square/Trousers/RtB/Wee) when survival allows
        decision_engine.lua    enumerate + rank actions -> RankedActionList
        probability.lua        exact hypergeometric draw odds
        simulation.lua         discard-aware, boss-aware Monte-Carlo survival + outs
        mechanics.lua          ante requirements, boss table, economy facts
        boss_effect.lua        boss-blind effects: scoring debuffs, resources, legality
        pacing.lua             whole-run pacing (engine strength vs the ante curve)
        consumable_value.lua   tarot/planet/spectral valuation (thinning; Hex/Ankh joker-destroy penalty)
        deck_plan.lua          deck-composition target + card-removal (thinning) value
        tarot.lua              in-blind tarot use + shop value + which drawn-hand card(s) to apply it to
        vouchers.lua           voucher values
        packs.lua              booster-pack valuation (sorted = deterministic); size-labelled names
        pack_open_advisor.lua  which revealed pack item to take (deterministic; names specific cards, slot/sell-aware, generator slot-fit)
        skip_advisor.lua       skip-blind vs play (+ blind-select generators)
        generators.lua         blind-select / play-time generator jokers
        owned_synergy.lua      owned jokers that trigger on shop actions
        shop_advisor.lua       buy/sell/sell-to-fund/voucher/pack/reroll/save; need-gated packs; pacing + boss aware
        tags.lua               skip-tag values
ui/     overlay.lua            recommendation panel state (move/conf/EV/reorder/reason)
        hud_inject.lua         draws the panel via love.draw (word-wrapped)
util/   cards.lua, log.lua     pure helpers
tests/  runner.lua             headless test harness (no game required)
        test_hand_eval.lua     golden + classification + scoring
        test_decision.lua      play/discard/order/planet/tarot/generators/search
        test_simulation.lua    probability + MC + eval + downsides + boss + pacing
        test_shop.lua          shop direction + synergies + resilience
        test_deck_plan.lua     deck target + card-removal (thinning) value
        test_jokers.lua        per-joker scoring + coverage guard
        test_mechanics.lua     ante / boss requirement facts
        test_advisors.lua      pack-open + skip advisors + consumable/pack/tarot valuation
        test_telemetry.lua     run-telemetry state machine + action trace + JSON
        runner_sim.lua         SEPARATE: Phase-1 simulator suites (slow; run with luajit)
        test_world.lua         sim in-blind mechanics + boss min-ante gating
        test_driver.lua        sim full-run loop + telemetry round-trip
        fixtures/hands.lua     hand-built states with expected scores
core/   run_telemetry.lua      pure run-trajectory recorder + action tracer (live + sim)
sim/    world.lua              forward simulator: faithful in-blind play, boss gating, economy/advance
        content.lua            shop/pack generation (odds), skip-tag economy, action trace
        driver.lua             full-run loop -> telemetry JSONL (same shapes as live)
tools/  analyze_runs.lua       death-ante / variance-vs-build / per-ante / COUNTERFACTUAL / skip stats / trace
        sim_batch.lua          run N sim seeds -> sim_out/<name>.jsonl (live progress; [shard nshards] for parallel)
        sim_par.sh             PARALLEL batch across all cores (shards seeds, merges) -- ~9x faster
util/   json.lua               dependency-free JSON (JSONL telemetry)
main.lua                       Steamodded entry; namespace require-loader; F7/F8/F9
your_mod.json                  Steamodded metadata
```

## Joker coverage

Every joker in `joker_data.lua` is either **modelled** (a scoring hook in
`joker_effects.lua`) or explicitly **value-only** — a coverage-guard test fails if
any is left as a silent zero. Scaling jokers read their live `ability` counter
rather than re-simulating; copy jokers (Blueprint/Brainstorm) act in every phase;
hand-modifier jokers (Four Fingers / Shortcut / Smeared) change classification.
Action-triggered jokers are mapped by *where they fire*: scoring → `joker_effects`,
$/round → shop income, shop actions → `owned_synergy`, downsides → `joker_downside`,
blind-select / play-time generators → `generators`.

The coverage guard catches catalogue gaps, but a joker's *live* center key can
differ from our catalogue key — the base game misspells some (Gluttonous is
`j_gluttenous_joker`) — and a mismatch would score a silent zero. So the mod also
**logs any board/shop joker key it doesn't recognise** (`[BES][WARN] uncovered
joker key …`), and the **F7** debug dump annotates each owned joker
`scored` / `value-only` / `UNCOVERED` — turning an invisible mis-valuation into a
reportable one.

## Deferred / known limits

- **MCTS** (`engine/mcts.lua`) isn't built; the bounded `search.lua` refines the
  play-vs-discard *recommendation* but does NOT yet drive the simulation rollout
  policy or the `joker_value` held-synergy measurement (those run per-sample /
  per-shop-joker and the search is too costly there without an optimisation pass).
  The `scoring_gain` tier floor remains the held-synergy mitigation, and the
  1-hand-plus-discard case still routes to forced PLAY.
- **Pacing** growth is a heuristic (xmult compounding can't be projected exactly);
  it's deliberately conservative ("behind → build power"). Magnitudes are tunable.
- Some one-off consumables/jokers that need within-round sequencing the engine
  doesn't track (Strength/Death/Hanged-Man tarots, DNA, Sixth Sense's "first
  hand", Burnt) fall back to flat values; a few bosses are mult-only/approximated
  (face-down-draw, Pillar/Arm/Serpent/Ox/Tooth).
- **Tarot apply-targets** are named only from your **drawn hand** (a tarot applies
  to cards selected from a dealt hand); before a hand exists they fall back to a
  strategy phrase rather than naming an undrawn card. The pick within the hand uses
  a chip heuristic (highest card; Stone → weakest; suit tarots convert the highest
  off-suit cards), not a per-card measurement — a possible future refinement.

## Running the tests (headless — no game needed)

Requires a standalone Lua 5.1+ (or LuaJIT). From the project root:

```sh
lua tests/runner.lua          # 740 unit tests
luajit tests/runner_sim.lua   # 195 sim integration tests (test_world / test_driver / …)
```

Exit code is non-zero on any failure; failures print as `FAIL  <case>  (got X, want Y)`.
No `love`, no `G`, no Steamodded — the engine consumes plain tables, which is what
makes it testable (and deterministic: the shop, the discard valuation, AND the
pack-open picks use a per-state seeded RNG, so the live recommendation doesn't
flicker between ticks — and the sim now samples all pools in sorted-key order so a
seed is byte-identical across processes, which is what makes the parallel runner safe).

## Installing in-game (manual smoke test)

1. Install [Lovely injector](https://github.com/ethangreen-dev/lovely-injector),
   then [Steamodded](https://github.com/Steamodded/smods) (Lovely first).
2. Copy this folder into your Balatro `Mods/` directory.
3. Launch Balatro, start a run. The recommendation panel appears in the HUD.
   - **F7** dump owned jokers' live `ability` tables (debug) to the console and to
     `bes_joker_dump.txt` in the LÖVE save folder; each is tagged
     `scored` / `value-only` / `UNCOVERED` so a mis-keyed joker is obvious
   - **F8** force a re-evaluation (also logs to console / DebugPlus)
   - **F9** toggle the overlay on/off

## Notes / to verify against the installed game

The headless suite does NOT exercise the in-game `G` reads — a green suite is
necessary, not sufficient. Fields marked `-- VERIFY` (stable card id, `sell_cost`,
`reroll_cost`, `chips_scored`, `current_round.free_rerolls`, sticker flags, and
`run.boss_key` for the upcoming boss) should be confirmed against your Balatro
version. The **F7** ability dump confirmed the scaling-joker counters live in
`ability.mult` / `ability.x_mult` / `ability.chips` with the expected defaults for
the current version, so those reads are no longer guesses. A wrong field shows up
only in game, and a shop sub-step that throws on real data is caught per-item and surfaced
in the panel as `[partial: …]`. RNG jokers/enhancements (Lucky, Misprint,
Bloodstone) return **expected** values and flag `approx`; a guaranteed `score_min`
floor (no RNG upside) is tracked alongside.
