# NEXT_SESSION.md — fresh-session handoff

## ⭐⭐ 2026-09-20 — R9 LIVE-REVIEW FIXES + the REPLAY-AUDIT plan (read the `r9-live-review-2026-09-20` memory)

Owner played a full live run (F11), it DIED to The Mouth, and owner flagged several decisions. All traced via
the R8 replay loop (capture → `RF.rehydrate` → re-run the engine) and fixed as CORRECTNESS (not winrate
tuning). Branch `winrate-v4-bundle`; all shipped to the install (`%APPDATA%/Balatro/Mods/balatroenginesim`,
backup `bes_install_backup_20260920` OUTSIDE Mods/) and pushed.

**Shipped this session (each tested + deployed):**
1. **Mouth death (run-killer)** — off-type plays score 0 under `single_hand_type`, so the engine now DIGS for
   the locked type instead of burning hands on 0-scorers; the tarot follow-up can't corrupt the lock. Locked
   by a regression test (`tests/test_decision.lua`). ⚠ The sim referee auto-corrects illegal plays, so this
   class is INVISIBLE to the sim suite — it needs live capture + replay.
2. **Build-aware card targeting (`engine/tarot.lua` `T.card_relevance_fn`)** — Empress/Hierophant/Strength/
   Death + spectral seals/editions target what the build REWARDS, read by PROBING each owned joker's scoring
   hooks (complete + self-maintaining: catches Wee/Hack/Fibonacci/Baron/faces/odd, not just suits). Tag-based
   was rejected as incomplete.
3. **Banner/Mystic valuation** — scored at the discards you'll HOLD at play (`SA.expected_discards_left`), not
   the fresh-blind max (Banner was 4× over-valued).
4. **Sim held-gold $3 fidelity** (`sim/world.lua`) + **Celestial finishing-window poverty exemption**
   (`shop_advisor`, agreement-neutral).
5. **SKIP decisions are now CAPTURED** (`main.lua`/`replay_fixture`/`replay_fixtures`) — previously the one
   decision class never logged. NOT a behaviour change (skip-RATE = the REFUTED `noskip` lever, −0.166).

**⭐ THE RECOMMENDED NEXT STEP — a REPLAY-BASED PROVABLE-ERROR audit (not an agreement bake-off).** Owner's
valid critique: "differs from my play" bottlenecks on the owner's judgment (the corpus IS their play). So the
audit's PRIMARY signal is PROVABLE errors — wrong on their own terms, judgment-free: a played hand that scores
0, an illegal play, a joker valued at an impossible state, an enhancement on a non-scoring card, a generator
with no output room. Method: replay every captured fixture (`data/agreement_corpus/` OR the live save-folder
`bes_fixtures.jsonl`) under the current engine and FLAG these. Agreement-divergence from the 7 winning human
runs is a SECONDARY lead-generator only. Verified provable-correctness fixes ship + get a regression test;
judgment/refuted items are LEFT (that's not the loop, it's discipline).

**Verification is decoupled from the owner:** they PLAY (any runs, any seed), the mod captures every decision,
the assistant REPLAYS. Owner does not need to know the optimum or replay a specific seed. The winrate CEILING
(~8% autonomous) is compute-bound and per-decision fixes won't move it — this work is ADVICE CORRECTNESS,
which is tractable and the live overlay's actual job. `run tests/runner.lua` (1210 pass) + `runner_sim.lua`
(604 pass, 1 pre-existing `test_world` failure) before committing.

## ⭐⭐ 2026-09-19 — WINRATE_V4 investigation + the IN-BLIND PLAY / MONEY-FARMING finding (read `WINRATE_V4_PLAN.md`)

