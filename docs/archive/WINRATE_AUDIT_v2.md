# WINRATE_AUDIT_v2.md — full-project winrate investigation (2026-07-11)

> **Successor to `WINRATE_AUDIT.md` (2026-07-05).** That audit's Phases 0–5 are complete or in
> progress and its implementation logs remain the authoritative history. This document re-audits
> the ENTIRE project against the current retained working tree (baseline
> `sim_out/p5_commit.jsonl`: death-ante **3.663**, progress **3.345**, **0/160 wins**, 120 BUILD /
> 40 VARIANCE deaths; 783 unit + 195 sim tests green), treating every prior conclusion as a
> hypothesis. Method: full read of all engine/sim/tool code (~19k lines), all planning documents
> and experiment logs (rounds 1–22 + Phases 0–5), and fresh data-mining of the n=160 baseline
> (keystone offer/take rates, voucher purchases, death-board composition, held-consumable
> occupancy, shop-advice distribution).
>
> **Verdict in one line: the v1 story ("the wall is build-assembly; the planner is the next
> lever") is only half right — the keystone-acquisition pipeline is still MECHANICALLY broken in
> three places the v1 fixes did not reach, the sim still cannot express a core part of the
> winning archetype (joker order / Blueprint), the engine pays real money for effects the world
> does not implement, and the strongest in-blind lever ever shipped (F1/F2) is silently disabled
> in ~2/3 of mid-game states. All of these are unit/mechanism-class fixes — the ONLY class that
> has ever shipped safely — and every one of them should land before more planner tuning.**

---

## 1. Executive summary

The project's proven rule — *ship unit/mechanism/correctness fixes freely; any isolated
measurement/value re-weight that doesn't co-move its tuned guardrails backfires* — held across
every phase and is re-confirmed by this audit. The productive question is therefore: **what
unit/mechanism defects remain?** This audit found a substantial set, several of them exactly on
the causal path to the winning archetype (an xmult stack that is kept and fed):

1. **W2 — Keystone acquisition is still broken on full boards, mechanically.** In the n=160
   baseline, the hand-conditional xmult keystones were *offered and affordable* dozens of times
   and almost never taken: **The Trio 0/5, The Family 0/4, Blueprint 1/5, Brainstorm 1/8,
   Ancient 1/8** (§4.1). Cause, confirmed in code: (a) on a full board an affordable keystone
   never enters the action list at all (`slots_free > 0` gate, `shop_advisor.lua:607`) — its only
   route is the SELL_JOKER upgrade-swap; and (b) **the swap valuation's accounting is
   incoherent** — it charges the sold joker's contribution twice (`shop_advisor.lua:890`
   subtracts `worst_c` inside `upgrade`, then `:894` subtracts `W_FV*worst_c` again), never
   charges the buy's dollar cost (`buy_fv_delta` is uncosted), never credits the sale's cash
   (`money_w` is 0 unless the joker is dead), and skips the `w_score` situational weighting the
   direct-buy path gets. These errors partially cancel in an uncontrolled way; the observed net
   is that keystones lose to vouchers/packs. The exact flaw all three human wins exposed
   ("engine skips/sells the keystones") is still live, one arithmetic layer deeper than C2/C3
   fixed.
2. **W3 — The sim world has no joker-reorder action.** Balatro players reorder jokers freely
   (additive left of ×mult; Blueprint left of its target); the sim keeps acquisition order
   forever. Consequences: every board holding an xmult under-scores relative to a human with the
   identical jokers (additive contributions bought after the xmult are never multiplied), and a
   bought **Blueprint sits in the last slot copying nothing** — permanently dead — even though
   the engine (correctly, post-C3) valued it at its best insertion. This is a world-fidelity gap
   of the A1-class: it suppresses precisely the compounding-xmult payoff the winning archetype
   needs, and it has been invisible because engine and world agree (both score the stored order).
3. **W4 — Engine↔world feature inconsistency, both directions.** The engine pays for benefits
   the world does not implement: **Hieroglyph bought 26/160 runs** — the world implements only
   the −1-hand downside (the −1-ante benefit is a documented no-op), so the engine pays $10 to
   permanently lose a hand every round; Director's Cut (7 buys) and Magic Trick (4) are pure
   $10 no-ops; Blue/Purple seals are valued but inert in the world; Credit Card's −$20 credit is
   honoured by the engine's affordability check but rejected by the world's `apply_action`,
   which **ends the shop phase early** on the first rejected action. The reverse direction (A5's
   "world pays what the engine never takes") was fixed in v1; this direction was never swept.
4. **W5 — The best in-blind lever is off most of the time.** The F1/F2 survival arbitration
   (+0.038, sign 31/18 — the strongest single-lever signal of the effort) is gated on
   `#consumables == 0` (`decision_engine.lua:500`). After the leveling fixes, the engine *holds*
   planets/tarots as intended: **~65% of ante-boundary snapshots hold ≥1 consumable** (in-blind
   occupancy is somewhat lower since uses fire mid-blind; exact per-decision coverage is step 1
   of E-5), so the arbitration is silently disabled across a large share of the mid-game. It is
   also never applied on the
   last hand (`forced_play`), where the mean-rule dig gate still lives — even though
   `Sim.survive_after`'s E[frac] objective is exactly the partial-credit-aware form whose absence
   caused the F3 revert.
5. **W1 — The verdict metric is not winrate-monotone.** Every A/B since Phase 0 optimizes mean
   progress / death-ante. Wins live in the far tail (only 15/160 baseline runs reach ante 6+),
   and a lever that fattens the tail while leaving the mean flat is currently invisible —
   and vice versa. The project's stated objective (true winrate) needs tail-sensitive verdicts
   (P(reach ante 6+/7+), win count) alongside progress, plus a cheaper way to measure in-blind
   policy changes than full-run cascades (a state-replay harness, §16 E-9).

The build-side prize is unchanged — assemble and keep a compounding xmult core — but the v2
diagnosis is sharper: **before more Phase-5 planner refinement, repair the acquisition mechanics
(W2), the order fidelity (W3), and the consistency holes (W4)**, because the planner's fit
credits currently push against a pipe that is still pinched shut, and Phase-3's "greedy valuation
can't assemble a deck" conclusion was partially confounded by W2/W3 in the same way the original
"architectural wall" conclusion was confounded by the broken world.

---

## 2. Current engine assessment

**Baseline (n=160 paired, byte-deterministic seeds `s*1000+3`):** mean death-ante 3.663, progress
3.345 (median 3.624), 0 wins, death mode ante 4 (46), 120 BUILD / 40 VARIANCE deaths, 92/160
deaths on Boss blinds (median clear-ratio 0.60).

