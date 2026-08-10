# Plan: eliminate static "base values" in favour of measured value

**Status:** ✅ ALL PHASES (0–6) DONE (2026-06-24). Full suite at completion: **454 passed, 0 failed** (later correctness/coverage/strategy passes have since grown it to **581**; current project state lives in `README.md` / `CLAUDE.md`). **Owner:** engine. **Created:** 2026-06-24.

> **Phase 6 landed:** minor fallbacks made honest. `ConsumableValue.card_value` Planet branch no longer
> assumes `freq 0.4` blindly — a PROVIDED freq table that omits a hand now means "you never make it" (0,
> not 0.4); with no freq table but a deck present it COMPUTES frequencies; only a deckless state uses the
> 0.4 prior. `Mechanics.boss_per_hand_need` documents its hand-count source (live `gs.blind.base_hands`
> → `gs.run.base_hands` → white-stake default 4). `Eval.edition_score_bonus` flat poly/holo prior left
> by design with a NOTE (only the no-deck prior path; measured path already reflects real magnitude).
> Tests in `test_advisors.lua`: planet freq computed from deck / 0 for an unmade hand / 0.4 only deckless.

> **Phase 5 landed:** conditional joker econ is deck-aware. `Eval.econ_value(gs, key)` scales a
> conditional joker's `$/round` prior by how the deck's relevant share compares to the balanced 52-card
> baseline (bounded ×[0,3]): **Rough Gem** (Diamonds vs 25%), **Business Card** (faces vs 12/52),
> **Cloud 9** (count of 9s vs 4). A balanced deck reproduces the prior; no deck → the flat prior
> (preserves deckless behaviour). Unconditional econ (Golden Joker, Rocket, To the Moon, Gift, Delayed
> Gratification) is unchanged; Bloodstone is xmult/scoring (econ 0), handled by the measured path.
> `Eval.econ_power` and `SA.estimate_blind_income` both route through `econ_value`. Tests in
> `test_simulation.lua`: Rough Gem Diamonds>none (0 with none), Golden deck-independent, Cloud 9 scales
> with 9s, no-deck → prior. Full suite: **451 passed, 0 failed**.

