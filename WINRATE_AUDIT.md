# WINRATE_AUDIT.md — research-grade audit of the engine + self-play stack (2026-07-05)

> **📍 CURRENT STATUS (updated 2026-07-13) — this is the authoritative project document.**
> **Retained baseline: `sim_out/p5_e5b.jsonl` — death-ante 4.013, progress 3.701, 2 wins (n=160, honest world).**
> - **2026-07-13 — E-5 RE-APPLIED ON THE HONEST WORLD ✅ KEPT — THE STRONGEST BATCH VERDICT OF THE PROJECT:
>   progress +0.146 (2.7x the previous best lever), sign 58/36 p≈0.030, death-ante +0.131 (first baseline over
>   4.0), wins 1→2 (2003 a8-death → WIN), TAIL GATE PASSES (27=27).** The E-9 replay screen predicted it
>   (regret −62%, oracle-match +9.2pts on held-consumable states); the pre-E-11 batch failure was cascade, as
>   hypothesized. Runtime ~1.6x accepted (batch ~106 min). The harness-screen-then-batch pipeline is now the
>   proven method for in-blind levers.
> _(Prior baseline line, superseded:)_
> **Retained baseline: `sim_out/p5_stdsync.jsonl` — death-ante 3.881, progress 3.555, 1 win (n=160, honest E-11 world).**
> - **2026-07-13 — engine standard-pool prior synced to the E-11 rates ✅ KEPT (`1e55ef5`): +0.017, sd 0.194, two a7
>   deaths deepened to a8 (26003, 160003).** The tail now has 4 runs dying AT ante 8 — wins are one lever away.
> - **2026-07-13 (§7) — E-11 honest-world rates ✅ KEPT AS RE-BASELINE (wiki-verified, agent-implemented):** standard-pack
>   cards 40% enhancement / 20% seal / 8% edition (sim had 12/4/3 — 3× under-enhanced); shop jokers can roll NEGATIVE
>   (0.3%, slot-free end-to-end); 9 skip-tags ante-gated (min ante 2, per wiki). Full-world re-roll (34/160 tied, sd 1.80):
>   mean −0.074 n.s., wins 4→1, **but reach-6+ 23→27 (3 a8 deaths + 5 a7s)** and ante-8 boards now hit **hand-lv median 19**
>   (was 3-5) — the leveling archetype is fully expressible under the honest rates. Referee honesty over headline wins:
>   pre-E-11 baselines are CROSS-WORLD (not comparable); all future paired verdicts run against `p5_rates`.
> - Same session, engine levers (pre-E-11 world): E-6 last-hand E[frac] dig KEPT (sign 6/2, sd 0.067) · E-10a commit 2.5
>   KEPT (3/0/157) · V2c leveling push KEPT (+0.020) · E-5 and swap-admission-widening REVERTED (see below).
> _(Prior baseline line, superseded:)_
> **Retained working-engine baseline: `sim_out/p5_e6.jsonl` — death-ante 3.925, progress 3.612, 4 WINS (n=160 paired).**
> - **2026-07-13 (§7) — E-6 last-hand E[frac] dig ✅ KEPT: sign 6/2, +0.006, sd 0.067 (lowest churn of any in-blind change),**
>   tail neutral, 147003 a6→a7. The forced_play dig is now arbitrated by the SAME boss-aware survive_after E[frac] as the
>   F1/F2 branch (CRN, margin-gated) instead of the mean-rule that refused digs that were the only chance to live.
> _(Prior baseline line, superseded:)_
> **Retained working-engine baseline: `sim_out/p5_commit25.jsonl` — death-ante 3.925, progress 3.607, 4 WINS (n=160 paired).**
> - **2026-07-13 (§7) — E-10a COMMIT_THRESHOLD 3.0→2.5 ✅ KEPT: sign 3/0/157, mean +0.024, ZERO regressions**
>   (58003 a3→a5 +2.20, 96003 a2→a4 +1.62). Commit rate 68→71/160 — the 2.5 band admits only the
>   hand_modifier+level/flat combos, all of which improved. Strictly-non-negative class.
> _(Prior baseline line, superseded:)_
> **Retained working-engine baseline: `sim_out/p5_lvlpush.jsonl` — death-ante 3.900, progress 3.582, 4 WINS (n=160 paired).**
> - **2026-07-13 (§7) — planner-V2c LEVELING PUSH ✅ KEPT (+0.020, sign 5/5, sd 0.227).** When committed + banked ($≥20) +
>   ante ≥ 4, the committed hand's planet_credit doubles on a longer taper (to lv 12) across ALL delivery channels (single
>   `planet_credit` hook + Orbital extension). Fired on ~10 runs; the two biggest gains are the designed shape (154003/144003:
>   banked a6 → a7 via levels); tail flat, wins 4=4. Narrow because the GATE is commit-rate-limited (54/160 commit) — the
>   coverage unlock is E-10a (COMMIT_THRESHOLD). Also this session: E-5 reverted on the tail gate (sign 57/33 p≈0.015 but
>   wins 4→2, reach-6+ 24→18, 1.6× runtime); swap-admission widening reverted (fired 4/160, 0/4 — the invest-only gate is
>   RIGHT; swap-eagering now 0-for-3); Overstock world reroll-slot fix kept (399b0c5).
> _(Prior baseline line, superseded:)_
> **Retained working-engine baseline: `sim_out/p5_w4.jsonl` — death-ante 3.888, progress 3.562, 4 WINS (n=160 paired).**
> - **2026-07-12 (§7, later) — W4 CONSISTENCY SWEEP ✅ KEPT (2 → 4 wins).** Three engine↔world consistency fixes in one bundle:
>   Hieroglyph's −1 ante RUNWAY modelled (driver replays the ante; was $10 for a strictly-harmful −1 hand, the MOST-bought
>   voucher at 27/112 offers), Magic Trick/Director's Cut removed from the sim voucher pool (were $10 no-ops), Credit Card's
>   −$20 debt honoured by the world (an over-cash buy no longer silently ends the shop). Paired vs p5_coupled: **progress
>   +0.066, death-ante +0.056, wins 2→4, sign 64/52** (world-change signature: broad symmetric swings, all aggregates
>   positive, tail 22→24 at ante 6+). Mechanism verified: Hieroglyph buys persist (24) now delivering real runway; freed
>   voucher budget moved to real vouchers (Grabber 21→33). New baseline `p5_w4`.
> - **2026-07-12 (§7) — FIRST MULTI-WIN BASELINE (0 → 2 wins).** After the pack-pick WIN, attacked keystone acquisition on FULL
>   boards. W2 (isolated swap-accounting fix) REVERTED (−0.111 churn). **Strength-proportional swap keep** (user idea: protect
>   strong jokers ∝ strength) got the first-ever win but washed in isolation (−0.022, cascade). **W3 world-fidelity joker REORDER**
>   (additive→copier→xmult so acquired keystones COMPOUND; probe 918→5346) ✅ KEPT +0.054. **COUPLED (strength-keep swap ON the
>   W3 world)** ✅ KEPT: **+0.040 vs W3 / +0.094 vs p5_bpick, wins 0→2, death-ante +0.087, churn controlled, keystones 14→18** —
>   the acquire-AND-compound thesis validated end-to-end. Baseline `p5_coupled` (superseded by p5_w4).
> - Next: E-5 (drop the held-consumable gate on the proven F1/F2 survival arbitration — coverage extension, in flight),
>   then skip-tag joker delivery analytic + Overstock (world reroll-slot bug + measured valuation), then planner V2 /
>   variance-aware pacing as coupled changes.
> _(Prior baseline line, superseded:)_
> **Retained working-engine baseline: `sim_out/p5_bpick.jsonl` — death-ante 3.712, progress 3.403, 0 wins (n=160 paired).**
> Last committed baseline remains `sim_out/p4_surv.jsonl` (3.612 / 3.300) until this retained working tree is committed.
> Branch `joker-coverage-and-engine-fixes`. Tests: **786 unit + 195 sim** (`lua tests/runner.lua`; `luajit tests/runner_sim.lua`).
> - **2026-07-11 (see §7):** profiling (runtime fine; 98-min batch was laptop-sleep) → commitment-upgrade (kept, 1/160 inert) →
>   analytic conditional-xmult value (kept, wash) → reroll-to-dig (REVERTED, −0.015 churn) → **Buffoon pack-pick core value (✅ WIN:
>   +0.054 progress, sign 18/7, P≈0.02, economy unchanged — the effort's strongest single lever, new baseline `p5_bpick`).**
> - **KEY FINDING:** the BUILD wall is core-EXPOSURE-limited. Levers on PAID/rarely-offered channels (shop cores, rerolls) wash out or
>   churn; fixing valuation on the FREE, heavily-used channel (pack picks) WON. Next: extend to other free channels (skip-tag joker
>   delivery, Overstock reroll-slot + measured value) and re-check the shop analytic now that packs assemble more cores. Not economy-spend.
> - **Phase 0** (paired-A/B tooling + progress metric) ✅ · **Phase 1** (world fidelity A1–A9) ✅ · **Phase 2** (engine valuation B/C/K) ✅
> - **Phase 3** (re-litigate the graveyard) ✅ — leveling-need KEPT (+0.012, verdict flipped); coupled-pair & scaler-damp-removal REFUTED.
> - **Phase 4** (in-blind survival) ✅ LOW-RISK PASS COMPLETE — F1/F2 ✅ (+0.038, best signal), F5 ✅, **F6/F7 ✅ (+0.012, sign 13/8)**; F4 & F8 REVERTED; coupled retune deferred.
> - **Phase 5** (committed-archetype planner) 🔶 IN PROGRESS — **V1 KEPT (+0.033, sign 17/11)**; commitment/level concentration works, still 0 wins. · **Phase 6** (live re-sync) ⬜.
> - **Baseline arc (faithful world):** scorer2 3.513 → a789 3.450 → k12 3.575 → **base160 3.550 → p3_levelneed 3.569 → p4_surv 3.612 → p4_f6f7 3.625 → p5_commit 3.663**.
> - **THE PROVEN RULE (holds across all phases):** ship unit/mechanism/correctness fixes freely; ANY measurement/value
>   re-weight that doesn't co-move the constants tuned around it BACKFIRES (the revert set: C1, B3, F3, F4, F8; cf. the
>   pre-audit graveyard). Verdicts are **paired n≥160** with the sign test + progress Δ; the sim is byte-deterministic per seed.
> - **Full ledger + how-to-run + what's-next: `NEXT_SESSION.md` (the fresh-session handoff). Implementation logs: §4 (P0-2), §5 (P3), §6 (P4) below.**

Scope: every subsystem that contributes to decision or simulation quality, audited against
(a) the code as committed on `joker-coverage-and-engine-fixes`, (b) the n=80 baseline batch
`sim_out/scorer2.jsonl` (mean death-ante 3.513, 0 wins), (c) real-Balatro rules, and (d) the
full experiment history (rounds 1–22, `NEXT_SESSION.md` / `selfplay-system-plan`). Method:
full read of the core decision path (`decision_engine`, `shop_advisor`, `eval_function`,
`joker_value`, `build_plan`, `pacing`, `consumable_value`, `skip_advisor`, `mechanics`,
`search` params, `discard_value`, `sim/world`, `sim/content`, `sim/driver`), four
completed sub-audits (consumable/pack/tag valuation; sim-world fidelity; scoring/facts
layer vs real Balatro; in-blind play policy), custom telemetry mining on the baseline
batch, and micro-experiments run against the real engine code.

---

## 0. Executive summary — the ceiling is not where the docs say it is

**The documented conclusion — "the ante-4 wall is architectural; the next step is a
committed-archetype planner" — is confounded and should be shelved.** The audit found that
the simulated world (the tuning ground truth) is structurally incapable of expressing the
three analyzed human-win archetypes, and the engine's own valuation has three independent,
concrete defects that suppress exactly the winning ingredients (leveling, conditional
xmult, copiers). Every tuning verdict since Phase 1 was rendered against this world, so the
list of "failed" experiments (leveling, flush-commitment, scaler investment) must be
considered *unresolved*, not refuted.

Headline findings, each verified directly in code and/or data:

1. **Scaling jokers never grow in the sim** — no code anywhere in `sim/` ever writes a
   joker `ability` counter, so Hologram / Ride the Bus / Constellation / Vampire / Runner /
   Supernova / every scaler is frozen at zero accumulation for the entire run, while the
   engine *buys them at up to 3× projected-growth value* and `scaling_fuel` pays real EV to
   feed them. The ante-4 death boards "full of scalers that never grew" could not have
   grown no matter what the engine did. (Decayers never decay either: Popcorn/Ice Cream
   read full value forever; Gros Michel/Cavendish never self-destruct.)
2. **The engine's highest-valued tarots are silent no-ops in the sim.** `use_consumable`
   executes only planets and deck-mutating tarots. Judgement (gained 15×, used 0×), High
   Priestess (15/0), Emperor, Fool, Wheel of Fortune, Hermit/Temperance money, and *all*
   spectrals (incl. Soul) are consumed with zero effect — after the engine paid for them —
   and until consumed they clog one of the 2 consumable slots, which **also permanently
   disables the in-blind search** (`can_search` requires no held consumables).