Fresh data-mining of `p5_commit.jsonl` (this audit):

- **Death boards are xmult-poor and under-leveled**: 66/160 die with **zero** xmult jokers,
  52 with one; mean 0.91 xmult/board. 41/160 die with **zero** hand levels (median ≈2; the
  analyzed human wins had 15–27). Board econ share ~0.8 jokers/board.
- **Keystone exposure is NOT the constraint**: 104 keystone offers (Duo/Trio/Family/Order/Tribe/
  Blueprint/Brainstorm/Baron/Ancient/Vampire/Lucky Cat/Constellation/Hologram/DNA) across 160
  runs, 78 affordable at offer time. Non-slot-gated ones are taken (Hologram 6/7, DNA 9/12,
  Vampire 7/12); the full-board-era ones are not (Trio 0/5, Family 0/4, Ancient 1/8 — §4.1).
- **Economy**: median $4 at ante 1, **$1 at ante 2** (the engine spends to near-zero early),
  $19–28 at antes 4–7. Ante-1/2 deaths = 42/160 (26%).
- **Shop advice distribution** (per offer-state record): SAVE 571, BUY_JOKER 509, BUY_PACK 468,
  REROLL 215, SELL_JOKER 170, BUY_CONSUMABLE 169, SELL_TO_BUY 149, BUY_VOUCHER 113. 690 packs
  opened, 411 joker sells (~2.6/run), F6 shop-funding fired 5 times total.
- **Vouchers bought**: hieroglyph 26 (strictly harmful in-sim, §4.3), seed_money 22, grabber 20,
  telescope 13, wasteful 12, paint_brush 11, directors_cut 7 (no-op in-sim), magic_trick 4
  (no-op in-sim).
- **Planner V1**: 54/160 runs commit (Straight 20, Full House 13, Two Pair 7, Pair 6, Flush 5);
  106 runs byte-identical to pre-planner.
- Skip decisions: 341/1144 offers taken (30%); orbital/charm/investment/buffoon lead.

**In-blind play** remains near-optimal per-hand (verified in v1 and unchanged); the sequential
policy improved with F1/F2 but is coverage-limited (W5). Scoring/facts layer is in the best shape
it has ever been (A1–A9, B/C/K fixes); remaining facts gaps are catalogued in §12.

---

## 3. Overall strengths (do not relitigate)

- **The measurement discipline** — paired byte-deterministic A/B at n≥160, sign test + progress
  delta, mechanism verification before KEEP, honest revert logs. This is genuinely
  research-grade and the reason the project can still find real defects.
- **The pure-engine / POD architecture** and the FACTS/OPINION wall. Every defect this audit
  found was findable *because* the system is headless and deterministic.
- **The facts layer** (hand_eval scoring pipeline, contains-semantics, retriggers, editions,
  boss effects) — v1's full sub-audit stands; nothing new wrong was found in scoring itself.
- **The revert-set lessons** (C1, B3, F3, F4, F8, swap-damp, coupled…) — the #1 tuning rule is
  real and this audit's recommendations are deliberately shaped to respect it: almost everything
  proposed below is a unit/mechanism/fidelity fix or a coupled, explicitly-experimental change.
- Telemetry richness (per-offer valuations, per-hand play logs, death-type split) — the §4
  findings took an afternoon to quantify *because* the data was already there.

---

## 4. Critical weaknesses (the headline findings)

### 4.1 W2 — the keystone pipeline is still pinched shut (CONFIRMED: code + data)

**Data.** Keystone offer/take from `p5_commit.jsonl` (`value` = the engine's logged action value;
`nil` = the buy action never entered the ranked list):

| key | offers | affordable | taken | logged BUY values |
|---|---|---|---|---|
| j_trio | 5 | 5 | **0** | nil (all) |
| j_family | 4 | 2 | **0** | nil (all) |
| j_ancient | 8 | 6 | 1 | nil (all) |
| j_blueprint | 5 | 3 | 1 | nil (all) |
| j_brainstorm | 8 | 2 | 1 | −2.63 |
| j_baron | 5 | 3 | 2 | nil |
| j_duo | 10 | 7 | 5 | 2.36–4.77 |
| j_hologram | 7 | 4 | 6 | 22.6 |
| j_vampire | 12 | 11 | 7 | 21.4–30.8 |

Sample refusals: seed 23003 ante 4, Trio $8 with **$61** in hand → advice `BUY_VOUCHER
v_tarot_merchant`; seed 17003 ante 5, Trio $8 with $65 → `BUY_VOUCHER v_crystal_ball`; seed
104003 ante 5, Trio $8 with $44 → `BUY_PACK Jumbo Standard`.

**Mechanism (three interlocking defects).**

1. **Full-board exclusion from the action list.** `shop_advisor.lua:607` pushes a BUY_JOKER
   action only when `slots_free > 0`. The board is full from ~ante 3 (median 5 jokers), so an
   affordable keystone is simply *not a candidate action* — `value=nil` in the trace. It is also
   not a SELL_TO_BUY candidate (that path requires `not affordable_now`). The only route is the
   SELL_JOKER upgrade term.
2. **The upgrade-swap accounting is incoherent.** `shop_advisor.lua:889–894`:
   ```lua
   upgrade = math.max(0, upgrade - worst_c - sell_margin)          -- net improvement, minus margin
   ...
   local value = money_w*eff_cash + SA.W_FV*(upgrade + nudge + sbonus) - SA.W_FV*worst_c
   ```
   The true net of "sell weakest, buy X" is `g − worst_c − net_cost(price) + cash_value(sale)`,
   hysteresis-gated by `sell_margin`. The code instead produces `g − 2·worst_c − sell_margin`
   (in `W_FV` units): the sold joker is charged **twice** (once inside `upgrade`, once at
   `:894`), the buy's dollar cost is charged **never** (`buy_fv_delta` is uncosted), the sale's
   cash is credited **never** (`money_w = 0` unless the joker is dead), and the `w_score`
   situational multiplier the direct-buy path gets is absent. The errors partially cancel in an
   uncontrolled, state-dependent way. Worked example of the dominant term: weakest contributes
   1.0 FV, margin 1.2, keystone measures 3.0 FV → true net gain 2.0 clears the 1.2 hysteresis,
   but the action values at `2.0×0.8 − 2.0×1.0 = −0.4` → SAVE wins. C2 opened the *gate* for
   keystones; the *arithmetic* still keeps them out. (Also: `n_contrib` at `:806` is computed
   and never used — the B2 only-scorer guard it fed was refactored away; the only-scorer
   protection now rests solely on `dead = worst_c <= 0.1`.)