> **Phase 4 landed:** `engine/packs.lua` content pools are calculated + de-duplicated.
> `TAROT_BASE`/`SPECTRAL_BASE` now live ONCE in `consumable_value` (packs reads `ConsumableValue.*`).
> Tarot pool routes every tarot through `ConsumableValue.card_value` (the same measured
> `Tarot.shop_value` path a loose shop tarot uses — fixes "measured standalone, static in pack"),
> with lighter sampling (`card_value` gained an optional `samples` arg). Spectral pool measures
> **Black Hole** (+1 to all hands = Σ freq×level_gain, exposed as `Packs.black_hole_value`); the
> destructive copiers (Ankh/Hex destroy your other jokers) stay priors by design. Standard `card_pool`
> is deck-aware via `DeckPlan.card_quality` + real `card_econ_value` — a **cheap, noise-free** quality
> model, NOT MC `card_add_value` (adding one card to ~52 is MC noise, per deck_plan's own rationale).
> Tests in `test_advisors.lua`: single-sourced priors, Black Hole measured/deck-aware, enhancement
> tarot takes the measured path, standard pack computed-from-deck. Full suite: **445 passed, 0 failed**.
> **Perf:** standard pack ~0 ms (was static; now deck-aware *and* free), Arcana ~400 ms one-time
> (measured tarots; gated to Arcana-pack-in-shop, sample count is a tunable knob), Celestial unchanged.

> **Phase 3 landed:** `engine/tags.lua` scoring/content tags are now CALCULATED. `tag_orbital`
> (+3 levels) measured via `best_planet`/`level_gain(...,3)`; the pack tags
> (`tag_buffoon`/`tag_meteor`/`tag_charm`/`tag_ethereal`/`tag_standard`) reuse the measured MEGA-pack
> valuation (`Packs.value`) — the same machinery the shop uses — converted boss-hand-fraction → dollars
> via `value_units`, with bounded sampling and a `$` flat prior fallback when there's no deck.
> `Tags.value(gs, key, opts)` gained `opts`; `skip_advisor.recommend(gs, opts)` threads a deterministic
> per-state rng. **Scoped out (kept as priors, with rationale in code):** joker-rarity tags
> (`uncommon`/`rare`/`negative`) — a single *random* joker isn't well-modelled by `expected_shop_joker`
> (best-of-N); edition tags (`foil`/`holo`/`polychrome`) — edition-on-a-random-joker; `tag_double` —
> the next tag isn't in game state, so 2×-best-other-tag isn't computable. Tests in `test_advisors.lua`:
> Orbital flush > mixed (deck-aware) + no-deck prior; Meteor/Buffoon measured + no-deck prior. Full
> suite: **440 passed, 0 failed**.

> **Phase 2 landed:** `engine/vouchers.lua` rewritten from a flat table to base prior + optional
> situational `sit(gs, opts)` closure (returns extra FV points, 0 with no deck). Measured terms:
> Telescope (play concentration via `hand_frequencies`), Observatory (best-planet payoff), Antimatter
> (expected marginal joker, bounded sampling), Grabber/Nacho Tong/Wasteful/Recyclomancy (extra-hand
> value, at-risk scaled), Paint Brush/Palette (measured +1 hand-size lift), Hieroglyph/Petroglyph
> (ante-skip, at-risk scaled; base bumped 4→5). `V.value(gs, key, opts)` gained `opts`; `shop_advisor`
> threads `{rng, cache, samples, at_risk=not secure}` from the voucher loop. Tests in `test_advisors.lua`:
> Observatory rises above base on a planet deck, Telescope > on concentrated vs spread play, Grabber
> at-risk > secure, no-deck → base prior. Full suite: **434 passed, 0 failed**.

> **Phase 0 landed:** `engine/value_units.lua` (ante-aware `dollar_frac` + `$↔frac↔FV`
> conversions, `FV_PER_FRAC = 2.5` derived from existing behaviour); the literal `DOLLAR_FRAC = 0.03`
> is gone from `packs.lua`, `consumable_value.lua`, and `pack_open_advisor.lua` (all now call
> `VU.dollars_to_frac`). `engine/joker_value.lua` gained an opt-in measurement cache
> (`JV.new_cache()`, threaded via `opts.cache`) on `avg_score`/`score_delta`. New suite
> `tests/test_value_units.lua` (registered in runner). Full suite: 425 passed, 0 failed.
>
> **Phase 1 landed:** `eval_function` is now deck-aware/measured. New helpers: `Eval.joker_jp`
> (per-owned-joker measured marginal, paired leave-one-out, tier floor for held/retrigger),
> `Eval.measured_joker_power` (board sum, nil → tier fallback), `Eval.joker_marginal_fv` (FV the sell
> logic ranks by), `Eval.add_joker_marginal_fv` (O(1) value of adding one shop joker). `joker_power`/
> `future_value`/`run_strength` take `opts` and measure when a deck is present (`measure=false` forces
> the tier path). `shop_advisor` sell ranking (`joker_contribution`) and upgrade delta (`buy_fv_delta`)
> now measure via a shared per-`recommend` cache; the leave-one-out is **gated** behind real sell
> pressure (board full / at-risk / low cash / decaying joker) so typical shops stay cheap.
> `simulation.lua` readout deliberately stays on the cheap tier path (`measure=false`) — it runs every
> live tick and is informational only. Tests: headline deck-aware marginal in `test_simulation.lua`
> (Lusty > Wrathful on a Hearts deck) + end-to-end shop sell target in `test_shop.lua` (#26: sells the
> off-suit joker, not the deck-carrier). Full suite: **430 passed, 0 failed**.
>
> **Perf (worst-case shop, measured):** typical shop (free slots) ~250 ms; full board under sell
> pressure ~1 s (one-time); no-deck/test states instant. The ~3.7 s seen only with a Buffoon pack +
> affordable reroll is **pre-existing** pack/reroll measurement, not Phase 1. Key fix: `buy_fv_delta`
> values a joker by its own marginal (one `score_delta`) instead of re-measuring the whole board.

## Why this exists

The project's KEY PRINCIPLE (see `DESIGN.md` / memory) is: *website/wiki data = priors +
factual mechanics only; STRENGTH / VALUE must be CALCULATED by simulation, never static tiers.*

An audit found the measuring infrastructure (`JokerValue.score_delta`, `JokerValue.avg_score`,
`ConsumableValue.hand_frequencies` / `level_gain` / `card_add_value`, `Packs.value`) is used on the
**buy-a-joker** path but **bypassed** by sells, vouchers, skip tags, pack non-joker contents, and
joker econ — all of which still resolve to static catalogue/opinion numbers. This plan migrates each
of those onto the measured path, behind shared infrastructure, without regressing the directional
test suite or the live-shop performance budget.

**Guiding rules for every change below**
- Static numbers stay only as a **fallback prior** (no deck / unmodeled item / not measurable), never
  as the primary value when a measurement is possible. Mirror the existing `scoring_gain` pattern:
  `measured or prior`, with a tier floor only as an anti-noise guard.
- Tests pin **direction and bounds**, not magic constants (house style). Every fix ships with a
  directional golden test.
- Everything stays **PURE** (consumes `GameState`, no `G` access).
- Respect the **performance budget**: entering a shop is already measurement-heavy (memory notes
  lag). New measurement must be cached and shared through the per-`recommend()` RNG.

---

## Phase 0 — Cross-cutting infrastructure (do FIRST; unblocks everything)

Two foundations have to land before the consumer migrations, or each fix re-invents them and the
common currency drifts.

### 0a. A single currency / conversion module — `engine/value_units.lua` (NEW)

Today three currencies float around unreconciled:
- **fraction of a boss hand** (scoring: `scoring_gain`, `packs`, `consumable_value`)
- **dollars** (econ, tags, money tarots)
- **future-value points** (`eval_function`, `vouchers`, sell logic — roughly `0.5 * tier` units)

And the $→scoring exchange rate is a hardcoded `DOLLAR_FRAC = 0.03`, duplicated in `packs.lua:71`
and `consumable_value.lua:89`, and **ante-independent** (a dollar is a far larger fraction of a boss
hand at ante 1 than ante 8, since boss requirements scale exponentially).

Create one module that owns the conversions, all ante-aware:
- `VU.dollar_frac(gs)` — value of $1 as a fraction of a boss hand. Replace the constant with a
  function of `Mechanics.boss_per_hand_need(gs)` / ante scaling (calibrate so it ≈ 0.03 at the
  mid-game ante where 0.03 was originally tuned, then decays late / rises early).
- `VU.frac_to_dollars(gs, frac)` and `VU.dollars_to_frac(gs, $)` — inverses.
- `VU.frac_to_fv(frac)` / `VU.fv_to_frac(fv)` — pin the scoring↔FV scale ONCE so the sell-side
  rework (Phase 1) and the buy-side `scoring_gain` agree. Derive the constant from current behaviour
  (`scoring_gain` multiplies measured-fraction by `w_score * 5`; `future_value` weights joker_power
  by 1.5 on `0.5*tier`) so existing directional tests survive.

Migrate `packs.lua` and `consumable_value.lua` off the literal `DOLLAR_FRAC` to `VU.dollar_frac(gs)`.
**Test:** `dollar_frac` is monotonic in ante (early > late); round-trip conversions are inverses.

### 0b. A measurement cache scoped to one `recommend()` — extend `engine/joker_value.lua`

Phase 1 (leave-one-out sell ranking) and several voucher/tag fixes call `avg_score` / `score_delta`
repeatedly on near-identical states. Add an opt-in memo keyed by a cheap state signature + sample
count, threaded through `opts.cache` (a plain table created once per `SA.recommend`), reusing the
existing shared `rng`. No global state (keeps PURE + deterministic). Without a cache the leave-one-out
in Phase 1 is `O(N jokers)` extra `avg_score` calls per shop tick.
**Test:** two calls with the same cache + signature return identical numbers and only sample once
(spy via a counted rng).

---

## Phase 1 — Sell-ranking & run-strength: route through measured value (HIGHEST IMPACT)

**Problem.** `Eval.joker_power` (`eval_function.lua:70`) = `tier * 0.5 * projection` (static). It
feeds `future_value` (`:137`), which feeds `joker_contribution` (`shop_advisor.lua:257`, weakest
joker to SELL) and `buy_fv_delta` (`:169`, upgrade target). So **buy is measured but sell is tier**:
the advisor can sell the low-tier joker actually carrying your deck and keep a high-tier dud. This is
a correctness bug, not just a mis-tuning.

**Fix.**
1. Add `Eval.measured_joker_power(gs, opts)` that values the board by summed measured marginal
   contribution: for each joker, `avg_score(board) − avg_score(board without it)`, deck-sampled via
   `JokerValue`, using the Phase-0b cache + shared rng. Convert to FV units via `value_units`. Keep
   the scaling **projection** multiplier (still bought for what it becomes). Fall back to the tier
   prior per-joker when unmeasurable (no deck / unregistered effect) — same `measured or prior`
   pattern as `scoring_gain`, including the noise floor (`floor_frac`, raised for retrigger/steel).
2. `future_value` uses `measured_joker_power` when a deck is present; tier-only path remains for the
   no-deck/test case so existing fixtures still pass.
3. `joker_contribution` becomes a **direct** leave-one-out measurement (avg_score with vs without
   joker i) instead of a `future_value` delta — cheaper and exact, and it's the quantity the sell
   logic actually wants.
4. Reconcile units so the SELL upgrade comparison (`buy_fv_delta` upgrade vs `worst_c`,
   `shop_advisor.lua:581`) stays coherent after the scale change; re-tune `SA.W_FV` only if a
   directional test demands it.

**Risk.** This touches the common currency that ALL shop tests lean on. Sequence: land 0a/0b, then
migrate `future_value` behind a deck-present guard, run `lua tests/runner.lua` after each step.

**Tests.**
- Hearts-heavy deck + low-tier Lusty vs high-tier off-suit joker → sell picks the off-suit dud, NOT
  Lusty (the headline bug).
- No-deck state → behaviour unchanged from tier path (existing fixtures green).
- Scaling joker still projected (sell less eager early).

---

## Phase 2 — Vouchers: static table → situational functions (`engine/vouchers.lua`)

Convert `entry(name, value, …)` constants into `val(gs)` closures (mirror `tags.lua`'s shape), with
the current number as the **base prior** plus a measured situational term. Priorities:

- **Observatory / Telescope** — drive off `ConsumableValue.best_planet(gs)` / `hand_frequencies`.
  Observatory (×1.5 planet mult) scales with planet investment + most-played-hand frequency; near-zero
  on a non-planet build. Telescope's value rises with how concentrated your played hands are.
- **Antimatter (+1 joker slot)** — value ≈ `Packs.expected_shop_joker(gs, …)` (the marginal joker the
  slot lets you hold), converted FV→ via `value_units`. Replace flat `8.0`.
- **Grabber / Nacho Tong (+1 hand)** — worth ≈ one extra `JokerValue.avg_score` per round, scaled by
  stance (much more when `situation()` is at-risk). Pass stance/sim through `opts`.
- **Hieroglyph / Petroglyph (−1 ante)** — model the ante skip explicitly (large; currently a flat 4).
- **Hand-size / discard vouchers (Paint Brush, Palette, Wasteful, Recyclomancy)** — tie to measured
  hand improvement (re-measure `avg_score` with `hand_size`/discards bumped) rather than flat 3.0.

Keep flat values for the genuinely structural ones (Overstock, Clearance) as priors.
**Signature change:** `V.value(gs, key)` may need `opts` (rng/cache/stance) — thread it from
`shop_advisor`'s BUY_VOUCHER loop (`:469`).

**Tests:** Observatory > flat-prior on a planet-frequent deck and ≈ prior on a non-planet deck;
Antimatter tracks expected_shop_joker (higher when shop pool measures strong).

---

## Phase 3 — Skip tags: static dollars → situational (`engine/tags.lua`)

Convert flat `function() return N end` to real `val(gs, opts)`:
- **tag_orbital (+3 hand levels)** → `best_planet` `level_gain × 3` for your deck, converted to
  dollars via `value_units`. (This is the clearest static-vs-measured gap in the file.)
- **tag_buffoon / charm / meteor / ethereal (mega packs)** → reuse `Packs.value` of the corresponding
  **mega** pack (the machinery already measures these), converted frac→dollars.
- **Joker tags (uncommon/rare/foil/holo/polychrome/negative)** → `expected_shop_joker` (a free joker's
  worth), plus the edition bonus, converted to dollars.
- **tag_double** → 2 × the best *other* available tag's value (needs the candidate tag list passed in).

This surfaces the **cross-currency** need from Phase 0a (tags are valued in dollars but the underlying
worth is scoring) — do Phase 0a first. Thread `opts` (rng/cache) from `skip_advisor` into
`Tags.value`.
**Tests:** Orbital worth more when your best-played hand is high-frequency; Buffoon tag tracks a
measured mega-buffoon pack; flat fallback for unknown tags preserved.

---

## Phase 4 — Pack content pools: static tables → measured (`engine/packs.lua`)

- **Tarot pool** (`TAROT_BASE`, `:149`) — for enhancement/suit tarots, route through
  `Tarot.shop_value` (the SAME measured path `consumable_value.card_value` already uses for shop
  standalones). Eliminates the "measured in shop, static in pack" inconsistency.
- **Spectral pool** (`SPECTRAL_BASE`, `:172`) — measure the measurable ones: **Black Hole** (+1 all
  hand levels) = Σ `level_gain` over hands you actually play; **Ankh/Hex** (copy a joker) = value of
  your best joker. Keep static priors for genuinely un-modelable ones (Soul = random Legendary).
- **Standard card pool** (`card_pool`, `:188`) — replace the flat `{plain, enhanced, edition, seal}`
  weights with `ConsumableValue.card_add_value` on representative sampled cards so the value is
  deck-bloat-aware (a flush deck values a same-suit enhanced card differently from a rainbow deck).
- **De-dup:** `TAROT_BASE`/`SPECTRAL_BASE` are duplicated in `packs.lua` AND `consumable_value.lua`.
  Move the prior tables to ONE module (extend `engine/mechanics.lua` or a new `consumable_data.lua`)
  and have both require it. Single source of truth.

**Tests:** standard-pack value differs between a focused and a diluted deck; Black Hole pack value
rises with more played hand types; tarot-in-pack value matches tarot-in-shop value for the same card.

---

## Phase 5 — Joker econ: deck-aware where conditional

`Eval.econ_power` (`eval_function.lua:85`) and `SA.estimate_blind_income` (`shop_advisor.lua:267`)
sum a static `econ` $/round per joker. Several econ jokers are conditional on deck/play:
**Rough Gem** ($/diamond played), **Bloodstone**, **Business Card** (chance on face cards), etc.

Add `JokerData`/eval helper `econ_value(gs, key)` that scales conditional econ by the already-computed
`deck_profile` (suit/face ratios × expected cards played per hand). Unconditional econ (Golden Joker,
Rocket) keeps its flat number as the value. Both call sites use the helper.
**Tests:** Rough Gem's econ on a diamond-heavy deck > on a diamond-poor deck; Golden Joker unchanged.

---

## Phase 6 — Minor fallbacks & denominators

- `consumable_value.card_value` Planet branch assumes **freq 0.4** when frequencies are missing
  (`:152`). Compute frequencies if a deck exists; keep 0.4 only as the true no-deck fallback.
- `Mechanics.boss_per_hand_need` falls back to **base_hands = 4** (`:92`) — *everything* divides by
  this. Prefer the live `gs.run`/voucher-adjusted hand count where available; document the fallback.
- Audit `eval_function.edition_score_bonus` flat foil/holo/poly priors (`:153`): fine on the measured
  path (editions are applied in `hand_eval`), but the prior path's flat poly `0.40` should ideally
  scale with the joker's own measured contribution. Low priority — note only.

---

## Sequencing & verification

1. **Phase 0a + 0b** (infra) — land + test in isolation; no behaviour change expected, all existing
   tests stay green.
2. **Phase 1** (sell/run-strength) — highest impact, riskiest currency change. Migrate behind a
   deck-present guard; run the full suite after each sub-step.
3. **Phase 4 de-dup** (single source for tarot/spectral priors) — cheap, unblocks 2/3 cleanly.
4. **Phase 2, 3, 4, 5** — independent consumer migrations; can be done in any order, one PR each,
   each with its directional test.
5. **Phase 6** — cleanup pass.

**After every phase:** `lua tests/runner.lua` (via Bash) must stay fully green — see the
`dev-environment` memory. Add the new directional tests to the existing files
(`tests/test_shop.lua`, `tests/test_advisors.lua`, `tests/test_deck_plan.lua`, etc.); add a
`tests/test_value_units.lua` for Phase 0.

**Performance gate.** Phase 1's leave-one-out and the Phase 2/3 voucher/tag measurements add Monte
Carlo to the shop tick. Before/after, time a representative `SA.recommend` on a full board + full
shop; if it regresses materially, lower sample counts, lean harder on the Phase-0b cache, or gate the
measurement (e.g. only leave-one-out when a SELL is actually a contender). The whole engine is
headless-testable, so benchmark in the runner.

**In-game `VERIFY` fields.** Several inputs these fixes consume are flagged `-- VERIFY` in code
(eternal/perishable/rental flags, `gs.run.consumable_slots`, boss keys, planet/hand-level live
values). Confirm against live `G` before trusting a fix that depends on them; degrade gracefully to
the prior when a field is nil (existing pattern). Green headless tests ≠ works in-game — see the
`deploy-and-ingame-loader` memory; re-sync to the Mods folder and spot-check.

## Definition of done — ✅ MET (2026-06-24, 454 tests passing)

- [x] No primary valuation resolves to a static catalogue number when a deck is present and the item is
  modelable; statics survive only as guarded fallbacks/priors.
- [x] `DOLLAR_FRAC` literal is gone; all $↔scoring↔FV conversion lives in `value_units` and is ante-aware.
- [x] `TAROT_BASE`/`SPECTRAL_BASE` exist in exactly one module (`consumable_value`).
- [x] Sell ranking, run-strength, vouchers, tags, pack contents, and joker econ all consult the measured
  path. Each has a directional test proving deck-awareness. Full suite green; shop tick within budget
  (typical shop ~250 ms; Arcana-pack shop ~400 ms one-time; live play/discard tick unaffected).

### Intentionally left as priors (modeling limits, not omissions — rationale in code)
- Joker-rarity skip tags (`uncommon`/`rare`/`negative`) + edition tags (`foil`/`holo`/`polychrome`):
  a single *random* joker isn't well-modelled by `expected_shop_joker` (best-of-N).
- `tag_double`: the next tag it copies isn't in game state.
- Spectral `Ankh`/`Hex`: they destroy your other jokers, so "value = your best joker" would be wrong.
- `Eval.edition_score_bonus` flat poly/holo prior: only the no-deck path; measured path is exact.

### Not yet verified in-game
All changes are headless-test-green, but several inputs are `-- VERIFY` fields (live hand counts,
boss keys, sticker flags). Re-sync to the Mods folder and spot-check shop/skip recommendations on a
real run; degrade-to-prior paths mean wrong fields fail safe, not loud.