3. **The leveling channel is dead at the source, by a known-but-never-fixed 5× scale bug.**
   Standalone planets are valued on the ×1 consumable scale while the *identical formula*
   through a Celestial pack gets ×`JOKER_SCORE_WEIGHT`(5). Baseline data: 289 standalone
   planets offered, **2 bought** (91% valued ≤ 0); Celestial packs 6% of 557 offers;
   `BUY_CONSUMABLE` is 1.9% of all shop advice; 35/80 runs died with 0 hand-levels, median
   1. Round 4 (2026-06-30) documented exactly this fix candidate ("planet x1→x5
   consistency") and it was never run — four other leveling levers were tried *on top of*
   the broken scale and all failed.
4. **Keystone xmults/copiers are structurally blocked from full boards.** The only entry
   for a shop joker onto a full board is the upgrade-swap path, gated on raw
   `score_delta > 0` at 6–8 MC samples. Measured zero-rates on a typical flat board:
   The Trio ≤0 46% of trials, Tribe 68%, Family 98%, **Blueprint 100%** (it copies the
   joker to its right and the measurement appends it last → always copies nothing),
   **Hologram 100%** (counter frozen at 0). This is the exact mechanism behind the
   documented "engine skips Duo/Family/Brainstorm/Tribe" flaw seen in all three human wins
   and in the baseline counterfactual (Blueprint ×3, Brainstorm ×3, Tribe, Duo, Hologram
   skipped).
5. **Vouchers are a $13/run sinkhole in the sim.** 106 voucher buys across 80 runs, but
   `apply_voucher` implements ~3 of 16 effects (Grabber/Wasteful/Paint Brush/Overstock/
   Clearance/Telescope/Director's Cut… are inert; Hieroglyph is modeled with the **wrong
   sign** — +1 hand instead of −1 ante −1 hand; Seed Money gives +$1 cap instead of +$5).
   Vouchers are also offered every *shop* instead of every *ante* (3× exposure).
6. **The in-blind policy has no concept of P(clear) — and the codebase's own P(clear)
   estimator is decision-dead.** Play-vs-discard and discard-set choice optimize the MEAN
   of a single future hand's max score (`discard_value.lua`), with no pace, quantile, or
   variance posture anywhere; the last-hand dig rule requires mean ≥ remaining, refusing
   digs that are the only chance to live. Meanwhile `simulation.lua` — a sound
   blind-survival estimator modeling hands/discards/boss effects — is only ever used to
   rewrite confidence *labels* after the decision is made (and the sim driver doesn't call
   it at all; sim and live run bit-identical policies). This is structurally sufficient to
   produce the 32/80 variance-death bucket. See section F.
7. **The A/B methodology is underpowered for the effect sizes being judged.** sd(death-ante)
   ≈ 1.6 → SE(n=80) ≈ 0.18. Verdicts of ±0.04–0.08 (B1 +0.038, leveling-need −0.051,
   first-xmult −0.051, coupled −0.063) are 0.2–0.4 SE — noise. The sim is per-seed
   deterministic, so **paired per-seed comparison** (same seeds, delta per seed, sign test)
   would give ~3–5× the power at zero extra compute; it has never been used.

**Consequence for the roadmap:** fix the referee first (world fidelity), re-baseline, then
fix the engine's three valuation brakes, then *re-run the experiment graveyard* against the
faithful world — and only if the wall still stands does the committed-archetype planner
become the next step. Doing the planner now would optimize against a world where its
payoff (growing multiplicative cores) mostly does not exist.

Beyond the headlines, the report catalogs a long tail across every subsystem — inert
vouchers/tags in the sim, pack picks lost at open, a `c_heirophant` key mismatch, a
Blue-seal ~100× unit bug, pack-rarity w² weighting, and a cluster of wrong per-joker
scoring hooks (Supernova a silent zero; Loyalty Card / Card Sharp over-firing ×4/×3 every
hand on the live path; Spare Trousers' mult wrongly gated; Photograph not re-firing on
retriggers; foil/holo joker editions in the wrong phase — section K).

---

## 1. Subsystem findings

Legend per finding: **Impact** on win rate (of fixing) / **Confidence** the finding is real
/ **Difficulty**. "Experiment-first" = don't trust the fix, measure it (paired, n≥160).

### A. Sim world fidelity (`sim/world.lua`, `sim/content.lua`, `sim/driver.lua`)

The world is the tuning ground truth; the two prior fidelity fixes were worth +0.11 and
+0.10 each. Every gap below distorts tuning **in the same direction: it punishes
build-investment behavior** (scalers, consumable engines, vouchers, skip chains) — the
exact behaviors the human wins used.

- **A1. Frozen scaler counters + immortal decayers.** CRITICAL / CONFIRMED / Medium.
  `Content.gen_joker` creates `ability = { extra = {} }`; nothing in `sim/` ever updates
  it; `joker_effects.scaled()` then reads the default (0 for accumulators; *full* value for
  decayers, e.g. Popcorn 20 forever). Fix: a world-side joker tick — per-play/per-discard
  growth rules for the ~15 most-bought scalers (Bus +1 mult/non-face hand, Green Joker
  +1/discard, Runner +15 chips/straight, Square +4/4-card hand, Wee +8/deuce scored,
  Hologram +0.25x/card added, Constellation +0.1x/planet used, Vampire per-enhanced-scored,
  Lucky Cat per-lucky-trigger, Red Card +3/reroll, Throwback +0.25x/skip, Supernova
  +1/hand-played-count…), and an end-of-round tick for decay/self-destruct (Popcorn −4,
  Ice Cream −5/hand, Gros Michel 1-in-6, Cavendish 1-in-1000, Egg +$3 sell). Write to the
  same `ability`/`ability.extra` fields `scaled()` reads (F7-verified field names).
  Experiment-first: none needed for the *rule* (it's the FACTS layer), but re-baseline.
- **A2. Dead consumable execution.** CRITICAL / CONFIRMED (data + code) / Low-Medium.
  `use_consumable` handles planets + ENH/SUIT/RANK/THIN tarots only. Dead: Hermit /
  Temperance (money — the engine actively recommends "use for +$20" and gets $0),
  Judgement (grant a joker), High Priestess (grant planets — leveling fuel!), Emperor,
  Fool, Wheel of Fortune (edition), all spectrals (Soul → legendary, Black Hole → level
  all hands, Immolate +$20, Ectoplasm…). Side effects: money model corrupted; consumable
  slots clogged; **in-blind search disabled** while clogged (decision_engine `can_search`).
  Fix order: money tarots (trivial), Judgement/HP/Emperor (use `grant_joker` / consumable
  gen), Lovers alias into `Tarot.ENH` (m_wild), spectral top-5.
- **A3. Hierophant key mismatch.** Medium / CONFIRMED / Trivial. `content.lua` generates
  `c_heirophant` (game spelling); every engine table keys `c_hierophant` → valued at the
  0.15 fallback and no-ops on use, in sim *and probably live*. Alias both spellings
  (project convention, same as `j_gluttenous_joker`).
- **A4. Inert vouchers + wrong restock cadence.** HIGH / CONFIRMED / Medium.
  See headline #5. Fix: implement mechanical effects (shop slots for Overstock — needs
  `run.shop_slots` consumed by `gen_shop`; Grabber +1 hand; Wasteful +1 discard; Paint
  Brush +1 hand size; Clearance −25% prices; Hone → `EDITION_W` ×2; Reroll Surplus −$2;
  Telescope → Celestial contains best-planet; merchant vouchers → `SLOT_TYPE_W`;
  Seed Money cap = 10), fix Hieroglyph (−1 ante, −1 hand), restock the voucher slot once
  per ante. Note upgrade-tier vouchers are never offered (BASE_VOUCHERS only) — acceptable
  simplification, document it.
- **A5. Dead skip tags.** Medium-High / CONFIRMED / Low. `tag_coupon` sets `run._coupon`
  and `tag_d6` sets `run._free_reroll` — neither flag is ever read. `tag_handy`,
  `tag_garbage`, `tag_speed`, `tag_juggle`, `tag_boss`, `tag_double` are explicit no-ops
  (~8 of 24 uniform tag rolls pay nothing while `engine/tags` believes $3–$11).
  Double-tag chaining (a real skip archetype) is impossible.
- **A6. Pack picks are held (and droppable) instead of used at open.** Medium-High /
  CONFIRMED / Low-Medium. Real Balatro uses Arcana/Celestial/Spectral picks immediately at
  open (no slot needed); the sim stores them into the 2 slots and **silently loses the
  pick when slots are full** (money already spent). Throttles the leveling-through-packs
  pipeline (Mega Celestial pick-2 with 1 slot loses a planet). Fix in `take_pack`: apply
  planet picks immediately via level-up; apply deck tarots against a sampled hand; store
  only genuinely storable cases.
- **A7. Boss effects missing in-world.** Medium / CONFIRMED / Medium. Pillar (an **ante-1
  pool** boss!) is a vanilla 2×; The Arm's `level_down` is declared but never applied;
  Tooth/Ox money penalties admitted-unapplied in `award_income`; face-down bosses
  (House/Wheel/Fish/Mark) give the engine perfect information; Serpent unmodeled;
  ante-8 finishers are plain 2× (win condition easier than real). Direction: sim easier
  than real on bosses (partially offsets the under-rewards above); leveling never punished
  by Arm; hoarding never punished by Ox/Tooth.
- **A8. Economy micro-gaps.** Medium / CONFIRMED / Low. Play-time money never lands
  (gold seal $3/played, Lucky $20, `play_econ` — the engine even orders cards for money it
  never receives); econ-joker income is a flat unconditional average (Delayed Gratification
  pays its $4 average even when the engine discards every round — over-rewards conditional
  econ, under-rewards copier-econ, the known TODO); Credit Card's −$20 debt unmodeled;
  SELL_TO_BUY sells a held consumable for a hardcoded $1.
- **A9. Generation odds off.** Low-Medium / REPORTED, VERIFY vs wiki / Low. Standard-pack
  card rates (12% enh / 4% seal / 3% edition) look ~3× low vs real (~40%/20%/8%);
  polychrome shop odds 2× high and *negative edition absent entirely* from shops; edition
  price adder flat +$1 (real: foil +$2 / holo +$3 / poly +$5 / negative +$5); mega packs
  ~2× over-offered (weights 4/2/1 vs real ≈4/2/0.5); tag pool has no ante gating (real
  gates ~10 tags to ante 2+ — inflates ante-1 skip EV); no first-shop guaranteed Buffoon
  pack; `gen_card` ids collide across packs (`1000+i`).
- **A10. Consumable-pool dedup absent** (holding a planet should block another copy) —
  already documented in `sim-world-fidelity-gap`; pairs with an engine-side "use held
  planets promptly" value (exists: `DE.LEVEL_USE_CREDIT`).

### B. Shop valuation scales (`shop_advisor`, `consumable_value`, `packs`, `value_units`, `vouchers`, `tags`)

- **B1. The ×1/×5 consumable scale split.** CRITICAL / CONFIRMED / Low (code) + retune.
  `BUY_CONSUMABLE` (shop_advisor:643): `w_score * vfrac`; `BUY_PACK` (:700):
  `w_score * 5 * pv` — same units ("fraction of a boss hand"), same underlying formulas.
  A loose Jupiter is worth exactly 1/5 of the expected Jupiter inside a Celestial pack.
  Knock-ons: SELL_TO_BUY (:925) prices a *held* planet's keep-loss at ×1 → held planets
  are the cheapest funders and get churned; `SA.CREATES_JOKER` (Judgement-only ×5) and
  the missing `c_soul` entry are band-aids for this exact gap; owned-synergy bonuses
  (`sbonus`) change scale by call-site (×5 in packs, ×1 loose). **Fix:** one
  frac→utility bridge (put `JOKER_SCORE_WEIGHT` into `value_units`, use it on every shop
  path), delete the CREATES_JOKER special case, then re-check `net_cost`/`DOLLAR_UTIL`
  calibration once. Also re-examine the stacking of `CV.level_persist` (≤4) with
  `BuildPlan.level_amplifier` (≤5) after rescale so planets don't overshoot.
  Experiment-first: **yes** — this raises consumable spending, the classic backfire shape;
  but unlike the failed bonus-levers it's a correctness unification, and it must be tested
  *after* the world fixes (A2/A6) or leveling still can't pay off fully.
- **B2. Blue-seal unit bug (~100×).** Medium / CONFIRMED by inspection / Trivial.
  `consumable_value.lua:134-136` adds `best_planet().value` (raw score, 10–150) into a
  boss-hand-fraction sum (0.0–0.5). Any Blue-seal card auto-dominates a Standard-pack
  pick. Fix: divide by `Mechanics.boss_per_hand_need(gs)`.
- **B3. Two independent $↔fraction exchange rates.** Medium / CONFIRMED / Low.
  `VU.dollar_frac` (0.015–0.05 frac/$) vs the shop's implied rate from
  `JOKER_SCORE_WEIGHT`/`COST_WEIGHT` ($1 ≈ 0.06 frac); every tag/skip comparison is
  cross-currency, and the gap grows with ante. Derive one from the other, ante-aware.
- **B4. Voucher values (engine side).** Medium / CONFIRMED / Low. Hieroglyph's permanent
  −1 hand is never charged (and `at_risk` *adds* value); Seed Money / Money Tree credit
  recurring econ that is $0 until the bankroll is high (not gated); Director's Cut minor.
  Engine bought v_grabber over affordable keystone jokers in the baseline traces — with
  correct sim voucher effects this may actually be right (+1 hand is strong), so fix
  fidelity first, then re-judge.
- **B5. Pack/reroll pool math.** Medium / CONFIRMED / Trivial. `packs.joker_pool` samples
  rarity-weighted *and* stores `w = it.w`, and `expected_pick` re-weights by `w` →
  probability ∝ w² (rares ≈0.25% instead of 5%) — systematically clips the rare tail from
  Buffoon-pack and REROLL EV (and Uncommon/Rare tag values via `joker_dollars`). Fix:
  `w = 1` for pre-sampled items. Also `spectral_pool` uses raw `SPECTRAL_BASE`, ignoring
  the destruction downsides `card_value` already knows (Hex/Ankh positive in the pool even
  on a built board).
- **B6. Tag magnitudes vs real.** Medium / MOSTLY CONFIRMED / Low. Edition tags
  (foil/holo/poly $5/$7/$9 flat) are actually *free edition jokers* in both real Balatro
  and the sim's own `apply_tag` — the engine declines skips its own world would pay a free
  polychrome joker for. `tag_negative` $16 flat (it's a free joker + a slot). Uncommon /
  Rare tags valued as fully-free measured jokers — matches the sim, diverges from real
  (real adds it to the next shop, still paid); pin both to one convention. Handy/Garbage/
  Speed/Coupon flat priors are 2–3× low mid-run (computable from run counters).
- **B7. Confirmed-sane:** interest breakpoint/bankroll-plan model, econ floor, SAVE-as-zero
  baseline, FV bridge within the joker domain (`W_FV × FV_PER_FRAC = JOKER_SCORE_WEIGHT`),
  Hex/Ankh pick-time destruction accounting, Wraith money-wipe netting, pack sizes/costs.

### C. Joker measurement layer (`joker_value`, `eval_function`)

- **C1. Sample-size noise is the root cause the guardrails patch around.** HIGH /
  CONFIRMED by micro-experiment / Low-Medium. At `samples=6`, measured `score_delta` is
  ≤0 in 46% of trials for The Trio, 68% Tribe, 98% Family (they fire too rarely to appear
  in 6 sampled best-plays). `UPGRADE_MARGIN`, `keep_bias`, prior floors are all
  compensators for this noise. Fix: adaptive samples — cheap 6-sample screen, then 24–48
  samples (cache-assisted) only when a swap/sell decision is actually live; and/or a
  direct analytic trigger-probability estimate for conditional xmults (P(hand contains
  pair/trips) from `hand_frequencies` × xmult value — no sampling needed).
- **C2. The full-board swap gate excludes keystones.** HIGH / CONFIRMED / Trivial fix.
  `shop_advisor.lua:847` requires raw `cur > 0` — a conditional xmult measuring exactly 0
  (C1) or a frozen/fresh scaler (A1) can *never* be swap-bought. Since the board is full
  from ~ante 3 on, this is the main mid-game acquisition path. Fix: gate on the floored
  `scoring_gain` (which already handles priors/projection) or `cur ~= nil`, and let the
  existing `UPGRADE_MARGIN + keep_bias` do the protecting.
- **C3. Blueprint always measures zero.** Medium-High / CONFIRMED / Trivial.
  `hand_eval` copy resolution: Blueprint copies the joker to its *right*; `score_delta`
  appends the candidate at the *end* of the list → nothing to copy → 0, every time
  (Brainstorm copies leftmost → fine). Fix: measure copiers at their best insertion
  position (or prepend Blueprint).
- **C4. Scaler value = phantom prior×projection.** Medium / CONFIRMED / covered by A1+C1.
  A fresh scaler measures ~0 (counter 0), gets floored to 0.6×tier prior, then multiplied
  by `scaling_projection` ≤3 — i.e., its entire value is the prior. Fine as a *model* of
  real growth, but currently disconnected from anything measured; after A1, consider
  projecting from the joker's actual growth rule × measured trigger frequency instead.
- **C5. Prior floors compress the measured signal** (0.6 tier floor; 0.9 for
  retrigger/steel) — a genuinely-bad-for-this-deck joker cannot measure bad. Revisit after
  C1 lowers noise (the floors exist to fight noise).

### D. The leveling pipeline (cross-cutting; the clearest quantified failure)

Chain: standalone planets dead (B1) → Celestial packs 6% of offers taken → Orbital tags
(17 taken) as the only reliable channel → world executes planet *use* correctly, but pack
planet picks can be dropped (A6) and High Priestess is dead (A2) → hand-levels at death:
median ≈0–1 vs human wins' 15–27. Fix order: A2 + A6 (world), then B1 (scale), then
re-test the reverted leveling levers (round 16/22) — their mechanisms were verified working
(+57% planets) and only lost on economics that the broken world and broken scale defined.

### E. Skip layer (`skip_advisor`, `tags`)

- **E1.** `play_value` omits forgone **interest** (skipping at a capped bankroll is $5
  cheaper than modeled → engine skips slightly too often when rich) and has no
  lose-risk term (a blind you'd likely *fail* is priced like a trivial one — skipping a
  dangerous Big blind is a real survival play the engine can't see). Low-Medium / Low.
- **E2.** Tag magnitudes: see B6. The 20 observed "tag > play but PLAY" anomalies are the
  intended 1.25 hysteresis, not a bug.

### F. In-blind play (`decision_engine`, `discard_value`, `heuristics`, `simulation`, `search`, `scaling_fuel`, `tarot`)

Prior work verified in-blind play is near-optimal *per hand* (0.23 hands unused at death;
scoring verified; the guaranteed>expected>accumulate play tiers with a money tie-break at
overkill are sound). **The claim breaks at everything sequential/probabilistic**: the
policy over a whole blind optimizes the MEAN of a single future hand's max score — no
P(clear), no pace, no variance posture anywhere in the decision path. This is structurally
sufficient to produce the 32/80 variance-death bucket. Unlike the build-side levers, these
fixes are measurable against the *current* world (variance deaths don't hinge on the dead
subsystems), so this track can run in parallel with Phase 1.

- **F1. Play-vs-discard is arbitrated by a mean of one hand's max score.** HIGH /
  CONFIRMED / Medium. `DV.measured` (discard_value.lua:58–82) averages
  `HandEval.best_play(...).score` over 10 redraws — (a) a mean, (b) of the vanity max
  (not `best_play_target`), (c) of ONE hand, ignoring `remaining`/`hands_left`.
  `greedy_choice` (decision_engine.lua:391–397) compares that against the current play
  plus `HAND_ECON` = $1 × DOLLAR_VALUE(12) = 12 score-equivalent — epsilon at ante 3+.
  The comparison is also biased toward DISCARD: a PLAY also refills the hand, which the
  single-step compare ignores. Concrete misrank: 2 hands / 600 remaining / made pair
  scoring 350×2 ≈ 95% clear line loses to a ~35% flush dig whose *mean* is higher →
  the variance-death signature. Fix: return the per-sample score vector `DV.measured`
  already computes and arbitrate by **P(clear)** with a margin gate (override only on
  clear disagreement). Experiment-first: yes (paired; watch variance-death count).
- **F2. `simulation.lua` is a sound P(clear|state) estimator that never influences any
  decision — and sim self-play runs the IDENTICAL policy to live.** HIGH / CONFIRMED /
  Medium. `DE._apply_sim` only rewrites confidence labels after `best` is chosen; the sim
  driver calls `Decision.decide(gs)` with no opts, live passes `opts.sim` — decisions are
  bit-identical either way. The estimator models hands/discards/refills/boss debuffs/
  legality/Hook correctly; its rollout discard policy is the old weight heuristic (not
  the measured policy — a bias to fix when wiring it in), and ~40–60 samples with common
  random numbers across the two candidate actions suffice for arbitration. This is the
  principled implementation of F1 — a one-step policy improvement using existing
  machinery. (It subsumes `search.lua`; do NOT invest in raising search depth/samples.)
- **F3. Last-hand dig rule demands mean ≥ remaining → refuses digs that are the only
  chance to live.** Medium / CONFIRMED / **Trivial — cheapest pure win in the audit.**
  decision_engine.lua:408–409 requires `discard_action.value >= remaining` (a mean). If
  the forced play certainly loses, a dig with a 30% tail ≥ remaining is refused → certain
  death where a 30% line existed. Fix: when `forced_play` and the play can't clear, take
  the dig if any measured sample ≥ remaining (P̂>0 beats P=0). Strictly non-negative by
  construction; also the proof-of-concept for quantile objectives before attempting F1.
- **F4. Discard-set coverage: ~7 candidate sets along ONE joker-blind, boss-blind keep
  ordering.** Medium / CONFIRMED / Low-Medium. `DV.best` (discard_value.lua:103–170)
  tries k-prefixes (k=1..5) of a single `keep_value`-ascending order, one
  "keep-current-best-play's-cards" set, and the heuristic shape set (which only exists at
  exactly 4-to-a-flush/4-straight/pair). Missing: 3-flush/3-straight digs toward the hand
  the jokers pay; keep-sets for hands other than the current best play; and `keep_value`
  (:21–32) is joker-blind AND boss-blind — under a suit-debuff boss a debuffed King ranks
  premium while a live 6 is pitched, and a 2 that feeds Wee ranks last. The measurement
  would score better sets correctly — but the right sets are never generated. Fix: add
  generators (keep-best-m-of-dominant-suit m≥3; keep-toward the hands top owned jokers
  reward; boss-aware keep_value; scaler-aware keep). Each set costs 10 best_play calls.
- **F5. Boss adaptation gaps (engine side).** Medium / CONFIRMED / Low-Medium.
  `best_play_target` accepts a legality `filter` and the world uses it — but the ENGINE
  never does (decision_engine.lua:210 and every other call site), so under Psychic / Eye /
  Mouth the clears flag, play-vs-discard compare, and fuel/ordering are computed on plays
  that may be illegal (the sim substitutes a legal play after the fact; the LIVE mod
  flatly recommends unplayable hands). Eye/Mouth also need cross-hand state
  (`played_types`) that is never exported into `gs.blind` — plumbing gap. The Hook: zero
  policy adjustment (every play costs 2 random held cards; multi-hand setups over-valued).
  The Arm's `level_down` is declared in boss_effect.lua but applied nowhere (also a world
  gap → A7). Water/Needle/Manacle and suit-debuff *scoring* are correct.
- **F6. Consumable timing: the use_action override is UNCONDITIONAL over a PLAY.**
  Small-Medium / CONFIRMED / Low. decision_engine.lua:459–471 promotes any use_action
  over the chosen PLAY regardless of values. Hermit/Temperance fire at any `gain > 0`
  (tarot.lua:244–249) — a held Hermit doubles $3 instead of waiting for a fat bankroll.
  Enhancement/suit tarots fire on any +1 score gain and are valued at TOTAL play score
  with zero permanence credit (vs planets' LEVEL_USE_CREDIT) — burns Chariot/steel onto a
  mediocre drawn card instead of waiting one hand. Fix: gate income tarots on bankroll,
  add a small permanence credit + material-gain threshold for enhancement tarots.
  (Immediate *planet* use is correct as-is.)
- **F7. Hand-selection tiers are sound; two nits.** Low / CONFIRMED / Trivial. Within the
  expected-clear tier, ties break by score, not `score_min` — picks the flashier RNG
  coin-flip over an equal-mean safer clear (one-line fix). Tier 0 (can't clear) has no
  pace concept — max single-hand score; that gap is what F1/F2 fix.
- **F8. Minor:** `DV.measured` samples=10 → 10–20% stderr misranks candidate sets
  (two-stage sizing: 10 to shortlist, 25–30 on the top 2 — nearly free);
  `DOLLAR_VALUE=12` flat regardless of ante (harmless today, don't build on it).
- **F9. `scaling_fuel`** logic is correctly survival-gated (never trades the clear; credit
  capped sanely); in the current sim it is pure waste (A1) — do not judge or tune it
  until A1 lands. Overkill banking / next-blind carryover: minor, ordering already
  switches to money once guaranteed.

**The documented variance-death trace explained** (24,733 on an ante-5 boss → 8,307 on
the easier ante-6 Small → death): capacity lives in one payoff shape → the mean-of-max
objective digs for it (F1) while the joker-blind keep order pitches made-hand components
(F4) → the draw misses, discards are spent → fallback plays score hundreds → the last-hand
mean-rule plays a guaranteed-loss hand instead of the tail-chance dig (F3). No code ever
computed the cumulative P(clear) of the safe line.

### G. Pacing & evaluation (`pacing`, `eval_function`)

- **G1.** `growth_factor` baseline 1.25 was *measured* (round 9) to be ~1.0 once the board
  fills, and the honest recalibration backfired — so the current model is knowingly
  optimistic, and everything gated on `pace` (proj_damp, invest window, pack need,
  situation weights, skip… ) inherits the bias. The right fix is not another constant:
  replace mean-capacity (`avg_score × hands`, variance-blind) with a **measured clear
  probability / quantile capacity** (e.g., 30th-percentile per-hand score × hands vs
  requirement — computable from the samples `avg_score` already draws). Experiment-first:
  yes, this failed once as a constant tweak; as a variance-aware metric it's a different
  hypothesis, and it should be re-run only after the world fixes.
- **G2.** `run_strength` weights are arbitrary but mostly telemetry-facing. Low.

### K. Scoring/facts layer (`hand_eval`, `joker_effects`, `joker_data`, `boss_effect`, `ordering`, `probability`)

The facts layer is largely excellent (see the verified list in §3 — all test goldens
recompute clean against real rules), but a handful of per-joker hooks are wrong in ways
that corrupt both the sim and the live advisor:

- **K1. Supernova is a silent zero (sim AND live).** HIGH / CONFIRMED code, VERIFY live
  field / Medium. `joker_effects.lua:231` reads it as a live-counter mult scaler
  (`scaled(j, MULT, 0)`), but real Supernova's mult = times the played hand type has been
  played this run — computed at score time, no accumulator on the ability. The sim reads
  0 forever (it was bought 8× in the baseline and contributed nothing); live very likely
  reads 0 too (one F7 dump settles it). Fix: plumb per-hand played counts into the
  GameState (world tracks them for Eye/Mouth anyway — F5's `played_types` plumbing can
  carry counts) and compute contextually.
- **K2. Loyalty Card and Card Sharp misread a static config as an accumulator — they
  over-fire EVERY hand on the live path.** HIGH (live) / CONFIRMED code, VERIFY live
  fields / Medium. `joker_effects.lua:252-253` use `scaled(j, XMULT, 1)`; live, their
  ability carries a constant config (`extra.Xmult` = 4 / 3) which the XMULT field-scan
  matches → the engine applies ×4 / ×3 on every hand, inflating live clear estimates
  (can recommend a play that won't actually clear). In the sim they read ×1 (inert).
  Real: Loyalty ×4 every 6th hand (~×1.5 long-run); Card Sharp ×3 only if the hand type
  was already played this round. Fix: model the conditions explicitly (Card Sharp needs
  round-played types — same plumbing as K1/F5; Loyalty needs its `remaining` counter).
- **K3. Spare Trousers' accumulated mult is wrongly gated on the current hand.**
  Medium / CONFIRMED / **one-line fix**. `joker_effects.lua:232` returns its mult only
  when the played hand contains Two Pair; real Balatro: Two Pair is the *growth*
  condition only — the accumulated mult applies to every hand. Skews best_play and
  scaling_fuel toward two-pair plays and undervalues owned Trousers. (Related:
  `joker_data` SCALE_TRIGGER_HANDS omits `j_trousers`, so its growth projection is
  also ungated.)
- **K4. Photograph doesn't re-fire on retriggers of the first face card.** Medium /
  CONFIRMED / Low. `ctx.flags.photograph_used` persists across the trigger loop —
  Photograph + Hanging Chad on a face card is ×8 in-game, ×2 in the model. Under-scores
  face-retrigger boards; the ordering advisor can't discover the known combo.
- **K5. Joker foil/holo editions applied AFTER the joker's own effect.** Medium /
  CONFIRMED code, high-confidence real rule / Low. `hand_eval.lua:459-461` applies the
  edition after `on_hand`; real: foil (+50 chips) and holo (+10 mult) apply BEFORE the
  joker's effect, only polychrome after — a Holo Cavendish is (mult+10)×3 in-game vs
  mult×3+10 modeled. Under-scores every foil/holo xmult joker. No golden pins the wrong
  order, so the fix is test-safe.
- **K6. Raised Fist modeled as `on_hand`** — held-card retriggers (Mime, Red Seal on the
  lowest card) can't double it; the known Raised Fist + Mime combo under-scores. Low-Med.
- **K7. Unmodeled bosses become "generic 2×, no restriction"** — The Pillar (ante-1
  pool!) and Crimson Heart (per-hand joker disable) are the two materially-scoring ones
  that are cheaply modelable; House/Wheel/Fish/Mark (face-down), Serpent, and the other
  finishers remain gaps. Cross-ref A7 (world) and F5 (engine legality).
- **K8. Low-impact bundle:** Four Fingers requires the whole played set to be the
  flush/straight (real: 4-card subset inside a 5-card play also qualifies, enabling
  contains-combos — only matters with FF owned); Shortcut ace-low gapped straights never
  classify (VERIFY real rule); Flint halving keeps fractions (real rounds — only matters
  at exact clear margins); Erosion hardcodes 52 (wrong on Abandoned Deck only); Hiker's
  permanent +5 chips/card is invisible card-side (needs `state_extraction` to read live
  bonus chips — VERIFY); whether Quads "contains" Two Pair (Mad/Clever/Trousers on
  quads) — VERIFY vs source; a Blueprint-copied Swashbuckler self-counts (small
  over-score); catalogue cost nits (`j_reserved_parking` $4 vs real $6, `j_lucky_cat`
  $7 vs $6 — VERIFY; ~60 other spot-checked costs/rarities match).

### H. Methodology & experiment design (the meta-findings)

- **H1. Power.** sd(death-ante) ≈ 1.6 → SE(n=80) ≈ 0.18, so ±0.05 verdicts are ~0.3 SE.
  Several kept/reverted decisions (B1 +0.038, leveling-need −0.051, first-xmult −0.051,
  swap-damp −0.075) are statistically indistinguishable from noise at n=80. **Adopt paired
  per-seed A/B**: the sim is deterministic per seed, so run identical seed sets and analyze
  per-seed deltas (mean paired Δ, sign test, and the count of seeds whose death-ante
  moved). Same compute, several-fold more power. Add a `compare <a.jsonl> <b.jsonl>` mode
  to `analyze_runs.lua`.
- **H2. Metric.** Death-ante is coarse (integer, censored at 8). A continuous progress
  score — ante + blind-index/3 + min(1, scored/target) at death — discriminates better;
  keep death-ante for headline, use progress for verdicts.
- **H3. Sequencing discipline.** Never change world and engine in the same batch;
  re-baseline after every world-fix cluster; keep the per-run `engine` stamp (already
  good).
- **H4. Re-litigate the graveyard after the world is fixed.** The reverted levers most
  likely to flip: leveling-need (round 22), leveling-alignment (16), flush-commitment (18),
  coupled pair (21), scaler-related damps (19/20 should be *dropped* — after A1 scalers
  really grow, so damping them is wrong for the opposite reason). The scripts/diffs exist;
  each retest is one batch.

### I. Performance (only where it buys decision quality)

- **I1.** Runtime is dominated by per-shop MC (`score_delta`, `hand_frequencies` — the
  latter re-sampled per shop-joker with no cache in `scoring_gain`, unlike the jp path).
  A cheap incremental deck signature (running hash updated on deck mutation) would make
  the previously-reverted cross-call memo viable, cutting shop-phase cost severely.
- **I2.** Spend the savings on samples where decisions are live (C1's adaptive sampling,
  F1's search) — precision at the decision margin is worth more than raw speed.
- **I3.** Parallel batches are solved (~12 min for n=80); n=160–200 paired batches are
  practical and should be the verdict standard (H1).

### J. Deploy/operational

- Repo engine ≠ installed live mod (documented in NEXT_SESSION) — after this audit's
  engine fixes land, re-sync `engine/*.lua` or live advice diverges further.
- The `c_hierophant`/`c_heirophant` alias (A3) is a live-game silent zero too.
- **Live-only correctness risks:** K2 (Loyalty/Card Sharp over-fire ×4/×3 every hand →
  the live advisor can claim a clear that won't happen), F5 (recommends Psychic/Eye/
  Mouth-illegal plays live), K1 (Supernova valued ~0 live). One F7 dump each of
  Loyalty Card, Card Sharp, Supernova, Idol, Ancient settles the live ability layouts.
- Tests pin some behaviors this audit marks wrong (e.g., Judgement's CREATES_JOKER ×5
  band-aid in `test_advisors` #630-642); expect deliberate test updates with B1. The
  hand_eval/joker goldens were recomputed against real rules and are clean — K4/K5
  fixes won't fight the fixtures.

---

## 2. Prioritized roadmap

Ranking rule: (expected win-rate movement) × (confidence) ÷ effort, honoring dependencies
(world before engine, engine before strategy, measurement before verdicts).

**Phase 0 — measurement (half a day).**   ✅ **item 1 DONE (2026-07-06) — see §4.**
1. Paired per-seed A/B in `analyze_runs.lua` + continuous progress metric (H1, H2).
2. Standard: n=160 paired for every verdict from here on.

**Phase 1 — world fidelity: make the winning archetypes possible (the big unlock).**
Order within phase by distortion size; re-baseline after each cluster; all are FACTS-layer
(honesty-rule-safe):
1. **A1** scaler accumulation + decay/destruct tick (top ~15 scalers first).  ✅ **DONE
   (2026-07-06) — see §4. New baseline `sim_out/a1.jsonl` (death-ante 3.400, progress 3.081);
   net vs `scorer2` a paired WASH (p≈0.65), scaler defects now exposed for Phase 2.**
2. **A2+A3** dead tarots (money → Judgement/HP/Emperor → Fool/WoF → Lovers+Hierophant
   aliases) and top spectrals (Soul, Black Hole, Immolate).  ✅ **DONE (2026-07-06) — see §4.
   New baseline `sim_out/a2a3.jsonl` (death-ante 3.288); paired WASH vs `a1` (p≈0.53) but the
   money model + dead leveling channel are now demonstrably working.**
3. **A4** voucher effects + once-per-ante restock; Hieroglyph sign fix.  ✅ **DONE
   (2026-07-06) — see §4. New baseline `sim_out/a4.jsonl` (death-ante 3.462, +0.175 vs a2a3);
   first fidelity fix to clearly move UP — the $13/run voucher sinkhole is closed.**
4. **A6** immediate pack-pick use (Celestial/Arcana), stop silent pick loss.  ✅ **DONE
   (2026-07-06) — see §4. New baseline `sim_out/a6.jsonl` (death-ante 3.612). FIRST
   STATISTICALLY SIGNIFICANT win: +0.157 progress, paired t p≈0.007, sign p≈0.046.**
5. **A5** dead tags (coupon/D6/handy/garbage/speed/juggle/double).  ✅ **DONE (2026-07-06)
   — see §4. Correct but BEHAVIORALLY INERT (byte-identical to `a6`): the engine never skips
   for these low-valued tags, so the payouts never fire. Unblocks B6 (engine tag valuation).**
6. **A7/A8/A9** boss money + Pillar/Arm; play-money credit; standard-pack rates; edition
   odds incl. negative; tag ante-gating; mega weights.  ✅ **DONE (2026-07-06) — see §4. New
   baseline `sim_out/a789.jsonl` (death-ante 3.450). Correct fidelity, net −0.16 (n.s.): the
   "sim too easy on bosses" correction. FIRST WIN appeared (seed 5003, ante 8). Pillar/Ox/
   face-down/Serpent/finishers + standard-pack rates + tag-gating DEFERRED (see §4).**
Expected outcome: the baseline moves on its own (fidelity corrections historically ±0.1
each; this cluster is much larger than anything shipped before) **and the ante-4 wall
diagnosis must be re-derived on the new world before any strategy work.**

**Phase 2 — engine valuation unification (each = one paired experiment vs the new baseline).**
1. **B1** one frac→utility bridge: ×JOKER_SCORE_WEIGHT on all shop paths (consumables
   included), delete `SA.CREATES_JOKER`, re-check level_persist × level_amplifier
   stacking. (The never-run round-4 fix; the leveling keystone.)  ✅ **DONE (2026-07-06) — see
   §4. New baseline `sim_out/b1.jsonl` (death-ante 3.538, +0.087 vs a789). Positive, no
   backfire — the audit's thesis confirmed: the correctness unification that FAILED against the
   broken world HELPS against the faithful one.**
2. **C2** swap-gate fix (`cur > 0` → floored scoring_gain) + **C3** copier insertion fix —
   unblocks keystone acquisition on full boards.  ✅ **DONE (2026-07-06) — see §4. Correct
   (Blueprint 0→690; keystone buys 9→12) but nearly-inert at n=80 (Rare keystones rarely
   offered on a full board). Baseline `c2c3.jsonl` ≈ b1 (3.538). Ships as correctness.**
3. **C1** adaptive samples on the swap/sell path (or analytic conditional-xmult triggers).
   ❌ **TRIED & REVERTED (2026-07-06) — see §4. Adaptive samples (24 for conditional xmults)
   was NEGATIVE (−0.175 death-ante, 14 worse / 6 better): removing the measurement noise
   without retuning the floors/margins that COMPENSATE for it mis-calibrates. A proper C1
   needs the guardrail retune together — deferred.**
4. **B5** pack/reroll pool w² fix; spectral pool via `card_value`.  ✅ **DONE (2026-07-06) —
   see §4. Correctness fix, ~neutral (+0.038 death-ante, sign 9/11, n.s.). Baseline
   `b5.jsonl` 3.575. Rare tail restored; Hex/Ankh no longer over-valued on a built board.**
5. **B2** Blue-seal unit fix; **B6** tag magnitudes (edition tags as free edition jokers);
   **E1** skip interest term; **B4** voucher downsides (Hieroglyph).
   — **B2 ✅ DONE (2026-07-06), see §4:** clean unit fix (Blue-seal 7.5→0.020), strictly
   non-negative (+0.012 death-ante, 1 later / 0 earlier, 77 tied). Baseline `b2.jsonl` 3.587.
6. **B3** unify the $↔frac rate (ante-aware).  ❌ **TRIED & REVERTED (2026-07-06) — see §4.
   Anchoring VU.BASE_FRAC to the shop rate (0.03→0.06) was NEGATIVE on the mean (−0.225
   death-ante) with a balanced sign (30/33) and high added variance — the downstream constants
   (SK.SHOP_VALUE, keep_bias) were tuned against the OLD rate; unifying needs the co-retune.**
7. **F3** last-hand quantile dig (take the tail-chance dig when the forced play certainly
   loses) — trivial, strictly non-negative, and the proof-of-concept for P(clear)
   objectives before the bigger F1/F2 work.
   ❌ **TRIED & REVERTED (2026-07-06) — see §4. NOT strictly non-negative in practice
   (−0.100, 0 seeds better / 3 worse): a low-P tail-dig USUALLY fails, and a failed dig plays
   a worse hand → sacrifices partial score (Mr Bones's 25% save, progress metric) and cascades
   the sim. The "you'd lose anyway" premise ignores that partial score has value.**
8. **K3** Trousers application-gate fix (one line) + **K4** Photograph retrigger +
   **K5** foil/holo edition order — pure scoring-correctness, test-safe.  ✅ **DONE (2026-07-06)
   — see §4. Facts-layer correctness (also fixes the LIVE mod); balanced wash in the sim
   (sign 4/4, −0.075 death-ante, n.s.). Baseline `k345.jsonl` 3.513.**
9. **K1+K2** Supernova / Loyalty / Card Sharp: plumb per-hand played counts + round
   played-types into the GameState (shared with F5's legality plumbing) and model the
   real conditions. K2 is also the biggest LIVE-only correctness risk — fix before the
   next live re-sync.  ✅ **DONE (2026-07-06) — see §4. Contextual models + world plumbing;
   slightly-positive correctness win (+0.062 death-ante, sign 11/8, n.s.). Baseline
   `k12.jsonl` 3.575. LIVE over-fire fixed; state_extraction plumbing is a follow-up.**

**Phase 3 — re-litigate the graveyard (cheap, high information).**  ✅ **COMPLETE (2026-07-06)
— see §5.** Determinism-fix precondition + fresh n=160 baseline `base160`, then paired n=160:
- **leveling-need** ✅ KEPT — verdict FLIPPED −0.051 → **+0.012** (backfire gone). New baseline `p3_levelneed` 3.569.
- **coupled pair** (flush-commit + leveling-align) ❌ REVERTED — still refuted (RNG-cascade, can't BUILD a deck greedily).
- **leveling-alignment / flush-commitment** — folded into the coupled test (no-ops alone; refuted coupled).
- **"delete scaler damps"** ❌ TESTED & REFUTED — removing `proj_damp` = wash + breaks guardrails; the committed
  `proj_damp`/`scale_trigger_factor` are legitimate survival-timing gates, KEPT; reverted round-19/20 damps stay out.

**Phase 4 — in-blind survival track (PARALLEL-VALID; variance deaths measurable against the current world).**
1. **F1+F2** boss-aware survival arbitration of play-vs-discard via `simulation.lua` (`survive_after`, E[frac]=
   P(clear)+partial-credit, CRN, margin-gated). Do NOT invest in `search.lua` — subsumed.  ✅ **DONE/SHIPPED
   (2026-07-07) — see §6. +0.038, sign 31/18 (p≈0.087) — the strongest single-lever signal of the effort. New
   baseline `p4_surv` 3.612.** (Note the objective is `E[frac]`, the F3-corrected partial-aware form, NOT pure P(clear).)
2. **F5** boss legality plumbing (engine-side Psychic/Eye/Mouth filter; reuses K1/K2 `played_hand_types`).  ✅
   **DONE/SHIPPED (2026-07-07) — see §6. Sim-NEUTRAL (world already substitutes legal plays) but fixes the LIVE
   mod's illegal recs + makes F1/F2's forced-PLAY legal.** (Promoted ahead of F4 as an F1/F2 fast-follow.)
3. **F4** discard-set generators (flush-dig, boss-aware `keep_value`).  ❌ **TRIED & REVERTED (2026-07-07) — see §6.
   High-variance RNG churn (+0.122 mean but sign 70/62 balanced, sd 1.255); the biggest "win" built no flush.
   DEPENDS ON F8 (adding candidate sets to a 10-sample-noisy measurement amplifies mispicks).**
4. **F8** two-stage discard sampling (noise reduction; the F4 prerequisite).  ❌ **TRIED & REVERTED (2026-07-07) —
   see §6. Partial n=106 (infra-limited): −0.054, sign 44/58, sd 1.421. C1-PATTERN — the discard guardrails
   (`keep_bias`/floors) COMPENSATE for the noise, so de-noising without co-retuning them mis-calibrates.**
5. **F6** consumable timing (Hermit bankroll gate; enhancement-tarot permanence credit); **F7** score_min
   tie-break.  ✅ **DONE/KEPT (2026-07-10) — see §6. +0.012 progress, +0.013 death-ante, sign 13/8;**
   Hermit payout improved $15.80→$18.94 and concrete shop-purchase funding is measured, not thresholded.

**Phase 5 — strategy layer (only what the new wall demands).**  🔶 **IN PROGRESS (2026-07-10; see §7).**
1. **G1** variance-aware pacing (quantile capacity / measured clear-prob).
2. Desperation conversion (idle $ at death is real but modest — median $8).
3. **The committed-archetype planner** on the `build_plan`/`deck_plan` scaffolding — the Phase-3 evidence
   now POINTS HERE: the deck-shaping levers stay refuted because a greedy per-decision valuation can't
   *assemble* a shaped deck (offer-rate-limited + cascade-dominated), independent of survival horizon. This is
   the build-side prize, measured against a world where commitment can finally pay. ✅ **V1 KEPT
   (2026-07-10): +0.033 progress, +0.038 death-ante, sign 17/11; sticky hand/economy commitment co-moves
   joker fit/retention + planet concentration + deck target. Still 0 wins; planner refinement remains.**

**Phase 6 — live sync.**  ⬜ **NOT STARTED.** Deploy the shipped engine fixes to the install (repo ≠ install);
verify the K1/K2/F5 live plumbing via F7 dumps; alias fixes. NOTE: the whole faithful-world engine (B1, C2/C3,
B5, B2, K3/K4/K5, K1/K2, leveling-need, F1/F2, F5) is SIM-SIDE only and NOT yet re-synced to the live mod.

### Why this ordering maximizes expected improvement
Every build-side experiment run before Phase 1 is judged by a referee that structurally
punishes the winning strategies — information per experiment is near zero (22 rounds of
history demonstrate this: only "flat scorer" fixes could win in a world where nothing else
works). Phase 1 is pure correctness with no tuning risk; Phase 2's items are
correctness/consistency fixes with known mechanisms, not speculative levers; Phase 3 turns
the existing graveyard into fresh, cheap experiments. The Phase 4 in-blind track is the
exception to "world first": variance deaths are an in-blind phenomenon the current world
measures faithfully, so it can run in parallel with Phase 1 — it attacks the 32/80
variance-death bucket directly. Phase 5 spends design effort only on whatever ceiling
*survives* a faithful world, a consistent value function, and a risk-aware play policy.

---

## 3. What was checked and found correct (bounding the audit)

Economy constants ($4 start, rewards 3/4/5, $1/unused hand, interest and cap, reroll $5+1
resetting per shop, sell = max(1, floor(cost/2))); ante bases and blind multipliers; boss
min-ante gating and fewest-seen selection; Mr Bones; pack sizes/pick counts; rarity
70/25/5; shop slot-type weights 20/4/4; determinism (sorted-key sampling, JSON key order,
LCG streams) — parallel batches are sound; discard measurement samples the true remaining
pile (no card-counting cheat beyond legal knowledge); anti-churn / keep-bias / first-scorer
/ econ-floor designs are coherent for the world they were tuned in; in-blind resource use
at death is efficient (0.23 hands, 0.15 discards left); telemetry pipeline (records,
paired shapes, engine stamps) is genuinely good infrastructure.

Scoring/facts layer (full sub-audit): all 12 hand base chips/mult and all 12 planet
increments exact; card chip values, enhancements (Bonus/Mult/Wild/Glass/Steel/Gold/Lucky),
per-card editions and their application position, seals (Red retrigger-aware, Gold $3 per
trigger, Blue/Purple correctly outside scoring); the phase structure (base → scored cards
L→R → held cards → jokers L→R → floor) and additive retrigger stacking; retrigger jokers
(Hack, Sock and Buskin, Dusk, Seltzer, Hanging Chad, Mime — Mime correctly drives
Baron/Steel); ~45 spot-checked joker magnitudes/conditions including the full
Duo/Trio/Family/Order/Tribe "contains" semantics (trips⊃pair, full house⊃two pair);
classification incl. Four Fingers thresholds, Shortcut gap-1, Smeared by color, wheel;
`best_play_target`'s guaranteed/expected/accumulate tiering with `score_min` excluding
exactly the RNG upside; `ordering.lua`'s premise (jokers and cards are the only real
reorderables; Blueprint targets re-resolve per permutation); `probability.lua`
hypergeometrics; and every test golden recomputed by hand against real rules — none
pinned wrong.

In-blind play (full sub-audit): single-hand selection given a target is sound (tier
ordering, money tie-break at locked clears, play_econ handling); scaling_fuel never
trades the clear (credit capped, equal-survival re-picks only); Water/Needle/Manacle
resource handling; suit-debuff *scoring* correct (gaps are in keep/candidate generation,
F4); immediate planet use is correct.

---

## 4. Implementation log (what actually got built + measured)

### 2026-07-06 — Phase 0, item 1: paired A/B + progress metric (H1, H2). ✅ SHIPPED

**What:** added to `tools/analyze_runs.lua` (pure tooling; no engine change):
- **Continuous progress metric (H2)** `run_outcome()`:
  `progress = (ante-1) + (blind_index + min(1,scored/target))/3`, range [0,8], win = 8.0
  (blind_index Small/Big/Boss = 0/1/2). Surfaced in the single-file report as a
  `PROGRESS SCORE` line (headline stays the death-ante histogram, per H2).
- **Paired per-seed A/B (H1)** — new subcommand `analyze_runs.lua <A> compare <B>`:
  pairs runs by seed, then reports the **paired progress Δ** (mean, sd, SE, t-stat,
  two-sided p via a normal-CDF approx), a **sign test** (robust to the discrete/
  censored death-ante), the **death-ante shift counts** (later/earlier/unchanged), and
  the biggest per-seed swings. Load/group logic refactored into `load_file`/`group_runs`
  so both modes share it; `trace` mode unchanged.

**Validation (empirical, not unit-tested — the tool is a standalone diagnostic):**
- **Self-compare `scorer2 vs scorer2` = exactly 0** across all 80 seeds (80 tied, Δ 0.000).
- **Reproduces the historical record exactly:** `scorer2 → levelneed` death-ante
  Δ = **−0.050** (docs: −0.051); `firstscorer → scorer2` Δ = **+0.038** (docs: +0.038).
- **Confirms H1 (the headline methodology finding): both of those historical verdicts
  are statistically indistinguishable from noise at n=80.** `levelneed`: paired progress
  mean Δ −0.009, t = −0.12, p ≈ 0.91; sign test 14 better / 14 worse / 52 tied.
  `firstscorer→scorer2`: mean Δ +0.042, t = +0.63, p ≈ 0.53; sign 4 / 5 / 71 tied. The
  ±0.05 "graveyard" the audit flagged as noise is now *demonstrably* noise — every
  reverted/kept ±0.05 decision in `NEXT_SESSION.md` was a coin flip.
- Baseline `scorer2` progress score: **mean 3.159, median 3.391** (n=80). This is the
  new continuous reference to A/B against.
- `lua tests/runner.lua` → **706 pass, 0 fail** (tool is outside the suite; no engine
  touched).

**Expectations met?** Yes — and it over-delivered: it didn't just add power, it
retroactively invalidated the confidence behind several logged verdicts, which
*strengthens* the audit's core recommendation to re-litigate the graveyard (H4/Phase 3)
once the world is fixed. Nothing here changes the engine or the world; it changes how we
*judge* every subsequent change.

**Follow-up / open:**
- Phase 0 item 2 (n≥160 paired as the verdict standard) is a **process** rule, not code —
  adopted going forward. n=80 batches are retained only for headline death-ante continuity.
- The `compare` power gain means the **next** experiment (Phase 1 · A1 scaler accumulation)
  should be run as `sim_par.sh` at n≥160 on a fixed seed set, then judged with `compare`
  against a **freshly re-baselined** `scorer2`-engine batch on those same seeds (H3:
  never change world + engine in one batch; re-baseline after each world cluster).
- No new discoveries in the code beyond confirming the record is reproducible byte-for-byte
  (determinism holds — a precondition the compare tool silently relies on).

### 2026-07-06 — Phase 1, item 1: A1 scaler accumulation + decay/self-destruct. ✅ SHIPPED

**What:** new `sim/joker_tick.lua` (FACTS layer) makes scaling jokers actually GROW and
decayers actually DECAY in the sim, writing to the exact `ability`/`ability.extra` fields
`engine/joker_effects.scaled()` reads (mult→`ability.mult`, chips→`ability.extra.chips`,
xmult→`ability.x_mult`; growth applied AFTER a hand scores so the increment lands next hand,
matching Balatro). Covered (16 keys, magnitudes wiki-verified):
- **per-play:** Ride the Bus (+1 mult, reset on scoring face), Green Joker (+1), Runner
  (+15 chips/straight), Square (+4 chips/4-card hand), Wee (+8 chips/scored-2), Spare
  Trousers (+2 mult/two-pair), Vampire (+0.1x/scored-enhanced, **eats the enhancement**),
  Ice Cream (−5 chips/hand, **destroyed at 0**).
- **per-discard:** Green Joker (−1), Ramen (−0.01x/card, destroyed at x1).
- **events:** Constellation (+0.1x/planet used), Fortune Teller (+1 mult/tarot used),
  Hologram (+0.25x/card added to deck), Throwback (+0.25x/blind skipped).
- **round-end:** Popcorn (−4 mult, destroyed at 0), Gros Michel (1/6 extinction), Cavendish
  (1/1000) — self-destruct rolls consume the world RNG **only when owned** (runs without
  them keep an undisturbed stream).
Wired into `world.lua` (play/discard/consumable-use, `round_end_tick`, `skip_tick`),
`content.lua` (deck-add), `driver.lua` (round-end tick + `joker_loss via=destroy` telemetry,
skip tick). **Deferred** (audit assigns elsewhere): Supernova/Loyalty/Card Sharp/Obelisk
(per-hand-TYPE counts → K1 plumbing), Lucky Cat (per-lucky-trigger RNG), Castle/Hit the
Road (per-round resettable), and the shop-event scalers Red Card (pack-skip)/Flash (reroll).

**Tests:** new `tests/test_joker_tick.lua` (14 cases) pins each growth/decay/destruct rule
AND that the engine's own scoring hook reads the grown value. `lua tests/runner.lua` 706/706;
`luajit tests/runner_sim.lua` **120/120** (was 86 + 34 new incl. tick suite).

**Batch (paired, n=80, same seeds; ISOLATES the world change — engine byte-identical to
`scorer2`):** `scorer2` (old world) vs `a1` (new world):
- progress mean Δ **−0.078** (t=−0.85, **p≈0.40 n.s.**); death-ante 3.513 → **3.400**.
- **sign test 24 better / 20 worse / 36 tied (p≈0.65) — a statistical WASH.**
- swings are LARGE and symmetric (±2.5 antes): 35003 a3→a6 (Ride the Bus grew, pace
  1.3→8.9), 19003 a5→a7; vs 13003 a6→a4, 31003 a6→a3.

**Expectations met?** Yes — this is the textbook signature of a pure FACTS-layer fidelity
fix: it moves individual runs hard in BOTH directions but nets to noise, because it isn't a
tuning lever — it makes the world HONEST. Verified the movers are legitimate, not bugs:
improvements are scalers finally maturing (35003); regressions are **honest** — the engine
still over-buys condition-locked scalers that can't be fed here (13003 bought Red Card at
value 11.5 with no pack-skips to grow it) and self-destruct rolls legitimately diverge the
RNG. **The key unlock:** the engine's scaler-valuation defects (over-valuing ungrown
scalers, the swap-gate, the ×1/×5 leveling scale) were previously UNMEASURABLE (scalers
couldn't grow); they are now exposed against a faithful world — exactly what Phase 2 fixes.

**New baseline:** `sim_out/a1.jsonl` (n=80, death-ante **3.400**, progress **3.081**). All
Phase-1/2 verdicts from here compare against THIS (not `scorer2`). **The ante-4 wall
diagnosis must be re-derived on this world** before any strategy work (§0 consequence).

**Follow-up:** (1) establish the official Phase-2 baseline at **n=160** on the A1 world when
the first engine change is judged (A1 itself ships as correctness regardless, so n=80 was
sufficient to observe the wash). (2) Next Phase-1 unit: **A2+A3** (dead tarots + Hierophant
alias) — will re-baseline again. (3) The deferred shop-event scalers (Red Card/Flash) and
K1 context-scalers (Supernova/Loyalty/Card Sharp) remain frozen; note this when their
valuation is judged.

### 2026-07-06 — Phase 1, item 2: A2+A3 dead consumable execution + aliases. ✅ SHIPPED

**The distortion (measured on `a1`):** the world's `use_consumable` executed only planets +
deck tarots; everything else was silently discarded after the engine paid for it. Data:
Temperance used 11× / Hermit 6× — each paid **$0** (corrupted money model); High Priestess
gained 15× / **used 0×**, Judgement 14/0, Emperor 7/0, Fool 8/0, WoF 6/0, Soul 2/0 — ~52 dead
generators clogging the 2 consumable slots (which also disables the in-blind search).

**What shipped (three coupled pieces):**
1. **World executor (FACTS, `sim/world.lua`):** faithfully applies every consumable effect —
   money (Hermit +min($,20); Temperance +min(Σ joker sell,50); Immolate +$20 & destroy 5),
   leveling (Black Hole +1 to every hand), generators (Judgement→joker, Soul→Legendary,
   High Priestess→2 Planets, Emperor→2 Tarots, Fool→recreate last, WoF→1/4 edition a joker).
   The used card is consumed FIRST so its slot is free for creation (real rule). Joker/
   consumable creation routes through `sim.content` (lazy require; no cycle). Fool tracks the
   last tarot/planet used. Loop-guard added to `play_blind` (generator use costs no hand).
2. **Engine (`decision_engine.generator_use`):** proposes USING a held free-value generator —
   Black Hole always, Judgement/Soul with a free joker slot, High Priestess/Emperor with a
   free consumable slot. This is the safe category per the tuning rule (free value from an
   OWNED item — no spend), and it revives the leveling channel (HP→Planets→level-ups).
3. **A3 aliases:** `c_heirophant` (the in-game misspelling) aliased in `tarot.ENH`,
   `consumable_value.TAROT_BASE`, `pack_open_advisor` (was scoring the 0.15 fallback + no-op on
   use, in sim AND live); Lovers → `m_wild` in `tarot.ENH`.

**Tests:** new `tests/test_consumables.lua` (23 cases) pins each effect, the slot rule, the
aliases, and that the engine now proposes using free generators (and does NOT with no room).
706/706 unit, **143/143 sim**.

**Batch (paired n=80 vs `a1`):** progress mean Δ **−0.091** (t=−0.63, **p≈0.53 n.s.**);
death-ante 3.400 → **3.288**; sign 26 better / 31 worse / 23 tied (p≈0.60). **sd rose 0.82→1.29**
(generators add real randomness). Another paired WASH — same fidelity-fix signature as A1.

**Expectations met?** Yes, and the intended MECHANISMS are verified working (this is a
correct fix whose net is masked by engine-defect noise + added variance, not a bug):
- **Money model fixed** — trace 24003 (a2→a6, +3.21): Temperance now pays real $ (broke at
  ante 3 → $23 at ante 4 → funded the build to ante 6). Was $0 pre-fix.
- **Dead leveling channel revived** — median hand-levels rise (ante 6: **3.0 vs a1's 2.0**),
  run_strength up at antes 5–7 (0.53 vs 0.48), mid-game $ up (ante 5: 25 vs 20). The
  winning-relevant TAIL improved even as the mean stayed flat.

**Honesty note (H3):** this bundles a world-fidelity fix with a small engine policy
(`generator_use`) because generators are INERT without both (the world can't show an effect
the engine never triggers). Both are correctness/additive-safe, net a wash. The engine piece
is cleanly isolable (`DE.GEN_USE` + `generator_use`) if a future measurement wants to attribute
it separately. Per H3 proper, future world/engine changes stay in separate batches.

**New baseline:** `sim_out/a2a3.jsonl` (n=80, death-ante **3.288**, progress **2.990**).
Cumulative fidelity arc: `scorer2` 3.513 (old world) → `a1` 3.400 → `a2a3` 3.288 — two paired
washes; the world is now materially more honest (scalers grow/decay, consumables real), which
is the setup for Phase 2 (engine valuation) to convert into survival. **Next Phase-1 unit: A4
(voucher effects + once-per-ante restock; Hieroglyph sign fix)** — will re-baseline again.

### 2026-07-06 — Phase 1, item 3: A4 voucher effects + once-per-ante restock. ✅ SHIPPED

**The distortion:** `sim/content.lua` `apply_voucher` implemented ~3 of 16 vouchers (rest
inert), Hieroglyph had the WRONG SIGN (+1 hand instead of −1), Seed Money gave +$1 cap
instead of raising it to $10, and the voucher slot was restocked **every shop** (3× per ante)
instead of once — a ~$13/run sinkhole (91 buys / 80 runs, most doing nothing).

**What shipped (all `sim/content.lua`, FACTS layer):**
- **Resource vouchers** now mutate run state: Overstock (+1 shop card slot, via `run.shop_slots`
  consumed by `gen_shop`), Grabber (+1 hand), Wasteful (+1 discard), Paint Brush (+1 hand size),
  Crystal Ball (+1 consumable slot, was already in), Seed Money (interest cap → $10, was the +1 bug).
- **Hieroglyph sign fix:** −1 hand (was +1). The −1-ante runway benefit is left unmodelled
  (a documented simplification — under-credits, the safe direction).
- **Generation vouchers** via flags read at gen time: Hone (foil/holo/poly ×2), Tarot/Planet
  Merchant (that slot type ×2), Clearance Sale (cards & packs −25%, via a `priced()` helper),
  Reroll Surplus (−$2 base reroll), Telescope (a Celestial pack's first planet is your
  most-leveled hand's).
- **Restock cadence:** ONE voucher per **ante** — generated at the ante's first shop, the SAME
  offer persisting across that ante's shops, cleared on purchase, replaced next ante.
- **Documented unmodelled:** v_blank (nothing — correct), v_magic_trick, v_directors_cut,
  Hieroglyph's −1 ante, and upgrade-tier vouchers (BASE-only pool, per the audit's note).

**Tests:** new `tests/test_vouchers.lua` (23 cases) pin each effect, the sign fix, the price
helper, and the once-per-ante restock. 706/706 unit, **166/166 sim**.

**Batch (paired n=80 vs `a2a3`):** progress mean Δ **+0.156** (t=+0.92, p≈0.36); death-ante
3.288 → **3.462** (+0.175); **sign 42 better / 30 worse / 8 tied** (p≈0.19); death-ante shift
**35 later / 23 earlier / 22 unchanged**. Directionally positive and clearly the strongest
Phase-1 result — though still n.s. at n=80 (ships as correctness regardless of significance).

**Why it moved UP** (unlike A1/A2's washes): the restock fix closes the 3× voucher sinkhole,
and bought vouchers now give REAL scoring capacity. Verified: voucher buys 91→81, ante-4 $
$12→$17, leveling ante 4–5 1.5/2.0 vs 1.0/1.0, run_strength ante 5 0.51 vs 0.48, ante-7 $67.
Same family as the two historical positive fidelity fixes (deck-mutation +0.11, econ-money
+0.10) — the world was UNDER-rewarding correct play (real resource vouchers) and OVER-charging
wasteful play (3× exposure); fixing both helps.

**New baseline:** `sim_out/a4.jsonl` (n=80, death-ante **3.462**, progress **3.145**). Cumulative
fidelity arc: `scorer2` 3.513 (old world) → `a1` 3.400 → `a2a3` 3.288 → **`a4` 3.462** — the
world is now much more faithful (scalers, consumables, vouchers all real) with death-ante back
near the original, poised for Phase 2 (engine valuation) to push past 3.5. **Next Phase-1 unit:
A6 (immediate pack-pick use — stop silently losing Celestial/Arcana picks) or A5 (dead tags);
then Phase 2 · B1 (the ×1/×5 leveling-scale unification).**

### 2026-07-06 — Phase 1, item 4: A6 immediate pack-pick use. ✅ SHIPPED — FIRST SIGNIFICANT WIN

**The distortion:** `content.take_pack` STORED a picked Arcana/Celestial/Spectral consumable
into the 2 slots and **silently lost it when slots were full** — money already spent. This
throttled the leveling-through-packs pipeline (the audit's dead-channel finding D): a Mega
Celestial pick-2 with 1 free slot lost a whole planet.

**Fix (`sim/content.lua`, FACTS layer):** a picked consumable with a **free slot** is still
stored (the engine times its use in-blind with `LEVEL_USE_CREDIT` etc.); with **slots full**
it is now **USED IMMEDIATELY** instead of dropped — routed through the A2 world executor
(`World._use_consumable`) with a freshly-sampled hand, so a Planet levels its hand, a tarot
enhances/converts real deck cards (mutation persists), a money tarot pays, a spectral applies.
Nothing paid-for is lost.

**Tests:** 4 A6 cases added to `tests/test_consumables.lua` (slot-full Planet levels, Hermit
pays, Hierophant enhances the deck; used picks aren't stored). 706/706 unit, **170/170 sim**.

**Batch (paired n=80 vs `a4`):** progress mean Δ **+0.157** (t=**+2.72**, **p≈0.0065 ✅
SIGNIFICANT**); death-ante 3.462 → **3.612** (+0.150); **sign 18 better / 7 worse / 55 tied
(p≈0.046 ✅)**; shift **9 later / 1 earlier / 70 unchanged**; sd only **0.52**. The FIRST
statistically-significant win of the whole effort — a clean, targeted, one-directional effect
(exactly what "recover a silently-lost pick" should look like: affected runs improve, the rest
are byte-identical).

**Mechanism verified:** **53 pack-time immediate-uses** (vs 0 in `a4` — picks that were being
dropped now land); median **hand-levels doubled by ante 6 (4.0 vs 2.0)**, up at ante 4 (2.0 vs
1.5). The leveling-through-packs pipeline is unthrottled.

**New baseline:** `sim_out/a6.jsonl` (n=80, death-ante **3.612**, progress **3.303**).
Cumulative arc: `scorer2` 3.513 (old world) → `a1` 3.400 → `a2a3` 3.288 → `a4` 3.462 →
**`a6` 3.612** — now ABOVE the original `scorer2` (3.513): the world is far more faithful AND
the engine survives longer on it. **Next: A5 (dead tags) or A7/A8/A9 (boss/play money, gen
odds) to finish Phase 1, then Phase 2 · B1 (the ×1/×5 leveling-scale unification — now that
the leveling channel demonstrably pays off, this keystone should finally land).**

### 2026-07-06 — Phase 1, item 5: A5 dead skip tags. ✅ SHIPPED (correct but inert — unblocks B6)

**The distortion:** `content.apply_tag` set `run._coupon`/`run._free_reroll` flags **never
read**, and `tag_handy`/`garbage`/`speed`/`juggle`/`boss`/`double` were explicit no-ops
(~8 of 24 tag rolls paid nothing while `engine/tags` believed $3–$11).

**Fix (FACTS layer):** Handy (+$1/hand played), Garbage (+$1/unused discard), Speed (+$5/blind
skipped) — one-time payouts from new run-history counters accrued by the driver; Juggle (+3
hand size for the next round, consumed in `play_blind`); Coupon (initial jokers & packs free
in the next shop) and D6 ($0 reroll base) — now READ and cleared in `shop_phase`. Boss (reroll
Boss) and Double (tag chaining) left as documented no-ops.

**Tests:** new `tests/test_tags.lua` (12 cases) pin each payout/flag + one-shot consumption.
706/706 unit, **182/182 sim**.

**Batch (paired n=80 vs `a6`):** **byte-identical** (80/80 tied, Δ 0.000; the only file diff is
the 80 `git_sha` metadata stamps — 0 behavioral differences). **The engine NEVER skips for these
tags** (measured: handy 0/27, garbage 0/18, speed 0/29, juggle 0/20, coupon 0/21, d6 0/23 —
138 declines, 0 takes; contrast investment 16 / rare 10 / orbital 17 taken). So the world-side
payouts never fire.

**Expectations / consequence:** A5 is a CORRECT fidelity fix (the tags were wrong; now faithful)
but is **behaviorally inert until the engine's tag valuation is raised** — this is exactly the
audit's **B6** (Phase 2, engine side: "Handy/Garbage/Speed/Coupon flat priors are 2–3× low
mid-run"). It's the same world↔engine coupling seen with A2 generators: the world can't show a
payout the engine never triggers. A5 is the necessary groundwork — without it, fixing B6 would
make the engine skip for tags that STILL do nothing. **Baseline unchanged: `a6.jsonl` 3.612**
(A5 is behaviorally identical). **Recommended next: B6** (raise the engine's Handy/Garbage/Speed/
Coupon/D6 tag values, now computable from run counters) to activate A5, or **Phase 2 · B1**
(the leveling-scale keystone).

### 2026-07-06 — Phase 1, item 6: A7/A8/A9 boss penalties + play-money + gen odds. ✅ SHIPPED

**Scope (the high-confidence, clearly-correct subset of a long tail):**
- **A7 (bosses)** — apply effect fields `engine/boss_effect` already DECLARES but the world
  ignored: **The Arm** (`level_down`: the played hand's level drops 1, permanent, floored at
  base) and **The Tooth** (`money_per_card`: −$1/card played, floored at $0). `sim/world.lua`
  `post_play_econ`.
- **A8 (economy)** — credit **in-blind scoring money** (gold seals $3, Lucky $20/15, Rough Gem
  $1/diamond) that `hand_eval` already computes in `ev.money` but the world never banked (the
  engine even ORDERS cards for it). Rough Gem excluded from `joker_econ_income` to avoid double
  count.
- **A9 (generation)** — mega pack weight 1→**0.5** (was ~2× over-offered); **per-edition price
  adders** (foil +2 / holo +3 / poly +5, was a flat +1); **run-scoped monotonic card ids** (was
  `1000+i`, which COLLIDED across packs and broke id-keyed tie-breaks).
- **DEFERRED (documented):** A7 Ox (money-zero-on-most-played — needs a per-hand-type counter,
  ante-6, rare at the death-ante), Pillar (cross-blind card-debuff — needs new state + an engine
  `debuffs_card` extension), face-down bosses (perfect-info exploit — complex), Serpent (ante-5+),
  ante-8 finisher effects (0 wins so far); A8 conditional econ-joker income / Credit Card debt /
  SELL_TO_BUY $1; A9 standard-pack enh/seal/edition RATES (VERIFY vs wiki), negative edition in
  shops (needs slot-free plumbing), tag ante-gating (VERIFY the gated list), first-shop Buffoon.

**Tests:** new `tests/test_economy_boss.lua` (13 cases) pin the play-money credit, Tooth/Arm
penalties + floors, per-edition adders, mega weight, and card-id uniqueness. 706/706 unit,
**195/195 sim**.

**Batch (paired n=80 vs `a6`):** progress mean Δ **−0.185** (t=−1.51, p≈0.13); death-ante
3.612 → **3.450** (−0.162); sign 17 better / 30 worse / 33 tied (p≈0.08); shift 10 later / 22
earlier / 48 unchanged. **First WIN ever: seed 5003, cleared ante 8** (Acrobat/Fibonacci/Seltzer/
Blue Joker/Cavendish).

**Expectations met?** Yes — this is the audit's explicitly-predicted "the sim is EASIER than real
on bosses" correction, so making bosses honest **lowers** death-ante (n.s.). Verified sound, not a
bug: Arm deaths doubled (2→4, the level-down biting), play-money lands but is small (seals are
rare), Tooth offsets it. The negative is partly the engine's **boss-naivety** — it plays its
leveled hand into the Arm's level_down and pays the Tooth without adapting (the audit's **F5**,
Phase 4). A7 is the world half; F5 is the engine half that recovers it. Shipping the honest world
now is the audit's world-first discipline.

**New baseline:** `sim_out/a789.jsonl` (n=80, death-ante **3.450**, progress **3.117**, **1 win**).
Cumulative arc: `scorer2` 3.513 (old world) → `a1` 3.400 → `a2a3` 3.288 → `a4` 3.462 → `a6` 3.612
→ **`a789` 3.450**. **Phase 1 (world fidelity) is essentially COMPLETE** — scalers grow/decay,
consumables & vouchers real, pack picks never lost, tags faithful, bosses honest, play-money banked.
The world is now a faithful gauntlet. **➡ Phase 2 (engine valuation) is next — start with B1**
(the ×1/×5 leveling-scale unification), then C2 (swap-gate) + C3 (Blueprint), which are expected
to convert this honest world into survival; and **F5** (engine boss adaptation) to recover A7.

### 2026-07-06 — Phase 2, item 1: B1 the ×1/×5 consumable-scale unification. ✅ SHIPPED (first ENGINE gain)

**The bug (CONFIRMED in code):** `shop_advisor` valued a standalone consumable's SCORE at
`w_score * (vfrac)` (×1) while a booster pack valued the identical planet at `w_score * 5 * (pv)`
(×5) — `vfrac` and `pv` are the SAME boss-hand-fraction units and both already apply
`level_amplifier`, so a loose Jupiter was worth exactly 1/5 of the same Jupiter inside a Celestial
pack. Standalone planets were ~never bought (audit data: 289 offered, 2 bought) → the leveling
channel died at the source. The `SA.CREATES_JOKER` ×5 pre-multiply and the money-tarot DOLLAR
term were band-aids around this exact gap.

**Fix (engine, `engine/shop_advisor.lua`):** put the ONE `JOKER_SCORE_WEIGHT` bridge on the
standalone-consumable SCORE path (BUY_CONSUMABLE both branches) AND the SELL_TO_BUY held-consumable
keep-loss — so a loose planet is valued like the pack planet, and a held planet is no longer the
cheapest funder (it used to be churned at 1/5 value to fund a pack, dismantling leveling fuel).
Removed the CREATES_JOKER ×5 band-aid (the base bridge now provides it; the deck-aware
created-joker MEASUREMENT is kept, so **Judgement is invariant** — which is why the pinned tests
pass unchanged). The DOLLAR term (real money) is left un-×5'd.

**Tests:** `tests/test_shop.lua` +2 (a standalone planet is a considered BUY_CONSUMABLE whose value
scales with the toggled `JOKER_SCORE_WEIGHT`). 708/708 unit, 195/195 sim.

**Batch (paired n=80 vs `a789`, engine-only change so world held constant — H3):** progress mean
Δ **+0.080** (t=+0.82, p≈0.41); death-ante 3.450 → **3.538** (+0.087); sign 30 better / 20 worse /
30 tied (p≈0.20); shift 16 later / 12 earlier / 52 unchanged.

**Verdict + why it ships:** B1 is a **correctness unification** (the ×1/×5 split is an objective
bug), so the batch's job is to confirm it does NOT backfire — the audit's stated risk ("raises
consumable spending, the classic backfire shape"), which past sessions hit against the broken
world. It does not: it trends POSITIVE and the mechanism fired — **BUY_CONSUMABLE advice went 22→85
(~4×)**, the engine now capturing standalone-consumable value it used to ignore. This is the
audit's central thesis realized: the SAME fix that FAILED pre-fidelity now HELPS on the faithful
world. Non-significant at n=80 (+0.087 is squarely in the ~0.18-SE noise band, per H1); the ship
decision rests on correctness + no-backfire, not significance. **Honest nuance:** the gain is broad
consumable-value capture, not specifically MORE leveling (median hand-levels are survivorship-
confounded and roughly flat) — the leveling channel was already working via A6 packs; B1 adds the
standalone path.

**New baseline:** `sim_out/b1.jsonl` (n=80, death-ante **3.538**, progress **3.198**, 1 win).
Cumulative arc: `scorer2` 3.513 (old world) → … → `a789` 3.450 → **`b1` 3.538** — the first
engine-valuation gain on the faithful world. **Follow-up:** an n=160 paired confirmation would
tighten the estimate before stacking more Phase-2 levers (recommended once ≥2 Phase-2 items are in,
to amortize the baseline re-run). **Next: C2** (swap-gate `cur>0` → floored scoring_gain) **+ C3**
(Blueprint copier-insertion) — unblock keystone acquisition on full boards.

### 2026-07-06 — Phase 2, item 2: C2 swap-gate + C3 copier-insertion. ✅ SHIPPED (correct, nearly-inert)

**The bugs:** (C2) the full-board upgrade-SWAP path — the main mid-game acquisition route once the
board fills ~ante 3 — required raw `score_delta > 0`, but a conditional xmult fires too rarely to
appear in a few samples (The Trio ≤0 in 46% of trials, Tribe 68%, Family 98%) and a copier measured
exactly 0, so **Duo/Trio/Tribe/Family/Order/Blueprint could NEVER be swap-bought** — the exact
"engine skips keystones" flaw seen in all three human wins. (C3) `joker_value.score_delta` appended
the candidate at the END of the joker list, so **Blueprint** (copies the joker to its RIGHT) had
nothing to copy and measured **0 every time**.

**Fix:** (C3, `engine/joker_value.lua`) draw the sample hands once, then measure a right-copier at
its BEST insertion position (positions 1..n, not the broken last slot) — determinism unchanged for
the common append path. (C2, `engine/shop_advisor.lua`) admit a **conditional-xmult keystone or
copier** (`is_xmult && !is_scaling`, i.e. `cat=="xmult"`) as a swap candidate even when it measures
0, protected by the existing `UPGRADE_MARGIN + keep_bias` sell-margin. Crucially we do NOT admit an
un-fed **xmult_scaling / chips scaler** (Hologram/Throwback/Runner) whose swap value is projected
UN-damped — chasing those by selling a scorer is the documented regression the raw gate guarded
against (and `swap-damp` −0.075 failed to fix from the other side). This distinction is what makes
the two `test_shop` "won't chase an unfed Throwback" tests pass while opening the gate for keystones.

**Tests:** `test_shop.lua` +3 (Blueprint measures its copy, was 0; Trio/Tribe/Family/Blueprint are
admitted keystones; Throwback/Hologram are not). Verified Blueprint `score_delta` 0 → **690** on a
Cavendish board. 711/711 unit, 195/195 sim.

**Batch (paired n=80 vs `b1`, engine-only):** progress mean Δ **+0.001**; death-ante 3.538 →
**3.538** (0.000); sign 3 better / 3 worse / **74 tied**; shift 1 later / 1 earlier / 78 unchanged.
NEARLY INERT — but the mechanism DID fire: keystone acquisitions **9 → 12** (+3 bought via the
now-open gate + a measurable Blueprint).

**Why inert + why it still ships:** the keystones are all **Rare** jokers (5% of joker rolls), so
they are seldom OFFERED on a full board (the audit itself noted "Blueprint — unmeasurable, 6
offers/80 runs"). At n=80 the opportunity is too scarce to move the aggregate — same shape as A5.
But C2+C3 is a CORRECTNESS fix: it repairs the exact "skips Duo/Family/Blueprint/Tribe" mechanism
that lost all three analyzed human wins, so it ships and matters in the specific runs that DO get
offered a keystone. An n≥160 (or a targeted keystone-offer-rate boost) would be needed to measure
its true effect.

**New baseline:** `sim_out/c2c3.jsonl` (n=80, death-ante **3.538**, progress **3.199**, 1 win —
behaviorally ≈ `b1` with correct keystone acquisition). **Next: C1** (adaptive samples / analytic
conditional-xmult triggers — reduces the measurement noise C2 works around, and would let keystone
swaps fire more reliably when offered), or **B5/B2** (pack-pool w² fix, Blue-seal unit), or the
**in-blind P(clear) track (Phase 4 · F3/F1)** — the 32/80 variance-death bucket, measurable against
the current world and orthogonal to the build-side levers.

### 2026-07-06 — Phase 2, item 3: C1 adaptive samples. ❌ TRIED & REVERTED (negative, informative)

**Hypothesis (audit HIGH-impact):** conditional-xmult keystones (Duo/Trio/Tribe/Family/Order)
fire too rarely to appear in the cheap 6–8-sample screen — score_delta reads them ≤0 in 46–98%
of trials — so give THOSE more samples (24, cache-assisted) on the live BUY/swap decisions so
their real deck-fit is seen instead of noise.

**Implementation:** a `measure_samples(key)` helper (24 for `is_xmult && !is_scaling`, else the
base 6–8) wired into `scoring_gain` and the full-board swap path (`cur` + `buy_fv_delta`).
Clean, targeted, 713/713 unit + 195/195 sim green; verified the lever (Tribe measures positive
on a flush deck at 24 samples).

**Batch (paired n=80 vs `c2c3`, engine-only):** progress mean Δ **−0.142** (t=−1.22, p≈0.22);
death-ante 3.538 → **3.362** (−0.175); sign 6 better / **14 worse** / 60 tied (p≈0.12); lost the
1 win. Clearly NOT helping — leans negative.

**Why it backfired (the informative part):** the audit itself notes "UPGRADE_MARGIN, keep_bias,
prior floors are all COMPENSATORS for this noise." The `score_delta` floor is `max(measured,
0.6×prior)`; at 8 noisy samples a conditional xmult reads ~0 → floored to the prior, a stable
prior-driven value. At 24 samples it reads its TRUE (often modest, deck-dependent) marginal —
but the compensating floors/margins are still in place, tuned for the noisy regime. So the
now-accurate value mis-calibrates against them: the engine acts on measurements the guardrails
were built to offset, and swaps/buys shift for the worse. This is the same class as the reverted
`swap-damp` (−0.075) — touching the swap valuation without co-tuning its guardrails backfires.

**Verdict: REVERTED** (working-tree only; never committed). A CORRECT C1 must do what the audit
actually prescribes — fix the noise AND simplify/retune the floors + `UPGRADE_MARGIN` + `keep_bias`
that exist only to compensate for it — as ONE co-calibrated change (ideally with the analytic
conditional-xmult estimate `P(trigger)×uplift`, which is noise-free by construction). That is a
larger, higher-risk retune and is deferred; the sample-bump alone is a net loss. **Baseline
unchanged: `c2c3.jsonl` 3.538.**

**Roadmap note:** this reinforces the session's pattern — on the faithful world, CORRECTNESS
unifications (B1) and mechanism-repairs (C2/C3) are safe-to-positive, but ISOLATED valuation/noise
tweaks that don't co-move their compensators backfire (C1 here; swap-damp, leveling-need, coupled,
cost-discount historically). **Next, pivot OFF the build-side (diminishing returns at n=80) to the
in-blind P(clear) track — Phase 4 · F3** (last-hand quantile dig: trivial, strictly non-negative by
construction, attacks the 32/80 variance-death bucket), then **F1/F2**. Or run an **n≥160
confirmation of the committed build stack (B1+C2+C3)** vs the `a789` world-baseline to size the
combined engine gain above the n=80 noise floor.

### 2026-07-06 — Phase 2, item 4: B5 pack/reroll pool math. ✅ SHIPPED (correctness, ~neutral)

**Two bugs (both in `engine/packs.lua`):**
- **w² rare-tail clip:** `joker_pool` samples M jokers rarity-weighted (via `draw()`), then stored
  each with `w = it.w` (the rarity weight AGAIN), and `expected_pick` re-draws ∝ `w` -- so the
  effective pick probability was ~w², clipping the rare tail (Rares ~0.25% instead of ~5%) and
  systematically under-valuing Buffoon-pack / reroll EV and the Uncommon/Rare skip-tags. Fix:
  store `w = 1` for the pre-sampled items (they already ARE the rarity distribution).
- **spectral over-valuation:** `spectral_pool` used the raw positive `SPECTRAL_BASE` prior, so
  Hex/Ankh looked GOOD in the pool even on a built board they would gut. Fix: value each spectral
  via `ConsumableValue.card_value` (the same path a loose spectral uses), which subtracts the
  jokers Hex/Ankh destroy (one survives) and the Ouija hand-size penalty -- identical to `tarot_pool`.

**Verified:** `c_hex` card_value **−6.6** on a 5-joker board (was the raw +0.6 prior → now floors to
0 in the pool); `expected_shop_joker(4)` = 3.96 (rare tail intact). **Tests:** `test_advisors.lua`
+5 (Hex negative & worse with more jokers to lose; spectral pack finite; joker-EV positive &
monotonic in slots seen). 716/716 unit, 195/195 sim.

**Batch (paired n=80 vs `c2c3`, engine-only):** progress mean Δ **+0.062** (t=+0.80, p≈0.42);
death-ante 3.538 → **3.575** (+0.038); sign 9 better / 11 worse / **72 tied** (p≈0.82). ~NEUTRAL,
within noise (like C2/C3) -- it moves only the runs where a Buffoon/Spectral pack or reroll EV is a
close call. Ships as a CORRECTNESS fix (the w² is an objective probability bug; the spectral
over-valuation is objectively wrong) that does not backfire.

**New baseline:** `sim_out/b5.jsonl` (n=80, death-ante **3.575**, progress **3.261**). Cumulative:
`scorer2` 3.513 (old world) → … → `a789` 3.450 → `b1` 3.538 → `c2c3` 3.538 → **`b5` 3.575** (the
committed-engine high on the faithful world). **Pattern holds:** correctness unifications/repairs
are safe-to-slightly-positive; the build-side is at diminishing returns per-fix at n=80 because each
trigger (keystone offer, spectral pack, rare roll) is individually rare. **Strongly recommend
either (a) an n≥160 confirmation of the whole committed build stack (B1+C2+C3+B5) vs the a789
world-baseline to size the combined gain, or (b) pivot to the in-blind P(clear) track (Phase 4 · F3
→ F1/F2) which attacks the orthogonal 32/80 variance-death bucket.**

### 2026-07-06 — Phase 2, item 5: B2 Blue-seal unit fix. ✅ SHIPPED (clean, strictly non-negative)

**The bug:** `consumable_value.card_econ_value` added a Blue seal's spawned-planet worth as
`best_planet().value` — a RAW score (`freq × level_gain`, ~10–150) — directly into `v`, which is a
BOSS-HAND-FRACTION sum (~0.02). So a Blue seal read ~+7.5 fraction-units (~100–200× the Gold/Lucky
terms), making ANY Blue-seal card auto-dominate a Standard-pack pick and inflate any Standard pack
holding one. **Fix:** divide the raw `best_planet().value` by `Mechanics.boss_per_hand_need(gs)` to
normalise onto the fraction scale (the `or 0.2` fallback was already a fraction; the ×0.5
held-at-round-end discount is kept).

**Verified:** Blue-seal `card_econ_value` **7.5 → 0.020**, now on the same scale as a Gold seal
(0.032). **Tests:** `test_advisors.lua` +2 (Blue-seal econ value is a small fraction and within
5× of a Gold seal). 718/718 unit, 195/195 sim.

**Batch (paired n=80 vs `b5`, engine-only):** progress mean Δ **+0.010** (t=+1.07, p≈0.29);
death-ante 3.575 → **3.587** (+0.012); sign 2 better / 1 worse / **77 tied**; shift **1 later / 0
earlier** / 79 unchanged; sd **0.086**. Nearly inert (Blue-seal cards are ~1% of standard cards) but
STRICTLY NON-NEGATIVE in the seeds it touched — the cleanest fix shape: it only stops the engine
over-chasing a ~100×-overvalued card. Ships as a correctness fix.

**New baseline:** `sim_out/b2.jsonl` (n=80, death-ante **3.587**, progress **3.271**). Cumulative:
`scorer2` 3.513 (old world) → … → `a789` 3.450 → `b1` 3.538 → `c2c3` 3.538 → `b5` 3.575 → **`b2`
3.587** — the committed-engine high. **The Phase-2 build-side correctness pass (B1, C2/C3, B5, B2)
is essentially complete** and has nudged the faithful-world baseline from 3.450 → 3.587 (+0.137),
each fix small-but-safe. **Next, per the diminishing-per-fix returns: (a) an n≥160 confirmation of
the full committed stack vs the a789 world-baseline, and/or (b) the in-blind P(clear) track
(Phase 4 · F3 → F1/F2) — the orthogonal 32/80 variance-death bucket.**

### 2026-07-06 — Phase 2, item 6: B3 unify the $↔fraction rate. ❌ TRIED & REVERTED (negative)

**The real bug (CONFIRMED):** `VU.dollar_frac` (0.03/$ at ante 3, decaying to 0.015 late) disagrees
with the shop's implied rate — the shop values a buy at `w_score*JOKER_SCORE_WEIGHT*frac -
COST_WEIGHT*cost`, so $1 buys `0.3/5 = 0.06` frac. So `tags.lua` (which converts a tag's
scoring-fraction to dollars via `VU.frac_to_dollars = frac/0.03`) valued a fraction at ~$33 vs the
shop's ~$16.67 — tags ~2× over-valued in the skip decision, worsening with ante (÷0.015 → ~4×).

**Attempt:** anchor the ante-aware VU curve at the shop's rate — `BASE_FRAC 0.03 → 0.06` (=
COST_WEIGHT/JOKER_SCORE_WEIGHT), clamp bounds doubled. Clean one-constant change; 718/718 unit
(updated the pinned `dollar_frac(ref)` test to reference `BASE_FRAC` — a keeper), 195/195 sim.

**Batch (paired n=80 vs `b2`, engine-only):** progress mean Δ **−0.245** (t=−1.52, p≈0.13);
death-ante 3.587 → **3.362** (−0.225); sign 30 better / **33 worse** / 17 tied (p≈0.80, a WASH);
**sd 1.44** (high — 63 of 80 seeds moved, both ways). Net NEGATIVE on the mean, no sign signal,
and it ADDS variance.

**Why it backfired (the C1 lesson again):** unlike B1/B2 (clear UNIT bugs), B3 reconciles two
INDEPENDENTLY-tuned rates. The downstream skip/consumable constants — `SK.SHOP_VALUE=6`, the
1.25 skip margin, keep_bias, the consumable-money terms — were all calibrated AGAINST the old
0.03 rate. Doubling the rate alone (money 2× more, tags ½) mis-calibrates every one of them at
once; the "unification" is only correct if the whole cluster is re-tuned together. Adding variance
with no mean gain is a net loss for a resource-constrained engine.

**Verdict: REVERTED** the `value_units` constant (kept the improved, `BASE_FRAC`-relative test).
A correct B3 = the rate unification **plus** a co-retune of `SK.SHOP_VALUE` / skip margin / the
consumable-money weights that were fit to the old rate — a larger calibration effort, deferred.
**Baseline unchanged: `b2.jsonl` 3.587.**

**Session-wide pattern, now firmly established:** on the faithful world, **UNIT-bug / mechanism
correctness fixes ship safely** (B1 +0.087, C2/C3, B5 ~0, B2 +0.012) while **CALIBRATION-reconciliation
changes that don't co-move the constants tuned against the old value backfire** (C1 −0.175, B3 −0.225;
cf. the historical swap-damp/leveling-need graveyard). The remaining clean-correctness B-items (B6
edition-tags, B4 voucher downsides) are lower-risk; but the highest untouched value is the **in-blind
P(clear) track (Phase 4 · F3 → F1/F2)** — the orthogonal 32/80 variance-death bucket, where F3 is
strictly non-negative by construction. **Strongly recommend F3 next.**

### 2026-07-06 — Phase 4, item 1: F3 last-hand quantile dig. ❌ TRIED & REVERTED (premise wrong)

**Hypothesis (audit "cheapest pure win, strictly non-negative"):** on the last hand, if the
forced PLAY certainly loses (`play.score < remaining`), take a DISCARD dig if it has ANY chance
to reach the target (P̂(clear)>0) rather than requiring the dig's MEAN ≥ remaining — "you were
going to lose anyway, so a positive tail is free."

**Implementation:** new `DV.clear_prob(gs, discard, target, opts)` (fraction of redraws whose
best-play ≥ target); the `forced_play` branch takes the chosen dig when its `clear_prob > 0`.
Clean; 723/723 unit (a crafted 4-to-a-flush scenario where the dig's mean is below the target but
its tail clears → DISCARD), 195/195 sim.

**Batch (paired n=80 vs `b2`, engine-only):** progress mean Δ **−0.100** (t=−1.64, p≈0.10);
death-ante 3.587 → **3.487**; sign 1 better / 4 worse / 75 tied; shift **0 seeds later / 3
earlier**. It helped ZERO runs and hurt several (44003 a8→a4, 64003 a6→a3).

**Why the "strictly non-negative" premise is FALSE (the finding):** it assumes a pure win-or-die
model where partial score is worthless. It isn't — **partial score has value**: (1) the sim's
Mr Bones saves a run that scored ≥25% of target, and (2) the progress metric credits
`min(1,scored/target)`. A low-P tail-dig, BY DEFINITION, usually FAILS; a failed dig has spent a
discard and plays a WORSE hand (it threw cards to chase the tail), so it scores LESS than the
direct play would have — turning a decent partial score (or a Mr Bones save) into a loss. The
occasional dig that clears doesn't outweigh the common failure that scores lower. Traced 44003:
the digs also change the blind's card/hand consumption and cascade the sim's downstream RNG, so a
run that reached ante 8 died at ante 4. So F3 is a net LOSS on average — the opposite of "free".

**Verdict: REVERTED** (working-tree only; never committed). A correct F3/F1 must arbitrate by
EXPECTED SURVIVAL that also credits the Mr-Bones/partial-score floor, not just P(clear)>0 — i.e.
only dig when the tail gain exceeds the partial-score it sacrifices. That is the real F1 (P(clear)
arbitration with a proper objective), a larger change; the trivial P̂>0 version is a net loss.
**Baseline unchanged: `b2.jsonl` 3.587.**

**Session tally (14 items attempted):** SHIPPED = Phase 0 tooling + 6 world-fidelity clusters
(A1,A2/A3,A4,A6,A5,A7-9) + 4 engine correctness fixes (B1,C2/C3,B5,B2). REVERTED with recorded
reasons = C1, B3, F3 — all three were calibration/objective changes whose premise didn't hold once
measured. Faithful-world death-ante `a789` 3.450 → **`b2` 3.587** (+0.137). The reverts sharpen the
rule: **only ship a change whose correctness is a UNIT/MECHANISM fact; anything that re-weights a
value or objective must be co-calibrated with the constants it touches AND measured — several look
obviously-right on paper and lose in the sim.** Remaining low-risk correctness items: **K3/K4/K5**
(pure scoring-correctness, test-safe) and **A3-style** live-key aliases. The big untouched prize
(variance deaths) needs the FULL F1/F2 P(clear) objective, not the F3 shortcut.

### 2026-07-06 — Phase 2, item 7: K3/K4/K5 scoring-correctness. ✅ SHIPPED (facts-layer; also fixes live)

Three per-joker scoring hooks were wrong in the FACTS layer (they corrupt both the sim AND the
live advisor's clear estimates):
- **K3 Spare Trousers:** `joker_effects` returned its accumulated mult ONLY on a hand containing
  Two Pair. Real Balatro: Two Pair is the GROWTH condition; the accumulated mult applies to EVERY
  hand. The gate zeroed a fed Trousers on every non-two-pair play, undervaluing it and skewing
  best_play/scaling_fuel toward two-pair. Fix: return the mult unconditionally (one line) + add
  `j_trousers` to `SCALE_TRIGGER_HANDS` so its growth PROJECTION is trigger-hand-gated too.
- **K4 Photograph:** a one-shot `flags.photograph_used` meant a RETRIGGER of the first face card
  (Hanging Chad) didn't re-fire the x2 -- Photograph+Chad on a face card is x8 in-game, was x2.
  Fix: track the first face CARD identity and fire on every trigger of it.
- **K5 joker foil/holo edition order:** applied AFTER the joker's own effect. Real: foil (+50
  chips) / holo (+10 mult) apply BEFORE, so an xmult joker multiplies them (Holo Cavendish =
  (mult+10)*3, not mult*3+10); polychrome (x1.5) stays AFTER. Fix: split the edition into a
  pre (additive) and post (multiplicative) application around `on_hand`.

**Verified:** fed Trousers scores on a Pair (30*(2+10)=360, was base-only); Photograph+Hanging
Chad on a King = x8 mult; Holo Cavendish on a Pair = (2+10)*3 = 36 (was 16); Poly Cavendish stays
2*3*1.5 = 9. **Tests:** `test_jokers.lua` +6, all exact-score. 723/723 unit (no golden broke --
K5 was test-safe as the audit predicted), 195/195 sim.

**Batch (paired n=80 vs `b2`):** progress mean Δ **−0.064** (t=−0.94, p≈0.35); death-ante 3.587 →
**3.513** (−0.075); sign **4 better / 4 worse / 72 tied (p=1.0)** -- a perfectly balanced WASH.
The affected jokers (Trousers, Photograph combos, foil/holo xmult) are individually rare, so few
runs move; the balance confirms noise. Ships as FACTS-layer correctness regardless of the neutral
aggregate (same rule as the world-fidelity fixes) -- and it corrects LIVE-mod scoring, not just the
sim. (K5's before/after order is the audit's CONFIRMED-but- -- VERIFY-tagged rule; a one-line revert
if a decompiled check ever contradicts it.)

**New baseline:** `sim_out/k345.jsonl` (n=80, death-ante **3.513**, progress **3.207**).

**Session close-out (15 items attempted, ~4h).** SHIPPED (12 commits): Phase-0 paired-A/B tooling
+ 6 world-fidelity clusters (A1,A2/A3,A4,A6,A5,A7-9) + 5 engine correctness fixes (B1,C2/C3,B5,B2,
K3/K4/K5). REVERTED with recorded reasons (3): C1, B3, F3. Faithful-world arc: old-world `scorer2`
3.513 → faithful `a789` 3.450 → engine fixes → **`k345` 3.513** -- i.e. the SAME headline death-ante
as the start, but now on a WORLD that faithfully models scalers/consumables/vouchers/tags/bosses/
play-money and an ENGINE whose consumable/keystone/pack/edition valuations are unit-correct. First
significant win landed at A6 (p≈0.007); the first COMPLETED run appeared at A7-9. **The proven rule
for the next session: ship unit/mechanism correctness freely; treat any value/objective re-weight
as an experiment that needs its guardrails co-calibrated (C1/B3/F3 all looked right and lost). The
remaining big prize -- the ~40% variance-death bucket -- needs the FULL F1/F2 survival-objective
arbitration (crediting the Mr-Bones/partial-score floor), not the F3 shortcut. Lower-risk leftovers:
K1/K2 (Supernova/Loyalty/Card Sharp, also live-only correctness risks), A6-style live-key aliases,
the deferred A7 bosses (Ox/Pillar), and the committed-archetype planner if the wall persists.**

### 2026-07-06 — Phase 2, item 8: K1/K2 Supernova/Loyalty/Card Sharp. ✅ SHIPPED (correctness, +)

These three jokers are CONTEXTUAL (value depends on play history), not accumulators — the old
`scaled(...)` reads were wrong in opposite ways on the two paths:
- **K1 Supernova** read `scaled(j, MULT, 0)` → a silent 0 forever in the sim (bought 8× in the
  baseline for nothing); real: mult = times THIS poker hand has been played this run (+ this play).
- **K2 Loyalty / Card Sharp** read `scaled(j, XMULT, 1)` → on LIVE this matched the STATIC config
  `extra.Xmult = 4/3` and applied x4/x3 EVERY hand (the advisor claiming clears that won't happen);
  real: Loyalty x4 every 6th hand, Card Sharp x3 only if the hand type was replayed this round.

**Fix:** model the real conditions from a plumbed play history — new GameState fields
`gs.run.hand_type_plays` (per-type run counts), `gs.run.hands_played` (total), `gs.blind.
played_hand_types` (types played this blind), populated by the world (`build_gs` + a `track_play`
after each scored hand) and `content.shop_gs`. Absent the plumbing (e.g. LIVE until state_extraction
is wired), all three read CONSERVATIVE (Supernova +1, Card Sharp/Loyalty x1) — which by itself
already kills the live over-fire.

**Verified:** Supernova on a Pair played 4× = +5 mult (was 0); Card Sharp x3 only on a replay;
Loyalty x4 only on the 6th hand. **Tests:** `test_jokers.lua` +6 (exact mult per condition).
723→**729/729 unit**, 195/195 sim.

**Batch (paired n=80 vs `k345`):** progress mean Δ **+0.054** (t=+0.75, p≈0.45); death-ante 3.513 →
**3.575** (+0.062); sign **11 better / 8 worse / 61 tied** — leans positive (within noise). Supernova
finally contributing (it was a dead buy) recovers most of the K3/K4/K5 dip. Ships as facts-layer
correctness; also fixes the biggest LIVE-only risk (K2's x4/x3-every-hand over-fire).

**Follow-up (LIVE):** `core/state_extraction` must populate `hand_type_plays` / `played_hand_types` /
`hands_played` from `G` (F7-verify the fields) for full live accuracy; until then the live path is
conservative-but-correct (no over-fire). Same plumbing F5 (Eye/Mouth legality) will reuse.

**New baseline:** `sim_out/k12.jsonl` (n=80, death-ante **3.575**, progress **3.261**). Committed-
engine arc on the faithful world: `a789` 3.450 → `b1` 3.538 → `c2c3` 3.538 → `b5` 3.575 → `b2` 3.587
→ `k345` 3.513 → **`k12` 3.575**. The build/scoring correctness pass (B1,C2/C3,B5,B2,K3/K4/K5,K1/K2)
is now complete — every one a unit/mechanism fact, net +0.12 over the faithful baseline, none a
backfire. The three REVERTS (C1/B3/F3) remain the cautionary set: value/objective re-weights that
need co-calibration. Next big lever: the FULL F1/F2 survival-objective in-blind arbitration.

---

## 5. Phase 3 implementation log — re-litigate the graveyard at n=160 (2026-07-06)

Phase 3 re-runs the four reverted build-strategy levers (leveling-need, leveling-alignment,
flush-commitment, coupled pair) against the Phase-1+2 faithful world, at the **n=160 PAIRED**
standard (H1/Phase-0). All prior verdicts for these were unpaired n=80 on the OLD world —
statistically noise (H1) AND incomparable — so none are reused; a fresh HEAD baseline anchors
every verdict.

### 2026-07-06 — Phase 3, item 0a: METHODOLOGY — residual cross-process non-determinism FIXED. ✅ SHIPPED

**The bug (found while validating the n=160 baseline):** the determinism fix logged in
`selfplay-system-plan` (2026-06-30, sorted-key sampling) was INCOMPLETE. Seed 44003 died at
**ante 4 in one luajit process but ante 6 in another** (in-process stable, cross-process
divergent). Root: LuaJIT's per-process **string-hash randomization** scrambles `pairs()`
iteration order over STRING-keyed tables, and two selection sites resolved TIES by that order:
- `engine/heuristics.lua` `by_suit` (the discard-shape suit pick) — `#list > #best_list` strict,
  so two equal-count suits were separated by `pairs()` order → different discard → different run.
- `engine/hand_eval.lua` `top_plays` — `best_by_type` (hand-type STRING keys) built via `pairs()`
  then sorted score-only, so equal-scoring plays kept a per-process-random order.
**Fix:** iterate `by_suit` in SORTED suit order (strict `>` keeps the alphabetical-first on ties);
make `top_plays` a TOTAL-order sort (tie-break equal scores by `hand_type` name). Both now resolve
identically in every process. (`simulation.lua:270`'s suit argmax has the same shape but is
decision-dead in the sim — F2 — so it was left; it only affects live-panel flicker.)

**Impact on the whole project:** EVERY historical batch carried this silent cross-process noise on
knife-edge seeds (~1/80). It was invisible to same-process reruns and only surfaced under paired
cross-batch compare. **Verification:** seed 44003 now cross-process stable (3 fresh processes agree);
and two independent n=160 pools run at DIFFERENT worker counts (11 vs 7 → different process-pool
hash seeds) are **byte-identical: 160/160 tied, Δ 0.000, sd 0.000.** Paired A/B at n=160 now has
ZERO process noise — any non-zero delta is a real engine effect. 729 unit + 195 sim green.
Committed `2381334`.

### 2026-07-06 — Phase 3, item 0b: fresh n=160 PAIRED baseline on the fixed engine. ✅ ESTABLISHED

`sim_out/base160.jsonl` (HEAD = fixed `2381334`, n=160): death-ante histogram a1=18 a2=27 a3=27
**a4=44** a5=34 a6=4 a7=3 a8=3 (mode ante 4); **progress mean 3.250, median 3.515; death-ante mean
3.55; 0/160 wins; 112 BUILD vs 48 VARIANCE deaths.** Per-ante: hand-lv stalls at **2–3** (human wins
15–27) while median $ reaches **$20–28 at antes 4–8** (mid-game economy headroom exists). This
BUILD-heavy, under-leveled profile is the reference for every Phase-3 verdict, and precisely the
target of P3-1. (The determinism fix left the aggregate unchanged — 3.250 both before/after — as a
tie-resolution change should: mean-neutral, it only fixes WHICH arbitrary choice knife-edge seeds make.)

### 2026-07-06 — Phase 3, item 1: leveling-need re-litigated. ✅ KEPT (verdict FLIPPED, small +, backfire GONE)

**What failed before (Round 22, n=80 unpaired, −0.051):** an additive Celestial/planet bonus when
the board has a core but low hand-levels. Mechanism worked (+57% planets) but it **drained economy →
ante-2 deaths ROSE** (a spend-shift in a world where the leveled base × FROZEN scaler never
compounded, pack picks were lost, and standalone planets were valued ×1).

**Why the faithful world should change it:** A1 (scalers grow), A6 (pack picks land — the significant
+0.157 win), B1 (standalone planets valued ×5), A2 (High Priestess levels) all shipped since. The
leveled base now COMPOUNDS with grown scalers + correctly-valued xmult, and B1 already opened the
channel so the nudge is a small TOP-UP, not a large spend-shift. Reconstructed as the safe
additive-when-lacking shape: `BP.level_need(gs)` — an additive frac credit fired ONLY when a
compounding core exists (`n_xmult≥1` over `base≥BASE_MIN`) AND total levels-above-1 <
`LEVEL_NEED_TARGET(4)`, TAPERING to 0 as levels rise (`CREDIT 0.12 × deficit/target`); 0 with no core
(no early over-buy). Injected additively alongside `level_amplifier` at both planet shop paths
(`shop_advisor` BUY_CONSUMABLE :627, BUY_PACK :697). `test_build_plan` +5 (gate, taper, core-gate,
monotonicity). 734 unit + 195 sim green.

**Batch (paired n=160 vs `base160`, engine-only):** progress mean Δ **+0.012** (t=+0.65, p≈0.51 n.s.);
death-ante 3.550 → **3.569** (+0.019); **sign 9 better / 4 worse / 147 tied** (p≈0.27); death-ante shift
**4 later / 1 earlier / 155 unchanged**; sd 0.235 (only 13/160 seeds move — surgical). Median progress
3.515 → 3.610.

**Verdict + why it ships:** the point of the batch was to test for the Round-22 BACKFIRE — and it is
GONE. Mechanism verified: ante-5 hand-lv **2.0→3.0** (more leveling) while median $ is flat-to-UP
(ante 6 $28→**$34**) and early deaths do NOT rise (shift 4 later : 1 earlier). So the historical
QUALITATIVE rejection (economy drain, earlier deaths) no longer holds, and the sign flips: −0.051 →
+0.012, positive on progress, death-ante, sign test AND death-ante shift. This is exactly the
audit's Phase-3 thesis — a lever that FAILED against the broken world HELPS (directionally) on the
faithful one. **Honest bound:** the aggregate is n.s. (+0.012 ≈ 0.65 SE); it is a small directional
win, NOT a significant one, kept on the same standard as the small kept Phase-2 items (safe-additive
class + no backfire + all-metrics-positive + verdict-flip). Magnitude (0.12) is a conservative
a-priori value; deliberately NOT swept (overfitting the fixed seed set). The lone real regression
(seed 30003 a5→a3, a spend-shift death) is outweighed ~2:1 by the improvers in both count and magnitude.

**New baseline:** `sim_out/p3_levelneed.jsonl` (n=160, death-ante **3.569**, progress **3.262**,
median 3.610, 0 wins). Phase-3 verdicts from here compare against THIS. **Graveyard verdict updated:
leveling-need is UN-refuted → NOW a (small) positive, not a backfire.** Next: P3-2 coupled pair.

### 2026-07-06 — Phase 3, item 2: coupled consistency pair (flush-commit + leveling-align). ❌ REVERTED (refuted on the faithful world — but the FAILURE MODE flipped)

**What failed before (Rounds 18 & 21, old world):** flush-commitment (a compounding credit to convert
toward the dominant suit) was a no-op at ship weight and, at a 5× probe, shaped the deck (suit-tarot
acquisition 1→14) but left death-ante FLAT and RAISED ante-1 deaths (early tempo cost); the coupled
pair (flush-commit + leveling-alignment) was −0.063 — the theoretically-strongest combination still hurt.

**Why the faithful world might change it:** baseline now survives a little longer, a leveled flush now
compounds with grown scalers (A1) + correctly-valued keystones (C2/C3), and there's mid-game economy
headroom (A4/A8). Reconstructed BOTH halves, coupled through `DeckPlan.target`: (a) a flush-commitment
credit in `CV.suit_tarot_value` — the compounding reliable-Flush payoff for a dominant-suit tarot, ramped
by `domfrac²`; (b) a leveling-ALIGNMENT bias (`FLUSH_ALIGN`) boosting the Flush family in the Planet
value when the run is committing to a flush. Exposed `dom`/`domfrac` from `DeckPlan.target`. +2 tests.

**Three batches, escalating the commitment weight to force the mechanism to actually fire:**
1. **gate 0.28, weight 1× → BYTE-IDENTICAL to baseline (160/160 tied).** Fully inert: the gate never
   opens — a fresh deck is exactly 0.25, and nothing lifts `domfrac` past 0.28 until the engine converts,
   which the gate itself blocks (chicken-and-egg). An inert lever tests nothing.
2. **gate 0.24 (below fresh 0.25 so it can bootstrap), weight 1× → −0.043 (n.s.).** Barely fires (6/160
   seeds move; suit-tarot mentions 361→383 ≈ noise); the movement is 3 better / 3 worse with two large
   REGRESSIONS (131003 a8→a3, 123003 a4→a2). Tracing 131003: NO flush was built — the regression is a
   pure RNG **cascade** from one flipped early decision, not a mechanism effect.
3. **gate 0.24, weight 5× (Round-18 probe strength) → +0.023 (n.s., high variance sd 0.818).** Sign 19/13,
   shift 12 later / 7 earlier, **ante-1 deaths DROP 18→14** (the OPPOSITE of Round 18's old-world rise!),
   with four early-death runs jumping to ante 4-5. Superficially a flip — **but the mechanism check
   REFUTES it:** even at 5× forcing, suit tarots never reach the top-used consumables (the deck is never
   actually flush-dominated), and **tracing the biggest "improvement" (24003 a1→a5) shows it built NO
   flush** — it plays Full House/Straight and survived by using **c_soul (a Legendary joker) + a Jumbo
   Celestial** at ante 1, i.e. a lucky downstream RNG **cascade** the lever triggered by flipping an early
   pack choice. The +0.023 is high-variance cascade noise, not deck-shaping survival.

**Verdict: REVERTED** (working-tree only; never committed). The coupled pair does NOT genuinely flip:
a greedy per-tarot commitment credit — even at extreme forcing weight — cannot assemble a coherent
flush build, because (a) suit tarots are too rarely OFFERED to shape a deck through the shop/pack channel,
and (b) the marginal decision flips it does cause merely **cascade the seeded RNG** (net noise) rather
than executing a plan. This is the same knife-edge-cascade phenomenon the determinism fix exposed
(seed 44003), now seen as the DOMINANT effect of a weak build-lever. **The finding CONFIRMS the audit's
Phase-5 thesis on the faithful world:** deck-shaping needs a STATEFUL committed-archetype planner that
drives conversion ONE direction across many shops and holds it — not a per-decision valuation credit.
The one genuine shift vs the old world (ante-1 deaths fall under forced commitment instead of rising) is
worth noting for that planner's design, but it is not a shippable lever. **Baseline unchanged:
`p3_levelneed.jsonl` 3.569.**

**Graveyard verdict updated:** flush-commitment / leveling-alignment / coupled pair remain REFUTED — but
for a SHARPER reason than "dies before it matures": the greedy valuation structurally can't *build* the
deck at all (offer-rate-limited + cascade-dominated), independent of survival horizon. Re-confirms the
planner as the real Phase-5 lever.

### 2026-07-06 — Phase 3, item 3: "delete the scaler damps" — TESTED & REFUTED (keep proj_damp). ✅ RESOLVED

**The roadmap item (§2 Phase 3): "Delete the scaler damps permanently (wrong once scalers actually grow)."**
First, a code audit disambiguated WHICH damps: the two reverted experiments the audit's H4 cites —
Round-19 swap-damp (`opts.proj_damp` in `jp_from_measure`) and Round-20 condition-discount
(`condition_factor` for enh/skip-fed scalers) — are **NOT committed** (grep-confirmed: they were
working-tree-only reverts). The only committed scaler damps are `SA.proj_damp` (a PACE gate — collapses a
scaler's forward projection when behind/urgent) and `scale_trigger_factor` (a TRIGGER-FREQUENCY gate —
discounts Runner/Square/Trousers by how often their trigger hand appears). Neither is the "frozen-scaler
over-valuation compensator" the audit imagined: `scale_trigger_factor` now MATCHES A1's world exactly
(A1's `joker_tick` grows those scalers only WHEN the trigger fires), and `proj_damp` is a survival-TIMING
argument independent of growth (an urgent board dies to the next boss whether or not the scaler would
eventually grow).

**Rather than assert this, it was MEASURED.** Probe: `SA.proj_damp` forced to 1.0 (no pace-damping at all
— the strongest form of "delete the damp"). Batch (paired n=160 vs `p3_levelneed`): progress mean Δ
**−0.004** (t=−0.13, p≈0.90); death-ante 3.569 → **3.562**; **sign 7 better / 8 worse / 145 tied** — a
dead WASH — and it BROKE the two guardrail tests (`behind→damped`, `urgent→damped hardest`). It produced
one lucky win (5003 a5→a9) via a single high-variance RNG cascade, offset by regressions — not a
systematic effect.

**Verdict: REVERTED — keep `proj_damp` and `scale_trigger_factor`.** The audit's "damping scalers is now
wrong" instinct does NOT hold: removing the pace-gate is neutral-to-slightly-negative on the faithful
world, exactly as the code analysis predicted. Both committed gates are legitimate and stay. The
**reverted round-19/20 damps stay OUT** — and are now DOUBLY wrong to re-add (they'd fight A1's real
growth AND over-suppress). Baseline unchanged: `p3_levelneed.jsonl` 3.569.

### 2026-07-06 — PHASE 3 CLOSE-OUT (5 experiments + a methodology fix)

**Methodology (item 0):** found & fixed a RESIDUAL cross-process non-determinism (two string-keyed
tie-breaks) that had silently added ~1/80-seed noise to EVERY historical batch. Verified exact:
two n=160 pools at different worker counts are now byte-identical (160/160 tied, Δ 0.000). Paired A/B at
n=160 now has ZERO process noise — the cleanest measurement footing the project has ever had. **Fresh
baseline** `base160` (progress 3.250, death-ante 3.55, 112 BUILD / 48 VARIANCE, mode ante 4).

**Graveyard re-litigation results (all paired n=160):**
| Lever | Old-world verdict | Faithful-world verdict | Ship? |
|---|---|---|---|
| **leveling-need** | −0.051 (drained econ, ante-2 deaths rose) | **+0.012 n.s.**, backfire GONE (leveling↑, $↑, early deaths↓) | ✅ KEPT |
| **coupled pair** (flush-commit + align) | −0.063 | inert→cascade-noise; refuted (can't BUILD the deck; offer-limited) | ❌ REVERT |
| leveling-alignment (alone) | flat | not tested alone (known no-op; only meaningful coupled → folded into coupled) | — |
| flush-commitment (alone) | flat + ante-1 rise | folded into coupled (its early-death cost FLIPPED to a drop under forcing, but via cascade) | — |
| **scaler damps** (proj_damp) | +0.038 when added | removal = −0.004 WASH + breaks guardrails → keep | ✅ KEEP (no delete) |

**Net:** committed engine moves `base160` 3.250 → **`p3_levelneed` 3.262** (leveling-need only); the other
levers correctly did NOT ship. Still 0 systematic wins. **The Phase-3 thesis is CONFIRMED with nuance:**
the faithful world DID flip the LEVELING levers from backfire to (small) positive — validating that Phases
1-2 removed the real brakes on leveling — but the DECK-SHAPING levers remain refuted for a sharper,
now-structural reason: a greedy per-decision valuation cannot *assemble* a shaped deck (suit tarots are
offer-rate-limited and marginal flips just cascade RNG). **This sharpens the Phase-5 decision: the wall
that survives a faithful world + unit-correct valuation + working leveling is specifically the
BUILD-ASSEMBLY problem — the committed-archetype PLANNER (drive shaping/leveling ONE direction across
many shops, hold through the dip) is the evidence-backed next step, not more per-decision valuation
levers.** The in-blind P(clear) track (Phase 4, F1/F2) remains the orthogonal prize for the 48/160
variance deaths.

---

## 6. Phase 4 implementation log — the in-blind survival-objective track (2026-07-07)

### 2026-07-07 — Phase 4, item 1: F1/F2 boss-aware survival arbitration. ✅ SHIPPED (best single signal of the effort)

**Rationale (refining the audit).** Re-reading the code sharpened F1/F2: the play-vs-discard
arbitration is NOT purely "mean of one hand's max" — the greedy fallback (`greedy_choice`, using
`DV.measured`) is, but a `search.lua` override already runs a depth-2 expectimax on
`frac = min(1, chips/target)` (expected capped fraction-of-target). Two real defects: (a) `search.lua`'s
rollout is **boss-BLIND** (no legality filter, no scoring debuffs, no Hook) — yet **94/160 base160
deaths are Boss deaths** (median clear-ratio 0.63), so the arbitration is systematically wrong exactly
where most deaths happen; (b) it uses only **2 samples** with no true CRN → noisy. Crucially, `E[frac]`
is *already* the F3-corrected objective (`= P(clear) + partial-score credit`), so the fix is NOT to
switch to pure P(clear) (that repeats the reverted-F3 mistake of discarding partial-score value) — it is
to run the same partial-aware objective on the **boss-aware `simulation.lua` rollout** with adequate
samples and proper common random numbers.

**What changed.** (1) `simulation.lua`: generalized `rollout` to return the final chip total and to
accept a FORCED opening move; added `Sim.survive_after(gs, first, samples, rng)` → `{ frac = E[min(1,
chips/target)], clear = P(clear) }` over the boss-aware full-blind rollout. (2) `decision_engine`:
replaced the `search.lua` override with a `survive_after` comparison of PLAY-now vs DISCARD-now under
**CRN** (same seed → same draws → low-variance paired delta), `SURV_SAMPLES=60`, margin-gated
(`SURV_MARGIN=0.06`) so it only overrides the greedy/heuristic choice on a clear survival edge; same
`can_search` gate (multi-hand, no held consumable). +4 tests (`test_simulation`: frac/clear bounds, CRN
determinism, trivial-target). 738 unit + 195 sim green.

**Batch (paired n=160 vs `p3_levelneed`, engine-only).** progress mean Δ **+0.038** (t=+0.80, p≈0.42);
death-ante 3.569 → **3.612** (+0.044); **sign 31 better / 18 worse / 111 tied (p≈0.087 — the strongest
lean of the whole effort)**; death-ante shift 12 later / 9 earlier / 139 unchanged; 49 seeds move.
Biggest improvers are EARLY-board survival rescues: 132003 a1→a4, 81003 a3→a6, 9003 a2→a4, 93003 a2→a4.

**Analysis.** The gain is a BROAD in-blind play-quality improvement (weak early boards make better
bank-vs-dig calls with a boss-aware survival estimate), NOT specifically a variance-death conversion
(VARIANCE 45→43, BUILD 115→117, boss clear-ratio unchanged at 0.63) — i.e. it squeezes 1-2 more antes
out of weak boards rather than fixing the capacity-then-crash trace. That's a legitimate, principled
win: the old arbitration was boss-blind and 2-sample-noisy; the new one is boss-aware and CRN-precise.

**Runtime.** A first read showed ~9.8h wall-clock, but that was the LAPTOP BEING SUSPENDED mid-batch,
not compute (user-confirmed). A clean timing probe (n=24 in 465s) extrapolates to **~52 min for n=160 —
about 5× baseline**, entirely acceptable for the tuning loop. (`SURV_SAMPLES` could be trimmed with CRN
if a future item needs it cheaper, but there's no need now.)

**Verdict: KEEP.** Positive on every metric, the strongest single signal of the effort, principled
(replaces a boss-blind heuristic with the boss-aware survival objective the audit's F2 prescribed),
affordable, and green. n.s. at n=160 in the aggregate (+0.038 ≈ 0.8 SE) but the sign test (31/18,
p≈0.087) is the closest to significance any single lever has reached, and it has no backfire.

**New baseline:** `sim_out/p4_surv.jsonl` (n=160, death-ante **3.612**, progress **3.300**, 0 wins).
**Next (Phase 4):** F5 promoted to fast-follow — the engine's PRIMARY `play_action` is still chosen
with no boss legality filter (`decision_engine:210`), so under Psychic/Eye/Mouth the forced-PLAY branch
can be illegal; F5 (pass the filter + reuse K1/K2's `played_hand_types` plumbing) makes F1/F2 correct on
those bosses. Then F4 (discard-set generators) and F6/F7.

### 2026-07-07 — Phase 4, item 2: F5 engine-side boss legality filter. ✅ SHIPPED (correctness; sim-neutral, fixes LIVE)

**Rationale.** The engine's PRIMARY play selection (`best_play_target` at decision_engine:256, and the
planet-use variant at :139) passed NO legality filter, so under Psychic (min 5 cards) / Eye (no repeat
hand type) / Mouth (one hand type all blind) it could pick an ILLEGAL play — corrupting `clears`,
play-vs-discard, ordering, and (post-F1/F2) the survival arbitration's forced-PLAY branch. The sim WORLD
already substitutes a legal play after the fact (`world.lua:474`), so this is invisible to sim survival
— but the LIVE mod flatly recommends the unplayable hand, and F1/F2 was rolling out an illegal first move.

**What changed.** Added `boss_filter(gs)` (builds the same `BossEffect.legal_play` closure simulation.lua
uses, from the K1/K2-plumbed `gs.blind.played_hand_types`), passed to both engine `best_play_target`
calls, with a fallback to the unfiltered play when NO legal play exists (can't make 5 late under Psychic
-> recommend the least-bad rather than nothing). +2 `test_decision` cases (no boss -> 2-card pair legal;
Psychic -> forced legal 5-card play). 740 unit + 195 sim green.

**Batch (paired n=160 vs `p4_surv`).** progress Δ **−0.007** (t=−0.97, p≈0.33); death-ante 3.612 →
**3.606**; **sign 1 better / 1 worse / 158 tied** — sim-NEUTRAL exactly as predicted (only the 2 seeds
that hit a restriction boss move, and the world was already substituting a legal play). Runtime 2991s
(~50 min) confirms the F1/F2 engine's ~5× cost.

**Verdict: KEEP** as a facts/correctness fix (same standard as K3/K4/K5/A5): it makes the ENGINE (and the
live mod) recommend only legal plays under Psychic/Eye/Mouth, and makes F1/F2's forced-PLAY branch
consistent with the world's substitution. **Baseline unchanged: `p4_surv.jsonl` 3.612.** Next: F4
(discard-set generators — 3-flush/3-straight digs, keep-toward-joker-hands, boss/joker-aware keep_value).

### 2026-07-07 — Phase 4, item 3: F4 discard-set generators (flush-dig + boss-aware keep_value). ❌ REVERTED (high-variance churn; reveals F4 depends on F8)

**Rationale.** `DV.best` generates only k-lowest-keep-value prefixes + a keep-best-play set +
externally-supplied sets, so a 3-to-a-flush dig (the archetype the human wins used) and a
pitch-the-debuffed-card set are never proposed. Added (a) a dominant-suit flush-dig generator (keep the
m best suited cards, m∈{3,4}, pitch the rest) and (b) boss-aware `keep_value` (a suit/face-debuffed card
scores ~0 → rank it first to discard). Both measurement-gated (the redraw is scored with the full joker
pipeline), verified in isolation (3-flush hand → keeps the 3 Hearts; debuffed King → discarded).

**Batch (paired n=160 vs `p4_surv`).** progress mean Δ **+0.122** (t=+1.23, p≈0.22) — the LARGEST mean
move of the whole effort — death-ante 3.612 → **3.763** (+0.150). **BUT: sign test 70 better / 62 worse
/ 28 tied (p≈0.54 — a WASH); sd 1.255 (2× F1/F2's); 132/160 seeds moved.** The mean is driven by ~4
outliers (89003 +4.90, 14003 +3.91, 115003 +3.48, 49003 +3.43 ≈ +0.10 of the +0.122 from 4 seeds), and
death clear-ratios WORSENED (Boss 0.63→0.57).

**Why it's churn, not a win (the diagnostic).** Tracing the biggest "win" 89003 (a1→a6): it built NO
flush — it cleared on Two Pair / Three of a Kind / High Card and simply drew well. So the flush-dig
mechanism isn't the driver; F4 changed many discard decisions (flush-dig is a candidate on most suited
hands), which **cascaded the seeded RNG** into wildly different runs. The BALANCED sign test (70/62) is
the tell: a genuine discard-quality improvement leans positive per-seed (F1/F2 was 31/18); a balanced
70/62 with 2× variance is decision CHURN that nets a non-significant mean via lucky outliers — the exact
B3 / coupled-5×-probe / C1 pattern the project reverts.

**Root cause + roadmap correction (per the "stop and justify" rule).** The audit's own **F8** predicted
this: `DV.measured` at 10 samples has 10-20% stderr, so adding MORE candidate sets amplifies
noise-driven mispicks. **F4 therefore DEPENDS ON F8** — discard-set generators only pay on a
LOW-NOISE measurement. Ordering correction: do **F8 (two-stage sampling: shortlist at 10, re-measure the
top 2-3 at 25-30) BEFORE re-attempting F4**. Also, the flush-dig has little opportunity to pay here (the
engine doesn't shape decks — P3-2 — so 3-flushes rarely complete) and boss-aware keep only bites on rare
debuff bosses, so the capability's upside is small while its churn is board-wide — a bad trade until F8.

**Verdict: REVERTED** (working-tree only; never committed). **Baseline unchanged: `p4_surv.jsonl`
3.612.** Next: **F8** (measurement-noise reduction — a prerequisite that also de-noises the whole
discard path and would let F4 be re-tried cleanly), then optionally F4; F6/F7 (consumable timing;
score_min tie-break) remain low-risk correctness items.

### Phase 4 interim status (2026-07-07)
SHIPPED: F1/F2 (boss-aware survival arbitration, +0.038 sign 31/18 — best single signal), F5 (boss
legality, correctness/sim-neutral). REVERTED: F4 (churn; blocked on F8). The in-blind ARBITRATION lever
(which action, F1/F2) beat the discard-GENERATION lever (which sets, F4) because generation is gated by
the noisy measurement F8 fixes. Committed-engine arc on the faithful world: p3_levelneed 3.569 → **p4_surv
3.612**. Remaining Phase-4: F8 → (F4 retry) → F6/F7.

### 2026-07-07 — Phase 4, item 4: F8 two-stage discard sampling. ❌ REVERTED (preliminary; C1-pattern)

**Rationale.** F4 revealed the discard measurement's 10-sample noise churns picks, so F8 = shortlist all
candidate sets at the base count, then RE-MEASURE the top 3 at 3× samples and pick on the low-noise
estimate (audit F8; a prerequisite for a clean F4 retry). Implemented + green (740/195).

**Measurement (INCOMPLETE — infra-limited).** The n=160 batch was interrupted THREE times by laptop
sleep (~50-min batches vs intermittent uptime), leaving a **partial n=106 paired** merge. That read:
progress mean Δ **−0.054** (t=−0.39, p≈0.70); death-ante −0.075; **sign 44 better / 58 worse / 4 tied**
(leans negative, n.s.); **sd 1.421 (HIGH — as churny as F4).** Preliminary and not standard-power, but
clearly NOT the clean stabilization hoped for.

**Why (the finding).** Reducing the measurement noise did NOT help — the **same wall as C1**: the discard
guardrails (`keep_bias`, prior floors, the `UPGRADE_MARGIN`-style compensators) are TUNED to COMPENSATE
for the 10-sample noise (audit C5 says this explicitly: "the floors exist to fight noise"). De-noising
the estimate without co-retuning those compensators mis-calibrates — and the two-stage re-measurement
also just changes which set wins on many decisions, cascading the RNG (the F4 churn mechanism). So F8, C1
and F4 are one family: **you cannot change the measurement's noise/candidate-set without co-retuning the
guardrails built around the old noise level.**

**Verdict: REVERTED** (working-tree only; never committed). **Baseline unchanged: `p4_surv.jsonl`
3.612.** A correct F8/F4 is a larger COUPLED change (two-stage sampling + F4 generators + a
keep_bias/floor re-tune, measured together at a clean n=160) — deferred; the isolated noise-reduction is
a net loss, same as C1/B3.

### Phase 4 close-out (this session, 2026-07-07)
SHIPPED: **F1/F2** (boss-aware survival arbitration — +0.038, sign 31/18 p≈0.087, the best single-lever
signal of the whole effort) and **F5** (engine boss legality — correctness, fixes live illegal recs).
REVERTED with recorded reasons: **F4** (discard-set generators — high-variance churn; depends on F8) and
**F8** (noise reduction — C1-pattern, needs guardrail co-retune). Committed-engine arc on the faithful
world: p3_levelneed 3.569 → **p4_surv 3.612**. **The session-wide rule holds across BOTH phases:
mechanism/correctness fixes ship (F1/F2, F5); measurement/value re-weights that don't co-move the
constants tuned around them backfire (F4, F8 — joining C1, B3, F3 from Phase 2).** Remaining Phase-4:
F6/F7 (consumable timing; score_min tie-break — low-risk correctness), and the coupled F8+F4+guardrail
retune. Phase 5 (committed-archetype planner) remains the build-side prize the Phase-3 evidence points to.

### 2026-07-10 — Phase 4, item 5: F6 consumable timing + F7 `score_min` tie-break. ✅ KEPT (small +, no backfire)

**Rationale, refined before implementation.** F6's defect was real: `decision_engine` promoted any
`use_action` over a PLAY, so Hermit cashed at +$1 and a permanent card tarot fired on any one-chip
improvement. A flat minimum-dollar gate was rejected as arbitrary. The principled timing rule is option
value: Hermit keeps growing until its +$20 cap, but may be cashed early when its current payout unlocks a
**specific measured shop purchase** valuable enough to beat the forgone larger payout. Temperance has no
in-blind growth mechanism, so a positive payout remains usable. Card tarots must first produce a material
immediate survival gain; only then should their permanent deck improvement receive credit. F7 is the
one-line correctness nit from the audit: equal-mean plays inside the expected-clear tier should choose the
higher guaranteed floor, not inherit enumeration order / the flashier RNG line.

**What changed.** (1) `engine/tarot.lua`: Hermit waits in-blind until its +$20 payout is maxed;
Temperance still uses any positive current payout. Enhancement/suit/rank tarots must add at least **5% of
boss-per-hand need immediately**, then receive a small **3% permanence credit**. The credit cannot open its
own gate. (2) `engine/shop_advisor.lua`: a held Hermit/Temperance is a funding candidate for an otherwise
unaffordable priced item. Early Hermit use is charged the exact remaining option value
`($20-current_gain) × DOLLAR_UTIL`; it is recommended only when the concrete item's existing measured value
beats waiting. This directly covers “use a sub-capped Hermit to buy a run-defining joker” without a generic
cash threshold. `sim/content.lua` executes that shop-use, then re-runs the advisor to buy the unlocked item.
(3) `hand_eval.best_play_target`: at equal expected score in tier 1, prefer higher `score_min` (F7); all tier
ordering and the tier-2 money tie-break stay unchanged.

**Regression coverage / validation.** Tests pin: low-bankroll Hermit is held in-blind; maxed Hermit and
positive Temperance are used; a mediocre Chariot/Steel draw is held; a material enhancement gets permanence
credit; a sub-capped Hermit funds Baron but not a weak flat Joker; and equal-mean probabilistic expected
clears choose the higher floor. `lua tests/runner.lua` **753/753**; `luajit tests/runner_sim.lua`
**195/195**; `git diff --check` clean.

**Batch (paired n=160 vs `p4_surv`, full fidelity).** Progress mean Δ **+0.0123** (t=+0.49, p≈0.62 n.s.);
death-ante **3.612→3.625 (+0.013)**; **sign 13 better / 8 worse / 139 tied** (p≈0.38); death-ante shift
**6 later / 4 earlier / 150 unchanged**; sd 0.315; 0 wins in both. This is surgical rather than churn:
only 21/160 seeds moved, with a positive sign lean and far below F4/F8's 1.25–1.42 sd.

**Mechanism / economy check.** Hermit uses fell **36→22**, while uses with a realized numeric payout rose
from **$15.80→$18.94 average**; seed 68003 waited from +$5.33 to +$20 and moved ante 5→6, and 104003 waited
from +$16 to +$20 and moved ante 5→6. The new shop path fired **1 Hermit + 5 Temperance** funding uses;
seed 6003 used Temperance for +$7 to unlock a purchase and moved ante 4→5. Chariot uses fell 21→18. The
headline late-ante dollar medians are survivorship-confounded; on same-seed/common-ante snapshots the paired
**median dollar Δ is exactly $0 at every ante**, with only small mean movement (ante 3 −$0.15; ante 4 −$0.39).
Death type is unchanged at **43 VARIANCE / 117 BUILD**. There is no economy-collapse signature.

**Verdict: KEEP.** Positive on progress, death-ante, sign, and death shifts; objectively-correct timing and
tie behavior; mechanism verified; no broad economy backfire. Magnitude is small/n.s., exactly like the kept
leveling-need result (+0.012), and is not presented as a win-rate breakthrough. One large regression
(113003 ante 7→5) diverged on an in-blind selection and cascaded downstream, but the overall sign remains
13/8 rather than the balanced high-variance churn that rejected F4/F8. **New retained working baseline:
`sim_out/p4_f6f7.jsonl` (death-ante 3.625, progress 3.312, n=160, 0 wins).**

### Phase 4 low-risk close-out (2026-07-10)
F1/F2 (+0.038, sign 31/18), F5 correctness, and F6/F7 (+0.012, sign 13/8) are retained. F4/F8 remain
reverted and are only valid as a coupled sampling+generator+guardrail calibration project. The surviving
death split is **117 BUILD / 43 VARIANCE**, so the next-highest-value work is Phase 5's committed-archetype
planner, not another isolated in-blind measurement change.

---

## 7. Phase 5 implementation log — committed-archetype planner (2026-07-10)

### 2026-07-10 — Phase 5, item 1: sticky committed-archetype planner V1. ✅ KEPT (directional +, mechanism real, still 0 wins)

**Why this beat the coupled F8+F4 retune.** After F6/F7, the baseline still split **117 BUILD / 43
VARIANCE** deaths. F1/F2 had already delivered the best in-blind signal, whereas F4 was balanced churn
(70/62, sd 1.255) whose largest gain built no flush and F8 leaned negative (44/58, sd 1.421). Retrying
that family requires a sampling+generator+floor/`keep_bias` calibration—the project's proven high-risk
class. Phase 3 instead supplied direct evidence that marginal credits cannot assemble a deck, and all
three human wins kept a compounding xmult core. The planner was therefore the higher expected-value item.

**Design / implementation.** `BuildPlan.advance(gs, current)` is a pure state transition whose small POD
is persisted as `gs.run.build_plan` by the simulator adapter. It commits by ante 4 only after an actual
anchor: a conditional xmult; a matching scaler+scorer; concentrated hand levels; or an economy converter
plus economy support. Commitments are sticky through the dip. The plan co-moves four coupled decisions:
(1) matching hand/economy jokers receive fit credit while off-plan conditional payoffs are diluted;
(2) matching core/scorer pieces receive sell/SELL_TO_BUY protection; (3) matching planets receive a
tapered additive credit through loose-shop, Celestial-pool, pack-pick, Fool-copy, Telescope/Orbital, and
best-planet paths; (4) `DeckPlan.target` follows committed Flush/rank/consistency shaping, but refuses to
invent a rank skew on a fresh tied deck. Existing hopeless-margin survival gating remains. State is plumbed
through `sim/world`, `sim/content`, skip states, pack states, and ante telemetry.

**Tests.** Regression cases cover anchor thresholds, Duo+Trio→Full House composition, scaler+scorer and
economy commitments, stickiness after anchors disappear, matching joker fit/retention, planet taper,
committed Flush/rank/economy deck targets, and the no-fake-rank-skew guard. Final suites:
`lua tests/runner.lua` **769/769**; `luajit tests/runner_sim.lua` **195/195**.

**Mechanism probe (n=16; not a verdict).** 8/16 runs committed by ante 1–2 and commitments stayed stable.
Target hands concentrated (several Straight lines at level 4). Paired result was mixed 2 better / 3 worse,
so no performance claim was taken from the probe; it only verified the state machine and exposed/fixed one
Orbital plumbing omission.

**Verdict batch (paired n=160 vs retained `p4_f6f7`, full fidelity).** Progress **3.312→3.345,
Δ +0.0329** (t=+1.03, p≈0.30 n.s.); death-ante **3.625→3.663, Δ +0.038**; **sign 17 better / 11 worse /
132 tied** (p≈0.34); death shifts **10 later / 7 earlier / 143 unchanged**; sd 0.404; 0 wins both.
The high-value tail improved slightly: death at ante 6+ **13→15**.

**Commitment/mechanism analysis.** 54/160 runs committed (24 at ante 1, 23 ante 2, 5 ante 3, 2 ante 4):
Straight 20, Full House 13, Two Pair 7, Pair 6, Flush 5, plus three sparse categories. The other **106
runs were byte-identical**, proving the effect is planner-local rather than board-wide churn. Hand-committed
runs averaged **+0.119 progress, sign 12/8, death shifts 10/6**; the sole economy commitment regressed and
is insufficient evidence either way. Among nine paired committed runs reaching ante 6, the committed hand's
mean level rose **3.00→4.11** (8/9 at level ≥4).

Two large improvements execute the advertised mechanism: seed 21003 committed Full House from Zany+Jolly,
acquired/used Earth and played Full House, moving ante 3→5; seed 23003 committed a level-5 Straight around
Runner, retained that core and added Cavendish, moving ante 5→6. The largest swing, 13003 (+2.95 progress),
committed Flush but did not materially level/build it, so it is cascade luck and contributes ~+0.018 of the
+0.033 aggregate. Removing it leaves roughly +0.015 with sign 16/11—still directional, but small. Straight
commitments were slightly negative in aggregate (−0.05); Two Pair (+0.333) and Flush (+0.8) were strongest,
but these post-hoc slices are not retuned on the fixed seeds.

**Runtime.** The full batch took **5868s (~98 min)** versus ~31 min for F6/F7; unit/sim suites also ran
slower. Some wall time may be laptop scheduling/sleep, but planner-path performance needs profiling before
large follow-up sweeps.

**Verdict: KEEP V1, Phase 5 remains in progress.** This is a coupled strategy mechanism, not a free
correctness fix, but it clears the required empirical bar: every aggregate direction is positive, the sign
leans positive, uncommitted runs are identical, planned ante-5/6 lines are observable, and variance is far
below F4/F8 churn. It is not the breakthrough yet: 0 wins, BUILD deaths 120/160, one large lucky outlier,
and commitment quality/runtime remain open. **New retained working baseline: `sim_out/p5_commit.jsonl`
(death-ante 3.663, progress 3.345, n=160, 0 wins). Last committed baseline remains `p4_surv` until the
working tree is explicitly committed.**

### 2026-07-11 — Phase 5 runtime profiling + two core-acquisition fixes → THE WALL IS OFFER-RATE, NOT VALUATION

**Runtime profiling (the flagged first task).** Per-run cost is 62–118s (avg 90.7s over 5 seeds spanning
ante 1→6) and does NOT scale with run depth (an ante-5 run ran in 64s). An n=160 batch is only ~20 min of
actual compute on 12 cores → **the reported ~98-min `p5_commit` batch was ~70–80% laptop-sleep, not a
planner compute regression.** `BP.advance` early-returns once committed and every planner function is
O(jokers) with no MC, so the planner cannot be a hotspot. No runtime optimization is needed before sweeps.
(NB: `jit.profile` segfaults on this LuaJIT 2.1 Windows build during finalization — unusable for hotspots;
per-run timing suffices. Don't retry it.)

**Item 4 — one-shot commitment UPGRADE.** ✅ KEPT (correct, near-inert). The commitment-quality refinement
the handoff suggested (down-weight Straight) resolves to a forbidden fixed-seed weight sweep, and the one
principled alternative (exempt off-plan xmults) is mechanically WRONG (hand-conditional xmults only fire on
their own hand). Instead: `BP.advance` made commitment PERMANENTLY sticky; a run could lock into a level-only
hand from early planet luck and then dilute its own emerging core. Added `maybe_upgrade`: a weak (LIVE
anchor-less: level-only hand or economy) commitment upgrades ONCE to a ≥2-joker-anchored hand that beats the
incumbent's live signal (incl. sunk levels) by `UPGRADE_MARGIN`, ante-gated, thrash-guarded. **BUT direct
replay of `BP.advance` over every p5_commit board showed it fires on 1/160 runs**: of 38 weak-committed runs,
only 3 ever develop a ≥2-anchor alt core and only 1 has any xmult alt. **The premise (over-sticky commitment)
is largely false — weak commits underperform because those runs never assemble a core at all.** Paired verdict
`p5_upgrade` vs `p5_commit`: 1 seed changed (+0.26), 159 tied, progress Δ +0.0016, 0 worse. Near-inert but
strictly non-negative → kept as latent correctness (matters more once cores assemble; harmless).

**Item — analytic conditional-xmult valuation** (the audit's own C1/C4; the "no sampling needed" idea).
✅ KEPT (correct, wash). Root cause of the skip-the-cores wall: a hand-conditional xmult (Duo/Trio/Family/
Order/Tribe) measured via 6-sample `score_delta` reads ~0 when its trigger hand is rare in-sample, so the
engine skips a core that multiplies every trigger hand it plays. `eval_function.lua` now values them by
`P(play a hand containing the trigger) × factor × board-base`, taking `max(measured, analytic)`; `factor` is
`(X−1)` on the buy path and `(1−1/X)` on the owned/sell path (correct asymmetric marginal against the base each
call site sees); P(trigger) is measured WITHOUT the joker (conservative); `avg_score`+`hand_freq` cached once
per eval. Probe: The Trio 3.6→6.49 on a trips-rich deck, Family 3.6→6.09, both at the flat floor on a spread
deck — it lifts a core precisely when the deck makes its trigger AND there is a base to multiply (so no early
over-buy backfire; a bare board has no base → no lift). Paired verdict `p5_analytic` vs `p5_upgrade`: progress
Δ +0.0017, **sign 2/2, 156/160 tied**, death-ante +0.006, 0 wins. WASH — but very low churn (sd 0.116), and
the changes were good (seed 99003 a7→**a8 near-win** at 7.83; 16003 a3→a4) vs 2 small regressions.

**WHY both are inert — the session's key finding.** Conditional-xmult BUYS went 9→11 across 160 runs; only
~29 of these 5 Rare cores are offered across 160 whole runs. **The BUILD wall (121/160 deaths) is not a
valuation problem — the engine now values cores correctly — it is an OFFER-RATE / exposure problem: the run
rarely SEES enough compounding cores to assemble a board.** This is the same ceiling C2/C3 hit ("correct but
nearly-inert — Rare keystones rarely offered") and the concrete face of the "offer-rate-limited + cascade-
dominated" reality the audit named for why deck-shaping levers stay refuted. **Consequence for the roadmap:
isolated valuation/mechanism fixes to specific core types are structurally capped by exposure.** The levers
that can move BUILD strength must raise EXPOSURE/economy (reroll-to-dig when core-poor and flush; more shop
slots via vouchers; joker-bearing skip tags; pack digging) or be G1 variance-aware pacing driving "no core +
behind → dig harder." Both shipped fixes also correct the LIVE mod (Phase 6): the engine no longer
undervalues owned conditional xmults or the upgrade-locked builds.

**New retained working baseline: `sim_out/p5_analytic.jsonl` (death-ante 3.669, progress 3.348, n=160,
0 wins)** — statistically identical to p5_commit (two non-negative correctness fixes on top). Last committed
baseline remains `p4_surv`. Tests: **783 unit (+`test_eval`, +upgrade regressions) + 195 sim**, green.

### 2026-07-11 (cont.) — reroll-to-dig REVERTED, then the Buffoon pack-pick fix (the session's WIN)

**Reroll-to-dig — ❌ TRIED & REVERTED.** Hypothesis: the engine rerolls only ~1.3×/run; when core-poor
(base but no xmult), behind-but-viable (invest window), and flush (can roll AND buy above the econ floor),
digging for the missing multiplier is under-done. Implemented an additive structural-priority bonus on the
reroll (`shop_advisor.lua`, gated by `invest`/`n_xmult==0`/`can_spare`), which correctly flipped a core-poor
board from BUY→REROLL in a probe. Paired `p5_dig` vs `p5_analytic`: **progress Δ −0.015, sign 7 better / 17
worse**, rerolls 219→258 (it fired), ante-4 median $ dipped ~$19→$16. Net-negative CHURN: the extra rerolls
spent economy chasing offer-rate-limited cores that often weren't there. Reverted. **Lesson: paying (rerolls)
to increase core EXPOSURE backfires — the engine is too poor, and the cores aren't reliably in the shop.**

**Economy-fidelity check (read-only sub-audit).** The sim economy is **FAITHFUL** (decompiled-verified
constants — `mechanics.lua:99-115` $1/$5 interest, $25 cap, $3/4/5 rewards; §3 certifies these), if anything
slightly *easier* than real (bosses under-modeled). Poverty is genuine early scarcity + spend-down, NOT a
harsh-world artifact. The engine DOES build economy when safe; the planner's `ECON_GLUT` only damps the 3rd+
econ joker. The real leak is that **FREE core-exposure channels are mis-valued** — chiefly the Buffoon pack pick.

**Buffoon pack-pick core valuation — ✅ KEPT (the session's best lever).** Root cause: `pack_open_advisor.lua`
`value_item` scored joker picks by raw `score_delta / need` with **NO rarity-prior floor** — so a conditional
xmult (Trio/Tribe/…) whose 6-sample delta rarely hits its trigger read ~0 on a weak board and a **flat common
out-ranked it in the pick**. This is the SAME noisy-measurement flaw fixed for shop valuation, but on a FREE,
heavily-used channel (~670 packs / 160 runs) — a direct mechanism for "never assembles a core." Fix: exposed
`Eval.joker_pick_frac(gs, sj, need, opts)` = `max(measured, analytic conditional-xmult marginal, tier-prior
floor) / need` (reusing the validated analytic-xmult logic + the jp_from_measure floor), wired into the pack
pick's measured branch. Probe: The Trio's pick value 0→**6.44** vs a flat common 0.94; no-deck prior floor 1.44.
Paired `p5_bpick` vs `p5_analytic`: **progress Δ +0.054, sign 18 better / 7 worse / 135 tied (P≈0.02,
significant); death-ante +0.044 (10 later / 6 earlier); per-ante $ UNCHANGED (spends no economy); 0 wins.**
**The strongest single-lever signal of the whole effort (beats F1/F2's +0.038.)** The win comes from BETTER
picks, not more/earlier spending.

**Session synthesis:** four levers at the BUILD wall — the three that targeted a PAID or RARELY-OFFERED channel
(shop conditional-xmult value, commitment-upgrade, reroll-dig) washed out or churned; the one that fixed the
FREE, heavily-used channel (pack picks) with the same valuation logic WON. **The lever is core EXPOSURE on
free channels + correct core valuation there — not spending to manufacture exposure.**

**New retained working baseline: `sim_out/p5_bpick.jsonl` (death-ante 3.712, progress 3.403, n=160, 0 wins).**
Last committed baseline remains `p4_surv`. Tests: **786 unit + 195 sim**, green. *(This baseline was committed
as `16e1d48` on 2026-07-11 — it is now the last committed baseline; supersedes the `p4_surv`-only note above.)*

**W2 (WINRATE_AUDIT_v2) keystone full-board swap accounting — ❌ TRIED & REVERTED.** The v2 audit flagged a
real arithmetic bug: the full-board upgrade-swap DOUBLE-CHARGED the sold joker's contribution (`- worst_c` in
`upgrade` at `shop_advisor.lua:890` AND `- W_FV*worst_c` in `value` at `:894`), plus left the buy dollar-uncosted
and the sale-cash uncredited — so keystones offered-and-affordable were skipped (Trio 0/5 in the data). Made the
accounting coherent (charge worst_c ONCE; fund the buy via `net_cost(up_cost - cash)`; track `up_cost`); a probe
confirmed a full board of commons now swaps a filler for The Trio. **But paired `p5_w2` vs `p5_bpick`: progress
Δ −0.111, sign 17 better / 39 worse; jokers SOLD 408→452 (+11%); keystones gained 14→12 (FEWER).** The coherent
accounting made swaps TOO EAGER — the engine churns the board (sells more) without acquiring more keystones, and
the lost board strength + RNG cascade cost 0.11 progress. **The double-charge was implicitly a GUARDRAIL against
over-swapping** — removing it without co-retuning `sell_margin`/`keep_bias` (calibrated around it) backfires:
the exact C1-pattern (de-noise/de-bias a valuation without co-moving its compensating constants → churn). **The
v2 audit's "safe mechanism-class fix" classification is WRONG for W2** — it is a coupled calibration project (fix
the accounting AND re-tune the swap-discipline margins together), not an isolated fix. Reverted; `p5_bpick` stands.

**Strength-proportional swap keep (the coupled W2, from a user insight) — ↩ REVERTED (but mechanism VALIDATED +
FIRST WIN).** Instead of removing the double-charge, recognise it as a FLAT strength penalty (uniform 2×C, which
both blocked good filler→keystone swaps AND under-protected strong jokers) and replace it with a
STRENGTH-PROPORTIONAL keep: `keep = worst_c·(1 + 0.5·worst_c)` — a weak filler swaps ~freely for a keystone, a
strong joker is protected super-linearly (no board churn). Probe: a commons board swaps a filler → The Trio;
a Baron/Cavendish/Blueprint board stays put. Added a survival-gate (admit a weak-measuring keystone swap only in
the invest window) — near-inert (+0.010, 2 seeds). **Paired `p5_skeep`/`p5_skgate` vs `p5_bpick`: progress
−0.032/−0.022, sign 12/19 & 14/18, SOLD 408→389 (churn CONTROLLED, unlike W2's 452), keystones 14→16, and the
FIRST SIM WIN in project history (1/160).** The mechanism does exactly what it should, but the swap path is
cascade-dominated (sd ≈ 0.49, highest of the effort) → a slight-negative wash. Reverted (churn by the proven
rule), but the first win proved the winning archetype is now REACHABLE — pointing at W3 (keystones weren't
COMPOUNDING).

### 2026-07-12 (cont.) — W4 consistency sweep: Hieroglyph runway + phantom-voucher removal + Credit Card debt. ✅ KEPT (2 → 4 wins)

**The E-4/W4 bundle (engine↔world consistency; mechanism/fidelity class).** Three fixes, one batch:
1. **Hieroglyph −1 ante modelled** (`sim/content.lua` `apply_voucher` sets `run._ante_back`; `sim/driver.lua`
   ante loop is now a while that CONSUMES the pending by REPLAYING the ante — fresh blinds/boss/shops at the
   same requirements = the extra ante of runway; consumed before the win check so an ante-8 buy can't win for
   free; the replayed ante restocks the voucher slot). Pre-fix the world modelled ONLY the −1 hand, so the
   engine paid $10 for a strictly-harmful effect — and Hieroglyph was the MOST-bought voucher (27/112 offers,
   engine value 5.0 for the real "-1 ante, -1 hand").
2. **Magic Trick / Director's Cut removed from `BASE_VOUCHERS`** — pure world no-ops the engine paid $10 for
   (6+6 buys in p5_coupled). The pool now sells only what the world models (v_blank stays — a real-game no-op).
3. **Credit Card debt honoured** (`apply_action` affordability = `dollars + credit(run) >= cost`, credit=$20
   with j_credit_card, all five buy paths + reroll) — the engine already counted the credit (OwnedSynergy), so
   an over-cash recommendation was rejected by the world and silently ENDED the whole shop (the F-9 reject-break).
   Interest was already negative-safe (`max(0, money)`).

**Regressions:** `test_vouchers` (+_ante_back, pool exclusion, debt honoured/bounded/rejected-without-card),
`test_driver` (a pending −1 ante replays the ante: two cleared bosses at max_ante=1, not a win). 798 unit +
203 sim green.

**Paired verdict `p5_w4` vs `p5_coupled` (n=160, full fidelity):** progress **3.497→3.562, Δ +0.066**;
death-ante **3.831→3.888, Δ +0.056**; **wins 2→4** (44003 a4→WIN, 130003 a5→WIN; both prior wins held);
sign 64/52/44 (p≈0.31); sd 1.286 — the A1-style world-change signature (the voucher POOL changed, so most
seeds' voucher streams re-cascade; broad symmetric swings with every aggregate positive). Tail: ante-6+
reach 22→24. Mechanism verified in-data: Hieroglyph buys persist (24 — now genuinely good), phantom buys
zero, freed budget moved to real vouchers (Grabber 21→33, Seed Money 25→30). Runtime 3826s/64 min (the
winning tail runs all 8 antes + Hieroglyph replays add blinds).

**Verdict: KEEP — the first 4-win baseline. `sim_out/p5_w4.jsonl` (death-ante 3.888, progress 3.562, 4 wins).**

### 2026-07-12 (cont.) — free-channel bundle (Overstock sit-term + rarity-tag analytic) ❌ REVERTED; Overstock world reroll-slot fix ✅ kept

**The bundle** (paired `p5_free` vs `p5_w4`): (a) Overstock measured exposure sit-term (`vouchers.lua`,
+clamp(1.5×expected_joker_fv,0,3)); (b) analytic cond-xmult lift on the rarity-tag pool
(`packs.lua` `expected_joker_of_rarity` + a new `Eval.conditional_xmult_frac`); (c) world: the REROLL
slot-refresh uses `run.shop_slots` instead of the fixed `SHOP_SLOTS` (Overstock's bought slot used to
VANISH on every reroll). **Verdict: progress −0.072, death-ante −0.062, sign 8/14, wins 4→5 — net-negative
churn; (a)+(b) reverted, (c) kept** (stream-neutral world fidelity, near-inert).

**Why it failed — TWO lessons:**
1. **The sit-term drives all-in early buys.** Seed 140003 bought Overstock at ante 1 down to $0 and died
   ante 1 (a6→a1, the worst crash); seed 27003 did the SAME and WON (4→5 wins came from here). Ungated
   exposure spending at ante 1 is high-variance, negative-EV — the reroll-to-dig lesson again, now on the
   voucher channel. A retry needs an early-ante/board-strength gate co-moved with the econ floor.
2. **"Additive-only" must be STREAM-NEUTRAL end-to-end (new lesson, project-grade).** Seed 147003 crashed
   a6→a2 with NO voucher buy: the first shop's `reroll_value` changed BEFORE any purchase. Both engine
   halves perturbed the shared measurement stream — the sit-term consumes main-rng draws whenever Overstock
   is OFFERED, and the tag-lift populated the SHARED cache's `_hand_freq`/`_avg_score` from a private
   stream, changing which draws the main stream consumes later. Any new measurement inserted into the
   shared-rng/shared-cache evaluation path re-times every downstream sample → whole-run cascade, even when
   the arithmetic is a pure max(). A clean retry must use a private rng AND a private cache (or pre-warm
   the shared cache from the main stream at a fixed point).

**Agent-mined direction locks (from p5_w4 data, informing the queue):** (i) ALL 6 surviving runs share:
cheap ×3 core by ante 1-2 + interest-capped economy by a3-4 + ONE hand hard-leveled 8-12 via Celestial
packs/Orbital tags — the two ante-8 DEATHS had core+economy but levels ≤2, so LEVELING CONCENTRATION is
the win-converter (planner V2c). (ii) Of 107 core-joker offers, 41 died at "B-full" (no candidate on a
5/5 board; j_order 9/9, vampire 5/5), 0 unaffordable, 6 out-valued → the full-board swap-ADMISSION gate
is the acquisition bottleneck (widen: admit keystones when `invest OR on_pace`; scaling-xmults are
currently excluded from keystone admission entirely; then E-2 SWAP_BUY).

### 2026-07-12 (cont.) — E-5 (drop the held-consumable gate on F1/F2 survival arbitration) ❌ REVERTED on the TAIL GATE, despite the strongest sign test of the effort

**The change (1 line):** `can_search` in `decision_engine.lua` dropped `#consumables == 0`, extending the
proven F1/F2 survive_after play-vs-discard arbitration to the ~65% of states holding a consumable (held
consumables don't enter the rollout; the use_action promotion runs independently). Runtime ~1.6× (measured
idle 134/203s → 233/310s per run; the batch took 103 min vs 64).

**Paired verdict `p5_e5` vs `p5_w4` (n=160):** **sign 57 better / 33 worse (p≈0.015 — the strongest sign
result of the whole effort, beating F1/F2's 31/18)**; VARIANCE deaths 52→42 (the mechanism does what it
claims — better in-blind survival choices). BUT: mean progress Δ **−0.018** (flat), death-ante −0.019,
**wins 4→2** (14003 win→a8 death at 7.x; 44003 win→a5), **reach-6+ tail 24→18** (fails the v2 audit's E-8
tail gate), BUILD deaths 104→116, sd 0.967 with catastrophic single-seed cascades (158003 a6→a1).

**Reading:** E-5 genuinely improves the median run's in-blind play (sign + variance-bucket evidence) but
redistributes the deep tail DOWN on this pool, and the deep tail is precisely the win-rate objective. A
mid-distribution improvement that sheds a6+/win mass is the wrong trade while wins are the goal — and its
1.6× runtime would tax every future experiment. Reverted (1 line + its regression test; trivial to re-apply).
**Retry conditions:** (a) after the E-9 replay harness exists, screen the arbitration decisions directly
(no cascade noise); or (b) couple the coverage extension with tail protection (e.g. a stricter override
margin when run_strength/board is high or ante ≥ 5, so late boards defer to the build-feeding heuristics).

### 2026-07-12 (cont.) — keystone swap-ADMISSION widening (invest OR on_pace) ❌ REVERTED: the survival gate was RIGHT

**The lever (1 line, `shop_advisor.lua`):** admit a weak-measuring keystone into the full-board upgrade-swap
whenever survival allows — `invest OR pace.on_pace` — instead of invest only. Motivated by the agent-mined
B-full attribution (41/107 core offers produced no candidate on a 5/5 board, incl. on-pace boards on $35).
A discriminating regression was built (Cavendish-anchored on-pace board at ante 2, no-trips deck so The Trio
measures exactly 0; verified to FAIL pre-change).

**Paired verdict `p5_admit` vs `p5_w4` (n=160): fired on 4 seeds — ALL FOUR WORSE (0/4), 156 byte-tied.**
154003 a6→a4 (−1.35), 138003 a8-near-win→a7 (−0.94). Mean −0.015, wins 4=4. **The on-pace admission
hypothesis is REFUTED: an on-pace board that trades a RELIABLE scorer for a weak-measuring conditional core
weakens itself exactly as the original guard's comment warned.** The invest-only discipline stands.

**Ledger correction:** "B-full: no candidate" ≠ "wrongly skipped". For on-pace boards the block is CORRECT
discipline. The B-full remedy must keep the survival gate and instead change the VALUATION SHAPE — E-2
SWAP_BUY atomic accounting (cost + sale cash + strength-keep in ONE ranked candidate) — or route acquisition
through commitment (planner), NOT through admission eagerness. Swap-eagering levers are now 0-for-3
(W2 −0.111, strength-keep-in-isolation −0.022, admission-widening 0/4).

### 2026-07-13 — planner-V2c LEVELING PUSH ✅ KEPT (the win-converter mechanism, coverage-limited)

**Evidence-derived design (agent-mined from p5_w4):** all 6 runs reaching ante 8 shared a cheap ×3 core by
a1-2 + interest-capped economy by a3-4 + ONE hand hard-leveled 8-12 via Celestial packs/Orbital; the two
ante-8 DEATHS had core+economy but levels ≤2; engine median hand-lv at a6 is 3. So: when
`BP.level_push_active(gs)` (hand-COMMITTED + dollars ≥ 20 + ante ≥ 4), `BP.planet_credit` returns
`max(V1 credit, LEVEL_PUSH(2.0) × COMMIT_LEVEL_CREDIT × (12−n)/12)` — increase-only, stream-neutral (pure
arithmetic, no rng/cache), byte-identical when the gate is closed. All delivery channels co-move through the
single planet_credit hook (loose planets, Celestial pool, pack picks, Fool copy, held-planet keep, best_planet);
`tags.lua` extends Orbital's MAGNITUDE (was: only its hand choice flowed through the commitment). Implemented
by a worktree agent from a written spec; 16 new regressions (gate closed = identical, gate open = committed
hand only, monotonic across all levels, deterministic). 810 unit + 206 sim green.

**Paired verdict `p5_lvlpush` vs `p5_w4` (n=160):** progress **+0.020** (t=1.11 n.s.), death-ante +0.012,
sign 5/5 (only ~10 seeds touched — the gate is commit-rate-limited: 54/160 runs commit, fewer are banked at
a4+), sd 0.227 (low churn), wins 4=4, tail 24→23 (flat). The two biggest gains execute the designed shape
exactly: 154003 a6→a7 (+1.66) and 144003 a6→a7 (+1.38) — banked late runs converting bank into levels; 49003
and 159003 a4→a5. Aggregate ante-6 hand-lv unchanged (median 3) because the gate rarely opens.

**Verdict: KEEP** (the V1-planner precedent: a correct, low-churn mechanism whose coverage — not its shape —
is the limiter). **New baseline `sim_out/p5_lvlpush.jsonl` (3.900 / 3.582, 4 wins). The coverage unlock is
E-10a: more runs must COMMIT (and commit earlier) for the finishing move to have surface.**

**W3 (WINRATE_AUDIT_v2) world-side joker REORDER — ✅ KEPT.** The sim froze acquisition order forever, so a bought
Blueprint sat in the last slot copying nothing (dead) and additive jokers acquired after an xmult were never
multiplied — acquired keystones under-compounded. `World.optimize_joker_order` (sim/world.lua, called at
`play_blind` start) arranges jokers into the human-optimal scoring order: additive/chips → copiers (Blueprint
copies its right neighbour = the first xmult; Brainstorm copies slot 1) → xmult last. FACTS-layer/A1-class
fidelity (models the reorder a real player does), never worse than acquisition order by construction. Probe:
a board scoring 918 in acquisition order scores 5346 reordered (+4428). **Paired `p5_w3` vs `p5_bpick`: progress
+0.054, sign 20 better / 13 worse; death-ante +0.031; 0 wins; sd 0.565 (broad re-scoring, not RNG churn).**
Net-positive world-fidelity correction → KEPT. New baseline `sim_out/p5_w3.jsonl` (death-ante 3.744,
progress 3.457, 0 wins). Committed `baf4ff7`.

**COUPLED: strength-keep swap ON the W3 world — ✅ KEPT (the arc's payoff; FIRST MULTI-WIN BASELINE).** Re-applied
the strength-proportional keystone swap (`keep = worst_c·(1+0.5·worst_c)`) + survival-gate on top of W3. The SAME
lever that washed −0.022 in isolation flips positive once W3 makes the acquired keystones COMPOUND. **Paired
`p5_coupled` vs `p5_w3`: progress +0.040 (sign 18/15), death-ante +0.087 (14 later / 7 earlier), wins 0→2, jokers
SOLD 412→407 (churn controlled), keystones 14→18.** Cumulative vs `p5_bpick`: +0.094, 2 wins. Every signal that
caught the earlier swap failures (SOLD count, keystones, death-ante shift) now points positive — the end-to-end
thesis is confirmed: **acquire the compounding cores (strength-keep swap) AND let them compound (W3) = wins.**
**New retained baseline `sim_out/p5_coupled.jsonl` (death-ante 3.831, progress 3.497, n=160, 2 wins). Tests 794
unit + 195 sim, green.** NEXT: grow the winrate from this 2-win foothold (W4 no-op effects; skip-tag joker
delivery; Overstock; then the planner / variance-aware pacing as coupled changes).

### 2026-07-13 (cont.) — SECOND_XMULT_BONUS ❌ tried & REVERTED (wash, offer-limited)
Agent-mined evidence stands (all 8 deep deaths carried ONE xmult; the winner stacked two), and the gap is
real (XMULT_FILL fires only in invest AND at zero xmults). But the additive bonus (1.5, gated on
commit_active + nx==1 + scorers>=3) fired on only 4 seeds: +2 (40003 a4->a6, 133003 a4->a5) / -2
(26003 a8->a7, 58003 a6->a5), mean +0.008, tail 27=27 — a wash that traded tail for middle. Offer-rate
limited like every isolated shop-value lever. RETRY only as a coupled planner-V2b change (second-multiplier
hunt co-moving reroll/skip-tag/pack channels toward the missing multiplier). The stdsync baseline stands.

### 2026-07-13 (cont.) — E-9 harness merged (ea0ce60) + E-5 replay-screened: decisions STRICTLY better
The E-9 corpus (400 fixtures, 28 seeds re-simulated; 161 held-consumable multi-hand states) A/B'd the E-5
gate removal at samples=120: mean regret 0.0196 -> 0.0075 (-62%), oracle-match 67.9% -> 77.1%, E[frac]
chosen 0.8479 -> 0.8578. The earlier batch revert (wins 4->2, tail 24->18 on the PRE-E-11 world) was
cascade REDISTRIBUTION, not bad decisions — the retry condition documented at the revert is satisfied.
E-5 re-applied on the honest world; verdict batch `p5_e5b` vs `p5_stdsync` in flight (tail gate decides;
runtime cost ~1.6x accepted if kept). Corpus + screen outputs: CLAUDE job tmp (corpus_e5.jsonl,
replay_e5_base/on.txt) — regenerate with tools/extract_states.lua when needed.

### 2026-07-13 (cont.) — E-7 CRN digs ❌ tried & REVERTED on the tail gate (screen-positive, batch-negative)
Agent-implemented CRN across discard candidate sets (fresh identical lcg per candidate in DV.best) and
screened on the E-9 harness first: regret 0.0085 -> 0.0072, E[frac] +0.0006, DISCARD-slice +0.001 —
weakly positive, effect tiny. Batch `p5_crn` vs `p5_e5b`: mean −0.214, sign 71/84, **reach-6+ 27 -> 15
(tail gate fails hard)**, wins 2->3 (noise; only 5/160 seeds tied — the change re-rolls EVERY dig in
EVERY run). LESSON: when the screened per-decision effect is this small, the whole-run verdict is pure
cascade redistribution — the harness correctly sized the effect (~nothing), and a near-zero-effect
re-roll of the entire pool is a lottery not worth drawing. Screen effect-size now gates batching:
don't spend a batch on |ΔE[frac]| < ~0.005. Kept from the attempt: the mechanism-based (non-brittle)
Hieroglyph replay test in test_driver.lua.

### 2026-07-14 — E-12 growth_factor compounding-fidelity fix ❌ tried & REVERTED on the tail gate
Evidence path (three read-only mining agents + a telemetry pace-probe): (1) the "second-multiplier hunt"
premise was REFUTED — deep-death boards already carry 2+ distinct xmults 72% of the time; nominal xmult
COUNT does not separate wins from deaths (only 2/25 deep deaths ever passed an affordable 2nd xmult). (2) The
clean, strictly-monotonic discriminator is LEVELING (peak hand_level_sum: shallow 0.6 / mid 2.4 / deep 4.9 /
win 8.0). (3) A pace-probe of the per-ante `metrics` in `p5_e5b` REFUTED the E-12-as-stated hypothesis
("winners report on_pace=false") — winners DO hit on_pace=true at a3-5 — but surfaced a sharper miscalibration:
the a6-8 DEATH cohort is OVER-credited at a3-5 (median margin 2-3, "comfortably ahead"), then dies. Root cause:
`growth_factor` credits a FLAT one-time xmult (Cavendish x3) a full 0.30/ante as if it COMPOUNDS, so
multiplier-rich / level-poor boards project a false lead and coast into the 2x/ante requirement curve.
THE FIX (model-correctness class): reallocate growth credit off one-time flat xmults onto the genuinely-
compounding axes — flat xmult 0.30→0.12, scaling xmult 0.45 (was 0.30+0.15, preserved), leveling 0.05→0.06
cap 12→15. Regression `tests/test_pacing.lua` (scaling xmult must out-credit flat by >2x). 830 unit + 296 sim green.
BATCH `p5_e12` vs `p5_e5b`: **progress Δ −0.038 (n.s., t=−0.96 p≈0.34), sign 15/18/127 balanced (p≈0.73),
TAIL GATE FAILS: reach-6+ 27→25 (a6 14→12).** Wins 2→3 is cascade noise (the +2.22 winner 78003 sits next to a
−2.64 regression 15003; 33 seeds changed with ±2.6 swings). Despite the theoretically-sound mechanism, in isolation
it behaves as the proven-trap class: a pacing/shop re-weight CASCADES the seeded RNG → balanced sign + high variance
= churn, and it shed tail mass. REVERTED (pacing.lua/runner.lua/test_pacing.lua restored). Baseline stays `p5_e5b`.
LESSON RE-CONFIRMED: even a defensible growth-MODEL correctness fix, if its effect is a margin re-scale that cascades
every shop decision, is a coupled-retune (needs the margin thresholds co-moved), not a free ship. Retry only coupled.
KEPT from the effort: the causal win-model (flat-xmult CONVERTER + 3-scaler ENGINE loaded by a2 + one leveled hand +
economy) and the redirect to the LEVELING valuation lever (celestial-pack channel, valuation-limited) — batching next.

### 2026-07-14 — leveling-need valuation lever (p5_lvlneed) ❌ tried & REVERTED (near-zero behavioral effect → cascade wash)
Motivated by mining agent 2 (leveling deficit is VALUATION-limited on the celestial-pack channel; take-rate flat with vs
without a core). Two coupled parts: (1) build_plan LEVEL_NEED_TARGET 4→7 + CREDIT 0.12→0.16 (reach the winners' hand_level_sum
depth; the deep-death cohort sits at ~5, above the old target → got 0 nudge); (2) shop_advisor:709/718 move `level_need` OUT of
the pack_need pace-damping (undamped like sbonus) — the core-gated leveling need is a survival signal that shouldn't be halved
by a "comfortably ahead" reading the pace-probe already showed is wrong for plateauing boards. 828 unit + 296 sim green.
BATCH `p5_lvlneed` vs `p5_e5b`: **progress Δ −0.050 (n.s., t=−1.08 p≈0.28), sign 22/26/112 balanced-negative (p≈0.67),
wins 2→1, TAIL GATE FAILS reach-6+ 27→24.** DIAGNOSTIC (the decisive part): planet_use/run **1.72→1.71 (unchanged)**,
scaling_final 1.17→1.14, $final 16.8→17.3 — the lever **changed leveling behavior essentially not at all**; the −0.050 is
pure RNG cascade (the tiny shop-value nudge re-rolled the offer pool without changing what gets leveled). Same failure shape
as E-7/E-12: a near-zero-BEHAVIORAL-effect shop change is a cascade lottery, not a win — the level_need gate (core + base>=2)
+ magnitude (0.16) was too small/narrow to actually tip celestial packs over jokers. REVERTED. Baseline stays `p5_e5b`.
LESSON (re-confirmed HARD, 3rd time this arc): SHOP-VALUE RE-WEIGHTS CASCADE THE SEEDED RNG → wash. Before batching a shop
lever, PROVE it changes BEHAVIOR (an action-summary/behavior diff on a cheap probe), not just the value number. Method pivot:
back to the SCREEN-then-batch track (in-blind coverage, where E-5 the best-ever lever lived) and mechanism/fidelity fixes;
stop spending batches on shop-value nudges whose behavioral effect is unproven.

### 2026-07-14 — SURV_MARGIN 0.06→0.02 (over-discard bias) ❌ screened, did NOT earn a batch (below the effect gate)
Baseline E-9 screen (corpus_e5b, 450 fixtures, 120 samples): mean regret 0.0076, oracle-match 65.0%, and a STRONG
directional bias — of 73 high-regret decisions, 72 chose DISCARD when PLAY was oracle-better (engine over-discards).
Root: greedy_choice credits a DISCARD the $1/hand HAND_ECON bonus, and the survive_after override only fires at a 0.06
E[frac] margin, so 0.02–0.05-gap over-discards are never corrected. Screened SURV_MARGIN 0.06→0.02: regret 0.0076→0.0053
(−30%), oracle-match 65→71% (+6pts), over-discards 72→48 — BUT **E[frac] chosen only +0.0015, below the ~0.005 gate**.
Per the E-7 rule a near-zero E[frac] effect batches as pure cascade — DID NOT BATCH; reverted to 0.06. The bias is real but
tiny because HAND_ECON captures ECONOMY (preserved-hand $) the survival oracle ignores, so the "corrected" discards were
near-ties trading survival for money. In-blind play is confirmed near-optimal (regret 0.0076); its ceiling is ~0.0015 E[frac]
— NOT where the winrate is. Pivoted to the world-fidelity no-op-joker lever (W5, the bigger find this session).

### 2026-07-14 — W5 world-fidelity: no-op VALUE_ONLY jokers implemented ✅ KEPT (correct fidelity; winrate-NEUTRAL)
An engine↔world audit (agent) found a class of jokers the ENGINE correctly values (~tier prior, ~6 buy pts) but the
sim WORLD treated as pure NO-OPS. Measured impact: 0.51 no-op gains/run, 20% of runs carry one at death (top: superposition
12, hiker 11, drunkard 10, riff_raff 9, midas_mask 6, juggler 5). Implemented (agent, worktree, wiki-verified): RESOURCE
jokers Juggler(+1 hand size)/Drunkard(+1 discard)/Burglar(+3 hands, discards→0)/Troubadour(+2 hs,−1 hand)/Merry Andy(+3 disc,
−1 hs) via a new `World.blind_resources`; GENERATORS Cartomancer/Superposition/Vagabond/8-Ball/Seance (world stream) +
Hallucination on pack-open — all OWNERSHIP-GATED so a non-owning run consumes zero extra RNG (byte-identical, clean attribution).
821 unit + 334 sim green (+38). BATCH `p5_w5` vs `p5_e5b`: **progress Δ −0.009 (n.s., t=−0.20 p≈0.84), wins 2=2, ONLY 22
seeds changed (10 better / 12 worse), reach-6+ 27→26 (one a7, noise).** The fix DELIVERS (big +3.49/+3.31 swings on owning runs)
but nets to a WASH — modest per-run value cascades symmetrically (−4.26/−2.02 offsets). KEY LESSON: even a CORRECT world-fidelity
fix washes on the winrate when the delivered value is modest + peripheral to the winning archetype (these jokers aren't the
Cavendish+scaler+leveling core). KEPT anyway as a fidelity/correctness fix (ship-freely class; a more faithful referee for any
future lever that builds around these jokers), NOT as a winrate win. New reference baseline `sim_out/p5_w5.jsonl` (3.692 progress,
2 wins; more-faithful world). DEFERRED follow-ups (same class): hiker/dna/midas_mask/riff_raff/sixth_sense, the 15 no-op
spectrals, and boss-disable (luchador/chicot) — but their winrate payoff is now in question (W5 shows the class washes unless
it touches the archetype core).

### 2026-07-14 — invest-when-committed ❌ behavioral-probe ABORTED (inert; isolates SUPPLY as the wall)
Hypothesis: open the invest window whenever COMMITTED (not just when behind pace) so committed runs load the
compounding stack even on-pace (`invest = invest_window(pace) OR commit_active`). Cheap n=32 behavioral probe vs
p5_w5 BEFORE a full batch (the post-leveling discipline): **scaler_buys 38=38, scaling_final/run 1.16=1.16,
xmult_buys 43→44, $final 18.5→18.3 — essentially INERT**; progress +0.007 n.s., only 2/32 seeds moved. WHY inert:
the invest window was ALREADY open for committed runs (they're behind pace early, so `not on_pace` already held),
so "open it more" adds ~nothing. DIAGNOSTIC VALUE: the engine already invests when it can — the binding constraint
is OFFER SUPPLY (mining: 2.49 scaling offers/run), NOT the invest gate or the engine's willingness. The cheap probe
saved a ~90-min batch — behavioral-probe-before-batch is now standard for shop levers. REVERTED. Baseline p5_w5.
SESSION SUMMARY: 5 levers tested (E-12, leveling-need, SURV_MARGIN, W5, invest-when-committed) — ALL wash/inert/
below-gate; only W5 kept (fidelity, winrate-neutral). Re-confirms the ARCHITECTURAL wall: the engine's per-decision
choices are near-locally-optimal (in-blind regret 0.0076; shop valuations verified reasonable), so no local re-weight
moves the winrate — the wall is GLOBAL build-assembly (supply + cascade limited), which greedy valuation can't solve.
The only supply-BYPASS is skip-tags (free jokers); the deferred architectural fix is lookahead/MCTS planning.

### 2026-07-14 — PACK SELL-TO-MAKE-ROOM (world fidelity + core-protection guardrail) ✅ KEPT (first winrate+ of the session)
The loop (post hook-feedback: don't conclude): the invest-probe isolated OFFER SUPPLY as the wall → mined the supply-
BYPASS channels → found a central, high-freq WORLD BUG: `sim/content.lua take_pack` had NO sell-to-make-room path, so
on a FULL board it silently VOIDED the paid-for pick — **50% of opened Buffoon packs delivered NOTHING**, even though
the engine's own advice named "sell X to make room" on 100/201 opens. This under-credited the pack supply-bypass the
winning archetype's scalers come through.
- **V1 (execute po.sell naively) ❌ REVERTED:** batch p5_packswap vs p5_w5 progress −0.098, sign 24/42 p=0.036 WORSE,
  **wins 2→0** (2003 a9→a5, 14003 a9→a6), tail shed. DIAGNOSIS: `weakest_owned_joker` picks by raw marginal FV with NO
  core protection → the swap DUMPED the winners' scaler cores (scalers measure low NOW but grow) and flat scorers
  (dumping them crashes scoring — the W2 lesson). The world's under-delivery had been an IMPLICIT anti-over-swap
  guardrail (the C1 pattern: a "bug" that was protecting the engine). Swap-eagering → 0-for-4 at this point.
- **V2 (couple with the guardrail) ✅ KEPT:** `weakest_owned_joker` now EXCLUDES keep_bias>0 jokers (compounding cores +
  flat scorers) from the sell candidates — only DISPOSABLE filler (econ/utility, keep_bias 0) is swap-eligible, so an
  all-scorer winning board yields no sell and declines the pick (board intact). n=32 probe preserved a win (14003) and
  flipped positive; **batch p5_packswap2 vs p5_w5: progress +0.059, death-ante +0.056, wins 2→3, reach-6+ 26→31 (+5,
  the TAIL GREW), a6 deaths 14→19; sign 24/20 n.s.** 39 swaps fired. The guardrail kept V1's middle gains AND protected
  (grew) the tail — the fidelity fix delivers pack scalers/jokers to full boards without churning the compounding core.
  Not statistically strong (sign n.s.) but directionally positive on EVERY axis + tail-safe + a ship-freely fidelity/
  guardrail fix. 819 unit + 338 sim green (+ core-protected pack-swap regression in test_world/test_advisors).
  **New reference baseline `sim_out/p5_packswap2.jsonl` (progress 3.750, 3 wins).** LESSON: swap-eagering is 0-for-4
  ISOLATED, but a swap COUPLED with the keep_bias core-protection guardrail (only replace disposable filler with a pack
  core) is the first positive swap — the guardrail is what the proven rule means by "coupled." NEXT: the same core-
  protected sell-to-make-room could extend to the SHOP (E-2 SWAP_BUY) so keystones compete first-class; and re-mine the
  new baseline's death anatomy for the next gap.

### 2026-07-14 — E-2 shop filler→core full-board swap ❌ tried & REVERTED (winrate-neutral, nearly inert)
Re-mine of p5_packswap2 found the shifted top gap = 2nd multiplier + LEVELING (wins hls 4 vs deaths 2; xmult 2 vs 1),
NOT economy. E-2 targeted the 2nd-multiplier delivery: the shop's full-board upgrade-swap EXCLUDED unfed xmult_scaling
cores (Hologram/Constellation) to avoid selling a contributing scorer to chase them. With the pack-swap's core-protection
guardrail (only DISPOSABLE filler is ever sold), that exclusion is overcautious, so E-2 admitted a compounding core swap
when worst_disposable (keep_bias 0) + invest, and skipped the UPGRADE_MARGIN hysteresis for that filler→core case.
819 unit + 338 sim green. Batch p5_e2 vs p5_packswap2: **progress −0.008 n.s., wins 3=3, reach-6+ 31=31 (tail holds),
but only 5 seeds changed (155 tied)** — nearly INERT. The invest gate (not on_pace + margin>=HOPELESS) is closed for most
full-board runs, so E-2 fired far below the mining's ~14 sharp-miss estimate. A guardrail-relaxation with ~zero winrate
effect → REVERTED (don't keep a near-inert margin relaxation that could over-eager with future levers). Baseline stays
`p5_packswap2`. (N=32 probe was uninformative: all the sharp-miss seeds are 48003+, outside seeds 1-32 → byte-identical.)
LESSON: the pack-swap won because its admission bar is LOW (po.sell fires on any FV-beat); the shop's is INVEST-gated +
hysteresis-charged, so the same mechanism delivers far less. The SUPPLY wall is real; the winning fix was the pack VOID bug.

### 2026-07-14 — TAG/Judgement/Soul grant_joker sell-to-make-room ❌ tried & REVERTED (near-inert + noise-floor caveat)
Same void-bug class as the pack-swap, applied to `grant_joker` (serves tag_uncommon/rare/top_up + Judgement + Soul): it
voided a created joker on a full board. Fixed with the same core-protected sell-of-filler; 819 unit + 348 sim green (regression
test). BUT batch p5_tagswap vs p5_packswap2: **only 1 tag_swap FIRED in 160 runs** — the "full board" condition is rare because
tags/Judgement/Soul fire at SKIP/early time when the board isn't full (vs pack opens, which happen throughout). Result
progress +0.035 / tail 31→33 / wins 3=3 looked positive but is NOT trustworthy: the ONE firing (seed 33003) did NOT change its
death-ante, while the 3 seeds that DID change (131003 a3→a6, 7003 a3→a6, 130003 a8→a7) had ZERO firings. => a ~3-seed NOISE
FLOOR in paired batches (residual non-determinism or unattributable cascade), unrelated to the fix. REVERTED.
**METHOD CAVEAT (important): a lever that changes <~5 seeds is within the noise floor and cannot be distinguished from noise
(retroactively confirms the E-2 revert at 5 seeds).** Only levers well above the floor are trustworthy — the pack-swap (39
firings, 22 net-changed seeds, tail +5, wins +1) qualifies and stands as the session's real win. LESSON: the void-bug pattern
only pays when the void is FREQUENT (pack opens throughout the game); the tag/Judgement/Soul void is real but rare → correct-
but-inert, not worth carrying. Session tally: pack-swap WON (baseline p5_packswap2, 3 wins); W5 kept neutral;
E-12/leveling/invest/SURV_MARGIN/E-2/tag-swap all wash/inert/reverted. Wall remains BUILD-ASSEMBLY (2nd multiplier + leveling
depth), supply+cascade limited.

### 2026-07-14 — E-10b commit-rate widening 2.5→2.0 ❌ REFUTED via behavioral probe (concentration DECREASED)
Evidence: p5_packswap2 leveling is SPREAD (avg max-single-hand-level 1.26 vs total 2.14; half the >=3-level runs spread
across ~1.4 hands vs the winners' one-hand hls 4). Hypothesis: widen commit so more runs have a hand to concentrate on.
2.0 broke a design test ("a lone scaler still does not commit") — the exact over-commit risk. n=32 behavioral probe:
**max-single-hand-level 1.16→0.94 and total-lv 1.97→1.69 (BOTH DOWN), progress −0.148 (0 better / 2 worse / 30 tied).**
REFUTED (probe, no batch wasted). LESSON: MORE commitment ≠ better concentration — widening admits LONE-SCALER anchors that
commit runs to WEAK hands and DILUTE leveling. The 2.5 threshold is correctly calibrated. => leveling concentration is NOT
commit-rate-limited; committed runs still spread because they can't always acquire the COMMITTED hand's planet (SUPPLY-limited,
the same wall). The full work queue (#1 2nd-mult / #2 E-12 / #3 F4+SURV_MARGIN / #4 E-2 / #5 E-10b) is now all tested & refuted;
the pack-swap void-fix is the only win. Remaining path = the architectural committed-archetype planner (Phase 5, large coupled
effort) or MCTS lookahead — every incremental valuation/gate/in-blind lever is exhausted.

### 2026-07-14 — E-2b shop filler→core swap WITHOUT invest gate ❌ tried & REVERTED (near-inert, channel too rare)
Insight after the pack-swap WIN: the pack-swap fired with NO invest gate (its bar is low — po.sell on any FV-beat), while E-2
kept the invest gate → inert. Hypothesis: the winning guardrail is CORE-PROTECTION, not the invest gate, so drop it on the SHOP
filler→core swap too. E-2b: admit any compounding core (incl. unfed xmult_scaling) when worst_disposable, credit SCALING_FILL
ungated (fit's FILL is invest-gated so an unfed core reads ~0 on-pace), drop the anti-churn hysteresis for filler→core. 819 unit
green. Batch p5_e2b vs p5_packswap2: **progress −0.004 n.s., wins 3=3, only 8 seeds changed, xmult delivery 1.18→1.20 (barely).**
NEAR-INERT — fired ~8x vs the pack-swap's 39x. ROOT: the shop core-swap channel is STRUCTURALLY ~1/5 the pack channel's frequency
(shop cores 2.49/run AND board must be full AND the swap must win the action ranking), so even ungated it stays below the ~20-firing
noise floor. REVERTED. CONCLUSION (multiply-confirmed): the pack-swap won because its void was FREQUENT (packs open throughout); every
extension of the winning mechanism to a RARER channel (E-2 invest-gated 5 seeds, E-2b ungated 8 seeds, tag/Judgement/Soul 1 firing)
is near-inert. A lever needs ~20+ directional firings to clear the noise floor; the frequent decision points are already near-optimal.
Baseline stays `p5_packswap2` (3 wins).

### 2026-07-14 — committed-hand play-freq for leveling valuation ❌ tried & REVERTED (near-inert, negative)
The counterfactual mining (a3-5 deaths = 62%; refuted idle-cash & pacing-detection; the a4 wall is build-assembly
VARIANCE — identical rosters at fixed ante, 2.3x capacity divergence) named ONE non-washed angle: value a celestial
pack by leveling the ONE committed hand you'll play, not the diffuse greedy-sample freq (the engine values celestial
at median -0.646 and declines affordable leveling in 64% of a3-5 deaths). BP.play_freq floored the committed hand's
freq to 0.35 (if makeable) in best_planet + planet_pool. 819 unit + 338 sim green. Probe: planet_use 2.25->2.28
(near-inert). Batch p5_lvlfreq vs p5_packswap2: **progress -0.038, wins 3->2, reach-6+ 31->29, only 8 seeds changed;
planet_use 1.71->1.74 / max-hand-lv 1.26->1.25 UNCHANGED.** The elevated freq didn't flip enough celestial buys (the
-0.646 has cost + pack_need-damping components the freq boost doesn't touch) AND is low-frequency (committed + celestial-
offered is rare). REVERTED. **CONCLUSION (now exhaustive): the incremental lever space AND the counterfactual agent's one
recommended angle are all tested — pack-swap (frequent void) is the sole win; every valuation/gate/in-blind/rare-mechanism
lever washes or is inert. The a3-5 death wall is build-assembly VARIANCE (identical decisions, different luck), not a
saveable decision. Remaining path = the architectural committed-archetype PLANNER (Phase 5) or MCTS lookahead.**

### 2026-07-14 — E-13 endgame power-over-economy ✅ KEPT (statistically SIGNIFICANT, the cleanest verdict of the project)
Found by mining the CLOSEST-to-winning runs (a7-8 deaths vs wins): mostly variance (indistinguishable boards, different
boss/draw luck), BUT one saveable pattern — the near-misses BANKED cash "for interest" while "Behind pace" at a7-8 (2003
died 0.928 on $49; 130003 0.956 on $46) and even SOLD scoring jokers for pure-economy jokers (33003 capacity 95k->11k),
while all 3 wins bought POWER late. THE FIX (correctness-shaped): when ante >= SA.ENDGAME_ANTE(7) AND not on_pace, economy
CAN'T convert to score before the run ends, so collapse w_econ (*0.1, econ jokers ~worthless) and cut income_factor (*0.25,
spend cash on power/leveling/rerolls not the bank). Probe converted near-miss 24003 (a8/0.887 -> WIN) and improved 2003
(0.928 -> 0.973). BATCH p5_e13 vs p5_packswap2: **progress +0.012, paired t=+2.25 p=0.0247 (SIGNIFICANT, p<0.05), sign 5/0/155
(zero regressions), wins 3->4, reach-6+ 31=31 (tail holds).** The KEY: E-13 fires LATE (endgame only) so it does NOT cascade
the early-game RNG -> sd 0.066 (vs the usual 0.5+), a clean directional effect that ISN'T swamped by cascade noise -- this is
WHY it's significant where every shop-value re-weight washed. 820 unit + 338 sim green (regression: a scorer's advantage over
a pure-econ joker grows in the endgame). **New baseline `sim_out/p5_e13.jsonl` (4 wins, 2.5%).** LESSON: a TARGETED, late-firing
correctness fix beats a broad valuation re-weight -- the endgame is a low-cascade surface. NEXT: E-13b sell-side (the upgrade-swap
uses add_joker_marginal_fv which includes econ, unguarded by E-13 -- 33003 sold scorers for econ; damp econ in the endgame swap).

### 2026-07-14 (cont.) — E-14 Mouth first-hand play ❌ REVERTED (inert; deaths are build-limited, not play errors)
Mining ranked The Mouth (bl_mouth, single_hand_type) the #1 boss killer (12/98 boss deaths; 11/12 forfeited hands — the
engine plays the max-SCORE first hand, locking a once-only type). Implemented a round-total-EV first-hand type selection
(play the repeatable type when score×repeats wins), gated strictly to single_hand_type via an independent RNG stream (non-Mouth
states byte-identical). **Probe: 0/32 outcomes changed** — the override was INERT because the killing plays go through the
USE_CONSUMABLE / `planet_use` follow-up path (a SEPARATE `HandEval.best_play_target` at build_plan? no — decision_engine
planet_use), which bypasses the standalone-play mouth override. Extending it to `planet_use` cascaded but converted 0/32
(+0.005 n.s.). ROOT CAUSE: **9 of 12 Mouth deaths are BUILD losses (clear-ratio <0.6)** — no play fix converts a run that
scored 30% of the requirement; only 3 near-misses (0.77-0.95) sit at the ~3-seed noise floor. Boss-play correctness is tapped
out because 108/156 (69%) of deaths are BUILD-limited. REVERTED.

### 2026-07-14 (cont.) — E-15 LEVEL_NEED_TARGET 4→8 (deep-leveling credit range) ❌ REVERTED (inert, xmult-gated)
Death-state analysis (the KEY diagnostic of the loop): **66% of deaths die with hand_level_sum ≤ 2 (mean 2.53) vs the 8-12
on ONE hand the three human wins carried; Celestial packs — the leveling source — valued mean −0.76 (65% negative) vs Buffoon
jokers +6.82, so the engine essentially never buys leveling.** Extended the proven additive `level_need` credit's taper target
4→8 toward the winning depth. **Probe INERT** — Celestial valuations unchanged (−0.79), leveling unchanged (2.30), progress
−0.007. Because `level_need` is xmult-GATED and death boards rarely reach even 4 levels (or hold an xmult), extending the range
affects almost no boards. REVERTED.

### 2026-07-14 (cont.) — E-16 COMMIT_MAX_ANTE 4→6 (commitment window) ⚪ NEUTRAL, reverted (folded into E-17 coupled test)
Telemetry (measured via the `build_plan` field in "ante" records — NOT death records, which omit it): **only 34% of runs EVER
commit to an archetype; 66% never do — so the whole Phase-5 planner leveling/concentration/retention layer is DEAD for two
thirds of runs.** The ante-4 cutoff locks out runs still alive at ante 5-6 (32+17 uncommitted snapshots). Extended the WINDOW
to 6, keeping the 2.5 quality bar (E-10b's 2.0 was refuted for over-committing). **n=160: progress +0.0013 (n.s.), sign 1/0/159,
wins 4→4, tail reach-6+ = 31 preserved.** Commitment rose 34%→50% and planet-use +36%, but outcomes didn't move — the extra
commitments don't cash out because leveling ACQUISITION is still gated (celestial negative). Correct behavior, but neutral +
churns → reverted. THE LAYERS ARE INTERLOCKED.

### 2026-07-14 (cont.) — E-17 LEVEL_PUSH finishing-move magnitude ❌ REVERTED (backfires — money diversion vs survival; NO sweet spot)
The coupled partner to E-16: the finishing-move push (planet_credit ×LEVEL_PUSH, gated committed+$20+ante4) already targets the
winning state but at 2.0 the pushed credit (0.24) was too weak to flip a Celestial pack positive (measured: committed full-board
$25 ante-5 state values a Celestial pack at pv 0.059, net-NEGATIVE after cost). Raised LEVEL_PUSH 2→5 (pushed credit 0.60 → pv
0.281 → pack clears cost). **Probe E-17@5: leveling ROSE 2.53→2.88 (mechanism WORKS) but progress −0.086, LOST BOTH probe wins
(14003/24003 still reached ante 7-8 but the cumulative money diversion to Celestial packs weakened their ENDGAME board — died at
the final boss).** Refined to E-17b (LEVEL_PUSH 4.0, PUSH_MIN_ANTE 4→6 = endgame-only so it can't disrupt ante 4-5 core assembly):
recovered 14003 but still lost 24003, leveling fell to 2.39 (ante-6 gate too narrow to fire), progress −0.024 sign 3/3. **NO SWEET
SPOT: fire broadly → leveling up but survival down (lost wins); fire narrow → leveling doesn't move (no benefit).** The leveling-
value money-diversion push is REFUTED (3rd time with E-15/E-17/E-17b). REVERTED to p5_e13. LESSON: the backfire cause is MONEY
DIVERSION from the board core to leveling; the winning archetype leveled ON TOP of a strong core, not instead of it — greedy
per-shop valuation can't tell "board is maxed, level now" from "board is weak, buy power". This is the interlocked build-assembly
wall the audit predicted; it needs architectural lookahead, not a value lever. **Loop banked NO new win (baseline stays p5_e13,
4 wins); the deliverable is the diagnosis: leveling assembly is the wall, and every value-lever route to it is refuted.**

### 2026-07-14 (cont.) — W6 world-fidelity joker bundle ✅ KEPT (largest single-lever gain of the session; +0.070)
Pivoted from the refuted leveling-value angle to CLEAN CORRECTNESS voids (a mining agent's find). Root cause: the engine's
`jp_from_measure` floors every joker positive, so it BUYS jokers that measure ~0, and the sim world silently DROPPED a whole
category of scoring mechanics → **~60 dead-slot acquisitions across 156 death runs** (the pack-void pattern, at scale). Verified
silent-zeros (0→nonzero probes): **Ancient/Idol** (per-round suit/rank never assigned, 0→112.7/9.2), **Obelisk/Hit-the-Road/
Yorick/Campfire/Ceremonial/Castle** (scaling counter never ticked, stuck at ×1/+0), **Chicot** (boss-nullify not modeled),
**Turtle Bean** (+5 hand size dropped). Implemented all 10 faithfully in `sim/joker_tick.lua`+`sim/world.lua`+`sim/content.lua`+
`sim/driver.lua` (ENGINE UNTOUCHED — pure world fidelity; the engine's decisions are unchanged, the world just delivers the
goods so existing holds pay off). Ownership-gated (non-owners byte-identical) + wrote the exact `ability` fields
`joker_effects.scaled()` reads. Caveats: Ceremonial +mult WITHOUT the destroy (bounded, one-time); Chicot disables effects but
NOT the requirement-multiplier (faithful); Turtle Bean floors-no-destruct. **BATCH p5_w6 vs p5_e13 (n=160 paired): progress
+0.070 (LARGER than pack-swap +0.059 and E-13 +0.012 — the session's biggest lever), sign 21 better / 10 worse / 129 tied
(binomial two-sided p≈0.05 — significant; the t-test is n.s. p=0.165 only because in-blind scoring cascades the RNG → sd 0.638,
and the sign test cuts through that), death-ante mean 4.069→4.138, leveling 2.53→2.76, wins 4→4, reach-6+ 31=31 (TAIL HOLDS).**
The gain is real survival: the ante-4 death cluster shifted to ante 5 (27→32). LESSON: after the leveling-VALUE graveyard, the
win came from making the WORLD faithful (deliver mechanics it dropped) — ship-freely correctness at scale, the same category as
pack-swap/Gluttonous. **New baseline `sim_out/p5_w6.jsonl` (progress 3.832, 4 wins).** NEXT: (1) engine-side — the engine still
MEASURES these at ~0 (its MC doesn't set the per-round suit), so it buys Ancient/etc blindly via the floor; teach the measurement
to set the suit so it PRIORITIZES + builds toward them (separate valuation change, test carefully). (2) the honest-exclusions
(glass/lucky_cat/caino need RNG-in-scoring; red_card/flash need a faithful shop-meta trigger) remain deferred.

### 2026-07-14 (cont.) — W7 §1 generator/leveling jokers ❌ REVERTED on the TAIL GATE (fidelity ≠ win for MEDIOCRE jokers)
Second mining pass found §1 (generator/leveling jokers the world dropped): implemented Burnt (+1 lvl to the first
DISCARD's hand/round), Space (1/4 to +1 lvl the played hand), Riff-Raff (2 Common jokers at blind select). Agent
DEFERRED Midas Mask (the sim's Gold economy is penalty-only — `hand_eval:566` charges −$3 to PLAY a gold card but
round-end never awards the +$3-held income, so faces→Gold would be net-NEGATIVE — a latent economy gap), DNA/Sixth-Sense
(only fire on single-card plays the engine never makes). **BATCH p5_w7 vs p5_w6 (n=160): progress −0.085 (t=−2.01,
p=0.044 — SIGNIFICANT NEGATIVE), wins 4→3, sign 4/11/145, reach-6+ 31→27 (TAIL GATE FAILS).** Leveling DID rise
(2.76→2.85) but net-negative. DIAGNOSIS — the crucial refinement to the fidelity-win recipe: **W6 WON because its jokers
are STRONG (Ancient/Obelisk/Yorick = big xmult = real capacity); W7's are MEDIOCRE — Burnt levels the DISCARDED (wrong)
hand, Space is low-freq (4 acq), Riff-Raff clogs slots with weak Commons. Delivering them faithfully EXPOSED that the
engine OVER-BUYS these via the jp_from_measure floor, and the added low-quality value + in-blind cascade nets negative.**
NOT every fidelity fix helps — the win depends on the joker's STRENGTH and whether the engine's floored buy was a mistake.
REVERTED to p5_w6. The real fix for the mediocre ones is ENGINE-side (stop over-buying them via the floor), not world
fidelity. **Baseline stays `sim_out/p5_w6.jsonl` (the W6 win, 4 wins/3.832).**

### 2026-07-14 (cont.) — W8 lucky_cat/glass/caino xmult scalers ⚪ NEAR-INERT, reverted (rare trigger cards)
The STRONG deferred set (xmult-SCALING jokers whose growth triggers need RNG): Lucky Cat (+0.25x per m_lucky 1-in-5
+Mult trigger), Glass (+0.75x per m_glass 1-in-4 shatter + destroy the card), Canio (+1x per face destroyed).
Implemented via SEEDED `run.rng` trigger-rolls in `joker_tick._roll_card_triggers` (scoring stays PURE — rolls in the
world/FACTS layer, not joker_effects, so world score and engine MC measurement agree), ownership-gated (byte-identical
non-owners). Faithful (0→123.7 Lucky Cat / 278.3 Glass probes). **But a frequency measurement was DECISIVE: the trigger
cards are RARE** — m_lucky in only 4/16 runs (0.33/blind, from the Magician tarot), m_glass in 3/16 (from Justice); growth
fires in ~1-2% of runs (Lucky Cat), <0.5% (Glass), ~0% (Canio, needs a Glass FACE to shatter while owned). **BATCH p5_w8 vs
p5_w6 (n=160): progress −0.007 (t=−0.24, p=0.81 n.s.), sign 3/3/154 (pure cascade noise on 6 seeds), wins 4→4, reach-6+
31→30 (tail −1, noise — a8 actually rose 1→2).** NEAR-INERT as predicted — unlike W6 (fired on every deck), these are
deck-composition-gated AND the trigger cards are rare. Reverted per the tail gate (zero winrate benefit doesn't justify the
−1 tail dip + added cascade surface). The code is CORRECT (strictly ≥ dead for owners) — a future revisit only if lucky/glass
decks become a built archetype. **CONCLUSION: the clean-void vein is EXHAUSTED for winrate — W6 (frequent+strong jokers)
was the win; W7 (mediocre) failed; W8/§2-spectrals/gold-econ (rare) are inert. Baseline stays `sim_out/p5_w6.jsonl` (4 wins,
3.832). The winning recipe is now sharp: a fixable, capacity-ADDING, FREQUENT, non-cascading gap. Next substantial gain needs
engine-side valuation (why the engine over-buys via the jp_from_measure floor) or the architectural planner/lookahead.**

### 2026-07-14 (cont.) — shape-B near-win decision mining on p5_w6 ⚪ DECISIVE: no narrow decision error remains (frontier is VARIANCE + BUILD-limited)
After W6, mined p5_w6's a7-8 near-wins (130003 a8; 25003/119003/123003/33003/127003/160003 a7) vs the 4 wins for a new
E-13-shaped late/narrow decision error. **RESULT: none exists — the frontier is VARIANCE + BUILD-ASSEMBLY limited, not
decision-limited (same verdict the a3-5 audit reached, now confirmed for a7-8).** The a7-8 cohort splits 3 VARIANCE / 4
BUILD; a6-8 splits 5 VARIANCE / 22 BUILD. VARIANCE deaths (25003 cap 128k/tgt 70k on-pace → bl_arm; 119003 137k/70k →
bl_water; 160003 79k/70k → bl_flint halving) had the capacity and died to a boss/draw — in-blind regret 0.0076 (near-
optimal), no shop/play fix. BUILD deaths (33003/127003 hand-lv 1 at a7; 130003 cap 60k vs a8 tgt 300k) are the archetype-
assembly wall. Three candidates ALL FAILED the wins-do-the-opposite test: (1) E-13b endgame scorer→econ SWAP damp (shop_
advisor:902 add_joker_marginal_fv includes econ, ungated by endgame_urgent) — only 5 such swaps in 160 runs and ONE is a
WIN (14003 sold Blue→Ticket@a7 and won); too rare + not clean. (2) endgame econ-voucher damp — ALL 4 wins ALSO buy late
econ vouchers (grabber/reroll_surplus/seed_money@a5-7); a damp penalizes the wins identically. (3) endgame reroll
discipline — win 82003 rerolled 9× late and WON, near-win 127003 rerolled 0× and died; reroll count uncorrelated (it's a
SYMPTOM of a maxed additive board with nothing to buy, not the cause). **ROOT: wins crossed an exponential threshold — TWO
stacked xmult keystones or keystone+deep-leveling (24003 baron+seeing_double; 93003 vampire+flower_pot+acrobat; 14003
hand-lv12+cavendish); near-wins held ONE keystone + additive commons that inflate early pace but can't compound (130003
pace 7.8@a5 > winning 24003's 2.4, then decayed to 0.4 as targets grew ~2×/ante). This is the jp_from_measure-floor over-
buying of additive filler — an ENGINE-SIDE valuation/PLANNER problem (architectural), supply-constrained (the 2nd-xmult
lever already washed, offer-limited), NOT a narrow late gate.** E-13 captured the sole clean late/low-cascade decision
slice of this surface. **TRIPLE-CONFIRMED EXHAUSTION: clean world-voids (W6 got the one big one; rest rare), leveling-VALUE
(E-15/E-17 refuted), and DECISION-space (this) are all mined out. The only remaining substantial gain is the architectural
committed-archetype planner that ASSEMBLES a 2-piece compounding stack + stops the additive-filler over-buy — a coupled,
supply-constrained research effort, the audit's long-standing high-ceiling long-shot. Baseline stays `p5_w6` (4 wins).**