**Fresh baselines (current HEAD, `branch winrate-v4-bundle`):** autonomous **8.1%** baseline / **28.7%** rich10
(the old docs' 2.5% is STALE — recent scaler/spectral/R7 work tripled it). `run_str` caps ~0.62 at ante 8 in
BOTH → money buys levels, not board power.

**What this session established (all in `WINRATE_V4_PLAN.md`):**
1. **Build/economy/supply levers are exhausted** — WS-3 product-value (reverted, killed winners), the whole
   economy family already tried (reroll-to-dig, banking, ecap3, pack-poverty), loss diagnosis = SUPPLY×SURVIVAL
   (engine takes offered multipliers fine; it just dies early → low exposure), and the learned-value path is a
   NO-GO on attainable data (`tools/data_scaling_probe.py`: plateaus below the free `capacity` baseline).
2. **In-blind SCORING-play is near-optimal** — `HandEval` faithful (7/7 canonical), chooser 94% max, ante-1 dig
   at a clairvoyant ceiling (78% vs 75%), and target-aware dig rewrites measured NEUTRAL (reverted). First
   blind clears 99.5%. The live self-player uses the full engine (`BES_SAMPLES=80`), not a degraded path.
3. **⭐ THE OPEN FRONTIER (owner, 2026-09-19): JOINT MONEY-FARMING + SCORING in-blind.** Pure "clear the blind"
   is solved, but milking ECONOMY *while* clearing (Gold cards/seals, Lucky, editions, econ jokers held/played
   to MAX $ subject to still clearing; $1/unused-hand compounds into the next shop) is NOT measured or
   optimized. Deterministic, non-compute-bound. Probe `engine/discard_fuel.lua`, `hold_fuel.lua`,
   `HandEval.play_econ`, and the MILK/DIG paths in `decision_engine`. Owner: assume autoplay actuation is fine.
4. **Target: near-100% is legitimate** (expert humans hit >98% gold-stake hardest decks); even 0.5% ante-1
   failures are a real defect. New diagnostics kept: `tools/first_blind_fast.lua`, `first_blind_optimal.lua`,
   `play_regret.lua`, `loss_diagnosis.py`, `data_scaling_probe.py`.

---

# NEXT_SESSION.md — earlier handoff (2026-09-04)

## ⭐ TASK 3 SWEEP — bring EVERY scaler onto the measured system (owner directive, 2026-09-04)

> **Owner reframed the goal: ALL jokers should follow the measured system, not revert to tier constants.**
> The scaler-coverage audit answers "how many still do": of **151 catalogued jokers, 120 non-scalers are
> already MEASURED** (deck-aware `score_delta`, or `econ_value` for money jokers — tier is only a low floor);
> **12 scalers were on the measured system; 19 still fell through** to `tier-prior × generic-projection`. A
> fresh scaler contributes ~0 (a fresh xmult is ×1), so `score_delta` reads 0 and the value collapses to the
> tier constant — the same class of error that had Ride the Bus at 3.78 vs measured 0.04.

**✅ BATCH 1 SHIPPED (`88ed981` + fix `1b2e6a1`) — the consumable-fed class + a class-A freebie (19 → 16):**
- **Constellation (+0.1x/Planet) & Fortune Teller (+1 mult/Tarot)** — the R5 "skipped a Constellation while
  rich" item. Valued by the event-fed model (below), **RESOURCE-AWARE**: planet/tarot uses per scoring-hand
  scale with generation capacity (Astronomer 0.30, tarot-makers 0.14), leveling / Satellite (0.15), money
  (0.06), else base 0.03. Constellation went from a context-blind flat **4.32-of-a-boss-hand EVERYWHERE** →
  ~nil in a non-planet build (the over-buy TRAP fixed) rising to **1.86** in a leveled Astronomer build (tracks
  how leveled you are).
- **Spare Trousers (class A)** — just needed `inc=2, scale_rate=0.50`; trigger hands were already gated.

**⭐ THE CORPUS CAUGHT A REGRESSION — the reusable lesson.** The agreement corpus (161 Constellation states)
was NEUTRAL overall (±0.2pp), but its **picks-diff** showed dropping the tier floor made an owned scaling core
measure LOW on a still-weak board → the engine wanted to **SELL its own committed Constellation** (seed
Z9PBGTL2, jp 0.113, below Egg). **Fix: gate the measured value to the BUY side only (`owned=false`).** The
owned/sell path keeps the measured+tier-floor route — sell-side core protection (`BP.CORE_KEEP` / the tier
floor as a FLOOR) is a SEPARATE, endorsed concern from not-over-BUYING. owned jp 0.113 → 7.200; buy-side
unchanged. **"Drop the tier floor" is a BUY-side directive; check the SELL ranking + corpus picks-diff, not
just the headline metrics, when you change a scaler.** The remaining −2 buy_agree was diagnosed to 3 winning
planet-build states where the decline is DEFENSIBLE (full-board swap / short runway / early speculation), not
undervaluation — the old flat 4.32 "agreed" by over-valuing everything.

**✅ BATCH 2 SHIPPED (`1993ca7`) — the remaining 14 scalers; 31/31 now measured, 0 fall-throughs.** The
consumable-fed model was generalized into a unified **EVENT-FED** model (`Eval.event_fed_forward`): `value =
feed_inc × projected_events / 2 × deck-aware-spu`, no tier floor, BUY-side only. Catalogue `feed_fuel/feed_inc`
drives it; the counter unit (chips/mult/x_mult) is derived from `cat`. Fuels by class:
- **C. Discard-fed:** Castle (+3ch/suit-discard), Hit-the-Road (+0.5x/Jack, resets/round), Yorick (+1x/23 discards)
- **scored-rank:** Wee (+8ch/scored 2)
- **D. Deck-content (bounded by deck count, deck-aware):** Vampire (+0.1x/enh eaten), Glass (+0.75x/shatter —
  **0 with no Glass cards, 0.50 with eight**), Lucky Cat (+0.25x/trigger)
- **E. Deck-size:** Hologram (+0.25x/card added)
- **F. Action-fed:** Campfire (+0.25x/sell, resets/ante), Throwback (+0.25x/skip), Flash (+2mult/reroll —
  **money-gated: 0.19 poor → 0.47 rich**), Red Card (+3mult/pack-skip)
- **G. Reset/rare/destroying:** Obelisk (+0.2x off-type, resets), Madness (+0.5x/select, DESTROYS a joker →
  `feed_damp 0.3`), Canio (+1x/face destroyed), Ceremonial (one-shot +2×right-sell, `feed_once` + damp)

`event_rate` holds the per-fuel rates (OWNER-CALIBRATABLE like `scale_rate`); resetting fuels use the PERIOD as
the horizon; deck-content fuels are bounded by deck count. **`SCALER FALL-THROUGHS: 0`** (audit:
`tools/scratchpad audit_scalers`). 1182 tests.
**Corpus (batch-1 → all-scalers): NET POSITIVE — `agree_save` +0.8pp (316→324)**, everything else neutral
(±0.1pp), guards unchanged. Dropping the inflated tier values made the engine **over-buy and over-churn
scalers LESS**: the changed decisions are the engine no longer selling working jokers to fund inflated scalers
(Smiley Face, 8 Ball, Gros Michel, Raised Fist — all "SELL → SAVE" now) and no longer speculatively buying
inflated Castle/Campfire/Hologram. **No early-core dumps** (the buy-side-only gate held); the only oddities are
ante-8 already-won states where measurement noise reshuffles equivalent win-lines.

**➡ THE SCALER SWEEP IS COMPLETE. Where the frontier goes next** (all optional, none is a fall-through fix):
- **Owner-calibrate the `event_rate` rates + `feed_damp`s** if any live-run value looks off — these are the
  Runner/Square-style domain constants, set to reasonable defaults, not yet owner-tuned.
- **The remaining tier-prior dependence is NOT scalers:** the 3 joker-making generators (Riff-Raff/Vagabond/
  Cartomancer, valued tier × `output_fit`) and a few utility jokers. Different modeling axis (output/utility),
  not the scaler system.
- **Deck-content BUY-timing:** Glass/Vampire/Lucky read 0 until the cards are in the deck — correct per-state,
  but a human buys them as a COMMITMENT to add those cards (the same foresight gap as early Constellation). A
  future "planned deck-content" signal could credit that; deferred (it's the build-commitment wall again).

## ⭐⭐ R6–R8 LIVE-RUN REVIEW (2026-09-04) — 3 fixes shipped, and the FIRST death traced end to end

> **Read `ADVICE_REVIEW.md` R6/R7/R8 for the full detail.** The headline is methodological: R8 is the first
> time this project has traced a live death from **board state → valuation → the specific line of code**,
> by finding the run in `bes_runs.jsonl` and **replaying the exact shop state from `bes_fixtures.jsonl`**.
> That loop — owner reports a misplay, find the seed, replay the fixture, watch the engine reproduce it —
> is now the sharpest diagnostic this project has, and it is repeatable. **Use it before theorising.**

**✅ SHIPPED THIS SESSION:**
- **Ectoplasm priced properly** (`175b5c4`) — it fell through to a flat `SPECTRAL_BASE` prior of **0.7** (3rd
  highest spectral) with its permanent −1 hand size charged at **zero**, while the structurally identical
  Ouija branch directly above it did charge one. Now: no-eligible-joker guard; the +1 slot priced by the
  existing board/runway-aware `Eval.negative_slot_fv`; and the credit scaled by how much of the board
  `BP.keep_bias` calls a keeper — because the slot rides on a RANDOM joker and leaves when you sell it, while
  the hand size never comes back. Ante 3, stock deck: **0 jokers −0.130 · 3 junk commons −0.466 · 2 commons +
  1 core +0.634 · 3 cores +2.808 · 3 cores at ante 8 +0.498 · 5 cores full board ante 2 +5.366** (all were a
  flat 0.700). New `CV.hand_size_cost` MEASURES the −1 hand size off the real deck by paired sampling, and
  **Ouija now uses it too**, so both cards inflicting that downside are charged the same way.
- **A generator with nowhere to put its output is not "live"** (`b21aa57`) — the two defects behind the R8
  death, below.

**⭐ R8, THE DEATH (seed 6EDJFT2Y, ante 4).** Board full → bought **Riff-Raff into the last joker slot** (it
spawned **zero** jokers for the rest of the run) → later needed a slot for a To Do List and **sold Greedy
Joker, the board's only unconditional Mult** → died at the ante-4 boss on **21.5% of the requirement holding
$52** (the same $52 as the canonical X3L32ZEA loss). Three of the five jokers on the death board score
nothing. Replaying the recorded state reproduced the misplay exactly, and **two composing defects are now
fixed**:
- 🔧 **`funder_is_live` protected a generator that could not generate.** The `card_generation` clause (added
  2026-09-01 for **Vagabond**) shields a joker whose "value is in its OUTPUT" — but with no room there IS no
  output. The fix is deliberately **asymmetric**: consumable-makers keep their UNCONDITIONAL protection (a
  consumable slot frees up as you use it, so a full tray is transient and gating it would re-open the very
  churn the 09-01 fix closed — that path is byte-identical), while the joker-maker is gated on a free joker
  slot. Riff-Raff is the only `card_generation` joker without the `"consumable"` tag, so **exactly one key**
  changes behaviour, in exactly the state where it provably produces nothing.
- 🔧 **The tier prior assumed the output lands.** Fix 2 alone does NOT change the outcome — Riff-Raff's
  marginal was **3.000** (a pure tier prior, 6 × 0.5) against Greedy's **1.800**, so unprotecting it still
  left the Mult as the cheapest sale. Both prior paths — sell-side `Eval.jp_from_measure` and the
  **independent** buy-side prior in `shop_advisor.scoring_gain` — are now scaled by `Generators.output_fit`.
  **No new constant:** it reuses `pack_open_advisor`'s existing `gen_fit` convention and its `room_credit`
  reading (Judgement is 0.1 there because "a RANDOM joker rarely beats what you sacrifice"; Riff-Raff makes
  2 random **Commons**, strictly weaker, so it takes the same 0.1).
  Result: marginal **3.000 → 0.300**, advice **SELL Greedy → SELL Riff-Raff**; buy value was **7.5233 on
  every board size**, now 7.02 / 7.02 / 2.43 / **−2.16** as the slots after purchase go 3 / 2 / 1 / 0.

**⏳ OPEN, ranked:**
1. **✅ DONE (`f46b5cc`, 2026-09-05) — THE PLAY CHOOSER IS NOW CARD-ORDER-AWARE.** `best_play` compared
   subsets in dealt order and could take a play that fails to clear while a REORDERED subset clears (owner's
   Greedy + Hanging Chad hand — Two Pair 340 dealt / 924 lead-Diamond-Ace, verified). `HandEval.best_play_target`
   now, when `HandEval.card_order_sensitive` (Hanging Chad / Photograph / Glass or poly cards), collects the
   top-K subsets by dealt score and re-judges each at its best CARD order (bounded cards-only permute), then
   returns the sel already in best order (so the sim, which scores sel in order, plays optimally). The human
   REORDER tip is preserved: `decision_engine` feeds `Ordering.optimize` the HAND-order sequence so it still
   recovers hand→best. Order-INSENSITIVE boards are byte-identical (0.98 ms/call; sensitive ~6.4 ms, gated).
   `best_play` (the 80× discard-sampling path) is left dealt-order for perf. **Corpus (cf_spec2→cf_play):
   BLIND class-agree +1.0pp (431→439)** — the engine's in-blind play choices now match the winning human MORE
   often; everything else neutral, guards intact. The changed plays are higher-value ordered picks.
2. **✅ DONE (`0538fa1`) — Business Card feeds the in-blind money model.** `j_business` (VALUE_ONLY) never
   reached `ev.money`, so the tier-2 "both clear → maximise MONEY" play tie-break read $0 for a farming board.
   `score_with` now adds $1 expected per played FACE card per Business Card (per trigger — a Hanging Chad
   retrigger re-rolls it; Oops! → $2; Pareidolia counts all cards). Feeds `ev.money` → `play_econ` → the
   tie-break and `econ_power`. **Corpus (cf_play→cf_all, with Vagabond): NEUTRAL** — BLIND −0.3pp (2 tier-2
   plays where the money tie-break now prefers the higher-$ clearing play), all SHOP/PACK metrics 0.0.
3. **✅ DONE (`ea897de`, 2026-09-22) — the self-player now EXECUTES the card reorder** (PHASE 0b in `ui/autoplay.lua`: permutes the played cards within their own hand slots to `best.reorder.card_order`, re-aligns; the game scores in T.x order, and align_cards sets T.x from the array index, so it sticks. Headless-tested vs a mock G with the real align/play-sort rules (`tests/test_autoplay.lua`); deployed. ✅ CONFIRMED LIVE by the owner on seed DGTW4TTP after a game restart — the first attempt looked broken only because the game had been running since before the deploy; the mod does NOT hot-reload.) Original note: ~~The self-player never reorders CARDS~~ — `ui/autoplay.lua` has a joker-reorder phase; `card_order`
   appears **zero times**. Now that the chooser (item 1) returns the best card order and the overlay tip
   recovers hand→best, the live autoplayer must EXECUTE that card reorder to realize the fix (the sim already
   does, since it scores the sel in order). ⚠ Live-only (`ui/autoplay.lua` needs `G`/love) — cannot be
   validated headlessly; needs an in-game run.
4a. **✅ 2026-09-23 — the Smiley→Blackboard sale (DGTW4TTP) was a HELD-CARD CONTEXT BUG, fixed `7874b55` + deployed.** HandEval read held cards from gs.hand (EMPTY in the shop), so Blackboard's ×3 fired on every sampled hand and Raised Fist/Shoot the Moon/Baron/Chariot-Steel measured 0. Also fixed: Card Sharp never fired in the rollout (`58f0c06`). New tool `tools/rollout_calibration.{lua,sh}` ranks cheap measures vs the full engine (307 boards): the shop's per-hand mean ranks sells best (88–95%); the fast rollout is pessimistic; a dig-aware per-hand measure adds +2–5pp at ~15× cost. OPEN: Blackboard's BUY is still priced by the tier floor (1.08 vs measured 0.42) — revisit the floor as a measured change. **Sim A/B of the held fix (paired n=160, baseline, 58f0c06→7874b55): progress +0.200 (t 2.28, p 0.022), wins 10→15, death-ante 35 later/23 earlier, reach-8 16→19; sign test 44/38 n.s. ⇒ suggestive positive, no harm.** Arms: sim_out/hc_ab_{before,after}.jsonl.
4. **⚠ Nothing notices a sale leaves the board with no unconditional Mult** (R8 defect 3, STILL open — the
   hard one). Greedy is `flat_mult` → `SCORER_KEEP`; plain scorers are deliberately unprotected. **Assessed
   2026-09-05 and deliberately NOT quick-fixed:** the leave-one-out marginal `joker_marginal_fv` is ACCURATE
   (Greedy really was weak on a few-Diamonds deck); the gap is WORST-CASE-hand board collapse — the boss hand
   didn't trigger the board's conditional/retrigger mult, so scoring collapsed. This is genuinely §31f's
   board-as-a-SET problem (Mult is a FACTOR; its marginal ≠ the product's collapse) and needs set-scoring
   (score the board as copiers×xmult×triggers, detect the last mult FACTOR), not a magnitude tweak or a
   guard bolted onto the averaged marginal. Left for the research fork.

**✅ GENERATORS (`c491742`, 2026-09-05) — Vagabond value is now econ-aware.** It makes a Tarot only at <= $4,
but the flat tier prior valued it 3.75 at every dollar level; `Generators.fire_rate` damps it by expected
firing rate (3.75 at $2 → 0.38 at $25). Cartomancer (unconditional) and Riff-Raff (output-fit gated, R8) are
unchanged. The generators are no longer context-blind constants.
5. **✅ TIER 1 DONE (`0c6ae12`, 2026-09-04) — the spectral wiring.** **Black Hole** now uses the measured
   `Packs.black_hole_value` in BOTH the buy valuation (`card_value`) and the use decision (`DE.GEN_USE`) —
   one deck-aware price, not three (0.9 → 0.388 stock ante 3). **The four SEAL spectrals** are now
   distinguished via `CV.seal_spectral_value` (Gold/Blue/Purple by `card_econ_value`; Red as a bounded
   retrigger estimate `CV.RED_SEAL_FRAC`, because a greedy measurement seals a plain card and reads ~0) —
   flat 0.2 → Gold .063 / Red .016 / Blue .026 / Purple .100. **Sigil** via `CV.sigil_value` (measure the
   flush conversion toward the dominant suit, damp for the random suit) — flat 0.3 → 0.020 rising to 0.055 as
   the deck leans flush. **Corpus (pre-spectral → wired): NET POSITIVE — PACK agree_same +0.5pp (84→86),
   PACK diff −0.5pp, everything else neutral, guards unchanged.** The changed picks are the engine choosing
   spectrals by measured value instead of flat priors (Sigil→Grim/Talisman where Sigil measures low with no
   flush lean; Incantation→Deja Vu on a board where the red retrigger is worth more) + spectral pack EVs
   recomputed. No regressions. **✅ TIER 2 DONE (`009c368`, 2026-09-05) — ALL 18 spectrals now measured, 0 flat priors.**
   **Soul** (a random Legendary) via `Packs.expected_joker_of_rarity("Legendary")`, slot-aware (full board
   ×0.7) — 1.2 → 1.98 free / 1.39 full, now the top spectral above Black Hole; its `DE.GEN_USE` uses the same
   measured value. **Cryptid** (2 copies of a card) via `card_add_value ×2` FLOORED like DNA/Marble
   (`CV.CRYPTID_FLOOR` — deck-copy value is dilution-dominated in a snapshot; the floor is the compounding it
   can't measure) — 0.4 → 0.2. **Aura** (a random edition) via an analytic `AURA_FRAC × base/need` estimate
   (a greedy measurement editions a card the sampler rarely scores and reads ~0, same intent-blindness as the
   Red seal) — 0.35 → deck-aware 0.01–0.10. **Familiar/Grim/Incantation** (destroy 1, add N enhanced) via
   `N × card_add_value` — 0.25 flat → scales with N (Incantation 0.37 > Familiar 0.29 > Grim 0.19). The pack
   pool inherits all of it (spectral_pool calls card_value). **Corpus (Tier1→Tier2): NEUTRAL** — PACK agree
   ±0.3pp (1 state), all SHOP metrics 0.0, guards unchanged. Changed picks = choosing spectrals by measured
   value (Incantation, the strongest add-group, now often wins) + spectral pack EVs rising because Soul is
   valued; no aggregate buy/save shift. ⚠ Watch: Soul at ~1.98 lifts spectral-pack EVs noticeably — if a live
   run shows over-buying Spectral packs, damp `CV.soul_value` or the pool's best-of-N.
   **➡ THE SPECTRAL LAYER IS FULLY MEASURED (18/18). No spectral reverts to a constant.**

**🛑 A PROCESS LESSON THAT PAID FOR ITSELF TWICE THIS SESSION** — CLAUDE.md's *"verify by MEASURING, not by
reading the diff"*. On Ectoplasm, the first draft's comment asserted the hand-size cost was **convex** in hand
size; the probe refuted it (0.33 at hand size 8, **0.09** at 5 — a smaller hand makes weaker hands, so the
marginal card contributes less), which also means stacking Ectoplasms are under-charged (recorded in-code).
And the first `stick` formula credited each joker `keep_bias / CORE_KEEP`, paying a flat common **48%** and
leaving three junk commons at **+0.97 — ABOVE the 0.7 being replaced**: as first written, the fix would have
made the reported misplay MORE likely. **Both were caught only by running the numbers.**

⚠ **Test-suite note:** `tests/test_shop.lua` uses `table.unpack` (~line 1048), which is nil under **LuaJIT**
— the suite aborts there if run with `luajit`. It is fine under `lua tests/runner.lua`, which is how the
headless suite is meant to run. Pre-existing, unrelated to this session's changes, but it will bite anyone
running that one suite standalone under luajit.

---

## ⭐ R5 LIVE-RUN REVIEW (2026-09-03) — 3 fixes shipped, the rest triaged
Owner watched a run and reported ~10 issues. Outcomes:

**✅ SHIPPED:**
- **Purple seal discarded into full consumable slots** (`567c165`) — `discard_value.keep_value` now treats a
  purple seal as pitchable (+3, for its Tarot) ONLY when a consumable slot is free; with full slots it's kept
  like any sealed card (+15) so it isn't thrown for a Tarot that overflows. Corpus-neutral (no in-blind regression).
- **Money hoarding** (`567c165`) — `FREE_SPEND_DISCOUNT` now DECAYS as the idle above-cap pile grows
  (0.4→0.12 over $25 of surplus), so a large hoard converts to build while the near-cap interest buffer is
  protected. **Corpus-neutral; baseline sim neutral/slight-neg (change barely fires — the poor sim engine
  dies at ~$22); RICH10 POSITIVE on every metric (wins 13v11, reach-8 15v13, sign 15/9, progress +0.065, only
  16 tied vs 34).** The operating-point signature (B3/level_gain) — neutral at baseline, converts at the rich
  end the live overlay serves. ⚠ rich10-in-sample isn't a *proven* lever (B3-lesson), but mechanism-sound +
  owner-reported + no baseline harm = defensible ship.
- **Skip advisor missed the board's money jokers** (`6a7892b`) — added `Eval.econ_power` to the skip's
  play-value, so a farming board (Business Card/Bloodstone/…) correctly prefers to PLAY not skip (owner:
  skipped a Meteor pack forgoing Business-Card farming). Correctness (the play earns that money).

**🔎 DIAGNOSED, not a bug / deferred:**
- **Overlay "Jupiter/Earth" & "holo-8S/blue-seal" mismatches** — the live tick renders the CHEAP tier pass
  (`main.lua:116`, `cheap = not with_sim`) then the background job refines to the MEASURED pick. The owner
  read the transient cheap pick before it refined. Engine's actual pick is CORRECT — a display-latency
  artifact. Fix is UX (mark provisional / prefer the cached measured pick); not done.
- **Played 3 Kings incl. a DEBUFFED one, no dig with 3 discards** — the engine already scores a debuffed card
  as 0 (`is_debuffed`), so it KNEW; playing to clear efficiently vs digging is the known build-commitment/dig
  wall (a uniform dig bias was REFUTED by the corpus). Not a clean bug.

**⛔ DEFERRED (harder — need modeling/measurement):**
- **Skipped a Constellation (xmult_scaling) while rich** — an xmult scaler is under-valued at purchase
  (fresh xmult ~1) and the engine doesn't connect "I'm rich → I'll use many planets → it scales fast."
  Needs RESOURCE-AWARE scaler valuation.
- **Kept an unscaled Castle while chip-flush** — Castle (discard-fed chip scaler) isn't in the measured-scaler
  system, so it's tier×proj-valued (over-valued when unfed), and a chip-scaler's value should drop when MULT
  (not chips) is the bottleneck. Add discard-fed scalers to the measured system + a chips-vs-mult-bottleneck
  read.
- **Build incoherence (held a Diamonds +mult without building Diamonds)** — the known CONVERSION wall (commit
  to a suit + convert cards). The #1 unsolved winrate problem.
- **Reluctant to use tarots (slows scaling)** — proactive consumable-use pacing; related to the conversion wall.

## ✅ FOUR UTILITY-JOKER MODELS shipped (2026-09-02) — beyond-tier follow-ups from the tier review
Owner directed these off their flat tier priors, systematically:
- **Invisible Joker** — was a flat prior (not modeled as a copier). Now valued by the joker it will
  DUPLICATE: `Eval.invisible_copy_jp` blends the board mean with the best (0.4/0.6, you shed weak jokers to
  bias the random pick), × 0.75 for the 3-round delay. **~0 with no board worth copying; scales with your
  best joker.** Scaling-inheritance falls out for free — the copy is priced via `joker_jp` at the board
  joker's CURRENT (scaled) value. Wired into `joker_jp` (owned) + `modeled_scoring_fraction` (shop). The
  shop correctly won't buy it on an empty board and buys it beside a strong joker.
- **Burglar** — discard anti-synergy in `joker_downside`. Burglar removes ALL discards, so DISCARD-FED
  jokers (`DISCARD_FED`: Faceless/Mail/Hit-the-Road/Trading/Yorick/Burnt/Castle) and purple-seal cards go
  dead beside it — penalized two-directionally (Burglar costs more with them owned; they cost more with
  Burglar owned). **Green Joker deliberately EXCLUDED** (no discards only helps it).
- **Diet Cola** — usage gate in `joker_downside`: its Double Tag only pays on a future SKIP, and skips are
  front-loaded, so it decays with ante (~0 penalty antes 1–2 → ~its whole prior by ante 8). The
  "don't sell a strong joker to fit it" concern is already handled by the anti-churn SELL_TO_BUY guard.
- **Showman** — ⚠ was NOT missing: it's catalogued under its real game key **`j_ring_master`** (the silent-
  key gotcha — `j_showman` would never match a live joker; a duplicate I added was caught by the coverage
  guard and removed). Retuned to the owner's tier **2** and given a build-dependent model (`Eval.showman_jp`
  = base + 0.25 × best board joker) — worth more when you have a strong joker worth duplicating.

1141 tests pass; all deployed. ⭐ LESSON reinforced: a new catalogue key MUST match the live center key —
the coverage guard (`no silent-zero jokers`) catches mismatches. **NEXT idea:** DNA-style copy models could
extend to any "duplicate" joker; and Green Joker + Burglar is a positive SYNERGY not yet credited (only the
anti-synergy is modeled).

## ✅✅ THE MEASURED VALUATION NOW REACHES THE SHOP (2026-09-02, `dfba522`) — the real completion
Chasing the follow-up (the engine buying weak scalers) uncovered the load-bearing bug: **`shop_advisor.
scoring_gain` has its OWN joker valuation (tier-prior × scaling-projection) that NEVER consulted the
measured-scaler system.** So all of Tasks 1–2 reached `add_joker_marginal_fv` but **NOT the primary shop
BUY decision** — the live overlay valued Ride the Bus at ~3.78 of a boss hand (≈10 in shop units) and
recommended buying it, and that is exactly why the Task-1/2 A/Bs read neutral (the values weren't reaching
the shop). **Fix:** `Eval.modeled_scoring_fraction` bridges the measured value into `scoring_gain` (no
re-projection — the scalers project internally; pace still damps); the shop econ term now uses the
deck-aware `Eval.econ_value`. Now Cavendish (xmult) 11.99 > basic Joker 4.00 > **Ride the Bus 1.68** (was
~10), and a full board REROLLs rather than churning to buy a weak scaler.

**SIM A/B — DECISIVE n=160 (HEAD `dfba522` vs baseline `591b462` = measured values NOT reaching the shop):
NEUTRAL, confirmed KEEP.** Progress 4.144 vs 4.092 (the FIX slightly higher, Δ +0.052, p 0.53 n.s.); sign
test leans to the fix (better on 30, worse on 21, 109 tied, n.s.); tail slightly favors baseline (wins 7 vs
9, reach-8 12 vs 15 — within noise, MDE ≈ 0.23). ⚠ The n=40 first pass read scary-negative (wins 1 vs 4)
but was cascade noise on 2 known coin-flip seeds (the baseline "won" by buying the WEAKEST jokers — Ride the
Bus + green_joker — that luck into good downstream shops); n=160 dissolved it. The fix is correct for ADVICE
QUALITY (the overlay no longer tells a human to buy a near-useless scaler at 3.78-of-a-boss-hand) and
sim-neutral. Arms: `sim_out/wire_head160.jsonl` · `wire_base160.jsonl` (n=40: `wire_head.jsonl`/`wire_base.jsonl`).
⚠ Perf: `scoring_gain` now measures modeled scalers/deck-mods per shop offer (Marble/DNA run `card_add_value`
= avg_score ×2); the sim arm ran ~15% slower. Fine for now; note it if the shop-eval hot path ever matters.

## ✅ TASK 2 COMPLETE: deck-modifier jokers modeled off tier + SIM-validated (2026-09-02)
The four `deck_modifier` jokers (Midas/Certificate/Marble/DNA) had no scoring model → a flat, deck-blind
tier floor. Now each is valued off its real channel (`ad9eb45`):
- **Midas Mask & Certificate** pay in MONEY → routed through `Eval.econ_value` (jp_to_fv's econ term) with
  scoring jp ~0 (`DECK_MOD_ECON`), NOT the tier floor (which double-counts). **Midas is FACE-DECK-AWARE**
  (`CONDITIONAL_ECON`, 12/52 baseline like Business Card): no-face deck ~0, face-heavy up to 3×. Certificate's
  seal is random → flat modest prior. (Midas econ 2.0, Certificate 1.5.)
- **Marble (adds Stones) & DNA (duplicates your best card)** reduce to "value of adding a card to the deck",
  MEASURED by `ConsumableValue.card_add_value` (score delta + dilution + deck-size joker feed). Floored at a
  REDUCED prior fraction (`DECK_MOD_FLOOR=0.12`, not 0.5) because a single-card marginal at the CURRENT board
  under-states the late compounding + strategic/consistency value a snapshot can't see; the measured value
  dominates upward when a premium copy target / deck-size synergy is present.
- Balanced-deck fv: **Midas 1.60** (highest, owner prior; → ~4.8 face-heavy) > **DNA 1.44** > **Certificate
  1.20** > **Marble 0.54**. Config: `eval_function.deck_modifier_jp` / `DECK_MOD_ECON`; `joker_data` econ
  priors. 6 regression tests.

**SIM A/B (paired n=40, HEAD `ad9eb45` vs baseline `3c13617` = deck-mods at tier floor):** modeled LEADS —
progress **4.470 vs 4.250** (Δ +0.220, p 0.085), wins **4 vs 3**, reach-8 **5 vs 3**, **sign 4/0 (every
seed that moved improved, none regressed), 36/40 tied**, no crashes. ⚠ The behavioral change is TINY (Midas
buys 0→1, others ~flat) so the +0.220 is **cascade-carried, not a proven winrate lever** — same epistemic
status as the scalers (frequency ceiling: these fire ~10% of runs). It meets the correctness keep-criterion
(leans positive, no regression). Value = **advice correctness**. Arms: `sim_out/dm_head.jsonl` · `dm_base.jsonl`.
⚠ Deck-mod valuation adds `card_add_value` cost (Marble/DNA measure avg_score ×2/offer) — the HEAD arm ran ~15%
slower; acceptable but note it if the shop-eval hot path ever matters.

**➡ NEXT: the driver slot-fill follow-up** (task #22) — the engine still BUYS weak scalers (Ride the Bus 0.04)
in the shop despite advice de-prioritizing them; a `sim/driver.lua` execution path fills slots with cheap
positive-value jokers. Then Task 3 (owner-parallel tier review). See the completion blocks below.

## ✅ TASK 1 COMPLETE: the measured-scaler system is finished + SIM-validated (2026-09-02)
**Task 1 = "finish the measured-scaler system"** (owner directive: *tiers are a LEGACY FALLBACK — measure
the scalers, drop the tier floor*) is DONE. Hiker (the last unmodelled scaler) is now measured, and the whole
system was SIM-A/B'd against the pre-scaler tier-floor baseline. **Result: SAFE (neutral-to-slightly-positive,
no regression) — KEEP.** Details below; the open work is now **Task 2** (deck-modifier effects) + a follow-up.

**Hiker — DONE (`13f6917`).** A DECK-BUFFER (+5 chips/scored card, permanent) with NO joker counter to inject.
Valued MEASURED via a new **deck-buff spu** (`JV.deck_buff_delta` — paired per-hand score delta from a uniform
per-card chip buff, deck-aware): `value = deck_buff·buff_rate·N/2·spu` (`eval_function.deck_buff_scaler_marginal`,
config `D.j_hiker.deck_buff=5 / buff_rate=0.4` in joker_data). `buff_rate` = re-score CONCENTRATION (derivation
exact: it's the Σrᵢ²/s concentration, /2 the linear-ramp average — no double-count). On a standard deck ante 3
Hiker measures **0.848** (was tier-floored ~10.5) — just below a basic Joker, just above Runner.

**SIM A/B — DONE (paired n=40, HEAD 13f6917 vs baseline 7911554 = pre-scaler tier floor).** Measured scalers
lead: progress **4.250 vs 4.171** (Δ +0.079, p 0.43 n.s.), wins **3 vs 2**, reach-8 **3 vs 2**, sign **6/5, 29
tied**, NO crashes. The 29/40 ties + near-identical scaler BUY counts (RtB 4/4, runner 2/2, hiker 3/3) confirm
the FREQUENCY CEILING: scaler valuation rarely flips a decision → it can't (and needn't) move an n=40 winrate
verdict. Its value is **advice CORRECTNESS for the human overlay**, and the change meets the keep criterion for
a correctness fix (ship unless significantly negative — it leans positive). The sim can't adjudicate the FINE
calibration (Runner 2.49 vs Supernova 1.02 etc. are invisible at this n); that stays owner domain knowledge.
Arms on disk: `sim_out/scaler_head.jsonl` (measured) · `sim_out/scaler_base.jsonl` (tier floor).

**⭐ FOLLOW-UP found during the A/B (separate lever, NOT the scaler valuation).** The engine still *buys* the
near-useless Ride the Bus (measured 0.04) ~4×/40-run in the SHOP — but its ADVICE de-prioritizes it (only **2
buy-advices for RtB in the whole 40-run arm**; the ticks recommend Ramen/Blueprint/reroll/save). The buys come
from a DRIVER slot-fill / low-positive-value execution path (identical in BOTH arms, so not caused by the
scaler change). Worth a pass: the driver executes cheap positive-value buys to fill a slot even when the
headline advice says otherwise — the "over-buy weak jokers early" pattern the owner has flagged. See
`sim/driver.lua` buy loop vs the single top-line advice.

---

## (historical) The "proceed" plan that produced the above — Task 1 progress log

**DONE + committed this session:**
- **Resetting scaler** (Ride the Bus) — `97227b6`. Valued at its geometric EQUILIBRIUM (measured per-unit ×
  `inc*p/(1-p)`, p = P a scored hand is face-free). 7.875 → 0.04. Anti-synergy (Sock&Buskin/Pareidolia)
  falls out of p. Also `46eb53f` (a projection damp, now largely superseded by the equilibrium path).
- **Accumulating joker-counter scalers** (Runner/Square/Supernova/Green) — the checkpoint just committed.
  Value = measured-per-unit (counter injection) × projected avg counter, NO tier floor. Per-joker `inc` +
  `scale_rate` in `joker_data.lua` (after the catalogue). **Owner-calibrated ranking: Runner(2.49) >
  Supernova(1.02) > Square(0.74) > Green(0.64).** Runner inc fixed 8→**15** (owner data catch). Supernova
  reads `gs.run.hand_type_plays` (not a counter) → measured via a generic mult proxy + existing-plays head
  start (`e.head_start`). Key fns in `eval_function.lua`: `scaler_marginal` (resetting), `accumulating_
  scaler_marginal`, `scaler_spu` (counter injection; mult-proxy for run-state jokers), `face_free_prob`.

**✅ DONE (both items — see the completion block at the top):**
1. **HIKER** — measured deck-buff valuation shipped (`13f6917`). 10.5 → 0.848.
2. **SIM A/B** — paired n=40 vs the pre-scaler tier-floor baseline: SAFE (neutral-to-positive, no regression).

**⚠ TWO LESSONS baked into the above:** (a) *don't anchor to Runner* — it's just a joker the engine happened
to pick; measure all scalers correctly and let values fall out. (b) *PULL REAL GAME VALUES, don't guess* —
two data errors this session (Runner inc 8→15; earlier Hologram ×0.1→×0.25) were both in NEW code.

## Task 2 (after Task 1): MODEL the deck-modifier effects
Midas Mask (gold econ), DNA (deck→four-of-a-kind), Certificate (seals), Marble (stone) are `deck_modifier`
jokers valued off TIER (effects not scored). Midas likely highest value. Medium-hard.

## ✅ Task 3 COMPLETE (2026-09-02, `07b7ba4`): owner tier review of the genuine-utility jokers
Applied the owner's 0–10 judgments to the utility jokers' tier prior (their whole valuation — they don't
score): Chaos 3→6, Turtle Bean 3→5, Oops! 5→6, Invisible 6→7, Burnt 6→7, Juggler 3→4, Drunkard 3→4, Credit
Card 1→2, Mr. Bones 6→5, Troubadour 5→4, Chicot 8→6. Held: Space 5, Burglar 5, Luchador 3, Diet Cola 3,
Merry Andy 4, Matador 3. Shipped on correctness (fire rarely, no A/B).

**⭐ BEYOND-TIER follow-ups the owner raised (tier can't capture these — future synergy/modeling work):**
- **Invisible Joker** is NOT modeled as a copier at all (flat tier prior, unlike Blueprint/Brainstorm). Owner
  asked: when it duplicates a SCALING joker, does the copy inherit the current scaled state? The engine
  doesn't model its copy value yet — worth a DNA-style "value = copy your best joker" model (and verify the
  scaling-inheritance game mechanic).
- **Burglar** anti-synergy with DISCARD jokers (Mail-In Rebate, purple seals) — it removes all discards. A
  downside-modeling opportunity (`joker_downside`).
- **Oops! All 6s** — synergy with probability jokers is already modeled (`PROB_ECON` ×2); note the small
  anti-synergy with Glass cards (doubles the shatter odds).
- **Diet Cola** value is conditional (needs spare money + a free slot + a planned skip to buy-sell for the
  Double Tag) — a usage-context gate, not a flat prior.
- **Showman** is NOT in the catalogue at all — needs adding if the owner wants it valued.
- **Matador** stays UNMODELLED/acquisition-gated (no boss-trigger model); un-gating needs a boss-econ model.

## Earlier this session (2026-09-01) — SHIPPED live-run fixes (all deployed, corpus-checked)
- **The Mouth** (`316f29b` populate `played_hand_types` live + `7911554` first play must be a REPEATABLE
  hand type — the cheap overlay pass is survive_after-blind and the self-player acts on it).
- **MILK** deferring a trivial clear on illusory held-gold (`71dedb3`) + Midas gold-exclusion in HoldFuel.
- **Reroll escalation damp** (`96b56b1`) — MEASURED WIN: eng_reroll_human_save 120→109 (was the money-bleed
  behind the "sold Fibonacci" death; the churn was the symptom, the reroll spree the cause).
- **Anti-churn generalised** (`0597c14` SA.stb_funder_allowed — plain scorers were churned) + card-generation
  (Vagabond) churn protection (`d268ff6`).
- **Mystic Summit play-timing** (`84dd375` defer_uplift — dig to 0 discards). **Ride the Bus face
  anti-synergy** (`46eb53f`). **level_need planet freq-gate** (`15e35af`).
- Full owner-observation log: `ADVICE_REVIEW.md` R4. Method: reconstruct the misplay from telemetry
  (`bes_fixtures.jsonl` **state** records carry the full `gs`), fix, regression-test, corpus/sim A/B.

---

## ⭐ IN-BLIND PLAY + HOLOGRAM + JOKER AUDIT (2026-08-31) — from more live self-player runs
**Joker-model audit (owner flagged a 0.1-vs-0.25 error).** It was a typo in NEW credit code, NOT the
model: `sim/joker_tick.lua` had Hologram correct at ×0.25. Swept all scoring constants (joker_effects)
and growth increments (joker_tick) vs the real game — ALL correct. Models are trustworthy.

**Hologram never scaled** (`2cee18b`) — `card_add_value` measured a card's deck contribution via
avg_score, which reads a scaler's CURRENT counter, so the deck-size scalers' gain was invisible and
Standard cards stayed ~0.05. Added `CV.add_card_feed`: Hologram +×0.25/card (board-scaled, capped),
Blue Joker +2 chips/card; Erosion (fed by REMOVING) excluded.

**In-blind play fixes** (owner: plays best hand even when it can't clear; spends build cards):
- **Dig-play out of discards** (`7168a99`) — with no discards + no clear, play CHAFF to cycle (keep
  build cards), arbitrated by survive_after E[frac]. Safe/narrow.
- **Retention tie-break** (`1374909`, `hand_eval`) — among EQUAL-score plays, keep the more valuable
  cards (don't spend a face as a useless kicker). Gated tier<2 (pre-clear only; a spent card returns
  after a clear). Fixed "played a face it needed as a 2-pair kicker with chaff available."
- **Faceless econ credit** (`1a2e3f1`) — the measured discard now includes the discard_econ money its
  pitched cards earn, so a hand-improving discard that also dumps 3 faces isn't under-valued.

**⭐ HUMAN-VALIDATED FINDING (mined the 7 winning runs, `data/agreement_corpus/runs.jsonl`):** the
winning in-blind style is **dig hard, play one big hand** — humans DISCARD **57%** of decisions
(~2.9/blind, often clear in 1 play); the engine discards **41%** on those same states. A uniform +0.05
dig bias was **REFUTED** (`b5f2165`): discard rate moved only 41→42% and blind class-agreement FELL
430→424 (it dug where the human PLAYED). ⇒ the engine under-digs SITUATIONALLY (commit-to-a-line
judgment = the build-commitment wall), not uniformly. **Econ ground truth:** winners build to ~$40 by
ante 3-4 and HOLD **$34-40** through the endgame (never single digits mid/late). The engine dropping to
single digits is the gap. **FIXED + MEASURED (`e170265`): an ante-aware econ floor** (`SA.econ_floor`)
ramps $10->$25 (interest cap) over antes 1-4, preserving the buffer while leaving surplus-above-cap free.
Agreement A/B (shop): agree_save 278->298 (+20), eng_buy_human_save 281->276, eng_reroll_human_save
136->120 -- ~21 over-spend buys/rerolls flipped to SAVE, ~20 matching the human (flips the RIGHT
decisions, unlike the refuted dig bias). Holding PAST the cap (the human's $34-40) is option-value
banking -- the remaining unsolved econ lever.

## ⭐ THREE LIVE-RUN OBSERVATIONS — now FIXED (2026-08-30)
1. **Banner** (`e693975`) — `DV.measured` scored the redraw on the original gs, crediting the discard as
   free; for discards_left jokers (Banner +30 chips/remaining discard) that over-valued discarding, so
   the engine discarded away Banner's chips. Now scores the redraw with `discards_left-1`. No-op for any
   deck without Banner/Mystic Summit (the only readers).
2. **Red Card** (`63d41f1`) — `scaling_mult` that grows +3 Mult per BOOSTER SKIP; the engine couldn't
   express feeding it. `pack_open_advisor` now skips a WEAK pack to feed Red Card (board-amplified,
   bounded ≤0.15 frac so a real pick always wins; gated on owning Red Card).
3. **Over-skipping** (`6249773`) — `blind_select_value` priced only on-select generators, ignoring the
   in-blind value only PLAYING realizes (scalers grow, Faceless/Mail/Trading farm). Now credited, so a
   scaler/farm board skips less. NOTE: the early strong-tag skips seen (Rare/Negative/Buffoon/Orbital)
   are mostly JUSTIFIED; if over-skipping persists in a fresh run, the lever is a MEASURED
   `SK.SKIP_MARGIN` adjustment (skip fires 100% of blind-selects — the one high-firing class worth a sim A/B).

Shipped this session AFTER the block below: the "stuck on SAVE" freshness-deadlock fix (`44826dc`),
atomic one-action-per-recommendation (Jupiter+Saturn + pack make-room, `318d146`), pack "never take a
joker into a full board" demote-or-skip (`e48e6d2`), the **interest-cap unit fix scoped to value-buys**
(`4007b36` — see the `interest-cap-unit-fix-scoped` memory: do NOT revert as conversion_baseline's
"reverted" one), and **don't-acquire-unmodelled-joker (Matador)** (`c70447c`, `JokerData.UNMODELLED`).

## ⭐ CURRENT STATE (2026-08-30) — the IN-GAME SELF-PLAYER + the autonomous review loop

**A working in-game self-player was built** (`ui/autoplay.lua`, toggle **F11**, default OFF). It
translates the engine's live recommendation into REAL Balatro inputs — it plays whole runs unattended
(blind select/skip · play/discard with joker **reorder** · cash-out · shop buy/sell/reroll/leave ·
buy+open packs · pick from packs incl. **card-tarot targeting** · use held consumables · use card-tarots
with target selection). It completed a full run (ante-4 death). **Point of it:** a real-game,
unlimited-sample bug-finder for the OVERLAY's advice — no sim-fidelity doubt, no tiny-corpus limit. Actuation
notes (learned the hard way): invoke the REAL UI button node (found via `config.button`), never a fabricated
event (crashes on `e.UIBox`); Play/Discard live under `G.STAGE_OBJECTS`; boosters buy via `use_card`; SELECT
and CLICK must be on SEPARATE frames (`can_play`/`can_use` lag a frame); a deadlock-breaker acts after 3s if
the decision flickers. Logs to `bes_autoplay.log` in the save folder (the in-game logger only print()s).

**The autonomous review loop (owner directive): CLAUDE does the analysis, not the owner.** The owner
generates in-game runs (I can't drive Balatro), OR — for DECISION quality — I run the **headless sim myself**
(same engine, same decisions; only outcomes are modelled) and analyse the traces. First loop run
(`sim_out/churn0.jsonl`, n=48) DEBUNKED the joker-churn hypothesis: churn is real (2.4 bought-then-sold/run,
driven by SELL_JOKER upgrades) but its harm is a **run-length CONFOUND** — raw corr(churn,reach)=+0.61 but
corr(#shops,reach)=+0.934 and de-confounded corr(churn-per-shop,reach)=**+0.074 (flat)**. So the n=1
`XAXGTK5S` impression ("churn killed it") did NOT survive scale — **no churn fix**; it died with the right
pieces one blind too late (the conversion wall). The loop caught a spurious fix before shipping it.

**Engine fixes shipped this session** (deployed, 1100 tests pass): Judgement/generator make-room now
output-quality-aware (don't take a RANDOM joker into a full board); Riff-Raff slot-farming (sell a
disposable common to reopen a spawner slot — mechanism-justified, outcome-unproven); `best_targets` covers
ALL card-targeting tarots + spectrals (Strength/Death/Hanged-Man/seals/Aura); the pack-poverty damp
(bank toward the interest cap before gambling on a pack — SAFE + advice-positive). Reverted: the
`interest_cap` unit fix (correct but regressed agreement — winners over-bank; see `conversion_baseline.txt`).

**Advice-quality A/B harness** (`tools/agreement_run.sh`): replay the frozen 7-win corpus under the current
engine → per-decision agreement diff. **Conversion investigation** (`CONVERSION_PLAN.md` +
`conversion_baseline.txt`): the gap is ECONOMY/SPEND discipline, not valuation (C' refuted: engine ranks the
human's multiplier #1 91% of the time) — the frontier is assembly TIMING (core lands ante 4 not ante 2-3).

---

# (previous handoff) 2026-08-28 — the advice-quality + sim-fidelity session

> **THE OBJECTIVE PIVOTED to ADVICE QUALITY this session** (the pivot the old §"if the objective ever
> shifts" section below anticipated). The mod advises a *human who wins ~87.5%*; autonomous winrate is
> ceilinged (below) but advice quality is a different, non-compute-bound objective. Read this top block
> for the current state; `ADVICE_REVIEW.md` (the human's run observations + fixes) and
> `JOKER_FIDELITY_AUDIT.md` (the sim-fidelity work) hold the detail. `GRAND_AUDIT.md` + `MCTS_PLAN.md`
> remain the authoritative record of the *winrate-ceiling* investigation (unchanged, still true).

## CURRENT STATE (2026-08-28) — the advice-quality + sim-fidelity session

Three big threads, all shipped/deployed (live install CURRENT, verified byte-identical; 1100 engine +
604 sim tests pass, the 1 sim fail is a pre-existing unrelated overflow test):

1. **Advice-review fixes** (`ADVICE_REVIEW.md`) — the owner played runs with the overlay live and
   catalogued every decision. Shipped: the **anti-churn SELL_TO_BUY live-funder gate** (was dumping
   Cloud 9 / Astronomer / polychrome Ice Cream for junk — the run-killer), the **active money-dig**,
   **held-consumable use** (Hermit), **pack-first sequencing**, **free-planet picks**, **debuff-first
   discard**, and UX (Play-blind at a boss, pack-pick target text, cost/size in the big line).

2. **⭐ JOKER SIM-FIDELITY (`JOKER_FIDELITY_AUDIT.md`) — the sim was FLATTERING the engine.** The sim
   paid many jokers a flat `econ` $/round they never actually earn (Faceless flat $3 vs its real
   $5-per-3-face-discard, etc.). Audited all 150 jokers; **25 of 26 gaps now faithfully modelled** (only
   Matador deferred — needs a boss-trigger event bus). **Result, measured: the faithful world HALVED the
   sim winrate (5.0% → 2.5%)** — proving the old number was inflated. The sim now measures the same
   reality the overlay faces, which makes future overlay work trustworthy instead of fake.

3. **⭐ IN-BLIND ECON SYSTEM (two channels, `engine/discard_fuel.lua` + `engine/hold_fuel.lua`).**
   *Discard channel*: farm/feed every applicable joker by discarding — Faceless (faces), Mail-In (rank),
   Trading (single), Hit the Road/Castle/Yorick (scaler-feed) — with a **harm guard** (hard-refuse to
   bleed Ramen's xmult; soft-penalise Green Joker). *Hold channel*: farm Reserved Parking / gold by
   playing a MINIMAL hand and HOLDING econ cards (held money is now credited inside the survival rollout
   so MILK fires the multi-hand farm). Plus an **aggressive farm** (break the winner to farm when
   `survive_after` confirms a spare hand re-clears — hardened to a 99% gate / 3-hand min / 2× samples
   after an early version measured −2 wins; the fix returned it to neutral).

**The measured verdict on the econ work: SAFE + CORRECT + sim-NEUTRAL** (full system vs active-dig
baseline: 8.3% = 8.3%, wins 4 = 4, only 9/48 seeds touched). It is real value on the *overlay* (the human
converts money into builds) but the sim's greedy engine still doesn't convert — **the winrate wall is
CONVERSION, not econ generation.** That is the unobstructed frontier: turn farmed money into a directed
supermodular build (copiers × xmult × the hand being built toward).

**➡ THE CONVERSION FRONTIER NOW HAS A PLAN: `CONVERSION_PLAN.md`.** The load-bearing reframe: every
prior conversion verdict (oracle_plan §24, additive family §31, target/completion model §32c, product
board-scorer P4) was rendered on the **ceilinged autonomous-winrate instrument** — NONE on the
**advice-quality / agreement instrument** (`replay_fixtures.lua` + `agreement.py`). So the target/product
family is *closed on winrate and OPEN on agreement*. The plan attacks it agreement-first (winrate becomes
a safety rail, not the target): Phase A = baseline the agreement report (no code); B = resurrect
`completion_credit` and judge it on agreement not winrate; C = a forward marginal on the committed target
board (fixes the root cause — `sgain` is a present-board marginal, `shop_advisor.lua:516`,678); D = the
pack-pick conversion channel (41% agreement, the biggest gap). Start at Phase A.

## The autonomous-winrate ceiling (UNCHANGED — the audit trail)

The engine is mature and correct; **autonomous** winrate (baseline ~2.5%) is a *policy/assembly* gap
(not supply — Phase 0a) that is **not closable with the current apparatus**: the value function is the
wall, and that wall is compute/data-bound beyond a few nights of local compute. Consolidated at the
ceiling. Details below + in `GRAND_AUDIT.md` / `MCTS_PLAN.md`.

## The load-bearing findings (all in GRAND_AUDIT + MCTS_PLAN, with tools)

- **The 2.5% ceiling is POLICY, not supply.** `tools/stream_oracle.lua`: 70% (baseline) / 92% (rich) of
  LOST runs were *offered* ≥2 affordable multiplier keystones and passed them up. The old "supply
  ceiling / no policy can manufacture offers" verdict is overturned (offers are endogenous —
  rerolls/packs/tags/vouchers manufacture them).
- **Every present-state lever is closed/bounded on a cheap screen:** P1 slots (correctness keeper), P3
  scaler-demotion (null, reverted), P2a interest-horizon (correctness keeper, winrate-null OOS), P4
  product board-scorer (bounded weak), plus the whole §31 additive/economy family.
- **The search machinery works but the value function is the wall.** `Driver.fork`/`Driver.rollout`
  built + byte-identical determinism proven; `sim/search.lua` makes sensible picks — but the rollout
  evaluator is infeasible (~42s/decision, in-blind `best_play` cost). The cheap analytic value (=
  `pace_margin`/`capacity`) is what the greedy engine already uses, and **no learned value beats it
  out-of-sample** — confirmed FOUR ways: P5 CV (`winprob_headroom.py`), NNUE piece-level OOS
  (`richeval_probe.py` — in-sample +0.13 was winner's-curse), and interactions + TD OOS
  (`offline_value.py`). Capacity is a MC score projection that already integrates the board's
  multiplicative structure; it is the achievable cheap-value ceiling on this data.
- **⇒ A feasible search can't beat greedy (same cheap value); a better value is infeasible (rollout) or
  non-generalizing (learned, data wall).** The winrate gap is real but not closable this way.

## What WOULD break it (all beyond a few nights of local compute — declined by the operator)

1. **Brute-force ~1,300–3,000+ training wins** for an NNUE-style piece-level value → ~3–8 nights at
   rich10 (~17.5s/run wall on 6 cores), *uncertain payoff* (the generalizable features are saturated;
   piece-level may need 10k+ wins).
2. **GPU self-play (AlphaZero-lite)** — the only option that breaks the data wall (bootstraps its own
   training data), but CPU-bottlenecked by sim speed (~20 days for ~100k games) and a multi-week build.
3. **(Enabler) sim speedup** — a faster in-blind play would unlock both, but risks the sim fidelity that
   makes its value signal valid.

## Durable assets from this session (the lasting value)

- Apparatus: hardened per-decision **agreement objective** (`agreement.py` guards + `replay_fixtures`
  pipeline, validated on the 14-win save-folder corpus); **tail-weighted verdict** (reach-7/8 + McNemar
  in `analyze_runs.lua compare`); the **search scaffold** (`Driver.fork`/`rollout`, `sim/search.lua`).
- Diagnostics (each precisely bounds one part of the problem): `stream_oracle.lua`, `leaf_value_auc.py`,
  `winprob_headroom.py`, `richeval_probe.py`, `offline_value.py`, `supermodular_headroom.lua`.
- Live install is CURRENT (P1 + P2a deployed 2026-08-26; backup at
  `%APPDATA%/Balatro/bes_install_backup_20260826`).

## If the objective ever shifts from AUTONOMOUS winrate to ADVICE quality

The mod advises a *human* (who wins 87.5%). That is a **different, measurable objective** (the agreement
objective vs the winners' picks) and is NOT compute-bound. Overlay-advice improvements that align with
winners are shippable on that objective even when they are winrate-null autonomously (e.g. P2a). This is
the natural pivot if winrate is treated as ceilinged. See `GRAND_AUDIT.md` §G1.

## Audit trail

The detailed section-by-section history is archived (moved 2026-08-26): `docs/archive/WINRATE_V3_PLAN.md`
(§-citations in GRAND_AUDIT resolve here), `docs/archive/WINRATE_AUDIT.md`, `docs/archive/WINRATE_AUDIT_v2.md`.