3. **Copiers still measure ≈0 on the boards that most need them.** The new analytic
   conditional-xmult floor (`eval_function.conditional_xmult_marginal`) covers only the five
   COND_XMULT keys and only on the FV paths (`jp_from_measure`) — `scoring_gain` (the direct-BUY
   frac path) has no analytic floor, and copiers (Blueprint/Brainstorm) have none anywhere: their
   value is `max(measured, 0.6×tier-prior)` where measured is a 6-sample MC of copying a weak
   board. Seed 123003 sold a Jolly to free a slot and then still SAVEd rather than buy Blueprint
   at $13/$15.

**Impact.** This is the single most direct causal chain to 0 wins: all three human wins ran a
kept contains-xmult stack; the engine cannot assemble one because the mid-game acquisition path
(full-board swap) taxes keystones ~double, and 66/160 boards die xmult-less. **Fix class:
unit/mechanism (ships per the #1 rule), but re-measure paired — raising swap frequency risks
churn, so watch the sign test and the sell counts.** See E-1/E-2 (§16).

### 4.2 W3 — the sim's action space is missing REORDER (CONFIRMED: code)

`sim/world.lua` / `sim/content.lua` never reorder `run.jokers`; acquisition order is scoring
order forever. Two consequences:

- **Additive-after-xmult loss.** Joker effects fold left→right, so a +mult joker bought after an
  xmult joker lands *after* the multiply: board `[×2, +10mult]` scores `base_mult×2 + 10` while
  a human orders `[+10, ×2]` for `(base_mult+10)×2`. The loss is `f×(x−1)` mult per misordered
  flat — typically 10–30% of final mult on the 94/160 death boards that own an xmult (E-3's
  micro-benchmark quantifies it exactly). The engine's
  `ordering.lua` computes the right order as an in-blind *tip*, but nothing in the sim applies
  it; engine and world consistently agree on the wrong order, so no test ever caught it.
- **Blueprint is dead-on-arrival.** Blueprint copies the joker to its RIGHT; appended at
  purchase it copies nothing until a later purchase happens to land after it — the C3 valuation
  fix (measure at best insertion) now *over-states* what the sim run will actually realize.

Reordering is a free, always-legal player action; a faithful referee must let the policy use it.
Cleanest honest design: the world applies the ENGINE's `Ordering.optimize` joker order (the
policy's own advice — opinion stays on the policy side) at shop exit / after each board change.
Direction of effect: raises the payoff of exactly the xmult-stack archetype; also makes
`ordering.lua`'s advice measurable for the first time. **Fix class: world fidelity (A-class).**
See E-3.

### 4.3 W4 — engine↔world consistency holes (CONFIRMED: code + data)

The A-phases fixed "world implements what the engine never uses" (A5) — the reverse direction
was never swept. Engine-valued features the world does not implement:

| feature | engine value | world behaviour | observed cost |
|---|---|---|---|
| v_hieroglyph | 5.0 FV base + 2.0 at-risk ("-1 ante, -1 hand") | **only** `base_hands −1` (−1 ante documented-unmodelled) | **26/160 runs pay $10 for a strict harm** |
| v_directors_cut | 3.0 FV ("reroll boss") | no-op | 7 buys × $10 |
| v_magic_trick | 2.0 FV | no-op | 4 buys × $10 |
| Credit Card credit | affordability extends to −$20 (`OS.credit`) | `apply_action` requires `dollars ≥ cost`, returns false → **shop phase ends** | shop truncated whenever the engine plans a credit buy |
| Blue seal (held → planet) | `card_econ_value` credits a planet-spawn fraction | never spawns in world | standard-pack picks mis-ranked |
| Purple seal (discard → tarot) | +0.10 frac | never spawns in world | ditto |
| consumable-pool dedup (A10) | engine holds planets; `DE.LEVEL_USE_CREDIT` tuned for it | world offers duplicates freely | hoarding cost under-modelled |
| tag_double / tag_boss | engine skip value $11 / $4 | explicit no-ops in `apply_tag` | phantom skip EV (rarely chosen today, but same class) |

Hieroglyph deserves its own line: in real Balatro it is a strong tempo voucher (−1 ante = ~3
extra shops at lower requirements); in the sim it is a $10 self-harm the engine buys in 16% of
runs (those runs still average slightly *later* deaths — 3.50 vs 3.32 progress — because only
rich, healthy runs can afford vouchers; the correlation masks the mechanical harm). Either
implement `−1 ante` in the world (FACTS; the driver's ante loop must become mutable) or zero the
engine's value for the unmodelled pieces until it is. **Fix class: fidelity/consistency.** See
E-4, plus a permanent guard: an automated cross-check test enumerating engine-valued
features vs world-implemented ones (§13 Tests).

### 4.4 W5 — F1/F2 survival arbitration coverage (CONFIRMED: code + data)

`decision_engine.lua:500`: `can_search = discards_left > 0 and hands_left >= 2 and
#(gs.consumables or {}) == 0`. The consumable gate predates F1/F2 (it guarded the old search.lua
override from conflicting with use_action logic). Post-leveling-fixes the engine deliberately
holds planets (LEVEL_USE_CREDIT timing, B1 buys, pack picks): **~65% of ante snapshots hold ≥1
consumable** (in-blind occupancy is somewhat lower as uses fire mid-blind), so the project's
best in-blind lever is off in a large share of mid-game blinds. Separately,
the `forced_play` branch (`:483`) still arbitrates the last-hand dig with the mean rule
(`discard_action.value >= remaining`) — the F3 revert taught that pure `P̂>0` is wrong *because
it ignores partial credit*, but `Sim.survive_after`'s E[frac] **is** the partial-credit-aware
objective and is simply not consulted there. Both are mechanism-repair extensions of an
already-proven lever, not new value re-weights. See E-5/E-6.

### 4.5 W1 — the objective being optimized is not winrate (methodology)

`run_outcome` progress and death-ante means are the verdict currency. But the deliverable is
winrate, which is `P(progress = 8.0)` — a tail statistic the current metrics track only weakly:
pushing 27 ante-2 deaths to ante 3 moves the mean as much as pushing 4 ante-6 runs to ante 8,
and only the latter approaches wins. Baseline tail: ante 6+ reached by 15/160; ante 7+ by 5.
Recommendations (§16 E-8/E-9): report and gate KEEP decisions on tail counts (reach-6+, reach-7+,
wins) alongside progress; add a **state-replay harness** for in-blind changes (evaluate P(clear)
/ E[frac] deltas on a fixed corpus of extracted blind states — this measures the policy directly,
immune to the seeded-RNG cascade churn that produced the F4/F8 false signals, and is ~100×
cheaper than full-run batches); and confirm KEEPs on a disjoint hold-out seed pool (e.g.
`s*1000+7`) to bound fixed-seed overfitting, which is now a real risk after ~10 sequential
KEEP decisions tuned on the same 160 seeds.

---

## 5. Decision pipeline review (in-blind)

Verified sound (unchanged from v1): per-hand play selection tiers (guaranteed > expected >
accumulate, money tie-break at overkill, F7 score_min tie-break), boss legality filtering (F5),
scaling-fuel survival gating, planet-use logic, Trading Card, Delayed-Gratification charging.

Weaknesses, in priority order:

- **P-1 (= W5).** Arbitration coverage: consumable gate + forced_play branch (§4.4).
- **P-2. Rollout-policy mismatch.** `simulation.rollout`'s discard policy is
  `Heuristics.best_discard` (poker-shape heuristic), not the engine's measured discard. The
  arbitration therefore compares "PLAY then heuristic policy" vs "DISCARD then heuristic
  policy" while the real continuation uses the measured policy. Bias is shared across both
  branches (CRN) so ranking damage is second-order, but it systematically misprices states where
  the measured policy would dig differently (exactly the joker-dig states). Cheap partial fix:
  make the rollout's discard boss-aware (it currently isn't); full fix (measured discard in the
  rollout) is a perf question — see §13.
- **P-3. Discard-set selection noise is addressable without F8.** `DV.best` measures each
  candidate set with a *continuing* shared RNG stream — candidate k's draws differ from candidate
  k+1's, so set selection carries avoidable comparison noise. Re-seeding the same per-state seed
  for **every candidate** (common random numbers across sets, same total cost) removes most of
  the between-set variance without touching sample counts or the guardrails (the C1/F8 trap was
  *changing the noise level the guardrails were tuned for*; CRN changes comparison noise, not
  marginal estimates — still measure paired, watch for churn). See E-7.
- **P-4. Candidate-set coverage (F4) remains open** but is correctly sequenced behind the
  planner: keep-sets toward the *committed* hand are the principled generator (plan-driven, one
  direction) rather than F4's blanket flush-digs. Couple with P-3, not alone.
- **P-5.** `search.lua` is dead code on the decision path (only tests call it) yet still
  required by decision_engine; remove/retire to avoid confusion (docs still describe it as the
  play-vs-discard refiner in places).
- **P-6.** Tier-0 accumulation (can't clear this hand) maximizes single-hand score with no pace
  concept; F1/F2 now covers most of this when it RUNS (another reason P-1 matters).

## 6. Joker system review (valuation, measurement, acquisition)

- **J-1 (= W2).** Acquisition mechanics on full boards: see §4.1. Fixes E-1/E-2.
- **J-2. Copier valuation needs an analytic form.** Extend the analytic-marginal idea to
  copiers: Blueprint/Brainstorm's marginal ≈ the best owned joker's measured on-hand marginal
  (position-corrected). Noise-free by construction, replaces a 100%-broken-then-patched MC path.
  (Couple with W3 — without world reorder, sim-Blueprint stays dead no matter its value.)
- **J-3. `scoring_gain` lacks the analytic conditional-xmult floor** that `jp_from_measure`
  now has — the direct-BUY path (used while slots are free, i.e. exactly when a cheap early Duo
  could be picked up) still sees 8-sample noise for conditional xmults. Port the same
  `max(measured, analytic)` there. Unit-consistency fix.
- **J-4. Measurement noise + floors (C1/C5)** remain the known coupled-retune project — not
  re-litigated here; the analytic path (J-2/J-3) is the correct noise-free escape hatch and
  should be exhausted first.
- **J-5. Sell-side is single-candidate.** SELL_JOKER evaluates only the weakest-by-protected-
  contribution joker. With keep_bias tiers this is usually right; but when the weakest is
  protected (e.g. all-scorer boards) no second candidate is ever considered. Low priority.
- **J-6.** `joker_downside` / `SELL_NUDGE`: Popcorn/Ice Cream/Gros Michel now genuinely decay in
  the sim (A1) — the static nudges + decay penalties double-charge them slightly on the sell
  path. Micro-item; fold into any keep_bias retune.
- **J-7.** Catalogue nits from v1 (K8: Reserved Parking $4 vs real $6 etc.) still open —
  VERIFY-tagged, low impact.

## 7. Shop strategy review

- **S-1 (= W4).** Voucher consistency holes; Hieroglyph. E-4.
- **S-2. Unit bridge audit (calibration-class — couple, don't ship alone).** BUY_JOKER values
  `w_score×(frac×5)`; BUY_VOUCHER values `w_score×FV`. The engine's own conversion says
  1 frac = 2.5 FV (`VU.FV_PER_FRAC`), so a joker's worth enters the ranking at 2 units per FV
  point while a voucher's enters at 1 — vouchers systematically at HALF weight unless
  `Vouchers.DATA` values were implicitly tuned to compensate (they were tuned empirically and
  predate B1). The B3 lesson applies verbatim: do NOT rescale in
  isolation; audit the four buy-path currencies (joker frac×5, pack frac×5, consumable frac×5
  post-B1, voucher FV×1) and re-anchor together, else leave alone. Evidence it may matter: 113
  voucher buys vs keystones skipped for vouchers (§4.1 samples).
- **S-3. Spend-guard asymmetry.** `econ_floor_penalty` is charged on jokers and packs but not on
  consumables or vouchers; consumables in the `gain>0` branch also skip `net_cost`. The ante-2
  median of $1 says early over-spend exists; consumables/vouchers are the uncharged channels.
  Unit-consistency candidate, but touching spend behaviour = measure paired.
- **S-4. Reroll policy is offer-blind to the plan.** 215 reroll recommendations, none targeted:
  reroll value is generic expected-best-joker improvement. Once committed (Phase 5), a reroll
  hunting for plan pieces (committed-hand xmults, planets for the committed hand) is the natural
  channel co-move — planner V2 material (E-10).
- **S-5. F6 shop-funding fired 5 times in 160 runs** — the option-cost pricing appears too
  strict to matter; cheap parameter probe only AFTER W2 lands (more keystones to fund).
- **S-6.** Shop-phase loop ends on first world-rejected action (`content.shop_phase`); combined
  with Credit Card (§4.3) or any future engine/world affordability drift this silently truncates
  shopping. Make the loop skip-and-continue on rejection (world-side robustness).
- **S-7. v1's B6 (skip-tag magnitudes) is still fully open.** Edition tags (foil/holo/poly) are
  free *edition jokers* in both real Balatro and the sim's own `apply_tag`, but the engine values
  them at flat $5/$7/$9 — below the measured value it would assign the same joker in a shop; and
  Handy/Garbage/Speed are computable from run counters the world already tracks
  (`run._hands_played`, `run._unused_discards`, `run._blinds_skipped`) **but those counters are
  never exported into the GameState**, so the engine cannot price them even if it wanted to
  (plumbing gap, same shape as the K1/K2 plumbing). Extend the shipped measured-tag machinery
  (`joker_dollars`) to the edition tags + plumb the counters. Mechanism/valuation class; measure
  paired (it raises skip frequency — the A5 groundwork made the payouts real, so this is the
  matching engine half).
- **S-8.** Pack-open advisor (`pack_open_advisor`) reviewed end-to-end: generator slot-fit,
  Fool copy-targeting, FV-symmetric full-board swap advice all coherent; no defects found.
- **S-9 (= v1 E1).** `skip_advisor.play_value` still omits forgone interest (skipping while at
  the cap is cheaper than modelled) and has no lose-risk term (a probably-fatal Big blind is
  priced like a trivial one). Small, bounded; bundle with S-7 if touched.

## 8. Deck-building review

- **D-1.** DeckPlan targets + removal valuation are coherent; the committed-plan integration
  (deck target follows commitment) landed in V1. Still missing: the *play* side never consults
  the committed hand (see E-10c) and thinning is only reachable in-blind (Hanged Man via
  `best_use`) — the human win used Hanged Man ×6; the engine's usage is negligible. After W2,
  re-check whether thinning offers are being out-competed by the (then-fixed) joker values.
- **D-2.** Standard-pack card rates in the world (12% enh / 4% seal / 3% edition) remain ~3×
  under real (~40%/20%/8%, VERIFY) — under-rewards deck-quality builds (Vampire/Glass/steel
  synergies, Hologram fuel). A9-leftover; one-line constants once verified. E-11.
- **D-3.** Suit-conversion/flush machinery is functional but archetype-blocked (offer-rate +
  commitment); correctly parked until the planner drives it.

## 9. Hand-play review

Covered in §5; additional facts-layer notes:

- **H-1.** Boss coverage gaps unchanged from v1 (Ox, Pillar, face-down info, Serpent, finisher
  effects; Arm/Tooth now modelled). Pillar is ante-1-pool and still a vanilla 2× — cheapest
  remaining boss item, but sim-easier-than-real fixes historically cost death-ante; ship as
  fidelity with eyes open.
- **H-2.** The Hook: rollout models the 2-random-discards (world + simulation), but the
  *decision* layer has no Hook-specific posture (multi-hand setups over-valued). Small, bounded.
- **H-3.** `hand_eval` correctness: no new defects found this pass (K-fixes verified in place;
  goldens recompute). Four Fingers/Shortcut/Quads-contains VERIFY items remain open questions
  (§20).

## 10. Economy review

- **E-y1.** Interest/bankroll-plan machinery (breakpoints, shop-wide budget, telescoping) —
  confirmed sane (v1 B7), no change.
- **E-y2.** Early game runs razor-thin ($1 median at ante 2). Whether this is optimal is
  genuinely unknown — it is the classic tempo-vs-econ frontier and every blunt knob tried
  historically backfired. Do not tune constants; instead let the tail metric (W1) adjudicate any
  future coupled change.
- **E-y3.** Income fidelity leftovers (v1 A8): Delayed Gratification pays its average even when
  discards are used; copier-econ doubling absent; SELL_TO_BUY consumable sale hardcodes $1.
  Small, honest-direction-mixed; batch as one A8b cluster.
- **E-y4.** `interest_penalty` horizon is a flat 3 rounds regardless of remaining runway
  (over-charges spending at ante 7+). Micro.

## 11. Search / evaluation review

- **V-1.** `Sim.survive_after` is the right objective (E[frac] = P(clear) + partial credit,
  CRN, boss-aware); its coverage (W5) and rollout policy (P-2) are the gaps, not its design.
- **V-2.** `search.lua` retire (P-5).
- **V-3.** Pacing G1 (variance-blind mean capacity; optimistic growth factor) is still the
  weakest evaluation component and it gates MANY behaviours (situation weights, proj_damp,
  invest window, pack need, commit_active). The v1 prescription stands: replace mean-capacity
  with a quantile/clear-prob capacity *measured from the samples already drawn* — as a coupled
  experiment (it failed as a constant tweak; the variance-aware form is a different hypothesis).
  After W1's tail metric exists, this is the natural next evaluation-layer experiment (E-12).
- **V-4.** `run_strength`/`future_value` weights: telemetry-facing, leave.
- **V-5.** Whole-visit shop planning (choose a SEQUENCE: reroll→buy→pack under one budget)
  remains untested; the old "lookahead no-op" verdict covered only single BUY selection. The
  bankroll plan gives the scaffolding. Speculative — park behind W2/planner V2 (§17 tier S).

## 12. Simulation fidelity review (world vs real Balatro)

Fixed and verified in v1 (A1–A9): scaler growth/decay, consumable execution, voucher effects (as
modelled), pack-pick immediate use, tag payouts, Arm/Tooth, play-money, editions/costs, boss
min-ante gating, Mr Bones, determinism.

Open, in priority order:

| id | gap | direction of bias | class |
|---|---|---|---|
| F-1 (=W3) | no joker REORDER action; Blueprint dead-in-sim | punishes xmult stacking (the winning archetype) | **world action-space** |
| F-2 (=W4) | Hieroglyph −1 ante; Director's Cut; Magic Trick; Credit Card; Blue/Purple seals; A10 dedup | engine pays for phantom value; slots/economy distorted | consistency |
| F-3 (=D-2) | standard-pack enh/seal/edition rates ~3× low | punishes deck-quality builds | constants (VERIFY) |
| F-4 | negative edition absent from shop/pack generation | slot-free jokers unreachable; engine values them | constants |
| F-5 | tag pool has no ante gating (real gates ~10 tags to ante 2+) | inflates ante-1 skip EV | constants (VERIFY) |
| F-6 | bosses: Pillar vanilla, Ox unapplied, face-down = perfect info, Serpent, finisher effects, Crimson Heart | sim easier than real (late antes) | mechanics |
| F-7 | first-shop guaranteed Buffoon pack absent | early joker access understated | constants (VERIFY) |
| F-8 | A8b income micro-gaps (§10 E-y3) | mixed | mechanics |
| F-9 | shop_phase ends on first rejected action (S-6) | truncates shopping on any engine/world drift | robustness |

None of these looks individually decisive, but F-1 + F-3 push in the SAME direction as every
pre-v1 gap: they under-reward exactly the build-investment behaviours the human wins used. The
lesson of Phase 1 was that this correlated bias class, in aggregate, was large enough to flip
strategy verdicts — treat the residue with the same seriousness.

## 13. Performance findings

- **n=160 batch ≈ 50 min (F1/F2 engine), ~98 min with the planner batch** — iteration speed is
  now the binding constraint on experiment throughput (laptop-sleep batch deaths compound it).
  Profile before optimizing (`tools/sim_profile.lua` exists but is minimal): prime suspects are
  `survive_after` (60 rollouts × 2 per eligible decision), per-shop `hand_frequencies`
  re-sampling (no cross-call cache; the reverted memo needs the cheap invalidation-aware deck
  signature from v1 I1), and the planner's extra `BuildPlan.advance`/commitment passes.
- **The state-replay harness (E-9) is also the perf fix for in-blind work**: measuring policy
  deltas on ~1–2k extracted blind states costs minutes, not hours, and has no cascade noise.
  Full-run batches remain the final verdict; replay becomes the screening tier.
- Fixing W5 (arbitration coverage) will RAISE runtime (more survive_after calls) — budget for
  it: consider SURV_SAMPLES 60→40 with CRN (paired-delta variance stays low) if needed, measured.
- Parallel batches: solved and exact; consider `sim_par.sh` chunk-restart (per-shard resume) so
  laptop sleep doesn't kill 50-minute batches (F8's measurement died to this THREE times).

**Tests (what's pinned vs missing).** 783 unit + 195 sim, direction/bounds style — good. Gaps
worth adding *before* the fixes: (1) a swap-path arithmetic test (full board, keystone worth
`worst_c + margin + ε` → swap MUST fire; would have caught W2b); (2) an engine↔world
consistency sweep test (for each voucher/tag/seal the ENGINE values > 0, assert the WORLD
implements a non-trivial effect, or the key is on an explicit documented-unmodelled list — turns
the W4 class into a permanent guard); (3) a sim-Blueprint end-to-end test once REORDER exists
(bought Blueprint must contribute > 0 to the next blind's score); (4) an arbitration-coverage
test (held planet does NOT disable survive_after after E-5); (5) keystone take-rate as a tracked
batch metric (not a hard test) so regressions are visible in every analyze run.

---

## 14. Review of previous experiments (methodology audit)

Assessed against their logs (§4–§7 of v1) with fresh eyes:

- **Phase 0–2 verdicts (A/B/C/K)** — sound. Paired design, mechanism checks, correct honesty
  about n.s. ships. No re-runs needed; the world fixes are facts.
- **Phase 3 (graveyard re-litigation)** — the *designs* were sound, but the headline conclusion
  ("a greedy per-decision valuation structurally cannot assemble a deck; the planner is the
  next lever") **over-reached given W2/W3**: the flush-commit/coupled retests were run on an
  engine whose keystone swap path double-taxed the very pieces a commitment would accumulate,
  and on a world where the assembled stack under-scores (no reorder) — the same
  confounded-referee shape v1 diagnosed in the pre-audit era, one layer down. The refutation of
  *suit-tarot deck-shaping* stands (offer-rate-limited is a fact); the generalization to "greedy
  can't assemble an xmult core" should be **downgraded to unresolved pending W2+W3**.
- **Phase 4 (F1/F2, F5 kept; F3/F4/F8 reverted)** — verdicts sound and the F4/F8 churn
  diagnosis (balanced sign + high sd = cascade, not signal) is an important, correct
  methodological finding. However: F1/F2's measured effect (+0.038) was taken on a state
  distribution where the gate was *live*; nobody measured its coverage. W5 says the shipped
  benefit is a fraction of the lever's potential — the cheapest high-info follow-up in the
  whole audit.
- **Phase 5 V1 (planner)** — the KEEP is defensible (surgical, uncommitted runs byte-identical,
  mechanism visible) but the effect decomposition shows ~half the aggregate from one cascade-luck
  seed (13003). The honest read: V1 is scaffolding-validated, performance-unproven. Refinement
  should wait for W2/W3 so its fit credits act on an open pipeline, and its verdicts should use
  the tail metric (a planner exists to create wins, not to shift ante-3 deaths to ante 4).
- **Cross-cutting**: ~10 sequential KEEPs were tuned/verified on the SAME fixed 160-seed pool.
  Each was individually n.s.; the arc (+0.41 death-ante since base160) is likely mostly real
  (mechanisms verified each time) but the fixed-pool overfitting risk is now material — adopt
  the hold-out confirmation pool (E-8) before the next KEEP.

## 15. Reconsideration of reverted ideas

| idea | v1 verdict | v2 disposition |
|---|---|---|
| C1 adaptive samples | reverted (guardrail mis-calibration) | stays reverted; **superseded** by analytic marginals (J-2/J-3) which are noise-free and need no guardrail retune |
| B3 $↔frac unify | reverted (needs co-retune) | stays reverted; folded into S-2's four-currency audit — attempt only as ONE coupled calibration with skip/keep constants |
| F3 last-hand P̂>0 dig | reverted (partial credit ignored) | **retry in a NEW form**: arbitrate forced_play digs with `survive_after` E[frac] (partial-credit-aware — repairs the exact premise that killed F3). E-6 |
| F4 discard generators | reverted (churn; depends on F8) | stays parked; retry only plan-driven (committed-hand keep-sets) + CRN (P-3/P-4), measured on the replay harness first |
| F8 two-stage sampling | reverted (C1-pattern) | superseded by CRN-across-candidates (E-7), which changes comparison noise, not the marginal-estimate noise the guardrails were tuned around |
| flush-commit / coupled pair | refuted (can't assemble; cascades) | stays reverted as a *valuation credit*; the underlying goal routes through planner V2 AFTER W2/W3 (§14 Phase-3 note) |
| swap-damp / scaler damps | refuted / keep committed gates | unchanged — and note the committed `proj_damp`+`scale_trigger_factor` are load-bearing guardrails for any W2 fix (swap frequency rises; the damps are what keeps un-fed scalers from exploiting the opened gate) |
| shop-buy lookahead/MCTS | no-op | stays refuted for buy-selection; the untested variant is whole-VISIT sequencing (V-5), speculative tier |
| leveling-need | FLIPPED, kept | unchanged |
| A1 pacing recalibration | reverted | superseded by the quantile-capacity form (E-12), a different hypothesis, post-W1 |

## 16. New experiment proposals

Format: hypothesis / mechanism / implementation sketch / measurement / success / rollback.
All engine changes paired n≥160 on the standard pool + confirmation on the hold-out pool once
adopted (E-8). "Replay" = the E-9 state-replay harness where applicable.

**E-1. Make the swap accounting coherent (W2b).** *Hypothesis:* valuing the swap as its true
net — `W_FV×max(0, g − worst_c − sell_margin) − net_cost(price) + DOLLAR_UTIL×cash`, with the
double `worst_c` charge removed and the same `w_score` treatment as the direct-buy path —
materially raises keystone take-rate without churn, because keep_bias/UPGRADE_MARGIN (the tuned
guardrails) remain in place. *Implementation:* a few lines + the §13 regression test (a keystone
worth `worst_c + margin + ε` on a full board MUST out-rank SAVE). *Measure:* keystone take-rate
when affordable (baseline table §4.1: Trio 0/5, Family 0/4, Ancient 1/8 …), sells/run
(baseline 2.6), paired progress + tail.
*Success:* take-rate ≥50%, sign test not worse, sells/run < 3.5. *Rollback:* churn signature
(balanced sign, sd > ~0.8).

**E-2. Full-board SWAP_BUY action (W2a).** *Hypothesis:* making "sell weakest + buy X" a single
first-class action (valued once as `g − worst_c − margin − net_cost + cash_delta`) lets
affordable keystones compete directly against vouchers/packs on full boards, instead of hiding
inside a SELL whose headline is the sale. *Implementation:* generate one SWAP_BUY candidate per
affordable shop joker on a full board (reuse the E-1 arithmetic; world applies sell-then-buy
atomically). Supersedes the two-step sell→re-recommend dance. *Measure:* as E-1 + BUY_VOUCHER/
BUY_PACK displacement. *Dependencies:* E-1 arithmetic. *Success/rollback:* as E-1.

**E-3. World REORDER action (W3).** *Hypothesis:* applying the engine's `Ordering.optimize`
joker order at shop-exit (and after pack/tag joker gains) raises realized board strength on
xmult boards and revives Blueprint, improving tail outcomes. *Implementation:* world-side hook
calling the policy's ordering advice (opinion stays policy-side); Blueprint targets re-resolve
per `effective_jokers`. Keep it deterministic. *Measure:* paired n=160 — expect the A1-style
signature (large symmetric swings, honest world) PLUS a positive tail lean; also
micro-benchmark: mean `avg_score` of the 94 xmult death boards before/after reordering
(direct, no batch needed). *Success:* micro-benchmark shows the expected `f×(x−1)` lift; batch
not worse; Blueprint's realized contribution > 0 in traces. *Note:* re-baseline after (world
change).

**E-4. Consistency sweep (W4).** *Hypothesis:* eliminating phantom-value purchases is a free
economy gain of ~$10–20 in the ~23% of runs that buy an inert/harmful voucher. *Implementation:*
(a) world: Hieroglyph `−1 ante` (driver ante-loop becomes mutable; requirements re-derive),
Credit Card debt honoured in `apply_action` (or engine credit zeroed in sim), Blue/Purple seal
effects (blue: planet at round end if held; purple: tarot on discard), shop_phase
skip-on-reject (F-9); (b) engine: value Director's Cut/Magic Trick at 0 until modelled (one
table edit each, documented); (c) the §13 consistency-sweep test so the class stays closed.
*Measure:* paired; Hieroglyph buys should persist (now genuinely good) — watch death-ante of
hiero-buying seeds specifically. *Success:* no phantom buys remain; batch not worse.

**E-5. Arbitration coverage: drop the consumable gate (W5a).** *Hypothesis:* running
survive_after with held consumables (they don't affect the rollout — uses are separate actions)
extends the proven +0.038 lever to the ~65% of states where it is currently off, with the same
sign-positive shape. *Implementation:* remove `#consumables == 0` from `can_search`; keep the
use_action promotion logic untouched (it already runs before/independently). Budget: runtime
up; pre-profile (E-13). *Measure:* paired n=160 + replay corpus (P(clear) delta on held-
consumable states). *Success:* sign-positive lean like F1/F2's; runtime acceptable. *Rollback:*
churn signature.

**E-6. Forced-play E[frac] arbitration (W5b, the corrected F3).** *Hypothesis:* on the last
hand with discards left, comparing `survive_after(PLAY)` vs `survive_after(DISCARD)` (E[frac]
credits the partial score a failed dig sacrifices — the exact F3 failure mode) converts some
certain losses into survivals without the F3 regression. *Implementation:* extend the F1/F2
branch to `forced_play` (hands_left==1, discards>0), margin-gated as now. *Measure:* replay
first (corpus of last-hand states from baseline deaths), then paired batch. *Success:* replay
E[frac] strictly-nonneg mean delta; batch sign lean positive. *Rollback:* if replay shows the
mean-rule already matches E[frac] decisions >95%, skip the batch (null result, close the item).

**E-7. CRN across discard candidate sets (P-3).** *Hypothesis:* re-seeding the same stream per
candidate removes between-set comparison noise and improves dig choices at zero cost.
*Implementation:* in `DV.best`, `rng = lcg(seed)` fresh per candidate (seed from state, as now).
*Measure:* replay corpus (dig-choice agreement with a 100-sample oracle: does CRN pick the
oracle's set more often?), then paired batch. *Success:* oracle agreement up ≥5 points; batch
non-negative. *Rollback:* churn.

**E-8. Hold-out seed pool + tail gates (W1a).** *Process change:* every KEEP requires (a) standard
pool paired verdict as today AND (b) non-negative tail (reach-6+ count) on the standard pool AND
(c) a one-off confirmation batch on `s*1000+7` seeds before commit. Cost: one extra batch per
KEEP. This bounds fixed-pool overfitting and re-anchors decisions to winrate direction.

**E-9. State-replay harness (W1b).** *Build:* extract ~1–2k in-blind decision states (hand,
pile, resources, boss, board) from baseline JSONL traces into fixtures; a runner evaluates a
candidate policy's action choice and its `survive_after`-style E[frac] under a high-sample
oracle, reporting per-state deltas vs the incumbent policy. *Use:* screening tier for ALL
in-blind changes (E-5/6/7, any F4 retry) — minutes per experiment, no cascade churn, direct
policy measurement. *Note:* the harness measures policy quality, not run outcomes; batches
remain the final gate. ~1–2 days of tooling that pays for itself within Tier 2.

**E-10. Planner V2 (after E-1..E-4).** Three coupled refinements, one batch each: (a)
**commit-rate**: anchor thresholds currently leave 106/160 runs uncommitted; test
COMMIT_THRESHOLD 3.0→2.5 with the existing upgrade guardrails; (b) **channel co-move**: reroll
value += committed-piece hunt term (S-4); skip-tag value += plan fit (Orbital → committed hand's
planet; Buffoon when the plan wants jokers); (c) **play integration**: a scaling_fuel-style
committed-hand credit (play the committed hand at equal survival, so Supernova/hand-type counts
and levels concentrate). Verdicts on tail metric + committed-run slice (V1 precedent: 54-run
slice showed +0.119 while aggregate showed +0.033). *Rollback per item.*

**E-11. Standard-pack rates + negative editions + tag gating (F-3/4/5).** Verify against
wiki/source; set constants; re-baseline (world change). Expect deck-quality archetypes to open
up; watch Standard-pack buy rate (baseline 690 packs).

**E-12. Quantile capacity for pacing (V-3, post-W1).** Replace `avg×hands` with
30th-percentile×hands from the same samples; co-move the thresholds that consume `margin`
(situation weights, invest window, HOPELESS_MARGIN, pack_need) in ONE coupled experiment.
High-risk class (the graveyard's shape) — only worth attempting with the replay harness +
tail gates in place, and only if post-W2 deaths remain BUILD-dominated with "thought it was
on-pace" signatures (on-pace% at ante 4–5 is 20–29% while death clear-ratios sit at 0.6 —
the signature is present today).

**E-13. Profiling + batch resume (perf).** Profile a full run (planner path incl.); implement
per-shard resume in `sim_par.sh`; consider SURV_SAMPLES trim with CRN if E-5's cost demands it.

## 17. Prioritised roadmap

**Tier 0 — process (this week, before any engine change).**
1. E-8 tail gates + hold-out pool (hours). 2. §13 consistency-sweep + swap-arithmetic tests.
3. E-13 profiling/resume.

**Tier 1 — high confidence × high impact (the acquisition unblock).**
4. E-1 swap-accounting fix → 5. E-2 SWAP_BUY action → 6. E-4 consistency sweep (incl.
Hieroglyph world fix) → 7. E-3 world REORDER (+ re-baseline). Each is unit/mechanism/fidelity
class; each individually cheap (hours, not days). *This tier is the audit's core bet: it
completes the keystone pipeline v1 started opening (C2/C3) and lets the winning archetype
actually score.*

**Tier 2 — high confidence × medium impact (in-blind coverage).**
8. E-9 replay harness → 9. E-5 consumable-gate removal → 10. E-6 forced-play E[frac] →
11. E-7 CRN digs. (9–11 screened on the harness, confirmed in batches.)

**Tier 3 — medium (the strategy layer, now on a working pipeline).**
12. E-10 planner V2 (a→b→c). 13. J-2/J-3 analytic copier/scoring_gain floors. 14. E-11 world
rates cluster. 15. S-7 skip-tag magnitudes + counter plumbing (the B6 engine half of A5).

**Tier 4 — conditional / coupled-calibration class (attempt only with explicit experiment
discipline).** 16. E-12 quantile pacing. 17. S-2 currency audit (+S-3 floor symmetry). 18. the
coupled F4+CRN plan-driven digs. 19. Phase 6 live re-sync (unchanged from v1: the whole
faithful-world engine is sim-side; K1/K2/F5 remain live correctness risks) — schedule whenever
live play matters; it does not affect sim winrate.

**Tier S — speculative research.** Whole-visit shop sequencing (V-5); MCTS remains correctly
deferred; RL out of scope; endless-ante play-to-strength (irrelevant to ante-8 winrate).

## 18. Expected winrate impact (honest ranges, from 0/160)

Point estimates are not honest at 0 observed wins; directional ranges with reasoning:

- **Tier 1 bundle (W2+W3+W4):** the only changes on the direct causal path to the winning
  archetype. If keystone take-rate goes ~0→50%+ on full boards and assembled stacks score their
  real (reordered) value, the 15-run ante-6+ tail should grow materially; first repeatable wins
  (1–5/160) are a realistic outcome, not a promise. Confidence the bundle is positive: high.
  Confidence it produces wins by itself: medium-low (the tail also needs levels ≥8+, which the
  leveling channel now supplies at median 3–4 by ante 6 — close but thin).
- **Tier 2 (in-blind coverage):** F1/F2's shipped effect was +0.038 at ~1/3 coverage; naive
  scaling suggests up to ~+0.05–0.08 progress additional, mostly mid-run survival → feeds the
  tail indirectly. Confidence: medium-high (mechanism proven; scaling assumption unproven).
- **Tier 3 planner V2:** unbounded upside in principle (it is the archetype-assembly layer) but
  V1's honest read is +0.03-with-caveats; refined on an unblocked pipeline it is the most
  plausible source of consistent (>3%) winrate — confidence: low-medium, the experiment exists
  to find out.
- **Tier 4:** each individually ±0 to small; they exist to remove known distortions, not to win.

## 19. Confidence statement

Code-level findings W2b (swap accounting), W3 (no reorder / Blueprint), W4 rows, W5 (gate) are
**read directly from the current working tree and are certain as descriptions of behaviour**;
their winrate impact is inference. Data findings are computed from `p5_commit.jsonl` (n=160)
with scripts retained in the session scratchpad; take-rates and buy-counts are exact counts, not
estimates. The strategic thesis (§1 verdict) is a judgment call with the explicit falsifier
built in: if Tier 1 lands cleanly and keystone-stacked, reordered, honestly-valued boards STILL
plateau at 0 wins with BUILD-dominated deaths, then the residual wall really is strategic and
planner V2 / E-12 become the whole game.

## 20. Open questions

1. Real-Balatro VERIFY backlog: standard-pack rates (F-3), tag ante-gating list (F-5), first-shop
   Buffoon (F-7), Hieroglyph exact semantics (ante floor at 1?), Four Fingers 4-of-5 subset rule,
   Shortcut ace-low gaps, Quads-contains-Two-Pair, catalogue costs (K8).
2. Is early spend-to-$1 optimal (E-y2)? Only answerable post-W1 with tail metrics.
3. How much of F1/F2's +0.038 was coverage-limited (E-5 answers)?
4. Does the Phase-3 "greedy can't assemble" conclusion survive W2+W3 (Tier 1 answers)?
5. Should the sim model stakes beyond White / decks beyond Red? (Out of scope until winrate > 0
   at White.)
6. Live-path parity (Phase 6): K1/K2 plumbing via `state_extraction` is still absent — the live
   mod runs conservative reads; F7 dumps for Loyalty/Card Sharp/Supernova/Idol/Ancient remain
   the checklist.
