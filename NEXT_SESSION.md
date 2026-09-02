# NEXT_SESSION.md — fresh-session handoff (2026-09-02)

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

## Task 3 (OWNER doing in parallel): tier review of the ~18 genuine-utility jokers
Where tier legitimately IS the value: Chaos, Space, Burglar, Mr. Bones, Matador, Chicot, Invisible, Burnt,
Troubadour, Oops!, Showman, Merry Andy, Turtle Bean, Luchador, Juggler, Drunkard, Diet Cola, Credit Card.
Owner annotates 0–10; apply as the fallback beneath the measured system.

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
